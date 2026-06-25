// Unit tests for the summarizer pure core. Run via `npm test`
// (tsc -> dist, then node --test dist/**/*.test.js). Built-in node:test runner,
// no vitest/jest dep.

import test from "node:test";
import assert from "node:assert/strict";

import type { Surface } from "./mcp.js";
import {
  DEFAULT_CONFIG,
  ConcurrencyBudget,
  buildContext,
  coerceBool,
  coerceAttention,
  composePrompt,
  eachJsonObject,
  extractFirstJsonObject,
  changeSignals,
  changeTail,
  tailChangeRatio,
  backoffDelayMs,
  isQuiescent,
  normalizeChangeLine,
  lineMultiset,
  fnv1a,
  isAgentSurface,
  lastLines,
  parseSummary,
  preGate,
  serializeContext,
  shouldSummarize,
  stripFences,
  truncateCodePoints,
  alertEdge,
  bellRoseEdge,
  SUMMARY_MAX_LEN,
  type LastSummary,
  type SummarizerConfig,
  type SurfaceSnapshot,
} from "./summarizer.js";

const cfg = DEFAULT_CONFIG;

/** Build a LastSummary that MATCHES a snapshot's current signals + change-tail (the
 *  "we just summarized this exact state" record), so a follow-up `shouldSummarize`
 *  with an unchanged screen takes the unchanged path. */
function lastFrom(
  s: SurfaceSnapshot,
  atMs: number,
  summary = "old",
  c: SummarizerConfig = cfg,
): LastSummary {
  return {
    signals: changeSignals(s.surface),
    tail: changeTail(s.viewport, c),
    atMs,
    summary,
  };
}

function makeSurface(over: Partial<Surface> = {}): Surface {
  return {
    id: "uuid-1",
    title: "claude — ghostty",
    pwd: "/Users/ramon/git/ghostty",
    window: 0,
    tab: 0,
    tabTitle: "ghostty",
    splitIndex: 0,
    splitCount: 1,
    focused: false,
    bell: false,
    exited: false,
    atPrompt: false,
    ...over,
  };
}

function snap(over: Partial<Surface> = {}, viewport = ""): SurfaceSnapshot {
  return { surface: makeSurface(over), viewport };
}

// ---------------------------------------------------------------------------
// isAgentSurface
// ---------------------------------------------------------------------------

test("isAgentSurface: agentState present => true", () => {
  assert.equal(isAgentSurface(makeSurface({ agentState: "working" }), cfg), true);
});

test("isAgentSurface: known processName => true", () => {
  assert.equal(isAgentSurface(makeSurface({ processName: "claude" }), cfg), true);
});

test("isAgentSurface: unknown processName, no state => false", () => {
  assert.equal(isAgentSurface(makeSurface({ processName: "zsh" }), cfg), false);
});

test("isAgentSurface: agentKind present (detector) => true", () => {
  assert.equal(isAgentSurface(makeSurface({ agentKind: "claude" }), cfg), true);
});

test("isAgentSurface: pool wrapper (processName=bash) but agentKind set => true", () => {
  // The real-world case: claude runs under the claude-pool `bash` wrapper, so the
  // foreground processName is "bash" and never matches the agent list — only the
  // dashboard's subtree-walk detection (agentKind) recognizes it.
  assert.equal(
    isAgentSurface(
      makeSurface({ processName: "bash", command: "bash claude-pool", agentKind: "claude" }),
      cfg,
    ),
    true,
  );
});

test("isAgentSurface: pool wrapper (bash) with NO agentKind/state => false", () => {
  assert.equal(
    isAgentSurface(makeSurface({ processName: "bash", command: "bash claude-pool" }), cfg),
    false,
  );
});

test("isAgentSurface: bare row (no optionals) => false", () => {
  assert.equal(isAgentSurface(makeSurface(), cfg), false);
});

test("isAgentSurface: exited agent => false", () => {
  assert.equal(
    isAgentSurface(makeSurface({ agentState: "working", exited: true }), cfg),
    false,
  );
});

// ---------------------------------------------------------------------------
// change detection: signals / changeTail / tailChangeRatio / normalize
// ---------------------------------------------------------------------------

test("changeSignals: identical hook tuple => identical hash", () => {
  const a = makeSurface({ agentState: "working", lastTool: "Edit", lastPrompt: "do" });
  const b = makeSurface({ agentState: "working", lastTool: "Edit", lastPrompt: "do" });
  assert.equal(changeSignals(a), changeSignals(b));
});

test("changeSignals: changed lastTool => different hash", () => {
  const a = makeSurface({ agentState: "working", lastTool: "Edit" });
  const b = makeSurface({ agentState: "working", lastTool: "Bash" });
  assert.notEqual(changeSignals(a), changeSignals(b));
});

test("changeSignals: ignores the viewport (tail handles that)", () => {
  // Same hook tuple, different screen => signals are equal (the tail carries screen).
  const a = makeSurface({ agentState: "working" });
  assert.equal(changeSignals(a), changeSignals({ ...a }));
});

test("normalizeChangeLine: strips spinner + collapses digits/space", () => {
  // An animated footer line normalizes to a STABLE string across ticks.
  const a = normalizeChangeLine("⠋ Thinking… (12s · esc to interrupt)");
  const b = normalizeChangeLine("⠙ Thinking… (47s · esc to interrupt)");
  assert.equal(a, b);
});

test("normalizeChangeLine: real content survives", () => {
  assert.equal(normalizeChangeLine("  Editing  src/foo.ts  "), "Editing src/foo.ts");
});

test("changeTail: only the last N lines feed change detection", () => {
  const tailN = cfg.fingerprintTailLines;
  const head = Array.from({ length: 50 }, (_, i) => `h${i}`).join("\n");
  const tail = Array.from({ length: tailN }, (_, i) => `t${i}`).join("\n");
  const a = changeTail(`${head}\n${tail}`, cfg);
  const b = changeTail(`DIFFERENT_HEAD\n${tail}`, cfg);
  assert.equal(a, b);
});

test("tailChangeRatio: identical tails => 0", () => {
  assert.equal(tailChangeRatio("a\nb\nc", "a\nb\nc"), 0);
});

test("tailChangeRatio: two empty tails => 0", () => {
  assert.equal(tailChangeRatio("", ""), 0);
});

test("tailChangeRatio: one differing line out of many => small ratio", () => {
  const prev = Array.from({ length: 20 }, (_, i) => `line${i}`).join("\n");
  const cur = prev.replace("line19", "line19-CHANGED");
  const r = tailChangeRatio(prev, cur);
  // 1 line replaced => 2 of 21 distinct lines differ => well under the 0.2 threshold.
  assert.ok(r > 0 && r < 0.2, `ratio ${r}`);
});

test("tailChangeRatio: a screen of fresh output => high ratio", () => {
  const prev = Array.from({ length: 20 }, (_, i) => `old${i}`).join("\n");
  const cur = Array.from({ length: 20 }, (_, i) => `new${i}`).join("\n");
  assert.ok(tailChangeRatio(prev, cur) > 0.9);
});

test("tailChangeRatio: spinner-only animation (via changeTail) => 0", () => {
  // The whole point: an idle agent whose ONLY change is the footer spinner/timer
  // compares EQUAL once normalized, so it never re-summarizes.
  const base = Array.from({ length: 18 }, (_, i) => `body line ${i}`).join("\n");
  const prev = changeTail(`${base}\n⠋ Thinking… (3s · esc to interrupt)`, cfg);
  const cur = changeTail(`${base}\n⠙ Thinking… (41s · esc to interrupt)`, cfg);
  assert.equal(tailChangeRatio(prev, cur), 0);
});

test("backoffDelayMs: streak 0 (or less) => 0 (normal cadence)", () => {
  assert.equal(backoffDelayMs(0, 30000, 600000), 0);
  assert.equal(backoffDelayMs(-3, 30000, 600000), 0);
});

test("backoffDelayMs: exponential in the streak, base at streak 1", () => {
  assert.equal(backoffDelayMs(1, 30000, 600000), 30000);
  assert.equal(backoffDelayMs(2, 30000, 600000), 60000);
  assert.equal(backoffDelayMs(3, 30000, 600000), 120000);
  assert.equal(backoffDelayMs(4, 30000, 600000), 240000);
});

test("backoffDelayMs: capped at maxMs (and overflow-safe for a huge streak)", () => {
  assert.equal(backoffDelayMs(5, 30000, 600000), 480000);
  assert.equal(backoffDelayMs(6, 30000, 600000), 600000); // would be 960000, capped
  assert.equal(backoffDelayMs(100, 30000, 600000), 600000); // no overflow
});

test("isQuiescent: waiting/idle true; working/undefined false", () => {
  assert.equal(isQuiescent("waiting"), true);
  assert.equal(isQuiescent("idle"), true);
  assert.equal(isQuiescent("working"), false);
  assert.equal(isQuiescent(undefined), false);
});

test("lineMultiset: counts non-blank lines, drops blanks", () => {
  const m = lineMultiset("a\n\nb\na\n   ");
  assert.equal(m.get("a"), 2);
  assert.equal(m.get("b"), 1);
  assert.equal(m.size, 2);
});

// ---------------------------------------------------------------------------
// shouldSummarize truth table
// ---------------------------------------------------------------------------

test("shouldSummarize: non-agent => skip not-agent", () => {
  const d = shouldSummarize(snap({ processName: "zsh" }), undefined, 0, cfg);
  assert.deepEqual(d, { due: false, reason: "not-agent" });
});

test("shouldSummarize: hidden agent => skip hidden", () => {
  // A tile the user hid in the dashboard is skipped (no Haiku call), even when first.
  const d = shouldSummarize(snap({ agentState: "working", hidden: true }), undefined, 0, cfg);
  assert.deepEqual(d, { due: false, reason: "hidden" });
});

test("shouldSummarize: hidden but skipHidden disabled => not skipped for hidden", () => {
  const d = shouldSummarize(
    snap({ agentState: "working", hidden: true }), undefined, 0,
    { ...cfg, skipHidden: false },
  );
  assert.equal(d.reason, "first"); // falls through to the normal path
});

test("shouldSummarize: first time for an agent => due first", () => {
  const d = shouldSummarize(snap({ agentState: "working" }), undefined, 1_000_000, cfg);
  assert.equal(d.due, true);
  assert.equal(d.reason, "first");
});

test("shouldSummarize: within debounce => skip debounce", () => {
  const s = snap({ agentState: "working" }, "x");
  const last = lastFrom(s, 1000);
  const d = shouldSummarize(s, last, 1000 + cfg.debounceMs - 1, cfg);
  assert.deepEqual(d, { due: false, reason: "debounce" });
});

test("shouldSummarize: changed hook signal past debounce => due changed-signal", () => {
  const sLast = snap({ agentState: "working", lastTool: "Edit" }, "x");
  const sNow = snap({ agentState: "working", lastTool: "Bash" }, "x");
  const last = lastFrom(sLast, 0);
  const d = shouldSummarize(sNow, last, cfg.debounceMs + 1, cfg);
  assert.deepEqual(d, { due: true, reason: "changed-signal" });
});

test("shouldSummarize: big screen change past debounce => due changed", () => {
  const body = Array.from({ length: 20 }, (_, i) => `old${i}`).join("\n");
  const sLast = snap({ agentState: "working" }, body);
  const sNow = snap(
    { agentState: "working" },
    Array.from({ length: 20 }, (_, i) => `new${i}`).join("\n"),
  );
  const last = lastFrom(sLast, 0);
  const d = shouldSummarize(sNow, last, cfg.debounceMs + 1, cfg);
  assert.deepEqual(d, { due: true, reason: "changed" });
});

test("shouldSummarize: QUIESCENT + spinner-only churn => skip quiescent-unchanged", () => {
  // THE headline cost fix: a waiting agent whose footer only animates is NOT
  // re-summarized — its normalized tail is unchanged and it has nothing new to say.
  const body = Array.from({ length: 18 }, (_, i) => `body ${i}`).join("\n");
  const sLast = snap({ agentState: "waiting" }, `${body}\n⠋ idle (3s)`);
  const sNow = snap({ agentState: "waiting" }, `${body}\n⠙ idle (88s)`);
  const last = lastFrom(sLast, 0);
  const d = shouldSummarize(sNow, last, cfg.debounceMs + 1, cfg);
  assert.deepEqual(d, { due: false, reason: "quiescent-unchanged" });
});

test("shouldSummarize: idle agent + spinner churn => skip quiescent-unchanged", () => {
  const sLast = snap({ agentState: "idle" }, "done\n⠋ (1s)");
  const sNow = snap({ agentState: "idle" }, "done\n⠹ (9s)");
  const d = shouldSummarize(sNow, lastFrom(sLast, 0), cfg.debounceMs + 1, cfg);
  assert.deepEqual(d, { due: false, reason: "quiescent-unchanged" });
});

test("shouldSummarize: unchanged AND idle-seconds past threshold (no hook state) => idle-unchanged", () => {
  // No agentState (not quiescent) but provably idle by idleSeconds => still skip.
  const s = snap({ processName: "claude", idleSeconds: cfg.idleSkipSeconds + 5 }, "x");
  const d = shouldSummarize(s, lastFrom(s, 0), cfg.debounceMs + 1000, cfg);
  assert.deepEqual(d, { due: false, reason: "idle-unchanged" });
});

test("shouldSummarize: unchanged, non-quiescent, not provably idle => due unchanged-not-idle", () => {
  // A working agent whose tail happens to sit unchanged this tick still re-summarizes.
  const s = snap({ agentState: "working" }, "x");
  const d = shouldSummarize(s, lastFrom(s, 0), cfg.debounceMs + 1, cfg);
  assert.deepEqual(d, { due: true, reason: "unchanged-not-idle" });
});

test("shouldSummarize: debounce wins over a changed screen", () => {
  const sNow = snap({ agentState: "working", lastTool: "Bash" }, "x");
  const last: LastSummary = { signals: "different", tail: "different", atMs: 5000, summary: "old" };
  const d = shouldSummarize(sNow, last, 5000 + cfg.debounceMs - 1, cfg);
  assert.equal(d.reason, "debounce");
  assert.equal(d.due, false);
});

// ---------------------------------------------------------------------------
// preGate (cheap, row-fields-only pre-filter)
// ---------------------------------------------------------------------------

test("preGate: non-agent => not-agent", () => {
  assert.deepEqual(
    preGate(makeSurface({ processName: "zsh" }), undefined, 0, cfg),
    { pass: false, reason: "not-agent" },
  );
});

test("preGate: hidden agent => hidden (avoids the read_surface)", () => {
  assert.deepEqual(
    preGate(makeSurface({ agentState: "working", hidden: true }), undefined, 0, cfg),
    { pass: false, reason: "hidden" },
  );
});

test("preGate: agent, no last => candidate", () => {
  assert.deepEqual(
    preGate(makeSurface({ agentState: "working" }), undefined, 0, cfg),
    { pass: true, reason: "candidate" },
  );
});

test("preGate: within debounce => debounce", () => {
  const last: LastSummary = { signals: "x", tail: "x", atMs: 1000, summary: "s" };
  assert.deepEqual(
    preGate(makeSurface({ agentState: "working" }), last, 1000 + cfg.debounceMs - 1, cfg),
    { pass: false, reason: "debounce" },
  );
});

test("preGate: past debounce => candidate (defers change/idle to full gate)", () => {
  const last: LastSummary = { signals: "x", tail: "x", atMs: 0, summary: "s" };
  assert.deepEqual(
    preGate(makeSurface({ agentState: "working", idleSeconds: 999 }), last, cfg.debounceMs + 1, cfg),
    { pass: true, reason: "candidate" },
  );
});

// ---------------------------------------------------------------------------
// parseSummary tolerance
// ---------------------------------------------------------------------------

test("parseSummary: plain JSON object", () => {
  const r = parseSummary('{"summary":"Running tests","phase":"testing","needsUser":false}');
  assert.deepEqual(r, { summary: "Running tests", phase: "testing", needsUser: false });
});

test("parseSummary: fenced json block", () => {
  const r = parseSummary('```json\n{"summary":"Editing file"}\n```');
  assert.deepEqual(r, { summary: "Editing file" });
});

test("parseSummary: bare fence (no lang)", () => {
  const r = parseSummary('```\n{"summary":"Waiting"}\n```');
  assert.deepEqual(r, { summary: "Waiting" });
});

test("parseSummary: prose around the JSON", () => {
  const r = parseSummary('Here is the status:\n{"summary":"Building"} hope that helps');
  assert.deepEqual(r, { summary: "Building" });
});

test("parseSummary: braces inside the summary string don't break extraction", () => {
  const r = parseSummary('{"summary":"Refactoring fn() { ... }"}');
  assert.deepEqual(r, { summary: "Refactoring fn() { ... }" });
});

test("parseSummary: trims and truncates an over-long summary", () => {
  const long = "x".repeat(SUMMARY_MAX_LEN + 50);
  const r = parseSummary(`{"summary":"  ${long}  "}`);
  assert.ok(r);
  assert.equal(r!.summary.length, SUMMARY_MAX_LEN);
});

test("parseSummary: coerces needsUser from a string", () => {
  const r = parseSummary('{"summary":"Blocked","needsUser":"true"}');
  assert.deepEqual(r, { summary: "Blocked", needsUser: true });
});

test("parseSummary: drops blank phase", () => {
  const r = parseSummary('{"summary":"Hi","phase":"   "}');
  assert.deepEqual(r, { summary: "Hi" });
});

test("parseSummary: empty summary => null", () => {
  assert.equal(parseSummary('{"summary":"   "}'), null);
});

test("parseSummary: missing summary => null", () => {
  assert.equal(parseSummary('{"phase":"testing"}'), null);
});

test("parseSummary: garbage => null", () => {
  assert.equal(parseSummary("totally not json at all"), null);
});

test("parseSummary: empty string => null", () => {
  assert.equal(parseSummary(""), null);
});

test("parseSummary: JSON array (not object) => null", () => {
  assert.equal(parseSummary('["summary","x"]'), null);
});

test("parseSummary: malformed JSON => null", () => {
  assert.equal(parseSummary('{"summary": '), null);
});

test("parseSummary: a preamble object WITHOUT summary => uses the LATER object", () => {
  // Haiku sometimes emits a reasoning object before the answer object; the first
  // balanced {...} must NOT win if it lacks a usable summary.
  const r = parseSummary('{"reasoning":"thinking"}\n{"summary":"real"}');
  assert.deepEqual(r, { summary: "real" });
});

test("parseSummary: stray prose braces before the real object => recovers", () => {
  // The first balanced brace `{this}` is not valid JSON; the parser must skip it
  // and parse the real object that follows.
  const r = parseSummary('use {this} format: {"summary":"x"}');
  assert.deepEqual(r, { summary: "x" });
});

test("parseSummary: a parse-failure object then a valid one => recovers", () => {
  // First balanced object is JSON-invalid (single quotes); skip to the valid one.
  const r = parseSummary("{'not':'json'} then {\"summary\":\"ok\"}");
  assert.deepEqual(r, { summary: "ok" });
});

test("parseSummary: multiple valid objects => first with a usable summary wins", () => {
  const r = parseSummary('{"summary":"first"} {"summary":"second"}');
  assert.deepEqual(r, { summary: "first" });
});

test("parseSummary: truncation does not split a surrogate pair at the boundary", () => {
  // 119 ascii chars + a 1-code-point emoji (2 UTF-16 units) at code point #120:
  // naive code-unit slicing would cut mid-surrogate; code-point slicing keeps it.
  const summary = "x".repeat(SUMMARY_MAX_LEN - 1) + "😀" + "tail";
  const r = parseSummary(JSON.stringify({ summary }));
  assert.ok(r);
  const out = r!.summary;
  // Exactly SUMMARY_MAX_LEN code points, and no trailing lone high surrogate.
  assert.equal(Array.from(out).length, SUMMARY_MAX_LEN);
  const lastUnit = out.charCodeAt(out.length - 1);
  assert.ok(
    !(lastUnit >= 0xd800 && lastUnit <= 0xdbff),
    "no trailing lone high surrogate",
  );
  // The emoji at the boundary survives intact as the final code point.
  assert.equal(Array.from(out).at(-1), "😀");
});

// ---------------------------------------------------------------------------
// composePrompt / serializeContext / buildContext
// ---------------------------------------------------------------------------

test("composePrompt: includes base and serialized context; no override", () => {
  const ctx = buildContext(
    snap({ agentState: "working", lastTool: "Edit" }, "hello\nworld"),
    "prev summary",
    cfg,
  );
  const { system, user } = composePrompt("BASE_PROMPT", null, ctx);
  assert.equal(system, "BASE_PROMPT"); // no override appended
  assert.match(user, /Agent state: working/);
  assert.match(user, /Last tool: Edit/);
  assert.match(user, /Your previous summary: prev summary/);
  assert.match(user, /hello\nworld/);
});

test("composePrompt: appends override under a delimiter", () => {
  const ctx = buildContext(snap({ agentState: "idle" }), undefined, cfg);
  const { system } = composePrompt("BASE", "Prefer terse verbs.", ctx);
  assert.match(system, /^BASE/);
  assert.match(system, /USER NOTES/);
  assert.match(system, /Prefer terse verbs\./);
});

test("serializeContext: omits unknown optional fields", () => {
  const ctx = buildContext(snap({ agentState: "working" }), undefined, cfg);
  const text = serializeContext(ctx);
  assert.doesNotMatch(text, /User request/);
  assert.doesNotMatch(text, /Last tool/);
  assert.doesNotMatch(text, /Idle seconds/);
  assert.doesNotMatch(text, /previous summary/);
});

test("serializeContext: empty viewport shows placeholder", () => {
  const ctx = buildContext(snap({ agentState: "working" }, ""), undefined, cfg);
  assert.match(serializeContext(ctx), /\(no output\)/);
});

test("serializeContext: leads with the actionable signals (state + request)", () => {
  const ctx = buildContext(
    snap({ agentState: "waiting", lastPrompt: "add the migration" }, "out"),
    undefined,
    cfg,
  );
  const text = serializeContext(ctx);
  assert.match(text, /User request: add the migration/);
  // Agent state and the request precede the raw terminal output.
  assert.ok(text.indexOf("Agent state:") < text.indexOf("Recent terminal output"));
  assert.ok(text.indexOf("User request:") < text.indexOf("Recent terminal output"));
});

// (ramon fork / Bell Attention) The bellRang clause is the ONLY thing that asks
// Haiku for the `attention` verdict — if it regresses the whole promotion path
// silently dies, and the runSweep tests can't catch it (they stub the model). So
// assert serializeContext actually emits it on bellRang, and omits it otherwise.
test("serializeContext: bellRang emits the bell clause asking for `attention`", () => {
  const text = serializeContext(
    buildContext(snap({ agentState: "working" }, "out"), undefined, cfg, true),
  );
  assert.match(text, /A terminal bell just rang on this surface/);
  assert.match(text, /return `attention`/);
});

test("serializeContext: no bellRang (false or omitted) => the bell clause is absent", () => {
  const off = serializeContext(
    buildContext(snap({ agentState: "working" }, "out"), undefined, cfg, false),
  );
  assert.doesNotMatch(off, /terminal bell just rang/i);
  const omitted = serializeContext(
    buildContext(snap({ agentState: "working" }, "out"), undefined, cfg),
  );
  assert.doesNotMatch(omitted, /terminal bell just rang/i);
});

test("buildContext: prompt window uses promptTailLines (wider than the fingerprint)", () => {
  // 30 lines: the tight fingerprint window (20) would drop the earliest, but the
  // wider prompt window (40) keeps all 30 so the model sees more task context.
  const vp = Array.from({ length: 30 }, (_, i) => `line${i}`).join("\n");
  const ctx = buildContext(snap({ agentState: "working" }, vp), undefined, cfg);
  assert.match(ctx.viewportTail, /line0\b/); // earliest line retained
  assert.match(ctx.viewportTail, /line29\b/); // latest line retained
});

// ---------------------------------------------------------------------------
// pure helpers
// ---------------------------------------------------------------------------

test("lastLines: returns the last n lines, trailing-newline tolerant", () => {
  assert.equal(lastLines("a\nb\nc\nd\n", 2), "c\nd");
  assert.equal(lastLines("a\nb", 5), "a\nb");
  assert.equal(lastLines("", 5), "");
});

test("fnv1a: deterministic and differs by input", () => {
  assert.equal(fnv1a("abc"), fnv1a("abc"));
  assert.notEqual(fnv1a("abc"), fnv1a("abd"));
  assert.match(fnv1a("anything"), /^[0-9a-f]{8}$/);
});

test("coerceBool: covers common forms", () => {
  assert.equal(coerceBool(true), true);
  assert.equal(coerceBool(false), false);
  assert.equal(coerceBool("yes"), true);
  assert.equal(coerceBool("TRUE"), true);
  assert.equal(coerceBool("no"), false);
  assert.equal(coerceBool(1), true);
  assert.equal(coerceBool(0), false);
  assert.equal(coerceBool(null), false);
  assert.equal(coerceBool(undefined), false);
});

test("stripFences: removes json fences", () => {
  assert.equal(stripFences("```json\n{}\n```"), "{}");
  assert.equal(stripFences("```\nx\n```"), "x");
  assert.equal(stripFences("no fences"), "no fences");
});

test("extractFirstJsonObject: balanced braces incl. nested + strings", () => {
  assert.equal(extractFirstJsonObject('{"a":{"b":1}} trailing'), '{"a":{"b":1}}');
  assert.equal(extractFirstJsonObject('{"s":"a}b"}'), '{"s":"a}b"}');
  assert.equal(extractFirstJsonObject("no object"), null);
  assert.equal(extractFirstJsonObject('{"s":"esc \\" }"}'), '{"s":"esc \\" }"}');
});

test("eachJsonObject: yields each top-level balanced object in order", () => {
  assert.deepEqual(
    [...eachJsonObject('{"a":1} junk {"b":2}')],
    ['{"a":1}', '{"b":2}'],
  );
});

test("eachJsonObject: nested objects are NOT yielded separately", () => {
  assert.deepEqual([...eachJsonObject('{"a":{"b":1}}')], ['{"a":{"b":1}}']);
});

test("eachJsonObject: an unclosed final brace yields nothing further", () => {
  assert.deepEqual([...eachJsonObject('{"a":1} {"b":')], ['{"a":1}']);
  assert.deepEqual([...eachJsonObject("no braces")], []);
});

test("eachJsonObject: braces inside strings don't end an object early", () => {
  assert.deepEqual([...eachJsonObject('{"s":"x}y"} {"t":1}')], ['{"s":"x}y"}', '{"t":1}']);
});

test("truncateCodePoints: leaves short strings untouched", () => {
  assert.equal(truncateCodePoints("hello", 10), "hello");
  assert.equal(truncateCodePoints("hello", 5), "hello");
});

test("truncateCodePoints: cuts at a code-point boundary, never mid-surrogate", () => {
  const s = "ab😀cd"; // 5 code points, 6 UTF-16 units (emoji is a pair)
  // Truncate to 3 code points: "ab😀" — the emoji must stay whole.
  const out = truncateCodePoints(s, 3);
  assert.equal(Array.from(out).length, 3);
  assert.equal(out, "ab😀");
  const lastUnit = out.charCodeAt(out.length - 1);
  assert.ok(!(lastUnit >= 0xd800 && lastUnit <= 0xdbff));
});

// ---------------------------------------------------------------------------
// ConcurrencyBudget
// ---------------------------------------------------------------------------

test("ConcurrencyBudget: caps acquisitions and releases", () => {
  const b = new ConcurrencyBudget(2);
  assert.equal(b.tryAcquire(), true);
  assert.equal(b.tryAcquire(), true);
  assert.equal(b.tryAcquire(), false); // cap reached
  assert.equal(b.active, 2);
  b.release();
  assert.equal(b.active, 1);
  assert.equal(b.tryAcquire(), true);
  assert.equal(b.active, 2);
});

test("ConcurrencyBudget: release floors at zero", () => {
  const b = new ConcurrencyBudget(1);
  b.release();
  b.release();
  assert.equal(b.active, 0);
});

// ---------------------------------------------------------------------------
// Attention detection (ramon fork): detectAlert / alertEdge / parseSummary.alert
// ---------------------------------------------------------------------------

test("parseSummary: parses an alert tag (lower-cased + trimmed)", () => {
  const r = parseSummary('{"summary":"Rate limited","alert":" Rate_Limited "}');
  assert.equal(r?.alert, "rate_limited");
});

test("parseSummary: absent alert => undefined", () => {
  const r = parseSummary('{"summary":"Building"}');
  assert.equal(r?.alert, undefined);
});

test("parseSummary: empty/non-string alert => undefined", () => {
  assert.equal(parseSummary('{"summary":"x","alert":""}')?.alert, undefined);
  assert.equal(parseSummary('{"summary":"x","alert":123}')?.alert, undefined);
});

test("alertEdge: none -> tag => ring", () => {
  assert.equal(alertEdge(undefined, "rate_limited"), "ring");
});

test("alertEdge: same tag held => none", () => {
  assert.equal(alertEdge("rate_limited", "rate_limited"), "none");
});

test("alertEdge: changed tag => ring", () => {
  assert.equal(alertEdge("rate_limited", "something_else"), "ring");
});

test("alertEdge: tag -> none => clear", () => {
  assert.equal(alertEdge("rate_limited", undefined), "clear");
});

test("alertEdge: none -> none => none", () => {
  assert.equal(alertEdge(undefined, undefined), "none");
});

// ---------------------------------------------------------------------------
// Bell-attention (ramon fork): parseSummary.attention + bellRoseEdge
// ---------------------------------------------------------------------------

test("parseSummary: parses attention boolean when present", () => {
  assert.equal(parseSummary('{"summary":"x","attention":true}')?.attention, true);
  assert.equal(parseSummary('{"summary":"x","attention":false}')?.attention, false);
  assert.equal(parseSummary('{"summary":"x","attention":"yes"}')?.attention, true);
});

// (bell-attention v2) The STRING "false" must parse to the boolean false — this is the
// single most load-bearing safety value (Haiku realistically emits a stringified bool),
// since `attention === false` is the ONLY thing that suppresses a bell promotion.
test("parseSummary: string \"false\"/\"no\"/\"0\" => false (the only suppressor)", () => {
  assert.equal(parseSummary('{"summary":"x","attention":"false"}')?.attention, false);
  assert.equal(parseSummary('{"summary":"x","attention":"no"}')?.attention, false);
  assert.equal(parseSummary('{"summary":"x","attention":"0"}')?.attention, false);
});

// FAIL-OPEN: an UNRECOGNIZED attention value must NOT suppress — it is omitted
// (undefined) so the loop's `attention !== false` promotes. The lax coerceBool would
// have mapped "maybe" -> false -> SUPPRESS; coerceAttention prevents that regression.
test("parseSummary: unrecognized attention string => omitted (fail-open promote)", () => {
  assert.equal("attention" in (parseSummary('{"summary":"x","attention":"maybe"}') ?? {}), false);
  assert.equal("attention" in (parseSummary('{"summary":"x","attention":"idk"}') ?? {}), false);
});

test("parseSummary: absent attention => undefined (omitted)", () => {
  assert.equal("attention" in (parseSummary('{"summary":"x"}') ?? {}), false);
});

// (bell-attention v2) coerceAttention is strict three-valued: only canonical booleans
// map; uncertainty is undefined (fail-open), NOT false (which would suppress).
test("coerceAttention: canonical true/false; unknown => undefined", () => {
  assert.equal(coerceAttention(true), true);
  assert.equal(coerceAttention(false), false);
  assert.equal(coerceAttention("true"), true);
  assert.equal(coerceAttention("FALSE"), false);
  assert.equal(coerceAttention("yes"), true);
  assert.equal(coerceAttention("no"), false);
  assert.equal(coerceAttention(1), true);
  assert.equal(coerceAttention(0), false);
  assert.equal(coerceAttention("maybe"), undefined);
  assert.equal(coerceAttention(""), undefined);
  assert.equal(coerceAttention(null), undefined);
  assert.equal(coerceAttention({}), undefined);
});

test("bellRoseEdge: false/undefined -> true => rising edge", () => {
  assert.equal(bellRoseEdge(undefined, true), true);
  assert.equal(bellRoseEdge(false, true), true);
});

test("bellRoseEdge: held true (true -> true) => not an edge", () => {
  assert.equal(bellRoseEdge(true, true), false);
});

test("bellRoseEdge: any -> false => not an edge (and re-arms)", () => {
  assert.equal(bellRoseEdge(true, false), false);
  assert.equal(bellRoseEdge(false, false), false);
  assert.equal(bellRoseEdge(undefined, false), false);
});

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
  composePrompt,
  eachJsonObject,
  extractFirstJsonObject,
  fingerprint,
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
  type SurfaceSnapshot,
} from "./summarizer.js";

const cfg = DEFAULT_CONFIG;

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
// fingerprint stability
// ---------------------------------------------------------------------------

test("fingerprint: identical state => identical hash", () => {
  const a = snap({ agentState: "working", lastTool: "Edit" }, "line1\nline2\n");
  const b = snap({ agentState: "working", lastTool: "Edit" }, "line1\nline2\n");
  assert.equal(fingerprint(a, cfg), fingerprint(b, cfg));
});

test("fingerprint: changed lastTool => different hash", () => {
  const a = snap({ agentState: "working", lastTool: "Edit" }, "x");
  const b = snap({ agentState: "working", lastTool: "Bash" }, "x");
  assert.notEqual(fingerprint(a, cfg), fingerprint(b, cfg));
});

test("fingerprint: changed viewport tail => different hash", () => {
  const a = snap({ agentState: "working" }, "old output");
  const b = snap({ agentState: "working" }, "new output");
  assert.notEqual(fingerprint(a, cfg), fingerprint(b, cfg));
});

test("fingerprint: only the last N lines matter", () => {
  const tailN = cfg.fingerprintTailLines;
  const head = Array.from({ length: 50 }, (_, i) => `h${i}`).join("\n");
  const tail = Array.from({ length: tailN }, (_, i) => `t${i}`).join("\n");
  const a = snap({ agentState: "working" }, `${head}\n${tail}`);
  const b = snap({ agentState: "working" }, `DIFFERENT_HEAD\n${tail}`);
  // Different heads beyond the window must NOT change the fingerprint.
  assert.equal(fingerprint(a, cfg), fingerprint(b, cfg));
});

// ---------------------------------------------------------------------------
// shouldSummarize truth table
// ---------------------------------------------------------------------------

test("shouldSummarize: non-agent => skip not-agent", () => {
  const d = shouldSummarize(snap({ processName: "zsh" }), undefined, 0, cfg);
  assert.deepEqual(d, { due: false, reason: "not-agent" });
});

test("shouldSummarize: first time for an agent => due first", () => {
  const d = shouldSummarize(snap({ agentState: "working" }), undefined, 1_000_000, cfg);
  assert.equal(d.due, true);
  assert.equal(d.reason, "first");
});

test("shouldSummarize: within debounce => skip debounce", () => {
  const s = snap({ agentState: "working" }, "x");
  const last: LastSummary = { fingerprint: "deadbeef", atMs: 1000, summary: "old" };
  const d = shouldSummarize(s, last, 1000 + cfg.debounceMs - 1, cfg);
  assert.deepEqual(d, { due: false, reason: "debounce" });
});

test("shouldSummarize: unchanged AND idle past threshold => skip idle-unchanged", () => {
  const s = snap({ agentState: "working", idleSeconds: cfg.idleSkipSeconds + 5 }, "x");
  const fp = fingerprint(s, cfg);
  const last: LastSummary = { fingerprint: fp, atMs: 0, summary: "old" };
  const now = cfg.debounceMs + 1000; // past debounce
  const d = shouldSummarize(s, last, now, cfg);
  assert.deepEqual(d, { due: false, reason: "idle-unchanged" });
});

test("shouldSummarize: changed fingerprint past debounce => due changed", () => {
  const sLast = snap({ agentState: "working", lastTool: "Edit" }, "x");
  const fpOld = fingerprint(sLast, cfg);
  const sNow = snap({ agentState: "working", lastTool: "Bash" }, "x");
  const last: LastSummary = { fingerprint: fpOld, atMs: 0, summary: "old" };
  const d = shouldSummarize(sNow, last, cfg.debounceMs + 1, cfg);
  assert.deepEqual(d, { due: true, reason: "changed" });
});

test("shouldSummarize: unchanged but NOT provably idle (no idleSeconds) => due", () => {
  // idleSeconds omitted => cannot prove idle => re-summarize once debounce passes.
  const s = snap({ agentState: "working" }, "x");
  const fp = fingerprint(s, cfg);
  const last: LastSummary = { fingerprint: fp, atMs: 0, summary: "old" };
  const d = shouldSummarize(s, last, cfg.debounceMs + 1, cfg);
  assert.deepEqual(d, { due: true, reason: "unchanged-not-idle" });
});

test("shouldSummarize: unchanged + idle BELOW threshold => due", () => {
  const s = snap({ agentState: "working", idleSeconds: cfg.idleSkipSeconds - 1 }, "x");
  const fp = fingerprint(s, cfg);
  const last: LastSummary = { fingerprint: fp, atMs: 0, summary: "old" };
  const d = shouldSummarize(s, last, cfg.debounceMs + 1, cfg);
  assert.equal(d.due, true);
});

test("shouldSummarize: debounce wins over a changed fingerprint", () => {
  // Even with a changed fingerprint, within debounce we must skip.
  const sNow = snap({ agentState: "working", lastTool: "Bash" }, "x");
  const last: LastSummary = { fingerprint: "different", atMs: 5000, summary: "old" };
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

test("preGate: agent, no last => candidate", () => {
  assert.deepEqual(
    preGate(makeSurface({ agentState: "working" }), undefined, 0, cfg),
    { pass: true, reason: "candidate" },
  );
});

test("preGate: within debounce => debounce", () => {
  const last: LastSummary = { fingerprint: "x", atMs: 1000, summary: "s" };
  assert.deepEqual(
    preGate(makeSurface({ agentState: "working" }), last, 1000 + cfg.debounceMs - 1, cfg),
    { pass: false, reason: "debounce" },
  );
});

test("preGate: past debounce => candidate (defers idle/fingerprint to full gate)", () => {
  const last: LastSummary = { fingerprint: "x", atMs: 0, summary: "s" };
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

test("parseSummary: absent attention => undefined (omitted)", () => {
  assert.equal("attention" in (parseSummary('{"summary":"x"}') ?? {}), false);
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

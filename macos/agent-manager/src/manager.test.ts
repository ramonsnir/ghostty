// Unit tests for the Phase-2 manager PURE core: goal assembly, the waiting-only +
// debounce + unchanged-skip gate, context serialization, and the tolerant
// suggestion JSON parse. All PURE — no SDK, no MCP. Run via `npm test`.

import test from "node:test";
import assert from "node:assert/strict";

import type { Surface } from "./mcp.js";
import {
  DEFAULT_CONFIDENCE,
  DEFAULT_MANAGER_CONFIG,
  MANAGER_MODEL,
  SUGGESTION_MAX_LEN,
  assembleGoals,
  buildContext,
  clampConfidence,
  composePrompt,
  dismissFingerprint,
  fingerprint,
  parseSuggestion,
  serializeContext,
  shouldSuggest,
  type LastSuggestion,
  type ManagerSnapshot,
} from "./manager.js";
import { MANAGER_BASE_PROMPT } from "./prompts.js";

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

function snap(over: Partial<Surface>, viewport = ""): ManagerSnapshot {
  return { surface: makeSurface(over), viewport };
}

const CFG = DEFAULT_MANAGER_CONFIG;

// --- model id sanity ---------------------------------------------------------

test("MANAGER_MODEL is the Opus id", () => {
  assert.equal(MANAGER_MODEL, "claude-opus-4-8");
});

// --- assembleGoals -----------------------------------------------------------

test("assembleGoals: userNotes lead and are labeled TOP PRIORITY", () => {
  const g = assembleGoals("migrate to postgres", ["fix the bug"]);
  const lines = g.split("\n");
  assert.match(lines[0], /TOP PRIORITY/);
  assert.match(lines[0], /migrate to postgres/);
  assert.match(g, /fix the bug/);
});

test("assembleGoals: empty when nothing present", () => {
  assert.equal(assembleGoals(undefined, []), "");
  assert.equal(assembleGoals("   ", [undefined, "  "]), "");
});

test("assembleGoals: prompts-only (no note) still produced", () => {
  const g = assembleGoals(undefined, ["do the thing"]);
  assert.match(g, /do the thing/);
  assert.doesNotMatch(g, /TOP PRIORITY/);
});

// --- shouldSuggest -----------------------------------------------------------

test("shouldSuggest: only fires for a WAITING agent", () => {
  const goals = "g";
  assert.equal(shouldSuggest(snap({ agentState: "working" }), goals, undefined, 0, CFG).due, false);
  assert.equal(shouldSuggest(snap({ agentState: "idle" }), goals, undefined, 0, CFG).due, false);
  assert.equal(shouldSuggest(snap({ agentState: undefined }), goals, undefined, 0, CFG).due, false);
  const d = shouldSuggest(snap({ agentState: "waiting" }), goals, undefined, 0, CFG);
  assert.equal(d.due, true);
  assert.equal(d.reason, "first");
});

test("shouldSuggest: exited never fires", () => {
  const d = shouldSuggest(snap({ agentState: "waiting", exited: true }), "g", undefined, 0, CFG);
  assert.equal(d.due, false);
  assert.equal(d.reason, "exited");
});

test("shouldSuggest: debounces within debounceMs of the last call", () => {
  const last = { fingerprint: "x", atMs: 1000, suggestion: "y" };
  const d = shouldSuggest(snap({ agentState: "waiting" }), "g", last, 1000 + CFG.debounceMs - 1, CFG);
  assert.equal(d.due, false);
  assert.equal(d.reason, "debounce");
});

test("shouldSuggest: skips an unchanged screen past debounce", () => {
  const s = snap({ agentState: "waiting" }, "the same screen");
  const goals = "g";
  const fp = fingerprint(s, goals, CFG);
  const last = { fingerprint: fp, atMs: 0, suggestion: "prev" };
  const d = shouldSuggest(s, goals, last, CFG.debounceMs + 1, CFG);
  assert.equal(d.due, false);
  assert.equal(d.reason, "unchanged");
});

test("shouldSuggest: a changed screen past debounce re-fires", () => {
  const goals = "g";
  const last = { fingerprint: "stale-fp", atMs: 0, suggestion: "prev" };
  const d = shouldSuggest(snap({ agentState: "waiting" }, "new screen"), goals, last, CFG.debounceMs + 1, CFG);
  assert.equal(d.due, true);
  assert.equal(d.reason, "changed");
});

// --- shouldSuggest: dismiss-suppression (Phase 2.1) --------------------------

test("shouldSuggest: dismissed + suppression NOT armed => arms it, skips", () => {
  const s = snap({ agentState: "waiting", suggestionDismissed: true }, "blocked screen");
  // A prior record whose manager fingerprint differs from the current one (so the
  // coarse 'unchanged' gate does NOT short-circuit), with no arm yet.
  const last: LastSuggestion = {
    fingerprint: "stale-mgr-fp",
    atMs: 0,
    suggestion: "prev",
    suppressedFingerprint: null,
  };
  const d = shouldSuggest(s, "g", last, CFG.debounceMs + 1, CFG);
  assert.equal(d.due, false);
  assert.equal(d.reason, "dismissed-arm");
  // It arms to the CURRENT summarizer fingerprint (the dismissed screen), so the
  // subsequent dismissed-unchanged compare lives in the same space.
  assert.equal(d.suppressedFingerprint, dismissFingerprint(s));
});

test("shouldSuggest: dismissed arms EVEN when the manager fingerprint is UNCHANGED", () => {
  // The load-bearing regression case: in the NORMAL waiting flow the screen + goals
  // are stable across the dismiss sweep, so the manager `unchanged` gate WOULD match
  // (fp === last.fingerprint). Dismiss-suppression must still arm at dismiss time —
  // it is evaluated BEFORE the `unchanged` gate for a dismissed surface.
  const goals = "g";
  const s = snap({ agentState: "waiting", suggestionDismissed: true }, "the blocking screen");
  const last: LastSuggestion = {
    fingerprint: fingerprint(s, goals, CFG), // EXACTLY the current manager fp (stable)
    atMs: 0,
    suggestion: "prev",
    suppressedFingerprint: null,
  };
  const d = shouldSuggest(s, goals, last, CFG.debounceMs + 1, CFG);
  assert.equal(d.due, false);
  assert.equal(d.reason, "dismissed-arm", "arms despite the unchanged manager fp");
  assert.equal(d.suppressedFingerprint, dismissFingerprint(s));
});

test("shouldSuggest: dismissed + ONE summarizer change after arming => suggest (single change)", () => {
  // After arming at screen A, the FIRST meaningful (summarizer) change re-suggests —
  // a SINGLE change, not two. Manager fp is held stable to prove the decision is
  // driven purely by the summarizer-space compare.
  const goals = "g";
  const sArmed = snap({ agentState: "waiting", suggestionDismissed: true }, "screen A");
  const armed = dismissFingerprint(sArmed);
  const sChanged = snap({ agentState: "waiting", suggestionDismissed: true }, "screen B");
  const last: LastSuggestion = {
    fingerprint: fingerprint(sChanged, goals, CFG), // stable manager fp (unchanged gate would match)
    atMs: 0,
    suggestion: "prev",
    suppressedFingerprint: armed,
  };
  const d = shouldSuggest(sChanged, goals, last, CFG.debounceMs + 1, CFG);
  assert.equal(d.due, true);
  assert.equal(d.reason, "dismissed-changed");
  assert.equal(d.suppressedFingerprint, null);
});

test("shouldSuggest: (a) dismissed + UNCHANGED vs the arm => skip", () => {
  const s = snap({ agentState: "waiting", suggestionDismissed: true }, "blocked screen");
  const armed = dismissFingerprint(s);
  const last: LastSuggestion = {
    fingerprint: "stale-mgr-fp", // differs from current so we reach the suppression block
    atMs: 0,
    suggestion: "prev",
    suppressedFingerprint: armed,
  };
  const d = shouldSuggest(s, "g", last, CFG.debounceMs + 1, CFG);
  assert.equal(d.due, false);
  assert.equal(d.reason, "dismissed-unchanged");
});

test("shouldSuggest: (b) dismissed + CHANGED vs the arm => suggest AND clear", () => {
  const s = snap({ agentState: "waiting", suggestionDismissed: true }, "a NEW screen entirely");
  const last: LastSuggestion = {
    fingerprint: "stale-mgr-fp",
    atMs: 0,
    suggestion: "prev",
    suppressedFingerprint: "an-old-arm-from-a-different-screen",
  };
  const d = shouldSuggest(s, "g", last, CFG.debounceMs + 1, CFG);
  assert.equal(d.due, true);
  assert.equal(d.reason, "dismissed-changed");
  assert.equal(d.suppressedFingerprint, null); // cleared
});

test("shouldSuggest: (c) NOT dismissed behaves as before (+ clears stale arm)", () => {
  // Even if a stale arm lingers, a not-dismissed waiting surface suggests as usual.
  const s = snap({ agentState: "waiting", suggestionDismissed: false }, "changed screen");
  const last: LastSuggestion = {
    fingerprint: "stale-mgr-fp",
    atMs: 0,
    suggestion: "prev",
    suppressedFingerprint: "lingering-arm",
  };
  const d = shouldSuggest(s, "g", last, CFG.debounceMs + 1, CFG);
  assert.equal(d.due, true);
  assert.equal(d.reason, "changed");
  assert.equal(d.suppressedFingerprint, null);
});

test("shouldSuggest: dismissed=undefined (pre-upgrade host) reads as not-dismissed", () => {
  const s = snap({ agentState: "waiting" }, "scr"); // suggestionDismissed omitted
  const d = shouldSuggest(s, "g", undefined, 0, CFG);
  assert.equal(d.due, true);
  assert.equal(d.reason, "first");
});

test("dismissFingerprint: uses the summarizer's fields (agentState/prompt/tool/tail)", () => {
  const base = snap({ agentState: "waiting", lastPrompt: "p", lastTool: "Bash" }, "tail");
  const changedTool = snap(
    { agentState: "waiting", lastPrompt: "p", lastTool: "Edit" }, "tail");
  const changedTail = snap(
    { agentState: "waiting", lastPrompt: "p", lastTool: "Bash" }, "different tail");
  assert.notEqual(dismissFingerprint(base), dismissFingerprint(changedTool));
  assert.notEqual(dismissFingerprint(base), dismissFingerprint(changedTail));
});

test("fingerprint: changes when goals or screen change", () => {
  const a = fingerprint(snap({ agentState: "waiting" }, "screen-1"), "goal-1", CFG);
  const b = fingerprint(snap({ agentState: "waiting" }, "screen-2"), "goal-1", CFG);
  const c = fingerprint(snap({ agentState: "waiting" }, "screen-1"), "goal-2", CFG);
  assert.notEqual(a, b);
  assert.notEqual(a, c);
});

// --- context serialization ---------------------------------------------------

test("buildContext + serializeContext: goals lead, screen included", () => {
  const s = snap(
    { agentState: "waiting", title: "t", pwd: "/p", userNotes: "use postgres" },
    "Which DB? (postgres/mysql)",
  );
  const goals = assembleGoals(s.surface.userNotes, [s.surface.lastPrompt]);
  const ctx = buildContext(s, goals, "earlier suggestion", CFG);
  const user = serializeContext(ctx);
  assert.match(user, /SESSION GOALS/);
  assert.match(user, /use postgres/);
  assert.match(user, /Which DB\?/);
  assert.match(user, /earlier suggestion/);
});

test("serializeContext: no goals => conservative placeholder", () => {
  const ctx = buildContext(snap({ agentState: "waiting" }, "screen"), "", undefined, CFG);
  const user = serializeContext(ctx);
  assert.match(user, /no explicit goals captured/);
});

test("composePrompt: system is the manager base (+ override), user is the context", () => {
  const ctx = buildContext(snap({ agentState: "waiting" }, "scr"), "g", undefined, CFG);
  const { system, user } = composePrompt(MANAGER_BASE_PROMPT, null, ctx);
  assert.match(system, /Agent Manager/);
  assert.match(system, /"suggestion"/); // the output contract is in the base
  assert.match(system, /"confidence"/); // (Phase 2.1) confidence is required
  assert.match(user, /SESSION GOALS/);
  const withOverride = composePrompt(MANAGER_BASE_PROMPT, "Be brief.", ctx);
  assert.match(withOverride.system, /Be brief\./);
});

// --- parseSuggestion ---------------------------------------------------------

test("parseSuggestion: plain object", () => {
  const p = parseSuggestion('{"suggestion":"use postgres","rationale":"the note says so"}');
  assert.equal(p?.suggestion, "use postgres");
  assert.equal(p?.rationale, "the note says so");
});

test("parseSuggestion: suggestion-only (no rationale) defaults confidence", () => {
  const p = parseSuggestion('{"suggestion":"yes, option 2"}');
  assert.equal(p?.suggestion, "yes, option 2");
  assert.equal(p?.rationale, undefined);
  // confidence is ALWAYS populated; absent => DEFAULT_CONFIDENCE.
  assert.equal(p?.confidence, DEFAULT_CONFIDENCE);
});

// --- parseSuggestion: ABSTAIN primitive -------------------------------------
// An empty / blank / missing / non-string suggestion is the manager's ABSTAIN signal:
// parseSuggestion returns null, and the loop (manageOne) then writes NOTHING — the tile
// shows only the summary. This is the PURE behavior the loop-level abstain test builds on.

test("parseSuggestion: empty-string suggestion => null (ABSTAIN)", () => {
  assert.equal(parseSuggestion('{"suggestion":"","confidence":0}'), null);
});

test("parseSuggestion: whitespace-only suggestion => null (ABSTAIN)", () => {
  assert.equal(parseSuggestion('{"suggestion":"   \\n\\t ","confidence":0}'), null);
});

test("parseSuggestion: missing suggestion field => null (ABSTAIN)", () => {
  assert.equal(parseSuggestion('{"confidence":0.9}'), null);
});

test("parseSuggestion: non-string suggestion => null (ABSTAIN)", () => {
  assert.equal(parseSuggestion('{"suggestion":42,"confidence":0.9}'), null);
});

test("parseSuggestion: garbage / non-JSON => null (ABSTAIN)", () => {
  assert.equal(parseSuggestion("sure, I'll do that"), null);
  assert.equal(parseSuggestion(""), null);
});

// --- parseSuggestion: confidence parse + clamp (Phase 2.1) -------------------

test("parseSuggestion: parses a valid confidence", () => {
  const p = parseSuggestion('{"suggestion":"use postgres","confidence":0.8}');
  assert.equal(p?.confidence, 0.8);
});

test("parseSuggestion: clamps confidence above 1 to 1", () => {
  const p = parseSuggestion('{"suggestion":"go","confidence":1.7}');
  assert.equal(p?.confidence, 1);
});

test("parseSuggestion: clamps confidence below 0 to 0", () => {
  const p = parseSuggestion('{"suggestion":"go","confidence":-0.4}');
  assert.equal(p?.confidence, 0);
});

test("parseSuggestion: non-number / NaN confidence => default", () => {
  assert.equal(parseSuggestion('{"suggestion":"go","confidence":"high"}')?.confidence, DEFAULT_CONFIDENCE);
  assert.equal(parseSuggestion('{"suggestion":"go","confidence":null}')?.confidence, DEFAULT_CONFIDENCE);
  // NaN is not representable in JSON; clampConfidence guards it directly.
  assert.equal(clampConfidence(Number.NaN), DEFAULT_CONFIDENCE);
  assert.equal(clampConfidence(Number.POSITIVE_INFINITY), DEFAULT_CONFIDENCE);
});

test("clampConfidence: boundary + valid values", () => {
  assert.equal(clampConfidence(0), 0);
  assert.equal(clampConfidence(1), 1);
  assert.equal(clampConfidence(0.42), 0.42);
  assert.equal(clampConfidence(undefined), DEFAULT_CONFIDENCE);
});

test("parseSuggestion: strips code fences", () => {
  const p = parseSuggestion('```json\n{"suggestion":"go ahead"}\n```');
  assert.equal(p?.suggestion, "go ahead");
});

test("parseSuggestion: tolerates a preamble object then the answer", () => {
  const p = parseSuggestion('{"thinking":"the user wants X"} then: {"suggestion":"do X"}');
  assert.equal(p?.suggestion, "do X");
});

test("parseSuggestion: trims the suggestion", () => {
  const p = parseSuggestion('{"suggestion":"  spaced reply  "}');
  assert.equal(p?.suggestion, "spaced reply");
});

test("parseSuggestion: empty/blank suggestion => null", () => {
  assert.equal(parseSuggestion('{"suggestion":""}'), null);
  assert.equal(parseSuggestion('{"suggestion":"   "}'), null);
});

test("parseSuggestion: no suggestion field => null", () => {
  assert.equal(parseSuggestion('{"rationale":"why"}'), null);
  assert.equal(parseSuggestion("not json at all"), null);
});

test("parseSuggestion: truncates an overlong suggestion by code point", () => {
  const long = "x".repeat(SUGGESTION_MAX_LEN + 50);
  const p = parseSuggestion(JSON.stringify({ suggestion: long }));
  assert.equal(p?.suggestion.length, SUGGESTION_MAX_LEN);
});

test("parseSuggestion: ignores a non-string rationale", () => {
  const p = parseSuggestion('{"suggestion":"go","rationale":7}');
  assert.equal(p?.suggestion, "go");
  assert.equal(p?.rationale, undefined);
});

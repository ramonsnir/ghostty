// Unit tests for the Phase-2 manager PURE core: goal assembly, the waiting-only +
// debounce + unchanged-skip gate, context serialization, and the tolerant
// suggestion JSON parse. All PURE — no SDK, no MCP. Run via `npm test`.

import test from "node:test";
import assert from "node:assert/strict";

import type { Surface } from "./mcp.js";
import {
  DEFAULT_MANAGER_CONFIG,
  MANAGER_MODEL,
  SUGGESTION_MAX_LEN,
  assembleGoals,
  buildContext,
  composePrompt,
  fingerprint,
  parseSuggestion,
  serializeContext,
  shouldSuggest,
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

test("parseSuggestion: suggestion-only (no rationale)", () => {
  const p = parseSuggestion('{"suggestion":"yes, option 2"}');
  assert.equal(p?.suggestion, "yes, option 2");
  assert.equal(p?.rationale, undefined);
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

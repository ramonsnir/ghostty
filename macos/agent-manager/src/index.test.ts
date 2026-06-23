// Orchestration tests for the loop's runSweep/summarizeOne wiring. These verify
// the load-bearing behaviors the pure gate tests can't: that the loop HONORS the
// gate (an unchanged idle session is never summarized end-to-end), per-surface
// error isolation, budget acquire/release pairing, dead-session record cleanup,
// and that a listSurfaces failure just skips the sweep. The model call + MCP
// client + overrides loader are all injected via LoopDeps. Run via `npm test`.

import test from "node:test";
import assert from "node:assert/strict";

import { runSweep, type LoopDeps, type SummarizeFn, type SuggestFn } from "./index.js";
import type { McpClient, Surface, SurfaceScreen, Annotation } from "./mcp.js";
import {
  DEFAULT_CONFIG,
  ConcurrencyBudget,
  fingerprint,
  type LastSummary,
  type SurfaceSnapshot,
} from "./summarizer.js";
import {
  DEFAULT_MANAGER_CONFIG,
  MANAGER_MODEL,
  type LastSuggestion,
} from "./manager.js";
import { makeOverrideLoader, type OverrideFs } from "./prompt.js";

// An OverrideFs that always reports "no override file" (returns null).
const noOverrideFs: OverrideFs = {
  statMtimeMs: () => null,
  readText: () => null,
};

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

interface FakeClientSpec {
  surfaces: Surface[];
  /** id -> viewport text returned by readSurface. */
  screens?: Record<string, string>;
  /** ids that should throw from readSurface. */
  readThrows?: Set<string>;
  /** when true, listSurfaces throws. */
  listThrows?: boolean;
}

interface FakeClient {
  client: McpClient;
  setCalls: Array<{ id: string; ann: Annotation }>;
  readCalls: string[];
}

/** Build a structurally-typed fake McpClient (cast to the class — runSweep only
 *  ever calls listSurfaces/readSurface/setAnnotation). */
function makeFakeClient(spec: FakeClientSpec): FakeClient {
  const setCalls: Array<{ id: string; ann: Annotation }> = [];
  const readCalls: string[] = [];
  const client = {
    async listSurfaces(): Promise<Surface[]> {
      if (spec.listThrows) throw new Error("list boom");
      return spec.surfaces;
    },
    async readSurface(id: string): Promise<SurfaceScreen> {
      readCalls.push(id);
      if (spec.readThrows?.has(id)) throw new Error(`read boom ${id}`);
      return { text: spec.screens?.[id] ?? "", cols: 80, rows: 24 };
    },
    async setAnnotation(id: string, ann: Annotation): Promise<void> {
      setCalls.push({ id, ann });
    },
  } as unknown as McpClient;
  return { client, setCalls, readCalls };
}

interface DepsSpec {
  fake: FakeClient;
  summarize: SummarizeFn;
  now?: number;
  last?: Map<string, LastSummary>;
  budgetMax?: number;
  managerBudgetMax?: number;
  /** Phase 2: optional manager call seam + its per-session memory. Defaults to a
   *  stub that throws (so a stray manager fire is loud), and an empty map. The
   *  summarizer tests use `agentState:"working"` surfaces, so the manager pass —
   *  which only fires on `waiting` — never reaches the stub there. */
  suggest?: SuggestFn;
  lastSuggestion?: Map<string, LastSuggestion>;
}

function makeDeps(spec: DepsSpec): {
  deps: LoopDeps;
  summarizeCalls: Array<{ system: string; user: string }>;
  suggestCalls: Array<{ system: string; user: string; model: string }>;
} {
  const summarizeCalls: Array<{ system: string; user: string }> = [];
  const summarize: SummarizeFn = async (req) => {
    summarizeCalls.push(req);
    return spec.summarize(req);
  };
  const suggestCalls: Array<{ system: string; user: string; model: string }> = [];
  const suggest: SuggestFn = async (req) => {
    suggestCalls.push(req);
    if (!spec.suggest) throw new Error("unexpected manager call (no suggest stub)");
    return spec.suggest(req);
  };
  const cfg = { ...DEFAULT_CONFIG, maxConcurrent: spec.budgetMax ?? DEFAULT_CONFIG.maxConcurrent };
  const deps: LoopDeps = {
    client: spec.fake.client,
    overrides: makeOverrideLoader("/home/test", noOverrideFs),
    cfg,
    budget: new ConcurrencyBudget(cfg.maxConcurrent),
    now: () => spec.now ?? 1_000_000,
    summarize,
    lastBySession: spec.last ?? new Map<string, LastSummary>(),
    managerOverrides: makeOverrideLoader("/home/test", noOverrideFs),
    managerCfg: { ...DEFAULT_MANAGER_CONFIG },
    managerModel: MANAGER_MODEL,
    suggest,
    lastSuggestionBySession: spec.lastSuggestion ?? new Map<string, LastSuggestion>(),
    managerBudget: new ConcurrencyBudget(
      spec.managerBudgetMax ?? DEFAULT_MANAGER_CONFIG.maxConcurrent,
    ),
  };
  return { deps, summarizeCalls, suggestCalls };
}

const okSummary: SummarizeFn = async () => '{"summary":"Doing the thing","phase":"build"}';

// ---------------------------------------------------------------------------
// Happy path: one agent surface => exactly one annotation + recorded LastSummary
// ---------------------------------------------------------------------------

test("runSweep: a due agent surface produces exactly one annotation + records LastSummary", async () => {
  const fake = makeFakeClient({
    surfaces: [makeSurface({ id: "s1", agentState: "working" })],
    screens: { s1: "line a\nline b" },
  });
  const { deps, summarizeCalls } = makeDeps({ fake, summarize: okSummary });

  await runSweep(deps);

  assert.equal(summarizeCalls.length, 1);
  assert.equal(fake.setCalls.length, 1);
  assert.deepEqual(fake.setCalls[0], {
    id: "s1",
    ann: { summary: "Doing the thing", phase: "build", needsUser: undefined },
  });
  const rec = deps.lastBySession.get("s1");
  assert.ok(rec);
  assert.equal(rec!.summary, "Doing the thing");
  assert.equal(deps.budget.active, 0); // slot released
});

// ---------------------------------------------------------------------------
// THE A+ GATE: an unchanged idle session is NOT summarized end-to-end
// ---------------------------------------------------------------------------

test("runSweep: unchanged + idle session is NOT summarized (gate honored, budget released)", async () => {
  const viewport = "stable\noutput";
  const surface = makeSurface({
    id: "s1",
    agentState: "working",
    idleSeconds: DEFAULT_CONFIG.idleSkipSeconds + 10, // provably idle
  });
  const snapshot: SurfaceSnapshot = { surface, viewport };
  const fp = fingerprint(snapshot, DEFAULT_CONFIG);

  const last = new Map<string, LastSummary>([
    ["s1", { fingerprint: fp, atMs: 0, summary: "old" }],
  ]);
  const fake = makeFakeClient({ surfaces: [surface], screens: { s1: viewport } });
  // now is well past debounce so only the idle-unchanged rule can apply.
  const { deps, summarizeCalls } = makeDeps({
    fake,
    summarize: okSummary,
    now: DEFAULT_CONFIG.debounceMs + 100_000,
    last,
  });

  await runSweep(deps);

  assert.equal(summarizeCalls.length, 0, "summarize must NOT be called");
  assert.equal(fake.setCalls.length, 0, "no annotation written");
  assert.equal(fake.readCalls.length, 1, "read happens (full gate needs the viewport)");
  assert.equal(deps.budget.active, 0, "budget slot released even on a skip");
});

test("runSweep: a CHANGED fingerprint past debounce IS summarized exactly once", async () => {
  const surface = makeSurface({
    id: "s1",
    agentState: "working",
    idleSeconds: 999,
    lastTool: "Bash",
  });
  // Seed a record whose fingerprint differs from the current snapshot.
  const last = new Map<string, LastSummary>([
    ["s1", { fingerprint: "stale0000", atMs: 0, summary: "old" }],
  ]);
  const fake = makeFakeClient({ surfaces: [surface], screens: { s1: "new output" } });
  const { deps, summarizeCalls } = makeDeps({
    fake,
    summarize: okSummary,
    now: DEFAULT_CONFIG.debounceMs + 100_000,
    last,
  });

  await runSweep(deps);

  assert.equal(summarizeCalls.length, 1);
  assert.equal(fake.setCalls.length, 1);
});

// ---------------------------------------------------------------------------
// Per-surface error isolation
// ---------------------------------------------------------------------------

test("runSweep: a readSurface error is swallowed; other surfaces still processed; budget released", async () => {
  const fake = makeFakeClient({
    surfaces: [
      makeSurface({ id: "bad", agentState: "working" }),
      makeSurface({ id: "good", agentState: "working" }),
    ],
    screens: { good: "ok" },
    readThrows: new Set(["bad"]),
  });
  const { deps, summarizeCalls } = makeDeps({ fake, summarize: okSummary });

  await runSweep(deps); // must not throw

  // "good" still summarized; "bad" produced no annotation.
  assert.equal(summarizeCalls.length, 1);
  assert.deepEqual(
    fake.setCalls.map((c) => c.id),
    ["good"],
  );
  assert.equal(deps.budget.active, 0, "both slots released (finally on each)");
});

test("runSweep: a model error is swallowed, writes no annotation, but stamps the debounce clock", async () => {
  const fake = makeFakeClient({
    surfaces: [makeSurface({ id: "s1", agentState: "working" })],
    screens: { s1: "x" },
  });
  const failing: SummarizeFn = async () => {
    throw new Error("model down");
  };
  const { deps } = makeDeps({ fake, summarize: failing, now: 1_000_000 });

  await runSweep(deps); // must not throw

  assert.equal(fake.setCalls.length, 0);
  // A failed attempt SPENT a model call, so it must throttle the retry: a record
  // exists with atMs=now but NO real summary written (annotation count stayed 0).
  const rec = deps.lastBySession.get("s1");
  assert.ok(rec, "a failed attempt records the debounce clock");
  assert.equal(rec.atMs, 1_000_000, "atMs stamped to now() on failure");
  assert.equal(deps.budget.active, 0);
});

test("runSweep: an unparseable model reply writes no annotation but stamps the debounce clock", async () => {
  const fake = makeFakeClient({
    surfaces: [makeSurface({ id: "s1", agentState: "working" })],
    screens: { s1: "x" },
  });
  const junk: SummarizeFn = async () => "not json at all";
  const { deps } = makeDeps({ fake, summarize: junk, now: 1_000_000 });

  await runSweep(deps);

  assert.equal(fake.setCalls.length, 0);
  const rec = deps.lastBySession.get("s1");
  assert.ok(rec, "an unparseable reply records the debounce clock");
  assert.equal(rec.atMs, 1_000_000, "atMs stamped to now() on parse failure");
  assert.equal(deps.budget.active, 0);
});

// ---------------------------------------------------------------------------
// Cost-leak guard: a FAILING/UNPARSEABLE attempt debounces the NEXT attempt, so a
// stuck session cannot spend one Haiku call per poll (no per-poll retry storm).
// ---------------------------------------------------------------------------

test("runSweep: a failing surface is debounced — two sweeps within debounceMs = ONE attempt", async () => {
  const fake = makeFakeClient({
    surfaces: [makeSurface({ id: "s1", agentState: "working" })],
    screens: { s1: "x" },
  });
  const failing: SummarizeFn = async () => {
    throw new Error("model down");
  };
  // Constant clock (now() === 1_000_000 every call) ⇒ the second sweep is strictly
  // within debounceMs of the first attempt's stamp.
  const { deps, summarizeCalls } = makeDeps({ fake, summarize: failing, now: 1_000_000 });

  await runSweep(deps);
  await runSweep(deps);

  assert.equal(summarizeCalls.length, 1, "second sweep is debounced — no retry storm");
  assert.equal(fake.setCalls.length, 0);
});

test("runSweep: an unparseable surface is debounced — two sweeps within debounceMs = ONE attempt", async () => {
  const fake = makeFakeClient({
    surfaces: [makeSurface({ id: "s1", agentState: "working" })],
    screens: { s1: "x" },
  });
  const junk: SummarizeFn = async () => "still not json";
  const { deps, summarizeCalls } = makeDeps({ fake, summarize: junk, now: 1_000_000 });

  await runSweep(deps);
  await runSweep(deps);

  assert.equal(summarizeCalls.length, 1, "second sweep is debounced — no retry storm");
  assert.equal(fake.setCalls.length, 0);
});

// ---------------------------------------------------------------------------
// listSurfaces failure just skips the sweep
// ---------------------------------------------------------------------------

test("runSweep: listSurfaces failure skips the sweep without throwing", async () => {
  const fake = makeFakeClient({ surfaces: [], listThrows: true });
  const { deps, summarizeCalls } = makeDeps({ fake, summarize: okSummary });

  await runSweep(deps); // must not throw

  assert.equal(summarizeCalls.length, 0);
  assert.equal(fake.setCalls.length, 0);
});

// ---------------------------------------------------------------------------
// Dead-session cleanup
// ---------------------------------------------------------------------------

test("runSweep: a vanished surface's record is dropped across sweeps", async () => {
  const last = new Map<string, LastSummary>([
    ["gone", { fingerprint: "x", atMs: 0, summary: "old" }],
    ["s1", { fingerprint: "y", atMs: 0, summary: "old" }],
  ]);
  // Only s1 is still live; "gone" should be pruned.
  const fake = makeFakeClient({
    surfaces: [makeSurface({ id: "s1", processName: "zsh" })], // non-agent => no work
  });
  const { deps } = makeDeps({ fake, summarize: okSummary, last });

  await runSweep(deps);

  assert.equal(deps.lastBySession.has("gone"), false, "dead session pruned");
  assert.equal(deps.lastBySession.has("s1"), true, "live session retained");
});

// ---------------------------------------------------------------------------
// Concurrency budget caps in-flight summarize() calls when > maxConcurrent due
// ---------------------------------------------------------------------------

test("runSweep: budget caps concurrent summaries to maxConcurrent per sweep", async () => {
  const surfaces = [1, 2, 3, 4].map((n) =>
    makeSurface({ id: `s${n}`, agentState: "working" }),
  );
  const screens: Record<string, string> = { s1: "a", s2: "b", s3: "c", s4: "d" };
  const fake = makeFakeClient({ surfaces, screens });

  // A summarize that blocks until released, so we can observe peak concurrency.
  let inFlight = 0;
  let peak = 0;
  const gate: Array<() => void> = [];
  const blocking: SummarizeFn = (req) =>
    new Promise<string>((resolve) => {
      inFlight++;
      peak = Math.max(peak, inFlight);
      gate.push(() => {
        inFlight--;
        resolve('{"summary":"ok"}');
      });
    });

  const { deps } = makeDeps({ fake, summarize: blocking, budgetMax: 2 });

  const sweep = runSweep(deps);
  // Let the synchronous fan-out + the two reads settle, then release all.
  await new Promise((r) => setTimeout(r, 10));
  assert.equal(peak, 2, "no more than maxConcurrent in flight at once");
  for (const release of gate) release();
  await sweep;

  // Only 2 of the 4 surfaces are summarized in this single sweep (batch cap).
  assert.equal(fake.setCalls.length, 2);
  assert.equal(deps.budget.active, 0, "all slots released after the sweep");
});

// ---------------------------------------------------------------------------
// Phase 2 manager pass (ramon fork / Agent Manager)
// ---------------------------------------------------------------------------

const okSuggestion: SuggestFn = async () =>
  '{"suggestion":"use postgres","confidence":0.9,"rationale":"the note says migrate to postgres"}';

test("runSweep: a WAITING agent gets BOTH a summary and a merged suggestion", async () => {
  const fake = makeFakeClient({
    surfaces: [makeSurface({ id: "s1", agentState: "waiting", userNotes: "migrate to postgres" })],
    screens: { s1: "Which database should I migrate to? (postgres/mysql)" },
  });
  const { deps, suggestCalls } = makeDeps({
    fake,
    summarize: okSummary,
    suggest: okSuggestion,
  });

  await runSweep(deps);

  // Two annotation writes: the summary (summarizer) and the suggestion (manager).
  const summaryWrite = fake.setCalls.find((c) => c.ann.summary !== undefined);
  const suggestionWrite = fake.setCalls.find((c) => c.ann.suggestion !== undefined);
  assert.ok(summaryWrite, "summarizer wrote a summary");
  assert.ok(suggestionWrite, "manager wrote a suggestion");
  // The manager write is a PARTIAL merge: ONLY the suggestion (no summary field).
  assert.equal(suggestionWrite!.ann.summary, undefined);
  assert.equal(suggestionWrite!.ann.suggestion, "use postgres");
  // (Phase 2.1) The merge carries the parsed confidence.
  assert.equal(suggestionWrite!.ann.confidence, 0.9);
  // The manager was called with the Opus model + the goals in the prompt.
  assert.equal(suggestCalls.length, 1);
  assert.equal(suggestCalls[0].model, MANAGER_MODEL);
  assert.match(suggestCalls[0].user, /migrate to postgres/);
  // And its memory was recorded.
  assert.equal(deps.lastSuggestionBySession.get("s1")?.suggestion, "use postgres");
});

test("runSweep: the manager is NOT starved when the summarizer budget is exhausted", async () => {
  // Regression: the manager used to SHARE the summarizer's budget and run second,
  // so with >= summarizer-cap due summaries every sweep it got zero slots and never
  // proposed. With its OWN budget it still fires for the waiting surface.
  const fake = makeFakeClient({
    surfaces: [
      makeSurface({ id: "a1", agentState: "working" }),
      makeSurface({ id: "a2", agentState: "working" }),
      makeSurface({ id: "w1", agentState: "waiting", userNotes: "ship it" }),
    ],
    screens: { a1: "x", a2: "y", w1: "Proceed? (y/n)" },
  });
  // Summarizer cap = 2 → a1+a2 exhaust it this sweep; w1 gets no SUMMARIZER slot.
  const { deps, suggestCalls } = makeDeps({
    fake,
    summarize: okSummary,
    suggest: okSuggestion,
    budgetMax: 2,
  });

  await runSweep(deps);

  // The manager still proposed for the waiting surface (own budget, not starved).
  assert.equal(suggestCalls.length, 1, "manager fired despite summarizer budget exhaustion");
  assert.ok(
    fake.setCalls.find((c) => c.id === "w1" && c.ann.suggestion === "use postgres"),
    "the waiting surface got its suggestion",
  );
  assert.equal(deps.budget.active, 0, "summarizer budget released");
  assert.equal(deps.managerBudget.active, 0, "manager budget released");
});

test("runSweep: a LOW-confidence suggestion is SUPPRESSED (not written)", async () => {
  // Quality gate: filler the model rated below suppressBelow is treated as abstain —
  // nothing is written to the tile (shows the summary only).
  const fake = makeFakeClient({
    surfaces: [makeSurface({ id: "s1", agentState: "waiting" })],
    screens: { s1: "All done — anything else?" },
  });
  const lowConf: SuggestFn = async () =>
    '{"suggestion":"Sounds good, I will continue.","confidence":0.2}';
  const { deps, suggestCalls } = makeDeps({ fake, summarize: okSummary, suggest: lowConf });

  await runSweep(deps);

  assert.equal(suggestCalls.length, 1, "manager was consulted");
  assert.equal(
    fake.setCalls.find((c) => c.ann.suggestion !== undefined),
    undefined,
    "no suggestion written (suppressed below the confidence floor)",
  );
  // The attempt is still recorded (debounce) so it doesn't re-fire every poll.
  assert.ok(deps.lastSuggestionBySession.get("s1"), "suppressed attempt is debounced");
});

test("runSweep: an ABSTAIN (empty suggestion) writes nothing", async () => {
  const fake = makeFakeClient({
    surfaces: [makeSurface({ id: "s1", agentState: "waiting" })],
    screens: { s1: "Task finished." },
  });
  const abstain: SuggestFn = async () => '{"suggestion":"","confidence":0}';
  const { deps } = makeDeps({ fake, summarize: okSummary, suggest: abstain });

  await runSweep(deps);

  assert.equal(
    fake.setCalls.find((c) => c.ann.suggestion !== undefined),
    undefined,
    "abstain → no suggestion written",
  );
});

test("runSweep: a WORKING agent never triggers the manager pass", async () => {
  const fake = makeFakeClient({
    surfaces: [makeSurface({ id: "s1", agentState: "working" })],
    screens: { s1: "doing work" },
  });
  // No suggest stub: a stray manager fire would throw "unexpected manager call".
  const { deps, suggestCalls } = makeDeps({ fake, summarize: okSummary });
  await runSweep(deps);
  assert.equal(suggestCalls.length, 0, "manager skipped a non-waiting agent");
  // Only the summary was written.
  assert.ok(fake.setCalls.every((c) => c.ann.suggestion === undefined));
});

test("runSweep: manager debounces a waiting agent (no second suggestion within debounceMs)", async () => {
  const last = new Map<string, LastSuggestion>([
    ["s1", { fingerprint: "x", atMs: 999_000, suggestion: "earlier" }],
  ]);
  const fake = makeFakeClient({
    surfaces: [makeSurface({ id: "s1", agentState: "waiting" })],
    screens: { s1: "still waiting" },
  });
  // now=1_000_000, last at 999_000 → 1s < 20s debounce → skipped (no read, no call).
  const { deps, suggestCalls } = makeDeps({
    fake,
    summarize: okSummary,
    now: 1_000_000,
    lastSuggestion: last,
  });
  await runSweep(deps);
  assert.equal(suggestCalls.length, 0, "manager debounced");
});

test("runSweep: manager skips an UNCHANGED waiting screen past debounce", async () => {
  // Seed last with the fingerprint the NEXT call would compute, so it is unchanged.
  // We compute it by running once, then a second run with no screen change.
  const fake = makeFakeClient({
    surfaces: [makeSurface({ id: "s1", agentState: "waiting", userNotes: "goal" })],
    screens: { s1: "same screen" },
  });
  let t = 1_000_000;
  const { deps, suggestCalls } = makeDeps({
    fake,
    summarize: okSummary,
    suggest: okSuggestion,
    lastSuggestion: new Map(),
  });
  deps.now = () => t;
  await runSweep(deps);                  // first: fires
  assert.equal(suggestCalls.length, 1);
  t += deps.managerCfg.debounceMs + 1;   // past debounce, but screen unchanged
  await runSweep(deps);                  // second: unchanged → skipped
  assert.equal(suggestCalls.length, 1, "unchanged screen not re-suggested");
});

test("runSweep: a DISMISSED waiting agent is suppressed until ONE MEANINGFUL change (natural path)", async () => {
  // The NATURAL production path: a `waiting` agent's screen AND goals stay STABLE
  // through the dismiss sweep (the user dismisses without the agent or goals moving).
  // Dismiss-suppression must still arm at dismiss time even though the manager
  // `unchanged` gate would match the stable screen+goals — and then a SINGLE viewport
  // change (not two) must re-suggest. This is the off-by-one regression guard: nothing
  // here mutates `userNotes` to dodge the `unchanged` gate.
  const surfaceState = makeSurface({
    id: "s1",
    agentState: "waiting",
    userNotes: "migrate to postgres", // STABLE across every sweep below
  });
  let viewport = "the blocking screen"; // STABLE through the dismiss sweep
  const fake = makeFakeClient({ surfaces: [surfaceState] });
  fake.client.readSurface = (async (id: string) => {
    void id;
    return { text: viewport, cols: 80, rows: 24 };
  }) as McpClient["readSurface"];

  let t = 1_000_000;
  const lastSuggestion = new Map<string, LastSuggestion>();
  const { deps, suggestCalls } = makeDeps({
    fake,
    summarize: okSummary,
    suggest: okSuggestion,
    lastSuggestion,
  });
  deps.now = () => t;

  await runSweep(deps);
  assert.equal(suggestCalls.length, 1, "first suggestion fires");

  // The user DISMISSES it; host now reports suggestionDismissed:true. The screen AND
  // goals are UNCHANGED (the natural case) — the arm must still be set this sweep.
  surfaceState.suggestionDismissed = true;
  t += deps.managerCfg.debounceMs + 1;
  await runSweep(deps); // dismissed-arm: arms suppression, no model call
  assert.equal(suggestCalls.length, 1, "dismissed-arm: no re-suggest");
  assert.ok(
    lastSuggestion.get("s1")?.suppressedFingerprint,
    "suppression armed at dismiss time despite an unchanged screen",
  );

  // Another stable sweep (screen + goals unchanged) — still suppressed.
  t += deps.managerCfg.debounceMs + 1;
  await runSweep(deps); // dismissed-unchanged: still suppressed
  assert.equal(suggestCalls.length, 1, "dismissed-unchanged: still suppressed");

  // EXACTLY ONE meaningful viewport change → summarizer fingerprint flips → suppression
  // clears and it suggests again on that SINGLE change.
  viewport = "a completely different blocking screen";
  t += deps.managerCfg.debounceMs + 1;
  await runSweep(deps);
  assert.equal(
    suggestCalls.length,
    2,
    "a SINGLE meaningful change re-suggests after dismissal",
  );
  assert.equal(
    lastSuggestion.get("s1")?.suppressedFingerprint ?? null,
    null,
    "arm cleared on the fresh suggestion",
  );
});

test("runSweep: a closed waiting session's manager memory is pruned", async () => {
  const last = new Map<string, LastSuggestion>([
    ["gone", { fingerprint: "f", atMs: 1, suggestion: "old" }],
    ["s1", { fingerprint: "g", atMs: 1, suggestion: "keep" }],
  ]);
  const fake = makeFakeClient({
    surfaces: [makeSurface({ id: "s1", agentState: "idle" })],
    screens: { s1: "x" },
  });
  const { deps } = makeDeps({ fake, summarize: okSummary, lastSuggestion: last });
  await runSweep(deps);
  assert.equal(deps.lastSuggestionBySession.has("gone"), false, "dead manager record pruned");
  assert.equal(deps.lastSuggestionBySession.has("s1"), true, "live manager record kept");
});

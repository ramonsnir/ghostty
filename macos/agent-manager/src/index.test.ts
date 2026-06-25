// Orchestration tests for the loop's runSweep/summarizeOne wiring. These verify
// the load-bearing behaviors the pure gate tests can't: that the loop HONORS the
// gate (an unchanged idle session is never summarized end-to-end), per-surface
// error isolation, budget acquire/release pairing, dead-session record cleanup,
// and that a listSurfaces failure just skips the sweep. The model call + MCP
// client + overrides loader are all injected via LoopDeps. Run via `npm test`.

import test from "node:test";
import assert from "node:assert/strict";

import {
  runSweep,
  makeCoalescedRunner,
  parseLoopEnablement,
  type LoopDeps,
  type SummarizeFn,
} from "./index.js";
import type { McpClient, Surface, SurfaceScreen, Annotation } from "./mcp.js";
import {
  DEFAULT_CONFIG,
  ConcurrencyBudget,
  changeSignals,
  changeTail,
  type LastSummary,
  type SurfaceSnapshot,
} from "./summarizer.js";
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
  /** ids that should throw from signalAttention. */
  signalThrows?: Set<string>;
  /** ids that should throw from setAttention. */
  attentionThrows?: Set<string>;
  /** when true, listSurfaces throws. */
  listThrows?: boolean;
}

interface FakeClient {
  client: McpClient;
  setCalls: Array<{ id: string; ann: Annotation }>;
  readCalls: string[];
  signalCalls: Array<{ id: string; reason?: string }>;
  attentionCalls: Array<{ id: string; on: boolean; reason?: string }>;
}

/** Build a structurally-typed fake McpClient (cast to the class — runSweep only ever
 *  calls listSurfaces/readSurface/setAnnotation/signalAttention/setAttention). */
function makeFakeClient(spec: FakeClientSpec): FakeClient {
  const setCalls: Array<{ id: string; ann: Annotation }> = [];
  const readCalls: string[] = [];
  const signalCalls: Array<{ id: string; reason?: string }> = [];
  const attentionCalls: Array<{ id: string; on: boolean; reason?: string }> = [];
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
    async signalAttention(id: string, reason?: string): Promise<void> {
      if (spec.signalThrows?.has(id)) throw new Error(`signal boom ${id}`);
      signalCalls.push({ id, reason });
    },
    async setAttention(id: string, on: boolean, reason?: string): Promise<void> {
      if (spec.attentionThrows?.has(id)) throw new Error(`attention boom ${id}`);
      attentionCalls.push({ id, on, reason });
    },
  } as unknown as McpClient;
  return { client, setCalls, readCalls, signalCalls, attentionCalls };
}

interface DepsSpec {
  fake: FakeClient;
  summarize: SummarizeFn;
  now?: number;
  last?: Map<string, LastSummary>;
  alerts?: Map<string, string>;
  /** Defaults TRUE (the continuous summarizer is on) so existing summarizer tests are
   *  unchanged; set false to exercise queue-only / bell-only mode. */
  summarizerEnabled?: boolean;
  bellFilter?: boolean;
  bellsSeen?: Map<string, boolean>;
  pendingBells?: Set<string>;
  budgetMax?: number;
  backoff?: { failureStreak: number; nextProbeMs: number };
}

function makeDeps(spec: DepsSpec): {
  deps: LoopDeps;
  summarizeCalls: Array<{ system: string; user: string; configDir?: string }>;
} {
  const summarizeCalls: Array<{ system: string; user: string; configDir?: string }> = [];
  const summarize: SummarizeFn = async (req) => {
    summarizeCalls.push(req);
    return spec.summarize(req);
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
    alertBySession: spec.alerts ?? new Map<string, string>(),
    summarizerEnabled: spec.summarizerEnabled ?? true,
    bellFilter: spec.bellFilter ?? false,
    bellSeenBySession: spec.bellsSeen ?? new Map<string, boolean>(),
    pendingBellIds: spec.pendingBells ?? new Set<string>(),
    summarizerBackoff: spec.backoff ?? { failureStreak: 0, nextProbeMs: 0 },
  };
  return { deps, summarizeCalls };
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

  const last = new Map<string, LastSummary>([
    ["s1", {
      signals: changeSignals(snapshot.surface),
      tail: changeTail(snapshot.viewport, DEFAULT_CONFIG),
      atMs: 0, summary: "old",
    }],
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
    ["s1", { signals: "stale0000", tail: "stale", atMs: 0, summary: "old" }],
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
    ["gone", { signals: "x", tail: "x", atMs: 0, summary: "old" }],
    ["s1", { signals: "y", tail: "y", atMs: 0, summary: "old" }],
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
// Account routing: the resolved configDir is threaded to the model call
// ---------------------------------------------------------------------------

test("runSweep: the summarizer's configDir is passed to the model call", async () => {
  const fake = makeFakeClient({
    surfaces: [makeSurface({ id: "s1", agentState: "working" })],
    screens: { s1: "line a" },
  });
  const { deps, summarizeCalls } = makeDeps({ fake, summarize: okSummary });
  deps.summarizerConfigDir = "/home/test/.claude-accounts/dev";

  await runSweep(deps);

  assert.equal(summarizeCalls.length, 1);
  assert.equal(summarizeCalls[0].configDir, "/home/test/.claude-accounts/dev");
});

test("runSweep: configDir is undefined when no account is configured (inherit auth)", async () => {
  const fake = makeFakeClient({
    surfaces: [makeSurface({ id: "s1", agentState: "working" })],
    screens: { s1: "line a" },
  });
  const { deps, summarizeCalls } = makeDeps({ fake, summarize: okSummary });

  await runSweep(deps);

  assert.equal(summarizeCalls.length, 1);
  assert.equal(summarizeCalls[0].configDir, undefined);
});


// ---------------------------------------------------------------------------
// Rate-limit / attention bell (ramon fork): the MODEL is the sole classifier.
// The loop rings on a rising edge of the model's `alert` field and clears when
// the model reports no alert. There is NO regex on the viewport — only Haiku's
// verdict moves the bell, so scrolled-up history can never (re-)ring it and
// recovery un-rings as soon as the model reclassifies.
// ---------------------------------------------------------------------------

// A viewport that CONTAINS the rate-limit prompt text. The loop must ignore the
// text itself — only the model's `alert` verdict matters — so these tests pair it
// with a model that does / does not flag the alert to prove the text is inert.
const RATE_LIMIT_SCREEN =
  "Claude usage limit reached\n\nWhat do you want to do?\n\n  1. Stop and wait for limit to reset\n  2. Ask your admin for more usage\n\nEnter to confirm · Esc to cancel";

const rateLimitedSummary: SummarizeFn = async () =>
  '{"summary":"Rate limited — waiting for reset","alert":"rate_limited"}';
const noAlertSummary: SummarizeFn = async () => '{"summary":"Back to writing tests"}';

test("bell: model flags rate_limited => rings exactly once + records the tag", async () => {
  const fake = makeFakeClient({
    surfaces: [makeSurface({ id: "s1", agentState: "working" })],
    screens: { s1: RATE_LIMIT_SCREEN },
  });
  const { deps } = makeDeps({ fake, summarize: rateLimitedSummary });

  await runSweep(deps);

  assert.equal(fake.attentionCalls.length, 1, "promoted attention exactly once");
  assert.equal(fake.attentionCalls[0].id, "s1");
  assert.equal(fake.attentionCalls[0].on, true);
  assert.match(fake.attentionCalls[0].reason ?? "", /rate limited/i);
  assert.equal(deps.alertBySession.get("s1"), "rate_limited");
});

test("bell: a held alert under idle-skip does not re-ring (no model call, stays armed)", async () => {
  const viewport = RATE_LIMIT_SCREEN;
  const surface = makeSurface({ id: "s1", agentState: "working", idleSeconds: 999 });
  const lastSig = changeSignals(surface);
  const lastTail = changeTail(viewport, DEFAULT_CONFIG);
  const fake = makeFakeClient({ surfaces: [surface], screens: { s1: viewport } });
  const { deps, summarizeCalls } = makeDeps({
    fake,
    summarize: rateLimitedSummary,
    now: DEFAULT_CONFIG.debounceMs + 100_000,
    last: new Map([["s1", { signals: lastSig, tail: lastTail, atMs: 0, summary: "Rate limited" }]]),
    alerts: new Map([["s1", "rate_limited"]]),
  });

  await runSweep(deps);

  assert.equal(summarizeCalls.length, 0, "idle-skip: no model call");
  assert.equal(fake.attentionCalls.length, 0, "held alert must not re-promote");
  assert.equal(deps.alertBySession.get("s1"), "rate_limited", "alert left armed");
});

test("bell: recovery — model reports NO alert => clears the armed tag, no ring", async () => {
  // The viewport STILL contains the rate-limit text (scrolled up), but the model
  // judges the live state has recovered and omits `alert`. The bell must clear.
  const fake = makeFakeClient({
    surfaces: [makeSurface({ id: "s1", agentState: "working" })],
    screens: { s1: RATE_LIMIT_SCREEN + "\n\n❯ npm test\nall green" },
  });
  const { deps } = makeDeps({
    fake,
    summarize: noAlertSummary,
    alerts: new Map([["s1", "rate_limited"]]),
  });

  await runSweep(deps);

  // The clearing edge un-promotes (set_attention off) and re-arms the tag.
  assert.equal(fake.attentionCalls.filter((c) => c.on).length, 0, "no promotion on recovery");
  assert.ok(fake.attentionCalls.some((c) => c.id === "s1" && c.on === false), "un-promoted");
  assert.equal(deps.alertBySession.has("s1"), false, "armed tag cleared / re-armed");
});

test("bell: scrolled-up text alone never rings — only the model's verdict does", async () => {
  // Not pre-armed; viewport contains the text; model says no alert => nothing happens.
  const fake = makeFakeClient({
    surfaces: [makeSurface({ id: "s1", agentState: "working" })],
    screens: { s1: RATE_LIMIT_SCREEN },
  });
  const { deps } = makeDeps({ fake, summarize: noAlertSummary });

  await runSweep(deps);

  assert.equal(fake.attentionCalls.length, 0, "viewport text is inert without a model alert");
  assert.equal(deps.alertBySession.has("s1"), false);
});

test("bell: a failed model call leaves the alert state UNTOUCHED (held stays armed)", async () => {
  const boom: SummarizeFn = async () => {
    throw new Error("summarizer account also rate limited");
  };
  const fake = makeFakeClient({
    surfaces: [makeSurface({ id: "s1", agentState: "working" })],
    screens: { s1: RATE_LIMIT_SCREEN },
  });
  const { deps } = makeDeps({
    fake,
    summarize: boom,
    alerts: new Map([["s1", "rate_limited"]]),
  });

  await runSweep(deps);

  // No fresh classify => no ring and no clear. (The honest cost of pure-Haiku: a
  // FIRST detection can't happen while the summarizer's own calls fail — mitigated
  // by routing the summarizer to a separate account.)
  assert.equal(fake.attentionCalls.length, 0, "no promotion on model failure");
  assert.equal(deps.alertBySession.get("s1"), "rate_limited", "held alert untouched");
});

test("bell: model alert rings regardless of the on-screen text", async () => {
  const fake = makeFakeClient({
    surfaces: [makeSurface({ id: "s1", agentState: "working" })],
    screens: { s1: "an opaque TUI with no recognizable prompt text" },
  });
  const { deps } = makeDeps({ fake, summarize: rateLimitedSummary });

  await runSweep(deps);

  assert.equal(fake.attentionCalls.length, 1, "the model's verdict alone drives the promotion");
  assert.equal(fake.attentionCalls[0].on, true);
  assert.equal(deps.alertBySession.get("s1"), "rate_limited");
});

test("bell: a changed alert tag re-rings", async () => {
  const otherAlert: SummarizeFn = async () =>
    '{"summary":"Something else needs you","alert":"needs_input"}';
  const fake = makeFakeClient({
    surfaces: [makeSurface({ id: "s1", agentState: "working" })],
    screens: { s1: "..." },
  });
  const { deps } = makeDeps({
    fake,
    summarize: otherAlert,
    alerts: new Map([["s1", "rate_limited"]]),
  });

  await runSweep(deps);

  assert.equal(fake.attentionCalls.length, 1, "a different tag is a fresh edge");
  assert.equal(fake.attentionCalls[0].on, true);
  assert.equal(deps.alertBySession.get("s1"), "needs_input");
});

test("bell: a failed set_attention rolls back so a later sweep retries", async () => {
  const fake = makeFakeClient({
    surfaces: [makeSurface({ id: "s1", agentState: "working" })],
    screens: { s1: RATE_LIMIT_SCREEN },
    attentionThrows: new Set(["s1"]),
  });
  const { deps } = makeDeps({ fake, summarize: rateLimitedSummary });

  await runSweep(deps);

  assert.equal(deps.alertBySession.has("s1"), false, "rolled back after a failed promotion");
});

test("bell: a non-agent surface is never read, classified, or rung", async () => {
  const fake = makeFakeClient({
    surfaces: [makeSurface({ id: "s1", processName: "vim" })],
    screens: { s1: RATE_LIMIT_SCREEN },
  });
  const { deps, summarizeCalls } = makeDeps({ fake, summarize: rateLimitedSummary });

  await runSweep(deps);

  assert.equal(fake.readCalls.length, 0, "non-agent is pre-gated out (no read)");
  assert.equal(summarizeCalls.length, 0, "and never classified");
  assert.equal(fake.attentionCalls.length, 0, "and never promoted");
});

test("bell: dead-surface alert records are pruned each sweep", async () => {
  const fake = makeFakeClient({ surfaces: [] }); // s1 is gone
  const { deps } = makeDeps({
    fake,
    summarize: rateLimitedSummary,
    alerts: new Map([["s1", "rate_limited"]]),
  });

  await runSweep(deps);

  assert.equal(deps.alertBySession.has("s1"), false, "stale alert record dropped");
});

// ---------------------------------------------------------------------------
// Bell-attention (ramon fork): a bell rising-edge forces a classify, and Haiku's
// `attention` verdict PROMOTES the bell to the sticky "attention needed" state via
// set_attention. Only when bellFilter is on; only on a rising edge; never for a
// non-agent; and `attention` is acted on ONLY for a bell-triggered classify.
// ---------------------------------------------------------------------------

const attnTrue: SummarizeFn = async () =>
  '{"summary":"Needs you: approve deploy?","attention":true}';
const attnFalse: SummarizeFn = async () =>
  '{"summary":"Workflow running in the background","attention":false}';

// A debounced agent surface: preGate/shouldSummarize would normally SKIP it, so any
// classify that happens is attributable to the bell force-through.
function debouncedAgent(over: Partial<Surface> = {}) {
  const surface = makeSurface({ id: "s1", agentState: "working", ...over });
  const last = new Map<string, LastSummary>([
    ["s1", { signals: "sig", tail: "tail", atMs: 1_000_000 - 1000, summary: "old" }],
  ]);
  return { surface, last };
}

test("bell-attention: bellFilter OFF ⇒ a bell never forces a classify (byte-identical)", async () => {
  const { surface, last } = debouncedAgent({ bell: true });
  const fake = makeFakeClient({ surfaces: [surface], screens: { s1: "x" } });
  const { deps, summarizeCalls } = makeDeps({ fake, summarize: attnTrue, last, bellFilter: false });

  await runSweep(deps);

  assert.equal(summarizeCalls.length, 0, "debounced surface stays skipped");
  assert.equal(fake.attentionCalls.length, 0);
});

test("bell-attention: a rising bell on a debounced agent forces a classify + promotes when attention:true", async () => {
  const { surface, last } = debouncedAgent({ bell: true });
  const fake = makeFakeClient({ surfaces: [surface], screens: { s1: "permission prompt" } });
  const { deps, summarizeCalls } = makeDeps({ fake, summarize: attnTrue, last, bellFilter: true });

  await runSweep(deps);

  assert.equal(summarizeCalls.length, 1, "bell forced a classify past debounce");
  assert.equal(fake.attentionCalls.length, 1, "promoted to attention needed");
  assert.deepEqual(fake.attentionCalls[0], {
    id: "s1",
    on: true,
    reason: "Needs you: approve deploy?",
  });
  assert.equal(deps.bellSeenBySession.get("s1"), true, "bell state recorded");
});

// (bell-attention v2 slice 6 — the recommended-config blocker regression test) In the
// `bell-features = system,audio` config the GUI never arms view.bell, so list_surfaces.bell
// is ALWAYS false and the rising-edge backstop can never fire. Promotion MUST instead come
// from the bell-reactive loop's pendingBellIds (the wait_for_event signal, truthful on every
// ring). Here s.bell is false but the id is pending ⇒ it must still force-classify + promote.
test("bell-attention: a pendingBellId forces a classify even when list_surfaces.bell is false (system,audio config)", async () => {
  const { surface, last } = debouncedAgent({ bell: false }); // never armed (sound-only)
  const fake = makeFakeClient({ surfaces: [surface], screens: { s1: "permission prompt" } });
  const { deps, summarizeCalls } = makeDeps({
    fake,
    summarize: attnTrue,
    last,
    bellFilter: true,
    pendingBells: new Set(["s1"]), // the bell-reactive loop saw it ring
  });

  await runSweep(deps);

  assert.equal(summarizeCalls.length, 1, "pendingBellId forced a classify despite bell=false");
  assert.equal(fake.attentionCalls.length, 1, "promoted");
  assert.equal(fake.attentionCalls[0].on, true);
  assert.equal(deps.pendingBellIds.size, 0, "pending set drained (one-shot per ring)");
});

// (bell-attention) The DECOUPLING: agent-manager (the expensive continuous summarizer) is
// OFF, but bell-filter is ON (queue-only / bell-only mode). A bell must STILL promote (cheap,
// per-bell, fail-open), while the due NON-belled agents must NOT be polled (the costly pass
// is gated off). This is the combination the "agent-manager optional" change requires.
test("bell-attention: summarizer OFF + bell-filter ON ⇒ a bell promotes but due agents are NOT polled", async () => {
  const belled = makeSurface({ id: "s1", agentState: "working", bell: false }); // sound-only ring
  const due = makeSurface({ id: "s2", agentState: "working", bell: false }); // changed/due, no bell
  const fake = makeFakeClient({
    surfaces: [belled, due],
    screens: { s1: "permission prompt", s2: "fresh output" },
  });
  const { deps, summarizeCalls } = makeDeps({
    fake,
    summarize: attnTrue,
    summarizerEnabled: false, // agent-manager OFF (the expensive poll is gated)
    bellFilter: true, // per-bell promotion ON
    pendingBells: new Set(["s1"]), // the bell-reactive loop saw s1 ring
  });

  await runSweep(deps);

  assert.deepEqual(fake.readCalls, ["s1"], "ONLY the belled surface is read — no continuous poll");
  assert.equal(summarizeCalls.length, 1, "exactly one classify (the bell), not the due agent s2");
  assert.equal(fake.attentionCalls.length, 1, "the bell still promotes with the summarizer off");
  assert.equal(fake.attentionCalls[0].id, "s1");
});

// Complement: summarizer OFF + bell-filter ON + NO bell ⇒ a fully no-op sweep.
test("bell-attention: summarizer OFF + bell-filter ON + no bell ⇒ no model calls at all", async () => {
  const fake = makeFakeClient({
    surfaces: [makeSurface({ id: "s1", agentState: "working" })],
    screens: { s1: "fresh output" },
  });
  const { deps, summarizeCalls } = makeDeps({
    fake,
    summarize: attnTrue,
    summarizerEnabled: false,
    bellFilter: true,
  });

  await runSweep(deps);

  assert.equal(summarizeCalls.length, 0, "no bell + summarizer off ⇒ nothing summarized");
  assert.equal(fake.readCalls.length, 0, "not even a read");
});

test("bell-attention: attention:false ⇒ classified but NOT promoted (quiet raw bell stands)", async () => {
  const { surface, last } = debouncedAgent({ bell: true });
  const fake = makeFakeClient({ surfaces: [surface], screens: { s1: "launched workflow" } });
  const { deps, summarizeCalls } = makeDeps({ fake, summarize: attnFalse, last, bellFilter: true });

  await runSweep(deps);

  assert.equal(summarizeCalls.length, 1, "still classified");
  assert.equal(fake.attentionCalls.length, 0, "not promoted");
});

// (bell-attention v2) Haiku realistically emits a STRINGIFIED boolean. A string
// "false" is a CONFIDENT suppress; an UNRECOGNIZED string is uncertain ⇒ fail-open
// PROMOTE. These two pin the load-bearing safety path end-to-end through runSweep.
test("bell-attention: string \"false\" ⇒ classified but NOT promoted (confident suppress)", async () => {
  const { surface, last } = debouncedAgent({ bell: true });
  const fake = makeFakeClient({ surfaces: [surface], screens: { s1: "launched workflow" } });
  const strFalse: SummarizeFn = async () =>
    '{"summary":"Workflow running","attention":"false"}';
  const { deps, summarizeCalls } = makeDeps({ fake, summarize: strFalse, last, bellFilter: true });

  await runSweep(deps);

  assert.equal(summarizeCalls.length, 1, "still classified");
  assert.equal(fake.attentionCalls.length, 0, "string \"false\" suppresses like boolean false");
});

test("bell-attention: an UNRECOGNIZED attention string ⇒ PROMOTE (fail-open, not suppress)", async () => {
  const { surface, last } = debouncedAgent({ bell: true });
  const fake = makeFakeClient({ surfaces: [surface], screens: { s1: "permission prompt" } });
  const strMaybe: SummarizeFn = async () =>
    '{"summary":"Needs you?","attention":"maybe"}';
  const { deps } = makeDeps({ fake, summarize: strMaybe, last, bellFilter: true });

  await runSweep(deps);

  assert.equal(fake.attentionCalls.length, 1, "uncertain value must fail-open to a promotion");
  assert.equal(fake.attentionCalls[0].on, true);
});

test("bell-attention: only a RISING edge forces — a held bell does not re-classify", async () => {
  const { surface, last } = debouncedAgent({ bell: true });
  // Pre-seed the bell as already-seen-high: no rising edge this sweep.
  const fake = makeFakeClient({ surfaces: [surface], screens: { s1: "x" } });
  const { deps, summarizeCalls } = makeDeps({
    fake,
    summarize: attnTrue,
    last,
    bellFilter: true,
    bellsSeen: new Map([["s1", true]]),
  });

  await runSweep(deps);

  assert.equal(summarizeCalls.length, 0, "held bell does not force a classify");
  assert.equal(fake.attentionCalls.length, 0);
});

test("bell-attention: a bell on a NON-agent surface is never read/classified/promoted", async () => {
  const fake = makeFakeClient({
    surfaces: [makeSurface({ id: "s1", processName: "vim", bell: true })],
    screens: { s1: "x" },
  });
  const { deps, summarizeCalls } = makeDeps({ fake, summarize: attnTrue, bellFilter: true });

  await runSweep(deps);

  assert.equal(fake.readCalls.length, 0, "non-agent not read");
  assert.equal(summarizeCalls.length, 0);
  assert.equal(fake.attentionCalls.length, 0);
});

test("bell-attention: `attention` is acted on ONLY for a bell-triggered classify", async () => {
  // A normally-due (changed) agent surface with NO bell: even if the model returns
  // attention:true, the loop must NOT promote (bellRang is false).
  const surface = makeSurface({ id: "s1", agentState: "working", bell: false });
  const fake = makeFakeClient({ surfaces: [surface], screens: { s1: "fresh output" } });
  const { deps, summarizeCalls } = makeDeps({ fake, summarize: attnTrue, bellFilter: true });

  await runSweep(deps);

  assert.equal(summarizeCalls.length, 1, "summarized as usual");
  assert.equal(fake.attentionCalls.length, 0, "no promotion without a bell");
});

test("bell-attention: a failed set_attention is swallowed (annotation still written)", async () => {
  const { surface, last } = debouncedAgent({ bell: true });
  const fake = makeFakeClient({
    surfaces: [surface],
    screens: { s1: "permission prompt" },
    attentionThrows: new Set(["s1"]),
  });
  const { deps } = makeDeps({ fake, summarize: attnTrue, last, bellFilter: true });

  await runSweep(deps); // must not throw

  assert.equal(fake.setCalls.length, 1, "annotation still written despite the promote failure");
  assert.equal(deps.budget.active, 0, "budget released");
});

test("bell-attention: dead-surface bell records are pruned each sweep", async () => {
  const fake = makeFakeClient({ surfaces: [] }); // s1 gone
  const { deps } = makeDeps({
    fake,
    summarize: attnTrue,
    bellFilter: true,
    bellsSeen: new Map([["s1", true]]),
  });

  await runSweep(deps);

  assert.equal(deps.bellSeenBySession.has("s1"), false, "stale bell record dropped");
});

// ---------------------------------------------------------------------------
// Bell-attention v2 FAIL-OPEN: a bell is suppressed ONLY by a clean, confident
// attention:false. Omitted/uncertain verdict, a thrown model call, and an
// unparseable reply all PROMOTE (a failing/hedging classifier never silences a bell).
// ---------------------------------------------------------------------------

const attnOmitted: SummarizeFn = async () => '{"summary":"working on stuff"}'; // no attention field

test("bell-attention v2: omitted attention on a bell ⇒ FAIL-OPEN promote", async () => {
  const { surface, last } = debouncedAgent({ bell: true });
  const fake = makeFakeClient({ surfaces: [surface], screens: { s1: "ambiguous screen" } });
  const { deps } = makeDeps({ fake, summarize: attnOmitted, last, bellFilter: true });

  await runSweep(deps);

  assert.equal(fake.attentionCalls.length, 1, "uncertain verdict still promotes");
  assert.equal(fake.attentionCalls[0].on, true);
});

test("bell-attention v2: a THROWN model call on a bell ⇒ FAIL-OPEN promote", async () => {
  const boom: SummarizeFn = async () => {
    throw new Error("summarizer account out of tokens");
  };
  const { surface, last } = debouncedAgent({ bell: true });
  const fake = makeFakeClient({ surfaces: [surface], screens: { s1: "x" } });
  const { deps } = makeDeps({ fake, summarize: boom, last, bellFilter: true });

  await runSweep(deps); // must not throw

  assert.equal(fake.attentionCalls.length, 1, "a failing classifier promotes (fail-open)");
  assert.equal(fake.attentionCalls[0].on, true);
});

test("bell-attention v2: an UNPARSEABLE reply on a bell ⇒ FAIL-OPEN promote", async () => {
  const junk: SummarizeFn = async () => "not json at all";
  const { surface, last } = debouncedAgent({ bell: true });
  const fake = makeFakeClient({ surfaces: [surface], screens: { s1: "x" } });
  const { deps } = makeDeps({ fake, summarize: junk, last, bellFilter: true });

  await runSweep(deps);

  assert.equal(fake.attentionCalls.length, 1, "unparseable reply promotes (fail-open)");
  assert.equal(fake.attentionCalls[0].on, true);
});

test("bell-attention v2: only a CONFIDENT attention:false suppresses", async () => {
  const { surface, last } = debouncedAgent({ bell: true });
  const fake = makeFakeClient({ surfaces: [surface], screens: { s1: "launched workflow in background" } });
  const { deps } = makeDeps({ fake, summarize: attnFalse, last, bellFilter: true });

  await runSweep(deps);

  assert.equal(fake.attentionCalls.length, 0, "explicit false is the ONLY thing that suppresses");
});

// (bell-attention v2 slice 4) makeCoalescedRunner — concurrent callers coalesce
// into non-overlapping runs, with a single re-run when a wake arrives mid-flight.
test("coalesce: serial calls run once each (no coalescing when idle)", async () => {
  let runs = 0;
  const run = makeCoalescedRunner(async () => {
    runs++;
  });
  await run();
  await run();
  assert.equal(runs, 2);
});

test("coalesce: a wake DURING a run triggers exactly one re-run", async () => {
  let runs = 0;
  let release!: () => void;
  let gate = new Promise<void>((r) => {
    release = r;
  });
  const run = makeCoalescedRunner(async () => {
    runs++;
    await gate; // park the first run so we can fire concurrent calls
  });
  const first = run(); // starts running, parked on gate
  // Two more calls arrive while running: they must coalesce to ONE re-run.
  const second = run();
  const third = run();
  // Re-arm the gate so the coalesced re-run can also complete promptly.
  const firstGate = gate;
  gate = Promise.resolve();
  release(); // let the first run finish; firstGate resolves
  void firstGate;
  await Promise.all([first, second, third]);
  assert.equal(runs, 2, "first run + exactly one coalesced re-run");
});

test("coalesce: re-run is suppressed when isStopped() is true", async () => {
  let runs = 0;
  let stopped = false;
  let release!: () => void;
  const gate = new Promise<void>((r) => {
    release = r;
  });
  const run = makeCoalescedRunner(
    async () => {
      runs++;
      await gate;
    },
    () => stopped,
  );
  const first = run();
  void run(); // wake while running
  stopped = true; // but we are stopping
  release();
  await first;
  assert.equal(runs, 1, "no re-run after stop even though a wake arrived");
});

// ---------------------------------------------------------------------------
// Rate-limit backoff (account-wide adaptive slowdown)
// ---------------------------------------------------------------------------

test("backoff: an all-fail sweep engages backoff (streak 1, next probe armed)", async () => {
  const fake = makeFakeClient({
    surfaces: [makeSurface({ id: "s1", agentState: "working" })],
  });
  const failing: SummarizeFn = async () => {
    throw new Error("model down");
  };
  const now = 1_000_000;
  const { deps } = makeDeps({ fake, summarize: failing, now });

  await runSweep(deps);

  assert.equal(deps.summarizerBackoff.failureStreak, 1, "streak incremented");
  // base debounce = 30000 => first window is 30000ms out.
  assert.equal(deps.summarizerBackoff.nextProbeMs, now + 30000);
});

test("backoff: a success keeps the streak at 0 (normal cadence)", async () => {
  const fake = makeFakeClient({
    surfaces: [makeSurface({ id: "s1", agentState: "working" })],
  });
  const { deps } = makeDeps({ fake, summarize: okSummary });

  await runSweep(deps);

  assert.equal(deps.summarizerBackoff.failureStreak, 0);
  assert.equal(deps.summarizerBackoff.nextProbeMs, 0);
});

test("backoff: while cooling down, the sweep makes NO model calls", async () => {
  const fake = makeFakeClient({
    surfaces: [makeSurface({ id: "s1", agentState: "working" })],
  });
  const now = 1_000_000;
  // Seeded: already backing off, next probe far in the future.
  const { deps, summarizeCalls } = makeDeps({
    fake,
    summarize: okSummary,
    now,
    backoff: { failureStreak: 3, nextProbeMs: now + 100_000 },
  });

  await runSweep(deps);

  assert.equal(summarizeCalls.length, 0, "no model call while cooling down");
  assert.equal(fake.readCalls.length, 0, "not even a read");
  assert.equal(deps.summarizerBackoff.failureStreak, 3, "streak untouched");
});

test("backoff: after the window, ONE probe fires and a success resets the streak", async () => {
  const fake = makeFakeClient({
    surfaces: [
      makeSurface({ id: "s1", agentState: "working" }),
      makeSurface({ id: "s2", agentState: "working" }),
    ],
  });
  const now = 1_000_000;
  const { deps, summarizeCalls } = makeDeps({
    fake,
    summarize: okSummary,
    now,
    backoff: { failureStreak: 3, nextProbeMs: now }, // window elapsed (now >= nextProbeMs)
  });

  await runSweep(deps);

  assert.equal(summarizeCalls.length, 1, "exactly ONE probe call, not the whole batch");
  assert.equal(deps.summarizerBackoff.failureStreak, 0, "recovered");
  assert.equal(deps.summarizerBackoff.nextProbeMs, 0);
});

test("backoff: after the window, a FAILED probe extends the backoff (streak++)", async () => {
  const fake = makeFakeClient({
    surfaces: [
      makeSurface({ id: "s1", agentState: "working" }),
      makeSurface({ id: "s2", agentState: "working" }),
    ],
  });
  const failing: SummarizeFn = async () => {
    throw new Error("still limited");
  };
  const now = 1_000_000;
  const { deps, summarizeCalls } = makeDeps({
    fake,
    summarize: failing,
    now,
    backoff: { failureStreak: 3, nextProbeMs: now },
  });

  await runSweep(deps);

  assert.equal(summarizeCalls.length, 1, "only one probe even on failure");
  assert.equal(deps.summarizerBackoff.failureStreak, 4, "streak extended");
  assert.equal(deps.summarizerBackoff.nextProbeMs, now + 240000, "4th window = 30000*2^3");
});

test("backoff: an unparseable reply counts as a failure (engages backoff)", async () => {
  const fake = makeFakeClient({
    surfaces: [makeSurface({ id: "s1", agentState: "working" })],
  });
  const junk: SummarizeFn = async () => "not json at all";
  const { deps } = makeDeps({ fake, summarize: junk });

  await runSweep(deps);

  assert.equal(deps.summarizerBackoff.failureStreak, 1, "unparseable => fail => backoff");
});

// --- parseLoopEnablement: the independent summarizer/queue gating ---

test("loops: summarizer ON by default (absent flag = back-compat on)", () => {
  const e = parseLoopEnablement({});
  assert.equal(e.summarizer, true, "absent GHOSTTY_SUMMARIZER => on");
  assert.equal(e.queue, false, "absent GHOSTTY_AGENT_QUEUE => off");
});

test('loops: explicit "0" disables the summarizer (queue-only mode)', () => {
  const e = parseLoopEnablement({ GHOSTTY_SUMMARIZER: "0", GHOSTTY_AGENT_QUEUE: "1" });
  assert.equal(e.summarizer, false, '"0" => summarizer off');
  assert.equal(e.queue, true, '"1" => queue on');
});

test('loops: explicit "1" keeps the summarizer on; queue independent', () => {
  const e = parseLoopEnablement({ GHOSTTY_SUMMARIZER: "1" });
  assert.equal(e.summarizer, true);
  assert.equal(e.queue, false, "queue off unless exactly 1");
});

test("loops: queue is opt-in on exactly 1 (any other value = off)", () => {
  assert.equal(parseLoopEnablement({ GHOSTTY_AGENT_QUEUE: "true" }).queue, false);
  assert.equal(parseLoopEnablement({ GHOSTTY_AGENT_QUEUE: "0" }).queue, false);
  assert.equal(parseLoopEnablement({ GHOSTTY_AGENT_QUEUE: "1" }).queue, true);
});

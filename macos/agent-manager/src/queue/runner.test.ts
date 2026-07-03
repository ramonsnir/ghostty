// (ramon fork / Agent Queue Supervisor) Integration tests for the PASS-3 orchestrator
// (runner.ts) wired into the loop, AND for the no-op / non-starvation guarantees in
// index.ts's runSweep. These exercise the load-bearing control-flow the pure-module
// tests can't: the dispatch-suppressed first sweep (§9), an end-to-end mocked
// dispatch→done→close cycle (§6/§10), and EXITED → signal_attention (§6). The MCP
// client + provider exec + store IO are all injected — NO live MCP, child_process, or
// fs. Run via `npm test`.

import test from "node:test";
import assert from "node:assert/strict";

import { runSweep, runQueueSweepSafe, type LoopDeps } from "../index.js";
import type { McpClient, Surface, SurfaceScreen, Annotation } from "../mcp.js";
import { DEFAULT_CONFIG, ConcurrencyBudget } from "../summarizer.js";
import { makeOverrideLoader, type OverrideFs } from "../prompt.js";

import {
  runQueueSweep,
  makeQueueRun,
  occupiesSlot,
  effectiveMaxItemsCap,
  effectiveConcurrency,
  packRun,
  projectLiveSurfaces,
  totalHeroActiveRegistry,
  DEFAULT_PENDING_GRACE_MS,
  type QueueDeps,
  type QueueRun,
} from "./runner.js";
import { ConcurrencyBudget as QueueBudget } from "./supervisor.js";
import type { QueueCommand, RunFactory, RunRegistry } from "./commands.js";
import type { QueueStatusReport, QueueGraphReport } from "./status.js";
import { loadKeep, loadStore, loadDispatched, loadHero, reconcile, type LiveSurface, type StoreIO } from "./store.js";
import { shellEnvPrefix, type Exec, type ExecResult } from "./provider.js";
import type { Assignment, AssignmentState, QueueTemplate } from "./types.js";

// ---------------------------------------------------------------------------
// Fixtures + fakes.
// ---------------------------------------------------------------------------

const noOverrideFs: OverrideFs = { statMtimeMs: () => null, readText: () => null };

function tmpl(over: Partial<QueueTemplate> = {}): QueueTemplate {
  return {
    name: "backlog",
    workdir: "/repo",
    agent: { command: "claude work" },
    concurrency: 9,
    maxItems: 200,
    grid: { cols: 3, rows: 3, fill: "columns" },
    // Throttle DISABLED in the shared fixture (0 = every sweep fetches list+status, the
    // pre-throttle behavior) so the dispatch/state-machine tests below — which advance the
    // clock by only ~5s between sweeps — keep exercising every-sweep provider calls. The
    // interval THROTTLING itself is covered by the dedicated tests at the end of the file,
    // which build templates with realistic intervals.
    intervals: { listMs: 0, statusMs: 0 },
    provider: {
      list: { command: ["list"], keyField: "id", titleField: "title", urlField: "url" },
      status: { command: ["status", "{key}"], doneStates: ["done"] },
    },
    onAgentExit: "leave-and-bell",
    closeOnComplete: true,
    keepOnComplete: false,
    closeStableSeconds: 5,
    params: [],
    schedules: [],
    ...over,
  };
}

/** An in-memory StoreIO. */
function memStore(initial: string | null = null): StoreIO {
  let text = initial;
  return {
    read: () => text,
    write: (t: string) => {
      text = t;
    },
  };
}

/** A fake McpClient capturing the queue tool calls. Only the methods the runner uses
 *  are implemented (the rest throw if hit, so a stray call is loud). */
interface QueueFakeSpec {
  surfaces: Surface[];
  /** list provider output (JSON). */
  listJson?: string;
  /** graph provider output (JSON) — only used when the template declares provider.graph. */
  graphJson?: string;
  /** key -> status JSON (defaults to {"state":"working"} = not terminal). */
  statusByKey?: Record<string, string>;
  /** new spawns: a queue of {id,sessionId} returned in order by spawnSplitCommand. */
  spawns?: Array<{ id: string; sessionId: number }>;
  /** when set, spawnSplitCommand throws for these call indexes. */
  spawnThrowsAt?: Set<number>;
}

interface QueueFake {
  client: McpClient;
  exec: Exec;
  calls: {
    spawn: Array<Record<string, unknown>>;
    annotate: Array<{ id: string; ann: Annotation }>;
    forceClose: string[];
    signal: Array<{ id: string; reason?: string }>;
    sendKey: Array<{ id: string; key: string }>;
    sendText: Array<{ id: string; text: string }>;
    moveIntoTab: Array<{ sourceUUID: string; targetAnchorUUID: string; balanced?: boolean; maxCols?: number; maxRows?: number }>;
    /** (hero) perform_action calls — the promote eject uses `move_split_to_new_tab`. */
    perform: Array<{ id: string; action: string }>;
    list: number;
    graph: number;
    status: string[];
    reports: QueueStatusReport[];
    graphReports: QueueGraphReport[];
  };
}

function makeQueueFake(spec: QueueFakeSpec): QueueFake {
  const calls: QueueFake["calls"] = {
    spawn: [],
    annotate: [],
    forceClose: [],
    signal: [],
    sendKey: [],
    sendText: [],
    moveIntoTab: [],
    perform: [],
    list: 0,
    graph: 0,
    status: [],
    reports: [],
    graphReports: [],
  };
  let spawnIdx = 0;
  const spawns = spec.spawns ?? [];

  const client = {
    async listSurfaces(): Promise<Surface[]> {
      return spec.surfaces;
    },
    async readSurface(id: string): Promise<SurfaceScreen> {
      void id;
      return { text: "", cols: 80, rows: 24 };
    },
    async setAnnotation(id: string, ann: Annotation): Promise<void> {
      calls.annotate.push({ id, ann });
    },
    async spawnSplitCommand(args: Record<string, unknown>): Promise<{ id: string; sessionId: number }> {
      const i = spawnIdx++;
      calls.spawn.push(args);
      if (spec.spawnThrowsAt?.has(i)) throw new Error(`spawn boom ${i}`);
      return spawns[i] ?? { id: `auto-${i}`, sessionId: 100 + i };
    },
    async forceCloseSurface(id: string): Promise<void> {
      calls.forceClose.push(id);
    },
    async signalAttention(id: string, reason?: string): Promise<void> {
      calls.signal.push({ id, reason });
    },
    // (review fix / slice 5) leave-and-bell now routes through set_attention; record it
    // on the SAME `calls.signal` array so the existing leave-and-bell assertions
    // (signal fired / not fired) keep verifying the attention raise.
    async setAttention(id: string, _on: boolean, reason?: string): Promise<void> {
      calls.signal.push({ id, reason });
    },
    async sendKey(id: string, key: string): Promise<void> {
      calls.sendKey.push({ id, key });
    },
    async sendText(id: string, text: string): Promise<void> {
      calls.sendText.push({ id, text });
    },
    async moveSurfaceIntoTab(args: { sourceUUID: string; targetAnchorUUID: string; balanced?: boolean; maxCols?: number; maxRows?: number }): Promise<void> {
      calls.moveIntoTab.push(args);
    },
    async performAction(id: string, action: string): Promise<void> {
      calls.perform.push({ id, action });
    },
    async reportQueueStatus(status: QueueStatusReport): Promise<void> {
      calls.reports.push(status);
    },
    async reportQueueGraph(graph: QueueGraphReport): Promise<void> {
      calls.graphReports.push(graph);
    },
  } as unknown as McpClient;

  // The provider exec: the FIRST arg element decides list vs status (matches the tmpl
  // command arrays ["list"] and ["status","{key}"]).
  const exec: Exec = async (argv: string[]): Promise<ExecResult> => {
    if (argv[0] === "list") {
      calls.list += 1;
      return { code: 0, stdout: spec.listJson ?? "[]", stderr: "" };
    }
    if (argv[0] === "status") {
      const key = argv[1] ?? "";
      calls.status.push(key);
      const out = spec.statusByKey?.[key] ?? '{"state":"working"}';
      return { code: 0, stdout: out, stderr: "" };
    }
    if (argv[0] === "graph") {
      calls.graph += 1;
      return { code: 0, stdout: spec.graphJson ?? '{"nodes":[]}', stderr: "" };
    }
    return { code: 0, stdout: "", stderr: "" };
  };

  return { client, exec, calls };
}

/** Build a RunRegistry (run name → run) from a list of runs. */
function registryOf(runs: QueueRun[]): RunRegistry {
  const r: RunRegistry = new Map();
  for (const run of runs) r.set(run.template.name, run);
  return r;
}

/** A factory that always fails (no `start` command is issued in these baseline tests; the
 *  command-channel tests inject their own factory). A stray `start` is a logged no-op. */
const noFactory: RunFactory = () => null;

/** A `takeCommands` seam that yields the given commands ONCE then `[]` thereafter, so a
 *  test can inject a start/pause/stop/abort on a chosen sweep without an MCP server. */
function commandsOnce(cmds: QueueCommand[]): () => Promise<QueueCommand[]> {
  let sent = false;
  return async () => {
    if (sent) return [];
    sent = true;
    return cmds;
  };
}

function makeQueueDeps(
  fake: QueueFake,
  runs: QueueRun[],
  now: () => number,
  maxTotal = 8,
  over: Partial<QueueDeps> = {},
): QueueDeps {
  return {
    client: fake.client,
    exec: fake.exec,
    budget: new QueueBudget(maxTotal),
    now,
    registry: registryOf(runs),
    factory: noFactory,
    takeCommands: async () => [],
    maxTotal,
    // (hero) default the hero cap to 0 (DISABLED) in the shared builder so pre-hero regular-pool
    // tests are unaffected; hero tests pass `over: { heroMax }`.
    heroMax: 0,
    pendingGraceMs: DEFAULT_PENDING_GRACE_MS,
    ...over,
  };
}

function surface(over: Partial<Surface> = {}): Surface {
  return {
    id: "u-1",
    title: "claude",
    pwd: "/repo",
    window: 0,
    tab: 0,
    tabTitle: "t",
    splitIndex: 0,
    splitCount: 1,
    focused: false,
    bell: false,
    exited: false,
    atPrompt: false,
    ...over,
  };
}

/** A live surface carrying the queue annotation fields (queueKey/queueName/queueUrl),
 *  which ride back on a list_surfaces row but are NOT on the base Surface type — the
 *  runner reads them via a cast, so the test attaches them the same way. */
function queueSurface(
  over: Partial<Surface> & { queueKey?: string; queueName?: string; queueUrl?: string },
): Surface {
  const { queueKey, queueName, queueUrl, ...rest } = over;
  return Object.assign(surface(rest), { queueKey, queueName, queueUrl });
}

// ---------------------------------------------------------------------------
// (1) Pass 3 is a NO-OP when no queue is configured (runSweep unchanged).
// ---------------------------------------------------------------------------

const okSummary = async () => '{"summary":"ok"}';

function makeLoopDeps(client: McpClient): LoopDeps {
  const cfg = { ...DEFAULT_CONFIG };
  return {
    client,
    overrides: makeOverrideLoader("/home/test", noOverrideFs),
    cfg,
    budget: new ConcurrencyBudget(cfg.maxConcurrent),
    now: () => 1_000_000,
    summarize: okSummary,
    lastBySession: new Map(),
    alertBySession: new Map(),
    summarizerEnabled: true,
    bellFilter: false,
    bellSeenBySession: new Map(),
    pendingBellIds: new Set(),
    summarizerBackoff: { failureStreak: 0, nextProbeMs: 0 },
    // queue intentionally OMITTED → the queue pass is a no-op.
  };
}

test("runSweep: NEVER touches the queue (the queue runs on its own decoupled loop)", async () => {
  // The queue supervisor is no longer pass 3 of runSweep — it runs on an INDEPENDENT
  // timer (runQueueSweepSafe) so the slow LLM passes can never block/starve it. So
  // runSweep must touch ZERO queue tools, even when a queue is configured.
  const fake = makeQueueFake({ surfaces: [surface({ id: "s1", processName: "zsh" })] });
  const deps = makeLoopDeps(fake.client);
  deps.queue = makeQueueDeps(fake, [makeQueueRun(tmpl(), memStore())], () => 1_000);
  await runSweep(deps); // must not throw, must not touch any queue tool
  assert.equal(fake.calls.spawn.length, 0, "runSweep does not dispatch");
  assert.equal(fake.calls.forceClose.length, 0);
  assert.equal(fake.calls.signal.length, 0);
  assert.equal(fake.calls.list, 0, "runSweep does not run the provider list");
});

test("runQueueSweepSafe: a no-op (no throw) when no queue is configured", async () => {
  const fake = makeQueueFake({ surfaces: [] });
  let listed = 0;
  (fake.client as unknown as { listSurfaces: () => Promise<Surface[]> }).listSurfaces =
    async () => { listed += 1; return []; };
  const deps = makeLoopDeps(fake.client); // deps.queue intentionally undefined
  await runQueueSweepSafe(deps);
  assert.equal(listed, 0, "no queue → not even a list_surfaces call");
  assert.equal(fake.calls.spawn.length, 0);
});

test("runQueueSweepSafe: isolates a thrown error (the loop never dies)", async () => {
  const fake = makeQueueFake({ surfaces: [] });
  const deps = makeLoopDeps(fake.client);
  deps.queue = makeQueueDeps(fake, [makeQueueRun(tmpl(), memStore())], () => 1_000);
  // Make the queue's list_surfaces throw — runQueueSweepSafe must swallow it.
  (deps.queue.client as unknown as { listSurfaces: () => Promise<Surface[]> }).listSurfaces =
    async () => { throw new Error("boom"); };
  await runQueueSweepSafe(deps); // must NOT throw
});

test("runQueueSweep: empty runs list is a no-op (does not even list surfaces)", async () => {
  const fake = makeQueueFake({ surfaces: [] });
  let listed = 0;
  (fake.client as unknown as { listSurfaces: () => Promise<Surface[]> }).listSurfaces =
    async () => {
      listed += 1;
      return [];
    };
  const deps = makeQueueDeps(fake, [], () => 1_000);
  await runQueueSweep(deps);
  assert.equal(listed, 0, "no runs → no list_surfaces call");
});

// ---------------------------------------------------------------------------
// (2) Dispatch suppression: the FIRST sweep reconciles but NEVER dispatches; the
//     SECOND sweep is the first that dispatches (§9 first-pass invariant).
// ---------------------------------------------------------------------------

test("runQueueSweep: first sweep is dispatch-suppressed; second sweep dispatches", async () => {
  const fake = makeQueueFake({
    surfaces: [], // no live queue surfaces yet
    listJson: '[{"id":"K-1","title":"do a thing","url":"http://x/K-1"}]',
    spawns: [{ id: "spawned-1", sessionId: 501 }],
  });
  const run = makeQueueRun(tmpl(), memStore());
  let now = 1_000_000;
  const deps = makeQueueDeps(fake, [run], () => now);

  // First sweep: reconcile only — NO dispatch even though a candidate is listed.
  await runQueueSweep(deps);
  assert.equal(fake.calls.spawn.length, 0, "first sweep must NOT dispatch (suppressed)");

  // Second sweep: now armed → dispatch the single candidate.
  now += 5000;
  await runQueueSweep(deps);
  assert.equal(fake.calls.spawn.length, 1, "second sweep dispatches");
  assert.equal(fake.calls.spawn[0].firstTab, true, "first item opens the run tab");
  // (§12 grid cap) a firstTab spawn opens a fresh tab — no grid context — so it sends NO caps.
  assert.equal(fake.calls.spawn[0].maxCols, undefined, "firstTab spawn omits grid caps");
  assert.equal(fake.calls.spawn[0].maxRows, undefined, "firstTab spawn omits grid caps");
  // The command is the item-env PREFIX (delivered via the command since the host spawn
  // protocol drops env_vars under .client) + the verbatim template launch line.
  assert.equal(
    fake.calls.spawn[0].command,
    shellEnvPrefix({ key: "K-1", title: "do a thing", url: "http://x/K-1" }) + "claude work",
  );
  assert.ok((fake.calls.spawn[0].command as string).endsWith("claude work"), "template appended verbatim");
  // §13 / acceptance #3: item context reaches the agent as GHOSTTY_ITEM_* ENV VARS
  // carried on the spawn call — NOT spliced into the command string.
  const env = fake.calls.spawn[0].env as Record<string, string> | undefined;
  assert.ok(env, "spawn carries an item env map");
  assert.equal(env!.GHOSTTY_ITEM_KEY, "K-1", "GHOSTTY_ITEM_KEY delivered");
  assert.equal(env!.GHOSTTY_ITEM_TITLE, "do a thing", "GHOSTTY_ITEM_TITLE delivered");
  assert.equal(env!.GHOSTTY_ITEM_URL, "http://x/K-1", "GHOSTTY_ITEM_URL delivered");
  // The dispatch stamped the queueKey annotation.
  const ann = fake.calls.annotate.find((a) => a.ann.queueKey === "K-1");
  assert.ok(ann, "queueKey annotation stamped on dispatch");
  assert.equal(ann!.ann.queueName, "backlog");
  assert.equal(ann!.ann.queueUrl, "http://x/K-1");
  // The run's active set now tracks the key.
  assert.ok(run.active.has("K-1"));
  assert.equal(run.active.get("K-1")!.state, "SPAWNED");
  assert.equal(run.active.get("K-1")!.sessionID, 501);
});

// ---------------------------------------------------------------------------
// (3) The supervisor is NOT starved when the summarizer budget is exhausted:
//     the queue runs on its OWN timer with its OWN budget, so a busy summarizer
//     fleet never denies it a dispatch slot.
// ---------------------------------------------------------------------------

test("runSweep: the supervisor is NOT starved when the summarizer budget is exhausted", async () => {
  // A busy fleet of working agents would exhaust the summarizer (cap 1) budget; the
  // queue must STILL dispatch its candidate.
  const queueRun = makeQueueRun(tmpl(), memStore());
  const fake = makeQueueFake({
    surfaces: [
      surface({ id: "a1", agentState: "working" }),
      surface({ id: "a2", agentState: "working" }),
    ],
    listJson: '[{"id":"Q-1","title":"queued work"}]',
    spawns: [{ id: "spawned-q1", sessionId: 777 }],
  });
  let now = 2_000_000;
  const deps = makeLoopDeps(fake.client);
  // Tiny summarizer budget so the pass fully consumes it.
  deps.cfg = { ...DEFAULT_CONFIG, maxConcurrent: 1 };
  deps.budget = new ConcurrencyBudget(1);
  // Count summarizer model calls so we can PROVE the busy fleet was actually processed
  // (not silently skipped) at the time the queue still dispatched — without that, a
  // green result wouldn't distinguish "queue not starved" from "the pass never ran".
  let summarizeCalls = 0;
  deps.summarize = async () => {
    summarizeCalls += 1;
    return '{"summary":"ok"}';
  };
  deps.now = () => now;
  deps.queue = makeQueueDeps(fake, [queueRun], () => now);

  // The structural guarantee that makes starvation IMPOSSIBLE: the queue owns a budget
  // object DISTINCT from the summarizer's, so the summarizer consuming its budget can
  // never deny the queue a slot.
  assert.notEqual(deps.queue!.budget, deps.budget, "queue budget != summarizer budget");

  // The queue runs on its OWN independent timer (`runQueueSweepSafe`), DECOUPLED from
  // the slow LLM summarizer pass (`runSweep`) — so it can never be blocked or starved
  // by it, even when its budget is exhausted or its model calls are slow. Drive the
  // summarizer once (consuming its budget), then the queue's own loop twice (arm + dispatch).
  await runSweep(deps); // summarizer (no queue inside runSweep)
  await runQueueSweepSafe(deps); // queue's own loop: first call arms (dispatch-suppressed)
  assert.equal(fake.calls.spawn.length, 0, "queue suppressed on its first sweep");
  now += 5000;
  await runQueueSweepSafe(deps); // queue dispatches, independent of the summarizer

  assert.equal(fake.calls.spawn.length, 1, "queue dispatched independently of the summarizer");
  assert.equal(deps.queue!.budget.active, 0, "queue budget released");
  // The summarizer genuinely ran against the busy fleet (so the queue dispatched
  // ALONGSIDE real summarizer work, not because the fleet was idle).
  assert.ok(summarizeCalls >= 1, "summarizer ran against the busy fleet");
});

// ---------------------------------------------------------------------------
// (3b) WITHIN-TICK dedup at the ORCHESTRATOR layer: a single list that contains the
//      SAME key twice dispatches exactly ONE agent (§7 no-duplicates). This proves the
//      synchronous pre-await active-set insert + selectCandidates intra-batch dedup
//      end-to-end through runQueueSweep, not just at the pure-function layer.
// ---------------------------------------------------------------------------

test("runQueueSweep: a single list with the SAME key twice dispatches exactly one agent", async () => {
  const fake = makeQueueFake({
    surfaces: [],
    // Same id appears twice in ONE list response (a flaky/duplicating provider).
    listJson:
      '[{"id":"DUP-1","title":"first"},{"id":"DUP-1","title":"second"}]',
    spawns: [{ id: "spawned-dup", sessionId: 888 }],
  });
  const run = makeQueueRun(tmpl(), memStore());
  let now = 3_000_000;
  const deps = makeQueueDeps(fake, [run], () => now);

  await runQueueSweep(deps); // arm (suppressed)
  assert.equal(fake.calls.spawn.length, 0, "first sweep suppressed");
  now += 5000;
  await runQueueSweep(deps); // dispatch — must collapse the duplicate to ONE

  assert.equal(fake.calls.spawn.length, 1, "the duplicated key dispatches exactly once");
  assert.equal(run.active.size, 1, "exactly one assignment tracked");
  assert.ok(run.active.has("DUP-1"));
});

// ---------------------------------------------------------------------------
// (3b) §8b maxItems start-time override caps / unlimits a sweep's dispatch.
// ---------------------------------------------------------------------------

test("runQueueSweep: a maxItems-param override CAPS dispatch below the list size", async () => {
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"A"},{"id":"B"},{"id":"C"}]', // three actionable items
    spawns: [
      { id: "s-a", sessionId: 1 },
      { id: "s-b", sessionId: 2 },
      { id: "s-c", sessionId: 3 },
    ],
  });
  // Template maxItems is huge (200) + concurrency 9, so ONLY the override limits dispatch.
  const t = tmpl({ params: [{ name: "maxItems", target: "maxItems", default: "100" }] });
  const run = makeQueueRun(t, memStore(), { params: { maxItems: "1" } });
  let now = 4_000_000;
  const deps = makeQueueDeps(fake, [run], () => now);

  await runQueueSweep(deps); // arm (suppressed)
  now += 5000;
  await runQueueSweep(deps); // dispatch — capped to ONE by the override

  assert.equal(fake.calls.spawn.length, 1, "override maxItems=1 caps the sweep to one spawn");
  assert.equal(run.active.size, 1);
});

test("runQueueSweep: maxItems override '0' (unlimited) dispatches PAST the template maxItems", async () => {
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"A"},{"id":"B"},{"id":"C"}]',
    spawns: [
      { id: "s-a", sessionId: 1 },
      { id: "s-b", sessionId: 2 },
      { id: "s-c", sessionId: 3 },
    ],
  });
  // Template maxItems is only 2; the "0" override must override it to UNLIMITED so all 3 go.
  const t = tmpl({ maxItems: 2, params: [{ name: "maxItems", target: "maxItems" }] });
  const run = makeQueueRun(t, memStore(), { params: { maxItems: "0" } });
  let now = 4_500_000;
  const deps = makeQueueDeps(fake, [run], () => now);

  await runQueueSweep(deps); // arm
  now += 5000;
  await runQueueSweep(deps); // dispatch — unlimited override beats the template cap of 2

  assert.equal(fake.calls.spawn.length, 3, "unlimited override dispatches all 3 (> template maxItems 2)");
});

// ---------------------------------------------------------------------------
// (live maxItems edit) effectiveMaxItemsCap respects a run.maxItemsLive override.
// ---------------------------------------------------------------------------

test("effectiveMaxItemsCap: a live override WINS over the start-time param and template cap", () => {
  const t = tmpl({ maxItems: 2, params: [{ name: "maxItems", target: "maxItems", default: "1" }] });
  // No live edit → start-time param (1) wins over the template (2).
  const run = makeQueueRun(t, memStore(), { params: { maxItems: "1" } });
  assert.equal(effectiveMaxItemsCap(run), 1);
  // A live numeric edit wins over both.
  run.maxItemsLive = 10;
  assert.equal(effectiveMaxItemsCap(run), 10);
  // A live null edit means UNLIMITED (null), beating the finite param/template.
  run.maxItemsLive = null;
  assert.equal(effectiveMaxItemsCap(run), null);
});

test("runQueueSweep: BUMPING the live cap re-enables dispatch past an already-reached cap", async () => {
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"A"},{"id":"B"},{"id":"C"}]',
    spawns: [
      { id: "s-a", sessionId: 1 },
      { id: "s-b", sessionId: 2 },
      { id: "s-c", sessionId: 3 },
    ],
  });
  // Start capped at 1 (template huge, param caps to 1).
  const t = tmpl({ params: [{ name: "maxItems", target: "maxItems", default: "1" }] });
  const run = makeQueueRun(t, memStore(), { params: { maxItems: "1" } });
  let now = 7_500_000;
  const deps = makeQueueDeps(fake, [run], () => now);

  await runQueueSweep(deps); // arm (suppressed)
  now += 5000;
  await runQueueSweep(deps); // dispatch — capped to ONE
  assert.equal(fake.calls.spawn.length, 1, "starts capped at 1");

  // BUMP the live cap to 3 (as a set_max_items command would) — no restart.
  run.maxItemsLive = 3;
  now += 5000;
  await runQueueSweep(deps); // now dispatches the remaining two (lifetimeDispatched 1 → 3)
  assert.equal(fake.calls.spawn.length, 3, "bumping the live cap re-enables dispatch past the reached cap");
});

// ---------------------------------------------------------------------------
// (live concurrency edit + multi-tab overflow §12) effectiveConcurrency clamp,
// live bump dispatch, and overflow tabs.
// ---------------------------------------------------------------------------

test("effectiveConcurrency: a live override WINS over the template, clamped to capPerTab*MAX_QUEUE_TABS", () => {
  const t = tmpl({ concurrency: 6, grid: { cols: 3, rows: 2, fill: "columns" } }); // capPerTab 6
  const run = makeQueueRun(t, memStore());
  assert.equal(effectiveConcurrency(run), 6);
  // A live edit beats the template — and MAY exceed one grid (panes overflow to more tabs).
  run.concurrencyLive = 9;
  assert.equal(effectiveConcurrency(run), 9);
  // Clamped at the multi-tab ceiling capPerTab*MAX_QUEUE_TABS = 6*8 = 48 (a fat-finger can't
  // open hundreds of tabs).
  run.concurrencyLive = 1000;
  assert.equal(effectiveConcurrency(run), 48);
  // Floored at 1.
  run.concurrencyLive = 1;
  assert.equal(effectiveConcurrency(run), 1);
});

test("runQueueSweep: BUMPING the live concurrency dispatches MORE simultaneous agents", async () => {
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"A"},{"id":"B"},{"id":"C"}]',
    spawns: [
      { id: "s-a", sessionId: 1 },
      { id: "s-b", sessionId: 2 },
      { id: "s-c", sessionId: 3 },
    ],
  });
  // concurrency 2 → at most 2 simultaneous agents.
  const t = tmpl({ concurrency: 2, grid: { cols: 2, rows: 1, fill: "columns" } });
  const run = makeQueueRun(t, memStore());
  let now = 8_000_000;
  const deps = makeQueueDeps(fake, [run], () => now);

  await runQueueSweep(deps); // arm (suppressed)
  now += 5000;
  await runQueueSweep(deps); // dispatch — capped to 2 (concurrency)
  assert.equal(fake.calls.spawn.length, 2, "starts capped at concurrency 2");

  // BUMP the live concurrency to 3.
  run.concurrencyLive = 3;
  now += 5000;
  await runQueueSweep(deps); // the 3rd agent now dispatches
  assert.equal(fake.calls.spawn.length, 3, "raising live concurrency dispatches the 3rd agent");
});

test("runQueueSweep: concurrency ABOVE the per-tab grid OVERFLOWS to a new tab (§12)", async () => {
  // grid 2x1 = 2 panes per tab; concurrency 3 → tab 1 holds slots 0,1; slot 2 overflows to a
  // NEW tab anchored on the run's window.
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"A"},{"id":"B"},{"id":"C"}]',
    spawns: [
      { id: "s-a", sessionId: 1 },
      { id: "s-b", sessionId: 2 },
      { id: "s-c", sessionId: 3 },
    ],
  });
  const t = tmpl({ concurrency: 3, grid: { cols: 2, rows: 1, fill: "columns" } });
  const run = makeQueueRun(t, memStore());
  let now = 9_000_000;
  const deps = makeQueueDeps(fake, [run], () => now);

  await runQueueSweep(deps); // arm (suppressed)
  now += 5000;
  await runQueueSweep(deps); // dispatch all 3
  const spawns = fake.calls.spawn;
  assert.equal(spawns.length, 3, "all 3 dispatched across 2 tabs");
  // Slot 0 → the run's FIRST tab (firstTab, no window anchor). NO grid caps (a fresh tab's
  // first leaf has no grid context; largestLeafSplit isn't called).
  assert.equal(spawns[0].firstTab, true);
  assert.equal(spawns[0].windowAnchorUUID, undefined);
  assert.equal(spawns[0].maxCols, undefined, "firstTab spawn omits grid caps");
  assert.equal(spawns[0].maxRows, undefined, "firstTab spawn omits grid caps");
  // Slot 1 → balanced split WITHIN tab 1 (same tab, has a pane) — not a new tab. It forwards
  // the template grid caps (2×1) so the BSP respects the per-tab grid.
  assert.equal(spawns[1].balanced, true);
  assert.notEqual(spawns[1].targetUUID, undefined);
  assert.equal(spawns[1].firstTab, undefined);
  assert.equal(spawns[1].maxCols, 2, "balanced split forwards template grid.cols");
  assert.equal(spawns[1].maxRows, 1, "balanced split forwards template grid.rows");
  // Slot 2 → OVERFLOW: a NEW tab (firstTab:true) anchored on the run's window. NO grid caps.
  assert.equal(spawns[2].firstTab, true);
  assert.notEqual(spawns[2].windowAnchorUUID, undefined);
  assert.equal(spawns[2].maxCols, undefined, "overflow newTab spawn omits grid caps");
  assert.equal(spawns[2].maxRows, undefined, "overflow newTab spawn omits grid caps");
});

// ---------------------------------------------------------------------------
// (§12 continuous packing) packRun — merge a fragmented run's tabs.
// ---------------------------------------------------------------------------

/** A seated RUNNING assignment at a given grid slot, for packing tests. */
function seatedAsgn(key: string, uuid: string, slot: number): import("./types.js").Assignment {
  return { queueName: "Q", key, sessionID: slot + 1, surfaceUUID: uuid, gridSlot: slot, state: "RUNNING", sinceMs: 0, hero: false };
}

test("packRun: merges a fragmented run (moves the survivor into the lower tab + reassigns its slot)", async () => {
  const fake = makeQueueFake({ surfaces: [] });
  // grid 2x1 = 2 panes/tab. tab0={slot 0}, tab1={slot 2} → 1 + 1 fragmentation.
  const t = tmpl({ concurrency: 4, grid: { cols: 2, rows: 1, fill: "columns" } });
  const run = makeQueueRun(t, memStore());
  run.active.set("A", seatedAsgn("A", "uuid-a", 0)); // tab 0
  run.active.set("B", seatedAsgn("B", "uuid-b", 2)); // tab 1
  const deps = makeQueueDeps(fake, [run], () => 1000);

  const moved = await packRun(run, deps);
  assert.equal(moved, 1, "one pane moved");
  assert.equal(fake.calls.moveIntoTab.length, 1);
  assert.equal(fake.calls.moveIntoTab[0].sourceUUID, "uuid-b", "the higher tab's pane moves");
  assert.equal(fake.calls.moveIntoTab[0].targetAnchorUUID, "uuid-a", "anchored on the lower tab");
  assert.equal(fake.calls.moveIntoTab[0].balanced, true);
  // (§12 grid cap) the pack move forwards the template grid caps (2×1) so consolidating a
  // fragmented run respects the destination tab's grid.
  assert.equal(fake.calls.moveIntoTab[0].maxCols, 2, "pack move forwards template grid.cols");
  assert.equal(fake.calls.moveIntoTab[0].maxRows, 1, "pack move forwards template grid.rows");
  // B is reassigned to tab0's free slot 1 (tab membership now matches the move).
  assert.equal(run.active.get("B")!.gridSlot, 1);
});

test("packRun: no-op on a non-fragmented run (single tab) and a balanced 2+2 (cap 2 doesn't fit)", async () => {
  const fake = makeQueueFake({ surfaces: [] });
  const t = tmpl({ concurrency: 4, grid: { cols: 2, rows: 1, fill: "columns" } });
  // Single tab (slots 0,1 both in tab0) → nothing to merge.
  const single = makeQueueRun(t, memStore());
  single.active.set("A", seatedAsgn("A", "uuid-a", 0));
  single.active.set("B", seatedAsgn("B", "uuid-b", 1));
  assert.equal(await packRun(single, makeQueueDeps(fake, [single], () => 1)), 0);
  // 2+2 across two FULL tabs (cap 2): the higher tab can't fit the lower → no reshuffle.
  const balanced = makeQueueRun(t, memStore());
  balanced.active.set("A", seatedAsgn("A", "uuid-a", 0));
  balanced.active.set("B", seatedAsgn("B", "uuid-b", 1));
  balanced.active.set("C", seatedAsgn("C", "uuid-c", 2));
  balanced.active.set("D", seatedAsgn("D", "uuid-d", 3));
  assert.equal(await packRun(balanced, makeQueueDeps(fake, [balanced], () => 1)), 0);
  assert.equal(fake.calls.moveIntoTab.length, 0);
});

test("packRun: DEFERS the whole merge when a source pane is not yet seated (no UUID)", async () => {
  const fake = makeQueueFake({ surfaces: [] });
  const t = tmpl({ concurrency: 4, grid: { cols: 2, rows: 1, fill: "columns" } });
  const run = makeQueueRun(t, memStore());
  run.active.set("A", seatedAsgn("A", "uuid-a", 0)); // tab 0 (seated anchor)
  const unseated = seatedAsgn("B", "uuid-b", 2);
  unseated.surfaceUUID = undefined; // host still attaching → not movable yet
  run.active.set("B", unseated);
  assert.equal(await packRun(run, makeQueueDeps(fake, [run], () => 1)), 0);
  assert.equal(fake.calls.moveIntoTab.length, 0, "no partial move");
});

// ---------------------------------------------------------------------------
// (3c) §11 health: a sweep PUSHES a run-level status (starting on arm, then counts).
// ---------------------------------------------------------------------------

test("runQueueSweep: reports queue health — 'starting' on the arm sweep, then waiting/next", async () => {
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"A","title":"Alpha"},{"id":"B","title":"Beta"},{"id":"C"}]',
    spawns: [{ id: "s-a", sessionId: 1 }],
  });
  // maxItems override 1 so the cap is visible in the report (dispatched/cap).
  const t = tmpl({ params: [{ name: "maxItems", target: "maxItems", default: "1" }] });
  const run = makeQueueRun(t, memStore(), { params: { maxItems: "1" } });
  let now = 6_000_000;
  const deps = makeQueueDeps(fake, [run], () => now);

  await runQueueSweep(deps); // arm sweep: no list fetched yet → "starting"
  const first = fake.calls.reports.at(-1)!;
  assert.equal(first.queueName, "backlog");
  assert.equal(first.present, true);
  assert.equal(first.phase, "starting");
  assert.equal(first.maxItems, 1);

  now += 5000;
  await runQueueSweep(deps); // dispatch sweep: A dispatched (cap 1), B/C waiting
  const last = fake.calls.reports.at(-1)!;
  assert.equal(last.phase, "running");
  assert.equal(last.active, 1, "A is running");
  assert.equal(last.dispatched, 1);
  assert.equal(last.queued, 2, "B + C waiting (A excluded as active)");
  assert.deepEqual(last.next.map((n) => n.key), ["B", "C"]);
});

test("runQueueSweep: a run AT its maxItems cap still reports health (not stuck 'reading the queue…')", async () => {
  // Regression: the list fetch (which updates the §11 health cache) used to sit BEHIND the
  // `maxItemsRemaining<=0` early-return, so a run rehydrated AT its cap never fetched →
  // listOk stayed false → the bar was stuck on "reading the queue…". Now the fetch runs
  // before the dispatch gate. Pre-seed the store at cap (1/1, A active) + a live surface
  // for A, so the first dispatch sweep is at-cap from the start.
  const seeded = JSON.stringify({
    version: 1,
    records: [{
      queueName: "backlog", key: "A", sessionID: 1, gridSlot: 0,
      state: "RUNNING", sinceMs: 0, surfaceUUID: "u-a-old", title: "Alpha",
    }],
    lifetimeDispatched: 1,
    dispatched: ["A"],
  });
  const fake = makeQueueFake({
    // A is live (matched by sessionID) + B is a new actionable item that can't dispatch (cap).
    surfaces: [queueSurface({ id: "u-a-new", sessionID: 1, queueName: "backlog", queueKey: "A" })],
    listJson: '[{"id":"A","title":"Alpha"},{"id":"B","title":"Beta"}]',
    statusByKey: { A: '{"state":"working"}' },
  });
  const t = tmpl({ params: [{ name: "maxItems", target: "maxItems", default: "1" }] });
  const run = makeQueueRun(t, memStore(seeded), { params: { maxItems: "1" } });
  let now = 7_000_000;
  const deps = makeQueueDeps(fake, [run], () => now);

  await runQueueSweep(deps); // sweep 1: reconcile (adopts A) + arm (no fetch yet)
  now += 5000;
  await runQueueSweep(deps); // sweep 2: AT cap (1/1) — must STILL fetch the list for health
  const last = fake.calls.reports.at(-1)!;
  assert.equal(last.listOk, true, "at cap, the list is still fetched → not 'reading the queue…'");
  assert.notEqual(last.phase, "starting");
  assert.equal(last.dispatched, 1);
  assert.equal(last.maxItems, 1);
  assert.equal(last.active, 1, "A occupies the only slot");
  assert.equal(last.queued, 1, "B is waiting (A excluded as active/latched)");
  assert.deepEqual(last.next.map((n) => n.key), ["B"]);
});

// ---------------------------------------------------------------------------
// (4) End-to-end mocked dispatch → RUNNING → done → close cycle (§6/§10).
// ---------------------------------------------------------------------------

test("runQueueSweep: end-to-end dispatch → running → done → close → cooldown", async () => {
  // We mutate the live surface + status across sweeps to walk the state machine.
  let surfaces: Surface[] = [];
  let statusByKey: Record<string, string> = {};
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"K-1","title":"task"}]',
    spawns: [{ id: "spawned-1", sessionId: 900 }],
    statusByKey: {},
  });
  // Make list/status reflect the mutable closures.
  (fake.client as unknown as { listSurfaces: () => Promise<Surface[]> }).listSurfaces =
    async () => surfaces;
  const baseExec = fake.exec;
  const exec: Exec = async (argv: string[]) => {
    if (argv[0] === "status") {
      const key = argv[1] ?? "";
      fake.calls.status.push(key);
      return { code: 0, stdout: statusByKey[key] ?? '{"state":"working"}', stderr: "" };
    }
    return baseExec(argv, {});
  };

  const run = makeQueueRun(tmpl({ closeStableSeconds: 5 }), memStore());
  let now = 3_000_000;
  const deps: QueueDeps = {
    client: fake.client,
    exec,
    budget: new QueueBudget(8),
    now: () => now,
    registry: registryOf([run]),
    factory: noFactory,
    takeCommands: async () => [],
    maxTotal: 8,
    heroMax: 0,
    pendingGraceMs: DEFAULT_PENDING_GRACE_MS,
  };

  // Sweep 1: arm (suppressed).
  await runQueueSweep(deps);
  assert.equal(fake.calls.spawn.length, 0);

  // Sweep 2: dispatch K-1 → SPAWNED. (No live surface yet — surfaces still []. But the
  // surface IS created by the spawn; we simulate it appearing for sweep 3.)
  now += 5000;
  await runQueueSweep(deps);
  assert.equal(fake.calls.spawn.length, 1);
  assert.equal(run.active.get("K-1")!.state, "SPAWNED");

  // The spawned surface now appears in list_surfaces, working (RUNNING), and carries
  // its annotation so reconcile keeps it active by sessionID.
  surfaces = [
    queueSurface({
      id: "spawned-1",
      sessionID: 900,
      agentState: "working",
      queueKey: "K-1",
      queueName: "backlog",
    }),
  ];

  // Sweep 3: SPAWNED → RUNNING (agentState seen). Status still working (not terminal).
  now += 5000;
  await runQueueSweep(deps);
  assert.equal(run.active.get("K-1")!.state, "RUNNING");

  // Sweep 4: provider status goes terminal → RUNNING → DONE_PENDING.
  statusByKey = { "K-1": '{"state":"done"}' };
  now += 5000;
  await runQueueSweep(deps);
  assert.equal(run.active.get("K-1")!.state, "DONE_PENDING");

  // Now the agent reports idle; the idle anchor starts. Not stable long enough yet.
  surfaces = [
    queueSurface({
      id: "spawned-1",
      sessionID: 900,
      agentState: "idle",
      queueKey: "K-1",
      queueName: "backlog",
    }),
  ];
  now += 1000; // only 1s of idle < closeStableSeconds(5s)
  await runQueueSweep(deps);
  assert.equal(run.active.get("K-1")!.state, "DONE_PENDING", "not closed before stable-idle window");

  // Sweep: idle held > 5s → DONE_PENDING → CLOSING → close sequence begins. Per §10 the
  // exit keys are sent THIS sweep but force-close is DEFERRED (the child is given time to
  // exit cleanly — the loop polls `exited` across sweeps, never blocks).
  now += 6000;
  await runQueueSweep(deps);
  assert.deepEqual(
    fake.calls.sendKey,
    [{ id: "spawned-1", key: "ctrl-d" }],
    "exit key sent on entering CLOSING",
  );
  assert.equal(fake.calls.forceClose.length, 0, "force-close DEFERRED — child not yet exited");
  assert.equal(run.active.get("K-1")!.state, "CLOSING", "still CLOSING, awaiting child exit");

  // The child now exits in response to the exit key; the next sweep observes
  // `exited === true` and force-closes (confirm-bypass) → cooldown.
  surfaces = [
    queueSurface({
      id: "spawned-1",
      sessionID: 900,
      agentState: "idle",
      exited: true,
      queueKey: "K-1",
      queueName: "backlog",
    }),
  ];
  now += 1000;
  await runQueueSweep(deps);
  // The exit key was sent ONCE (not re-sent), and the force-close fired after the child
  // exited.
  assert.deepEqual(fake.calls.sendKey, [{ id: "spawned-1", key: "ctrl-d" }], "exit key sent only once");
  assert.deepEqual(fake.calls.forceClose, ["spawned-1"], "force-close after the child exited");
  // The key is gone from active and is now in cooldown.
  assert.equal(run.active.has("K-1"), false, "closed key removed from active");
  assert.ok(run.cooldown.has("K-1"), "closed key entered cooldown");
});

// ---------------------------------------------------------------------------
// (4a) closeOnComplete=false: a DONE_PENDING + stably-idle agent is NEVER auto-closed
//      — the completed split is left open for manual close (§5/§6/§10, acceptance #6).
// ---------------------------------------------------------------------------

test("runQueueSweep: closeOnComplete=false leaves a done+stably-idle split OPEN (no close sequence)", async () => {
  let surfaces: Surface[] = [];
  let statusByKey: Record<string, string> = {};
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"K-1","title":"task"}]',
    spawns: [{ id: "spawned-1", sessionId: 900 }],
  });
  (fake.client as unknown as { listSurfaces: () => Promise<Surface[]> }).listSurfaces =
    async () => surfaces;
  const baseExec = fake.exec;
  const exec: Exec = async (argv: string[]) => {
    if (argv[0] === "status") {
      const key = argv[1] ?? "";
      fake.calls.status.push(key);
      return { code: 0, stdout: statusByKey[key] ?? '{"state":"working"}', stderr: "" };
    }
    return baseExec(argv, {});
  };

  // closeOnComplete OFF — the opt-out the blocker fix threads through the gate.
  const run = makeQueueRun(tmpl({ closeStableSeconds: 5, closeOnComplete: false }), memStore());
  let now = 11_500_000;
  const deps: QueueDeps = {
    client: fake.client,
    exec,
    budget: new QueueBudget(8),
    now: () => now,
    registry: registryOf([run]),
    factory: noFactory,
    takeCommands: async () => [],
    maxTotal: 8,
    heroMax: 0,
    pendingGraceMs: DEFAULT_PENDING_GRACE_MS,
  };

  await runQueueSweep(deps); // arm
  now += 5000;
  await runQueueSweep(deps); // dispatch K-1 → SPAWNED
  assert.equal(run.active.get("K-1")!.state, "SPAWNED");

  surfaces = [
    queueSurface({ id: "spawned-1", sessionID: 900, agentState: "working", queueKey: "K-1", queueName: "backlog" }),
  ];
  now += 5000;
  await runQueueSweep(deps); // → RUNNING
  statusByKey = { "K-1": '{"state":"done"}' };
  now += 5000;
  await runQueueSweep(deps); // → DONE_PENDING
  assert.equal(run.active.get("K-1")!.state, "DONE_PENDING");

  // The agent goes idle and STAYS idle well past closeStableSeconds — with auto-close
  // ON this would close; with closeOnComplete=false it must HOLD in DONE_PENDING and
  // never send exit keys or force-close.
  surfaces = [
    queueSurface({ id: "spawned-1", sessionID: 900, agentState: "idle", queueKey: "K-1", queueName: "backlog" }),
  ];
  now += 1000;
  await runQueueSweep(deps); // idle anchor starts
  now += 60000; // far past the stable window
  await runQueueSweep(deps);

  assert.equal(run.active.get("K-1")!.state, "DONE_PENDING", "held in DONE_PENDING — never advanced to CLOSING");
  assert.equal(fake.calls.sendKey.length, 0, "no exit keys sent (close sequence never runs)");
  assert.equal(fake.calls.forceClose.length, 0, "the completed split is left OPEN for manual close");
  assert.equal(run.active.has("K-1"), true, "the assignment is still tracked (slot held)");
  assert.equal(run.cooldown.has("K-1"), false, "not closed → no cooldown");
});

// ---------------------------------------------------------------------------
// (keep) A per-split set_keep PIN holds a done+stably-idle split OPEN (no close), stamps
//        the keep flag onto the annotation, and survives across a fresh run on the same store.
// ---------------------------------------------------------------------------

test("runQueueSweep: a set_keep PIN holds a done+idle split OPEN and stamps keep:true on the annotation", async () => {
  let surfaces: Surface[] = [];
  let statusByKey: Record<string, string> = {};
  let pending: QueueCommand[] = [];
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"K-1","title":"task"}]',
    spawns: [{ id: "spawned-1", sessionId: 900 }],
  });
  (fake.client as unknown as { listSurfaces: () => Promise<Surface[]> }).listSurfaces =
    async () => surfaces;
  const baseExec = fake.exec;
  const exec: Exec = async (argv: string[]) => {
    if (argv[0] === "status") {
      const key = argv[1] ?? "";
      fake.calls.status.push(key);
      return { code: 0, stdout: statusByKey[key] ?? '{"state":"working"}', stderr: "" };
    }
    return baseExec(argv, {});
  };

  // Default template (auto-close ON, keepOnComplete OFF) — only the per-split pin keeps it.
  const store = memStore();
  const run = makeQueueRun(tmpl({ closeStableSeconds: 5 }), store);
  let now = 11_500_000;
  const deps: QueueDeps = {
    client: fake.client,
    exec,
    budget: new QueueBudget(8),
    now: () => now,
    registry: registryOf([run]),
    factory: noFactory,
    takeCommands: async () => {
      const c = pending;
      pending = [];
      return c;
    },
    maxTotal: 8,
    heroMax: 0,
    pendingGraceMs: DEFAULT_PENDING_GRACE_MS,
  };

  await runQueueSweep(deps); // arm
  now += 5000;
  await runQueueSweep(deps); // dispatch K-1 → SPAWNED
  surfaces = [
    queueSurface({ id: "spawned-1", sessionID: 900, agentState: "working", queueKey: "K-1", queueName: "backlog" }),
  ];
  now += 5000;
  await runQueueSweep(deps); // → RUNNING
  statusByKey = { "K-1": '{"state":"done"}' };
  now += 5000;
  await runQueueSweep(deps); // → DONE_PENDING
  assert.equal(run.active.get("K-1")!.state, "DONE_PENDING");

  // PIN the split via a set_keep command (the dashboard 📌 toggle).
  pending = [{ action: "set_keep", run: "backlog", key: "K-1", keep: true }];
  surfaces = [
    queueSurface({ id: "spawned-1", sessionID: 900, agentState: "idle", queueKey: "K-1", queueName: "backlog" }),
  ];
  now += 1000;
  await runQueueSweep(deps); // command applied; idle anchor starts
  assert.equal(run.keep.get("K-1"), true, "the pin set the per-split keep override");
  now += 60000; // far past the stable window — would normally close
  await runQueueSweep(deps);

  assert.equal(run.active.get("K-1")!.state, "DONE_PENDING", "kept — held in DONE_PENDING, never CLOSING");
  assert.equal(fake.calls.sendKey.length, 0, "no exit keys sent (close sequence never runs)");
  assert.equal(fake.calls.forceClose.length, 0, "the kept split is left OPEN for manual work");
  // The latest annotation stamp for K-1 carries keep:true so the dashboard pin reflects it.
  const k1Annotates = fake.calls.annotate.filter((a) => a.ann.queueKey === "K-1");
  assert.ok(k1Annotates.length > 0, "K-1 was annotated");
  assert.equal(k1Annotates[k1Annotates.length - 1].ann.keep, true, "annotation stamps keep:true");

  // The keep override is persisted to the per-run store so it survives a restart.
  assert.deepEqual(loadKeep(store), { "K-1": true }, "keep persisted to the per-run store");
});

test("runQueueSweep: keepOnComplete=true template default keeps a done+idle split OPEN (no per-split pin)", async () => {
  let surfaces: Surface[] = [];
  let statusByKey: Record<string, string> = {};
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"K-1","title":"task"}]',
    spawns: [{ id: "spawned-1", sessionId: 900 }],
  });
  (fake.client as unknown as { listSurfaces: () => Promise<Surface[]> }).listSurfaces =
    async () => surfaces;
  const baseExec = fake.exec;
  const exec: Exec = async (argv: string[]) => {
    if (argv[0] === "status") {
      const key = argv[1] ?? "";
      fake.calls.status.push(key);
      return { code: 0, stdout: statusByKey[key] ?? '{"state":"working"}', stderr: "" };
    }
    return baseExec(argv, {});
  };

  const run = makeQueueRun(tmpl({ closeStableSeconds: 5, keepOnComplete: true }), memStore());
  let now = 12_000_000;
  const deps: QueueDeps = {
    client: fake.client,
    exec,
    budget: new QueueBudget(8),
    now: () => now,
    registry: registryOf([run]),
    factory: noFactory,
    takeCommands: async () => [],
    maxTotal: 8,
    heroMax: 0,
    pendingGraceMs: DEFAULT_PENDING_GRACE_MS,
  };

  await runQueueSweep(deps); // arm
  now += 5000;
  await runQueueSweep(deps); // dispatch → SPAWNED
  surfaces = [
    queueSurface({ id: "spawned-1", sessionID: 900, agentState: "working", queueKey: "K-1", queueName: "backlog" }),
  ];
  now += 5000;
  await runQueueSweep(deps); // → RUNNING
  statusByKey = { "K-1": '{"state":"done"}' };
  now += 5000;
  await runQueueSweep(deps); // → DONE_PENDING
  surfaces = [
    queueSurface({ id: "spawned-1", sessionID: 900, agentState: "idle", queueKey: "K-1", queueName: "backlog" }),
  ];
  now += 1000;
  await runQueueSweep(deps);
  now += 60000;
  await runQueueSweep(deps);

  assert.equal(run.active.get("K-1")!.state, "DONE_PENDING", "kept by template default — never auto-closed");
  assert.equal(fake.calls.forceClose.length, 0, "no force-close");
  const k1 = fake.calls.annotate.filter((a) => a.ann.queueKey === "K-1");
  assert.equal(k1[k1.length - 1].ann.keep, true, "annotation stamps keep:true from the template default");
});

test("runQueueSweep: a keep override rehydrates from the per-run store on a fresh run (restart)", async () => {
  // Persist a keep override, then start a FRESH run object on the SAME store (a sidecar/GUI
  // restart) — its first reconcile must rehydrate the override so the split stays kept.
  const store = memStore();
  store.write(JSON.stringify({ version: 1, records: [], lifetimeDispatched: 0, dispatched: [], keep: { "K-9": true } }));

  const fake = makeQueueFake({ surfaces: [], listJson: "[]", spawns: [] });
  (fake.client as unknown as { listSurfaces: () => Promise<Surface[]> }).listSurfaces =
    async () => [];
  const run = makeQueueRun(tmpl(), store);
  let now = 13_000_000;
  const deps: QueueDeps = {
    client: fake.client,
    exec: fake.exec,
    budget: new QueueBudget(8),
    now: () => now,
    registry: registryOf([run]),
    factory: noFactory,
    takeCommands: async () => [],
    maxTotal: 8,
    heroMax: 0,
    pendingGraceMs: DEFAULT_PENDING_GRACE_MS,
  };

  await runQueueSweep(deps); // first sweep reconciles + rehydrates keep
  assert.equal(run.keep.get("K-9"), true, "the keep override rehydrated from the per-run store");
});

// ---------------------------------------------------------------------------
// (4b) The close sequence's awaitExited is BOUNDED: a child that never reports
//      `exited` is force-closed once `awaitExitedMs` elapses (§10 timeout fallback).
// ---------------------------------------------------------------------------

test("runQueueSweep: awaitExited is bounded — force-closes after the timeout even if the child never exits", async () => {
  let surfaces: Surface[] = [];
  let statusByKey: Record<string, string> = {};
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"K-1","title":"task"}]',
    spawns: [{ id: "spawned-1", sessionId: 900 }],
  });
  (fake.client as unknown as { listSurfaces: () => Promise<Surface[]> }).listSurfaces =
    async () => surfaces;
  const baseExec = fake.exec;
  const exec: Exec = async (argv: string[]) => {
    if (argv[0] === "status") {
      const key = argv[1] ?? "";
      fake.calls.status.push(key);
      return { code: 0, stdout: statusByKey[key] ?? '{"state":"working"}', stderr: "" };
    }
    return baseExec(argv, {});
  };

  const run = makeQueueRun(tmpl({ closeStableSeconds: 5 }), memStore());
  let now = 6_000_000;
  const deps: QueueDeps = {
    client: fake.client,
    exec,
    budget: new QueueBudget(8),
    now: () => now,
    registry: registryOf([run]),
    factory: noFactory,
    takeCommands: async () => [],
    maxTotal: 8,
    heroMax: 0,
    pendingGraceMs: DEFAULT_PENDING_GRACE_MS,
    awaitExitedMs: 10_000, // explicit bound for the test
  };

  await runQueueSweep(deps); // arm
  now += 5000;
  await runQueueSweep(deps); // dispatch
  // Surface appears, working → done → idle, walked quickly to CLOSING.
  surfaces = [
    queueSurface({ id: "spawned-1", sessionID: 900, agentState: "working", queueKey: "K-1", queueName: "backlog" }),
  ];
  now += 5000;
  await runQueueSweep(deps); // → RUNNING
  statusByKey = { "K-1": '{"state":"done"}' };
  now += 5000;
  await runQueueSweep(deps); // → DONE_PENDING
  // Idle anchor starts (not yet held long enough).
  surfaces = [
    queueSurface({ id: "spawned-1", sessionID: 900, agentState: "idle", queueKey: "K-1", queueName: "backlog" }),
  ];
  now += 1000;
  await runQueueSweep(deps); // 1s idle < 5s → still DONE_PENDING
  assert.equal(run.active.get("K-1")!.state, "DONE_PENDING");
  now += 6000;
  await runQueueSweep(deps); // idle held > 5s → CLOSING; exit key sent; force-close deferred
  assert.equal(fake.calls.forceClose.length, 0, "force-close deferred while awaiting exit");
  assert.equal(run.active.get("K-1")!.state, "CLOSING");

  // The child NEVER exits (still no `exited`). Within the await window: still deferred.
  now += 5000; // 5s < 10s bound
  await runQueueSweep(deps);
  assert.equal(fake.calls.forceClose.length, 0, "still within await window → not yet force-closed");

  // Past the bound (now >10s since exit keys) → force-close anyway (timeout fallback).
  now += 6000; // total ~11s since exit keys
  await runQueueSweep(deps);
  assert.deepEqual(fake.calls.forceClose, ["spawned-1"], "force-closed after await timeout");
  assert.deepEqual(fake.calls.sendKey, [{ id: "spawned-1", key: "ctrl-d" }], "exit key sent exactly once");
  assert.equal(run.active.has("K-1"), false, "closed key removed from active");
  assert.ok(run.cooldown.has("K-1"), "closed key entered cooldown");
});

// ---------------------------------------------------------------------------
// (5) EXITED (early) triggers signal_attention and frees the slot (§6).
// ---------------------------------------------------------------------------

test("runQueueSweep: an agent that EXITS early rings the bell (signal_attention) and frees the slot", async () => {
  let surfaces: Surface[] = [];
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"K-1","title":"task"}]',
    spawns: [{ id: "spawned-1", sessionId: 900 }],
  });
  (fake.client as unknown as { listSurfaces: () => Promise<Surface[]> }).listSurfaces =
    async () => surfaces;

  const run = makeQueueRun(tmpl(), memStore());
  let now = 4_000_000;
  const deps = makeQueueDeps(fake, [run], () => now);

  await runQueueSweep(deps); // arm
  now += 5000;
  await runQueueSweep(deps); // dispatch K-1
  assert.equal(run.active.get("K-1")!.state, "SPAWNED");

  // The spawned surface appears but its child EXITED early (before completion).
  surfaces = [
    queueSurface({
      id: "spawned-1",
      sessionID: 900,
      exited: true,
      agentState: "working",
      queueKey: "K-1",
      queueName: "backlog",
    }),
  ];
  now += 5000;
  await runQueueSweep(deps);

  // leave-and-bell: bell rung, slot FREED (EXITED excluded from occupancy) but the
  // assignment is KEPT in EXITED state so its key is NOT silently re-dispatched, and the
  // dead split is NOT auto-closed (kept for human review).
  assert.equal(fake.calls.signal.length, 1, "signal_attention fired on early exit");
  assert.equal(fake.calls.signal[0].id, "spawned-1");
  assert.equal(run.active.get("K-1")?.state, "EXITED", "kept in EXITED (key blocks re-dispatch)");
  assert.equal(fake.calls.spawn.length, 1, "NOT auto-re-queued (still just the one dispatch)");
  assert.equal(fake.calls.forceClose.length, 0, "the dead split is NOT auto-closed");
});

// ---------------------------------------------------------------------------
// (5a) A human closing an EXITED (leave-and-bell) split frees the key to COOLDOWN, not
//      immediate eligibility (§6) — so a stale `list` can't instantly re-dispatch the
//      same still-failing item before the cooldown hold elapses.
// ---------------------------------------------------------------------------

test("runQueueSweep: a crashed (EXITED) split's key is COOLED then LATCHED — NOT re-dispatched until it leaves the list and returns (§7.1)", async () => {
  let surfaces: Surface[] = [];
  // Mutable spec so the `list` provider's output can change mid-test (the item leaving /
  // returning to the actionable set is what re-arms the §7.1 dispatch latch).
  const spec = {
    surfaces: [] as Surface[],
    listJson: '[{"id":"K-1","title":"task"}]',
    spawns: [
      { id: "spawned-1", sessionId: 900 },
      { id: "spawned-2", sessionId: 901 },
    ],
  };
  const fake = makeQueueFake(spec);
  (fake.client as unknown as { listSurfaces: () => Promise<Surface[]> }).listSurfaces =
    async () => surfaces;

  const run = makeQueueRun(tmpl(), memStore());
  let now = 4_500_000;
  const deps = makeQueueDeps(fake, [run], () => now);

  await runQueueSweep(deps); // arm
  now += 5000;
  await runQueueSweep(deps); // dispatch K-1
  assert.ok(run.dispatched.has("K-1"), "K-1 latched at dispatch");

  // The spawned surface appears but EXITS early (leave-and-bell).
  surfaces = [
    queueSurface({ id: "spawned-1", sessionID: 900, exited: true, agentState: "working", queueKey: "K-1", queueName: "backlog" }),
  ];
  now += 5000;
  await runQueueSweep(deps);
  assert.equal(run.active.get("K-1")?.state, "EXITED", "kept in EXITED");
  assert.equal(run.cooldown.has("K-1"), false, "not cooled while the split is still open");

  // A human closes the dead split → its session vanishes → reconcile prunes the EXITED
  // record. Per §6 the freed key enters COOLDOWN; per §7.1 it ALSO stays in the dispatch
  // latch (K-1 is still in the list — it never left the actionable set).
  surfaces = [];
  now += 5000;
  await runQueueSweep(deps);
  assert.equal(run.active.has("K-1"), false, "EXITED record pruned after the human closed it");
  assert.ok(run.cooldown.has("K-1"), "freed key entered COOLDOWN");
  assert.ok(run.dispatched.has("K-1"), "still latched (K-1 never left the list)");
  assert.equal(fake.calls.spawn.length, 1, "K-1 NOT re-dispatched while cooling/latched");

  // Cooldown elapses, but K-1 is STILL in the list → the §7.1 latch keeps it suppressed.
  // (This is the behavior change: cooldown alone no longer re-dispatches an item that
  // never left the list — a crashed agent is not blindly auto-retried.)
  now += 130_000; // > DEFAULT_COOLDOWN_MS (120s)
  await runQueueSweep(deps);
  assert.equal(fake.calls.spawn.length, 1, "still NOT re-dispatched — the latch outlives the cooldown while K-1 stays listed");
  assert.ok(run.dispatched.has("K-1"), "latch still held");

  // K-1 LEAVES the actionable list (e.g. moved off the queried state) for a sweep → the
  // latch RE-ARMS (clears). An empty list never removes the run (no auto-quit).
  spec.listJson = "[]";
  now += 5000;
  await runQueueSweep(deps);
  assert.equal(run.dispatched.has("K-1"), false, "latch re-armed once K-1 left the list");
  assert.equal(fake.calls.spawn.length, 1, "nothing dispatched on the empty list");

  // K-1 RETURNS to the list (a real status round-trip) → now eligible → re-dispatched.
  spec.listJson = '[{"id":"K-1","title":"task"}]';
  now += 5000;
  await runQueueSweep(deps);
  assert.equal(fake.calls.spawn.length, 2, "re-dispatched only after K-1 left the list and returned");
});

test("runQueueSweep: a split KILLED BEFORE the agent claims (item still listed, NO cooldown) is NOT re-dispatched until a list round-trip (§7.1 — the kill-before-claim hole)", async () => {
  let surfaces: Surface[] = [];
  const spec = {
    surfaces: [] as Surface[],
    listJson: '[{"id":"K-1","title":"task"}]',
    spawns: [
      { id: "spawned-1", sessionId: 700 },
      { id: "spawned-2", sessionId: 701 },
    ],
  };
  const fake = makeQueueFake(spec);
  (fake.client as unknown as { listSurfaces: () => Promise<Surface[]> }).listSurfaces =
    async () => surfaces;

  const run = makeQueueRun(tmpl(), memStore());
  let now = 6_000_000;
  const deps = makeQueueDeps(fake, [run], () => now);

  await runQueueSweep(deps); // arm
  now += 5000;
  await runQueueSweep(deps); // dispatch K-1
  assert.equal(fake.calls.spawn.length, 1);
  assert.ok(run.dispatched.has("K-1"), "latched at dispatch");

  // The agent is up and WORKING but has NOT claimed (the human-gated dispatch→claim gap),
  // so the item is STILL in the list. The user kills the split before confirming. A killed
  // WORKING (non-EXITED) record is session-gone-pruned with NO cooldown — so ONLY the
  // §7.1 latch can suppress re-dispatch here (this is precisely the hole the latch closes).
  surfaces = [
    queueSurface({ id: "spawned-1", sessionID: 700, agentState: "working", queueKey: "K-1", queueName: "backlog" }),
  ];
  now += 5000;
  await runQueueSweep(deps); // observe it live + working

  surfaces = []; // user killed it
  now += 200_000; // well past any cooldown/grace window — proves it's the latch, not a timer
  await runQueueSweep(deps);
  assert.equal(run.active.has("K-1"), false, "killed record pruned (empty active set)");
  assert.equal(run.cooldown.has("K-1"), false, "no cooldown for a killed working agent — only the latch holds it");
  assert.ok(run.dispatched.has("K-1"), "still latched (K-1 never left the list)");
  assert.equal(fake.calls.spawn.length, 1, "NOT re-dispatched despite an empty active set AND no cooldown");

  // K-1 leaves the list, then returns (the only re-arm path) → re-dispatched.
  spec.listJson = "[]";
  now += 5000;
  await runQueueSweep(deps);
  assert.equal(run.dispatched.has("K-1"), false, "latch re-armed when K-1 left the list");
  spec.listJson = '[{"id":"K-1","title":"task"}]';
  now += 5000;
  await runQueueSweep(deps);
  assert.equal(fake.calls.spawn.length, 2, "re-dispatched only after the list round-trip");
});

test("runQueueSweep: the dispatched latch PERSISTS across a sidecar restart (a killed-before-claim item isn't re-grabbed after restart)", async () => {
  const store = memStore(); // ONE store, shared across the simulated restart
  const spec = {
    surfaces: [] as Surface[],
    listJson: '[{"id":"K-1","title":"task"}]',
    spawns: [
      { id: "spawned-1", sessionId: 800 },
      { id: "spawned-2", sessionId: 801 },
    ],
  };
  const fake = makeQueueFake(spec);
  let surfaces: Surface[] = [];
  (fake.client as unknown as { listSurfaces: () => Promise<Surface[]> }).listSurfaces =
    async () => surfaces;

  // --- run #1: dispatch K-1, then the user kills it before claim ---
  const run1 = makeQueueRun(tmpl(), store);
  let now = 7_000_000;
  let deps = makeQueueDeps(fake, [run1], () => now);
  await runQueueSweep(deps); // arm
  now += 5000;
  await runQueueSweep(deps); // dispatch K-1
  assert.equal(fake.calls.spawn.length, 1);
  assert.ok(run1.dispatched.has("K-1"), "latched (and persisted) at dispatch");
  surfaces = []; // user kills the split

  // --- SIDECAR RESTART: a brand-new run over the SAME persisted store ---
  const run2 = makeQueueRun(tmpl(), store);
  deps = makeQueueDeps(fake, [run2], () => now);
  // First post-restart sweep: reconcile stamps reconcileStartedMs (now), rehydrates the
  // latch, and SHIELDS the killed record for graceMs after restart (the premature-prune
  // fix: a transient/incomplete post-restart list_surfaces must not be mistaken for a kill).
  await runQueueSweep(deps);
  assert.ok(run2.dispatched.has("K-1"), "latch rehydrated from the store on restart");
  assert.equal(run2.active.has("K-1"), true, "killed record HELD within the post-restart grace (not pruned yet)");
  // Advance PAST the reconcile-start grace → the genuinely-gone record is now pruned,
  // isolating the latch as the sole re-dispatch suppressor.
  now += 200_000;
  await runQueueSweep(deps); // dispatch-armed; reconcile prunes K-1; K-1 still listed → latch suppresses
  assert.equal(run2.active.has("K-1"), false, "killed record pruned once past the restart grace — only the latch remains");
  assert.equal(fake.calls.spawn.length, 1, "NOT re-dispatched after restart (the latch persisted)");
});

// ---------------------------------------------------------------------------
// (6) maxTotal caps the whole fleet across runs.
// ---------------------------------------------------------------------------

test("runQueueSweep: agent-queue-max-total caps total dispatches across runs", async () => {
  // Two runs, each listing 3 candidates, but maxTotal = 2 → only 2 spawns total.
  const fakeA = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"A-1"},{"id":"A-2"},{"id":"A-3"}]',
  });
  // One shared client/exec wouldn't distinguish runs, so build per-run fakes but share
  // a single budget via the deps. Simpler: one fake, two runs with distinct names; the
  // list returns A-keys for both (fine — keys differ only by run's active map).
  const runA = makeQueueRun(tmpl({ name: "A" }), memStore());
  const runB = makeQueueRun(tmpl({ name: "B" }), memStore());
  let now = 5_000_000;
  const deps = makeQueueDeps(fakeA, [runA, runB], () => now, 2);

  await runQueueSweep(deps); // arm both
  now += 5000;
  await runQueueSweep(deps); // dispatch — capped at maxTotal across the two runs

  assert.equal(fakeA.calls.spawn.length, 2, "global maxTotal(2) capped the fleet across runs");
});

test("runQueueSweep: maxTotal = Infinity (unlimited) imposes no fleet cap — bounded only by per-run concurrency", async () => {
  // Same two-run setup as the cap test, but with the new default: an UNLIMITED
  // fleet (maxTotal = Infinity). Each run lists 3 candidates and has ample
  // concurrency (tmpl default 9), so all 6 dispatch — the global cap never binds.
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"A-1"},{"id":"A-2"},{"id":"A-3"}]',
  });
  const runA = makeQueueRun(tmpl({ name: "A" }), memStore());
  const runB = makeQueueRun(tmpl({ name: "B" }), memStore());
  let now = 5_000_000;
  const deps = makeQueueDeps(fake, [runA, runB], () => now, Infinity);

  await runQueueSweep(deps); // arm both
  now += 5000;
  await runQueueSweep(deps); // dispatch — no global ceiling

  assert.equal(fake.calls.spawn.length, 6, "unlimited maxTotal dispatched both runs' full lists");
});

// ---------------------------------------------------------------------------
// (6b) §8b START-TIME PARAMS: a run's params are injected into the provider command env.
// ---------------------------------------------------------------------------

test("runQueueSweep: start-time params (§8b) are injected into the provider list env (answer > default)", async () => {
  const t = tmpl();
  t.params = [
    { name: "project", env: "LINEAR_PROJECT" },
    { name: "ms", env: "LINEAR_MILESTONES", default: "VP" }, // no answer → default flows
  ];
  let listEnv: Record<string, string> | undefined;
  // Custom exec captures the env handed to the `list` provider call.
  const exec: Exec = async (argv, opts) => {
    if (argv[0] === "list") {
      listEnv = opts.env;
      return { code: 0, stdout: "[]", stderr: "" };
    }
    return { code: 0, stdout: '{"state":"x"}', stderr: "" };
  };
  const fake = makeQueueFake({ surfaces: [], listJson: "[]" });
  const run = makeQueueRun(t, memStore(), { params: { project: "Acme" } });
  let now = 8_500_000;
  const deps = makeQueueDeps(fake, [run], () => now, 8, { exec });

  await runQueueSweep(deps); // arm
  now += 5000;
  await runQueueSweep(deps); // dispatch sweep fetches the list WITH the params env

  assert.deepEqual(
    listEnv,
    { LINEAR_PROJECT: "Acme", LINEAR_MILESTONES: "VP" },
    "the user's answer overrides; an unanswered param falls back to its default",
  );
});

// ---------------------------------------------------------------------------
// (6a) The queue's OWN ConcurrencyBudget actually BOUNDS a single batch: a budget of 1
//      caps a multi-candidate batch to one dispatch in a sweep (then it acquires again
//      next sweep). Proves the per-candidate acquire is a real bound, not decorative.
// ---------------------------------------------------------------------------

test("runQueueSweep: a too-small queue budget bounds the dispatch batch within a sweep", async () => {
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"B-1"},{"id":"B-2"},{"id":"B-3"}]',
  });
  // Slots/grid/maxItems all allow 3; only the budget (1) should bind the batch.
  const run = makeQueueRun(tmpl(), memStore());
  let now = 5_500_000;
  const deps: QueueDeps = {
    client: fake.client,
    exec: fake.exec,
    budget: new QueueBudget(1), // batch bound = 1 acquisition at a time
    now: () => now,
    registry: registryOf([run]),
    factory: noFactory,
    takeCommands: async () => [],
    maxTotal: 8,
    heroMax: 0,
    pendingGraceMs: DEFAULT_PENDING_GRACE_MS,
  };

  await runQueueSweep(deps); // arm
  now += 5000;
  await runQueueSweep(deps); // sweep dispatches — budget 1 caps the batch to ONE
  assert.equal(fake.calls.spawn.length, 1, "budget(1) bounded this sweep's batch to one dispatch");
  assert.equal(deps.budget.active, 0, "budget released after the bounded batch");

  // Next sweep re-acquires and dispatches the next candidate (the bound is per-sweep,
  // not permanent — the budget is released in finally).
  now += 5000;
  await runQueueSweep(deps);
  assert.equal(fake.calls.spawn.length, 2, "the next sweep dispatches another under the same budget");
});

// ---------------------------------------------------------------------------
// (7) §13 INJECTION: a hostile item title rides the command ONLY inside a single-quoted
//     env-assignment prefix (so it can't break out), with the template appended VERBATIM;
//     it ALSO rides the env field. A `'`-containing title is the breakout attempt.
// ---------------------------------------------------------------------------

test("runQueueSweep: a hostile item title is single-quote-escaped in the command prefix (no injection) + appended template is verbatim", async () => {
  // A single-quote breakout attempt — the worst case for the single-quoted prefix.
  const hostileTitle = "'; rm -rf ~; echo '";
  const item = { key: "K-1", title: hostileTitle, url: "http://x/K-1" };
  const fake = makeQueueFake({
    surfaces: [],
    listJson: JSON.stringify([{ id: "K-1", title: hostileTitle, url: "http://x/K-1" }]),
    spawns: [{ id: "spawned-1", sessionId: 501 }],
  });
  const run = makeQueueRun(tmpl(), memStore());
  let now = 7_000_000;
  const deps = makeQueueDeps(fake, [run], () => now);

  await runQueueSweep(deps); // arm
  now += 5000;
  await runQueueSweep(deps); // dispatch

  assert.equal(fake.calls.spawn.length, 1);
  const command = fake.calls.spawn[0].command as string;
  // (a) The command is EXACTLY the safe prefix + the verbatim template (no naive splice).
  assert.equal(command, shellEnvPrefix(item) + "claude work");
  // (b) The template launch line is appended UNALTERED.
  assert.ok(command.endsWith("claude work"), "template appended verbatim");
  // (c) The hostile bytes appear ONLY inside a single-quoted literal — the breakout `'`
  //     is escaped as '\'' so the shell can't terminate the quote and run `rm`.
  assert.ok(command.includes("GHOSTTY_ITEM_TITLE='"), "title is inside a single-quoted assignment");
  assert.ok(command.includes("'\\''"), "the embedded single quote is escaped");
  // (d) The title still rides the env field too (for the .exec backend), verbatim.
  const env = fake.calls.spawn[0].env as Record<string, string>;
  assert.equal(env.GHOSTTY_ITEM_TITLE, hostileTitle, "title delivered verbatim as env data");
  assert.equal(env.GHOSTTY_ITEM_KEY, "K-1");
});

// ---------------------------------------------------------------------------
// (8) maxItems is a TRUE LIFETIME cap that survives a sidecar restart (§7). The
//     monotonic counter is persisted as a top-level store field and rehydrated on the
//     first reconcile, so completed+pruned dispatches still count against the budget.
// ---------------------------------------------------------------------------

test("runQueueSweep: maxItems lifetime cap survives a sidecar restart (rehydrated from the store)", async () => {
  // A shared store the FIRST run writes and the SECOND (restarted) run reads.
  const store = memStore();
  // maxItems = 1: the very first run dispatches one item, consuming the lifetime budget.
  const fake1 = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"K-1"}]',
    spawns: [{ id: "spawned-1", sessionId: 901 }],
  });
  const run1 = makeQueueRun(tmpl({ maxItems: 1 }), store);
  let now = 8_000_000;
  const deps1 = makeQueueDeps(fake1, [run1], () => now);
  await runQueueSweep(deps1); // arm
  now += 5000;
  await runQueueSweep(deps1); // dispatch K-1 (lifetime now 1 == maxItems)
  assert.equal(fake1.calls.spawn.length, 1, "first run dispatched its one allowed item");
  assert.equal(run1.lifetimeDispatched, 1);

  // SIMULATE a sidecar restart: the surface vanished (host restart / closed), so its
  // record is pruned on reconcile and the live fleet is empty — but the persisted
  // lifetime counter MUST still cap a fresh run at maxItems=1 (no new dispatch).
  const fake2 = makeQueueFake({
    surfaces: [], // the prior surface is gone → record prunes, fleet empty
    listJson: '[{"id":"K-2"}]', // a NEW eligible candidate appears
    spawns: [{ id: "spawned-2", sessionId: 902 }],
  });
  const run2 = makeQueueRun(tmpl({ maxItems: 1 }), store); // SAME store
  const deps2 = makeQueueDeps(fake2, [run2], () => now);
  await runQueueSweep(deps2); // arm + reconcile (rehydrates lifetimeDispatched=1 from store)
  assert.equal(run2.lifetimeDispatched, 1, "lifetime counter rehydrated from the persisted store");
  now += 5000;
  await runQueueSweep(deps2); // would dispatch K-2 — but the lifetime cap is already spent
  assert.equal(fake2.calls.spawn.length, 0, "maxItems lifetime cap held across the restart");
});

// ---------------------------------------------------------------------------
// (9) Dispatch AFTER an orphan adoption SPLITS INTO the adopted pane's tab (§9/§12).
//     An adopted pane is given a real (lowest-free) grid slot on reconcile, so it COUNTS
//     as grid occupancy and the refill dispatch splits beside it (NOT a new tab) — the
//     run keeps all its splits in one tab even after a restart re-adopts surviving panes.
// ---------------------------------------------------------------------------

test("runQueueSweep: a dispatch after an orphan adoption splits into the adopted tab (not a new tab) and keeps the adopted pane", async () => {
  // A live orphan surface (carries the queueKey annotation, no record) is adopted on the
  // first reconcile; a new candidate is then dispatched on the armed sweep.
  let surfaces: Surface[] = [
    queueSurface({
      id: "orphan-1",
      sessionID: 800,
      agentState: "working",
      queueKey: "ORPH-1",
      queueName: "backlog",
    }),
  ];
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"NEW-1"}]',
    spawns: [{ id: "spawned-new", sessionId: 810 }],
  });
  (fake.client as unknown as { listSurfaces: () => Promise<Surface[]> }).listSurfaces =
    async () => surfaces;

  const run = makeQueueRun(tmpl(), memStore());
  let now = 9_000_000;
  const deps = makeQueueDeps(fake, [run], () => now);

  await runQueueSweep(deps); // arm + adopt the orphan
  assert.equal(run.active.has("ORPH-1"), true, "orphan adopted");
  assert.equal(run.active.get("ORPH-1")!.state, "RUNNING");
  assert.equal(fake.calls.spawn.length, 0, "no dispatch on the suppressed first sweep");

  now += 5000;
  await runQueueSweep(deps); // armed → dispatch NEW-1 alongside the adopted pane
  assert.equal(fake.calls.spawn.length, 1, "the new item dispatched");
  // The dispatch must SPLIT INTO the adopted pane's tab — NOT open a new tab. The
  // adopted pane got a real grid slot (slot 0) on reconcile, so it anchors the tab; the
  // split is BALANCED (the GUI picks the largest pane + direction), not a fixed direction.
  const spawnArgs = fake.calls.spawn[0];
  assert.notEqual(spawnArgs.firstTab, true, "refill must NOT open a new tab (firstTab absent)");
  assert.equal(spawnArgs.balanced, true, "the refill is a balanced BSP split");
  assert.equal(spawnArgs.direction, undefined, "balanced mode sends no explicit direction");
  assert.equal(spawnArgs.targetUUID, "orphan-1", "the split anchors on the adopted pane's tab");
  // (§12 grid cap) the balanced refill forwards the template grid caps so the BSP never
  // exceeds cols columns / rows rows (default tmpl() grid is 3×3).
  assert.equal(spawnArgs.maxCols, 3, "balanced split forwards template grid.cols");
  assert.equal(spawnArgs.maxRows, 3, "balanced split forwards template grid.rows");
  // The adopted pane is still tracked (NOT clobbered/closed by the refill).
  assert.equal(run.active.has("ORPH-1"), true, "adopted pane survives the refill dispatch");
  assert.equal(run.active.has("NEW-1"), true, "new item tracked");
  // The adopted pane was assigned a real (non-negative) grid slot, not the -1 sentinel.
  assert.ok(run.active.get("ORPH-1")!.gridSlot >= 0, "adopted pane reclaimed a real grid slot");
  // Both occupy a concurrency slot (no overshoot): 2 active, well under concurrency 9.
  assert.equal(fake.calls.signal.length, 0, "no spurious attention");
});

// ---------------------------------------------------------------------------
// (10) occupiesSlot — the EXITED-frees-slot / FINISHED-FAILED-COOLDOWN-removed
//      invariant, as an explicit state-table unit test (§6).
// ---------------------------------------------------------------------------

test("occupiesSlot: only the live, pre/in-flight states occupy a slot", () => {
  const base: Assignment = {
    queueName: "q",
    key: "K",
    sessionID: 1,
    gridSlot: 0,
    state: "RUNNING",
    sinceMs: 0,
    hero: false,
  };
  const expected: Record<AssignmentState, boolean> = {
    QUEUED: true,
    SPAWNED: true,
    RUNNING: true,
    DONE_PENDING: true,
    CLOSING: true,
    EXITED: false, // kept-but-freed (leave-and-bell) — blocks re-dispatch, frees the slot
    FINISHED: false,
    FAILED: false,
    COOLDOWN: false,
  };
  for (const [state, occ] of Object.entries(expected) as [AssignmentState, boolean][]) {
    assert.equal(occupiesSlot({ ...base, state }), occ, `occupiesSlot(${state})`);
  }
});

// ---------------------------------------------------------------------------
// (11) The optional `claim` provider fires fire-and-forget after a dispatch, and a
//      claim FAILURE is non-fatal (the dispatch still succeeds) — §5/§7.
// ---------------------------------------------------------------------------

test("runQueueSweep: a configured claim command fires after dispatch and is non-fatal on failure", async () => {
  const claimArgs: string[][] = [];
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"K-1","title":"t"}]',
    spawns: [{ id: "spawned-1", sessionId: 950 }],
  });
  // Wrap exec so a `claim` argv is captured AND fails (non-zero) — the dispatch must
  // still succeed (claim is a latency optimization, never correctness §7).
  const baseExec = fake.exec;
  const exec: Exec = async (argv: string[], opts) => {
    if (argv[0] === "claim") {
      claimArgs.push(argv);
      return { code: 1, stdout: "", stderr: "claim boom" }; // failure → non-fatal
    }
    return baseExec(argv, opts);
  };

  const run = makeQueueRun(
    tmpl({
      provider: {
        list: { command: ["list"], keyField: "id", titleField: "title" },
        status: { command: ["status", "{key}"], doneStates: ["done"] },
        claim: { command: ["claim", "{key}"] },
      },
    }),
    memStore(),
  );
  let now = 10_000_000;
  const deps: QueueDeps = {
    client: fake.client,
    exec,
    budget: new QueueBudget(8),
    now: () => now,
    registry: registryOf([run]),
    factory: noFactory,
    takeCommands: async () => [],
    maxTotal: 8,
    heroMax: 0,
    pendingGraceMs: DEFAULT_PENDING_GRACE_MS,
  };

  await runQueueSweep(deps); // arm
  now += 5000;
  await runQueueSweep(deps); // dispatch + claim (fire-and-forget)
  // Let the fire-and-forget claim promise settle.
  await new Promise((r) => setImmediate(r));

  assert.equal(fake.calls.spawn.length, 1, "dispatch succeeded despite the failing claim");
  assert.deepEqual(claimArgs, [["claim", "K-1"]], "claim fired with the {key} rendered as an argv element");
  assert.equal(run.active.get("K-1")!.state, "SPAWNED", "the assignment is tracked normally");
});

// ---------------------------------------------------------------------------
// (12) §2 sessionID-0 TOLERANCE + BACKFILL: a freshly-spawned SPLIT returns sessionID 0
//      because the host attaches asynchronously. The supervisor must NOT treat that as
//      "no pty-host" and self-disable — it tracks the surface by UUID and BACKFILLS the
//      real sessionID once the host attaches (visible next sweep). It self-disables ONLY
//      if the surface stays live-but-session-0 PAST the grace window (genuine no pty-host).
// ---------------------------------------------------------------------------

test("runQueueSweep: a sessionID-0 spawn is TOLERATED + BACKFILLED once the host attaches (no false self-disable)", async () => {
  const spec: { surfaces: Surface[]; listJson: string; spawns: { id: string; sessionId: number }[] } = {
    surfaces: [],
    listJson: '[{"id":"K-1"}]',
    spawns: [{ id: "spawned-1", sessionId: 0 }], // async-attach: session not ready at spawn
  };
  const fake = makeQueueFake(spec);
  const run = makeQueueRun(tmpl(), memStore());
  let now = 12_000_000;
  const deps = makeQueueDeps(fake, [run], () => now);

  await runQueueSweep(deps); // arm
  now += 5000;
  await runQueueSweep(deps); // dispatch K-1; spawn returns sessionId 0 — TOLERATED

  assert.equal(fake.calls.spawn.length, 1, "one spawn");
  assert.equal(run.disabled, false, "NOT disabled on a transient sessionID 0");
  assert.equal(run.active.has("K-1"), true, "the surface is tracked (pending session) by UUID");
  assert.equal(run.active.get("K-1")!.sessionID, 0, "session pending (0) for now");

  // The host attaches: list_surfaces now shows the spawned surface with a REAL session
  // (carrying the queueKey annotation the dispatch stamped).
  spec.surfaces = [
    queueSurface({ id: "spawned-1", sessionID: 555, queueKey: "K-1", queueName: "backlog" }),
  ];
  now += 5000;
  await runQueueSweep(deps); // reconcile UUID-matches the pending record + BACKFILLS the session

  assert.equal(run.active.has("K-1"), true, "still tracked");
  assert.equal(run.active.get("K-1")!.sessionID, 555, "sessionID BACKFILLED from list_surfaces");
  assert.equal(run.disabled, false, "still not disabled");
  assert.equal(fake.calls.spawn.length, 1, "no re-dispatch (the key was never freed)");
});

test("runQueueSweep: a surface that NEVER attaches a session (genuine no pty-host) self-disables AFTER grace", async () => {
  const spec: { surfaces: Surface[]; listJson: string; spawns: { id: string; sessionId: number }[] } = {
    surfaces: [],
    listJson: '[{"id":"K-1"}]',
    spawns: [{ id: "spawned-1", sessionId: 0 }],
  };
  const fake = makeQueueFake(spec);
  const run = makeQueueRun(tmpl(), memStore());
  let now = 20_000_000;
  const deps = makeQueueDeps(fake, [run], () => now);

  await runQueueSweep(deps); // arm
  now += 5000;
  await runQueueSweep(deps); // dispatch; spawn sessionId 0 — tolerated
  assert.equal(run.disabled, false, "not disabled yet (transient tolerance)");

  // The surface is LIVE but its session STAYS 0 (no pty-host — .exec backend).
  spec.surfaces = [
    queueSurface({ id: "spawned-1", sessionID: 0, queueKey: "K-1", queueName: "backlog" }),
  ];
  now += 5000;
  await runQueueSweep(deps);
  assert.equal(run.disabled, false, "within grace: still tolerated");

  // Past the grace window: a live-but-session-0 surface ⇒ no-pty-host ⇒ self-disable.
  now += DEFAULT_PENDING_GRACE_MS + 1000;
  await runQueueSweep(deps);
  assert.equal(run.disabled, true, "past grace with a live session-0 surface → self-disabled (deferred §2 backstop)");

  // Disabled ⇒ no further dispatch (no tight loop).
  const spawnsAfter = fake.calls.spawn.length;
  now += 5000;
  await runQueueSweep(deps);
  assert.equal(fake.calls.spawn.length, spawnsAfter, "disabled run dispatches nothing further");
});

// ===========================================================================
// (13) ON-DEMAND run lifecycle + the GUI→sidecar command channel (§8a).
// ===========================================================================

/** A persistence recorder: captures the last active-run record list the supervisor wrote. */
function activeRunsRecorder(): {
  persist: (recs: import("./store.js").ActiveRunRecord[]) => void;
  last: () => import("./store.js").ActiveRunRecord[] | null;
} {
  let last: import("./store.js").ActiveRunRecord[] | null = null;
  return { persist: (recs) => { last = recs; }, last: () => last };
}

// ---------------------------------------------------------------------------
// (13a) A `start` command creates the run and (after the suppressed first sweep)
//       dispatches its first candidate. The registry is EMPTY until the command arrives.
// ---------------------------------------------------------------------------

test("runQueueSweep: a start command creates a run on demand and then dispatches", async () => {
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"K-1","title":"task"}]',
    spawns: [{ id: "spawned-1", sessionId: 700 }],
  });
  const store = memStore();
  // The factory builds the run from the basename "backlog-file" → run name "backlog".
  const factory: RunFactory = (basename: string): QueueRun | null => {
    if (basename !== "backlog-file") return null;
    return makeQueueRun(tmpl({ name: "backlog" }), store, { templateName: "backlog-file" });
  };
  const rec = activeRunsRecorder();
  const registry: RunRegistry = new Map();
  let now = 13_000_000;
  const deps: QueueDeps = {
    client: fake.client,
    exec: fake.exec,
    budget: new QueueBudget(8),
    now: () => now,
    registry,
    factory,
    takeCommands: commandsOnce([{ action: "start", template: "backlog-file" }]),
    persistActiveRuns: rec.persist,
    maxTotal: 8,
    heroMax: 0,
    pendingGraceMs: DEFAULT_PENDING_GRACE_MS,
  };

  // Sweep 1: drains the start → creates the run; its OWN first sweep is dispatch-suppressed.
  await runQueueSweep(deps);
  assert.equal(registry.size, 1, "start command created the run");
  assert.ok(registry.has("backlog"));
  assert.equal(fake.calls.spawn.length, 0, "new run is dispatch-suppressed on its first sweep");
  // The active-run SET was persisted on the start.
  assert.ok(rec.last(), "active-run set persisted on start");
  assert.deepEqual(rec.last(), [{ template: "backlog-file", name: "backlog", paused: false, draining: false }]);

  // Sweep 2: no more commands (commandsOnce → []), the armed run dispatches K-1.
  now += 5000;
  await runQueueSweep(deps);
  assert.equal(fake.calls.spawn.length, 1, "armed run dispatches on the next sweep");
  assert.ok(registry.get("backlog")!.active.has("K-1"));
});

// ---------------------------------------------------------------------------
// (13b) PAUSE halts NEW dispatch but a paused run STILL closes a done+idle item
//       (it keeps tracking + closing — §8a).
// ---------------------------------------------------------------------------

test("runQueueSweep: a paused run halts dispatch but still closes a done item", async () => {
  let surfaces: Surface[] = [];
  let statusByKey: Record<string, string> = {};
  const fake = makeQueueFake({
    surfaces: [],
    // TWO candidates so we can prove the SECOND never dispatches while paused.
    listJson: '[{"id":"K-1","title":"a"},{"id":"K-2","title":"b"}]',
    spawns: [{ id: "spawned-1", sessionId: 900 }, { id: "spawned-2", sessionId: 901 }],
  });
  (fake.client as unknown as { listSurfaces: () => Promise<Surface[]> }).listSurfaces =
    async () => surfaces;
  const baseExec = fake.exec;
  const exec: Exec = async (argv: string[]) => {
    if (argv[0] === "status") {
      fake.calls.status.push(argv[1] ?? "");
      return { code: 0, stdout: statusByKey[argv[1] ?? ""] ?? '{"state":"working"}', stderr: "" };
    }
    return baseExec(argv, {});
  };

  const run = makeQueueRun(tmpl({ name: "backlog", concurrency: 1, closeStableSeconds: 5 }), memStore());
  const registry = registryOf([run]);
  let now = 13_500_000;
  const deps: QueueDeps = {
    client: fake.client, exec, budget: new QueueBudget(8), now: () => now,
    registry, factory: noFactory, takeCommands: async () => [],
    maxTotal: 8, heroMax: 0, pendingGraceMs: DEFAULT_PENDING_GRACE_MS,
  };

  await runQueueSweep(deps); // arm
  now += 5000;
  await runQueueSweep(deps); // dispatch K-1 (concurrency 1 → only one)
  assert.equal(fake.calls.spawn.length, 1);
  surfaces = [queueSurface({ id: "spawned-1", sessionID: 900, agentState: "working", queueKey: "K-1", queueName: "backlog" })];
  now += 5000;
  await runQueueSweep(deps); // → RUNNING
  statusByKey = { "K-1": '{"state":"done"}' };
  now += 5000;
  await runQueueSweep(deps); // → DONE_PENDING
  assert.equal(run.active.get("K-1")!.state, "DONE_PENDING");

  // NOW pause the run. A done agent goes idle; the paused run must STILL run the close
  // sequence on K-1 — but must NOT dispatch the waiting K-2 even though a slot opens.
  run.paused = true;
  surfaces = [queueSurface({ id: "spawned-1", sessionID: 900, agentState: "idle", queueKey: "K-1", queueName: "backlog" })];
  now += 1000;
  await runQueueSweep(deps); // idle anchor
  now += 6000;
  await runQueueSweep(deps); // idle held → CLOSING; exit key sent (still closing while paused)
  assert.deepEqual(fake.calls.sendKey, [{ id: "spawned-1", key: "ctrl-d" }], "paused run STILL closes the done item");
  // The child exits → force-close → K-1 freed; but K-2 must NEVER dispatch while paused.
  surfaces = [queueSurface({ id: "spawned-1", sessionID: 900, agentState: "idle", exited: true, queueKey: "K-1", queueName: "backlog" })];
  now += 1000;
  await runQueueSweep(deps);
  assert.deepEqual(fake.calls.forceClose, ["spawned-1"], "paused run force-closed the done item");
  assert.equal(fake.calls.spawn.length, 1, "paused run dispatched NOTHING new (K-2 not spawned)");

  // Resume → the freed slot now dispatches K-2 (after cooldown of K-1 is irrelevant; K-2 is new).
  run.paused = false;
  now += 5000;
  await runQueueSweep(deps);
  assert.equal(fake.calls.spawn.length, 2, "resumed run dispatches K-2");
  assert.ok(run.active.has("K-2"));
});

// ---------------------------------------------------------------------------
// (13c) STOP drains: no new dispatch; the run is REMOVED once its active set empties.
// ---------------------------------------------------------------------------

test("runQueueSweep: a stop command drains the run, then removes it once the active set empties", async () => {
  let surfaces: Surface[] = [];
  let statusByKey: Record<string, string> = {};
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"K-1"},{"id":"K-2"}]',
    spawns: [{ id: "spawned-1", sessionId: 900 }, { id: "spawned-2", sessionId: 901 }],
  });
  (fake.client as unknown as { listSurfaces: () => Promise<Surface[]> }).listSurfaces =
    async () => surfaces;
  const baseExec = fake.exec;
  const exec: Exec = async (argv: string[]) => {
    if (argv[0] === "status") {
      fake.calls.status.push(argv[1] ?? "");
      return { code: 0, stdout: statusByKey[argv[1] ?? ""] ?? '{"state":"working"}', stderr: "" };
    }
    return baseExec(argv, {});
  };

  const run = makeQueueRun(tmpl({ name: "backlog", concurrency: 1, closeStableSeconds: 5 }), memStore());
  const registry = registryOf([run]);
  const rec = activeRunsRecorder();
  let now = 14_000_000;
  const deps: QueueDeps = {
    client: fake.client, exec, budget: new QueueBudget(8), now: () => now,
    registry, factory: noFactory, takeCommands: async () => [],
    persistActiveRuns: rec.persist, maxTotal: 8, heroMax: 0, pendingGraceMs: DEFAULT_PENDING_GRACE_MS,
  };

  await runQueueSweep(deps); // arm
  now += 5000;
  await runQueueSweep(deps); // dispatch K-1
  assert.equal(fake.calls.spawn.length, 1);
  surfaces = [queueSurface({ id: "spawned-1", sessionID: 900, agentState: "working", queueKey: "K-1", queueName: "backlog" })];

  // STOP the run. From now on: no new dispatch (K-2 never spawns), but K-1 completes + closes.
  run.draining = true;
  now += 5000;
  await runQueueSweep(deps); // → RUNNING; drain → no K-2 dispatch
  assert.equal(fake.calls.spawn.length, 1, "draining run dispatches nothing new");
  statusByKey = { "K-1": '{"state":"done"}' };
  now += 5000;
  await runQueueSweep(deps); // → DONE_PENDING
  surfaces = [queueSurface({ id: "spawned-1", sessionID: 900, agentState: "idle", queueKey: "K-1", queueName: "backlog" })];
  now += 1000;
  await runQueueSweep(deps); // idle anchor
  now += 6000;
  await runQueueSweep(deps); // CLOSING; exit key sent
  surfaces = [queueSurface({ id: "spawned-1", sessionID: 900, agentState: "idle", exited: true, queueKey: "K-1", queueName: "backlog" })];
  now += 1000;
  await runQueueSweep(deps); // force-close → K-1 leaves active → run drained → REMOVED
  assert.deepEqual(fake.calls.forceClose, ["spawned-1"]);
  assert.equal(registry.has("backlog"), false, "drained run removed once its active set emptied");
  assert.equal(fake.calls.spawn.length, 1, "K-2 NEVER dispatched (drained)");
  // The active-run set was re-persisted WITHOUT the removed run.
  assert.deepEqual(rec.last(), [], "active-run set persisted empty after the drain removal");
});

// ---------------------------------------------------------------------------
// (13c-i) STOP with an EXITED (leave-and-bell) assignment: a crashed split is KEPT in
//         `active` (EXITED) for human review and never occupies a slot — so a draining
//         run whose only remaining assignment is EXITED must still DRAIN + be removed
//         (gated on slot-occupancy, NOT `active.size`). Without this the run would
//         linger in the registry until a human closes the dead split.
// ---------------------------------------------------------------------------

test("runQueueSweep: a stop command drains a run even when its only remaining assignment is EXITED", async () => {
  let surfaces: Surface[] = [];
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"K-1"}]',
    spawns: [{ id: "spawned-1", sessionId: 900 }],
  });
  (fake.client as unknown as { listSurfaces: () => Promise<Surface[]> }).listSurfaces =
    async () => surfaces;

  const run = makeQueueRun(tmpl({ name: "backlog", concurrency: 1 }), memStore());
  const registry = registryOf([run]);
  const rec = activeRunsRecorder();
  let now = 16_000_000;
  const deps: QueueDeps = {
    client: fake.client, exec: fake.exec, budget: new QueueBudget(8), now: () => now,
    registry, factory: noFactory, takeCommands: async () => [],
    persistActiveRuns: rec.persist, maxTotal: 8, heroMax: 0, pendingGraceMs: DEFAULT_PENDING_GRACE_MS,
  };

  await runQueueSweep(deps); // arm
  now += 5000;
  await runQueueSweep(deps); // dispatch K-1
  assert.equal(fake.calls.spawn.length, 1);

  // K-1's child EXITS early (leave-and-bell): kept in EXITED, slot freed, NOT auto-closed.
  surfaces = [queueSurface({ id: "spawned-1", sessionID: 900, exited: true, agentState: "working", queueKey: "K-1", queueName: "backlog" })];
  now += 5000;
  await runQueueSweep(deps);
  assert.equal(run.active.get("K-1")?.state, "EXITED", "kept in EXITED for review");
  assert.equal(fake.calls.forceClose.length, 0, "EXITED split NOT auto-closed");

  // STOP the run while the EXITED split still stands. The run holds an EXITED assignment
  // (active.size === 1) but NOTHING occupies a slot → it must drain + be removed.
  run.draining = true;
  now += 5000;
  await runQueueSweep(deps);
  assert.equal(registry.has("backlog"), false, "drained run removed despite the held EXITED assignment");
  assert.equal(fake.calls.forceClose.length, 0, "the dead split is LEFT standing for review (not force-closed by the drain)");
  assert.deepEqual(rec.last(), [], "active-run set persisted empty after the drain removal");
});

// ---------------------------------------------------------------------------
// (13d) ABORT force-closes ALL the run's assignments this sweep, then removes the run.
// ---------------------------------------------------------------------------

test("runQueueSweep: an abort command exit+force-closes all assignments and removes the run", async () => {
  let surfaces: Surface[] = [];
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"K-1"},{"id":"K-2"}]',
    spawns: [{ id: "spawned-1", sessionId: 900 }, { id: "spawned-2", sessionId: 901 }],
  });
  (fake.client as unknown as { listSurfaces: () => Promise<Surface[]> }).listSurfaces =
    async () => surfaces;

  const run = makeQueueRun(tmpl({ name: "backlog", concurrency: 9 }), memStore());
  const registry = registryOf([run]);
  const rec = activeRunsRecorder();
  let now = 15_000_000;
  const deps: QueueDeps = {
    client: fake.client, exec: fake.exec, budget: new QueueBudget(8), now: () => now,
    registry, factory: noFactory, takeCommands: async () => [],
    persistActiveRuns: rec.persist, maxTotal: 8, heroMax: 0, pendingGraceMs: DEFAULT_PENDING_GRACE_MS,
  };

  await runQueueSweep(deps); // arm
  now += 5000;
  await runQueueSweep(deps); // dispatch K-1 + K-2 (two slots)
  assert.equal(fake.calls.spawn.length, 2, "two agents dispatched");
  // Both surfaces appear live + tracked.
  surfaces = [
    queueSurface({ id: "spawned-1", sessionID: 900, agentState: "working", queueKey: "K-1", queueName: "backlog" }),
    queueSurface({ id: "spawned-2", sessionID: 901, agentState: "working", queueKey: "K-2", queueName: "backlog" }),
  ];
  now += 5000;
  await runQueueSweep(deps); // → both RUNNING
  assert.equal(run.active.size, 2);

  // ABORT: this sweep sends exit keys + force-closes BOTH, then removes the run.
  run.aborting = true;
  now += 5000;
  await runQueueSweep(deps);
  assert.equal(registry.has("backlog"), false, "aborted run removed from the registry");
  assert.deepEqual(
    fake.calls.forceClose.sort(),
    ["spawned-1", "spawned-2"],
    "abort force-closed every live assignment",
  );
  // Exit keys were sent to both before the force-close.
  assert.deepEqual(
    fake.calls.sendKey.map((k) => k.id).sort(),
    ["spawned-1", "spawned-2"],
    "abort sent the exit keys before force-closing",
  );
  assert.deepEqual(rec.last(), [], "active-run set persisted empty after the abort removal");
});

// ---------------------------------------------------------------------------
// (13e) REHYDRATION: a previously-started run (pre-populated in the registry, as
//       rehydrateActiveRuns would) with a persisted in-flight assignment is re-adopted across a
//       simulated sidecar restart and does NOT re-dispatch (§9). No start command needed.
// ---------------------------------------------------------------------------

test("runQueueSweep: a rehydrated active run re-adopts its in-flight item and does NOT re-dispatch", async () => {
  // The per-run store carries a FINALIZED RUNNING record from before the restart.
  const priorRecord: Assignment = {
    queueName: "backlog",
    key: "K-1",
    sessionID: 900,
    surfaceUUID: "old-uuid", // will be refreshed to the live UUID on reconcile
    gridSlot: 0,
    state: "RUNNING",
    sinceMs: 0, // long ago → past grace, but its session IS live so it stays active
    hero: false,
  };
  const store = memStore(
    JSON.stringify({ version: 1, records: [priorRecord], lifetimeDispatched: 1 }),
  );
  // The live surface for that session is present after the restart (carries its annotation).
  const live = queueSurface({
    id: "live-uuid", sessionID: 900, agentState: "working",
    queueKey: "K-1", queueName: "backlog",
  });
  const fake = makeQueueFake({
    surfaces: [live],
    // The provider STILL lists K-1 (it's in flight) — a re-dispatch would be the bug.
    listJson: '[{"id":"K-1"}]',
    spawns: [{ id: "would-be-dup", sessionId: 999 }],
  });
  (fake.client as unknown as { listSurfaces: () => Promise<Surface[]> }).listSurfaces =
    async () => [live];

  // Simulate rehydrateActiveRuns: the run is ALREADY in the registry at sidecar startup, with
  // its template + the SAME store (no start command issued).
  const run = makeQueueRun(tmpl({ name: "backlog" }), store, { templateName: "backlog-file" });
  const registry = registryOf([run]);
  let now = 16_000_000;
  const deps: QueueDeps = {
    client: fake.client, exec: fake.exec, budget: new QueueBudget(8), now: () => now,
    registry, factory: noFactory, takeCommands: async () => [],
    maxTotal: 8, heroMax: 0, pendingGraceMs: DEFAULT_PENDING_GRACE_MS,
  };

  // Sweep 1: reconcile re-adopts K-1 (matched by sessionID 900); dispatch suppressed.
  await runQueueSweep(deps);
  assert.ok(run.active.has("K-1"), "in-flight K-1 re-adopted from the persisted store");
  assert.equal(run.active.get("K-1")!.surfaceUUID, "live-uuid", "UUID refreshed to the live surface");
  assert.equal(run.lifetimeDispatched, 1, "lifetime counter rehydrated");
  assert.equal(fake.calls.spawn.length, 0, "first sweep dispatch-suppressed");

  // Sweep 2: armed — but K-1 is already active, so it is NOT re-dispatched (§7/§9).
  now += 5000;
  await runQueueSweep(deps);
  assert.equal(fake.calls.spawn.length, 0, "no re-dispatch of the already-running rehydrated item");
  assert.equal(run.active.size, 1, "still exactly one assignment");
});

// ---------------------------------------------------------------------------
// (13f) A no-command sweep over a running registry is unchanged (regression guard for
//       the command-drain addition): draining nothing leaves the dispatch path identical.
// ---------------------------------------------------------------------------

test("runQueueSweep: a sweep with no commands behaves exactly like the static-runs model", async () => {
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"K-1"}]',
    spawns: [{ id: "spawned-1", sessionId: 900 }],
  });
  const run = makeQueueRun(tmpl({ name: "backlog" }), memStore());
  let now = 17_000_000;
  // takeCommands defaults to async () => [] via makeQueueDeps.
  const deps = makeQueueDeps(fake, [run], () => now);

  await runQueueSweep(deps); // arm (suppressed)
  assert.equal(fake.calls.spawn.length, 0);
  now += 5000;
  await runQueueSweep(deps); // dispatch
  assert.equal(fake.calls.spawn.length, 1, "no-command sweep dispatches just like before");
  assert.equal(deps.registry.size, 1, "the run is untouched by an empty command drain");
});

// ---------------------------------------------------------------------------
// (14) NO auto-quit on an empty list (quitWhenEmpty REMOVED). A run is removed only by
//      an explicit stop/abort; an empty `list` just means "nothing actionable now" and
//      the run KEEPS polling. (The old quitWhenEmpty keyed on active.size===0, which a
//      transient/incomplete post-restart list_surfaces could falsely produce → abandon
//      live agents + remove the run. Removed; this pins the persist-forever behavior.)
// ---------------------------------------------------------------------------

test("runQueueSweep: an empty list + no active agents does NOT remove the run", () => {
  return (async () => {
    const fake = makeQueueFake({ surfaces: [], listJson: "[]" });
    const run = makeQueueRun(tmpl(), memStore());
    let now = 1_000_000;
    const deps = makeQueueDeps(fake, [run], () => now);

    await runQueueSweep(deps); // arm (dispatch suppressed; no list fetch yet)
    now += 5000;
    await runQueueSweep(deps); // empty list, nothing active
    assert.equal(deps.registry.size, 1, "run persists on an empty list (no auto-quit)");
    assert.equal(fake.calls.spawn.length, 0, "nothing dispatched (empty list)");
    now += 5000;
    await runQueueSweep(deps); // and again — still there, still polling
    assert.equal(deps.registry.size, 1, "still present after another empty sweep");
  })();
});

// ---------------------------------------------------------------------------
// (interval throttling) Provider `list`/`status` calls are throttled to
// intervals.listMs / intervals.statusMs — the 5s sweep stays the base cadence for
// reconcile/close/commands/health, but the provider is NOT hit every sweep.
// ---------------------------------------------------------------------------

test("runQueueSweep: list fetch is THROTTLED to intervals.listMs", async () => {
  const fake = makeQueueFake({ surfaces: [], listJson: "[]" });
  const t = tmpl({ intervals: { listMs: 30000, statusMs: 0 } });
  const run = makeQueueRun(t, memStore());
  let now = 1_000_000;
  const deps = makeQueueDeps(fake, [run], () => now);

  await runQueueSweep(deps); // arm — dispatch suppressed, no list fetch at all
  assert.equal(fake.calls.list, 0, "arm sweep does not fetch the list");

  now += 5000;
  await runQueueSweep(deps); // first dispatch sweep — lastListAtMs is -Inf → fetches
  assert.equal(fake.calls.list, 1, "first dispatch sweep fetches");

  now += 5000; // +5s since the fetch < 30s
  await runQueueSweep(deps);
  assert.equal(fake.calls.list, 1, "within listMs: no re-fetch");

  now += 10000; // +15s since the fetch < 30s
  await runQueueSweep(deps);
  assert.equal(fake.calls.list, 1, "still within listMs: no re-fetch");

  now += 20000; // +35s since the fetch ≥ 30s
  await runQueueSweep(deps);
  assert.equal(fake.calls.list, 2, "after listMs elapses: re-fetch");
});

test("runQueueSweep: a throttled (skipped) list sweep STILL reports health from the cache", async () => {
  // The dashboard counts must stay live between list polls — reportQueueStatus reads the
  // cached lastListItems, so a throttled sweep still pushes the same waiting count.
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"A"},{"id":"B"}]',
    spawns: [{ id: "s-a", sessionId: 1 }, { id: "s-b", sessionId: 2 }],
  });
  // Cap dispatch to 0 net effect on health by using a big concurrency but tracking the
  // "waiting" count: list has 2 items, both dispatched on the fetch sweep, so 0 waiting after.
  const t = tmpl({ intervals: { listMs: 30000, statusMs: 0 }, concurrency: 1 });
  const run = makeQueueRun(t, memStore());
  let now = 1_000_000;
  const deps = makeQueueDeps(fake, [run], () => now);

  await runQueueSweep(deps); // arm
  now += 5000;
  await runQueueSweep(deps); // fetch: dispatch A (concurrency 1), B waiting
  const afterFetch = fake.calls.reports.at(-1)!;
  assert.equal(fake.calls.list, 1);
  assert.equal(afterFetch.queued, 1, "B waiting after the fetch sweep");

  now += 5000; // throttled sweep (no fetch)
  await runQueueSweep(deps);
  assert.equal(fake.calls.list, 1, "throttled: no second fetch");
  const afterThrottle = fake.calls.reports.at(-1)!;
  assert.equal(afterThrottle.queued, 1, "throttled sweep still reports the cached waiting count");
});

test("runQueueSweep: status probe is THROTTLED to intervals.statusMs", async () => {
  let surfaces: Surface[] = [];
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"K-1"}]',
    spawns: [{ id: "spawned-1", sessionId: 900 }],
    statusByKey: { "K-1": '{"state":"working"}' }, // never terminal → stays RUNNING, keeps being probed
  });
  (fake.client as unknown as { listSurfaces: () => Promise<Surface[]> }).listSurfaces =
    async () => surfaces;
  // list throttling OFF (0) so it doesn't interfere; status throttled to 30s.
  const t = tmpl({ intervals: { listMs: 0, statusMs: 30000 } });
  const run = makeQueueRun(t, memStore());
  let now = 2_000_000;
  const deps = makeQueueDeps(fake, [run], () => now);

  await runQueueSweep(deps); // arm
  now += 5000;
  await runQueueSweep(deps); // dispatch K-1 → SPAWNED (advanceStates ran before dispatch, active empty)
  assert.equal(fake.calls.status.length, 0, "no probe the sweep it was spawned (not yet live)");

  // The spawned surface now appears live + working.
  surfaces = [
    queueSurface({ id: "spawned-1", sessionID: 900, agentState: "working", queueKey: "K-1", queueName: "backlog" }),
  ];

  now += 5000;
  await runQueueSweep(deps); // advanceStates: statusDue (-Inf) → probe #1, SPAWNED→RUNNING
  assert.equal(fake.calls.status.length, 1, "first status probe fires once the agent is live");

  now += 5000; // +5s since the probe < 30s
  await runQueueSweep(deps);
  assert.equal(fake.calls.status.length, 1, "within statusMs: no re-probe");

  now += 30000; // ≥ 30s since the probe
  await runQueueSweep(deps);
  assert.equal(fake.calls.status.length, 2, "after statusMs elapses: re-probe");
});

test("advanceStates: a due status sweep with NO live agent does not burn the interval", async () => {
  // The window is consumed only when a probe actually fires. A SPAWNED assignment whose
  // surface isn't live yet must NOT consume the status window — the next sweep (surface live)
  // probes immediately rather than waiting a full interval.
  let surfaces: Surface[] = [];
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"K-1"}]',
    spawns: [{ id: "spawned-1", sessionId: 900 }],
    statusByKey: { "K-1": '{"state":"working"}' },
  });
  (fake.client as unknown as { listSurfaces: () => Promise<Surface[]> }).listSurfaces =
    async () => surfaces;
  const t = tmpl({ intervals: { listMs: 0, statusMs: 30000 } });
  const run = makeQueueRun(t, memStore());
  let now = 5_000_000;
  const deps = makeQueueDeps(fake, [run], () => now);

  await runQueueSweep(deps); // arm
  now += 5000;
  await runQueueSweep(deps); // dispatch K-1 → SPAWNED; surface NOT live yet → no probe
  assert.equal(fake.calls.status.length, 0);

  // Surface still not live this sweep (host attach lag): SPAWNED but no live surface.
  now += 5000;
  await runQueueSweep(deps); // due, but no live agent → no probe, window NOT consumed
  assert.equal(fake.calls.status.length, 0, "no probe when the agent isn't live");

  // Surface finally appears — even though only 5s passed since the (no-op) due sweep, the
  // probe fires NOW because the window was never consumed.
  surfaces = [
    queueSurface({ id: "spawned-1", sessionID: 900, agentState: "working", queueKey: "K-1", queueName: "backlog" }),
  ];
  now += 5000;
  await runQueueSweep(deps);
  assert.equal(fake.calls.status.length, 1, "probes immediately once the agent is live (window not pre-burned)");
});

// (parallel probes / command-latency fix) The per-agent provider `status` probes in a sweep
// run CONCURRENTLY, not one-await-at-a-time. Serialized N×5s probes were the dominant sweep-
// latency source that made a queued adopt/promote wait tens of seconds. This measures PEAK
// concurrency via a barrier exec: each status probe increments an in-flight counter and does
// not resolve until ALL N are simultaneously in-flight (a 200ms safety net makes a serialized
// regression FAIL the assertion promptly instead of hanging). Under Promise.all all N enter
// together → peak N; a serial `for … await` would peak at 1.
test("advanceStates: due status probes for multiple agents run CONCURRENTLY (not serialized)", async () => {
  const N = 3;
  let inFlight = 0;
  let maxInFlight = 0;
  let release!: () => void;
  const allIn = new Promise<void>((r) => (release = r));

  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"K-1"},{"id":"K-2"},{"id":"K-3"}]',
    spawns: [
      { id: "s1", sessionId: 901 },
      { id: "s2", sessionId: 902 },
      { id: "s3", sessionId: 903 },
    ],
  });
  let surfaces: Surface[] = [];
  (fake.client as unknown as { listSurfaces: () => Promise<Surface[]> }).listSurfaces =
    async () => surfaces;

  // Barrier status exec (list/graph delegate to the fake). Peak concurrency is recorded as
  // each probe enters; the probe unblocks only once all N are in-flight together.
  const exec: Exec = async (argv, opts) => {
    if (argv[0] !== "status") return fake.exec(argv, opts);
    inFlight += 1;
    maxInFlight = Math.max(maxInFlight, inFlight);
    if (inFlight >= N) release();
    await Promise.race([allIn, new Promise<void>((r) => setTimeout(r, 200))]);
    inFlight -= 1;
    return { code: 0, stdout: '{"state":"working"}', stderr: "" };
  };

  const t = tmpl({
    concurrency: N,
    grid: { cols: N, rows: 1, fill: "columns" },
    intervals: { listMs: 0, statusMs: 0 },
  });
  const run = makeQueueRun(t, memStore());
  let now = 3_000_000;
  const deps = makeQueueDeps(fake, [run], () => now, 8, { exec });

  // Dispatch all N (→ SPAWNED). Surfaces not live yet → no probe fires.
  await runQueueSweep(deps);
  now += 5000;
  await runQueueSweep(deps);
  assert.equal(fake.calls.spawn.length, N, "all N items dispatched");
  assert.equal(maxInFlight, 0, "no status probe while the agents aren't live yet");

  // The N agents are now live + working → the next sweep probes all N.
  surfaces = [
    queueSurface({ id: "s1", sessionID: 901, agentState: "working", queueKey: "K-1", queueName: "backlog" }),
    queueSurface({ id: "s2", sessionID: 902, agentState: "working", queueKey: "K-2", queueName: "backlog" }),
    queueSurface({ id: "s3", sessionID: 903, agentState: "working", queueKey: "K-3", queueName: "backlog" }),
  ];
  now += 5000;
  await runQueueSweep(deps);

  assert.equal(maxInFlight, N, "all N status probes were in-flight simultaneously (parallelized)");
});

// ---------------------------------------------------------------------------
// (backlog graph) provider.graph fetch + report_queue_graph push (throttled, present:false).
// ---------------------------------------------------------------------------

// A template that opts into the optional backlog board.
function graphTmpl(over: Partial<QueueTemplate> = {}): QueueTemplate {
  return tmpl({
    provider: {
      list: { command: ["list"], keyField: "id", titleField: "title", urlField: "url" },
      status: { command: ["status", "{key}"], doneStates: ["done"] },
      graph: { command: ["graph"] },
    },
    ...over,
  });
}

test("runQueueSweep: with provider.graph, a sweep fetches the board + pushes report_queue_graph with the backlog count", async () => {
  // Board: W is waiting/dispatched (in the list), B1/B2 are backlog, D is terminal.
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"W"}]',
    spawns: [{ id: "s-w", sessionId: 1 }],
    graphJson: JSON.stringify({
      nodes: [
        { key: "W", state: "Todo", done: false, blockedBy: [] },
        { key: "B1", state: "Backlog", done: false, blockedBy: ["W"] },
        { key: "B2", state: "Backlog", done: false, labels: ["Design needed"], blockedBy: [] },
        { key: "D", state: "Done", done: true, blockedBy: [] },
      ],
    }),
  });
  const run = makeQueueRun(graphTmpl(), memStore());
  let now = 1_000_000;
  const deps = makeQueueDeps(fake, [run], () => now);

  await runQueueSweep(deps); // arm (graph fetches here: lastGraphAtMs is -Inf)
  now += 5000;
  await runQueueSweep(deps); // dispatch W

  assert.ok(fake.calls.graph >= 1, "the graph command was fetched");
  const last = fake.calls.graphReports.at(-1)!;
  assert.equal(last.present, true);
  assert.equal(last.queueName, "backlog");
  assert.equal(last.nodes.length, 4, "the full board (incl. done) is pushed");
  // backlog = non-terminal not waiting/running: B1, B2 (W excluded as active/listed, D done).
  assert.equal(last.backlog, 2);
  // Edges + labels survive to the report (for the canvas).
  assert.deepEqual(last.nodes.find((n) => n.key === "B1")?.blockedBy, ["W"]);
  assert.deepEqual(last.nodes.find((n) => n.key === "B2")?.labels, ["Design needed"]);
});

test("runQueueSweep: provider.graph fetch is THROTTLED to intervals.listMs", async () => {
  const fake = makeQueueFake({ surfaces: [], listJson: "[]", graphJson: '{"nodes":[]}' });
  const run = makeQueueRun(graphTmpl({ intervals: { listMs: 30000, statusMs: 0 } }), memStore());
  let now = 1_000_000;
  const deps = makeQueueDeps(fake, [run], () => now);

  await runQueueSweep(deps); // arm — graph fetches (lastGraphAtMs -Inf)
  assert.equal(fake.calls.graph, 1, "first sweep fetches the graph");

  now += 5000;
  await runQueueSweep(deps);
  assert.equal(fake.calls.graph, 1, "within listMs: no graph re-fetch");

  now += 30000; // ≥ listMs since the first fetch
  await runQueueSweep(deps);
  assert.equal(fake.calls.graph, 2, "after listMs: graph re-fetches");
});

test("runQueueSweep: NO provider.graph => never fetches a graph nor pushes report_queue_graph", async () => {
  const fake = makeQueueFake({ surfaces: [], listJson: "[]" });
  const run = makeQueueRun(tmpl(), memStore()); // base tmpl has no provider.graph
  let now = 1_000_000;
  const deps = makeQueueDeps(fake, [run], () => now);
  await runQueueSweep(deps);
  now += 5000;
  await runQueueSweep(deps);
  assert.equal(fake.calls.graph, 0);
  assert.equal(fake.calls.graphReports.length, 0);
});

test("runQueueSweep: aborting a run with provider.graph pushes report_queue_graph present:false", async () => {
  const fake = makeQueueFake({ surfaces: [], listJson: "[]", graphJson: '{"nodes":[]}' });
  const run = makeQueueRun(graphTmpl({ name: "backlog" }), memStore());
  const registry = registryOf([run]);
  let now = 1_000_000;
  const deps: QueueDeps = {
    client: fake.client, exec: fake.exec, budget: new QueueBudget(8), now: () => now,
    registry, factory: noFactory, takeCommands: async () => [],
    maxTotal: 8, heroMax: 0, pendingGraceMs: DEFAULT_PENDING_GRACE_MS,
  };
  await runQueueSweep(deps); // arm
  run.aborting = true;
  now += 5000;
  await runQueueSweep(deps); // abort → run removed
  assert.equal(registry.has("backlog"), false);
  const gone = fake.calls.graphReports.at(-1)!;
  assert.equal(gone.present, false, "graph section cleared on abort");
  assert.deepEqual(gone.nodes, []);
});

// ---------------------------------------------------------------------------
// (adopt) runAdopt — move the human-created split in, annotate, claim, persist the latch;
//         roll back the latch on a move failure; no move when the run has no seated anchor;
//         and the moved+annotated surface is folded in by reconcile next sweep.
// ---------------------------------------------------------------------------

/** Seat one RUNNING assignment in a run so `firstSeatedUUID` has an anchor pane. */
function seat(run: QueueRun, key: string, uuid: string, slot = 0): void {
  run.active.set(key, {
    queueName: run.runName,
    key,
    sessionID: 500 + slot,
    surfaceUUID: uuid,
    gridSlot: slot,
    state: "RUNNING",
    sinceMs: 0,
    hero: false,
  });
}

test("runAdopt: moves the split into the run's tab, annotates (keep=template), claims, persists the latch", async () => {
  const claimArgs: string[][] = [];
  const fake = makeQueueFake({ surfaces: [], listJson: "[]" });
  // Capture claim argv via a custom exec.
  const exec: Exec = async (argv) => {
    if (argv[0] === "claim") { claimArgs.push(argv); return { code: 0, stdout: "", stderr: "" }; }
    if (argv[0] === "list") return { code: 0, stdout: "[]", stderr: "" };
    return { code: 0, stdout: '{"state":"working"}', stderr: "" };
  };
  const store = memStore();
  const t = tmpl({ keepOnComplete: true, provider: {
    list: { command: ["list"], keyField: "id" },
    status: { command: ["status", "{key}"], doneStates: ["done"] },
    claim: { command: ["claim", "{key}"] },
  } });
  const run = makeQueueRun(t, store);
  seat(run, "SEED", "anchor-uuid", 0);
  let now = 6_000_000;
  const deps = makeQueueDeps(fake, [run], () => now, 8, {
    exec,
    takeCommands: commandsOnce([
      { action: "adopt", run: "backlog", key: "ADOPT-1", surfaceUUID: "free-uuid", url: "http://x/ADOPT-1" },
    ]),
  });

  await runQueueSweep(deps);

  // The latch is the crux.
  assert.ok(run.dispatched.has("ADOPT-1"), "adopt latched the key");
  // The split was MOVED into the run's tab, anchored on the seated pane.
  assert.equal(fake.calls.moveIntoTab.length, 1);
  assert.equal(fake.calls.moveIntoTab[0].sourceUUID, "free-uuid");
  assert.equal(fake.calls.moveIntoTab[0].targetAnchorUUID, "anchor-uuid");
  assert.equal(fake.calls.moveIntoTab[0].maxCols, 3);
  // The annotation stamps queueKey/queueName/queueUrl + keep FOLLOWING the template (true here).
  const ann = fake.calls.annotate.find((a) => a.id === "free-uuid");
  assert.ok(ann, "annotated the moved surface");
  assert.equal(ann!.ann.queueKey, "ADOPT-1");
  assert.equal(ann!.ann.queueName, "backlog");
  assert.equal(ann!.ann.queueUrl, "http://x/ADOPT-1");
  assert.equal(ann!.ann.keep, true, "keep follows template keepOnComplete, NOT a forced true");
  // The claim fired with the adopted key.
  assert.deepEqual(claimArgs, [["claim", "ADOPT-1"]]);
  // The latch is persisted so suppression survives a crash before the adopting reconcile.
  assert.ok(loadDispatched(store).includes("ADOPT-1"), "latch persisted");
  // runAdopt NEVER writes run.active for the adopted key (reconcile is its sole owner) and never
  // spawns — so no new agent was launched (lifetimeDispatched is only ever bumped by dispatch).
  assert.ok(!run.active.has("ADOPT-1"), "adopt does not insert into active (reconcile owns it)");
  assert.equal(fake.calls.spawn.length, 0, "adopt launches NO new agent (no spawn)");
});

test("runAdopt: a MOVE failure rolls back the latch (item stays dispatchable) and persists", async () => {
  const fake = makeQueueFake({ surfaces: [], listJson: "[]" });
  // Make moveSurfaceIntoTab throw.
  (fake.client as unknown as { moveSurfaceIntoTab: (a: unknown) => Promise<void> }).moveSurfaceIntoTab =
    async () => { throw new Error("move boom"); };
  const store = memStore();
  const run = makeQueueRun(tmpl(), store);
  seat(run, "SEED", "anchor-uuid", 0);
  let now = 6_100_000;
  const deps = makeQueueDeps(fake, [run], () => now, 8, {
    takeCommands: commandsOnce([
      { action: "adopt", run: "backlog", key: "ADOPT-2", surfaceUUID: "free-uuid" },
    ]),
  });

  await runQueueSweep(deps);

  assert.ok(!run.dispatched.has("ADOPT-2"), "move failure rolled back the latch");
  assert.ok(!loadDispatched(store).includes("ADOPT-2"), "rollback persisted");
});

test("runAdopt: no seated anchor → no move, but annotation is still stamped (seed)", async () => {
  const fake = makeQueueFake({ surfaces: [], listJson: "[]" });
  const run = makeQueueRun(tmpl(), memStore()); // empty run, no seated pane
  let now = 6_200_000;
  const deps = makeQueueDeps(fake, [run], () => now, 8, {
    takeCommands: commandsOnce([
      { action: "adopt", run: "backlog", key: "SEED-1", surfaceUUID: "free-uuid" },
    ]),
  });

  await runQueueSweep(deps);

  assert.equal(fake.calls.moveIntoTab.length, 0, "no move when the run has no seated anchor");
  assert.ok(run.dispatched.has("SEED-1"), "still latched");
  const ann = fake.calls.annotate.find((a) => a.id === "free-uuid");
  assert.ok(ann, "annotation stamped so reconcile seeds it next sweep");
  assert.equal(ann!.ann.queueKey, "SEED-1");
});

test("adopt + reconcile: the annotated surface is folded in as a RUNNING assignment, no lifetime bump", () => {
  // The pure reconcile path the runner relies on: a live surface (non-zero sessionID) carrying
  // queueKey+queueName with NO matching record is adopted as RUNNING.
  const live: LiveSurface[] = [
    { sessionID: 7777, surfaceUUID: "free-uuid", queueKey: "ADOPT-9", queueName: "backlog", title: "the bug" },
  ];
  const plan = reconcile([], live, 9_000_000, DEFAULT_PENDING_GRACE_MS);
  const adopt = plan.actions.find((a) => a.kind === "adopt");
  assert.ok(adopt, "reconcile adopts the annotated free surface");
  assert.equal(adopt!.kind === "adopt" && adopt!.assignment.key, "ADOPT-9");
  assert.equal(adopt!.kind === "adopt" && adopt!.assignment.state, "RUNNING");
  assert.ok(adopt!.kind === "adopt" && adopt!.assignment.gridSlot >= 0, "occupies a real grid slot");
});

test("adopt + reconcile: a sessionID-0 surface is NOT adopted (§2.3 precondition)", () => {
  const live: LiveSurface[] = [
    { sessionID: 0, surfaceUUID: "free-uuid", queueKey: "ADOPT-0", queueName: "backlog" },
  ];
  const plan = reconcile([], live, 9_000_000, DEFAULT_PENDING_GRACE_MS);
  assert.equal(plan.actions.find((a) => a.kind === "adopt"), undefined,
    "a 0-session surface has no persistence key → not adoptable");
});

// ---------------------------------------------------------------------------
// (adopt) runInferKey — the side-effect loop calls the inferKey seam; an infer_key with no
//         seam is a harmless no-op; the seam writes queueKeySuggested.
// ---------------------------------------------------------------------------

test("runQueueSweep: infer_key dispatches deps.inferKey with the surface + run", async () => {
  const fake = makeQueueFake({ surfaces: [], listJson: "[]" });
  const run = makeQueueRun(tmpl(), memStore());
  const calls: Array<{ uuid: string; run: string }> = [];
  let now = 6_300_000;
  const deps = makeQueueDeps(fake, [run], () => now, 8, {
    takeCommands: commandsOnce([{ action: "infer_key", run: "backlog", surfaceUUID: "u-infer" }]),
    inferKey: async (uuid, runName) => { calls.push({ uuid, run: runName }); },
  });

  await runQueueSweep(deps);

  assert.deepEqual(calls, [{ uuid: "u-infer", run: "backlog" }]);
});

test("runQueueSweep: infer_key with NO inferKey seam is a harmless no-op", async () => {
  const fake = makeQueueFake({ surfaces: [], listJson: "[]" });
  const run = makeQueueRun(tmpl(), memStore());
  let now = 6_400_000;
  const deps = makeQueueDeps(fake, [run], () => now, 8, {
    takeCommands: commandsOnce([{ action: "infer_key", run: "backlog", surfaceUUID: "u-infer" }]),
  });
  // Must not throw.
  await runQueueSweep(deps);
  assert.equal(fake.calls.annotate.length, 0);
});

// ---------------------------------------------------------------------------
// (hero) Two-pool dispatch accounting (HERO-AGENTS.md § Slot accounting). The list is
// split by item.hero: the REGULAR pool is gated by concurrency + max-total + maxItems
// (counting ONLY non-hero); the HERO pool is gated ONLY by the fleet-wide
// `agent-queue-hero-max`. The two pools are ORTHOGONAL.
// ---------------------------------------------------------------------------

/** A template whose list provider maps a `hero` boolean field (mirrors keyField/titleField). */
function heroTmpl(over: Partial<QueueTemplate> = {}): QueueTemplate {
  const base = tmpl(over);
  return {
    ...base,
    provider: {
      ...base.provider,
      list: { ...base.provider.list, heroField: "hero" },
    },
  };
}

/** Arm a run (its first sweep only reconciles — dispatch is suppressed) so the NEXT sweep
 *  dispatches. Uses an empty list for the arm so nothing is chosen. */
async function arm(deps: QueueDeps): Promise<void> {
  await runQueueSweep(deps);
}

test("hero: the hero cap is ORTHOGONAL to concurrency — a hero dispatches even when the regular pool is full", async () => {
  // concurrency 1 → the regular pool can seat exactly ONE regular. The list has ONE regular
  // AND one hero. The regular fills the single concurrency slot; the hero must STILL dispatch
  // (its own pool, gated only by heroMax=2), so BOTH spawn.
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"R-1","hero":false},{"id":"H-1","hero":true}]',
    spawns: [{ id: "s-r1", sessionId: 601 }, { id: "s-h1", sessionId: 602 }],
  });
  const run = makeQueueRun(heroTmpl({ concurrency: 1 }), memStore());
  let now = 7_000_000;
  const deps = makeQueueDeps(fake, [run], () => now, 8, { heroMax: 2 });

  await arm(deps);
  now += 5000;
  await runQueueSweep(deps);

  assert.equal(fake.calls.spawn.length, 2, "regular (concurrency 1) + hero (own pool) both dispatch");
  assert.ok(run.active.has("R-1"), "regular dispatched");
  assert.ok(run.active.has("H-1"), "hero dispatched despite concurrency 1");
  assert.equal(run.active.get("H-1")!.hero, true, "hero record carries the hero bit");
  assert.equal(run.active.get("R-1")!.hero, false, "regular record is not a hero");
});

test("hero: maxItems caps HEROES too — a hero does NOT dispatch once the queue's lifetime cap is hit", async () => {
  // maxItems 1 → exactly ONE dispatch EVER, regular or hero (heroes share the single total
  // lifetime budget — HERO-AGENTS.md § Slot accounting). Dispatch a regular first
  // (lifetimeDispatched → 1 = cap); a hero appearing next must NOT dispatch.
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"R-1","hero":false}]',
    spawns: [{ id: "s-r1", sessionId: 611 }, { id: "s-h1", sessionId: 612 }],
  });
  const run = makeQueueRun(heroTmpl({ maxItems: 1 }), memStore());
  let now = 7_100_000;
  const deps = makeQueueDeps(fake, [run], () => now, 8, { heroMax: 2 });

  await arm(deps);
  now += 5000;
  await runQueueSweep(deps); // dispatch the one regular → the SINGLE lifetime budget is now spent
  assert.equal(run.lifetimeDispatched, 1, "total lifetime counter bumped by the regular dispatch");

  // The list now also surfaces a hero; the shared maxItems budget is spent (cap 1), so the hero
  // must NOT dispatch — the queue's lifetime cap applies to heroes too.
  const fake2 = makeQueueFake({
    surfaces: [queueSurface({ id: "s-r1", sessionID: 611, agentState: "working", queueKey: "R-1", queueName: "backlog" })],
    listJson: '[{"id":"R-1","hero":false},{"id":"H-1","hero":true}]',
    spawns: [{ id: "s-h1", sessionId: 612 }],
  });
  const deps2 = makeQueueDeps(fake2, [run], () => now, 8, { heroMax: 2 });
  now += 5000;
  await runQueueSweep(deps2); // reconcile R-1 as active; H-1 must NOT dispatch (cap hit)
  now += 5000;
  await runQueueSweep(deps2);

  assert.ok(!run.active.has("H-1"), "hero blocked — maxItems=1 already spent by the regular");
  assert.equal(run.lifetimeDispatched, 1, "no dispatch beyond the maxItems cap (heroes included)");
});

test("hero: the REGULAR pool is unaffected by heroes — heroes don't consume regular slots", async () => {
  // concurrency 2, list = 2 regulars + 2 heroes, heroMax 2. All FOUR should dispatch: the two
  // regulars fill both concurrency slots, the two heroes fill both hero slots — no cross-eat.
  const fake = makeQueueFake({
    surfaces: [],
    listJson:
      '[{"id":"R-1","hero":false},{"id":"R-2","hero":false},{"id":"H-1","hero":true},{"id":"H-2","hero":true}]',
    spawns: [
      { id: "s1", sessionId: 621 },
      { id: "s2", sessionId: 622 },
      { id: "s3", sessionId: 623 },
      { id: "s4", sessionId: 624 },
    ],
  });
  const run = makeQueueRun(heroTmpl({ concurrency: 2 }), memStore());
  let now = 7_200_000;
  const deps = makeQueueDeps(fake, [run], () => now, 8, { heroMax: 2 });

  await arm(deps);
  now += 5000;
  await runQueueSweep(deps);

  assert.equal(fake.calls.spawn.length, 4, "2 regulars + 2 heroes all dispatch (orthogonal pools)");
  assert.ok(run.active.has("R-1") && run.active.has("R-2"), "both regulars dispatched (concurrency 2)");
  assert.ok(run.active.has("H-1") && run.active.has("H-2"), "both heroes dispatched (heroMax 2)");
});

test("hero: the fleet-wide heroMax caps NEW hero dispatches (2 heroes listed, heroMax 1 → only 1)", async () => {
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"H-1","hero":true},{"id":"H-2","hero":true}]',
    spawns: [{ id: "s-h1", sessionId: 631 }, { id: "s-h2", sessionId: 632 }],
  });
  const run = makeQueueRun(heroTmpl({ concurrency: 5 }), memStore());
  let now = 7_300_000;
  const deps = makeQueueDeps(fake, [run], () => now, 8, { heroMax: 1 });

  await arm(deps);
  now += 5000;
  await runQueueSweep(deps);

  assert.equal(fake.calls.spawn.length, 1, "heroMax 1 caps to a single hero dispatch");
  assert.equal(run.lifetimeDispatched, 1, "the single total counter bumped by the one hero dispatch");
});

test("hero: heroMax=0 DISABLES hero dispatch — hero-marked items never spawn", async () => {
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"H-1","hero":true},{"id":"R-1","hero":false}]',
    spawns: [{ id: "s-r1", sessionId: 641 }],
  });
  const run = makeQueueRun(heroTmpl({ concurrency: 5 }), memStore());
  let now = 7_400_000;
  const deps = makeQueueDeps(fake, [run], () => now, 8, { heroMax: 0 });

  await arm(deps);
  now += 5000;
  await runQueueSweep(deps);

  assert.equal(fake.calls.spawn.length, 1, "only the regular dispatches; the hero is disabled");
  assert.ok(run.active.has("R-1"), "regular still dispatches with heroMax 0");
  assert.ok(!run.active.has("H-1"), "hero is NOT dispatched when heroMax=0");
});

test("hero: heroActiveGlobal is FLEET-WIDE — a live hero in run A blocks a new hero in run B (heroMax 1)", async () => {
  const fakeA = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"HA-1","hero":true}]',
    spawns: [{ id: "s-ha1", sessionId: 651 }],
  });
  const runA = makeQueueRun(heroTmpl({ name: "A", concurrency: 5 }), memStore());
  const runB = makeQueueRun(heroTmpl({ name: "B", concurrency: 5 }), memStore());
  let now = 7_500_000;
  const registry: RunRegistry = new Map([["A", runA], ["B", runB]]);
  const depsA = makeQueueDeps(fakeA, [], () => now, 8, { heroMax: 1, registry });

  // Arm both, then dispatch A's hero (fills the single fleet hero slot).
  await runQueueSweep(depsA);
  now += 5000;
  await runQueueSweep(depsA);
  assert.ok(runA.active.has("HA-1"), "run A's hero dispatched");
  assert.equal(totalHeroActiveRegistry(registry), 1, "one hero live fleet-wide");

  // Now run B lists a hero; heroActiveGlobal=1 == heroMax → heroRemaining 0 → B's hero waits.
  const fakeB = makeQueueFake({
    surfaces: [queueSurface({ id: "s-ha1", sessionID: 651, agentState: "working", queueKey: "HA-1", queueName: "A" })],
    listJson: '[{"id":"HB-1","hero":true}]',
    spawns: [{ id: "s-hb1", sessionId: 652 }],
  });
  const depsB = makeQueueDeps(fakeB, [], () => now, 8, { heroMax: 1, registry });
  now += 5000;
  await runQueueSweep(depsB);
  assert.ok(!runB.active.has("HB-1"), "run B's hero is blocked — fleet-wide hero cap is full");
});

test("hero: a hero dispatches into its OWN dedicated tab (firstTab, no grid caps, slot -1)", async () => {
  // Seed a regular already seated so the run has a grid tab; the hero must open a SEPARATE
  // tab anchored on the run's window, NOT a balanced grid split.
  const fake = makeQueueFake({
    surfaces: [queueSurface({ id: "u-r1", sessionID: 700, agentState: "working", queueKey: "R-1", queueName: "backlog" })],
    listJson: '[{"id":"R-1","hero":false},{"id":"H-1","hero":true}]',
    spawns: [{ id: "s-h1", sessionId: 701 }],
  });
  const run = makeQueueRun(heroTmpl({ concurrency: 5 }), memStore());
  // Pre-seat the regular (adopted from the live surface on the arm sweep's reconcile).
  let now = 7_600_000;
  const deps = makeQueueDeps(fake, [run], () => now, 8, { heroMax: 2 });

  await arm(deps); // reconcile adopts R-1 (orphan) + arms
  assert.ok(run.active.has("R-1"), "regular adopted from the live surface");
  now += 5000;
  await runQueueSweep(deps); // dispatch the hero into its own tab

  const heroSpawn = fake.calls.spawn.find((s) => (s.command as string).includes("H-1"));
  assert.ok(heroSpawn, "hero spawned");
  assert.equal(heroSpawn!.firstTab, true, "hero opens a NEW tab (firstTab)");
  assert.equal(heroSpawn!.balanced, undefined, "hero is NOT a balanced grid split");
  assert.equal(heroSpawn!.maxCols, undefined, "hero sends no grid caps (not in the grid)");
  assert.equal(heroSpawn!.maxRows, undefined, "hero sends no grid caps");
  assert.equal(heroSpawn!.windowAnchorUUID, "u-r1", "hero anchored on the run's existing window");
  assert.equal(run.active.get("H-1")!.gridSlot, -1, "hero record uses the -1 (no-grid) slot sentinel");
});

test("hero: a hero surface is annotated with hero:true", async () => {
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"H-1","hero":true}]',
    spawns: [{ id: "s-h1", sessionId: 711 }],
  });
  const run = makeQueueRun(heroTmpl({ concurrency: 5 }), memStore());
  let now = 7_700_000;
  const deps = makeQueueDeps(fake, [run], () => now, 8, { heroMax: 2 });

  await arm(deps);
  now += 5000;
  await runQueueSweep(deps);

  const ann = fake.calls.annotate.find((a) => a.ann.queueKey === "H-1");
  assert.ok(ann, "hero surface annotated");
  assert.equal(ann!.ann.hero, true, "annotation carries hero:true (drives the tab marker)");
});

test("hero: the close gate treats a hero as keep=true — a done+idle hero HOLDS in DONE_PENDING even with keepOnComplete:false + closeOnComplete:true", async () => {
  // A hero must NEVER be auto-closed (HERO-AGENTS.md § Lifecycle) regardless of the template's
  // keep/close settings. Dispatch a hero, drive it to done + stably idle, and assert it stays
  // DONE_PENDING and is NEVER force-closed (unlike a regular, which would auto-close).
  const surfaces: Surface[] = [];
  const fake = makeQueueFake({
    surfaces,
    listJson: '[{"id":"H-1","hero":true}]',
    spawns: [{ id: "s-h1", sessionId: 800 }],
    statusByKey: { "H-1": '{"state":"done"}' },
  });
  const run = makeQueueRun(
    heroTmpl({ concurrency: 5, keepOnComplete: false, closeOnComplete: true, closeStableSeconds: 5 }),
    memStore(),
  );
  let now = 8_000_000;
  const deps = makeQueueDeps(fake, [run], () => now, 8, { heroMax: 2 });

  await arm(deps);
  now += 5000;
  await runQueueSweep(deps); // dispatch the hero
  assert.ok(run.active.has("H-1"), "hero dispatched");

  // Make it live + idle; provider says done.
  surfaces.push(queueSurface({ id: "s-h1", sessionID: 800, agentState: "idle", queueKey: "H-1", queueName: "backlog" }));
  now += 5000;
  await runQueueSweep(deps); // SPAWNED→RUNNING→DONE_PENDING (status done), idle anchor starts
  now += 20_000; // well past closeStableSeconds
  await runQueueSweep(deps); // a REGULAR would advance to CLOSING here; a hero must HOLD

  assert.equal(run.active.get("H-1")!.state, "DONE_PENDING", "hero holds in DONE_PENDING (never auto-closed)");
  assert.equal(fake.calls.forceClose.length, 0, "hero is never force-closed by the supervisor");
});

test("hero: persistence — a promoted/hero split rehydrates as a hero across a sidecar restart", async () => {
  // Dispatch a hero, then simulate a restart by building a FRESH run on the SAME store and
  // reconciling: the run-level hero set + the record's hero bit must both come back.
  const store = memStore();
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"H-1","hero":true}]',
    spawns: [{ id: "s-h1", sessionId: 810 }],
  });
  const run = makeQueueRun(heroTmpl({ concurrency: 5 }), store);
  let now = 8_100_000;
  const deps = makeQueueDeps(fake, [run], () => now, 8, { heroMax: 2 });
  await arm(deps);
  now += 5000;
  await runQueueSweep(deps);
  assert.ok(run.hero.has("H-1"), "hero in the live run's hero set");

  // The store persisted the hero set + the record's hero bit.
  const persisted = loadStore(store);
  const rec = persisted.find((a) => a.key === "H-1");
  assert.ok(rec, "hero record persisted");
  assert.equal(rec!.hero, true, "persisted record carries hero:true");
  assert.deepEqual(loadHero(store), ["H-1"], "run-level hero set persisted");

  // RESTART: a fresh run on the same store, with the surface now live (so reconcile keeps it).
  const fake2 = makeQueueFake({
    surfaces: [queueSurface({ id: "s-h1", sessionID: 810, agentState: "working", queueKey: "H-1", queueName: "backlog" })],
    listJson: '[{"id":"H-1","hero":true}]',
  });
  const run2 = makeQueueRun(heroTmpl({ concurrency: 5 }), store);
  const deps2 = makeQueueDeps(fake2, [run2], () => now, 8, { heroMax: 2 });
  now += 5000;
  await runQueueSweep(deps2); // first sweep reconciles + rehydrates the hero set

  assert.ok(run2.hero.has("H-1"), "hero set rehydrated after restart");
  assert.equal(run2.active.get("H-1")!.hero, true, "reconciled record re-stamped as a hero");
  assert.equal(totalHeroActiveRegistry(new Map([["backlog", run2]])), 1, "the restored hero counts against heroActiveGlobal");
});

// ---------------------------------------------------------------------------
// (hero) promote / demote command SIDE EFFECTS (Stage 3). promote flips the hero bit +
// EJECTS the split into its own tab (move_split_to_new_tab) + re-stamps the hero annotation;
// demote flips it false + drops the hero annotation (never re-packs into a grid). Promotion
// NEVER blocks on the hero cap (may exceed); no NEW hero dispatches until it drains under.
// ---------------------------------------------------------------------------

test("hero: PROMOTE ejects the split into its own tab + annotates hero:true (the side effect)", async () => {
  // A running regular R-1 (adopted from a live surface). A `promote` command must eject it via
  // move_split_to_new_tab, flip the run-level hero bit, and re-stamp the annotation hero:true.
  const fake = makeQueueFake({
    surfaces: [queueSurface({ id: "u-r1", sessionID: 900, agentState: "working", queueKey: "R-1", queueName: "backlog" })],
    listJson: "[]", // nothing new to dispatch — focus on the promote side effect
  });
  const run = makeQueueRun(heroTmpl({ concurrency: 5 }), memStore());
  let now = 9_000_000;
  // Arm WITHOUT the command so the adopt lands as a regular before the promote sweep.
  const armDeps = makeQueueDeps(fake, [run], () => now, 8, { heroMax: 2 });
  await arm(armDeps); // reconcile adopts R-1 (regular)
  assert.ok(run.active.has("R-1"), "regular adopted");
  assert.equal(run.active.get("R-1")!.hero, false, "starts as a regular");

  now += 5000;
  const deps = makeQueueDeps(fake, [run], () => now, 8, {
    heroMax: 2,
    takeCommands: commandsOnce([{ action: "promote", run: "backlog", surfaceUUID: "u-r1", key: "R-1" }]),
  });
  await runQueueSweep(deps); // drains the promote command + fires runPromote

  // EJECT: the promote used the move_split_to_new_tab keybind action on the surface.
  assert.ok(
    fake.calls.perform.some((p) => p.id === "u-r1" && p.action === "move_split_to_new_tab"),
    "promote ejected the split into its own tab via move_split_to_new_tab",
  );
  // The run-level hero set + the per-record bit both flipped, and the grid slot is the -1 sentinel.
  assert.ok(run.hero.has("R-1"), "R-1 added to the run-level hero set");
  assert.equal(run.active.get("R-1")!.hero, true, "R-1 record re-stamped as a hero");
  assert.equal(run.active.get("R-1")!.gridSlot, -1, "promoted hero uses the -1 (no-grid) slot sentinel");
  // The annotation carries hero:true (drives the GUI tab marker / tile).
  const ann = fake.calls.annotate.find((a) => a.id === "u-r1" && a.ann.hero === true);
  assert.ok(ann, "promoted surface annotated hero:true");
});

test("hero: PROMOTE is counter-neutral — it does NOT refund the maxItems lifetime slot", async () => {
  // A regular R-1 is DISPATCHED, bumping the single total lifetimeDispatched to 1 (one lifetime
  // slot spent). Promoting it must NOT decrement that counter: an item launched as a regular
  // counts against maxItems FOREVER, so promotion can't refund a slot (which would let the queue
  // over-launch). Marking it a hero frees only its CONCURRENCY slot (heroes run off-grid).
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"R-1","hero":false}]',
    spawns: [{ id: "s-r1", sessionId: 950 }],
  });
  const run = makeQueueRun(heroTmpl({ concurrency: 5 }), memStore());
  let now = 9_050_000;
  const deps = makeQueueDeps(fake, [run], () => now, 8, { heroMax: 2 });
  await arm(deps);
  now += 5000;
  await runQueueSweep(deps); // DISPATCH R-1 as a regular
  assert.ok(run.active.has("R-1"), "regular R-1 dispatched");
  assert.equal(run.lifetimeDispatched, 1, "total lifetime counter bumped by the dispatch");

  // R-1's spawned surface is now live; promote it. Swap the client on the same run so state carries.
  const fake2 = makeQueueFake({
    surfaces: [queueSurface({ id: "s-r1", sessionID: 950, agentState: "working", queueKey: "R-1", queueName: "backlog" })],
    listJson: '[{"id":"R-1","hero":false}]',
  });
  now += 5000;
  const deps2 = makeQueueDeps(fake2, [run], () => now, 8, {
    heroMax: 2,
    takeCommands: commandsOnce([{ action: "promote", run: "backlog", surfaceUUID: "s-r1", key: "R-1" }]),
  });
  await runQueueSweep(deps2); // promote R-1

  assert.ok(run.hero.has("R-1"), "R-1 promoted to a hero");
  assert.equal(run.active.get("R-1")?.hero, true, "the assignment is now a hero (off the regular pool)");
  assert.equal(run.lifetimeDispatched, 1, "the lifetime counter is UNCHANGED — no maxItems refund");
});

test("hero: PROMOTE frees a concurrency slot but the queue never dispatches beyond maxItems", async () => {
  // The reported bug. maxItems 1 → only ONE agent may EVER launch. Dispatch R-1
  // (lifetimeDispatched → 1 = cap). Promoting R-1 → hero frees its CONCURRENCY slot, but the
  // historical maxItems count stands — so even though a second regular R-2 is now listed and
  // there's plenty of concurrency room (5), R-2 must NOT launch. (Under the earlier buggy refund
  // lifetimeDispatched dropped to 0 and R-2 over-launched past the cap.)
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"R-1","hero":false}]',
    spawns: [{ id: "s-r1", sessionId: 970 }],
  });
  const run = makeQueueRun(heroTmpl({ concurrency: 5, maxItems: 1 }), memStore());
  let now = 9_070_000;
  const deps = makeQueueDeps(fake, [run], () => now, 8, { heroMax: 2 });
  await arm(deps);
  now += 5000;
  await runQueueSweep(deps); // dispatch R-1 → the single lifetime budget (cap 1) is spent
  assert.equal(run.lifetimeDispatched, 1);

  const fake2 = makeQueueFake({
    surfaces: [queueSurface({ id: "s-r1", sessionID: 970, agentState: "working", queueKey: "R-1", queueName: "backlog" })],
    listJson: '[{"id":"R-1","hero":false},{"id":"R-2","hero":false}]',
    spawns: [{ id: "s-r2", sessionId: 971 }],
  });
  now += 5000;
  const deps2 = makeQueueDeps(fake2, [run], () => now, 8, {
    heroMax: 2,
    takeCommands: commandsOnce([{ action: "promote", run: "backlog", surfaceUUID: "s-r1", key: "R-1" }]),
  });
  await runQueueSweep(deps2); // promote R-1 + attempt R-2
  now += 5000;
  await runQueueSweep(deps2);

  assert.ok(run.hero.has("R-1"), "R-1 promoted");
  assert.equal(run.lifetimeDispatched, 1, "historical maxItems count unchanged (no refund)");
  assert.ok(!run.active.has("R-2"), "R-2 NOT launched — the maxItems cap of 1 stands despite the freed concurrency slot");
});

test("hero: PROMOTION never blocks (may exceed heroMax); no NEW hero dispatches until it drains under", async () => {
  // heroMax 1. One live hero H-1 already fills the fleet slot. Promoting a running regular R-1
  // pushes heroActiveGlobal to 2 (OVER the cap of 1) — promotion must SUCCEED anyway. While over
  // cap, a newly-listed hero H-3 must NOT dispatch. Once the heroes DRAIN back under the cap, the
  // waiting hero dispatches.
  const surfaces: Surface[] = [
    queueSurface({ id: "u-h1", sessionID: 910, agentState: "working", queueKey: "H-1", queueName: "backlog" }),
    queueSurface({ id: "u-r1", sessionID: 911, agentState: "working", queueKey: "R-1", queueName: "backlog" }),
  ];
  const fake = makeQueueFake({
    surfaces,
    // H-1 is already a hero (persisted below via the run-level set); R-1 regular; H-3 a NEW hero.
    listJson: '[{"id":"H-1","hero":true},{"id":"R-1","hero":false},{"id":"H-3","hero":true}]',
    spawns: [{ id: "s-h3", sessionId: 913 }],
  });
  const run = makeQueueRun(heroTmpl({ concurrency: 5 }), memStore());
  // Pre-seed H-1 as an existing hero so heroActiveGlobal starts at 1 (== heroMax).
  run.hero.add("H-1");
  let now = 9_100_000;
  // Arm WITHOUT the command so the promote fires on a real dispatch sweep (arm suppresses dispatch).
  const armDeps = makeQueueDeps(fake, [run], () => now, 8, { heroMax: 1 });
  await arm(armDeps); // reconcile adopts H-1 + R-1
  assert.ok(run.active.has("H-1") && run.active.has("R-1"), "both live surfaces adopted");

  now += 5000;
  const deps = makeQueueDeps(fake, [run], () => now, 8, {
    heroMax: 1,
    takeCommands: commandsOnce([{ action: "promote", run: "backlog", surfaceUUID: "u-r1", key: "R-1" }]),
  });
  await runQueueSweep(deps); // promote R-1 (over-cap) + attempt to dispatch H-3

  // Promotion SUCCEEDED even though it pushes heroActiveGlobal to 2 > heroMax 1.
  assert.ok(run.hero.has("R-1"), "R-1 promoted despite being over the hero cap");
  assert.equal(totalHeroActiveRegistry(new Map([["backlog", run]])), 2, "heroActiveGlobal exceeds heroMax after promotion");
  // The NEW hero H-3 is BLOCKED while over cap (heroRemaining = 1 - 2 = clamped 0).
  assert.ok(!run.active.has("H-3"), "no NEW hero dispatches while over the cap");
  assert.equal(fake.calls.spawn.length, 0, "nothing spawned while over cap");

  // DRAIN: both heroes' surfaces go away (a human closed them) → reconcile prunes them →
  // heroActiveGlobal drops to 0 (< heroMax 1). Now the waiting hero H-3 must dispatch.
  surfaces.length = 0;
  const fake2 = makeQueueFake({
    surfaces,
    listJson: '[{"id":"H-3","hero":true}]',
    spawns: [{ id: "s-h3", sessionId: 913 }],
  });
  const deps2 = makeQueueDeps(fake2, [run], () => now, 8, { heroMax: 1 });
  now += 60_000; // past the pending/session-gone grace so the two vanished heroes prune
  await runQueueSweep(deps2); // reconcile prunes H-1/R-1; first sweep on fake2 re-arms dispatch
  now += 5000;
  await runQueueSweep(deps2); // now under cap → H-3 dispatches

  assert.ok(run.active.has("H-3"), "the waiting hero dispatches once live heroes drain under the cap");
  assert.equal(run.active.get("H-3")!.hero, true, "H-3 is a hero");
});

test("hero: DEMOTE flips the bit false + drops the hero annotation; the item re-enters the regular pool", async () => {
  // A live hero H-1 that is the run's ONLY pane. A `demote` command clears the run-level hero bit,
  // drops the hero annotation (hero:false), and — because there is NO other grid pane to anchor a
  // re-pack on — leaves the split in its own tab (no moveSurfaceIntoTab). After the demote the
  // split counts as a REGULAR for accounting (heroActiveGlobal drops). (The re-pack WHEN a grid
  // anchor exists is covered by the next test.)
  const fake = makeQueueFake({
    surfaces: [queueSurface({ id: "u-h1", sessionID: 920, agentState: "working", queueKey: "H-1", queueName: "backlog" })],
    listJson: "[]",
  });
  const run = makeQueueRun(heroTmpl({ concurrency: 5 }), memStore());
  run.hero.add("H-1"); // it is a hero going in
  let now = 9_200_000;
  // Arm WITHOUT the command so H-1 is adopted + re-stamped a hero before the demote sweep.
  const armDeps = makeQueueDeps(fake, [run], () => now, 8, { heroMax: 2 });
  await arm(armDeps); // reconcile adopts H-1, re-stamped as a hero
  assert.equal(run.active.get("H-1")!.hero, true, "H-1 starts a hero");
  assert.equal(totalHeroActiveRegistry(new Map([["backlog", run]])), 1, "counts as a hero before demote");

  const performBefore = fake.calls.perform.length;
  const moveBefore = fake.calls.moveIntoTab.length;
  now += 5000;
  const deps = makeQueueDeps(fake, [run], () => now, 8, {
    heroMax: 2,
    takeCommands: commandsOnce([{ action: "demote", run: "backlog", surfaceUUID: "u-h1", key: "H-1" }]),
  });
  await runQueueSweep(deps); // drains the demote command + fires runDemote

  // The hero bit is cleared and it re-enters the REGULAR pool for accounting.
  assert.ok(!run.hero.has("H-1"), "H-1 removed from the run-level hero set");
  assert.equal(run.active.get("H-1")!.hero, false, "H-1 record re-classified regular");
  assert.equal(totalHeroActiveRegistry(new Map([["backlog", run]])), 0, "no longer counts against heroActiveGlobal");
  // The annotation was dropped (hero:false written).
  const ann = fake.calls.annotate.find((a) => a.id === "u-h1" && a.ann.hero === false);
  assert.ok(ann, "demote annotated hero:false (drops the GUI marker)");
  // DEMOTE never ejects (no perform), and with no grid anchor it does not move-into-tab either.
  assert.equal(fake.calls.perform.length, performBefore, "demote does not eject/perform any action");
  assert.equal(fake.calls.moveIntoTab.length, moveBefore, "no anchor → no re-pack (stays in own tab)");
});

test("hero: DEMOTE re-packs the split back into the run's grid when a regular anchor exists", async () => {
  // A run with a seated REGULAR R-1 (grid slot 0) beside a hero H-1 (ejected to its own tab,
  // gridSlot -1). Demoting H-1 clears the hero bit AND re-packs it into R-1's grid tab via a
  // balanced moveSurfaceIntoTab (the same proven cross-tab move the packer/adopt use), resetting
  // H-1's gridSlot to the lowest free slot (1) so it re-enters occupancy accounting.
  const fake = makeQueueFake({
    surfaces: [
      queueSurface({ id: "u-r1", sessionID: 921, agentState: "working", queueKey: "R-1", queueName: "backlog" }),
      queueSurface({ id: "u-h1", sessionID: 920, agentState: "working", queueKey: "H-1", queueName: "backlog" }),
    ],
    listJson: "[]",
  });
  const run = makeQueueRun(heroTmpl({ concurrency: 5 }), memStore());
  run.active.set("R-1", seatedAsgn("R-1", "u-r1", 0)); // regular, occupies grid slot 0
  run.active.set("H-1", { ...seatedAsgn("H-1", "u-h1", -1), hero: true }); // hero, ejected (slot -1)
  run.hero.add("H-1");
  let now = 9_300_000;

  const moveBefore = fake.calls.moveIntoTab.length;
  const deps = makeQueueDeps(fake, [run], () => now, 8, {
    heroMax: 2,
    takeCommands: commandsOnce([{ action: "demote", run: "backlog", surfaceUUID: "u-h1", key: "H-1" }]),
  });
  await runQueueSweep(deps); // drains the demote command + fires runDemote

  assert.ok(!run.hero.has("H-1"), "H-1 removed from the run-level hero set");
  assert.equal(run.active.get("H-1")!.hero, false, "H-1 record re-classified regular");
  // RE-PACK: moved into R-1's tab, anchored on R-1, balanced, with the template grid caps.
  const move = fake.calls.moveIntoTab.find((m) => m.sourceUUID === "u-h1");
  assert.ok(move, "demote re-packed H-1 into the grid (moveSurfaceIntoTab called)");
  assert.equal(move!.targetAnchorUUID, "u-r1", "anchored on the seated regular R-1");
  assert.equal(move!.balanced, true, "balanced move (the packer's tiling)");
  assert.equal(move!.maxCols, 3, "forwards template grid.cols");
  assert.equal(move!.maxRows, 3, "forwards template grid.rows");
  // H-1's grid slot is reset so it rejoins occupancy (R-1 holds 0 → lowest free is 1).
  assert.equal(run.active.get("H-1")!.gridSlot, 1, "H-1 re-assigned the lowest free grid slot");
  assert.ok(fake.calls.moveIntoTab.length > moveBefore, "a re-pack move happened");
});

// (hero) The `list_surfaces` hero read-back — the wire-contract visibility chokepoint
// (HERO-AGENTS.md): `MCPLayout.surfacesJSONData` emits `hero` on a hero row, and the sidecar
// reads it back off the `Surface` row into `LiveSurface.hero` (mirroring the queueKey read-back).
// The run-level `hero` Set stays authoritative; this only proves the bit survives the round-trip.
test("hero: projectLiveSurfaces echoes the hero bit back off the list_surfaces row", () => {
  const surfaces: Surface[] = [
    Object.assign(surface({ id: "u-h1", sessionID: 920 }), {
      queueKey: "H-1",
      queueName: "backlog",
      hero: true,
    }),
    Object.assign(surface({ id: "u-r1", sessionID: 921 }), {
      queueKey: "R-1",
      queueName: "backlog",
      hero: false,
    }),
    // A row with no hero field at all (pre-upgrade GUI / regular tile) → hero omitted.
    Object.assign(surface({ id: "u-r2", sessionID: 922 }), {
      queueKey: "R-2",
      queueName: "backlog",
    }),
    // A foreign run's row is filtered out entirely (queueName mismatch).
    Object.assign(surface({ id: "u-x", sessionID: 923 }), {
      queueKey: "X-1",
      queueName: "other-run",
      hero: true,
    }),
  ];
  const live = projectLiveSurfaces(surfaces, "backlog");
  const byUUID = new Map(live.map((l) => [l.surfaceUUID, l]));
  assert.equal(byUUID.size, 3, "the foreign-run row is skipped");
  assert.equal(byUUID.get("u-h1")!.hero, true, "hero:true echoed back");
  assert.equal(byUUID.get("u-r1")!.hero, false, "hero:false echoed back");
  assert.equal("hero" in byUUID.get("u-r2")!, false, "an absent hero field stays omitted");
});

test("hero: promote persistence round-trip — a promoted split rehydrates a hero across a restart", async () => {
  // Promote a running regular via a command, confirm the hero bit is PERSISTED, then simulate a
  // sidecar restart (fresh run on the same store) and confirm the promoted split comes back a hero.
  const store = memStore();
  const fake = makeQueueFake({
    surfaces: [queueSurface({ id: "u-r1", sessionID: 930, agentState: "working", queueKey: "R-1", queueName: "backlog" })],
    listJson: "[]",
  });
  const run = makeQueueRun(heroTmpl({ concurrency: 5 }), store);
  let now = 9_300_000;
  const armDeps = makeQueueDeps(fake, [run], () => now, 8, { heroMax: 2 });
  await arm(armDeps); // adopt R-1
  now += 5000;
  const deps = makeQueueDeps(fake, [run], () => now, 8, {
    heroMax: 2,
    takeCommands: commandsOnce([{ action: "promote", run: "backlog", surfaceUUID: "u-r1", key: "R-1" }]),
  });
  await runQueueSweep(deps); // promote R-1
  assert.ok(run.hero.has("R-1"), "R-1 promoted");

  // The run-level hero set + the record's hero bit are persisted to the store.
  assert.deepEqual(loadHero(store), ["R-1"], "promoted key persisted in the run-level hero set");
  const rec = loadStore(store).find((a) => a.key === "R-1");
  assert.ok(rec, "record persisted");
  assert.equal(rec!.hero, true, "persisted record carries hero:true");

  // RESTART: a fresh run on the same store; the surface is still live.
  const fake2 = makeQueueFake({
    surfaces: [queueSurface({ id: "u-r1", sessionID: 930, agentState: "working", queueKey: "R-1", queueName: "backlog" })],
    listJson: "[]",
  });
  const run2 = makeQueueRun(heroTmpl({ concurrency: 5 }), store);
  const deps2 = makeQueueDeps(fake2, [run2], () => now, 8, { heroMax: 2 });
  now += 5000;
  await runQueueSweep(deps2); // first sweep reconciles + rehydrates the hero set

  assert.ok(run2.hero.has("R-1"), "hero set rehydrated after restart");
  assert.equal(run2.active.get("R-1")!.hero, true, "reconciled record re-stamped as a hero after restart");
});

// ---------------------------------------------------------------------------
// (schedules) recurring scan-agent dispatch / single-flight / completion / auto-close.
// ---------------------------------------------------------------------------

test("runQueueSweep: dispatches a DUE schedule, holds single-flight while live, delivers prose, re-arms on close", async () => {
  const store = memStore();
  const run = makeQueueRun(
    tmpl({ schedules: [{ id: "s1", cron: "* * * * *", prompt: "scan the docs", closeOnComplete: true }] }),
    store,
  );
  const spec: QueueFakeSpec = { surfaces: [], listJson: "[]", spawns: [{ id: "sch-1", sessionId: 500 }] };
  const fake = makeQueueFake(spec);
  // Whole-minute clock so `* * * * *` fires deterministically (armedAt lands on a firing).
  const M = 60_000;
  let now = 100 * M;
  const deps = makeQueueDeps(fake, [run], () => now);

  // sweep 1: ARM (dispatch-suppressed) — no spawn.
  await runQueueSweep(deps);
  assert.equal(fake.calls.spawn.length, 0, "first sweep arms, does not dispatch");
  assert.ok(run.schedules.get("s1"), "s1 armed");

  // sweep 2: DUE (armedAt=100M is a firing; now is past it) → dispatch the scheduled split.
  now = 101 * M;
  await runQueueSweep(deps);
  assert.equal(fake.calls.spawn.length, 1, "due schedule dispatches exactly one split");
  const ann = fake.calls.annotate.find((a) => (a.ann as { scheduleId?: string }).scheduleId === "s1");
  assert.ok(ann, "the scheduled split is annotated with its scheduleId");
  assert.equal((ann!.ann as { schedule?: boolean }).schedule, true, "annotated schedule:true");
  assert.equal(run.scheduleActive.has("s1"), true, "tracked as the live scheduled run");
  // The prose + schedule identity ride the spawn command as a GHOSTTY_SCHEDULE_* env prefix
  // (consumed by the agent, e.g. `claude "$GHOSTTY_SCHEDULE_PROMPT"`) — NOT typed in.
  const cmd = fake.calls.spawn[0].command as string;
  assert.ok(cmd.includes("GHOSTTY_SCHEDULE_ID='s1'"), "schedule id env prefix on the command");
  assert.ok(cmd.includes("GHOSTTY_SCHEDULE_PROMPT='scan the docs'"), "prose delivered as env");

  // The scheduled split is now live in list_surfaces → single-flight holds (no second dispatch).
  spec.surfaces = [
    Object.assign(surface({ id: "sch-1", agentState: "working" }), {
      queueName: run.runName,
      scheduleId: "s1",
    }) as Surface & { sessionID?: number },
  ];
  (spec.surfaces[0] as { sessionID?: number }).sessionID = 500;

  // sweep 3: single-flight (no new spawn).
  now = 102 * M;
  await runQueueSweep(deps);
  assert.equal(fake.calls.spawn.length, 1, "single-flight: no second dispatch while live");

  // sweep 4: the split CLOSED (gone from list_surfaces) → completion re-anchors the cadence.
  spec.surfaces = [];
  now = 103 * M;
  await runQueueSweep(deps);
  assert.equal(run.scheduleActive.has("s1"), false, "single-flight slot freed on close");
  assert.equal(run.schedules.get("s1")!.lastCompletionAt, 103 * M, "completion re-anchored to close time");
});

test("runQueueSweep: auto-closes an EXITED scheduled split when closeOnComplete (the default)", async () => {
  const store = memStore();
  const run = makeQueueRun(
    tmpl({ schedules: [{ id: "s1", cron: "* * * * *", prompt: "scan", closeOnComplete: true }] }),
    store,
  );
  const spec: QueueFakeSpec = { surfaces: [], listJson: "[]", spawns: [{ id: "sch-1", sessionId: 500 }] };
  const fake = makeQueueFake(spec);
  const M = 60_000;
  let now = 100 * M;
  const deps = makeQueueDeps(fake, [run], () => now);

  await runQueueSweep(deps); // arm
  now = 101 * M;
  await runQueueSweep(deps); // dispatch → sch-1

  // The scheduled agent's child EXITED (scan finished) while the split is still present.
  spec.surfaces = [
    Object.assign(surface({ id: "sch-1", exited: true }), {
      queueName: run.runName,
      scheduleId: "s1",
    }),
  ];
  now = 102 * M;
  await runQueueSweep(deps);
  assert.ok(fake.calls.forceClose.includes("sch-1"), "an exited scheduled split is force-closed");
});

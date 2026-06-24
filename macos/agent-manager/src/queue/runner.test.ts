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
  DEFAULT_PENDING_GRACE_MS,
  type QueueDeps,
  type QueueRun,
} from "./runner.js";
import { ConcurrencyBudget as QueueBudget } from "./supervisor.js";
import type { QueueCommand, RunFactory, RunRegistry } from "./commands.js";
import type { QueueStatusReport } from "./status.js";
import { loadStore, type StoreIO } from "./store.js";
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
    closeStableSeconds: 5,
    quitWhenEmpty: false,
    params: [],
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
    list: number;
    status: string[];
    reports: QueueStatusReport[];
  };
}

function makeQueueFake(spec: QueueFakeSpec): QueueFake {
  const calls: QueueFake["calls"] = {
    spawn: [],
    annotate: [],
    forceClose: [],
    signal: [],
    sendKey: [],
    list: 0,
    status: [],
    reports: [],
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
    async sendKey(id: string, key: string): Promise<void> {
      calls.sendKey.push({ id, key });
    },
    async reportQueueStatus(status: QueueStatusReport): Promise<void> {
      calls.reports.push(status);
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
  // latch RE-ARMS (clears). quitWhenEmpty is false in tmpl() so the empty list won't quit.
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
  now += 200_000; // past grace so the killed record is pruned, isolating the latch
  await runQueueSweep(deps); // first post-restart sweep reconciles + rehydrates the latch (dispatch suppressed)
  assert.ok(run2.dispatched.has("K-1"), "latch rehydrated from the store on restart");
  assert.equal(run2.active.has("K-1"), false, "killed record pruned — only the rehydrated latch remains");
  now += 5000;
  await runQueueSweep(deps); // now dispatch-armed; K-1 still listed → latch suppresses
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
  // adopted pane got a real grid slot (slot 0) on reconcile, so the refill targets it.
  const spawnArgs = fake.calls.spawn[0];
  assert.notEqual(spawnArgs.firstTab, true, "refill must NOT open a new tab (firstTab absent)");
  assert.equal(spawnArgs.direction, "right", "the refill splits beside the adopted pane");
  assert.equal(spawnArgs.targetUUID, "orphan-1", "the split targets the adopted pane");
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
    maxTotal: 8, pendingGraceMs: DEFAULT_PENDING_GRACE_MS,
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
    persistActiveRuns: rec.persist, maxTotal: 8, pendingGraceMs: DEFAULT_PENDING_GRACE_MS,
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
    persistActiveRuns: rec.persist, maxTotal: 8, pendingGraceMs: DEFAULT_PENDING_GRACE_MS,
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
    persistActiveRuns: rec.persist, maxTotal: 8, pendingGraceMs: DEFAULT_PENDING_GRACE_MS,
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
    maxTotal: 8, pendingGraceMs: DEFAULT_PENDING_GRACE_MS,
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
// (14) quitWhenEmpty (§8a): the run QUITS when a sweep sees a SUCCESSFUL empty list
//      AND nothing is active — but NOT while agents are still running, and NOT on a
//      flaky/failed list.
// ---------------------------------------------------------------------------

test("runQueueSweep: quitWhenEmpty run with an empty list + no active agents removes itself", () => {
  // arm (suppressed), then a sweep that fetches a clean empty list with nothing active
  // → the run quits (removed from the registry) even though maxItems is not reached.
  return (async () => {
    const fake = makeQueueFake({ surfaces: [], listJson: "[]" });
    const run = makeQueueRun(tmpl({ quitWhenEmpty: true }), memStore());
    let now = 1_000_000;
    const deps = makeQueueDeps(fake, [run], () => now);

    await runQueueSweep(deps); // arm (dispatch suppressed; no list fetch yet)
    assert.equal(deps.registry.size, 1, "still armed after the first sweep");
    now += 5000;
    await runQueueSweep(deps); // armed → fetch empty list → quit
    assert.equal(deps.registry.size, 0, "quit on empty list + no active");
    assert.equal(fake.calls.spawn.length, 0, "nothing was ever dispatched");
  })();
});

test("runQueueSweep: quitWhenEmpty does NOT quit while an agent is still running (empty list, active>0)", () => {
  return (async () => {
    // A mutable spec so we can empty the list AFTER an item is dispatched (the agent
    // 'claimed' it → it left the filter), while the agent keeps running.
    const spec = {
      surfaces: [] as Surface[],
      listJson: '[{"id":"Q-1","title":"t"}]',
      spawns: [{ id: "spawned-1", sessionId: 4242 }],
    };
    const fake = makeQueueFake(spec);
    const run = makeQueueRun(tmpl({ quitWhenEmpty: true }), memStore());
    let now = 2_000_000;
    const deps = makeQueueDeps(fake, [run], () => now);

    await runQueueSweep(deps); // arm
    now += 5000;
    await runQueueSweep(deps); // dispatch Q-1 → SPAWNED (active = 1)
    assert.equal(fake.calls.spawn.length, 1);
    assert.equal(run.active.size, 1, "Q-1 tracked");

    // The agent claimed its item, so the source list is now empty — but the agent is
    // still running. The run must KEEP polling, not quit.
    spec.listJson = "[]";
    spec.surfaces = [queueSurface({ id: "spawned-1", queueKey: "Q-1", queueName: "backlog" })];
    now += 5000;
    await runQueueSweep(deps);
    assert.equal(deps.registry.size, 1, "must NOT quit while the agent is still active");
    assert.ok(run.active.has("Q-1"), "the running agent is still tracked");
  })();
});

test("runQueueSweep: quitWhenEmpty does NOT quit on a FLAKY (non-zero) list", () => {
  return (async () => {
    // A list provider that always fails → fetchListResult ok:false → NOT 'empty' → never quits.
    const fake = makeQueueFake({ surfaces: [] });
    fake.exec = async (argv: string[]) => {
      if (argv[0] === "list") return { code: 1, stdout: "", stderr: "boom" };
      return { code: 0, stdout: '{"state":"working"}', stderr: "" };
    };
    const run = makeQueueRun(tmpl({ quitWhenEmpty: true }), memStore());
    let now = 3_000_000;
    const deps = makeQueueDeps(fake, [run], () => now);
    await runQueueSweep(deps); // arm
    now += 5000;
    await runQueueSweep(deps); // list FAILS → not empty → must NOT quit
    assert.equal(deps.registry.size, 1, "a failed list never reads as empty (no quit)");
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

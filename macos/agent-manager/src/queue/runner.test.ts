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
import { DEFAULT_MANAGER_CONFIG, MANAGER_MODEL } from "../manager.js";
import { makeOverrideLoader, type OverrideFs } from "../prompt.js";

import {
  runQueueSweep,
  makeQueueRun,
  occupiesSlot,
  DEFAULT_PENDING_GRACE_MS,
  type QueueDeps,
  type QueueRun,
} from "./runner.js";
import { ConcurrencyBudget as QueueBudget } from "./supervisor.js";
import type { QueueCommand, RunFactory, RunRegistry } from "./commands.js";
import { loadStore, type StoreIO } from "./store.js";
import type { Exec, ExecResult } from "./provider.js";
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
    intervals: { listMs: 45000, statusMs: 20000 },
    provider: {
      list: { command: ["list"], keyField: "id", titleField: "title", urlField: "url" },
      status: { command: ["status", "{key}"], doneStates: ["done"] },
    },
    onAgentExit: "leave-and-bell",
    closeOnComplete: true,
    closeStableSeconds: 5,
    quitWhenEmpty: false,
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
    managerOverrides: makeOverrideLoader("/home/test", noOverrideFs),
    managerCfg: { ...DEFAULT_MANAGER_CONFIG },
    managerModel: MANAGER_MODEL,
    suggest: async () => {
      throw new Error("unexpected manager call");
    },
    lastSuggestionBySession: new Map(),
    managerBudget: new ConcurrencyBudget(DEFAULT_MANAGER_CONFIG.maxConcurrent),
    // queue intentionally OMITTED → pass 3 is a no-op.
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
  assert.equal(fake.calls.spawn[0].command, "claude work");
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
// (3) The supervisor is NOT starved when the summarizer/manager budgets are
//     exhausted (mirrors the existing manager-not-starved test): pass 3 runs with
//     its OWN budget after passes 1+2 settle, so a busy summarizer/manager fleet
//     never denies it a dispatch slot.
// ---------------------------------------------------------------------------

test("runSweep: the supervisor is NOT starved when summarizer + manager budgets are exhausted", async () => {
  // A busy fleet of working/waiting agents would exhaust the summarizer (cap 1) and
  // manager (cap 1) budgets; the queue pass must STILL dispatch its candidate.
  const queueRun = makeQueueRun(tmpl(), memStore());
  const fake = makeQueueFake({
    surfaces: [
      surface({ id: "a1", agentState: "working" }),
      surface({ id: "w1", agentState: "waiting", userNotes: "ship" }),
    ],
    listJson: '[{"id":"Q-1","title":"queued work"}]',
    spawns: [{ id: "spawned-q1", sessionId: 777 }],
  });
  let now = 2_000_000;
  const deps = makeLoopDeps(fake.client);
  // Tiny shared budgets so passes 1+2 fully consume them.
  deps.cfg = { ...DEFAULT_CONFIG, maxConcurrent: 1 };
  deps.budget = new ConcurrencyBudget(1);
  deps.managerBudget = new ConcurrencyBudget(1);
  // Count pass-1/pass-2 model calls so we can PROVE the busy fleet was actually
  // processed (not silently skipped) at the time the queue still dispatched — without
  // that, a green result wouldn't distinguish "queue not starved" from "passes 1+2
  // never ran". (Budgets are released by the time runSweep returns, so we assert the
  // work happened + the structural guarantee below, not a mid-sweep budget snapshot.)
  let summarizeCalls = 0;
  let suggestCalls = 0;
  deps.summarize = async () => {
    summarizeCalls += 1;
    return '{"summary":"ok"}';
  };
  deps.suggest = async () => {
    suggestCalls += 1;
    return '{"suggestion":"go","confidence":0.9}';
  };
  deps.now = () => now;
  deps.queue = makeQueueDeps(fake, [queueRun], () => now);

  // The structural guarantee that makes starvation IMPOSSIBLE: the queue pass owns a
  // budget object DISTINCT from both the summarizer and the manager budgets, so passes
  // 1+2 consuming theirs can never deny the queue a slot.
  assert.notEqual(deps.queue!.budget, deps.budget, "queue budget != summarizer budget");
  assert.notEqual(deps.queue!.budget, deps.managerBudget, "queue budget != manager budget");

  // The queue runs on its OWN independent timer (`runQueueSweepSafe`), DECOUPLED from
  // the slow LLM summarizer/manager passes (`runSweep`) — so it can never be blocked or
  // starved by them, even when their budgets are exhausted or their model calls are slow.
  // Drive the LLM passes once (consuming their budgets), then the queue's own loop twice
  // (arm + dispatch).
  await runSweep(deps); // summarizer + manager (no queue inside runSweep anymore)
  await runQueueSweepSafe(deps); // queue's own loop: first call arms (dispatch-suppressed)
  assert.equal(fake.calls.spawn.length, 0, "queue suppressed on its first sweep");
  now += 5000;
  await runQueueSweepSafe(deps); // queue dispatches, independent of the LLM passes

  assert.equal(fake.calls.spawn.length, 1, "queue dispatched independently of the LLM passes");
  assert.equal(deps.queue!.budget.active, 0, "queue budget released");
  // Passes 1+2 genuinely ran against the busy fleet (so the queue dispatched ALONGSIDE
  // real summarizer/manager work, not because the fleet was idle).
  assert.ok(summarizeCalls >= 1, "summarizer ran against the busy fleet");
  assert.ok(suggestCalls >= 1, "manager ran against the waiting agent");
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

test("runQueueSweep: closing an EXITED split puts its key into COOLDOWN (not immediately eligible)", async () => {
  let surfaces: Surface[] = [];
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"K-1","title":"task"}]',
    spawns: [{ id: "spawned-1", sessionId: 900 }],
  });
  (fake.client as unknown as { listSurfaces: () => Promise<Surface[]> }).listSurfaces =
    async () => surfaces;

  const run = makeQueueRun(tmpl(), memStore());
  let now = 4_500_000;
  const deps = makeQueueDeps(fake, [run], () => now);

  await runQueueSweep(deps); // arm
  now += 5000;
  await runQueueSweep(deps); // dispatch K-1

  // The spawned surface appears but EXITS early (leave-and-bell).
  surfaces = [
    queueSurface({ id: "spawned-1", sessionID: 900, exited: true, agentState: "working", queueKey: "K-1", queueName: "backlog" }),
  ];
  now += 5000;
  await runQueueSweep(deps);
  assert.equal(run.active.get("K-1")?.state, "EXITED", "kept in EXITED");
  assert.equal(run.cooldown.has("K-1"), false, "not cooled while the split is still open");

  // A human closes the dead split → its session vanishes → reconcile prunes the EXITED
  // record. Per §6 the freed key enters COOLDOWN, so the very next list does NOT
  // re-dispatch it even though K-1 is still in the list.
  surfaces = [];
  now += 5000;
  await runQueueSweep(deps);
  assert.equal(run.active.has("K-1"), false, "EXITED record pruned after the human closed it");
  assert.ok(run.cooldown.has("K-1"), "freed key entered COOLDOWN");
  assert.equal(fake.calls.spawn.length, 1, "K-1 NOT re-dispatched while cooling (still just the one spawn)");

  // After the cooldown elapses the key is eligible again (a reopened item is re-picked).
  now += 130_000; // > DEFAULT_COOLDOWN_MS (120s)
  await runQueueSweep(deps);
  assert.equal(fake.calls.spawn.length, 2, "K-1 re-dispatched once its cooldown expired");
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
// (7) §13 INJECTION: a hostile item title is delivered VERBATIM as env DATA on the
//     spawn — the command string is byte-identical to the template (no splice).
// ---------------------------------------------------------------------------

test("runQueueSweep: a hostile item title is NEVER spliced into the command — rides only in env", async () => {
  const hostileTitle = '"; rm -rf ~; echo "';
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
  // (a) The command is BYTE-IDENTICAL to the template's launch line — no substitution.
  assert.equal(
    fake.calls.spawn[0].command,
    "claude work",
    "command is the verbatim template string (no field splice)",
  );
  // (b) The hostile title rides ONLY in env, verbatim — inert as an env VALUE.
  const env = fake.calls.spawn[0].env as Record<string, string>;
  assert.equal(env.GHOSTTY_ITEM_TITLE, hostileTitle, "title delivered verbatim as env data");
  assert.equal(env.GHOSTTY_ITEM_KEY, "K-1");
  // The command string contains NONE of the hostile bytes.
  assert.equal(
    (fake.calls.spawn[0].command as string).includes("rm -rf"),
    false,
    "no item bytes leaked into the command string",
  );
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
// (12) §2 HARD DEP: a spawn returning sessionID 0 (no pty-host) self-DISABLES the run
//      and creates NO cross-restart re-dispatch loop. Without a stable session id a
//      surface can be neither persisted nor re-adopted, so the supervisor must refuse to
//      track it (rather than persist a sessionID-0 record that prunes → re-dispatches a
//      duplicate every restart cycle). This is the sidecar backstop for the §2 self-
//      disable the mcp.ts contract documents.
// ---------------------------------------------------------------------------

test("runQueueSweep: a sessionID-0 spawn (no pty-host) self-disables the run with no re-dispatch loop", async () => {
  // The shared store a simulated restart re-reads.
  const store = memStore();
  const fake = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"K-1"}]',
    // The spawn returns sessionID 0 — the no-pty-host signal.
    spawns: [{ id: "spawned-1", sessionId: 0 }],
  });
  const run = makeQueueRun(tmpl(), store);
  let now = 12_000_000;
  const deps = makeQueueDeps(fake, [run], () => now);

  await runQueueSweep(deps); // arm
  now += 5000;
  await runQueueSweep(deps); // attempt dispatch — spawn returns sessionID 0

  // The spawn was attempted exactly once; the run is now self-disabled and tracks NOTHING.
  assert.equal(fake.calls.spawn.length, 1, "one spawn attempted");
  assert.equal(run.disabled, true, "run self-disabled on the sessionID-0 spawn");
  assert.equal(run.active.has("K-1"), false, "the untrackable sessionID-0 surface is NOT tracked");
  assert.equal(run.lifetimeDispatched, 0, "the lifetime counter rolled back (nothing trackable launched)");

  // The persisted store carries NO sessionID-0 record (so a restart can't re-dispatch it).
  assert.equal(loadStore(store).length, 0, "no sessionID-0 record persisted");

  // Further sweeps on THIS run dispatch nothing (disabled), even though K-1 stays listed.
  for (let i = 0; i < 3; i++) {
    now += 5000;
    await runQueueSweep(deps);
  }
  assert.equal(fake.calls.spawn.length, 1, "disabled run dispatches nothing further (no loop)");

  // SIMULATE a sidecar restart with the SAME store: the fresh run reconciles from the
  // (empty) store and must NOT re-dispatch the same key into a loop. Its first spawn
  // would again return sessionID 0 → it self-disables again, never looping duplicates.
  const fake2 = makeQueueFake({
    surfaces: [],
    listJson: '[{"id":"K-1"}]',
    spawns: [{ id: "spawned-2", sessionId: 0 }],
  });
  const run2 = makeQueueRun(tmpl(), store); // SAME store
  const deps2 = makeQueueDeps(fake2, [run2], () => now);
  await runQueueSweep(deps2); // arm
  now += 5000;
  await runQueueSweep(deps2); // one spawn attempt, then disabled
  now += 5000;
  await runQueueSweep(deps2);
  now += 5000;
  await runQueueSweep(deps2);
  assert.equal(fake2.calls.spawn.length, 1, "restart attempts ONE spawn then self-disables — no duplicate loop");
  assert.equal(run2.disabled, true, "restarted run also self-disabled");
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

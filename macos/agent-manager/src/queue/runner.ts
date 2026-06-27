// (ramon fork / Agent Queue Supervisor) The deterministic PASS-3 orchestrator that
// wires the PURE modules (provider/grid/supervisor/store/templates) together into a
// single sweep step. It owns the SIDE EFFECTS (MCP spawn/close/attention, provider
// exec, persistence, the clock + the timers) behind INJECTABLE SEAMS — exactly the
// summarizer/manager `LoopDeps` style — so the whole supervisor is testable WITHOUT a
// live MCP server, a real `node:child_process`, or a real filesystem.
//
// The loop is single-threaded + strictly NON-OVERLAPPING (index.ts awaits a full
// sweep before the next setTimeout), so this pass needs no overlap lock (§7). It gets
// its OWN ConcurrencyBudget (NOT the summarizer's / manager's) — the manager-budget
// starvation lesson (§13/CLAUDE.md) — so a busy summarizer/manager fleet can never
// deny it dispatch slots.
//
// CRITICAL ORDER-OF-OPERATIONS the spec pins (§7/§9):
//   1. RECONCILE FIRST, every sweep: rebuild the active set from the persisted store
//      ⇄ `list_surfaces` (by stable sessionID) BEFORE any dispatch decision.
//   2. The FIRST sweep after a (re)start is DISPATCH-SUPPRESSED until reconcile has
//      run once — re-adoption always precedes new dispatch (closes the restart-window
//      double-dispatch gap).
//   3. The within-tick active-set insert is SYNCHRONOUS, BEFORE the spawn `await`, so
//      a later candidate in the same batch can't pick a key already in flight.
//
// NOTHING here is Linear/Git/issue-key aware: items reach the agent as GHOSTTY_ITEM_*
// env vars (provider.buildItemEnv), provider `{key}` is an argv element — never spliced.

import type { McpClient, Surface } from "../mcp.js";
import { McpError } from "../mcp.js";
import {
  applyCommands,
  type QueueCommand,
  type RunFactory,
  type RunRegistry,
} from "./commands.js";
import {
  buildItemEnv,
  shellEnvPrefix,
  fetchListResult,
  fetchGraphResult,
  probeStatus,
  renderArgv,
  runProvider,
  type Exec,
} from "./provider.js";
import { lowestFreeSlot, splitPlan, gridCap, MAX_QUEUE_TABS, packMove } from "./grid.js";
import {
  ConcurrencyBudget,
  closeSequencePlan,
  cooldownExpired,
  cooldownUntil,
  foldIdleAnchor,
  nextState,
  remainingSlots,
  selectCandidates,
  type NextStateContext,
} from "./supervisor.js";
import {
  activeSetFromKept,
  finalizeRecord,
  loadLifetimeDispatched,
  loadDispatched,
  loadKeep,
  loadStore,
  makePendingRecord,
  persistStore,
  reconcile,
  type ActiveRunRecord,
  type LiveSurface,
  type StoreIO,
} from "./store.js";
import {
  resolveMaxItemsOverride,
  resolveParamsEnv,
  runDisplayName,
  runIdentityScope,
} from "./templates.js";
import {
  queueStatusReport,
  backlogCount,
  type QueueStatusReport,
  type QueueGraphReport,
} from "./status.js";
import type {
  Assignment,
  GraphNode,
  QueueGraph,
  QueueTemplate,
  WorkItem,
} from "./types.js";

const log = (msg: string): void => console.log(`agent-manager: queue: ${msg}`);
const errlog = (msg: string): void => console.error(`agent-manager: queue: ${msg}`);

/**
 * The grace window a still-PENDING (un-finalized) store record is given before
 * reconcile prunes it (§9). Covers the spawn → first `list_surfaces` lag + a crash
 * between the pending-write and the spawn returning.
 */
export const DEFAULT_PENDING_GRACE_MS = 30_000;

/** Bounded wait for the child to EXIT during the close sequence (§10). On timeout the
 *  loop force-closes anyway (the gate already established done+stably-idle). */
export const DEFAULT_AWAIT_EXITED_MS = 10_000;

/**
 * One running queue. Holds the supervisor's OWNED, in-memory run state — the SINGLE
 * OWNER of assignment state (§8); the Swift/MCP side keeps only display + intents. All
 * timing comes from the injected clock; nothing here reads its own.
 */
export interface QueueRun {
  template: QueueTemplate;
  /** The template BASENAME (the `*.json` filename minus extension) this run was started
   *  from. Distinct from `template.name` (the human/origin label): the basename is the
   *  reload key (`loadTemplateByName(dir, basename)`) used by active-run rehydration (§8a/§9)
   *  and the dedup identity for a `start` command (re-starting the same template basename is
   *  a no-op). Defaults to `template.name` for runs created without a basename (tests). */
  templateName: string;
  /** (parallel runs) The run's DISPLAY name + IDENTITY: `template.name` plus the run's
   *  non-empty env-param VALUES (e.g. "ExampleOS · Acme · v2.0"). This — NOT `template.name`
   *  — is the dashboard origin, the annotation `queueName`, the health-report name, the
   *  active-run record name, and the reconcile filter, so two scoped runs of one template
   *  are shown + controlled as DISTINCT runs. Computed from `template` + `params` at
   *  construction; defaults to `template.name` when the run has no env params. */
  runName: string;
  /** (parallel runs) The canonical, order-independent scope identity (`runIdentityScope`):
   *  the resolved provider env. Two `start`s of the same template with this same scope are an
   *  idempotent no-op; different scopes run in PARALLEL. Used by `applyCommand`'s dedup. */
  identityScope: string;
  /** The store seam for THIS run's durable records (one file per run). */
  storeIO: StoreIO;
  /** (§8b) The resolved START-TIME parameter answers (param name → value) the run was
   *  started with. Injected into the PROVIDER command env each sweep via
   *  `resolveParamsEnv(template, params)` so the `list`/`status`/`claim` commands are
   *  scoped to the user's chosen project/milestone/etc. Empty when the template declares no
   *  params. Persisted in the active-runs record so a restart re-applies the same scope. */
  params: Record<string, string>;
  /** The active assignments, keyed by work-item KEY (the dedup identity, §7). */
  active: Map<string, Assignment>;
  /** Per-key cooldown `until` timestamps (§6). */
  cooldown: Map<string, number>;
  /** (§7.1) The DISPATCHED LATCH: every work-item key dispatched and not yet re-armed.
   *  `selectCandidates` SUPPRESSES any key in here — a re-dispatch is BLOCKED ENTIRELY
   *  (not merely time-cooled like `cooldown`) until a SUCCESSFUL `list` no longer reports
   *  the key (it left the actionable set), at which point the dispatch sweep clears it; if
   *  the key later REAPPEARS in the list it is eligible again. This closes the
   *  kill-before-claim hole: the dispatch→claim gap is human-gated (the agent waits for
   *  the user's go-ahead before it claims, which is what moves the item off the queried
   *  state), so a split killed in that window leaves the item STILL actionable — the
   *  ~2-min cooldown would expire and re-grab it. The latch instead requires a real status
   *  round-trip (leave the list, return) to re-arm. Persisted + rehydrated on the first
   *  reconcile so the suppression survives a sidecar/GUI restart. */
  dispatched: Set<string>;
  /** Per-key idle-debounce anchor (ms the agentState last BECAME idle, §10). */
  idleAnchor: Map<string, number | undefined>;
  /** Per-key close-sequence progress (§10). Once an assignment enters CLOSING the loop
   *  sends the exit keys ONCE and stamps `sinceMs`; subsequent sweeps POLL the live
   *  surface's `exited` flag and only force-close once it is true OR the bounded
   *  `awaitExitedMs` window has elapsed — so the exit-key→drain handshake is real (the
   *  child is given time to exit cleanly) without the single-threaded loop ever
   *  blocking. Keyed by work-item key; cleared on finish. */
  closeAwait: Map<string, { exitKeysSent: boolean; sinceMs: number }>;
  /** MONOTONIC LIFETIME dispatch counter — the TRUE `maxItems` cap (§7). Rehydrated from
   *  the persisted store's top-level counter on the first reconcile and re-floored to the
   *  live fleet each sweep, so a sidecar restart does NOT reset the lifetime budget below
   *  what has already been dispatched. Never decremented. */
  lifetimeDispatched: number;
  /** false until reconcile() has run ONCE since this run was (re)started (§9). */
  reconciledOnce: boolean;
  /** (premature-prune fix) ms-since-epoch this run FIRST reconciled in the current
   *  process (stamped once, on the first reconcile; a restart makes a fresh run object so
   *  it re-stamps). Passed to `reconcile` so a finalized record's session-gone prune is
   *  shielded for `pendingGraceMs` after a (re)start — protecting live, tracked agents from
   *  a transient/incomplete post-restart `list_surfaces`. Non-persisted. */
  reconcileStartedMs?: number;
  /** false until the FIRST sweep (which reconciles) has completed; dispatch is
   *  SUPPRESSED while false so re-adoption ALWAYS precedes any new dispatch — the
   *  §9 first-pass invariant that closes the restart-window double-dispatch gap. The
   *  first sweep reconciles + arms this; the SECOND sweep is the first that dispatches. */
  dispatchArmed: boolean;
  /** SELF-DISABLED (§2 hard dep): set true the first time a spawn returns sessionID 0
   *  — the no-pty-host signal. A surface with sessionID 0 has NO stable persistence key,
   *  so it can be neither re-adopted nor matched across a restart; a persisted
   *  sessionID-0 record would be pruned then RE-DISPATCHED, looping a duplicate agent on
   *  the same item every restart cycle. Per §2 (pty-host is a HARD dependency the feature
   *  is a no-op without), the run REFUSES to dispatch further once it sees a sessionID-0
   *  spawn — it logs once and stays dormant. It does NOT persist or finalize the
   *  untrackable record, so no re-dispatch loop is created. (The PRIMARY guard is
   *  Swift-side — `AgentManagerController` only arms the queue under pty-host — but this
   *  is the sidecar-level backstop so the loop is safe even if that guard is ever absent.) */
  disabled: boolean;
  /** (§8a) PAUSED — a `pause` command set this; a `resume` clears it. While paused the run
   *  still RECONCILES, advances states, and CLOSES due assignments (so a done item is torn
   *  down and a crashed agent rings the bell), but it DISPATCHES NOTHING new. Persisted so a
   *  paused run rehydrates paused. */
  paused: boolean;
  /** (§8a) DRAINING — a `stop` command set this. No new dispatch; the run is REMOVED from
   *  the registry once its active set empties (every assignment finished/closed/pruned). A
   *  draining run still advances states + closes due assignments so in-flight work completes
   *  cleanly. Persisted so a draining run rehydrates draining. */
  draining: boolean;
  /** (§8a) ABORTING — an `abort` command set this. The run sends the exit keys + force-closes
   *  ALL its live assignments THIS sweep, then is removed from the registry. NOT persisted as
   *  a flag (abort terminates the run; the active-runs store simply drops it). */
  aborting: boolean;
  /** (§11 health) The most recent `list` items seen by a dispatch sweep (null until the
   *  first list fetch) + whether that fetch SUCCEEDED. Cached purely to build the
   *  run-level health report (`report_queue_status`) each sweep without an extra provider
   *  call — the dashboard's "N waiting / next: …" reads from this. Not persisted. */
  lastListItems: WorkItem[] | null;
  lastListOk: boolean;
  /** (interval throttling) Wall-clock ms of the LAST provider `list` fetch and the LAST
   *  per-agent `status` probe round. The 5s sweep is the BASE cadence (reconcile / close /
   *  command-drain / health report run every sweep), but the PROVIDER calls are throttled to
   *  `template.intervals.listMs` / `.statusMs` — a `list` fetch happens only when
   *  `nowMs - lastListAtMs >= intervals.listMs`, and the per-agent `status` probes only when
   *  `nowMs - lastStatusAtMs >= intervals.statusMs`. Init `NEGATIVE_INFINITY` so the first
   *  sweep always fetches (and to avoid a `nowMs===0` sentinel collision). Not persisted —
   *  after a restart the first sweep re-fetches, which is correct. */
  lastListAtMs: number;
  lastStatusAtMs: number;
  /** (backlog graph) The most recent WHOLE-board snapshot from the optional `provider.graph`
   *  (null until the first successful fetch), and the wall-clock ms of the last graph fetch
   *  ATTEMPT. The graph is fetched on the SAME cadence as `list` (`intervals.listMs`), cached
   *  here, and pushed to the GUI via `report_queue_graph` — independent of dispatch, so the
   *  backlog view stays live even while the run is paused/draining. Not persisted (a restart
   *  re-fetches on the first due sweep). `lastGraphAtMs` inits NEGATIVE_INFINITY so the first
   *  sweep fetches. */
  lastGraph: QueueGraph | null;
  lastGraphAtMs: number;
  /** (live maxItems edit) A run-level OVERRIDE of the lifetime cap, set by a `set_max_items`
   *  command WHILE the run is live (the dashboard cap control). Takes PRECEDENCE over the
   *  start-time/template cap in `effectiveMaxItemsCap`. `undefined` = no live edit (use the
   *  start-time/template cap); `null` = live-set to UNLIMITED; a positive number = the live
   *  cap. Persisted in the active-runs record so a restart re-applies it. Reducing it below
   *  what is already dispatched only stops FUTURE dispatch (running agents are never killed). */
  maxItemsLive?: number | null;
  /** (live concurrency edit) A run-level OVERRIDE of the max SIMULTANEOUS agents, set by a
   *  `set_concurrency` command WHILE the run is live (the dashboard parallel control). Takes
   *  PRECEDENCE over the template `concurrency` in `effectiveConcurrency`. The grid `cols*rows`
   *  is the PER-TAB pane cap; a concurrency above it OVERFLOWS to additional tabs (§12), so
   *  this can exceed one grid. `undefined` = no live edit (use the template). A positive integer
   *  (clamped to `capPerTab * MAX_QUEUE_TABS`). Persisted in the active-runs record so a restart
   *  re-applies it. Lowering it only stops FUTURE dispatch (running agents are never killed). */
  concurrencyLive?: number;
  /** (keep) PER-SPLIT keep overrides: work-item key → explicit keep verdict (true = keep
   *  open / never auto-close, false = allow auto-close even when the template defaults to
   *  keep). Set by the dashboard 📌 pin via the `set_keep` command; consulted by
   *  `effectiveKeep` (which falls back to `template.keepOnComplete`). RUN-LEVEL state (NOT
   *  per-record) so reconcile — which rebuilds `active` from the store records every sweep —
   *  never wipes it; mirrors the `dispatched` latch. Persisted in the per-run store
   *  (`StoreFile.keep`) + rehydrated on the first reconcile so a kept split stays kept across
   *  a sidecar/GUI restart. Cleared on abort. */
  keep: Map<string, boolean>;
  /** (keep) Keys whose keep was just toggled by a `set_keep` command and need their surface
   *  annotation RE-STAMPED this sweep so the dashboard 📌 pin reflects it immediately. Drained
   *  + cleared by `runOne` after reconcile. NON-persisted (a transient per-sweep intent). This
   *  is belt-and-suspenders over the per-sweep `restampAnnotation` (which fires for every active
   *  assignment only because `list_surfaces` does not echo the queueKey, making
   *  `needsAnnotationRestamp` always true) — so the pin stays correct even if that ever changes. */
  keepDirty: Set<string>;
}

/** Build a fresh run state for a template. The store is loaded lazily on the first
 *  reconcile, at which point `lifetimeDispatched` is REHYDRATED from the persisted store
 *  file's monotonic counter — so the §7 `maxItems` cap is a TRUE lifetime cap that
 *  survives a sidecar restart, not merely a per-process bound. `dispatched` (the live
 *  fleet floor) starts at 0 and is re-floored to the reconciled active size each sweep. */
export function makeQueueRun(
  template: QueueTemplate,
  storeIO: StoreIO,
  opts: {
    templateName?: string;
    paused?: boolean;
    draining?: boolean;
    params?: Record<string, string>;
    maxItemsLive?: number | null;
    concurrencyLive?: number;
  } = {},
): QueueRun {
  const params = opts.params ?? {};
  return {
    template,
    templateName: opts.templateName ?? template.name,
    runName: runDisplayName(template, params),
    identityScope: runIdentityScope(template, params),
    storeIO,
    params,
    maxItemsLive: opts.maxItemsLive,
    concurrencyLive: opts.concurrencyLive,
    active: new Map<string, Assignment>(),
    cooldown: new Map<string, number>(),
    dispatched: new Set<string>(),
    keep: new Map<string, boolean>(),
    keepDirty: new Set<string>(),
    idleAnchor: new Map<string, number | undefined>(),
    closeAwait: new Map<string, { exitKeysSent: boolean; sinceMs: number }>(),
    lifetimeDispatched: 0,
    reconciledOnce: false,
    dispatchArmed: false,
    disabled: false,
    paused: opts.paused ?? false,
    draining: opts.draining ?? false,
    aborting: false,
    lastListItems: null,
    lastListOk: false,
    lastListAtMs: Number.NEGATIVE_INFINITY,
    lastStatusAtMs: Number.NEGATIVE_INFINITY,
    lastGraph: null,
    lastGraphAtMs: Number.NEGATIVE_INFINITY,
  };
}

/** (§11 health) The run's EFFECTIVE lifetime cap: the LIVE edit if set (the dashboard cap
 *  control — `null` ⇒ unlimited), else the §8b maxItems override if set (0 ⇒ unlimited ⇒
 *  null), else the template `maxItems`. PURE. Shared by the dispatch gate and the health
 *  report so they agree. */
export function effectiveMaxItemsCap(run: QueueRun): number | null {
  if (run.maxItemsLive !== undefined) return run.maxItemsLive; // live edit wins (null = unlimited)
  const override = resolveMaxItemsOverride(run.template, run.params);
  const cap = override === undefined ? run.template.maxItems : override;
  return cap <= 0 ? null : cap;
}

/** (keep) Whether an item's split is KEPT — exempt from the supervisor's auto-close. PURE.
 *  The PER-SPLIT override (the dashboard 📌 pin → `run.keep`) wins; absent it, the template's
 *  `keepOnComplete` default applies; absent that, false (auto-close). This is the value fed to
 *  `nextState` (so a kept split holds in DONE_PENDING) AND stamped onto the surface annotation
 *  (`keep`) so the dashboard pin reflects the live verdict. NOTE: `closeOnComplete:false` is a
 *  SEPARATE, harder hold checked directly in `nextState` (not folded here), so the pin's
 *  displayed state stays meaningful for the common (closeOnComplete:true) case. */
export function effectiveKeep(run: QueueRun, key: string): boolean {
  const override = run.keep.get(key);
  if (override !== undefined) return override;
  return run.template.keepOnComplete;
}

/** (keep) Snapshot the run's keep overrides as a plain `{key: boolean}` for `persistStore`
 *  (the durable store holds an object, not a Map). PURE. */
export function keepRecord(run: QueueRun): Record<string, boolean> {
  const out: Record<string, boolean> = {};
  for (const [k, v] of run.keep) out[k] = v;
  return out;
}

/** The run's EFFECTIVE max simultaneous agents (the TOTAL pane budget across all its tabs):
 *  the LIVE `set_concurrency` edit if set, else the template `concurrency`. PURE. CLAMPED to
 *  `[1, capPerTab * MAX_QUEUE_TABS]` so a fat-fingered live edit can't open hundreds of
 *  overflow tabs. The grid `cols*rows` is the PER-TAB cap; this total may exceed it (panes
 *  overflow to more tabs, §12). Shared by the dispatch gate + the health report so they agree. */
export function effectiveConcurrency(run: QueueRun): number {
  const raw = run.concurrencyLive ?? run.template.concurrency;
  const capPerTab = gridCap(run.template.grid.cols, run.template.grid.rows);
  const maxPanes = Math.max(1, capPerTab) * MAX_QUEUE_TABS;
  return Math.max(1, Math.min(raw, maxPanes));
}

/** The injectable seams the supervisor pass needs (mirrors LoopDeps). */
export interface QueueDeps {
  client: McpClient;
  /** The provider process-runner seam (node:child_process in prod; a fake in tests). */
  exec: Exec;
  /** The supervisor's OWN budget — NEVER the summarizer's / manager's (§13). */
  budget: ConcurrencyBudget;
  now: () => number;
  /**
   * (§8a) The DYNAMIC active-run REGISTRY, keyed by run NAME (= `template.name`). Was a
   * static `QueueRun[]` in Phase 1; runs are now created/removed ON DEMAND from drained
   * commands + active-run rehydration. An EMPTY registry ⇒ pass 3 dispatches nothing (but
   * still drains commands, so a `start` can populate it). The supervisor MUTATES this map
   * (adds on `start`, removes on drained/aborted) and the caller's `index.ts` shares the
   * same Map reference across sweeps so state persists.
   */
  registry: RunRegistry;
  /** (§8a) The run FACTORY a `start` command uses to build a QueueRun from a template
   *  basename (loads+validates the template + wires a per-run StoreIO). Returns null on a
   *  bad/absent template (a failed start). */
  factory: RunFactory;
  /** (§8a) DRAIN the GUI→sidecar command FIFO for this sweep. Defaults to
   *  `client.takeQueueCommands()`; injectable so a test can feed commands without MCP.
   *  A drain FAILURE is caught (logged, no commands) so the sweep still reconciles. */
  takeCommands?: () => Promise<QueueCommand[]>;
  /** (§8a/§9) Persist the current active-run SET after the registry changes (a start /
   *  pause / resume / stop / drain-removal / abort-removal). Optional; a no-op default means
   *  the persistence is opt-in (tests that don't care omit it). Production wires it to the
   *  active-runs StoreIO. */
  persistActiveRuns?: (records: ActiveRunRecord[]) => void;
  /** The global fleet cap across ALL runs (`agent-queue-max-total`). The per-sweep
   *  global REMAINING is derived from this minus the current global active count — so
   *  the cap is always honored regardless of how active counts drift between sweeps. */
  maxTotal: number;
  /** Grace window for pruning un-finalized pending records (§9). */
  pendingGraceMs: number;
  /** Bounded window the close sequence waits for the child to EXIT (poll across sweeps)
   *  after sending the exit keys, before force-closing anyway (§10). Optional; defaults
   *  to DEFAULT_AWAIT_EXITED_MS. */
  awaitExitedMs?: number;
}

/** Snapshot the registry into the persisted active-run record list (§8a). PURE. */
export function activeRunRecords(registry: RunRegistry): ActiveRunRecord[] {
  const out: ActiveRunRecord[] = [];
  for (const run of registry.values()) {
    const rec: ActiveRunRecord = {
      template: run.templateName,
      name: run.runName,
      paused: run.paused,
      draining: run.draining,
    };
    // Persist the start-time params (§8b) so a restart re-applies the same scope. Omit
    // when empty (no declared params / no answers) to keep the file tidy + back-compat.
    if (Object.keys(run.params).length > 0) rec.params = { ...run.params };
    // Persist a LIVE maxItems edit so a restart re-applies it (null = unlimited; omitted
    // when never live-edited, so a restart falls back to the start-time/template cap).
    if (run.maxItemsLive !== undefined) rec.maxItemsLive = run.maxItemsLive;
    // Persist a LIVE concurrency edit so a restart re-applies it (omitted when never edited,
    // so a restart falls back to the template concurrency).
    if (run.concurrencyLive !== undefined) rec.concurrencyLive = run.concurrencyLive;
    out.push(rec);
  }
  return out;
}

/**
 * Run ONE supervisor sweep over the DYNAMIC active-run registry (§8a). Order of operations:
 *   0. DRAIN the GUI→sidecar command FIFO and apply it (start/pause/resume/stop/abort) to
 *      the registry FIRST — so a `start` populates the registry before reconcile/dispatch
 *      and a `pause`/`stop`/`abort` takes effect THIS sweep. Persist the active-run set if
 *      the command batch changed it.
 *   1. For each registry run: if ABORTING, run the abort sequence (force-close all live
 *      assignments) + remove it; else reconcile + advance + close + (if not paused/draining)
 *      dispatch — and remove a DRAINING run once its active set has emptied.
 *
 * PURE-of-control-flow: every effect goes through `deps`. A NO-OP for dispatch when the
 * registry is empty (the summarizer + manager behavior is byte-identical when no queue is
 * started), but the command drain ALWAYS runs so a `start` can arm it. Catches its own
 * per-run errors so one bad run never stops the others (and never the whole loop). Exported
 * for the integration tests.
 */
export async function runQueueSweep(deps: QueueDeps): Promise<void> {
  // --- 0) DRAIN + apply commands (always; this is how an on-demand run starts) ---------
  let commands: QueueCommand[] = [];
  const take = deps.takeCommands ?? (() => deps.client.takeQueueCommands());
  try {
    commands = await take();
  } catch (err) {
    errlog(`take_queue_commands failed: ${msg(err)}`);
    commands = [];
  }
  if (commands.length > 0) {
    const changed = applyCommands(deps.registry, commands, deps.factory);
    if (changed) {
      persistActiveRunSet(deps);
      // SNAPPY FEEDBACK: push each run's health snapshot IMMEDIATELY after a command applies,
      // BEFORE this sweep's provider round-trips (the per-agent `status` probes + the `list`
      // fetch). Otherwise a pause/resume/stop/set_max_items only reflects in the dashboard at
      // the END of the sweep (after those Linear calls) — the visible "really slow" lag. The
      // normal end-of-sweep report still runs and refreshes the live counts. Skip ABORTING
      // runs (the sweep removes them + reports `present:false` below — no point flashing them).
      for (const run of deps.registry.values()) {
        if (!run.aborting) await reportQueueStatus(run, deps);
      }
    }
  }

  // No runs in the registry (none started / all drained-or-aborted-away) ⇒ nothing to
  // reconcile or dispatch. We've already drained commands, so a future `start` arms it.
  if (deps.registry.size === 0) return;

  // Snapshot the live surfaces ONCE per sweep for reconciliation + state tracking.
  let surfaces: Surface[];
  try {
    surfaces = await deps.client.listSurfaces();
  } catch (err) {
    errlog(`list_surfaces failed: ${msg(err)}`);
    return;
  }

  // The per-sweep global REMAINING = the fleet cap minus the count already active
  // across every run. Derived fresh each sweep (after reconcile rebuilds active sets,
  // active counts are accurate), then decremented as each run dispatches so the
  // `agent-queue-max-total` cap holds across runs within a single sweep.
  let globalRemaining = Math.max(0, deps.maxTotal - totalActiveRegistry(deps.registry));

  let registryChanged = false;
  // Iterate a SNAPSHOT of the entries so we can safely delete from the registry mid-loop.
  for (const [name, run] of [...deps.registry.entries()]) {
    try {
      if (run.aborting) {
        // ABORT: exit+force-close ALL of this run's live assignments, then remove the run.
        await abortRun(run, surfaces, deps);
        deps.registry.delete(name);
        registryChanged = true;
        await reportRunGone(deps, name);
        await reportGraphGone(deps, name);
        log(`run "${name}" ABORTED — all assignments force-closed, run removed`);
        continue;
      }
      const dispatched = await runOne(run, surfaces, deps, globalRemaining);
      globalRemaining = Math.max(0, globalRemaining - dispatched);
      // DRAIN removal: a stopping run with nothing left OCCUPYING a slot is removed
      // (§8a). EXITED (leave-and-bell) review-held splits do NOT block the drain — see
      // `drainComplete` — so a `stop` on a run with a crashed split still completes.
      if (run.draining && drainComplete(run)) {
        deps.registry.delete(name);
        registryChanged = true;
        await reportRunGone(deps, name);
        await reportGraphGone(deps, name);
        log(`run "${name}" DRAINED — no slot-occupying assignments, run removed`);
      }
      // NOTE: there is intentionally NO "quit-when-empty" auto-removal. A run is removed
      // ONLY by an explicit stop (drain) or abort. An empty `list` just means "nothing
      // actionable right now" — the run stays and keeps polling for new/unblocked items.
      // (The old `quitWhenEmpty` knob was removed: it keyed on `active.size === 0`, which a
      // transient/incomplete post-restart `list_surfaces` could falsely produce by pruning
      // live records — silently abandoning live agents and removing the whole run. Removed
      // so no template can re-trigger that; persistence is the safer default.)
    } catch (err) {
      errlog(`run "${name}": ${msg(err)}`);
    }
  }
  if (registryChanged) persistActiveRunSet(deps);
}

/** Persist the current active-run set via the (optional) seam (§8a/§9). Best-effort. */
function persistActiveRunSet(deps: QueueDeps): void {
  if (deps.persistActiveRuns === undefined) return;
  try {
    deps.persistActiveRuns(activeRunRecords(deps.registry));
  } catch (err) {
    errlog(`persist active-runs failed: ${msg(err)}`);
  }
}

/**
 * ABORT a run (§8a): send the template exit keys + force-close EVERY live assignment that
 * still has a surface, then clear the run's tracking. Best-effort per assignment (a failed
 * send/close is logged, never thrown). The run is removed from the registry by the caller.
 * The persisted ASSIGNMENT store for this run is cleared (empty records) so a restart does
 * not re-adopt the torn-down panes.
 */
/**
 * Force-tear-down a run: exit-keys + confirm-bypass close every assignment, then clear the
 * in-memory + durable store so a restart won't re-adopt the closed panes.
 *
 * KNOWN RESIDUAL WINDOW (accepted for v1, §6): `aborting` is in-memory only — it is
 * deliberately NOT persisted. A crash AFTER `run.aborting = true` but BEFORE this function
 * finishes force-closing + clearing the store rehydrates the run as a normal active run and
 * re-adopts the not-yet-closed panes; the user must re-issue the abort. This matches the
 * spec's "abort terminates the run; the active-runs store simply drops it" note (a partially
 * aborted run is rare and self-correcting via a second abort).
 */
async function abortRun(run: QueueRun, surfaces: Surface[], deps: QueueDeps): Promise<void> {
  const liveByUUID = new Map<string, Surface>();
  for (const s of surfaces) liveByUUID.set(s.id, s);
  for (const a of [...run.active.values()]) {
    const uuid = a.surfaceUUID;
    if (uuid === undefined) continue;
    // Send the template exit keys (best-effort) so the child exits before the confirm-bypass
    // close — same handshake as the normal close (§10), but done in one shot for an abort.
    const steps = closeSequencePlan(a, run.template);
    for (const step of steps) {
      try {
        if (step.kind === "sendText") await sendText(deps, uuid, step.text);
        else if (step.kind === "sendKey") await sendKey(deps, uuid, step.key);
      } catch (err) {
        errlog(`abort ${a.key} (${step.kind}): ${msg(err)}`);
      }
    }
    try {
      await deps.client.forceCloseSurface(uuid);
    } catch (err) {
      errlog(`abort ${a.key} (forceClose): ${msg(err)}`);
    }
  }
  run.active.clear();
  run.idleAnchor.clear();
  run.closeAwait.clear();
  // Abort is a full teardown — also drop the §7.1 dispatch latch so a DELIBERATE re-start
  // of this template begins fresh (an aborted item still in the list is re-dispatchable
  // again), matching the records being cleared here.
  run.dispatched.clear();
  // (keep) Drop the per-split keep overrides too — an aborted run is gone; a fresh start
  // begins with no keeps.
  run.keep.clear();
  run.keepDirty.clear();
  // Clear the durable assignment store so a restart won't re-adopt the closed panes.
  persistStore(run.storeIO, [], run.lifetimeDispatched, [], {});
}

/** Whether an assignment OCCUPIES a concurrency + grid slot. PURE. An EXITED
 *  (leave-and-bell) assignment is KEPT in the active map to block its key from
 *  re-dispatch (§6) but does NOT occupy a slot — so the run never deadlocks behind a
 *  crashed agent. (FINISHED/FAILED/COOLDOWN are removed from `active` outright, so in
 *  practice the live `active` map holds only slot-occupying states + EXITED.) Exported
 *  for a direct state-table unit test of the occupancy contract. */
export function occupiesSlot(a: Assignment): boolean {
  return a.state !== "EXITED" && a.state !== "FINISHED" && a.state !== "FAILED" && a.state !== "COOLDOWN";
}

/** Count the slot-occupying assignments in a run (EXITED excluded). PURE. */
function slotOccupancy(run: QueueRun): number {
  let n = 0;
  for (const a of run.active.values()) if (occupiesSlot(a)) n += 1;
  return n;
}

/** Whether a DRAINING run's active set has "emptied" enough to remove it (§8a). PURE.
 *  "Empties" is interpreted as NO assignment still OCCUPYING a slot — i.e. nothing is
 *  in flight. EXITED (leave-and-bell) records are deliberately IGNORED here: they hold
 *  a crashed/finished split for human review and never occupy a slot, so a `stop` on a
 *  run whose only remaining assignments are EXITED still drains and the run is removed
 *  (the dead splits stay standing; their surfaces vanish from `list_surfaces` when a
 *  human closes them — no run tracking is needed to keep them around). Without this a
 *  draining run with a crashed split would linger in the registry indefinitely. */
export function drainComplete(run: QueueRun): boolean {
  return slotOccupancy(run) === 0;
}

/** Sum the slot occupancy across all runs in the registry (the global fleet occupancy). PURE. */
function totalActiveRegistry(registry: RunRegistry): number {
  let n = 0;
  for (const r of registry.values()) n += slotOccupancy(r);
  return n;
}

/**
 * Drive ONE run for a sweep: (1) reconcile store ⇄ live surfaces (always, BEFORE
 * dispatch); (2) advance each active assignment's state from provider status + the
 * live row; (3) execute due close sequences; (4) dispatch new candidates from the
 * provider list — but only AFTER the first reconcile (dispatch-suppressed first sweep).
 */
async function runOne(
  run: QueueRun,
  surfaces: Surface[],
  deps: QueueDeps,
  globalRemaining: number,
): Promise<number> {
  const nowMs = deps.now();
  const t = run.template;
  // --- 1) RECONCILE (always first; §9) --------------------------------------------
  // Project the live surfaces carrying THIS run's annotation into LiveSurface views.
  // (parallel runs) Filter by the run's IDENTITY name (`runName`), which is what
  // dispatchOne/restampAnnotation stamp as the surface annotation queueName — so two
  // scoped runs of one template never adopt each other's tiles.
  const liveForRun = projectLiveSurfaces(surfaces, run.runName);
  const records = loadStore(run.storeIO);
  // Stamp the reconcile-start once (this process) so the prune grace shields records for
  // pendingGraceMs after a (re)start — see reconcile()'s `reconcileStartedMs`.
  if (run.reconcileStartedMs === undefined) run.reconcileStartedMs = nowMs;
  const plan = reconcile(
    records,
    liveForRun,
    nowMs,
    deps.pendingGraceMs,
    run.reconcileStartedMs,
  );

  // REHYDRATE the monotonic lifetime-dispatch counter from the persisted store ONCE
  // (on the first reconcile after a (re)start), so the §7 `maxItems` cap is a TRUE
  // lifetime cap that survives a sidecar restart — completed dispatches that already
  // consumed the budget are not forgotten just because their records were pruned. Take
  // the MAX so a stale-but-larger persisted counter can never be lowered.
  if (!run.reconciledOnce) {
    const persisted = loadLifetimeDispatched(run.storeIO);
    if (persisted > run.lifetimeDispatched) run.lifetimeDispatched = persisted;
    // Rehydrate the dispatched LATCH (§7.1) too: a kill-before-claim item is still in the
    // actionable `list`, so without restoring the latch the first post-restart dispatch
    // sweep would re-grab it. Union into whatever the fresh run already holds (empty here).
    for (const k of loadDispatched(run.storeIO)) run.dispatched.add(k);
    // (keep) Rehydrate the per-split keep overrides so a kept split stays kept across a
    // sidecar/GUI restart (a fresh run already started keep.set above won't be clobbered).
    for (const [k, v] of Object.entries(loadKeep(run.storeIO))) {
      if (!run.keep.has(k)) run.keep.set(k, v);
    }
  }

  // Rebuild the in-memory active set from the kept records BEFORE any dispatch.
  run.active = activeSetFromKept(plan.kept);
  // Keep the lifetime dispatch floor at least the size of the live fleet (a restart
  // must not let the cap drop below what is already running).
  if (run.active.size > run.lifetimeDispatched) run.lifetimeDispatched = run.active.size;

  // Re-stamp the queueKey annotation on any surface that lost it (GUI restart dropped
  // the in-memory map; the store is truth — §9). Adopt/active both persisted below.
  // On a PRUNE of an EXITED record (a human closed a crashed/leave-and-bell split, so
  // its session vanished), put the freed key into COOLDOWN — §6 says closing an EXITED
  // split frees the key "to COOLDOWN → eligible again", so a stale `list` can't
  // instantly re-dispatch the same still-failing item before the ≈2min hold elapses.
  for (const action of plan.actions) {
    if (action.kind === "active" && action.needsAnnotationRestamp) {
      await restampAnnotation(deps, run, action.assignment);
    } else if (action.kind === "adopt") {
      await restampAnnotation(deps, run, action.assignment);
    } else if (action.kind === "prune" && action.assignment.state === "EXITED") {
      run.cooldown.set(action.assignment.key, cooldownUntil(nowMs));
      run.idleAnchor.delete(action.assignment.key);
      run.closeAwait.delete(action.assignment.key);
    } else if (action.kind === "prune" && action.reason === "no-pty-host") {
      // §2 DEFERRED BACKSTOP: a dispatched surface stayed sessionID 0 past the grace
      // window (it's live but the host never attached) → genuinely no pty-host. Disable
      // the run so it dispatches nothing further (the feature is a documented no-op
      // without pty-host), and cool the key so it isn't immediately re-dispatched.
      run.disabled = true;
      run.cooldown.set(action.assignment.key, cooldownUntil(nowMs));
      errlog(
        `run "${run.runName}": ${action.assignment.key} surface never attached a host session ` +
          `(no pty-host, §2) — supervisor self-DISABLED for this run`,
      );
    }
  }
  persistStore(run.storeIO, [...run.active.values()], run.lifetimeDispatched, [...run.dispatched], keepRecord(run));
  run.reconciledOnce = true;

  // (keep) Re-stamp the annotation for any split whose keep was just toggled (a `set_keep`
  // command this sweep) so the dashboard 📌 pin reflects it immediately, independent of the
  // needsAnnotationRestamp path above. Drain + clear the dirty set.
  if (run.keepDirty.size > 0) {
    for (const key of [...run.keepDirty]) {
      const a = run.active.get(key);
      if (a !== undefined) await restampAnnotation(deps, run, a);
    }
    run.keepDirty.clear();
  }

  // --- 2) ADVANCE active assignment states ----------------------------------------
  const liveByUUID = new Map<string, Surface>();
  for (const s of surfaces) liveByUUID.set(s.id, s);
  await advanceStates(run, liveByUUID, deps, nowMs);

  // --- 3) CLOSE due assignments (DONE_PENDING → CLOSING) ---------------------------
  await runCloseSequences(run, liveByUUID, deps);

  // Drop expired cooldown entries so the map doesn't grow unbounded.
  for (const key of [...run.cooldown.keys()]) {
    if (cooldownExpired(run.cooldown, key, nowMs)) run.cooldown.delete(key);
  }

  // --- 4) DISPATCH new candidates (SUPPRESSED on the very first sweep) -------------
  // reconciledOnce is set true above THIS sweep, but the SUPPRESSION applies to the
  // first sweep's dispatch: we only dispatch when the run had ALREADY reconciled at
  // least once BEFORE this sweep. All decision branches funnel to a single report+return
  // below so the run-level HEALTH report fires EVERY sweep (incl. the arm sweep) — that
  // is the "queue is present, here's what's next" signal the dashboard shows before any
  // split spawns.
  let dispatched = 0;
  if (!run.dispatchArmed) {
    run.dispatchArmed = true; // arm for the NEXT sweep; suppress dispatch THIS sweep
  } else if (run.disabled) {
    // SELF-DISABLED (§2): a prior spawn returned sessionID 0 (no pty-host) → dormant.
    // Reconcile + state-advance + close still ran above; launch nothing new.
  } else if (run.paused || run.draining) {
    // PAUSED / DRAINING (§8a): keep tracking + closing (done above), dispatch NOTHING new.
  } else {
    // --- 3.5) CONTINUOUS PACKING (§12): consolidate fragmented tabs BEFORE dispatch, so a
    // new dispatch fills the packed layout's low tabs rather than a stray fragment. One merge
    // per sweep; a no-op once the layout is minimal. Best-effort (never throws into the sweep).
    await packRun(run, deps);
    dispatched = await dispatchCandidates(run, deps, nowMs, globalRemaining);
  }

  // --- 4.5) REFRESH the backlog GRAPH (optional `provider.graph`), throttled to listMs.
  // Independent of dispatch (runs even while paused/draining/disabled) so the grooming
  // view stays live; best-effort (a failed fetch keeps the last-known board).
  await refreshGraph(run, deps, nowMs);

  // --- 5) REPORT run-level health (§11), AFTER dispatch so the counts are fresh. -----
  await reportQueueStatus(run, deps);
  return dispatched;
}

/** (backlog graph) Fetch the optional `provider.graph` board on the `list` cadence, cache
 *  it on the run, and push it to the GUI via `report_queue_graph`. No-op when the template
 *  declares no `provider.graph`, when the client lacks the capability (test fakes), or when
 *  not yet due. A FAILED fetch is skipped silently — the GUI keeps the last-known board (no
 *  push), never blanking the canvas on a transient provider error. The header-badge
 *  `backlog` count excludes everything the header already shows as waiting/running (the
 *  actionable-list keys ∪ the active assignment keys). */
async function refreshGraph(run: QueueRun, deps: QueueDeps, nowMs: number): Promise<void> {
  const spec = run.template.provider.graph;
  if (spec === undefined) return;
  // A self-DISABLED run (no pty-host) is dormant — don't spend tracker calls on its board.
  if (run.disabled) return;
  if (deps.client.reportQueueGraph === undefined) return; // optional client capability
  // Same throttle as `list` (consumed on the ATTEMPT so a failing graph waits a full
  // interval too — a hard cap of one graph call per listMs regardless of outcome).
  if (nowMs - run.lastGraphAtMs < run.template.intervals.listMs) return;
  run.lastGraphAtMs = nowMs;

  let res: { ok: boolean; nodes: GraphNode[] };
  try {
    res = await fetchGraphResult(spec, deps.exec, {
      cwd: run.template.workdir,
      env: resolveParamsEnv(run.template, run.params),
    });
  } catch (err) {
    errlog(`provider.graph "${run.runName}": ${msg(err)}`);
    return;
  }
  if (!res.ok) return; // keep last-known board on a failed fetch

  run.lastGraph = { nodes: res.nodes };
  const exclude = new Set<string>([
    ...(run.lastListItems ?? []).map((i) => i.key),
    ...run.active.keys(),
  ]);
  const report: QueueGraphReport = {
    queueName: run.runName,
    present: true,
    backlog: backlogCount(res.nodes, exclude),
    nodes: res.nodes,
  };
  try {
    await deps.client.reportQueueGraph(report);
  } catch (err) {
    errlog(`report_queue_graph "${run.runName}": ${msg(err)}`);
  }
}

/** (backlog graph) Tell the GUI a run's backlog board is GONE (run removed) so it clears
 *  the "N backlog" button + canvas. Best-effort; called alongside `reportRunGone`. */
async function reportGraphGone(deps: QueueDeps, name: string): Promise<void> {
  if (deps.client.reportQueueGraph === undefined) return;
  try {
    await deps.client.reportQueueGraph({
      queueName: name,
      present: false,
      backlog: 0,
      nodes: [],
    });
  } catch (err) {
    errlog(`report_queue_graph(gone) "${name}": ${msg(err)}`);
  }
}

/** (§11 health) Build + push the run-level health report via the MCP client. Best-effort
 *  (a failed report is logged, never thrown into the sweep). `present:true` (the run is
 *  live); the caller reports `present:false` separately when it removes a run. */
async function reportQueueStatus(run: QueueRun, deps: QueueDeps): Promise<void> {
  if (deps.client.reportQueueStatus === undefined) return; // optional client capability
  const occupying = [...run.active.values()].filter(occupiesSlot);
  // The RUNNING items (key/title/url) for the "M running" dropdown — from the
  // slot-occupying assignments (title/url were captured at dispatch from the work item).
  const runningItems = occupying.map((a) => ({ key: a.key, title: a.title, url: a.url }));
  // Exclude from the backlog/next: everything currently tracked (active map, any state)
  // PLUS the §7.1 dispatch latch — those keys are NOT eligible to dispatch, so showing
  // them as "waiting" would mislead. This mirrors `selectCandidates`' own skips.
  const exclude = new Set<string>([...run.active.keys(), ...run.dispatched]);
  const report: QueueStatusReport = queueStatusReport({
    queueName: run.runName,
    present: true,
    paused: run.paused,
    draining: run.draining,
    disabled: run.disabled,
    dispatchArmed: run.dispatchArmed,
    runningItems,
    excludeKeys: exclude,
    listItems: run.lastListItems,
    listOk: run.lastListOk,
    dispatched: run.lifetimeDispatched,
    maxItemsCap: effectiveMaxItemsCap(run),
    concurrency: effectiveConcurrency(run),
    // A generous cap for the "N waiting" dropdown (the count itself is always exact);
    // beyond this the GUI shows "… and N more".
    nextLimit: 25,
  });
  try {
    await deps.client.reportQueueStatus(report);
  } catch (err) {
    errlog(`report_queue_status "${run.runName}": ${msg(err)}`);
  }
}

/** (§11 health) Report that a run is GONE (removed) so the dashboard clears its section.
 *  Best-effort; called right after a drain/abort/quit removal. */
async function reportRunGone(deps: QueueDeps, name: string): Promise<void> {
  if (deps.client.reportQueueStatus === undefined) return;
  try {
    await deps.client.reportQueueStatus(
      queueStatusReport({
        queueName: name,
        present: false,
        paused: false,
        draining: false,
        disabled: false,
        dispatchArmed: true,
        runningItems: [],
        excludeKeys: new Set<string>(),
        listItems: null,
        listOk: false,
        dispatched: 0,
        maxItemsCap: null,
      }),
    );
  } catch (err) {
    errlog(`report_queue_status gone "${name}": ${msg(err)}`);
  }
}

// ---------------------------------------------------------------------------
// Reconciliation projection + annotation re-stamp.
// ---------------------------------------------------------------------------

/** Project `list_surfaces` rows into the minimal `LiveSurface` view reconcile needs,
 *  filtered to surfaces carrying THIS run's queueName annotation (or no queue
 *  annotation at all — those can never match/adopt and are skipped). The annotation
 *  fields ride back on the Surface row as queueKey/queueName/queueUrl (the Swift side
 *  echoes the stored annotation into list_surfaces). PURE. */
export function projectLiveSurfaces(
  surfaces: Surface[],
  queueName: string,
): LiveSurface[] {
  const out: LiveSurface[] = [];
  for (const s of surfaces) {
    const sid = typeof s.sessionID === "number" ? s.sessionID : 0;
    // Only surfaces belonging to THIS run participate (matched by the annotation's
    // queueName); a surface with no queue annotation, or another run's, is skipped so
    // reconcile never adopts a foreign tile.
    const sQueueName = (s as { queueName?: string }).queueName;
    if (sQueueName !== undefined && sQueueName !== queueName) continue;
    const live: LiveSurface = { sessionID: sid, surfaceUUID: s.id };
    const qk = (s as { queueKey?: string }).queueKey;
    if (typeof qk === "string") live.queueKey = qk;
    if (typeof sQueueName === "string") live.queueName = sQueueName;
    const url = (s as { queueUrl?: string }).queueUrl;
    if (typeof url === "string") live.url = url;
    if (typeof s.title === "string") live.title = s.title;
    out.push(live);
  }
  return out;
}

/** Re-stamp the queueKey/queueName/queueUrl/keep annotation on a surface from the durable
 *  assignment (used on reconcile when the GUI dropped the in-memory map, and on orphan
 *  adoption). Best-effort: a write failure is logged, never thrown into the loop.
 *  (keep) `keep` is stamped EVERY sweep this runs (which, since list_surfaces does not echo
 *  the queueKey, is every sweep for every active assignment) so the dashboard 📌 pin reflects
 *  the live `effectiveKeep` — including after a per-split toggle or a GUI restart. */
async function restampAnnotation(
  deps: QueueDeps,
  run: QueueRun,
  a: Assignment,
): Promise<void> {
  if (a.surfaceUUID === undefined) return;
  try {
    await deps.client.setAnnotation(a.surfaceUUID, {
      queueKey: a.key,
      queueName: run.runName,
      ...(a.url !== undefined ? { queueUrl: a.url } : {}),
      keep: effectiveKeep(run, a.key),
    });
  } catch (err) {
    errlog(`restamp ${a.key}: ${msg(err)}`);
  }
}

// ---------------------------------------------------------------------------
// State advancement (§6) — provider status + live row → nextState.
// ---------------------------------------------------------------------------

/** Advance each non-terminal assignment's state. Probes provider `status` for RUNNING/
 *  SPAWNED assignments (the ONLY completion trigger), folds the idle anchor from the
 *  hook-driven agentState, and stamps the new state + sinceMs on a change. */
async function advanceStates(
  run: QueueRun,
  liveByUUID: Map<string, Surface>,
  deps: QueueDeps,
  nowMs: number,
): Promise<void> {
  let changed = false;
  // (interval throttling) Probe provider `status` at most once per `intervals.statusMs`,
  // not every 5s sweep. The idle-anchor fold (cheap, from the hook-driven agentState) and
  // the close-gate still run EVERY sweep; only the provider round-trip is throttled. When a
  // probe is NOT due, `statusTerminal` stays undefined for every agent → nextState makes no
  // status-driven completion this sweep (it resumes on the next due sweep). Decided once for
  // the whole batch so all agents share one round; the window is consumed (`lastStatusAtMs`
  // advanced) ONLY if a probe actually fired, so a due sweep with no live SPAWNED/RUNNING
  // agent doesn't burn the interval (the next sweep with an agent probes immediately).
  const statusDue = nowMs - run.lastStatusAtMs >= run.template.intervals.statusMs;
  let probed = false;
  for (const a of [...run.active.values()]) {
    // Terminal/transitional states are owned by the close loop / cooldown logic.
    if (
      a.state === "CLOSING" ||
      a.state === "FINISHED" ||
      a.state === "FAILED" ||
      a.state === "EXITED" ||
      a.state === "COOLDOWN"
    ) {
      continue;
    }

    const live = a.surfaceUUID !== undefined ? liveByUUID.get(a.surfaceUUID) : undefined;
    const surfaceLive = live !== undefined;
    const agentState = live?.agentState;
    const exited = live?.exited ?? false;

    // Fold the idle-debounce anchor from the freshly-observed agentState.
    const priorAnchor = run.idleAnchor.get(a.key);
    const anchor = foldIdleAnchor(priorAnchor, agentState, nowMs);
    run.idleAnchor.set(a.key, anchor);

    // Probe provider status ONLY for states that can complete (SPAWNED/RUNNING) and
    // only when the surface is still live (no point probing a gone surface).
    let statusTerminal: boolean | undefined = undefined;
    if (statusDue && surfaceLive && (a.state === "SPAWNED" || a.state === "RUNNING")) {
      const probe = await probeStatus(run.template.provider.status, a.key, deps.exec, {
        cwd: run.template.workdir,
        env: resolveParamsEnv(run.template, run.params),
      });
      statusTerminal = probe.terminal;
      probed = true;
    }

    const ctx: NextStateContext = {
      statusTerminal,
      surfaceLive,
      agentState,
      exited,
      idleStableSinceMs: anchor,
      nowMs,
      closeStableSeconds: run.template.closeStableSeconds,
      // §5/§6/§10: a template that opts OUT of auto-close pins the assignment in
      // DONE_PENDING (never advances to CLOSING), so runCloseSequences never tears its
      // completed split down — it is left open for manual close.
      closeOnComplete: run.template.closeOnComplete,
      // (keep) the per-split keep verdict (dashboard 📌 pin / keepOnComplete default) — a
      // kept split holds in DONE_PENDING and is never auto-torn-down.
      keep: effectiveKeep(run, a.key),
    };
    const next = nextState(a, ctx);
    if (next !== a.state) {
      const updated: Assignment = { ...a, state: next, sinceMs: nowMs };
      run.active.set(a.key, updated);
      changed = true;

      // EXITED (early): leave-and-bell — KEEP the dead split for human review, ring the
      // bell everywhere, and FREE the concurrency + grid slot — but DO NOT remove the
      // assignment from the active set (§6). Keeping it (in the EXITED state) means its
      // KEY still blocks `selectCandidates` (active.has(key)) so the failing item is
      // NEVER silently re-dispatched; the slot is freed instead by EXCLUDING EXITED
      // assignments from the occupancy count (slotOccupancy/occupiedSlots below), so the
      // run never deadlocks behind a crashed agent. When a human closes the dead split
      // its surface vanishes → reconcile prunes the EXITED record → the key is eligible.
      if (next === "EXITED") {
        if (updated.surfaceUUID !== undefined) {
          await signal(deps, updated.surfaceUUID, `agent for ${updated.key} exited early`);
        }
        run.idleAnchor.delete(a.key);
        log(`run "${run.runName}": ${updated.key} EXITED early — bell rung, slot freed`);
      }
    }
  }
  // Consume the status-probe window only when a probe actually fired this sweep (see the
  // `statusDue`/`probed` note above).
  if (probed) run.lastStatusAtMs = nowMs;
  if (changed) persistStore(run.storeIO, [...run.active.values()], run.lifetimeDispatched, [...run.dispatched], keepRecord(run));
}

// ---------------------------------------------------------------------------
// Close sequence (§10) — exit keys → AWAIT EXITED (bounded, poll across sweeps) →
// force close → cooldown.
// ---------------------------------------------------------------------------

/**
 * Drive the close sequence for every CLOSING assignment (§10). The exit-key→drain
 * handshake is REAL but never BLOCKS the single-threaded loop: it is staged ACROSS
 * SWEEPS via `run.closeAwait`.
 *   - First time a key is seen CLOSING: send the template `agent.exit` keys ONCE (so the
 *     agent's child exits), stamp `closeAwait`, and DEFER — do NOT force-close this sweep
 *     (give the child time to exit cleanly before the hard close).
 *   - Subsequent sweeps: if the live surface reports `exited === true`, OR the bounded
 *     `awaitExitedMs` window since the exit-keys-send has elapsed (the §10 timeout
 *     fallback), force-close (confirm-bypass) and free the key+slot into cooldown.
 *   - A CLOSING assignment with NO live surface (already gone) or NO UUID: finish
 *     directly (nothing to await/close).
 */
async function runCloseSequences(
  run: QueueRun,
  liveByUUID: Map<string, Surface>,
  deps: QueueDeps,
): Promise<void> {
  const awaitMs = deps.awaitExitedMs ?? DEFAULT_AWAIT_EXITED_MS;
  let changed = false;
  for (const a of [...run.active.values()]) {
    if (a.state !== "CLOSING") continue;
    const uuid = a.surfaceUUID;
    if (uuid === undefined) {
      finishAndCooldown(run, a, deps.now());
      changed = true;
      continue;
    }

    const live = liveByUUID.get(uuid);
    // Already gone from list_surfaces (the user closed it, or a prior force-close took
    // effect) → nothing left to close.
    if (live === undefined) {
      finishAndCooldown(run, a, deps.now());
      changed = true;
      log(`run "${run.runName}": ${a.key} surface gone → cooldown`);
      continue;
    }

    // Stage 1: first sweep in CLOSING — send the exit keys ONCE, then DEFER (await the
    // child's exit across the next sweep(s)). The exit keys come from the close plan.
    let progress = run.closeAwait.get(a.key);
    if (progress === undefined || !progress.exitKeysSent) {
      const steps = closeSequencePlan(a, run.template);
      for (const step of steps) {
        try {
          // The exit prelude: a typed command (sendText, e.g. "/quit") and/or control
          // keys (sendKey, e.g. "ctrl-d"/"enter"), per the template's agent.exit (§10).
          if (step.kind === "sendText") await sendText(deps, uuid, step.text);
          else if (step.kind === "sendKey") await sendKey(deps, uuid, step.key);
        } catch (err) {
          errlog(`close ${a.key} (${step.kind}): ${msg(err)}`);
        }
      }
      progress = { exitKeysSent: true, sinceMs: deps.now() };
      run.closeAwait.set(a.key, progress);
      // If the child is ALREADY exited this very sweep, fall through to force-close;
      // otherwise defer to a later sweep so the child can exit cleanly.
      if (!live.exited) {
        log(`run "${run.runName}": ${a.key} exit keys sent; awaiting child exit`);
        continue;
      }
    }

    // Stage 2: poll for exit. Force-close once the child has EXITED, or the bounded
    // await window has elapsed (the §10 timeout fallback — force_close is confirm-bypass
    // and the gate already established done+stably-idle).
    const elapsed = deps.now() - progress.sinceMs;
    if (live.exited || elapsed >= awaitMs) {
      if (!live.exited) {
        log(`run "${run.runName}": ${a.key} await-exit timed out (${elapsed}ms); force-closing`);
      }
      try {
        await deps.client.forceCloseSurface(uuid);
      } catch (err) {
        errlog(`close ${a.key} (forceClose): ${msg(err)}`);
      }
      finishAndCooldown(run, a, deps.now());
      changed = true;
      log(`run "${run.runName}": ${a.key} closed → cooldown`);
    }
    // else: still within the await window and not yet exited → keep polling next sweep.
  }
  if (changed) persistStore(run.storeIO, [...run.active.values()], run.lifetimeDispatched, [...run.dispatched], keepRecord(run));
}

/** Move a closed assignment to FINISHED and start its key's COOLDOWN, freeing the
 *  key + grid slot (§6/§10). Removes it from the active set + clears its close-await
 *  + idle-anchor bookkeeping. */
function finishAndCooldown(run: QueueRun, a: Assignment, nowMs: number): void {
  run.active.delete(a.key);
  run.idleAnchor.delete(a.key);
  run.closeAwait.delete(a.key);
  run.cooldown.set(a.key, cooldownUntil(nowMs));
}

// ---------------------------------------------------------------------------
// Dispatch (§7/§12) — list provider → select → spawn → persist → track.
// ---------------------------------------------------------------------------

/** Fetch the provider list, select candidates under every cap, and dispatch each — with
 *  a SYNCHRONOUS active-set insert before the spawn await (§7 within-tick dedup). */
async function dispatchCandidates(
  run: QueueRun,
  deps: QueueDeps,
  nowMs: number,
  globalRemaining: number,
): Promise<number> {
  const t = run.template;

  // Remaining slots = min(EFFECTIVE concurrency room, global remaining). The active count
  // is every assignment currently OCCUPYING a slot (EXITED kept-but-freed ones excluded,
  // §6). The per-tab `cols*rows` is NOT a global cap — concurrency is the total pane budget
  // and panes overflow to additional tabs (§12), so it does not bound this.
  const activeCount = slotOccupancy(run);
  const slots = remainingSlots(t, activeCount, globalRemaining, effectiveConcurrency(run));
  // §8b maxItems OVERRIDE: a start-time "maxItems" param can override the template cap
  // (null = unlimited ⇒ Infinity remaining; selectCandidates' Math.min(slots, Infinity) =
  // slots). The global `agent-queue-max-total` + grid/concurrency still bound an unlimited run.
  const cap = effectiveMaxItemsCap(run);
  const maxItemsRemaining =
    cap === null ? Number.POSITIVE_INFINITY : Math.max(0, cap - run.lifetimeDispatched);
  // NOTE: do NOT early-return on a full slot/cap here — the list fetch below ALSO updates
  // the §11 health cache (lastListOk/lastListItems), re-arms the §7.1 latch, and sets the
  // quit-when-empty observation, all of which must happen even when the run can't dispatch
  // (e.g. at its maxItems cap). The dispatch gate is applied AFTER the fetch instead (a
  // capped run that fetched `[]` shows "0 waiting · N running · N/N", not "reading the queue…").

  // (interval throttling) Throttle the provider `list` fetch to `intervals.listMs` instead
  // of hitting it every 5s sweep. When a fetch is NOT due, dispatch nothing THIS sweep and
  // return — the §11 health report (fired by runOne after this returns) reads the CACHED
  // `lastListItems`/`lastListOk` from the previous fetch, so the dashboard counts stay live;
  // the latch re-arm + quit-when-empty observation simply wait for the next due fetch.
  // `lastListAtMs` inits NEGATIVE_INFINITY so the first dispatch sweep always fetches. The
  // window is consumed on the ATTEMPT (set before the fetch), so even a FAILED list waits a
  // full interval before retrying — a hard cap of one provider `list` call per `listMs`,
  // regardless of outcome (the point: stop hammering the provider every 5s).
  if (nowMs - run.lastListAtMs < t.intervals.listMs) return 0;
  run.lastListAtMs = nowMs;

  // Fetch the provider list (skip the tick on any failure — never throws). Use the
  // ok-distinguishing variant so quit-when-empty can tell a SUCCESSFUL empty list from a
  // failed/skip one (§8a): only a clean, parsed, empty list arms the quit.
  let items: WorkItem[];
  try {
    const res = await fetchListResult(t.provider.list, deps.exec, {
      cwd: t.workdir,
      env: resolveParamsEnv(t, run.params),
    });
    items = res.items;
    // (§11 health) Cache the list for the run-level status report. Only a SUCCESSFUL
    // fetch updates the cached items (a failed/skip fetch keeps the last good list so the
    // header doesn't flicker to "0 waiting" on a transient provider blip); listOk tracks
    // the latest fetch either way.
    run.lastListOk = res.ok;
    if (res.ok) run.lastListItems = res.items;
    // RE-ARM the §7.1 dispatch latch: a previously-dispatched key that a SUCCESSFUL list no
    // longer reports has LEFT the actionable set (claimed/blocked/labeled/moved off the
    // queried state) — clear it so it is eligible again IF it later reappears. Only a
    // SUCCESSFUL list re-arms (`res.ok`); a failed/skipped list must NEVER clear the latch,
    // else a transient provider error would re-enable a killed-before-claim item. A
    // successful EMPTY list re-arms ALL latched keys (every one has left the set) — done
    // here, BEFORE the `items.length === 0` early-return below.
    if (res.ok && run.dispatched.size > 0) {
      const present = new Set(items.map((i) => i.key));
      let rearmed = false;
      for (const key of [...run.dispatched]) {
        if (!present.has(key)) {
          run.dispatched.delete(key);
          rearmed = true;
        }
      }
      if (rearmed) {
        persistStore(run.storeIO, [...run.active.values()], run.lifetimeDispatched, [...run.dispatched], keepRecord(run));
      }
    }
  } catch (err) {
    errlog(`run "${run.runName}": list provider failed: ${msg(err)}`);
    return 0;
  }
  // Dispatch gate (applied AFTER the fetch+cache+re-arm above): nothing to dispatch when
  // the slots/cap are exhausted (e.g. at maxItems) or the actionable list is empty.
  if (slots <= 0 || maxItemsRemaining <= 0) return 0;
  if (items.length === 0) return 0;

  const candidates = selectCandidates(
    items,
    run.active,
    run.cooldown,
    run.dispatched,
    nowMs,
    slots,
    maxItemsRemaining,
  );

  let dispatched = 0;
  let acquired = 0;
  try {
    for (const item of candidates) {
      // The supervisor's OWN budget genuinely BOUNDS this sweep's batch: acquire a slot
      // per candidate and HOLD it for the whole batch (release only at the end, in the
      // finally). So a budget of N caps the batch to N dispatches in one sweep even
      // though dispatchOne is awaited sequentially — the budget is a real per-batch
      // bound, not decorative. (The slot/grid/global/lifetime caps already bound
      // concurrency; this is the starvation-lesson budget the spec requires the queue
      // pass to OWN separately from the summarizer/manager — §13.)
      if (!deps.budget.tryAcquire()) break;
      acquired += 1;
      const ok = await dispatchOne(run, item, deps, deps.now());
      if (ok) dispatched += 1;
    }
  } finally {
    for (let i = 0; i < acquired; i++) deps.budget.release();
  }
  return dispatched;
}

/**
 * Dispatch ONE item (§6 QUEUED→SPAWNED, §9 crash-safe ordering):
 *   (a) compute the grid slot + split plan; (b) write a PENDING record + persist BEFORE
 *   the spawn; (c) SYNCHRONOUSLY insert the key into the active set (within-tick dedup,
 *   §7) BEFORE awaiting the spawn; (d) spawn → UUID + sessionID; (e) finalize + persist;
 *   (f) stamp the {queueKey} annotation; (g) optional fire-and-forget claim.
 *
 * RESIDUAL CRASH WINDOW (documented, §9): a process-kill STRICTLY between (d) the spawn
 * returning and (f) the annotation being stamped leaves a live, un-annotated surface plus
 * a finalized record. On restart, reconcile matches that record to the live surface by
 * its STABLE sessionID (the record IS finalized) — so it re-adopts the surface as the
 * SAME assignment and re-stamps the dropped annotation; it is NOT double-dispatched. The
 * only truly un-recoverable sliver is a kill between (d) and (e): a live surface with NO
 * finalized record AND no annotation yet — but in Node there is no await between (d) and
 * (e), so this is a synchronous boundary (practically unreachable), and its blast radius
 * is one duplicate at worst (strictly smaller than the orphan-adopt window). Accepted v1.
 */
async function dispatchOne(
  run: QueueRun,
  item: WorkItem,
  deps: QueueDeps,
  nowMs: number,
): Promise<boolean> {
  const t = run.template;

  // (a) Grid slot + split plan from the currently-occupied slots (EXITED freed ones
  // excluded so a hole left by a crashed agent is refilled).
  const occupied = new Set<number>();
  for (const a of run.active.values()) {
    if (a.gridSlot >= 0 && occupiesSlot(a)) occupied.add(a.gridSlot);
  }
  // The total pane budget is the EFFECTIVE concurrency (across ALL the run's tabs); the
  // lowest free slot fills the lowest tab first, then overflows (§12). A slot exists for
  // every agent the (gated) concurrency allows.
  const cap = effectiveConcurrency(run);
  const slot = lowestFreeSlot(occupied, cap);
  if (slot === null) return false; // full — shouldn't happen (remainingSlots gated)
  // Plan how to materialize this slot's pane (§12): the run's first tab, an OVERFLOW tab
  // (slot is the first of a fresh tab), or a BALANCED split within the slot's existing tab.
  // `slot`'s only geometry is which tab it belongs to (floor(slot / cols*rows)).
  const sp = splitPlan(occupied, slot, gridCap(t.grid.cols, t.grid.rows));

  // (b) PENDING record written BEFORE the spawn (crash-safety, §9 step a). The record's
  // queueName is the run's IDENTITY name (`runName`), matching the annotation stamped below
  // + the reconcile filter, so parallel scoped runs of one template never cross-adopt (§9).
  const pending = makePendingRecord(run.runName, item.key, slot, nowMs, {
    title: item.title,
    url: item.url,
  });
  // (c) SYNCHRONOUS active-set insert BEFORE the spawn await (within-tick dedup, §7).
  // The monotonic lifetime counter increments HERE (at the intent), so even a crash
  // between the pending-write and the finalize still counts the dispatch against the
  // §7 lifetime cap — and it is persisted as a top-level field, surviving a restart.
  run.active.set(item.key, pending);
  run.lifetimeDispatched += 1;
  // LATCH the key (§7.1): once dispatched it is SUPPRESSED from re-dispatch until a
  // successful `list` no longer reports it (it left the actionable set) and it later
  // returns — so a kill BEFORE the agent claims (the item still in the list) is never
  // re-grabbed. Stamped at the intent (alongside the lifetime counter) + persisted, so it
  // holds across a crash/restart; rolled back below only if the spawn itself fails.
  run.dispatched.add(item.key);
  persistStore(run.storeIO, [...run.active.values()], run.lifetimeDispatched, [...run.dispatched], keepRecord(run));

  // (d) Spawn the split, DELIVERING item context to the agent (§13, the #1 requirement).
  // Item fields ride as GHOSTTY_ITEM_* env, NEVER spliced as bare shell text. They are
  // delivered TWO ways for the two backends:
  //   - `env` (itemEnv): the SurfaceConfiguration.environmentVariables — honored under
  //     the `.exec` backend.
  //   - a single-quoted ENV-ASSIGNMENT PREFIX on `command` (`KEY='v' … <command>`): under
  //     the fork's pty-host (`.client`) backend the host spawn protocol forwards
  //     `working_directory`+`initial_input` but NOT env vars, so the `env` field is
  //     dropped there — the prefix rides the command (which IS forwarded) instead. The
  //     single-quoting (shellEnvPrefix) keeps a hostile title inert (no injection); the
  //     template `command` itself is still appended VERBATIM. Belt-and-suspenders: both
  //     set the same vars, so it works on either backend.
  // Three spawn shapes from the §12 plan:
  //   - firstTab           → open the run's FIRST tab (frontmost window; no run window yet).
  //   - newTab + window-   → open an OVERFLOW tab in the run's EXISTING window, anchored on a
  //     anchor UUID         live pane so all the run's tabs share one window (firstTab:true +
  //                         windowAnchorUUID).
  //   - balanced + target  → split WITHIN the slot's tab; the anchor UUID identifies the tab
  //     UUID                and the GUI splits its largest pane. We omit a missing UUID so the
  //                         tool's first-tab fallback applies cleanly.
  const itemEnv = buildItemEnv(item);
  const commandWithItemEnv = shellEnvPrefix(item) + t.agent.command;
  let spawned: { id: string; sessionId: number };
  try {
    let spawnArgs: Parameters<typeof deps.client.spawnSplitCommand>[0];
    const base = { command: commandWithItemEnv, cwd: t.workdir, env: itemEnv };
    if (sp.firstTab === true) {
      spawnArgs = { ...base, firstTab: true };
    } else if (sp.newTab === true) {
      // Overflow tab: open a new tab anchored on the run's window (any live pane).
      const windowAnchorUUID = occupiedUUID(run, sp.windowAnchorSlotIndex);
      spawnArgs = { ...base, firstTab: true, ...(windowAnchorUUID !== undefined ? { windowAnchorUUID } : {}) };
    } else {
      // Balanced split WITHIN the slot's tab — pass the template grid caps (§12 grid cap)
      // so the BSP never exceeds cols columns / rows rows in that tab (further splits stack
      // into rows / add columns). firstTab/newTab branches do NOT pass caps: a fresh tab's
      // first leaf has no grid context and largestLeafSplit isn't called for them.
      const targetUUID = occupiedUUID(run, sp.anchorSlotIndex);
      spawnArgs = {
        ...base,
        ...(targetUUID !== undefined ? { targetUUID } : {}),
        balanced: true,
        maxCols: t.grid.cols,
        maxRows: t.grid.rows,
      };
    }
    spawned = await deps.client.spawnSplitCommand(spawnArgs);
  } catch (err) {
    // Spawn failed → FAILED (§6). Free the slot so the run never deadlocks behind a
    // failed spawn; drop the pending record. The key is NOT cooled (it can retry next
    // list, since nothing ran), and the lifetime counter is ROLLED BACK — nothing
    // actually launched, so the failed attempt must not consume the §7 lifetime budget.
    run.active.delete(item.key);
    if (run.lifetimeDispatched > 0) run.lifetimeDispatched -= 1;
    // Roll back the §7.1 latch too: nothing actually launched, so the key must stay
    // eligible to retry on the next list (mirrors the lifetime-counter rollback).
    run.dispatched.delete(item.key);
    persistStore(run.storeIO, [...run.active.values()], run.lifetimeDispatched, [...run.dispatched], keepRecord(run));
    errlog(`run "${run.runName}": spawn ${item.key} failed: ${msg(err)}`);
    return false;
  }

  // ┌─ INVARIANT (do NOT break): there must be NO `await` between the spawn resolving
  // │  above (d) and `finalizeRecord` below (e). The (d)→(e) duplicate-window claim in
  // │  this function's doc comment ("practically unreachable") rests ENTIRELY on this
  // │  boundary being synchronous in single-threaded Node. The sessionId-0 backstop and
  // │  the finalize+persist below are all synchronous. Inserting an `await` here would
  // │  silently WIDEN that crash window into a real duplicate-dispatch gap.
  // └─ If you must await between spawn and finalize, re-derive the §9 recovery story first.

  // sessionID-0 TOLERANCE (the async-attach reality): a freshly-created SPLIT surface
  // usually returns sessionID 0 from `ghostty_surface_session_id` because the host
  // attaches ASYNCHRONOUSLY (on a per-surface IO thread) — the id is assigned a beat
  // after the split is created, and is visible in the very next `list_surfaces`. (The
  // new-TAB path is slow enough that its id is already attached by the time it returns,
  // which is why the first item gets a real session and later splits often don't.) So we
  // do NOT treat a 0 here as "no pty-host" and self-disable. We FINALIZE the record with
  // the stable UUID (sessionID 0 for now) and stamp the queueKey annotation; reconcile
  // then UUID-matches the live surface next sweep and BACKFILLS the real sessionID once
  // the host has attached (§9). Genuine no-pty-host (the id NEVER attaches) is detected
  // in reconcile — a session-0 record whose surface stays live-but-session-0 PAST the
  // grace window — which self-disables the run then (deferred, not on a transient 0).

  // (e) FINALIZE the record with the (maybe-0) sessionID + UUID; persist. A 0 here is
  // a pending session id reconcile will backfill (see above).
  const finalized = finalizeRecord(pending, spawned.sessionId, spawned.id, deps.now());
  run.active.set(item.key, finalized);
  persistStore(run.storeIO, [...run.active.values()], run.lifetimeDispatched, [...run.dispatched], keepRecord(run));

  // (f) Stamp the {queueKey} annotation so the dashboard groups it + reconcile can
  // adopt it after a crash (§8.5/§9). Best-effort.
  try {
    await deps.client.setAnnotation(spawned.id, {
      queueKey: item.key,
      queueName: run.runName,
      ...(item.url !== undefined ? { queueUrl: item.url } : {}),
      // (keep) stamp the initial keep verdict (template keepOnComplete default, or any
      // pre-existing override for this key — e.g. a re-dispatch after a round-trip).
      keep: effectiveKeep(run, item.key),
    });
  } catch (err) {
    errlog(`run "${run.runName}": annotate ${item.key}: ${msg(err)}`);
  }

  // (g) Optional fire-and-forget claim (a LATENCY optimization, never correctness §7).
  if (t.provider.claim !== undefined) {
    const argv = renderArgv(t.provider.claim.command, item.key);
    void runProvider(argv, deps.exec, {
      cwd: t.workdir,
      env: resolveParamsEnv(t, run.params),
    }).catch(() => {
      /* claim failure is non-fatal + already logged inside runProvider's result */
    });
  }

  log(`run "${run.runName}": dispatched ${item.key} → slot ${slot} (session ${spawned.sessionId})`);
  return true;
}

/** The live surface UUID occupying a grid slot index, for the split target. Returns
 *  `undefined` when not found so the caller OMITS `targetUUID` from the spawn payload
 *  (the tool treats an absent target as a first-tab fallback). Returning "" instead
 *  would be sent on the wire as an empty target — a latent contract mismatch — so we
 *  never do that. The planner guarantees an occupied target in the happy path. */
function occupiedUUID(run: QueueRun, slotIndex: number): string | undefined {
  for (const a of run.active.values()) {
    if (a.gridSlot === slotIndex && a.surfaceUUID !== undefined) return a.surfaceUUID;
  }
  return undefined;
}

/** The SEATED assignment occupying a grid slot (has a `surfaceUUID`), or undefined. PURE. */
function seatedAtSlot(run: QueueRun, slotIndex: number): Assignment | undefined {
  for (const a of run.active.values()) {
    if (a.gridSlot === slotIndex && occupiesSlot(a) && a.surfaceUUID !== undefined) return a;
  }
  return undefined;
}

/**
 * CONTINUOUS PACKING (§12): consolidate a fragmented run's tabs. When agents finish unevenly,
 * a run can end up with e.g. tabs of 3 + 1 + 1 panes that could sit in one tab. Each sweep we
 * compute ONE merge (`packMove`) — a whole source tab whose panes fit an earlier tab's free
 * space — and MOVE its panes there (a focus-preserving cross-tab move), closing the emptied
 * source tab. Applying one merge per sweep converges to the fewest tabs WITHOUT reshuffling a
 * balanced layout (4+4 / 5+2 don't fit, so they never move). Best-effort: a failed move stops
 * this sweep (the next retries); an un-seated source pane (host still attaching) defers the
 * whole merge. Returns the number of panes moved (0 = nothing to pack / deferred).
 */
export async function packRun(run: QueueRun, deps: QueueDeps): Promise<number> {
  const capPerTab = gridCap(run.template.grid.cols, run.template.grid.rows);
  // Occupied slots = every slot-occupying assignment (seated or not) so the tab grouping is
  // accurate; the move itself only proceeds when the source panes are seated (have a UUID).
  const occupied = new Set<number>();
  for (const a of run.active.values()) {
    if (a.gridSlot >= 0 && occupiesSlot(a)) occupied.add(a.gridSlot);
  }
  const plan = packMove(occupied, capPerTab);
  if (plan === null) return 0;

  // Resolve a SEATED anchor pane in the target tab (any occupied target-range slot with a
  // UUID); without one we can't address the destination tab — defer to a later sweep.
  let targetAnchorUUID: string | undefined;
  for (let k = 0; k < capPerTab; k++) {
    const uuid = occupiedUUID(run, plan.targetTab * capPerTab + k);
    if (uuid !== undefined) { targetAnchorUUID = uuid; break; }
  }
  if (targetAnchorUUID === undefined) return 0;

  // Resolve every source pane as a SEATED assignment up front; if ANY is un-seated (host
  // still attaching), defer the WHOLE merge so we never half-move a tab (which would itself
  // fragment). The slot lists are positionally paired by `packMove`.
  const moves: Array<{ asgn: Assignment; toSlot: number }> = [];
  for (let i = 0; i < plan.sourceSlots.length; i++) {
    const asgn = seatedAtSlot(run, plan.sourceSlots[i]);
    if (asgn === undefined || asgn.surfaceUUID === undefined) return 0; // defer
    moves.push({ asgn, toSlot: plan.targetSlots[i] });
  }

  let moved = 0;
  for (const { asgn, toSlot } of moves) {
    if (deps.client.moveSurfaceIntoTab === undefined) break; // optional capability
    try {
      await deps.client.moveSurfaceIntoTab({
        sourceUUID: asgn.surfaceUUID!,
        targetAnchorUUID,
        balanced: true,
        // (§12 grid cap) Respect the destination tab's grid so consolidating a fragmented
        // run never re-introduces a 4th column in a 3-col grid.
        maxCols: run.template.grid.cols,
        maxRows: run.template.grid.rows,
      });
    } catch (err) {
      errlog(`run "${run.runName}": pack move ${asgn.key} failed: ${msg(err)}`);
      break; // stop this sweep; the next re-evaluates from the new (partial) layout.
    }
    // The pane now lives in the target tab → reassign its grid slot (tab membership) so the
    // occupancy model + future dispatch/pack stay consistent.
    asgn.gridSlot = toSlot;
    moved += 1;
  }
  if (moved > 0) {
    persistStore(run.storeIO, [...run.active.values()], run.lifetimeDispatched, [...run.dispatched], keepRecord(run));
    log(`run "${run.runName}": packed ${moved} pane(s) into tab ${plan.targetTab} (continuous packing)`);
  }
  return moved;
}

// ---------------------------------------------------------------------------
// Small effect wrappers (kept thin so the orchestration above stays readable).
// ---------------------------------------------------------------------------

/** Raise attention for a surface (leave-and-bell); best-effort. Routed through
 *  set_attention (the always-loud Tier-2 state) rather than signal_attention so a
 *  crashed-agent review prompt stays loud even under the `agent-manager-bell-filter`
 *  tone-down (review fix / slice 5). */
async function signal(deps: QueueDeps, uuid: string, reason: string): Promise<void> {
  try {
    await deps.client.setAttention(uuid, true, reason);
  } catch (err) {
    errlog(`set_attention ${uuid}: ${msg(err)}`);
  }
}

/** Send a single exit key via the MCP `send_key` tool (the supervisor's only key send —
 *  it never sends free-form input). The key string is a template `exit.keys` entry,
 *  passed verbatim. `McpClient.sendKey` is a real typed wrapper over the same `send_key`
 *  tool the rest of the MCP server exposes, so the PRODUCTION path matches the TESTED
 *  path (no silent no-op fallback). Best-effort: a failed send is logged by the caller
 *  (closeOne) and the close still proceeds to force-close (§10). */
async function sendKey(deps: QueueDeps, uuid: string, key: string): Promise<void> {
  await deps.client.sendKey(uuid, key);
}

/** Type a literal exit COMMAND via the MCP `send_text` tool (for agents that exit via a
 *  typed command, e.g. Claude Code's `/quit`). Types only — a subsequent `sendKey("enter")`
 *  from the close plan submits it. Best-effort like `sendKey`; a failure is logged by the
 *  caller and the close still proceeds to force-close (§10). */
async function sendText(deps: QueueDeps, uuid: string, text: string): Promise<void> {
  await deps.client.sendText(uuid, text);
}

function msg(err: unknown): string {
  if (err instanceof McpError) return `mcp: ${err.message}`;
  return err instanceof Error ? err.message : String(err);
}

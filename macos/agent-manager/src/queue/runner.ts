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
  loadHero,
  loadSchedules,
  loadStore,
  makePendingRecord,
  persistStore,
  reconcile,
  type ActiveRunRecord,
  type LiveSurface,
  type StoreIO,
} from "./store.js";
import { computeNextStart, isDue, parseCron, type ScheduleState } from "./schedule.js";
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
  type ScheduleStatus,
} from "./status.js";
import type {
  Assignment,
  GraphNode,
  QueueGraph,
  QueueTemplate,
  ScheduleSpec,
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
  /** (hero) The HERO key set: every work-item key currently classified as a HERO (see
   *  HERO-AGENTS.md). RUN-LEVEL state (NOT per-record — like `keep`/`dispatched`) so reconcile,
   *  which rebuilds the active map from records every sweep, never wipes it; it is the
   *  AUTHORITATIVE source of a split's hero-ness and is re-stamped onto each reconciled
   *  assignment's `Assignment.hero` at the top of every sweep. A hero is gated by the fleet-wide
   *  `agent-queue-hero-max` cap (orthogonal to the regular concurrency/maxItems/max-total pools),
   *  is kept-by-default (never auto-closed), and lives in its own dedicated tab. `promote`/`demote`
   *  toggle membership. Persisted in the per-run store (`StoreFile.hero`) + rehydrated on the first
   *  reconcile so a promoted split stays a hero across a sidecar/GUI restart. Cleared on abort. */
  hero: Set<string>;
  /** (schedules) The per-schedule CADENCE state, keyed by ScheduleSpec.id: armedAt /
   *  lastCompletionAt / paused (see queue/schedule.ts). RUN-LEVEL state persisted in the
   *  per-run store (`StoreFile.schedules`) + rehydrated on the first reconcile, so a
   *  schedule's timing (and its pause) survives a sidecar/GUI restart. Armed (armedAt = now)
   *  the first time each template schedule is seen; entries for removed schedules are pruned. */
  schedules: Map<string, ScheduleState>;
  /** (schedules) The LIVE scheduled runs, keyed by ScheduleSpec.id — the in-flight scan for
   *  each schedule (its surface UUID + host sessionID + grid slot). This is the SINGLE-FLIGHT
   *  gate (a schedule with a live entry never dispatches a second run) and the completion
   *  detector (an entry that vanishes from `list_surfaces` = its split closed = a completion).
   *  The prose is delivered at spawn via the `GHOSTTY_SCHEDULE_PROMPT` env (see dispatchSchedule),
   *  NOT typed after the fact — so nothing about delivery is tracked here. NOT persisted — rebuilt
   *  each sweep from the annotated live surfaces (`queueSchedule`/`scheduleId`), so a restart
   *  re-adopts a still-open scheduled split without re-dispatch. */
  scheduleActive: Map<string, { uuid: string; sessionID: number; gridSlot: number }>;
  /** (schedules) Schedule ids with a pending "Run now" request (the dashboard button →
   *  `run_schedule_now` command). Consumed on the next dispatch (bypasses the cron due-check
   *  and a `paused` state). NOT persisted (a run-now that didn't fire before a restart is lost
   *  — acceptable; the cadence resumes normally). */
  scheduleRunNow: Set<string>;
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
    hero: new Set<string>(),
    schedules: new Map<string, ScheduleState>(),
    scheduleActive: new Map<string, { uuid: string; sessionID: number; gridSlot: number }>(),
    scheduleRunNow: new Set<string>(),
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

/** (hero) Whether an item's split is a HERO — the AUTHORITATIVE run-level classification. PURE.
 *  Consulted by the two-pool dispatch accounting (heroes are gated by the fleet-wide
 *  `agent-queue-hero-max`, orthogonal to the regular pools), by the keep-forces-hero close gate
 *  (a hero is treated as `keep === true`), and stamped onto the surface annotation + record so the
 *  GUI + a restart both see it. */
export function effectiveHero(run: QueueRun, key: string): boolean {
  return run.hero.has(key);
}

/** (hero) Snapshot the run's hero key set as a plain string[] for `persistStore` (the durable
 *  store holds an array, not a Set). PURE. */
export function heroRecord(run: QueueRun): string[] {
  return [...run.hero];
}

/** (schedules) Snapshot the run's schedule cadence map as a plain `{id: ScheduleState}` for
 *  `persistStore` (the durable store holds an object, not a Map). PURE. */
export function scheduleRecord(run: QueueRun): Record<string, ScheduleState> {
  const out: Record<string, ScheduleState> = {};
  for (const [id, st] of run.schedules) out[id] = st;
  return out;
}

/** Persist ALL of the run's durable state through the store seam — the single write path
 *  used everywhere in the sweep. Centralizes the positional `persistStore` argument list
 *  (records + lifetime counter + latch + keep + hero + schedules) so a new run-level field
 *  is threaded in ONE place. `heroLifetimeDispatched` is passed 0 (informational only — the
 *  single `lifetimeDispatched` counter caps both pools; see store.ts). Never throws. */
function persistRun(run: QueueRun): void {
  persistStore(
    run.storeIO,
    [...run.active.values()],
    run.lifetimeDispatched,
    [...run.dispatched],
    keepRecord(run),
    heroRecord(run),
    0,
    scheduleRecord(run),
  );
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
  /** (hero) The fleet-wide HERO ceiling (`agent-queue-hero-max`; env
   *  `GHOSTTY_AGENT_QUEUE_HERO_MAX`, default 2). ORTHOGONAL to `maxTotal`/concurrency/maxItems:
   *  a hero neither consumes nor is bounded by any of them — the ONLY gate on a NEW hero
   *  dispatch is `heroRemaining = heroMax − heroActiveGlobal`, where `heroActiveGlobal` counts
   *  live heroes across ALL runs. `0` DISABLES hero dispatch entirely (hero-marked items then
   *  wait on the `heroSlots` gate, visibly). NOTE the inversion vs `maxTotal`, where `0` means
   *  UNLIMITED — for heroes `0` means DISABLED (a discipline limit, not a resource limit).
   *  Promotion of a RUNNING regular is NOT gated by this (it may push over the cap; only NEW
   *  dispatches wait until it drains under). See HERO-AGENTS.md § Slot accounting. */
  heroMax: number;
  /** Grace window for pruning un-finalized pending records (§9). */
  pendingGraceMs: number;
  /** Bounded window the close sequence waits for the child to EXIT (poll across sweeps)
   *  after sending the exit keys, before force-closing anyway (§10). Optional; defaults
   *  to DEFAULT_AWAIT_EXITED_MS. */
  awaitExitedMs?: number;
  /** (adopt) The Haiku key-inference seam for an `infer_key` command: read the surface, call
   *  the model with a bespoke "extract the issue key" prompt, and write the result back as the
   *  `queueKeySuggested` annotation (so the GUI adopt modal prefills). Wired in index.ts where
   *  `summarize`+`warmBase` live (keeps the runner SDK-free). OPTIONAL — when omitted (tests),
   *  the `infer_key` side-effect loop is a no-op. */
  inferKey?: (surfaceUUID: string, runName: string) => Promise<void>;
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

  // (adopt §1.6 step 5) SIDE-EFFECT loop for the two new actions. They flowed HARMLESSLY
  // through `applyCommands` above (`adopt` latched in the reducer; `infer_key` is a no-op),
  // and here we re-iterate the SAME drained array to fire their async side effects exactly
  // once. `runAdopt` does the physical move + annotation + claim (latch already added); it
  // self-guards on `registry.get(cmd.run)` so a drained run is a no-op. `runInferKey` only
  // READS a surface + writes an annotation, so it works even with an empty registry (the
  // empty-run candidate path) — which is why this loop is BEFORE the `registry.size === 0`
  // early return.
  for (const cmd of commands) {
    try {
      if (cmd.action === "adopt") await runAdopt(cmd, deps);
      else if (cmd.action === "infer_key") await runInferKey(cmd, deps);
      // (hero) promote ejects the split into its own tab + re-stamps the hero annotation;
      // demote drops the hero annotation. The reducer already flipped the run-level `hero` bit
      // synchronously (so the two-pool accounting sees it this sweep); these fire the effects.
      else if (cmd.action === "promote") await runPromote(cmd, deps);
      else if (cmd.action === "demote") await runDemote(cmd, deps);
    } catch (err) {
      errlog(`${cmd.action} side-effect: ${msg(err)}`);
    }
  }

  // No runs in the registry (none started / all drained-or-aborted-away) ⇒ nothing to
  // reconcile or dispatch. We've already drained commands + run the adopt/infer side
  // effects, so a future `start` arms it.
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
  // (hero) The REGULAR pool's global cap counts ONLY non-hero active assignments — a hero
  // does not consume the fleet-wide `max-total` budget (HERO-AGENTS.md § Slot accounting).
  let globalRemaining = Math.max(0, deps.maxTotal - totalRegularActiveRegistry(deps.registry));
  // (hero) The HERO pool's fleet-wide REMAINING = `heroMax − heroActiveGlobal`. ORTHOGONAL to
  // `globalRemaining`: derived from its OWN cap + its OWN (fleet-wide) hero occupancy, and
  // decremented independently as each run dispatches a hero this sweep. `heroMax === 0` DISABLES
  // hero dispatch (heroRemaining stays ≤ 0 forever); promotion (which mutates a running
  // assignment) can push heroActiveGlobal past heroMax, driving this negative → clamped to 0 →
  // no NEW hero dispatches until it drains under the cap.
  let heroRemaining = Math.max(0, deps.heroMax - totalHeroActiveRegistry(deps.registry));

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
      const disp = await runOne(run, surfaces, deps, globalRemaining, heroRemaining);
      globalRemaining = Math.max(0, globalRemaining - disp.regular);
      heroRemaining = Math.max(0, heroRemaining - disp.hero);
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
  // (hero) Drop the hero classification too — an aborted run is gone; a fresh start begins
  // with no heroes (the hero lifetime counter is left as-is / irrelevant once the run is
  // dropped from the registry).
  run.hero.clear();
  // Clear the durable assignment store so a restart won't re-adopt the closed panes.
  persistStore(run.storeIO, [], run.lifetimeDispatched, [], {}, []);
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

/** Count the slot-occupying assignments in a run (EXITED excluded). PURE. Counts BOTH pools
 *  (hero + regular); used for grid-slot placement (a hero still holds a grid slot in its own
 *  tab) and the drain check. The two-pool DISPATCH accounting uses the split variants below. */
function slotOccupancy(run: QueueRun): number {
  let n = 0;
  for (const a of run.active.values()) if (occupiesSlot(a)) n += 1;
  return n;
}

/** (hero) Count the slot-occupying HERO assignments in a run. PURE. `heroActiveGlobal` is the
 *  sum of this across the registry (`totalHeroActiveRegistry`). A hero is identified by the
 *  AUTHORITATIVE run-level `hero` set (re-stamped onto `Assignment.hero` each sweep), read here
 *  off the record so the count is a pure function of `run.active`. */
function heroOccupancy(run: QueueRun): number {
  let n = 0;
  for (const a of run.active.values()) if (occupiesSlot(a) && a.hero === true) n += 1;
  return n;
}

/** (hero) Count the slot-occupying REGULAR (non-hero) assignments in a run. PURE. This is the
 *  count the regular pool's concurrency + global max-total gates use — a hero neither consumes
 *  a regular concurrency slot nor is counted against `max-total` (HERO-AGENTS.md § Slot
 *  accounting). = `slotOccupancy − heroOccupancy`. */
function regularOccupancy(run: QueueRun): number {
  let n = 0;
  for (const a of run.active.values()) if (occupiesSlot(a) && a.hero !== true) n += 1;
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

/** Sum the slot occupancy across all runs in the registry (the global fleet occupancy). PURE.
 *  Counts BOTH pools; used only for the global drain / diagnostics. The REGULAR-pool global
 *  cap uses `totalRegularActiveRegistry`, and the hero cap uses `totalHeroActiveRegistry`. */
function totalActiveRegistry(registry: RunRegistry): number {
  let n = 0;
  for (const r of registry.values()) n += slotOccupancy(r);
  return n;
}

/** (hero) Sum the REGULAR (non-hero) slot occupancy across all runs — the fleet count the
 *  `agent-queue-max-total` global cap gates against (heroes are NOT counted against max-total).
 *  PURE. */
function totalRegularActiveRegistry(registry: RunRegistry): number {
  let n = 0;
  for (const r of registry.values()) n += regularOccupancy(r);
  return n;
}

/** (hero) `heroActiveGlobal` — the fleet-wide count of live HERO assignments across ALL runs.
 *  PURE. The ONLY quantity the hero gate consults: `heroRemaining = heroMax − heroActiveGlobal`.
 *  Fleet-wide because `agent-queue-hero-max` is a discipline limit on YOUR ATTENTION, not a
 *  per-run resource (HERO-AGENTS.md design decision #1). */
export function totalHeroActiveRegistry(registry: RunRegistry): number {
  let n = 0;
  for (const r of registry.values()) n += heroOccupancy(r);
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
  heroRemaining: number,
): Promise<{ regular: number; hero: number }> {
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
    // (hero) Rehydrate the HERO key set so a promoted split stays a hero across a sidecar/GUI
    // restart (mirrors the keep/dispatched rehydrate). `lifetimeDispatched` is a SINGLE total
    // counter (regular + hero), so there's no separate hero counter to rehydrate.
    for (const k of loadHero(run.storeIO)) run.hero.add(k);
    // (schedules) Rehydrate the per-schedule cadence (armedAt / lastCompletionAt / paused) so a
    // schedule's timing + pause survive a restart (mirrors the keep/hero rehydrate). The
    // scheduleSweep re-arms any NEW template schedule + prunes removed ids from here.
    for (const [id, st] of Object.entries(loadSchedules(run.storeIO))) {
      if (!run.schedules.has(id)) run.schedules.set(id, st);
    }
  }

  // Rebuild the in-memory active set from the kept records BEFORE any dispatch.
  run.active = activeSetFromKept(plan.kept);
  // (hero) RE-STAMP each reconciled assignment's `Assignment.hero` from the AUTHORITATIVE
  // run-level `hero` set. Reconcile rebuilds `active` from records/annotations every sweep and
  // an orphan-adopt carries hero=false (the annotation doesn't yet round-trip it — contract-lint
  // #1/#7), so without this the per-record bit would drift from the run-level truth and the
  // two-pool accounting (which reads `a.hero`) would miscount a promoted-then-restarted hero as
  // regular. The run-level set is the single source of truth; this projects it onto the records.
  for (const [key, a] of run.active) {
    const isHero = run.hero.has(key);
    if (a.hero !== isHero) run.active.set(key, { ...a, hero: isHero });
  }
  // Keep the lifetime dispatch floor at least the size of the live fleet (a restart must not let
  // the cap drop below what is already running). (hero) `lifetimeDispatched` is the TOTAL count
  // (regular + hero) — `maxItems` caps BOTH pools (HERO-AGENTS.md § Slot accounting), so the floor
  // counts the WHOLE live fleet. A single counter (no separate hero counter) means promote/demote
  // are counter-NEUTRAL — an item counts once, forever, regardless of which pool it currently sits
  // in, so promotion can neither refund a maxItems slot nor double-count.
  const totalActive = regularOccupancy(run) + heroOccupancy(run);
  if (totalActive > run.lifetimeDispatched) run.lifetimeDispatched = totalActive;

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
  persistRun(run);
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
  // Whether the run was ALREADY armed BEFORE this sweep (i.e. this is not the first,
  // dispatch-suppressed sweep). Captured before the block below flips `dispatchArmed`, and
  // reused as the schedule-dispatch gate so schedules obey the SAME first-sweep suppression
  // (a restart's first sweep re-adopts existing scheduled splits before any new dispatch).
  const wasArmed = run.dispatchArmed;
  let dispatched = { regular: 0, hero: 0 };
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
    dispatched = await dispatchCandidates(run, deps, nowMs, globalRemaining, heroRemaining);
  }

  // --- 4.25) SCHEDULES: fire + track the recurring scan agents (see queue/schedule.ts).
  // Completion-detection + auto-close ALWAYS run (so an in-flight scan finishes cleanly even
  // during drain, and a restart re-adopts a still-open scheduled split); NEW dispatch only
  // when the run is armed + enabled + not paused/draining (the same gate as work dispatch).
  const canDispatchSchedules = wasArmed && !run.disabled && !run.paused && !run.draining;
  await scheduleSweep(run, deps, nowMs, surfaces, canDispatchSchedules);

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

  // (hero) Mark backlog nodes that are known heroes so the canvas shows the hero glyph on ANY
  // hero, not just one blocked on the hero-slot cap. Two sources OR'd with a provider-set
  // `node.hero`: a `list` item carrying a truthy `heroField`, and a PROMOTED key (run.hero set).
  const heroKeys = new Set<string>([
    ...(run.lastListItems ?? []).filter((i) => i.hero === true).map((i) => i.key),
    ...run.hero,
  ]);
  const nodes: GraphNode[] =
    heroKeys.size === 0
      ? res.nodes
      : res.nodes.map((n) => (n.hero === true || heroKeys.has(n.key) ? { ...n, hero: true } : n));

  run.lastGraph = { nodes };
  const exclude = new Set<string>([
    ...(run.lastListItems ?? []).map((i) => i.key),
    ...run.active.keys(),
  ]);
  const report: QueueGraphReport = {
    queueName: run.runName,
    present: true,
    backlog: backlogCount(nodes, exclude),
    nodes,
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
/** (schedules) Build the per-schedule status for the dashboard Schedules lane: paused/running
 *  flags + the next-start (from `computeNextStart`, absent while paused/running) + last
 *  completion. PURE-ish (reads the run's in-memory schedule state; the cron parse is cheap). A
 *  bad cron yields no `nextRunAt` (the lane still shows the row). */
function scheduleStatuses(run: QueueRun): ScheduleStatus[] {
  return run.template.schedules.map((spec) => {
    const st = run.schedules.get(spec.id);
    const running = run.scheduleActive.has(spec.id);
    const paused = st?.paused ?? false;
    let nextRunAt: number | undefined;
    if (st !== undefined && !running && !paused) {
      try {
        nextRunAt = computeNextStart(parseCron(spec.cron), st);
      } catch {
        nextRunAt = undefined;
      }
    }
    const out: ScheduleStatus = { id: spec.id, name: spec.name ?? spec.id, paused, running };
    if (nextRunAt !== undefined) out.nextRunAt = nextRunAt;
    if (st?.lastCompletionAt !== undefined) out.lastCompletionAt = st.lastCompletionAt;
    return out;
  });
}

async function reportQueueStatus(run: QueueRun, deps: QueueDeps): Promise<void> {
  if (deps.client.reportQueueStatus === undefined) return; // optional client capability
  const occupying = [...run.active.values()].filter(occupiesSlot);
  // The RUNNING items (key/title/url) for the "M running" dropdown — from the
  // slot-occupying assignments (title/url were captured at dispatch from the work item).
  // (hero) Carry each assignment's `hero` bit so the "M running" dropdown marks heroes.
  const runningItems = occupying.map((a) => ({ key: a.key, title: a.title, url: a.url, hero: a.hero }));
  // (hero) The keys that are heroes right now — promoted (run.hero) ∪ active hero assignments ∪
  // `list` items with a truthy `heroField` — so `next`/`running`/`held` refs all get marked.
  const heroKeys = new Set<string>([
    ...run.hero,
    ...[...run.active.values()].filter((a) => a.hero === true).map((a) => a.key),
    ...(run.lastListItems ?? []).filter((i) => i.hero === true).map((i) => i.key),
  ]);
  // Exclude from the backlog/next: everything currently tracked (active map, any state)
  // PLUS the §7.1 dispatch latch — those keys are NOT eligible to dispatch, so showing
  // them as "waiting" would mislead. This mirrors `selectCandidates`' own skips.
  const exclude = new Set<string>([...run.active.keys(), ...run.dispatched]);
  // (hero) The per-sweep gate ROOM feeding `blockReasons` — the SAME primitives
  // `dispatchCandidates` gates on, so the report attributes exactly why a waiting item is
  // stuck. `heroMax`/`heroActive` are fleet-wide globals; the three regular-pool remainders
  // are this run's own room. `Number.POSITIVE_INFINITY` for an unlimited cap ⇒ never blocking.
  const cap = effectiveMaxItemsCap(run);
  const report: QueueStatusReport = queueStatusReport({
    queueName: run.runName,
    present: true,
    paused: run.paused,
    draining: run.draining,
    disabled: run.disabled,
    dispatchArmed: run.dispatchArmed,
    runningItems,
    excludeKeys: exclude,
    heroKeys,
    heroMax: deps.heroMax,
    heroActive: totalHeroActiveRegistry(deps.registry),
    regularConcurrencyRemaining: effectiveConcurrency(run) - regularOccupancy(run),
    regularGlobalRemaining:
      deps.maxTotal - totalRegularActiveRegistry(deps.registry),
    regularMaxItemsRemaining:
      cap === null ? Number.POSITIVE_INFINITY : cap - run.lifetimeDispatched,
    // (release) HELD items are derived from these two: latched keys that are still listed but
    // no longer active. `activeKeys` is the full active map (any state), distinct from `exclude`
    // (which also carries the latch) so the builder can compute listed ∩ latched ∩ ¬active.
    latchedKeys: run.dispatched,
    activeKeys: new Set<string>(run.active.keys()),
    listItems: run.lastListItems,
    listOk: run.lastListOk,
    dispatched: run.lifetimeDispatched,
    maxItemsCap: effectiveMaxItemsCap(run),
    concurrency: effectiveConcurrency(run),
    // A generous cap for the "N waiting" dropdown (the count itself is always exact);
    // beyond this the GUI shows "… and N more".
    nextLimit: 25,
    // (schedules) The Schedules-lane rows (next-run / last-run / paused / running).
    schedules: scheduleStatuses(run),
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
    // (hero) Echo the hero bit back off the row (mirrors the queueKey read-back). The
    // run-level `hero` Set is still authoritative — this is the wire-contract visibility
    // field (HERO-AGENTS.md), not the source of truth.
    const heroBit = (s as { hero?: boolean }).hero;
    if (typeof heroBit === "boolean") live.hero = heroBit;
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
      // (hero) keep the tab marker / tile in sync with the run-level hero verdict after a GUI
      // restart dropped the annotation map (mirrors the keep re-stamp).
      hero: effectiveHero(run, a.key),
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
  const activeList = [...run.active.values()];

  // (parallel probes) Fire this run's due provider `status` probes CONCURRENTLY rather than
  // one-`await`-at-a-time. Each probe is a provider CLI call bounded by DEFAULT_PROVIDER_TIMEOUT_MS
  // (5s, provider.ts); run sequentially, N agents ballooned a single sweep to ~N×5s — the dominant
  // command-latency source (a queued adopt/promote must wait out the whole in-flight sweep before it
  // is drained). The probe TARGETS are exactly the old inline condition — SPAWNED/RUNNING with a
  // LIVE surface, and only when the throttle window is due — so `probed` ("at least one probe fired",
  // which gates the `lastStatusAtMs` window burn) and the no-live-agent behavior are unchanged. Only
  // the I/O is parallelized: the anchor fold + nextState stamping below stay SEQUENTIAL over the same
  // `activeList` (they mutate `run` state), so ordering/determinism is preserved.
  const probeTargets = statusDue
    ? activeList.filter(
        (a) =>
          (a.state === "SPAWNED" || a.state === "RUNNING") &&
          a.surfaceUUID !== undefined &&
          liveByUUID.has(a.surfaceUUID),
      )
    : [];
  const statusByKey = new Map<string, boolean>();
  if (probeTargets.length > 0) {
    const env = resolveParamsEnv(run.template, run.params);
    const results = await Promise.all(
      probeTargets.map((a) =>
        probeStatus(run.template.provider.status, a.key, deps.exec, {
          cwd: run.template.workdir,
          env,
        }).then(
          (probe) => ({ key: a.key, terminal: probe.terminal }),
          // probeStatus already swallows exec failures (→ {terminal:false}); this rejection
          // guard is belt-and-suspenders so one unexpected throw can't fail the WHOLE batch
          // (Promise.all rejects on the first rejection) and strand the other agents' verdicts.
          () => ({ key: a.key, terminal: false }),
        ),
      ),
    );
    for (const r of results) statusByKey.set(r.key, r.terminal);
  }
  const probed = probeTargets.length > 0;

  for (const a of activeList) {
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

    // The provider `status` verdict for this key from the parallel probe batch above —
    // `undefined` when not probed this sweep (throttled, surface not live, or a terminal
    // state), exactly matching the old inline `statusTerminal = undefined` default.
    const statusTerminal: boolean | undefined = statusByKey.get(a.key);

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
      // (hero) a HERO is ALWAYS treated as keep===true (never auto-closed, independent of the
      // 📌 pin / template keepOnComplete) so its follow-up-PR context survives — HERO-AGENTS.md
      // § Lifecycle. `|| effectiveHero(...)` forces the hold; the pin still works on top.
      keep: effectiveKeep(run, a.key) || effectiveHero(run, a.key),
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
  if (changed) persistRun(run);
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
  if (changed) persistRun(run);
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
 *  a SYNCHRONOUS active-set insert before the spawn await (§7 within-tick dedup).
 *
 *  (hero) TWO-POOL accounting (HERO-AGENTS.md § Slot accounting). The list is split by
 *  `item.hero` into a REGULAR pool and a HERO pool:
 *   - REGULAR pool — gated by `remainingSlots(effConcurrency, activeRegular, globalRegularRemaining)`
 *     (`activeRegular` = non-hero slot-occupiers only; heroes run off-grid in their own tab, so
 *     they don't consume a regular concurrency slot) + the shared `maxItems` lifetime budget.
 *   - HERO pool — gated by `heroRemaining = heroMax − heroActiveGlobal` (fleet-wide) AND the SAME
 *     shared `maxItems` budget: the queue's lifetime cap applies to heroes too, so a hero can't be
 *     scheduled once `maxItems` is hit. No per-run concurrency / `max-total` gate a hero.
 *  `maxItems` is spent by the SINGLE total `run.lifetimeDispatched` counter (regular + hero), so
 *  the two pools SHARE one lifetime budget (heroes picked first this sweep, regulars get the rest).
 *  Returns `{ regular, hero }` so the sweep can decrement each fleet-wide (concurrency/hero) budget. */
async function dispatchCandidates(
  run: QueueRun,
  deps: QueueDeps,
  nowMs: number,
  globalRemaining: number,
  heroRemaining: number,
): Promise<{ regular: number; hero: number }> {
  const t = run.template;

  // Remaining REGULAR slots = min(EFFECTIVE concurrency room, global remaining). The active
  // count is every NON-HERO assignment currently OCCUPYING a slot (EXITED kept-but-freed ones
  // excluded, §6; heroes excluded — they don't consume a regular concurrency slot). The per-tab
  // `cols*rows` is NOT a global cap — concurrency is the total pane budget and panes overflow to
  // additional tabs (§12), so it does not bound this.
  const activeRegular = regularOccupancy(run);
  const slots = remainingSlots(t, activeRegular, globalRemaining, effectiveConcurrency(run));
  // §8b maxItems OVERRIDE: a start-time "maxItems" param can override the template cap
  // (null = unlimited ⇒ Infinity remaining; selectCandidates' Math.min(slots, Infinity) =
  // slots). The global `agent-queue-max-total` + grid/concurrency still bound an unlimited run.
  // (hero) The maxItems budget is spent by `run.lifetimeDispatched`, the SINGLE TOTAL dispatch
  // counter (regular + hero) — so `maxItems` caps BOTH pools: a hero can't be scheduled once the
  // queue's lifetime cap is hit, exactly like a regular. It's shared across the two pools this
  // sweep (heroes dispatch first, then regulars get the remainder — see below).
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
  if (nowMs - run.lastListAtMs < t.intervals.listMs) return { regular: 0, hero: 0 };
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
        persistRun(run);
      }
    }
  } catch (err) {
    errlog(`run "${run.runName}": list provider failed: ${msg(err)}`);
    return { regular: 0, hero: 0 };
  }
  if (items.length === 0) return { regular: 0, hero: 0 };

  // (hero) Split the list into the two pools by `item.hero`. The dispatch classification is
  // the ITEM's `hero` bit (from the provider `heroField`); the resulting assignment records
  // it + the run-level `hero` set is updated at dispatch (see dispatchOne). Regular + hero are
  // then selected under their OWN caps — orthogonal by construction.
  const heroItems = items.filter((i) => i.hero === true);
  const regularItems = items.filter((i) => i.hero !== true);

  // HERO selection FIRST (heroes compete for your scarce attention, so surface them promptly):
  // gated by `heroRemaining` (fleet-wide `heroMax − heroActiveGlobal`) AND the shared `maxItems`
  // budget — a hero can't dispatch once the queue's lifetime cap is hit, exactly like a regular.
  const heroCandidates =
    heroRemaining <= 0 || maxItemsRemaining <= 0
      ? []
      : selectCandidates(
          heroItems,
          run.active,
          run.cooldown,
          run.dispatched,
          nowMs,
          heroRemaining,
          maxItemsRemaining,
        );
  // REGULAR selection: gated by the regular concurrency/global slots + the maxItems budget that
  // REMAINS after this sweep's hero picks (heroes and regulars share the one lifetime budget, so
  // a sweep can never dispatch more than `maxItemsRemaining` total across both pools).
  const regularMaxItemsRemaining = Math.max(0, maxItemsRemaining - heroCandidates.length);
  const regularCandidates =
    slots <= 0 || regularMaxItemsRemaining <= 0
      ? []
      : selectCandidates(
          regularItems,
          run.active,
          run.cooldown,
          run.dispatched,
          nowMs,
          slots,
          regularMaxItemsRemaining,
        );

  let regular = 0;
  let hero = 0;
  let acquired = 0;
  try {
    // Dispatch heroes FIRST (they compete for your scarce attention, so surface them promptly),
    // then regulars. Each `dispatchOne` gets its pool classification so it records the hero bit
    // + bumps the correct lifetime counter. The supervisor's OWN budget genuinely BOUNDS this
    // sweep's batch across BOTH pools: acquire a slot per candidate and HOLD it for the whole
    // batch (release only at the end, in the finally) — the starvation-lesson budget the queue
    // pass OWNs separately from the summarizer/manager (§13). The per-pool caps above already
    // bound concurrency/hero-slots; this is the extra per-sweep-batch bound.
    for (const item of heroCandidates) {
      if (!deps.budget.tryAcquire()) break;
      acquired += 1;
      const ok = await dispatchOne(run, item, deps, deps.now(), true);
      if (ok) hero += 1;
    }
    for (const item of regularCandidates) {
      if (!deps.budget.tryAcquire()) break;
      acquired += 1;
      const ok = await dispatchOne(run, item, deps, deps.now(), false);
      if (ok) regular += 1;
    }
  } finally {
    for (let i = 0; i < acquired; i++) deps.budget.release();
  }
  return { regular, hero };
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
  isHero: boolean,
): Promise<boolean> {
  const t = run.template;

  // (a) Grid slot + split plan from the currently-occupied slots (EXITED freed ones
  // excluded so a hole left by a crashed agent is refilled).
  // (hero) A HERO gets its OWN dedicated tab (single terminal) and NEVER participates in the
  // BSP grid packing (HERO-AGENTS.md § Layout). It is assigned grid slot -1 (a sentinel that
  // `occupiesSlot`/the occupied-set scan below EXCLUDE via `gridSlot >= 0`), so it doesn't
  // shift the regular grid's slot indices, and it is spawned as a fresh first-tab below.
  const occupied = new Set<number>();
  for (const a of run.active.values()) {
    if (a.gridSlot >= 0 && occupiesSlot(a)) occupied.add(a.gridSlot);
  }
  // The total pane budget is the EFFECTIVE concurrency (across ALL the run's tabs); the
  // lowest free slot fills the lowest tab first, then overflows (§12). A slot exists for
  // every agent the (gated) concurrency allows.
  const cap = effectiveConcurrency(run);
  const slot = isHero ? -1 : lowestFreeSlot(occupied, cap);
  if (slot === null) return false; // full — shouldn't happen (remainingSlots gated)
  // Plan how to materialize this slot's pane (§12): the run's first tab, an OVERFLOW tab
  // (slot is the first of a fresh tab), or a BALANCED split within the slot's existing tab.
  // `slot`'s only geometry is which tab it belongs to (floor(slot / cols*rows)).
  // (hero) A HERO ALWAYS opens its OWN new tab (single terminal, never in the grid) — the same
  // "firstTab on the run's window" shape as an overflow tab, anchored on a live pane so it
  // shares the run's window. It never calls `splitPlan` (which would place it in the BSP grid).
  const sp = isHero ? undefined : splitPlan(occupied, slot, gridCap(t.grid.cols, t.grid.rows));

  // (b) PENDING record written BEFORE the spawn (crash-safety, §9 step a). The record's
  // queueName is the run's IDENTITY name (`runName`), matching the annotation stamped below
  // + the reconcile filter, so parallel scoped runs of one template never cross-adopt (§9).
  const pending = makePendingRecord(run.runName, item.key, slot, nowMs, {
    title: item.title,
    url: item.url,
    hero: isHero,
  });
  // (c) SYNCHRONOUS active-set insert BEFORE the spawn await (within-tick dedup, §7).
  // The monotonic lifetime counter increments HERE (at the intent), so even a crash
  // between the pending-write and the finalize still counts the dispatch against the
  // §7 lifetime cap — and it is persisted as a top-level field, surviving a restart.
  // (hero) `lifetimeDispatched` is a SINGLE total counter (regular + hero): EVERY dispatch bumps
  // it, so `maxItems` caps both pools (HERO-AGENTS.md § Slot accounting). A hero ALSO joins the
  // AUTHORITATIVE run-level `hero` set so subsequent sweeps classify it as a hero (the record
  // already carries the bit via makePendingRecord).
  run.active.set(item.key, pending);
  if (isHero) run.hero.add(item.key);
  run.lifetimeDispatched += 1;
  // LATCH the key (§7.1): once dispatched it is SUPPRESSED from re-dispatch until a
  // successful `list` no longer reports it (it left the actionable set) and it later
  // returns — so a kill BEFORE the agent claims (the item still in the list) is never
  // re-grabbed. Stamped at the intent (alongside the lifetime counter) + persisted, so it
  // holds across a crash/restart; rolled back below only if the spawn itself fails.
  run.dispatched.add(item.key);
  persistRun(run);

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
    if (sp === undefined) {
      // (hero) HERO tab: open a NEW dedicated single-terminal tab (never a grid split),
      // anchored on the run's window (any seated grid pane) so it shares the run's window like
      // an overflow tab. `firstTab:true` opens a fresh tab; a `windowAnchorUUID` keeps it in the
      // run's existing window when one exists (else it opens frontmost). HERO-AGENTS.md § Layout.
      const windowAnchorUUID = firstSeatedUUID(run);
      spawnArgs = { ...base, firstTab: true, ...(windowAnchorUUID !== undefined ? { windowAnchorUUID } : {}) };
    } else if (sp.firstTab === true) {
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
    // (hero) Roll back the single total counter the dispatch bumped; a hero spawn-failure also
    // drops the run-level hero membership it just joined.
    run.active.delete(item.key);
    if (isHero) run.hero.delete(item.key);
    if (run.lifetimeDispatched > 0) run.lifetimeDispatched -= 1;
    // Roll back the §7.1 latch too: nothing actually launched, so the key must stay
    // eligible to retry on the next list (mirrors the lifetime-counter rollback).
    run.dispatched.delete(item.key);
    persistRun(run);
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
  persistRun(run);

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
      // (hero) stamp the hero verdict so the GUI's across-tabs hero-glyph tab marker + tile
      // visual light up immediately (§ Tab marker / Notification). Reads the run-level set.
      hero: effectiveHero(run, item.key),
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
// ---------------------------------------------------------------------------
// (schedules) Recurring scan-agent pass — see queue/schedule.ts + AGENT-QUEUE.md.
// ---------------------------------------------------------------------------

/** Single-quote a value for a safe shell env-assignment prefix (mirrors dispatchOne's
 *  shellEnvPrefix): wrap in single quotes and escape embedded single quotes. PURE. */
function shellQuote(v: string): string {
  return `'${v.replace(/'/g, "'\\''")}'`;
}

/**
 * (schedules) The whole per-run schedule pass, run every sweep (see AGENT-QUEUE.md → Schedules):
 *   0. ARM any new template schedule (armedAt = now) + PRUNE cadence state for removed ids.
 *   1. COMPLETION: a tracked scheduled run whose surface vanished from `list_surfaces` (its
 *      split CLOSED, by any cause) → record `lastCompletionAt = now` + free the single-flight
 *      slot (this re-anchors the cadence for the next run).
 *   2. RE-ADOPT: a live scheduled surface we don't yet track (a restart re-adopting a still-open
 *      scan) → track it (no re-dispatch; its prose was already delivered).
 *   3. For each live tracked run: DELIVER the prose prompt once the agent is up (typed input +
 *      Enter), and AUTO-CLOSE an EXITED split when the schedule's `closeOnComplete` is set.
 *   4. DISPATCH (only when `canDispatch`): for each schedule with no live run, not paused (unless
 *      a Run-now request overrides), and DUE (`isDue`) or Run-now → spawn a scheduled split.
 * All effects go through `deps`; errors are caught so one bad schedule never breaks the sweep.
 * Schedules occupy the grid but bypass the concurrency/maxItems/max-total caps (they are not in
 * `run.active`). Persists the run when the cadence state changed.
 */
async function scheduleSweep(
  run: QueueRun,
  deps: QueueDeps,
  nowMs: number,
  surfaces: Surface[],
  canDispatch: boolean,
): Promise<void> {
  const specs = run.template.schedules;
  if (specs.length === 0 && run.schedules.size === 0) return; // fast no-op

  let changed = false;

  // 0) Arm new schedules + prune removed ones.
  const inTemplate = new Set<string>();
  for (const s of specs) {
    inTemplate.add(s.id);
    const existing = run.schedules.get(s.id);
    if (existing === undefined) {
      run.schedules.set(s.id, { armedAt: nowMs });
      changed = true;
    } else if (existing.armedAt === 0 && existing.lastCompletionAt === undefined) {
      // A pause/resume command created a placeholder (armedAt 0) before the schedule was ever
      // armed — anchor it to now so a resume doesn't fire it retroactively from the epoch.
      existing.armedAt = nowMs;
      changed = true;
    }
  }
  for (const id of [...run.schedules.keys()]) {
    if (!inTemplate.has(id)) {
      run.schedules.delete(id);
      run.scheduleActive.delete(id);
      run.scheduleRunNow.delete(id);
      changed = true;
    }
  }

  // Map THIS run's live scheduled surfaces by scheduleId (annotation read-back — the row
  // carries queueName + scheduleId, echoed by list_surfaces; a surface of another run or with
  // no scheduleId is skipped).
  const liveById = new Map<string, Surface>();
  for (const s of surfaces) {
    const sQueueName = (s as { queueName?: string }).queueName;
    if (sQueueName !== undefined && sQueueName !== run.runName) continue;
    const sid = (s as { scheduleId?: string }).scheduleId;
    if (typeof sid === "string" && sid.length > 0) liveById.set(sid, s);
  }

  // 1) COMPLETION: a tracked schedule whose surface is gone → its split closed.
  for (const [id, act] of [...run.scheduleActive]) {
    if (!liveById.has(id)) {
      const st = run.schedules.get(id);
      if (st !== undefined) {
        st.lastCompletionAt = nowMs;
        changed = true;
      }
      run.scheduleActive.delete(id);
    }
  }

  // 2) RE-ADOPT: a live scheduled surface we don't yet track (restart). gridSlot -1 = unknown
  // geometry (excluded from occupancy). The prose was delivered at spawn (via env), so there is
  // nothing to re-deliver.
  for (const [id, s] of liveById) {
    if (!run.scheduleActive.has(id) && run.schedules.has(id)) {
      run.scheduleActive.set(id, {
        uuid: s.id,
        sessionID: typeof s.sessionID === "number" ? s.sessionID : 0,
        gridSlot: -1,
      });
    }
  }

  // 3) AUTO-CLOSE an EXITED scheduled split when the schedule opts in (default). Its
  // disappearance next sweep records the completion (step 1). closeOnComplete:false leaves it
  // open for manual review (the normal bell already fired). (The prose was delivered at spawn
  // via GHOSTTY_SCHEDULE_PROMPT — no per-sweep delivery to do.)
  for (const [id] of run.scheduleActive) {
    const s = liveById.get(id);
    if (s === undefined || !s.exited) continue;
    const spec = specs.find((x) => x.id === id);
    if (spec?.closeOnComplete !== false) {
      try {
        await deps.client.forceCloseSurface(s.id);
      } catch (err) {
        errlog(`run "${run.runName}": schedule "${id}" auto-close failed: ${msg(err)}`);
      }
    }
  }

  // 4) DISPATCH due / run-now schedules (single-flight: skip any with a live run).
  if (canDispatch) {
    for (const spec of specs) {
      const id = spec.id;
      if (run.scheduleActive.has(id)) continue; // single-flight
      const st = run.schedules.get(id);
      if (st === undefined) continue;
      const runNow = run.scheduleRunNow.has(id);
      if (st.paused && !runNow) continue; // paused (a Run-now request overrides)
      let due = runNow;
      if (!due) {
        try {
          due = isDue(parseCron(spec.cron), st, nowMs);
        } catch (err) {
          errlog(`run "${run.runName}": schedule "${id}" cron invalid: ${msg(err)}`);
          continue;
        }
      }
      if (!due) continue;
      run.scheduleRunNow.delete(id);
      const ok = await dispatchSchedule(run, spec, deps, nowMs);
      if (ok) changed = true;
    }
  }

  if (changed) persistRun(run);
}

/**
 * (schedules) Dispatch ONE scheduled scan: pack a split into the run's grid (bypassing the
 * concurrency cap — schedules are not in `run.active` and don't consume a slot budget),
 * annotate it (`queueName` + `schedule` + `scheduleId`) so the dashboard groups + marks it and
 * a restart can re-adopt it, and record it as the live run for this schedule with the prose
 * PENDING (delivered by scheduleSweep once the agent is up). Returns true on a successful
 * spawn. Best-effort annotation (a miss is re-stamped never — but reconcile ignores keyless
 * surfaces, so at worst the tile lacks its glyph until the next dispatch).
 */
async function dispatchSchedule(
  run: QueueRun,
  spec: ScheduleSpec,
  deps: QueueDeps,
  nowMs: number,
): Promise<boolean> {
  const t = run.template;

  // Combined grid occupancy: work-item slots (run.active) + other live schedules' slots, with a
  // slot→UUID map so a balanced split anchors on a real pane (schedules aren't in run.active, so
  // occupiedUUID alone would miss a schedule-only run).
  const occupied = new Set<number>();
  const slotUUID = new Map<number, string>();
  for (const a of run.active.values()) {
    if (a.gridSlot >= 0 && occupiesSlot(a) && a.surfaceUUID !== undefined) {
      occupied.add(a.gridSlot);
      slotUUID.set(a.gridSlot, a.surfaceUUID);
    }
  }
  for (const act of run.scheduleActive.values()) {
    if (act.gridSlot >= 0) {
      occupied.add(act.gridSlot);
      slotUUID.set(act.gridSlot, act.uuid);
    }
  }
  // A generous cap so lowestFreeSlot always finds a slot (schedules bypass concurrency); overflow
  // to new tabs/rows is handled by splitPlan + the GUI's grid caps, exactly like a work item.
  const capForSlot = occupied.size + t.schedules.length + 4;
  const slot = lowestFreeSlot(occupied, capForSlot) ?? occupied.size;
  const sp = splitPlan(occupied, slot, gridCap(t.grid.cols, t.grid.rows));
  const lowestUUID = (() => {
    let best: { slot: number; uuid: string } | undefined;
    for (const [sl, uuid] of slotUUID) {
      if (best === undefined || sl < best.slot) best = { slot: sl, uuid };
    }
    return best?.uuid;
  })();

  // The schedule context reaches the agent as ENV — exactly like a work item's GHOSTTY_ITEM_*
  // (§13): the launcher/agent command CONSUMES it (e.g. `claude "$GHOSTTY_SCHEDULE_PROMPT"`),
  // rather than us typing the prose in (a fresh raw-mode TUI drops pre-first-input typing, and
  // its agentState never reports until it gets input — so a send_text gate would never fire).
  //   - GHOSTTY_SCHEDULE_PROMPT : the resolved prose (from promptFile/prompt) — the actual scan.
  //   - GHOSTTY_SCHEDULE_ID / _NAME : the schedule identity.
  //   - the run's resolved param env (LINEAR_PROJECT / …) so the scan is SCOPED to the same
  //     project/milestone as the run ("parameterized by queue") — same env the provider gets.
  // Delivered TWO ways for the two backends (mirrors dispatchOne): a single-quoted env-assignment
  // PREFIX on `command` (survives the pty-host `.client` backend, which forwards the command but
  // NOT the `env` field) AND the `env` map (honored under `.exec`).
  const scheduleEnv: Record<string, string> = {
    ...resolveParamsEnv(t, run.params),
    GHOSTTY_SCHEDULE_ID: spec.id,
    GHOSTTY_SCHEDULE_NAME: spec.name ?? spec.id,
    GHOSTTY_SCHEDULE_PROMPT: spec.prompt ?? "",
  };
  const prefix = Object.entries(scheduleEnv)
    .map(([k, v]) => `${k}=${shellQuote(v)}`)
    .join(" ");
  const command = `${prefix} ${spec.command ?? t.agent.command}`;
  const env = scheduleEnv;

  let spawned: { id: string; sessionId: number };
  try {
    const base = { command, cwd: t.workdir, env };
    let spawnArgs: Parameters<typeof deps.client.spawnSplitCommand>[0];
    if (sp.firstTab === true) {
      // The run's first pane — but if the run already has seated panes elsewhere, anchor on the
      // run's window so the scheduled tab shares it (mirrors dispatchOne's overflow shape).
      const anchor = lowestUUID;
      spawnArgs = { ...base, firstTab: true, ...(anchor !== undefined ? { windowAnchorUUID: anchor } : {}) };
    } else if (sp.newTab === true) {
      const anchor = slotUUID.get(sp.windowAnchorSlotIndex ?? -1) ?? lowestUUID;
      spawnArgs = { ...base, firstTab: true, ...(anchor !== undefined ? { windowAnchorUUID: anchor } : {}) };
    } else {
      const target = slotUUID.get(sp.anchorSlotIndex ?? -1) ?? lowestUUID;
      spawnArgs = {
        ...base,
        ...(target !== undefined ? { targetUUID: target } : {}),
        balanced: true,
        maxCols: t.grid.cols,
        maxRows: t.grid.rows,
      };
    }
    spawned = await deps.client.spawnSplitCommand(spawnArgs);
  } catch (err) {
    errlog(`run "${run.runName}": schedule "${spec.id}" spawn failed: ${msg(err)}`);
    return false;
  }

  // Record the live run BEFORE the (awaited) annotation — the single-flight gate must hold even
  // if the annotation write throws. (The prose was delivered at spawn via GHOSTTY_SCHEDULE_PROMPT.)
  run.scheduleActive.set(spec.id, {
    uuid: spawned.id,
    sessionID: spawned.sessionId,
    gridSlot: slot,
  });

  // Annotate so the dashboard groups it under the queue + marks it a schedule, and a restart can
  // re-adopt it. NO queueKey — a schedule is not a work item, so the work-item reconcile leaves
  // it alone (it only adopts surfaces carrying a queueKey).
  try {
    await deps.client.setAnnotation(spawned.id, {
      queueName: run.runName,
      schedule: true,
      scheduleId: spec.id,
    });
  } catch (err) {
    errlog(`run "${run.runName}": schedule "${spec.id}" annotate failed: ${msg(err)}`);
  }
  log(`run "${run.runName}": dispatched schedule "${spec.id}" (${spec.name ?? spec.id})`);
  return true;
}

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

/** The first SEATED (has a `surfaceUUID`) anchor pane ANYWHERE in a run — the lowest occupied
 *  slot's UUID. Used by `runAdopt` to address the run's grid tab for the move. Returns
 *  `undefined` when the run has no seated pane (empty/all-unseated run). PURE. */
function firstSeatedUUID(run: QueueRun): string | undefined {
  let best: { slot: number; uuid: string } | undefined;
  for (const a of run.active.values()) {
    if (a.gridSlot >= 0 && occupiesSlot(a) && a.surfaceUUID !== undefined) {
      if (best === undefined || a.gridSlot < best.slot) best = { slot: a.gridSlot, uuid: a.surfaceUUID };
    }
  }
  return best?.uuid;
}

/**
 * (adopt) Perform the SIDE EFFECTS of an `adopt` command: physically MOVE the human-created
 * split into the run's grid tab, STAMP the queue annotation (so reconcile folds it in next
 * sweep), FIRE the provider claim, and PERSIST the latch. The reducer (`applyCommand`) already
 * added the latch SYNCHRONOUSLY (before this `await`) — the crux that blocks a second dispatch.
 *
 * Ordering / correctness (LOCKED FORCED CORRECTNESS): the only ROLLBACK is a MOVE failure (the
 * split never entered the grid → the item must stay dispatchable, so we clear the latch). The
 * annotation/claim are best-effort; reconcile's existing orphan-adoption (store.ts) folds the
 * annotated surface in next sweep as a RUNNING assignment — relying on its non-zero-`sessionID`
 * precondition (guaranteed under the queue's pty-host HARD DEP). NEVER writes `run.active`
 * (reconcile is its single owner) — this writes only `run.dispatched` + the annotation, so it
 * occupies a concurrency slot WITHOUT incrementing `lifetimeDispatched` (no new agent launched).
 */
async function runAdopt(cmd: QueueCommand, deps: QueueDeps): Promise<void> {
  const name = cmd.run;
  const key = cmd.key;
  const uuid = cmd.surfaceUUID;
  // The reducer already no-op'd (and added NO latch) on any missing arg / unknown run, so
  // there is nothing to move or roll back here.
  if (name === undefined || name.length === 0 || key === undefined || key.length === 0 || uuid === undefined || uuid.length === 0) {
    return;
  }
  const run = deps.registry.get(name);
  if (run === undefined) return;

  // Re-check the dedup against the LIVE active map (a sweep may have advanced state since the
  // reducer ran): if the key is now an active assignment, do NOT move + do NOT touch the latch
  // (either the reducer rejected it, or this active-map check now covers it).
  if (run.active.has(key)) {
    errlog(`run "${name}": adopt ${key} — already active, skipping move`);
    return;
  }
  // The reducer adds the latch; confirm it (defensive — if somehow absent there's nothing to
  // roll back, and reconcile would still fold an annotated surface in).
  const t = run.template;

  // MOVE the split into the run's grid tab, anchored on a seated pane. If the run has NO
  // seated pane (empty/all-unseated run), DO NOT move — the adopted split becomes the run's
  // seed (reconcile gives it slot 0 next sweep). Overflow at capacity (LOCKED #5) is handled
  // by `move_surface_into_tab` honoring maxCols/maxRows (multi-tab overflow packing).
  const anchorUUID = firstSeatedUUID(run);
  if (anchorUUID !== undefined) {
    if (deps.client.moveSurfaceIntoTab === undefined) {
      errlog(`run "${name}": adopt ${key} — move_surface_into_tab unavailable; leaving split in place (reconcile still adopts)`);
    } else {
      try {
        await deps.client.moveSurfaceIntoTab({
          sourceUUID: uuid,
          targetAnchorUUID: anchorUUID,
          balanced: true,
          maxCols: t.grid.cols,
          maxRows: t.grid.rows,
        });
      } catch (err) {
        // MOVE failed → ROLL BACK the latch (the adoption did not happen, so the item must
        // stay dispatchable), persist, and return.
        run.dispatched.delete(key);
        persistRun(run);
        errlog(`run "${name}": adopt ${key} move failed: ${msg(err)} — latch rolled back, item stays free`);
        return;
      }
    }
  }

  // STAMP the annotation so reconcile adopts the moved-in surface next sweep. keep FOLLOWS the
  // template `keepOnComplete` (LOCKED #3), NOT a forced true.
  try {
    await deps.client.setAnnotation(uuid, {
      queueKey: key,
      queueName: run.runName,
      ...(cmd.url !== undefined && cmd.url.length > 0 ? { queueUrl: cmd.url } : {}),
      keep: effectiveKeep(run, key),
    });
  } catch (err) {
    errlog(`run "${name}": adopt ${key} annotate: ${msg(err)}`);
  }

  // FIRE the provider claim (consistent with dispatchOne §g) — a latency optimization, never
  // correctness. Fire-and-forget.
  if (t.provider.claim !== undefined) {
    const argv = renderArgv(t.provider.claim.command, key);
    void runProvider(argv, deps.exec, {
      cwd: t.workdir,
      env: resolveParamsEnv(t, run.params),
    }).catch(() => {
      /* claim failure is non-fatal + already logged inside runProvider's result */
    });
  }

  // PERSIST the latch NOW (the active map is updated by the NEXT reconcile's adopt; persisting
  // the latch here ensures suppression survives a crash before that reconcile).
  persistRun(run);
  log(`run "${run.runName}": ADOPTED ${key} (surface ${uuid}) — latched, moved, annotated`);
}

/** (adopt) Drive the OPTIONAL `infer_key` side effect: hand off to the `deps.inferKey` seam
 *  (wired in index.ts to read the surface → Haiku → write `queueKeySuggested`). Gated so a test
 *  without the seam is a no-op. `cmd.run` may be "" (the multi-run pre-pick case) — the seam
 *  tolerates it (empty candidate list, still reads the surface). */
async function runInferKey(cmd: QueueCommand, deps: QueueDeps): Promise<void> {
  const uuid = cmd.surfaceUUID;
  if (uuid === undefined || uuid.length === 0) return;
  if (deps.inferKey === undefined) return;
  await deps.inferKey(uuid, cmd.run ?? "");
}

/**
 * (hero) Perform the SIDE EFFECTS of a `promote` command: EJECT the running regular split into
 * its OWN new tab (single terminal, out of the BSP grid) via the `move_split_to_new_tab` keybind
 * action, then RE-STAMP the surface annotation with the hero verdict so the GUI's across-tabs
 * hero-glyph tab marker + tile visual light up (HERO-AGENTS.md § Layout / § Tab marker). The
 * reducer (`applyCommand`) already flipped the run-level `hero` bit SYNCHRONOUSLY — so the
 * two-pool accounting classifies the split as a hero THIS sweep (and `runOne` re-stamps
 * `Assignment.hero` from the set); this only does the physical eject + annotation.
 *
 * Promotion NEVER BLOCKS on the hero cap: it mutates a RUNNING assignment (does not dispatch), so
 * it may push `heroActiveGlobal` PAST `agent-queue-hero-max` — the only consequence is that no NEW
 * heroes dispatch until it drains under (the hero gate in dispatchCandidates handles that). Both
 * effects are best-effort: a failed eject is logged (the split stays in place but is still a hero
 * by accounting); reconcile keeps `run.active` current regardless. It makes a single narrow write
 * to `run.active` (grid slot -1 + hero:true on the promoted record) so THIS sweep's accounting is
 * immediately correct — the run-level `run.hero` set the reducer flipped remains the AUTHORITATIVE
 * source reconcile re-derives from every sweep (mirrors the wording in `runDemote`). The grid slot
 * is reassigned to the ejected-out sentinel (-1) so the packer + the next dispatch's occupied-set
 * scan (`gridSlot >= 0`) exclude the hero from BSP packing. Promotion is COUNTER-NEUTRAL: the item
 * was already counted once in the single total `lifetimeDispatched` at its dispatch, and stays
 * counted — so it neither refunds a `maxItems` slot (which would let the queue over-launch) nor
 * double-counts. Marking it a hero frees only its regular CONCURRENCY slot (heroes run off-grid).
 */
async function runPromote(cmd: QueueCommand, deps: QueueDeps): Promise<void> {
  const name = cmd.run;
  const uuid = cmd.surfaceUUID;
  // The reducer already no-op'd on any missing arg / unknown run, so there's nothing to do here.
  if (name === undefined || name.length === 0 || uuid === undefined || uuid.length === 0) return;
  const run = deps.registry.get(name);
  if (run === undefined) return;
  const key = cmd.key;

  // EJECT the split into its own new tab (single terminal). Reuses the `move_split_to_new_tab`
  // keybind action via perform_action (focus-then-act, GUI-side). Best-effort: on failure the
  // split stays where it is but is still a hero for accounting/marker purposes.
  if (deps.client.performAction === undefined) {
    errlog(`run "${name}": promote — perform_action unavailable; hero stays in place (still accounted as hero)`);
  } else {
    try {
      await deps.client.performAction(uuid, "move_split_to_new_tab");
    } catch (err) {
      errlog(`run "${name}": promote eject ${key ?? uuid} failed: ${msg(err)} — hero stays in place`);
    }
  }

  // Reassign the assignment's grid slot to the ejected-out sentinel (-1) so it no longer
  // participates in the BSP grid occupancy (mirrors a hero dispatch's slot -1), and flip its
  // per-record `hero` bit so this sweep's accounting sees it as a hero at once.
  //
  // (hero) CONCURRENCY freed, maxItems NOT refunded. Marking the assignment a hero excludes it
  // from `regularOccupancy`, so the run's CONCURRENCY gate immediately has one more free slot — a
  // regular can take the vacated slot (intended: a hero runs in its own tab, off the grid). But
  // the promoted item was LAUNCHED as a regular and so counts against the HISTORICAL `maxItems`
  // lifetime budget FOREVER — we deliberately do NOT decrement `run.lifetimeDispatched`, so
  // promotion can't refund a lifetime slot and let the queue dispatch another regular BEYOND
  // `maxItems`. (An earlier build decremented it here; that over-launched past the cap.) The
  // reconcile floor at runOne only ever RAISES `lifetimeDispatched` (to the live regular fleet),
  // never lowers it, so the historical count stands even though the promoted item left the
  // regular pool.
  if (key !== undefined && key.length > 0) {
    const a = run.active.get(key);
    if (a !== undefined) run.active.set(key, { ...a, gridSlot: -1, hero: true });
  }

  // RE-STAMP the annotation so the GUI hero marker/tile light up immediately (independent of the
  // per-sweep restamp). keep FOLLOWS the run-level verdict (a hero is kept-by-default in the close
  // gate, but the annotation `keep` still reflects effectiveKeep for the pin display).
  try {
    await deps.client.setAnnotation(uuid, {
      queueName: run.runName,
      ...(key !== undefined && key.length > 0 ? { queueKey: key, keep: effectiveKeep(run, key) } : {}),
      hero: true,
    });
  } catch (err) {
    errlog(`run "${name}": promote annotate ${key ?? uuid}: ${msg(err)}`);
  }

  // PERSIST the run-level hero set now (the reducer flipped it; persisting here ensures the
  // promotion survives a crash before the next reconcile sweep, like runAdopt persists the latch).
  persistRun(run);
  log(`run "${run.runName}": PROMOTED ${key ?? uuid} to HERO — ejected to own tab, annotated`);
}

/**
 * (hero) Perform the SIDE EFFECTS of a `demote` command: DROP the hero annotation so the GUI
 * clears the hero glyph tab marker + tile visual; the split RE-ENTERS the regular pool for
 * future accounting (the reducer already cleared the run-level `hero` bit synchronously); AND
 * RE-PACK the split back into the run's BSP grid — symmetric with promote's eject. A promoted
 * split lives in its OWN tab with gridSlot -1; leaving it there on demote stranded a plain
 * regular in a dedicated tab (the "normal agent in a dedicated tab" report). We now move it into
 * a seated regular anchor's grid tab via the SAME balanced `moveSurfaceIntoTab` the packer/adopt
 * use (multi-tab overflow honored) and reset its gridSlot so it re-enters occupancy. Best-effort:
 * with no grid anchor (the run's only pane) there's nothing to pack into, so it stays put; a
 * failed move logs and leaves it in place. Mutates `run.active` in place (hero bit + gridSlot) —
 * the established pattern (see packRun) — then persists.
 */
async function runDemote(cmd: QueueCommand, deps: QueueDeps): Promise<void> {
  const name = cmd.run;
  const uuid = cmd.surfaceUUID;
  if (name === undefined || name.length === 0 || uuid === undefined || uuid.length === 0) return;
  const run = deps.registry.get(name);
  if (run === undefined) return;
  const key = cmd.key;

  // Resolve the demoted assignment — by key when we have one, else by surface UUID (demote may
  // carry only the surface). Mutated in place (the established pattern — see packRun).
  const asgn = (key !== undefined && key.length > 0)
    ? run.active.get(key)
    : [...run.active.values()].find((a) => a.surfaceUUID === uuid);

  // Reflect the demotion on the per-record bit at once (reconcile also re-derives it from the
  // now-cleared run-level set every sweep).
  if (asgn !== undefined && asgn.hero) asgn.hero = false;

  // RE-PACK the split back into the run's BSP grid — symmetric with promote's eject (the split
  // was ejected to its OWN tab on promote and given gridSlot -1). Find a SEATED regular anchor
  // already in the grid + the lowest free slot, then MOVE it there via the SAME balanced
  // cross-tab move the packer/adopt use (multi-tab overflow honored by maxCols/maxRows). On a
  // successful move, reset gridSlot so the item re-enters occupancy accounting. Best-effort:
  // with NO anchor (the demoted split is the run's only pane) there is no grid to pack into, so
  // it just stays in its own tab; a failed move logs and leaves it in place (still demoted).
  let repacked = false;
  if (asgn !== undefined && asgn.surfaceUUID !== undefined && deps.client.moveSurfaceIntoTab !== undefined) {
    const occupied = new Set<number>();
    let anchor: string | undefined;
    for (const a of run.active.values()) {
      if (a.surfaceUUID === asgn.surfaceUUID) continue;
      if (a.gridSlot >= 0 && occupiesSlot(a)) {
        occupied.add(a.gridSlot);
        if (anchor === undefined && a.surfaceUUID !== undefined) anchor = a.surfaceUUID;
      }
    }
    const slot = anchor !== undefined ? lowestFreeSlot(occupied, effectiveConcurrency(run)) : null;
    if (anchor !== undefined && slot !== null) {
      try {
        await deps.client.moveSurfaceIntoTab({
          sourceUUID: asgn.surfaceUUID,
          targetAnchorUUID: anchor,
          balanced: true,
          maxCols: run.template.grid.cols,
          maxRows: run.template.grid.rows,
        });
        asgn.gridSlot = slot;
        repacked = true;
      } catch (err) {
        errlog(`run "${name}": demote re-pack ${key ?? uuid} failed: ${msg(err)} — split stays in its own tab`);
      }
    }
  }

  // DROP the hero annotation so the GUI clears the marker. keep FOLLOWS effectiveKeep now that
  // the hero-forced hold is gone (a demoted split without a 📌 pin resumes normal auto-close).
  try {
    await deps.client.setAnnotation(uuid, {
      queueName: run.runName,
      ...(key !== undefined && key.length > 0 ? { queueKey: key, keep: effectiveKeep(run, key) } : {}),
      hero: false,
    });
  } catch (err) {
    errlog(`run "${name}": demote annotate ${key ?? uuid}: ${msg(err)}`);
  }

  persistRun(run);
  log(`run "${run.runName}": DEMOTED ${key ?? uuid} to regular — hero annotation dropped${repacked ? ` (re-packed into grid slot ${asgn?.gridSlot})` : " (no grid anchor — stays in own tab)"}`);
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
    persistRun(run);
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

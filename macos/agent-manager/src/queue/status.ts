// (ramon fork / Agent Queue Supervisor, §11 health) The run-level HEALTH report the
// supervisor PUSHES to the GUI each sweep via the `report_queue_status` MCP tool, so the
// Agent Dashboard can show — even BEFORE any split spawns — that a queue is present and
// what it's about to do (count + what's next). PURE: `queueStatusReport` derives the report
// from primitives; runner.ts owns the I/O (caching the last list + the MCP call).

import type { BlockReason, GraphNode, WorkItem } from "./types.js";

/** One item reference for the dashboard header dropdowns (key + optional title + the
 *  Linear/tracker URL, so a "0 waiting"/"N running" click can link out). */
export interface QueueItemRef {
  key: string;
  title?: string;
  url?: string;
  /** (hero) The dispatch GATE(s) currently blocking this WAITING item, so the backlog
   *  canvas can say EXACTLY why it hasn't dispatched (a hero stuck on `heroSlots` vs. a
   *  regular past `maxItems`). Present ONLY on `next[]` (waiting) refs, and only when at
   *  least one gate is blocking it (omitted when the item WOULD dispatch — i.e. a free
   *  slot exists — so an unblocked backlog item carries no reasons). Dependency-blocked is
   *  intentionally NOT a reason (the graph edges already show it). See HERO-AGENTS.md. */
  blockReasons?: BlockReason[];
  /** (ramon fork / Hero Agents) True when this item is a HERO — set on `next` (waiting),
   *  `running`, AND `held` refs so the dashboard's "N waiting/running/held" dropdowns mark
   *  heroes at a glance (a load-bearing item in its own tab, capped by `agent-queue-hero-max`).
   *  Sourced from the caller's `heroKeys` (run-level `hero` set ∪ active hero assignments ∪
   *  `list` items with a truthy `heroField`) plus a WorkItem's own `hero`. Absent ⇒ regular. */
  hero?: boolean;
}

/** The run-level health snapshot the GUI dashboard renders. Mirrors the Swift
 *  `QueueStatus` value type + `report_queue_status` tool args. */
export interface QueueStatusReport {
  queueName: string;
  /** false ⇒ the run was removed (drained/aborted/quit/empty) — the GUI clears it. */
  present: boolean;
  /** Coarse lifecycle phase for the header chip. */
  phase: "starting" | "running" | "paused" | "draining" | "disabled";
  /** Count of actionable items NOT currently active (the backlog "how many"). */
  queued: number;
  /** Whether the last `list` fetch SUCCEEDED — false ⇒ "starting"/provider error, so
   *  the GUI can distinguish "0 waiting" from "haven't/ couldn't read the queue yet". */
  listOk: boolean;
  /** Slot-occupying assignments (how many agents are running right now). */
  active: number;
  /** Lifetime dispatches so far (against `maxItems`). */
  dispatched: number;
  /** Effective lifetime cap, or null for unlimited. */
  maxItems: number | null;
  /** Effective max SIMULTANEOUS agents (the live `set_concurrency` edit if set, else the
   *  template `concurrency`). The dashboard shows it + lets the user tap-to-edit it. */
  concurrency: number;
  /** Up to `nextLimit` of the next actionable items (not currently active) — the
   *  "N waiting" dropdown. May be shorter than `queued` (capped); each carries its URL. */
  next: QueueItemRef[];
  /** The currently-RUNNING items (one per slot-occupying agent) — the "M running"
   *  dropdown. `running.length === active`. Each carries its URL. */
  running: QueueItemRef[];
  /** (release) Count of HELD items — keys still in the §7.1 dispatch latch AND still in the
   *  actionable list but no longer active. These were dispatched once but the queue won't
   *  re-dispatch them: the agent crashed/exited, OR was killed before it claimed the item, so
   *  the item is back in the backlog yet the latch suppresses it (normally only a tracker
   *  status round-trip clears the latch). The "N held" dropdown exposes them so they can be
   *  RELEASED in-place. `held.length` may be < `heldCount` (capped at `nextLimit`). */
  heldCount: number;
  /** (release) Up to `nextLimit` of those HELD items — each with a per-item Release button
   *  (clears its latch so it re-dispatches on the next list poll, no tracker round-trip). */
  held: QueueItemRef[];
  /** (hero) The fleet-wide `agent-queue-hero-max` cap (0 = hero dispatch DISABLED). Global,
   *  NOT per-run — the same value on every run's report. Mirrors the Swift `QueueStatus`. */
  heroMax: number;
  /** (hero) The fleet-wide count of live HERO assignments across ALL runs (`heroActiveGlobal`).
   *  The hero gate's remaining is `heroMax − heroActive`; when ≥ `heroMax`, a waiting hero
   *  carries a `heroSlots` block reason. Global, NOT per-run. */
  heroActive: number;
  /** (schedules) The run's recurring scan-agent SCHEDULES, for the dashboard's thin Schedules
   *  lane (see AGENT-QUEUE.md → Schedules). Empty when the template declares none. Built by the
   *  runner (the cron math lives with the run state) and echoed here unchanged. */
  schedules: ScheduleStatus[];
}

/** (schedules) One schedule's live status for the dashboard Schedules lane. */
export interface ScheduleStatus {
  /** The schedule id (stable identity). */
  id: string;
  /** Display name (defaults to the id). */
  name: string;
  /** User-muted (vacation). */
  paused: boolean;
  /** A scan is in flight right now (single-flight — no new run until it closes). */
  running: boolean;
  /** ms-since-epoch of the next scheduled start; absent when paused or currently running
   *  (nothing is armed while a run is in flight). The lane renders it as "next in …". */
  nextRunAt?: number;
  /** ms-since-epoch the most recent run's split closed; absent if it has never run. Rendered
   *  as "ran … ago". */
  lastCompletionAt?: number;
}

/** Inputs for the pure status builder — primitives + the run's in-memory facts. */
export interface QueueStatusInputs {
  queueName: string;
  present: boolean;
  paused: boolean;
  draining: boolean;
  disabled: boolean;
  /** false until the run has reconciled+armed once (the very first sweep) — drives the
   *  "starting" phase so the dashboard shows the queue immediately, before any dispatch. */
  dispatchArmed: boolean;
  /** The currently-RUNNING items (slot-occupying assignments) with key/title/url. The
   *  report's `active` count is `runningItems.length` and `running` echoes them. */
  runningItems: ReadonlyArray<QueueItemRef>;
  /** Keys NOT eligible to dispatch (active assignments of any state + the §7.1 latch) —
   *  excluded from queued/next so the backlog reflects what would actually dispatch. */
  excludeKeys: ReadonlySet<string>;
  /** (release) The §7.1 dispatch-latch keys (`run.dispatched`). A listed key in this set
   *  that is NOT in `activeKeys` is HELD — surfaced as `held`/`heldCount` so it can be
   *  released. Defaults to empty (legacy build / present:false). */
  latchedKeys?: ReadonlySet<string>;
  /** (release) The currently-tracked assignment keys (`run.active`, ANY state). A held key
   *  that is still active (RUNNING / EXITED-with-split) is NOT shown (it isn't stuck behind
   *  the latch — it's tracked). Defaults to empty. */
  activeKeys?: ReadonlySet<string>;
  /** The most recent `list` items, or null if none fetched yet (arm sweep / paused-first). */
  listItems: ReadonlyArray<WorkItem> | null;
  /** Whether the most recent `list` fetch succeeded. */
  listOk: boolean;
  dispatched: number;
  /** Effective lifetime cap (null = unlimited). */
  maxItemsCap: number | null;
  /** Effective max simultaneous agents (the live `set_concurrency` edit if set, else the
   *  template `concurrency`). Defaults to 0 when omitted (a present:false / legacy build). */
  concurrency?: number;
  /** How many "next" items to include (default 5). */
  nextLimit?: number;
  // ----- (hero) block-reason attribution inputs (per-run gate ROOM this sweep) -----
  // These let the pure builder attribute WHY each waiting item can't dispatch. All are the
  // room REMAINING (≥ 0); a gate is "blocking" when its room is ≤ 0. They are the SAME
  // primitives the dispatch gate consults (`dispatchCandidates`), passed in so the report
  // stays a pure function. Omitted ⇒ no attribution (legacy/present:false ⇒ blockReasons absent).
  /** (schedules) The run's schedule statuses, prebuilt by the runner (cron math lives with the
   *  run state). Echoed unchanged into the report. Defaults to [] (no schedules / legacy). */
  schedules?: ScheduleStatus[];
  /** (hero) The fleet-wide `agent-queue-hero-max` cap (0 = hero dispatch disabled). Echoed as
   *  `heroMax`. */
  heroMax?: number;
  /** (hero) Fleet-wide live-hero count (`heroActiveGlobal`). Echoed as `heroActive`. A waiting
   *  HERO item is `heroSlots`-blocked when `heroMax − heroActive ≤ 0`. */
  heroActive?: number;
  /** (hero) Remaining REGULAR concurrency room = `effConcurrency − activeRegular` (≤ 0 ⇒ a
   *  waiting regular item is `queueConcurrency`-blocked). */
  regularConcurrencyRemaining?: number;
  /** (hero) Remaining fleet-wide REGULAR global room = `agent-queue-max-total −
   *  totalRegularActive` (≤ 0 ⇒ a waiting regular item is `globalConcurrency`-blocked).
   *  POSITIVE_INFINITY when max-total is unlimited. */
  regularGlobalRemaining?: number;
  /** (hero) Remaining REGULAR lifetime budget = `maxItemsCap − lifetimeDispatched` (≤ 0 ⇒ a
   *  waiting regular item is `maxItems`-blocked). POSITIVE_INFINITY when maxItems is unlimited. */
  regularMaxItemsRemaining?: number;
  /** (hero) Keys that are HEROES right now — the run-level `hero` set (promotions) ∪ active hero
   *  assignments ∪ `list` items with a truthy `heroField`. Used to mark `next`/`running`/`held`
   *  refs so the dashboard dropdowns show a hero glyph. Defaults empty (legacy/present:false). */
  heroKeys?: ReadonlySet<string>;
}

/**
 * Build the run-level health report. PURE + unit-tested. `queued`/`next` are derived from
 * the last list MINUS the active keys (the backlog the user is asking about). `phase` is
 * starting (not yet armed, or no successful list yet) → paused → draining → disabled →
 * running, in that precedence. A `present:false` build (run removed) zeroes the live
 * fields so the GUI clears the section cleanly.
 */
export function queueStatusReport(input: QueueStatusInputs): QueueStatusReport {
  const nextLimit = input.nextLimit ?? 5;
  if (!input.present) {
    return {
      queueName: input.queueName,
      present: false,
      phase: "running",
      queued: 0,
      listOk: false,
      active: 0,
      dispatched: input.dispatched,
      maxItems: input.maxItemsCap,
      concurrency: input.concurrency ?? 0,
      next: [],
      running: [],
      heldCount: 0,
      held: [],
      heroMax: input.heroMax ?? 0,
      heroActive: input.heroActive ?? 0,
      schedules: input.schedules ?? [],
    };
  }

  const backlog = (input.listItems ?? []).filter(
    (i) => typeof i.key === "string" && i.key.length > 0 && !input.excludeKeys.has(i.key),
  );
  // De-dupe by key (a flaky provider can repeat) while preserving order.
  const seen = new Set<string>();
  const deduped: WorkItem[] = [];
  for (const i of backlog) {
    if (seen.has(i.key)) continue;
    seen.add(i.key);
    deduped.push(i);
  }

  // Phase precedence: a disabled/draining/paused run reports that even mid-dispatch;
  // otherwise "starting" until it has armed AND seen a successful list, then "running".
  let phase: QueueStatusReport["phase"];
  if (input.disabled) phase = "disabled";
  else if (input.draining) phase = "draining";
  else if (input.paused) phase = "paused";
  else if (!input.dispatchArmed || !input.listOk) phase = "starting";
  else phase = "running";

  // (release) HELD items = listed ∩ latched ∩ ¬active, deduped in list order. A latched key
  // not in the current list is omitted (it left the actionable set — the §7.1 re-arm clears it
  // on the next successful list); a latched key that is still active is omitted (it's tracked,
  // not stuck behind the latch).
  const latched = input.latchedKeys ?? new Set<string>();
  const activeKeys = input.activeKeys ?? new Set<string>();
  const heldSeen = new Set<string>();
  const heldItems: WorkItem[] = [];
  for (const i of input.listItems ?? []) {
    if (typeof i.key !== "string" || i.key.length === 0) continue;
    if (!latched.has(i.key) || activeKeys.has(i.key)) continue;
    if (heldSeen.has(i.key)) continue;
    heldSeen.add(i.key);
    heldItems.push(i);
  }

  // Map a WorkItem/ref → QueueItemRef, including title/url only when non-empty. (hero) Marks the
  // ref a hero when the caller's `heroKeys` contains its key OR the item carries its own `hero`
  // (a `list` WorkItem with a truthy `heroField`) — so every dropdown (waiting/running/held) shows
  // the hero glyph, not just the backlog canvas.
  const heroKeys = input.heroKeys ?? new Set<string>();
  const toRef = (i: { key: string; title?: string; url?: string; hero?: boolean }): QueueItemRef => {
    const ref: QueueItemRef = { key: i.key };
    if (i.title !== undefined && i.title.length > 0) ref.title = i.title;
    if (i.url !== undefined && i.url.length > 0) ref.url = i.url;
    if (i.hero === true || heroKeys.has(i.key)) ref.hero = true;
    return ref;
  };

  // (hero) Attribute the dispatch GATE(s) blocking a WAITING item. PURE. A HERO item competes
  // ONLY for the fleet-wide hero slots (`heroSlots`); a REGULAR item competes for the run's
  // concurrency (`queueConcurrency`), the fleet-wide `max-total` (`globalConcurrency`), and the
  // run's lifetime budget (`maxItems`) — and can be blocked by several at once. A gate is
  // blocking when its remaining room is ≤ 0. Returns `undefined` when no applicable gate blocks
  // (the item WOULD dispatch — a slot exists; it's just next in line), so `blockReasons` is
  // OMITTED on an unblocked ref. Dependency-blocked is intentionally NOT a reason here.
  const heroRemaining =
    input.heroMax !== undefined && input.heroActive !== undefined
      ? input.heroMax - input.heroActive
      : undefined;
  const blockReasonsFor = (item: WorkItem): BlockReason[] | undefined => {
    const reasons: BlockReason[] = [];
    if (item.hero === true) {
      // A hero-marked item: only the fleet-wide hero-slot gate applies. `heroMax === 0` (hero
      // dispatch disabled) yields heroRemaining ≤ 0 too, so a disabled build shows `heroSlots`.
      if (heroRemaining !== undefined && heroRemaining <= 0) reasons.push("heroSlots");
    } else {
      // A regular item: the three regular-pool gates, in the report's canonical order.
      if (input.regularMaxItemsRemaining !== undefined && input.regularMaxItemsRemaining <= 0)
        reasons.push("maxItems");
      if (
        input.regularConcurrencyRemaining !== undefined &&
        input.regularConcurrencyRemaining <= 0
      )
        reasons.push("queueConcurrency");
      if (input.regularGlobalRemaining !== undefined && input.regularGlobalRemaining <= 0)
        reasons.push("globalConcurrency");
    }
    return reasons.length > 0 ? reasons : undefined;
  };
  // A waiting ref carries its block reasons (when blocked). Only `next` (waiting) items get them.
  const toNextRef = (i: WorkItem): QueueItemRef => {
    const ref = toRef(i);
    const reasons = blockReasonsFor(i);
    if (reasons !== undefined) ref.blockReasons = reasons;
    return ref;
  };

  return {
    queueName: input.queueName,
    present: true,
    phase,
    queued: deduped.length,
    listOk: input.listOk,
    active: input.runningItems.length,
    dispatched: input.dispatched,
    maxItems: input.maxItemsCap,
    concurrency: input.concurrency ?? 0,
    next: deduped.slice(0, nextLimit).map(toNextRef),
    running: input.runningItems.map(toRef),
    heldCount: heldItems.length,
    held: heldItems.slice(0, nextLimit).map(toRef),
    heroMax: input.heroMax ?? 0,
    heroActive: input.heroActive ?? 0,
    schedules: input.schedules ?? [],
  };
}

// ---------------------------------------------------------------------------
// Backlog graph (the OPTIONAL `provider.graph` board) — pushed to the GUI via
// `report_queue_graph` for the dashboard's "N backlog" button + DAG canvas.
// ---------------------------------------------------------------------------

/** The board snapshot the sidecar pushes via the `report_queue_graph` MCP tool. Mirrors
 *  the Swift `QueueGraph` value type 1:1. `backlog` is the header-badge count (derived
 *  once here so the GUI and the canvas agree); `nodes` is the full board for the canvas. */
export interface QueueGraphReport {
  queueName: string;
  /** false ⇒ the run was removed — the GUI clears the backlog button + canvas. */
  present: boolean;
  /** The header-badge count: non-terminal nodes NOT currently waiting/running. */
  backlog: number;
  /** The full scoped board (every state) for the DAG canvas. */
  nodes: GraphNode[];
}

/**
 * `stateType` categories (provider-supplied, generic) that mean the item is ALREADY being
 * worked on — EXCLUDED from the backlog badge. The badge counts the *groomable/schedulable
 * remainder* (work that could still be picked up), and an in-progress item has already been
 * picked up (by a human or another process); it is neither schedulable now nor groomable.
 * Generic: this keys off the same standard `stateType` vocabulary the canvas colors by
 * (triage/backlog/unstarted/started/completed/canceled). An ABSENT/unknown stateType is NOT
 * excluded (counted as backlog — the safe default), so a provider that doesn't classify
 * states still gets a sensible count. Compared case-insensitively.
 */
const IN_PROGRESS_STATE_TYPES = new Set(["started"]);

/**
 * Count the "backlog" — the groomable remainder shown on the header button: graph nodes
 * that are NOT terminal (`done`), NOT already in progress (`stateType` in
 * `IN_PROGRESS_STATE_TYPES`), AND NOT currently waiting/running (their key is not in
 * `excludeKeys`). PURE + unit-tested. `excludeKeys` is the run's actionable-list keys
 * PLUS its active assignment keys, so the count never double-counts what the header
 * already shows as "N waiting" / "M running". The full board (incl. done/canceled AND
 * in-progress) is still rendered in the canvas; this is only the badge number.
 *
 * Excluding in-progress fixes the "2 backlog but only 1 schedulable" report: an issue
 * someone is actively working on (In Progress) is non-terminal and not in the actionable
 * Todo list, so it WOULD have been counted as backlog even though the queue can never
 * dispatch it (the `list` provider only yields Todo). The DAG still shows it (blue node).
 */
export function backlogCount(
  nodes: ReadonlyArray<GraphNode>,
  excludeKeys: ReadonlySet<string>,
): number {
  let n = 0;
  for (const node of nodes) {
    if (node.done) continue;
    if (excludeKeys.has(node.key)) continue;
    if (node.stateType && IN_PROGRESS_STATE_TYPES.has(node.stateType.toLowerCase())) continue;
    n += 1;
  }
  return n;
}

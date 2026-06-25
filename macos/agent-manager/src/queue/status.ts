// (ramon fork / Agent Queue Supervisor, §11 health) The run-level HEALTH report the
// supervisor PUSHES to the GUI each sweep via the `report_queue_status` MCP tool, so the
// Agent Dashboard can show — even BEFORE any split spawns — that a queue is present and
// what it's about to do (count + what's next). PURE: `queueStatusReport` derives the report
// from primitives; runner.ts owns the I/O (caching the last list + the MCP call).

import type { GraphNode, WorkItem } from "./types.js";

/** One item reference for the dashboard header dropdowns (key + optional title + the
 *  Linear/tracker URL, so a "0 waiting"/"N running" click can link out). */
export interface QueueItemRef {
  key: string;
  title?: string;
  url?: string;
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

  // Map a WorkItem/ref → QueueItemRef, including title/url only when non-empty.
  const toRef = (i: { key: string; title?: string; url?: string }): QueueItemRef => {
    const ref: QueueItemRef = { key: i.key };
    if (i.title !== undefined && i.title.length > 0) ref.title = i.title;
    if (i.url !== undefined && i.url.length > 0) ref.url = i.url;
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
    next: deduped.slice(0, nextLimit).map(toRef),
    running: input.runningItems.map(toRef),
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
 * Count the "backlog" — the groomable remainder shown on the header button: graph nodes
 * that are NOT terminal (`done`) AND NOT currently waiting/running (their key is not in
 * `excludeKeys`). PURE + unit-tested. `excludeKeys` is the run's actionable-list keys
 * PLUS its active assignment keys, so the count never double-counts what the header
 * already shows as "N waiting" / "M running". The full board (incl. done/canceled) is
 * still rendered in the canvas; this is only the badge number.
 */
export function backlogCount(
  nodes: ReadonlyArray<GraphNode>,
  excludeKeys: ReadonlySet<string>,
): number {
  let n = 0;
  for (const node of nodes) {
    if (node.done) continue;
    if (excludeKeys.has(node.key)) continue;
    n += 1;
  }
  return n;
}

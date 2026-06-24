// (ramon fork / Agent Queue Supervisor, §11 health) The run-level HEALTH report the
// supervisor PUSHES to the GUI each sweep via the `report_queue_status` MCP tool, so the
// Agent Dashboard can show — even BEFORE any split spawns — that a queue is present and
// what it's about to do (count + what's next). PURE: `queueStatusReport` derives the report
// from primitives; runner.ts owns the I/O (caching the last list + the MCP call).

import type { WorkItem } from "./types.js";

/** One "what's next" entry for the dashboard header (key + optional title). */
export interface QueueNextItem {
  key: string;
  title?: string;
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
  /** Up to `nextLimit` of the next actionable items (not currently active). */
  next: QueueNextItem[];
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
  /** How many agents are currently RUNNING (slot-occupying assignments). */
  activeCount: number;
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
      next: [],
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

  return {
    queueName: input.queueName,
    present: true,
    phase,
    queued: deduped.length,
    listOk: input.listOk,
    active: input.activeCount,
    dispatched: input.dispatched,
    maxItems: input.maxItemsCap,
    next: deduped.slice(0, nextLimit).map((i) =>
      i.title !== undefined && i.title.length > 0
        ? { key: i.key, title: i.title }
        : { key: i.key },
    ),
  };
}

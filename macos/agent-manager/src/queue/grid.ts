// (ramon fork / Agent Queue Supervisor) Grid accounting (§12) — PURE + deterministic.
//
// A queue run keeps all its splits in ONE tab. The engine tracks a `gridSlot` per
// assignment PURELY for OCCUPANCY ACCOUNTING (cap the live panes at cols*rows; refill
// the lowest free slot when one closes). It does NOT compute geometry: the actual tiling
// is a BALANCED binary-space-partition done GUI-side (`spawn_split_command` with
// `balanced:true` splits the LARGEST pane in the tab along its longer side). That is
// correct across closures because Ghostty's binary tree RE-FLOWS when a pane closes (the
// sibling absorbs the parent region) — an abstract grid-neighbor split would land in the
// wrong place and produce stray columns/rows, so we let the GUI place each split from the
// real tree instead.
//
// All functions are pure (no I/O, no clock) and unit-tested. NOTHING here is content-aware.

/** The grid capacity = cols*rows (the max simultaneous panes a run may hold). PURE. */
export function gridCap(cols: number, rows: number): number {
  return cols * rows;
}

/**
 * The lowest free slot index in [0, cap), or null when the grid is full. PURE.
 * "Lowest free" reuses a closed split's slot before opening a higher one. The index is
 * an OCCUPANCY TOKEN only (caps concurrency); it carries no geometric meaning under the
 * balanced-BSP tiling.
 */
export function lowestFreeSlot(occupied: Set<number>, cap: number): number | null {
  for (let i = 0; i < cap; i++) {
    if (!occupied.has(i)) return i;
  }
  return null;
}

/**
 * How to materialize a new pane in the run's tab (§12):
 *   - `{firstTab:true}` — the run has no live panes yet; open its tab (the first leaf).
 *   - `{balanced:true, anchorSlotIndex}` — split WITHIN the tab that holds the pane at
 *     `anchorSlotIndex`. The GUI picks the largest pane + direction (balanced BSP); the
 *     anchor only identifies which tab. `anchorSlotIndex` is the lowest occupied slot (any
 *     live pane of the run would do — they share one tab).
 */
export type SplitPlan =
  | { firstTab: true }
  | { firstTab?: false; balanced: true; anchorSlotIndex: number };

/**
 * Plan how to materialize the next pane from the currently-occupied slots. PURE.
 * Empty ⇒ open the run's first tab; otherwise a balanced split anchored at the lowest
 * occupied slot (the GUI chooses the actual pane + direction from the real split tree).
 */
export function splitPlan(occupiedSlots: Set<number>): SplitPlan {
  if (occupiedSlots.size === 0) return { firstTab: true };
  return { balanced: true, anchorSlotIndex: lowestOccupied(occupiedSlots) };
}

/** The lowest occupied slot index (callers guarantee the set is non-empty). PURE. */
function lowestOccupied(occupied: Set<number>): number {
  let min = Number.POSITIVE_INFINITY;
  for (const i of occupied) if (i < min) min = i;
  return min;
}

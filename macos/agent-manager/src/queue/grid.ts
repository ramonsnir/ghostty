// (ramon fork / Agent Queue Supervisor) Grid layout (§12) — PURE + deterministic.
//
// A queue run keeps all its splits in ONE tab, auto-arranged into a grid of up to
// cols×rows, filled per `fill`. Ghostty's split tree is strictly BINARY (no true
// grid geometry), so the supervisor tracks a `gridSlot` per assignment and computes
// each spawn's split TARGET + DIRECTION from the slot index. Holes (from a closed
// split) are left empty and the next dispatch fills the LOWEST free slot — the
// surviving panes never re-flow.
//
// All functions are pure (no I/O, no clock) so the layout planner is fully
// unit-testable. NOTHING here is queue-content aware.

import type { GridFill } from "./types.js";

/** A grid cell coordinate. */
export interface Slot {
  col: number;
  row: number;
}

/**
 * Map a slot INDEX to its (col,row) for a given fill (§12). PURE.
 *   - fill "columns" (row-major): fill a row of columns before the next row, so
 *       row = floor(i/cols), col = i % cols.
 *   - fill "rows" (column-major): fill a column of rows before the next column, so
 *       col = floor(i/rows), row = i % rows.
 */
export function slotForIndex(
  i: number,
  cols: number,
  rows: number,
  fill: GridFill,
): Slot {
  if (fill === "columns") {
    return { row: Math.floor(i / cols), col: i % cols };
  }
  return { col: Math.floor(i / rows), row: i % rows };
}

/**
 * The inverse of `slotForIndex`: map a (col,row) back to its slot index for a given
 * fill. PURE. (Used by the split planner to find the index of a neighbor slot.)
 */
export function indexForSlot(
  slot: Slot,
  cols: number,
  rows: number,
  fill: GridFill,
): number {
  if (fill === "columns") {
    return slot.row * cols + slot.col;
  }
  return slot.col * rows + slot.row;
}

/** The grid capacity = cols*rows. PURE. */
export function gridCap(cols: number, rows: number): number {
  return cols * rows;
}

/**
 * The lowest free slot index in [0, cap), or null when the grid is full. PURE.
 * "Lowest free" honors the hole policy (§12): a closed split's slot is reused
 * before opening a higher one, with no re-flow.
 */
export function lowestFreeSlot(occupied: Set<number>, cap: number): number | null {
  for (let i = 0; i < cap; i++) {
    if (!occupied.has(i)) return i;
  }
  return null;
}

/**
 * The result of planning HOW to materialize a new slot in the binary split tree:
 *   - `{firstTab:true}` — the run has no splits yet; open its tab (the first leaf).
 *   - `{targetSlotIndex, direction}` — split the EXISTING surface at
 *     `targetSlotIndex` in `direction` to create the new leaf.
 */
export type SplitPlan =
  | { firstTab: true }
  | { firstTab?: false; targetSlotIndex: number; direction: "right" | "down" };

/**
 * Plan the binary split that materializes `newSlotIndex` (§12). PURE.
 *
 * Given the set of ALREADY-occupied slot indices (the live panes) and the grid
 * geometry, decide what to split and in which direction so the new leaf lands in
 * the right grid position:
 *   - no occupied slots             → open the run's first tab (`firstTab`).
 *   - new slot starts a NEW COLUMN  (its row is 0 / it has no neighbor above in its
 *     column) → split the slot ONE COLUMN TO THE LEFT in the same row RIGHT.
 *   - new slot is BELOW an existing one in its column → split the slot directly
 *     ABOVE it DOWN.
 *
 * The chosen target is required to be currently occupied (it's the pane we split);
 * for the no-hole fill orders the natural left/above neighbor is always present, so
 * this yields the clean grid the spec describes. If the strictly-preferred neighbor
 * is somehow absent (an unusual hole pattern), we fall back to the nearest occupied
 * neighbor (left-in-row, else above-in-column, else the lowest occupied slot) so the
 * planner is total and never returns a target that isn't a live pane.
 */
export function splitPlan(
  newSlotIndex: number,
  occupiedSlots: Set<number>,
  fill: GridFill,
  cols: number,
  rows: number,
): SplitPlan {
  if (occupiedSlots.size === 0) return { firstTab: true };

  const here = slotForIndex(newSlotIndex, cols, rows, fill);

  // A slot in row 0 cannot be "below" anything → it starts a new column: split the
  // pane immediately to its left (same row) RIGHT. Otherwise prefer splitting the
  // pane directly above it DOWN.
  if (here.row === 0) {
    const left = idxIfOccupied(
      { col: here.col - 1, row: 0 },
      occupiedSlots,
      cols,
      rows,
      fill,
    );
    if (left !== null) return { targetSlotIndex: left, direction: "right" };
    // Fallback: nothing to the left (hole) — split the lowest occupied pane right.
    return { targetSlotIndex: lowestOccupied(occupiedSlots), direction: "right" };
  }

  const above = idxIfOccupied(
    { col: here.col, row: here.row - 1 },
    occupiedSlots,
    cols,
    rows,
    fill,
  );
  if (above !== null) return { targetSlotIndex: above, direction: "down" };

  // The pane directly above is a hole. Prefer a left neighbor (split right), else
  // fall back to the lowest occupied pane split down.
  const left = idxIfOccupied(
    { col: here.col - 1, row: here.row },
    occupiedSlots,
    cols,
    rows,
    fill,
  );
  if (left !== null) return { targetSlotIndex: left, direction: "right" };
  return { targetSlotIndex: lowestOccupied(occupiedSlots), direction: "down" };
}

// ---------------------------------------------------------------------------
// Pure helpers.
// ---------------------------------------------------------------------------

/** The slot index for a (col,row) if it is in-bounds AND currently occupied, else
 *  null. PURE. */
function idxIfOccupied(
  slot: Slot,
  occupied: Set<number>,
  cols: number,
  rows: number,
  fill: GridFill,
): number | null {
  if (slot.col < 0 || slot.row < 0 || slot.col >= cols || slot.row >= rows) {
    return null;
  }
  const idx = indexForSlot(slot, cols, rows, fill);
  return occupied.has(idx) ? idx : null;
}

/** The lowest occupied slot index (the set is guaranteed non-empty by callers). */
function lowestOccupied(occupied: Set<number>): number {
  let min = Number.POSITIVE_INFINITY;
  for (const i of occupied) if (i < min) min = i;
  return min;
}

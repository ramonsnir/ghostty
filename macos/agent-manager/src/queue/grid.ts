// (ramon fork / Agent Queue Supervisor) Grid accounting (§12) — PURE + deterministic.
//
// A queue run lays its splits out as a grid of up to `cols*rows` panes PER TAB, and
// OVERFLOWS to additional tabs (in the run's own window) when `concurrency` exceeds one
// tab's capacity — so concurrency 9 with a 3x2 grid fills tab 1 (6) then spills 3 into
// tab 2, and 18 fills three tabs. The engine tracks a `gridSlot` per assignment PURELY
// for OCCUPANCY ACCOUNTING: slots are integers in [0, concurrency); slot `i` lives in tab
// `floor(i / capPerTab)` at position `i % capPerTab`. "Lowest free slot" fills the lowest
// tab first, reusing a closed split's hole before opening a higher slot. The slot index
// carries NO geometry beyond which tab it belongs to — within a tab the actual tiling is a
// BALANCED binary-space-partition done GUI-side (`spawn_split_command` with `balanced:true`
// splits the LARGEST pane in that tab along its longer side), which stays evenly tiled and
// self-heals when a pane closes (Ghostty's binary tree re-flows on close).
//
// All functions are pure (no I/O, no clock) and unit-tested. NOTHING here is content-aware.

/** A safety ceiling on how many tabs one run may spread across (so a fat-fingered
 *  concurrency can't open hundreds of tabs). `effectiveConcurrency` clamps to
 *  `capPerTab * MAX_QUEUE_TABS`. PURE constant. */
export const MAX_QUEUE_TABS = 8;

/** The PER-TAB grid capacity = cols*rows (the max panes one tab may hold). PURE. */
export function gridCap(cols: number, rows: number): number {
  return cols * rows;
}

/**
 * The lowest free slot index in [0, cap), or null when full. PURE. Here `cap` is the
 * run's TOTAL pane budget (`effectiveConcurrency`), NOT one tab's capacity — "lowest free"
 * therefore fills the lowest tab before spilling to the next, and reuses a closed split's
 * slot before opening a higher one.
 */
export function lowestFreeSlot(occupied: Set<number>, cap: number): number | null {
  for (let i = 0; i < cap; i++) {
    if (!occupied.has(i)) return i;
  }
  return null;
}

/** Which tab a slot belongs to: `floor(slot / capPerTab)`. PURE. */
export function tabIndexForSlot(slot: number, capPerTab: number): number {
  return Math.floor(slot / Math.max(1, capPerTab));
}

/**
 * How to materialize a new pane for slot `newSlot` (§12):
 *   - `{firstTab:true}` — the run has no live panes yet; open its FIRST tab (the run's
 *     first leaf, in the frontmost window — there is no run window yet to anchor on).
 *   - `{newTab:true, windowAnchorSlotIndex}` — `newSlot` is the first pane of a tab that
 *     has no live panes yet (an OVERFLOW tab): open a NEW tab in the run's EXISTING window,
 *     identified by `windowAnchorSlotIndex` (any live pane of the run — they share a window).
 *   - `{balanced:true, anchorSlotIndex}` — the target tab already holds panes: split WITHIN
 *     it. `anchorSlotIndex` is the lowest occupied slot IN THE SAME TAB; the GUI splits the
 *     largest pane of that tab (the anchor only identifies the tab).
 */
export type SplitPlan =
  | { firstTab: true }
  | { firstTab?: false; newTab: true; windowAnchorSlotIndex: number }
  | { firstTab?: false; newTab?: false; balanced: true; anchorSlotIndex: number };

/**
 * Plan how to materialize the next pane (`newSlot`) given the currently-occupied slots and
 * the per-tab capacity. PURE. Empty ⇒ the run's first tab; otherwise: if the target tab
 * (the one `newSlot` lands in) has no live pane yet, open a new tab in the run's window;
 * else a balanced split anchored at the lowest occupied slot OF THAT TAB.
 */
export function splitPlan(
  occupiedSlots: Set<number>,
  newSlot: number,
  capPerTab: number,
): SplitPlan {
  if (occupiedSlots.size === 0) return { firstTab: true };
  const tab = tabIndexForSlot(newSlot, capPerTab);
  let lowestInTab = Number.POSITIVE_INFINITY;
  let lowestAny = Number.POSITIVE_INFINITY;
  for (const s of occupiedSlots) {
    if (s < lowestAny) lowestAny = s;
    if (tabIndexForSlot(s, capPerTab) === tab && s < lowestInTab) lowestInTab = s;
  }
  if (lowestInTab === Number.POSITIVE_INFINITY) {
    // The target tab is empty (a fresh overflow tab) → open a new tab in the run's window,
    // anchored on any existing pane so every tab of the run lives in ONE window.
    return { newTab: true, windowAnchorSlotIndex: lowestAny };
  }
  return { balanced: true, anchorSlotIndex: lowestInTab };
}

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

/**
 * One CONTINUOUS-PACKING merge: a fragmented run (e.g. tabs holding 3 + 1 + 1 panes) wastes
 * tabs when those panes could sit together. `packMove` finds ONE whole tab whose panes ALL
 * fit into the free space of an EARLIER (lower-index) tab, and returns the move that merges
 * it in — the highest such source tab into the LEFTMOST earlier tab with room. Applying it
 * each sweep converges the layout to the fewest tabs WITHOUT reshuffling balanced cases:
 * `4 + 4` or `5 + 2` (cap 6) don't move because the higher tab's panes don't fit the lower
 * tab's free space, while `3 + 1 + 1` packs to a single tab over two sweeps. PURE; returns
 * null when nothing can be merged (already minimal, or only one tab).
 *
 *   - `sourceSlots`  : the occupied slots of the source tab (ascending) — the panes to move.
 *   - `targetSlots`  : the destination slots in the target tab's range (ascending, one per
 *                      source pane) — the moved panes' NEW grid slots (tab membership).
 *   - `targetTab`    : the target tab index (the caller resolves an anchor pane in it).
 */
export interface PackMove {
  sourceSlots: number[];
  targetSlots: number[];
  targetTab: number;
}

export function packMove(occupiedSlots: Set<number>, capPerTab: number): PackMove | null {
  if (capPerTab < 1 || occupiedSlots.size === 0) return null;
  // Group occupied slots by tab index.
  const byTab = new Map<number, number[]>();
  for (const s of occupiedSlots) {
    const t = tabIndexForSlot(s, capPerTab);
    const arr = byTab.get(t);
    if (arr) arr.push(s);
    else byTab.set(t, [s]);
  }
  const tabs = [...byTab.keys()].sort((a, b) => a - b);
  if (tabs.length < 2) return null; // one tab (or none) — nothing to merge.

  // Source = highest non-empty tab down; target = the LEFTMOST earlier tab with room for the
  // WHOLE source tab. Merging a whole tab only when it FITS is what avoids reshuffling a
  // balanced layout (4+4 / 5+2 don't fit), while packing fragmentation (3+1+1).
  for (let i = tabs.length - 1; i >= 1; i--) {
    const src = tabs[i];
    const sourceSlots = byTab.get(src)!.slice().sort((a, b) => a - b);
    const need = sourceSlots.length;
    for (let j = 0; j < i; j++) {
      const tgt = tabs[j];
      const free = capPerTab - byTab.get(tgt)!.length;
      if (free < need) continue;
      // The lowest `need` FREE slots in the target tab's range.
      const base = tgt * capPerTab;
      const targetSlots: number[] = [];
      for (let k = 0; k < capPerTab && targetSlots.length < need; k++) {
        const slot = base + k;
        if (!occupiedSlots.has(slot)) targetSlots.push(slot);
      }
      return { sourceSlots, targetSlots, targetTab: tgt };
    }
  }
  return null;
}

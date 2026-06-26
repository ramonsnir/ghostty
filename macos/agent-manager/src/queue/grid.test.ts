// Unit tests for the queue grid ACCOUNTING (§12). Run via `npm test`. Pure functions
// only — fully deterministic. (Geometry is a balanced BSP done GUI-side; the engine only
// caps occupancy + refills holes, so there is no slot→geometry mapping to test here.)

import test from "node:test";
import assert from "node:assert/strict";

import { gridCap, lowestFreeSlot, splitPlan, tabIndexForSlot, packMove } from "./grid.js";

// ---------------------------------------------------------------------------
// gridCap / lowestFreeSlot — occupancy accounting (caps concurrency, refills holes).
// ---------------------------------------------------------------------------

test("gridCap", () => {
  assert.equal(gridCap(3, 3), 9);
  assert.equal(gridCap(3, 2), 6);
  assert.equal(gridCap(1, 1), 1);
});

// (§12 grid cap) The per-tab pane cap gridCap = cols*rows is consistent with the BSP grid
// caps that are now forwarded to the GUI (maxCols=cols, maxRows=rows): a tab capped at
// cols columns × rows rows holds exactly cols*rows panes. The BSP direction logic itself is
// Swift-side (largestLeafSplit); this just pins the shared invariant.
test("gridCap == cols*rows (consistent with the forwarded BSP grid caps)", () => {
  for (const [cols, rows] of [
    [3, 2],
    [2, 1],
    [1, 1],
    [4, 4],
  ]) {
    assert.equal(gridCap(cols, rows), cols * rows);
  }
});

test("lowestFreeSlot: empty grid => 0", () => {
  assert.equal(lowestFreeSlot(new Set(), 9), 0);
});

test("lowestFreeSlot: with a hole picks the hole, not the next free", () => {
  // 0,1,2,4 occupied → slot 3 is the hole and is reused before 5.
  assert.equal(lowestFreeSlot(new Set([0, 1, 2, 4]), 9), 3);
});

test("lowestFreeSlot: contiguous fill picks the next index", () => {
  assert.equal(lowestFreeSlot(new Set([0, 1, 2]), 9), 3);
});

test("lowestFreeSlot: full grid => null", () => {
  assert.equal(lowestFreeSlot(new Set([0, 1, 2, 3]), 4), null);
});

// ---------------------------------------------------------------------------
// tabIndexForSlot — which tab a slot lands in (floor(slot / capPerTab)).
// ---------------------------------------------------------------------------

test("tabIndexForSlot: slots partition into tabs of capPerTab", () => {
  // capPerTab 6 (e.g. 3x2): slots 0-5 → tab 0, 6-11 → tab 1, 12-17 → tab 2.
  assert.equal(tabIndexForSlot(0, 6), 0);
  assert.equal(tabIndexForSlot(5, 6), 0);
  assert.equal(tabIndexForSlot(6, 6), 1);
  assert.equal(tabIndexForSlot(11, 6), 1);
  assert.equal(tabIndexForSlot(12, 6), 2);
});

// ---------------------------------------------------------------------------
// splitPlan — firstTab when empty; an OVERFLOW tab when the target tab is empty;
// otherwise a balanced split anchored at the lowest occupied slot OF THE SAME TAB.
// ---------------------------------------------------------------------------

test("splitPlan: no occupied slots => open the first tab", () => {
  assert.deepEqual(splitPlan(new Set(), 0, 6), { firstTab: true });
});

test("splitPlan: a slot within an already-populated tab => balanced split anchored in THAT tab", () => {
  // capPerTab 6; tab 0 has panes; the new slot 1 is also tab 0 → balanced anchored at the
  // lowest occupied slot of tab 0.
  assert.deepEqual(splitPlan(new Set([0]), 1, 6), { balanced: true, anchorSlotIndex: 0 });
  assert.deepEqual(splitPlan(new Set([0, 1, 2]), 3, 6), { balanced: true, anchorSlotIndex: 0 });
});

test("splitPlan: anchor is the lowest occupied slot OF THE SAME TAB (a low hole is skipped)", () => {
  // Slot 0 is a hole; lowest live pane in tab 0 is slot 1 → anchor 1.
  assert.deepEqual(splitPlan(new Set([1, 2, 4]), 0, 6), { balanced: true, anchorSlotIndex: 1 });
});

test("splitPlan: the first slot of a fresh OVERFLOW tab => newTab anchored on the run's window", () => {
  // capPerTab 6; tab 0 full (0-5); slot 6 is the first of tab 1 (empty) → open a new tab,
  // window-anchored on any live pane (the lowest occupied = 0).
  assert.deepEqual(splitPlan(new Set([0, 1, 2, 3, 4, 5]), 6, 6), {
    newTab: true,
    windowAnchorSlotIndex: 0,
  });
});

test("splitPlan: a SUBSEQUENT slot of an overflow tab => balanced within that tab", () => {
  // tab 1 already has slot 6; slot 7 is also tab 1 → balanced anchored at 6 (not a new tab).
  assert.deepEqual(splitPlan(new Set([0, 1, 2, 3, 4, 5, 6]), 7, 6), {
    balanced: true,
    anchorSlotIndex: 6,
  });
});

// ---------------------------------------------------------------------------
// packMove — continuous packing: merge a whole tab into an earlier tab with room,
// without reshuffling balanced layouts. capPerTab 6 throughout.
// ---------------------------------------------------------------------------

test("packMove: nothing to merge for 0 or 1 tab", () => {
  assert.equal(packMove(new Set(), 6), null);
  assert.equal(packMove(new Set([0, 1, 2]), 6), null); // one tab
});

test("packMove: 3 + 1 + 1 merges the HIGHEST tab into the leftmost tab with room", () => {
  // tab0={0,1,2} (3), tab1={6} (1), tab2={12} (1). Highest src = tab2; leftmost target with
  // room = tab0 (free 3 ≥ 1). Move slot 12 → the lowest free slot of tab0's range = 3.
  assert.deepEqual(packMove(new Set([0, 1, 2, 6, 12]), 6), {
    sourceSlots: [12],
    targetSlots: [3],
    targetTab: 0,
  });
});

test("packMove: a whole multi-pane tab merges when it fits (and picks the lowest free slots)", () => {
  // tab0={0,1} (2, free 4), tab1={6,7,8} (3). src=tab1 fits tab0 → move 6,7,8 → 2,3,4.
  assert.deepEqual(packMove(new Set([0, 1, 6, 7, 8]), 6), {
    sourceSlots: [6, 7, 8],
    targetSlots: [2, 3, 4],
    targetTab: 0,
  });
});

test("packMove: does NOT reshuffle balanced layouts (4+4, 5+2) — the higher tab doesn't fit", () => {
  // 4+4: tab0 free 2 < 4. 5+2: tab0 free 1 < 2. Neither merges.
  assert.equal(packMove(new Set([0, 1, 2, 3, 6, 7, 8, 9]), 6), null);
  assert.equal(packMove(new Set([0, 1, 2, 3, 4, 6, 7]), 6), null);
});

test("packMove: skips a FULL earlier tab and merges into the next one with room (6+1+1)", () => {
  // tab0 full (0-5); tab1={6} (1); tab2={12} (1). src=tab2: tab0 free 0 (skip) → tab1 free 5 → move 12 → 7.
  assert.deepEqual(packMove(new Set([0, 1, 2, 3, 4, 5, 6, 12]), 6), {
    sourceSlots: [12],
    targetSlots: [7],
    targetTab: 1,
  });
});

test("packMove: a hole in the target tab is reused as the destination slot", () => {
  // tab0={0,2} (slot 1 is a hole), tab1={6}. src=tab1 → tab0 free includes 1 → move 6 → 1.
  assert.deepEqual(packMove(new Set([0, 2, 6]), 6), {
    sourceSlots: [6],
    targetSlots: [1],
    targetTab: 0,
  });
});

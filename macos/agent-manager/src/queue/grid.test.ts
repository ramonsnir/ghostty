// Unit tests for the queue grid layout planner. Run via `npm test`. Pure functions
// only — fully deterministic.

import test from "node:test";
import assert from "node:assert/strict";

import {
  gridCap,
  indexForSlot,
  lowestFreeSlot,
  slotForIndex,
  splitPlan,
  type SplitPlan,
} from "./grid.js";

// ---------------------------------------------------------------------------
// slotForIndex — both fills, incl. a 3x3.
// ---------------------------------------------------------------------------

test("slotForIndex: columns fill is row-major (3x3)", () => {
  const cols = 3,
    rows = 3;
  const expect: Array<[number, number]> = [
    // [row, col] for slots 0..8
    [0, 0],
    [0, 1],
    [0, 2],
    [1, 0],
    [1, 1],
    [1, 2],
    [2, 0],
    [2, 1],
    [2, 2],
  ];
  for (let i = 0; i < 9; i++) {
    const s = slotForIndex(i, cols, rows, "columns");
    assert.deepEqual([s.row, s.col], expect[i], `slot ${i}`);
  }
});

test("slotForIndex: rows fill is column-major (3x3)", () => {
  const cols = 3,
    rows = 3;
  const expect: Array<[number, number]> = [
    // [col, row] for slots 0..8
    [0, 0],
    [0, 1],
    [0, 2],
    [1, 0],
    [1, 1],
    [1, 2],
    [2, 0],
    [2, 1],
    [2, 2],
  ];
  for (let i = 0; i < 9; i++) {
    const s = slotForIndex(i, cols, rows, "rows");
    assert.deepEqual([s.col, s.row], expect[i], `slot ${i}`);
  }
});

test("slotForIndex: non-square columns (cols=2, rows=3)", () => {
  // row-major over 2 columns: 0->(0,0) 1->(0,1) 2->(1,0) 3->(1,1) 4->(2,0) 5->(2,1)
  assert.deepEqual(slotForIndex(0, 2, 3, "columns"), { row: 0, col: 0 });
  assert.deepEqual(slotForIndex(2, 2, 3, "columns"), { row: 1, col: 0 });
  assert.deepEqual(slotForIndex(5, 2, 3, "columns"), { row: 2, col: 1 });
});

test("indexForSlot is the inverse of slotForIndex (both fills)", () => {
  for (const fill of ["columns", "rows"] as const) {
    for (let i = 0; i < 9; i++) {
      const s = slotForIndex(i, 3, 3, fill);
      assert.equal(indexForSlot(s, 3, 3, fill), i, `${fill} slot ${i}`);
    }
  }
});

// ---------------------------------------------------------------------------
// gridCap / lowestFreeSlot.
// ---------------------------------------------------------------------------

test("gridCap", () => {
  assert.equal(gridCap(3, 3), 9);
  assert.equal(gridCap(2, 4), 8);
});

test("lowestFreeSlot: empty grid => 0", () => {
  assert.equal(lowestFreeSlot(new Set(), 9), 0);
});

test("lowestFreeSlot: with a hole picks the hole, not the next free", () => {
  // 0,1,2,4 occupied; slot 3 is a hole -> reused first.
  assert.equal(lowestFreeSlot(new Set([0, 1, 2, 4]), 9), 3);
});

test("lowestFreeSlot: contiguous fill picks the next index", () => {
  assert.equal(lowestFreeSlot(new Set([0, 1, 2]), 9), 3);
});

test("lowestFreeSlot: full grid => null", () => {
  assert.equal(lowestFreeSlot(new Set([0, 1, 2, 3]), 4), null);
});

// ---------------------------------------------------------------------------
// splitPlan — the exact target + direction for a 3x3 columns-first fill, 0..8.
// ---------------------------------------------------------------------------

test("splitPlan: 3x3 columns-first fill sequence (slots 0..8)", () => {
  const cols = 3,
    rows = 3,
    fill = "columns" as const;
  // Build up the occupied set slot by slot, planning each as it is added.
  const occupied = new Set<number>();
  const expected: SplitPlan[] = [
    { firstTab: true }, // 0: first tab
    { targetSlotIndex: 0, direction: "right" }, // 1: (0,1) new column -> split slot0 right
    { targetSlotIndex: 1, direction: "right" }, // 2: (0,2) new column -> split slot1 right
    { targetSlotIndex: 0, direction: "down" }, // 3: (1,0) below slot0 -> split slot0 down
    { targetSlotIndex: 1, direction: "down" }, // 4: (1,1) below slot1 -> split slot1 down
    { targetSlotIndex: 2, direction: "down" }, // 5: (1,2) below slot2 -> split slot2 down
    { targetSlotIndex: 3, direction: "down" }, // 6: (2,0) below slot3 -> split slot3 down
    { targetSlotIndex: 4, direction: "down" }, // 7: (2,1) below slot4 -> split slot4 down
    { targetSlotIndex: 5, direction: "down" }, // 8: (2,2) below slot5 -> split slot5 down
  ];
  for (let i = 0; i < 9; i++) {
    const plan = splitPlan(i, occupied, fill, cols, rows);
    assert.deepEqual(plan, expected[i], `slot ${i} plan`);
    occupied.add(i);
  }
});

test("splitPlan: 3x3 rows-first fill sequence (slots 0..8)", () => {
  // rows fill (column-major): col=floor(i/rows), row=i%rows. Fill a whole COLUMN of
  // rows top-to-bottom before starting the next column. Symmetric to the columns test
  // above so a mid-sequence rows-fill regression is caught the same way.
  const cols = 3,
    rows = 3,
    fill = "rows" as const;
  const occupied = new Set<number>();
  const expected: SplitPlan[] = [
    { firstTab: true }, // 0: (0,0) first tab
    { targetSlotIndex: 0, direction: "down" }, // 1: (0,1) below slot0 -> split slot0 down
    { targetSlotIndex: 1, direction: "down" }, // 2: (0,2) below slot1 -> split slot1 down
    { targetSlotIndex: 0, direction: "right" }, // 3: (1,0) new column -> split slot0 right
    { targetSlotIndex: 3, direction: "down" }, // 4: (1,1) below slot3 -> split slot3 down
    { targetSlotIndex: 4, direction: "down" }, // 5: (1,2) below slot4 -> split slot4 down
    { targetSlotIndex: 3, direction: "right" }, // 6: (2,0) new column -> split slot3 right
    { targetSlotIndex: 6, direction: "down" }, // 7: (2,1) below slot6 -> split slot6 down
    { targetSlotIndex: 7, direction: "down" }, // 8: (2,2) below slot7 -> split slot7 down
  ];
  for (let i = 0; i < 9; i++) {
    const plan = splitPlan(i, occupied, fill, cols, rows);
    assert.deepEqual(plan, expected[i], `slot ${i} plan`);
    occupied.add(i);
  }
});

test("splitPlan: first dispatch (empty grid) => firstTab", () => {
  assert.deepEqual(splitPlan(0, new Set(), "columns", 3, 3), { firstTab: true });
});

test("splitPlan: refilling a hole reuses the right neighbor relationship", () => {
  // 0..8 occupied, then slot 4 closes (a hole). Refilling slot 4 (1,1): the pane
  // directly above is slot 1 (0,1) which is still occupied -> split it down.
  const occupied = new Set([0, 1, 2, 3, 5, 6, 7, 8]); // 4 freed
  const plan = splitPlan(4, occupied, "columns", 3, 3);
  assert.deepEqual(plan, { targetSlotIndex: 1, direction: "down" });
});

test("splitPlan: rows-first fill, slot 1 is below slot 0 (split down)", () => {
  // rows fill (column-major): slot1 -> (col0,row1), below slot0 (col0,row0).
  const occupied = new Set([0]);
  const plan = splitPlan(1, occupied, "rows", 3, 3);
  assert.deepEqual(plan, { targetSlotIndex: 0, direction: "down" });
});

test("splitPlan: rows-first fill, a new column splits the column-start to the right", () => {
  // rows fill: slot3 -> (col1,row0). row==0 -> new column -> split the left
  // neighbor (col0,row0)=slot0 right.
  const occupied = new Set([0, 1, 2]); // first column filled
  const plan = splitPlan(3, occupied, "rows", 3, 3);
  assert.deepEqual(plan, { targetSlotIndex: 0, direction: "right" });
});

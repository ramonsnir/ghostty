// Unit tests for the queue grid ACCOUNTING (§12). Run via `npm test`. Pure functions
// only — fully deterministic. (Geometry is a balanced BSP done GUI-side; the engine only
// caps occupancy + refills holes, so there is no slot→geometry mapping to test here.)

import test from "node:test";
import assert from "node:assert/strict";

import { gridCap, lowestFreeSlot, splitPlan, tabIndexForSlot } from "./grid.js";

// ---------------------------------------------------------------------------
// gridCap / lowestFreeSlot — occupancy accounting (caps concurrency, refills holes).
// ---------------------------------------------------------------------------

test("gridCap", () => {
  assert.equal(gridCap(3, 3), 9);
  assert.equal(gridCap(3, 2), 6);
  assert.equal(gridCap(1, 1), 1);
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

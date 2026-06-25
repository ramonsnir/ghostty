// Unit tests for the queue grid ACCOUNTING (§12). Run via `npm test`. Pure functions
// only — fully deterministic. (Geometry is a balanced BSP done GUI-side; the engine only
// caps occupancy + refills holes, so there is no slot→geometry mapping to test here.)

import test from "node:test";
import assert from "node:assert/strict";

import { gridCap, lowestFreeSlot, splitPlan } from "./grid.js";

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
// splitPlan — firstTab when empty; otherwise a balanced split anchored at the
// lowest occupied slot (the GUI picks the actual pane + direction).
// ---------------------------------------------------------------------------

test("splitPlan: no occupied slots => open the first tab", () => {
  assert.deepEqual(splitPlan(new Set()), { firstTab: true });
});

test("splitPlan: with panes => balanced split anchored at the lowest occupied slot", () => {
  assert.deepEqual(splitPlan(new Set([0])), { balanced: true, anchorSlotIndex: 0 });
  assert.deepEqual(splitPlan(new Set([0, 1, 2])), { balanced: true, anchorSlotIndex: 0 });
});

test("splitPlan: anchor is the LOWEST occupied slot even with a low hole", () => {
  // Slot 0 is a hole (closed); the lowest LIVE pane is slot 1 → that's the anchor.
  assert.deepEqual(splitPlan(new Set([1, 2, 4])), { balanced: true, anchorSlotIndex: 1 });
});

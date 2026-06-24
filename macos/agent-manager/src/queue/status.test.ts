// Unit tests for the pure queue HEALTH report builder (§11). Run via `npm test`.

import test from "node:test";
import assert from "node:assert/strict";

import { queueStatusReport, type QueueStatusInputs } from "./status.js";
import type { WorkItem } from "./types.js";

function items(...keys: Array<string | [string, string]>): WorkItem[] {
  return keys.map((k) =>
    Array.isArray(k) ? { key: k[0], title: k[1] } : { key: k },
  );
}

/** A baseline "running, armed, list OK" input; override per test. */
function input(over: Partial<QueueStatusInputs> = {}): QueueStatusInputs {
  return {
    queueName: "Q",
    present: true,
    paused: false,
    draining: false,
    disabled: false,
    dispatchArmed: true,
    activeCount: 0,
    excludeKeys: new Set<string>(),
    listItems: [],
    listOk: true,
    dispatched: 0,
    maxItemsCap: null,
    ...over,
  };
}

test("present:false zeroes the live fields (the GUI clears the section)", () => {
  const r = queueStatusReport(input({ present: false, listItems: items("A", "B"), dispatched: 5 }));
  assert.equal(r.present, false);
  assert.equal(r.queued, 0);
  assert.deepEqual(r.next, []);
  assert.equal(r.dispatched, 5); // dispatched carries (display-only)
});

test("phase is 'starting' before the run is armed", () => {
  assert.equal(queueStatusReport(input({ dispatchArmed: false })).phase, "starting");
});

test("phase is 'starting' until the first SUCCESSFUL list (listOk false)", () => {
  assert.equal(queueStatusReport(input({ listOk: false })).phase, "starting");
});

test("phase precedence: disabled > draining > paused > running", () => {
  assert.equal(queueStatusReport(input({ disabled: true, draining: true, paused: true })).phase, "disabled");
  assert.equal(queueStatusReport(input({ draining: true, paused: true })).phase, "draining");
  assert.equal(queueStatusReport(input({ paused: true })).phase, "paused");
  assert.equal(queueStatusReport(input()).phase, "running");
});

test("backlog excludes active/latched keys + de-dupes; next is limited + carries titles", () => {
  const r = queueStatusReport(input({
    listItems: items("A", ["B", "Build it"], "C", "C", "D", "E", "F"), // C duplicated
    excludeKeys: new Set(["A"]),                                       // A active/latched
    activeCount: 1,
    dispatched: 1,
    nextLimit: 3,
  }));
  // A excluded; C de-duped → B,C,D,E,F = 5 waiting.
  assert.equal(r.queued, 5);
  assert.equal(r.active, 1);
  assert.deepEqual(r.next, [{ key: "B", title: "Build it" }, { key: "C" }, { key: "D" }]);
});

test("maxItemsCap passes through (null = unlimited)", () => {
  assert.equal(queueStatusReport(input({ maxItemsCap: 3 })).maxItems, 3);
  assert.equal(queueStatusReport(input({ maxItemsCap: null })).maxItems, null);
});

test("null listItems (arm sweep) → 0 queued, no next, starting", () => {
  const r = queueStatusReport(input({ listItems: null, listOk: false, dispatchArmed: false }));
  assert.equal(r.queued, 0);
  assert.deepEqual(r.next, []);
  assert.equal(r.phase, "starting");
});

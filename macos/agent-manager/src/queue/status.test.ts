// Unit tests for the pure queue HEALTH report builder (§11). Run via `npm test`.

import test from "node:test";
import assert from "node:assert/strict";

import { queueStatusReport, backlogCount, type QueueStatusInputs } from "./status.js";
import type { GraphNode, WorkItem } from "./types.js";

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
    runningItems: [],
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
    runningItems: [{ key: "A", title: "Active A", url: "https://x/A" }],
    dispatched: 1,
    nextLimit: 3,
  }));
  // A excluded; C de-duped → B,C,D,E,F = 5 waiting.
  assert.equal(r.queued, 5);
  assert.equal(r.active, 1);
  assert.deepEqual(r.next, [{ key: "B", title: "Build it" }, { key: "C" }, { key: "D" }]);
  // running echoes the runningItems (carrying url for the dropdown link).
  assert.deepEqual(r.running, [{ key: "A", title: "Active A", url: "https://x/A" }]);
});

test("next carries item url (for the waiting-dropdown Linear link)", () => {
  const r = queueStatusReport(input({
    listItems: [{ key: "EX-9", title: "Fix it", url: "https://linear.app/x/EX-9" }],
  }));
  assert.deepEqual(r.next, [{ key: "EX-9", title: "Fix it", url: "https://linear.app/x/EX-9" }]);
});

test("maxItemsCap passes through (null = unlimited)", () => {
  assert.equal(queueStatusReport(input({ maxItemsCap: 3 })).maxItems, 3);
  assert.equal(queueStatusReport(input({ maxItemsCap: null })).maxItems, null);
});

test("concurrency passes through (present + present:false), defaulting to 0 when omitted", () => {
  assert.equal(queueStatusReport(input({ concurrency: 9 })).concurrency, 9);
  assert.equal(queueStatusReport(input()).concurrency, 0); // omitted → 0
  assert.equal(queueStatusReport(input({ present: false, concurrency: 6 })).concurrency, 6);
});

test("null listItems (arm sweep) → 0 queued, no next, starting", () => {
  const r = queueStatusReport(input({ listItems: null, listOk: false, dispatchArmed: false }));
  assert.equal(r.queued, 0);
  assert.deepEqual(r.next, []);
  assert.equal(r.phase, "starting");
});

// ---------------------------------------------------------------------------
// backlogCount — the header-badge number (non-terminal, not waiting/running).
// ---------------------------------------------------------------------------

function node(over: Partial<GraphNode> & { key: string }): GraphNode {
  return { done: false, labels: [], blockedBy: [], ...over };
}

test("backlogCount: counts non-terminal nodes not in the exclude set", () => {
  const nodes = [node({ key: "A-1" }), node({ key: "A-2" }), node({ key: "A-3" })];
  assert.equal(backlogCount(nodes, new Set(["A-2"])), 2);
});

test("backlogCount: terminal (done) nodes never count", () => {
  const nodes = [node({ key: "A-1", done: true }), node({ key: "A-2" })];
  assert.equal(backlogCount(nodes, new Set()), 1);
});

test("backlogCount: excludes both waiting (list) and running (active) keys", () => {
  const nodes = [
    node({ key: "W" }), // waiting
    node({ key: "R" }), // running
    node({ key: "B" }), // backlog
    node({ key: "D", done: true }), // done
  ];
  assert.equal(backlogCount(nodes, new Set(["W", "R"])), 1);
});

test("backlogCount: empty board → 0", () => {
  assert.equal(backlogCount([], new Set(["X"])), 0);
});

test("backlogCount: in-progress (stateType 'started') nodes are NOT counted", () => {
  const nodes = [
    node({ key: "TODO", stateType: "unstarted" }), // groomable → counts
    node({ key: "WIP", stateType: "started" }), // in progress → NOT counted
    node({ key: "WIP2", stateType: "Started" }), // case-insensitive → NOT counted
    node({ key: "BACK", stateType: "backlog" }), // groomable → counts
    node({ key: "NOTYPE" }), // unknown/absent stateType → counts (safe default)
  ];
  assert.equal(backlogCount(nodes, new Set()), 3);
});

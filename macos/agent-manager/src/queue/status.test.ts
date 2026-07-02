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

/** A hero-marked work item (for block-reason tests). */
function hero(key: string): WorkItem {
  return { key, hero: true };
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

test("held = listed ∩ latched ∩ ¬active (the dispatch-latch escape set)", () => {
  // A latched + active (running) → NOT held. B latched + listed + not active → HELD.
  // C latched but NOT listed → NOT held (it left the set; the re-arm clears it). D listed but
  // not latched → just waiting. E latched + listed + not active → HELD.
  const r = queueStatusReport(input({
    listItems: items("A", ["B", "Fix B"], "D", "E"),
    excludeKeys: new Set(["A", "B", "C", "E"]),          // active ∪ latched
    activeKeys: new Set(["A"]),                           // only A is tracked/active
    latchedKeys: new Set(["A", "B", "C", "E"]),
    runningItems: [{ key: "A", title: "A" }],
  }));
  assert.equal(r.heldCount, 2);
  assert.deepEqual(r.held, [{ key: "B", title: "Fix B" }, { key: "E" }]);
  // D is the only non-excluded listed item → the sole waiting entry.
  assert.deepEqual(r.next, [{ key: "D" }]);
});

test("held de-dupes + caps at nextLimit; heldCount is the capped list length", () => {
  const r = queueStatusReport(input({
    listItems: items("B", "B", "E", "F", "G"),            // B duplicated
    activeKeys: new Set<string>(),
    latchedKeys: new Set(["B", "E", "F", "G"]),
    excludeKeys: new Set(["B", "E", "F", "G"]),
    nextLimit: 2,
  }));
  // B,E,F,G held (B de-duped) but the list is capped to 2.
  assert.equal(r.held.length, 2);
  assert.deepEqual(r.held, [{ key: "B" }, { key: "E" }]);
});

test("held is empty when nothing latched, and on a present:false report", () => {
  assert.deepEqual(queueStatusReport(input({ listItems: items("A", "B") })).held, []);
  assert.equal(queueStatusReport(input({ listItems: items("A", "B") })).heldCount, 0);
  const gone = queueStatusReport(input({ present: false, listItems: items("A"), latchedKeys: new Set(["A"]) }));
  assert.deepEqual(gone.held, []);
  assert.equal(gone.heldCount, 0);
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
// (hero) heroMax / heroActive + per-item blockReasons.
// ---------------------------------------------------------------------------

test("hero: heroMax/heroActive pass through (present + present:false), default 0 when omitted", () => {
  const r = queueStatusReport(input({ heroMax: 2, heroActive: 1 }));
  assert.equal(r.heroMax, 2);
  assert.equal(r.heroActive, 1);
  // Omitted → 0 (a legacy build that doesn't feed the hero inputs).
  const bare = queueStatusReport(input());
  assert.equal(bare.heroMax, 0);
  assert.equal(bare.heroActive, 0);
  // present:false still carries the globals (defaulting 0).
  const gone = queueStatusReport(input({ present: false, heroMax: 3, heroActive: 2 }));
  assert.equal(gone.heroMax, 3);
  assert.equal(gone.heroActive, 2);
});

test("hero: blockReasons is OMITTED on an unblocked waiting item (a free slot exists)", () => {
  const r = queueStatusReport(input({
    listItems: items("A", "B"),
    // Regular room everywhere; hero disabled but the items aren't heroes.
    regularConcurrencyRemaining: 5,
    regularGlobalRemaining: 5,
    regularMaxItemsRemaining: 5,
    heroMax: 0,
    heroActive: 0,
  }));
  assert.deepEqual(r.next, [{ key: "A" }, { key: "B" }]);
  assert.equal(r.next[0].blockReasons, undefined);
});

test("hero: a regular waiting item at concurrency 0 gets queueConcurrency only", () => {
  const r = queueStatusReport(input({
    listItems: items("A"),
    regularConcurrencyRemaining: 0, // full
    regularGlobalRemaining: 5,      // fleet has room
    regularMaxItemsRemaining: 5,    // budget has room
    heroMax: 2,
    heroActive: 0,
  }));
  assert.deepEqual(r.next[0].blockReasons, ["queueConcurrency"]);
});

test("hero: a regular waiting item blocked by ALL THREE regular gates lists them in canonical order", () => {
  const r = queueStatusReport(input({
    listItems: items("A"),
    regularConcurrencyRemaining: 0,
    regularGlobalRemaining: 0,
    regularMaxItemsRemaining: 0,
    heroMax: 2,
    heroActive: 0,
  }));
  // Canonical order: maxItems, queueConcurrency, globalConcurrency.
  assert.deepEqual(r.next[0].blockReasons, ["maxItems", "queueConcurrency", "globalConcurrency"]);
});

test("hero: an unlimited (Infinity) regular cap never blocks", () => {
  const r = queueStatusReport(input({
    listItems: items("A"),
    regularConcurrencyRemaining: 3,
    regularGlobalRemaining: Number.POSITIVE_INFINITY, // max-total unlimited
    regularMaxItemsRemaining: Number.POSITIVE_INFINITY, // maxItems unlimited
    heroMax: 2,
    heroActive: 0,
  }));
  assert.equal(r.next[0].blockReasons, undefined);
});

test("hero: a waiting HERO item over the fleet cap gets heroSlots ONLY (never a regular gate)", () => {
  const r = queueStatusReport(input({
    listItems: [hero("H-1")],
    // Regular gates are ALL full — but a hero doesn't compete for them.
    regularConcurrencyRemaining: 0,
    regularGlobalRemaining: 0,
    regularMaxItemsRemaining: 0,
    heroMax: 2,
    heroActive: 2, // heroRemaining = 0 → blocked on hero slots
  }));
  assert.deepEqual(r.next[0].blockReasons, ["heroSlots"]);
});

test("hero: a waiting HERO item with a free hero slot is NOT blocked", () => {
  const r = queueStatusReport(input({
    listItems: [hero("H-1")],
    regularConcurrencyRemaining: 0,
    regularGlobalRemaining: 0,
    regularMaxItemsRemaining: 0,
    heroMax: 2,
    heroActive: 1, // heroRemaining = 1 > 0 → free
  }));
  assert.equal(r.next[0].blockReasons, undefined);
});

test("hero: heroMax=0 (hero dispatch DISABLED) blocks a waiting hero on heroSlots", () => {
  const r = queueStatusReport(input({
    listItems: [hero("H-1")],
    regularConcurrencyRemaining: 5,
    regularGlobalRemaining: 5,
    regularMaxItemsRemaining: 5,
    heroMax: 0,
    heroActive: 0, // heroRemaining = 0 → disabled → blocked
  }));
  assert.deepEqual(r.next[0].blockReasons, ["heroSlots"]);
});

test("hero: a mixed backlog attributes each item by its own pool", () => {
  const r = queueStatusReport(input({
    listItems: [{ key: "R-1" }, hero("H-1"), { key: "R-2" }],
    regularConcurrencyRemaining: 0, // regulars blocked on queue concurrency
    regularGlobalRemaining: 5,
    regularMaxItemsRemaining: 5,
    heroMax: 1,
    heroActive: 0, // hero has room → NOT blocked
  }));
  const byKey = new Map(r.next.map((n) => [n.key, n.blockReasons]));
  assert.deepEqual(byKey.get("R-1"), ["queueConcurrency"]);
  assert.deepEqual(byKey.get("R-2"), ["queueConcurrency"]);
  assert.equal(byKey.get("H-1"), undefined); // hero slot free
});

test("hero: block-reason inputs OMITTED → no blockReasons anywhere (legacy build)", () => {
  const r = queueStatusReport(input({ listItems: items("A", "B") }));
  assert.equal(r.next[0].blockReasons, undefined);
  assert.equal(r.next[1].blockReasons, undefined);
});

test("hero: next/running/held refs are marked hero (heroKeys ∪ item.hero)", () => {
  const r = queueStatusReport(input({
    // B is a hero via its own heroField; D is regular. C is held + a hero via heroKeys (promoted).
    listItems: [hero("B"), { key: "C" }, { key: "D" }],
    runningItems: [{ key: "A", hero: true }, { key: "E" }],
    latchedKeys: new Set(["C"]),
    activeKeys: new Set(["A", "E"]),
    excludeKeys: new Set(["A", "E", "C"]),
    heroKeys: new Set(["C"]),
    nextLimit: 25,
  }));
  // waiting: B hero via own field; D regular. (C is held, excluded from next.)
  assert.equal(r.next.find((i) => i.key === "B")?.hero, true);
  assert.equal(r.next.find((i) => i.key === "D")?.hero, undefined);
  // running: A hero via the assignment bit (runningItems.hero); E regular.
  assert.equal(r.running.find((i) => i.key === "A")?.hero, true);
  assert.equal(r.running.find((i) => i.key === "E")?.hero, undefined);
  // held: C hero via heroKeys (a promoted item that fell back to held).
  assert.equal(r.held.find((i) => i.key === "C")?.hero, true);
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

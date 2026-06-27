// Unit tests for the durable assignment store + crash-safe ordering + restart
// RECONCILIATION (§9). Run via `npm test`. The persistence seam is an IN-MEMORY
// StoreIO (NOT real fs); reconcile + the record transforms are pure (injected nowMs).

import test from "node:test";
import assert from "node:assert/strict";

import type { Assignment } from "./types.js";
import {
  activeSetFromKept,
  finalizeRecord,
  isAssignmentState,
  loadLifetimeDispatched,
  loadDispatched,
  loadKeep,
  loadStore,
  makePendingRecord,
  parseDispatched,
  parseKeep,
  parseLifetimeDispatched,
  parseStore,
  persistStore,
  reconcile,
  serializeStore,
  parseActiveRuns,
  serializeActiveRuns,
  loadActiveRuns,
  persistActiveRuns,
  type ActiveRunRecord,
  type LiveSurface,
  type StoreIO,
} from "./store.js";

// ---------------------------------------------------------------------------
// An in-memory StoreIO so no real file is ever touched.
// ---------------------------------------------------------------------------

function memIO(initial: string | null = null): StoreIO & { text: string | null } {
  const box: { text: string | null } = { text: initial };
  return {
    text: box.text,
    read() {
      return box.text;
    },
    write(t: string) {
      box.text = t;
      // keep the public mirror in sync (tests read .text)
      (this as { text: string | null }).text = t;
    },
  };
}

function asgn(over: Partial<Assignment> = {}): Assignment {
  return {
    queueName: "q",
    key: "K-1",
    sessionID: 100,
    surfaceUUID: "uuid-1",
    gridSlot: 0,
    state: "RUNNING",
    sinceMs: 1000,
    ...over,
  };
}

function live(over: Partial<LiveSurface> = {}): LiveSurface {
  return { sessionID: 100, surfaceUUID: "uuid-1", queueKey: "K-1", queueName: "q", ...over };
}

// ---------------------------------------------------------------------------
// parse / serialize round-trips + tolerance.
// ---------------------------------------------------------------------------

test("serializeStore -> parseStore round-trips records", () => {
  const recs = [asgn(), asgn({ key: "K-2", sessionID: 101, surfaceUUID: "uuid-2", gridSlot: 1 })];
  const round = parseStore(serializeStore(recs));
  assert.deepEqual(round, recs);
});

test("serializeStore persists the lifetime counter; parseLifetimeDispatched round-trips it", () => {
  const text = serializeStore([asgn()], 7);
  assert.equal(parseLifetimeDispatched(text), 7);
  // records still parse independently of the counter.
  assert.equal(parseStore(text).length, 1);
});

test("parseLifetimeDispatched tolerates absent / garbage / negative => 0", () => {
  assert.equal(parseLifetimeDispatched(null), 0);
  assert.equal(parseLifetimeDispatched(""), 0);
  assert.equal(parseLifetimeDispatched("not json"), 0);
  assert.equal(parseLifetimeDispatched("[1,2,3]"), 0);
  assert.equal(parseLifetimeDispatched('{"records":[]}'), 0); // no counter field (pre-upgrade)
  assert.equal(parseLifetimeDispatched('{"lifetimeDispatched":"5"}'), 0); // non-numeric
  assert.equal(parseLifetimeDispatched('{"lifetimeDispatched":-3}'), 0); // negative
  assert.equal(parseLifetimeDispatched('{"lifetimeDispatched":4.9}'), 4); // floored
});

test("serializeStore floors a negative / non-finite counter to 0", () => {
  assert.equal(parseLifetimeDispatched(serializeStore([], -1)), 0);
  assert.equal(parseLifetimeDispatched(serializeStore([], Number.NaN)), 0);
  assert.equal(parseLifetimeDispatched(serializeStore([], 0)), 0);
});

test("persistStore writes + loadLifetimeDispatched reads back the counter", () => {
  const io = memIO();
  persistStore(io, [asgn()], 12);
  assert.equal(loadLifetimeDispatched(io), 12);
  assert.equal(loadStore(io).length, 1);
});

test("serializeStore persists the dispatched latch; parseDispatched round-trips it (deduped)", () => {
  const text = serializeStore([asgn()], 3, ["K-1", "K-2", "K-1"]);
  assert.deepEqual(parseDispatched(text).sort(), ["K-1", "K-2"]);
  // The records + counter still round-trip alongside the latch.
  assert.equal(parseStore(text).length, 1);
  assert.equal(parseLifetimeDispatched(text), 3);
});

test("parseDispatched tolerates absent / garbage / wrong-shape / non-string entries => []", () => {
  assert.deepEqual(parseDispatched(null), []);
  assert.deepEqual(parseDispatched(""), []);
  assert.deepEqual(parseDispatched("not json"), []);
  assert.deepEqual(parseDispatched("[1,2,3]"), []); // top-level array, not an object
  assert.deepEqual(parseDispatched('{"records":[]}'), []); // no dispatched field (pre-upgrade)
  assert.deepEqual(parseDispatched('{"dispatched":"K-1"}'), []); // not an array
  assert.deepEqual(parseDispatched('{"dispatched":["K-1",2,"",null,"K-1"]}'), ["K-1"]); // strings only, deduped
});

test("persistStore writes + loadDispatched reads back the latch", () => {
  const io = memIO();
  persistStore(io, [asgn()], 5, ["K-7", "K-9"]);
  assert.deepEqual(loadDispatched(io).sort(), ["K-7", "K-9"]);
  // The latch is independent of the records + counter on the same file.
  assert.equal(loadLifetimeDispatched(io), 5);
  assert.equal(loadStore(io).length, 1);
});

// ---------------------------------------------------------------------------
// (keep) per-split keep overrides — serialize/parse/persist round-trips.
// ---------------------------------------------------------------------------

test("serializeStore persists the keep overrides; parseKeep round-trips them", () => {
  const text = serializeStore([asgn()], 3, ["K-1"], { "K-1": true, "K-2": false });
  assert.deepEqual(parseKeep(text), { "K-1": true, "K-2": false });
  // keep is independent of records / counter / latch on the same file.
  assert.equal(parseStore(text).length, 1);
  assert.deepEqual(parseDispatched(text), ["K-1"]);
});

test("serializeStore omits the keep field entirely when there are no overrides (back-compat)", () => {
  const text = serializeStore([asgn()], 0, []);
  assert.ok(!Object.prototype.hasOwnProperty.call(JSON.parse(text), "keep"));
  assert.deepEqual(parseKeep(text), {});
});

test("parseKeep tolerates absent / garbage / wrong-shape / non-boolean entries => {}", () => {
  assert.deepEqual(parseKeep(null), {});
  assert.deepEqual(parseKeep(""), {});
  assert.deepEqual(parseKeep("not json"), {});
  assert.deepEqual(parseKeep("[1,2,3]"), {}); // top-level array
  assert.deepEqual(parseKeep('{"records":[]}'), {}); // no keep field (pre-upgrade)
  assert.deepEqual(parseKeep('{"keep":["K-1"]}'), {}); // not an object
  assert.deepEqual(parseKeep('{"keep":{"K-1":true,"K-2":"yes","":true,"K-3":false}}'), {
    "K-1": true,
    "K-3": false,
  }); // booleans + non-empty keys only
});

test("persistStore writes + loadKeep reads back the keep overrides", () => {
  const io = memIO();
  persistStore(io, [asgn()], 1, [], { "K-7": true });
  assert.deepEqual(loadKeep(io), { "K-7": true });
});

test("loadKeep returns {} when the seam read throws", () => {
  const io: StoreIO = {
    read() {
      throw new Error("boom");
    },
    write() {},
  };
  assert.deepEqual(loadKeep(io), {});
});

test("loadDispatched returns [] when the seam read throws", () => {
  const io: StoreIO = {
    read() {
      throw new Error("boom");
    },
    write() {
      /* noop */
    },
  };
  assert.deepEqual(loadDispatched(io), []);
});

test("loadLifetimeDispatched returns 0 when the seam read throws", () => {
  const io: StoreIO = {
    read() {
      throw new Error("boom");
    },
    write() {
      /* noop */
    },
  };
  assert.equal(loadLifetimeDispatched(io), 0);
});

test("parseStore tolerates null / empty / garbage / wrong-shape => []", () => {
  assert.deepEqual(parseStore(null), []);
  assert.deepEqual(parseStore(""), []);
  assert.deepEqual(parseStore("   "), []);
  assert.deepEqual(parseStore("not json"), []);
  assert.deepEqual(parseStore("[1,2,3]"), []); // array, not the object shape
  assert.deepEqual(parseStore('{"version":1}'), []); // no records array
  assert.deepEqual(parseStore('{"records":"nope"}'), []);
});

test("parseStore drops individual records missing required identity fields", () => {
  const text = JSON.stringify({
    version: 1,
    records: [
      { queueName: "q", key: "K-1", state: "RUNNING", sessionID: 5, gridSlot: 0, sinceMs: 1 },
      { key: "K-2", state: "RUNNING" }, // no queueName -> dropped
      { queueName: "q", state: "RUNNING" }, // no key -> dropped
      { queueName: "q", key: "K-3", state: "BOGUS" }, // bad state -> dropped
    ],
  });
  const recs = parseStore(text);
  assert.equal(recs.length, 1);
  assert.equal(recs[0].key, "K-1");
});

test("isAssignmentState guards the union", () => {
  assert.ok(isAssignmentState("RUNNING"));
  assert.ok(isAssignmentState("COOLDOWN"));
  assert.ok(!isAssignmentState("running"));
  assert.ok(!isAssignmentState("nope"));
});

// ---------------------------------------------------------------------------
// loadStore / persistStore over the in-memory seam (never throw).
// ---------------------------------------------------------------------------

test("loadStore returns [] on an empty seam, then round-trips after persist", () => {
  const io = memIO();
  assert.deepEqual(loadStore(io), []);
  const recs = [asgn()];
  assert.ok(persistStore(io, recs));
  assert.deepEqual(loadStore(io), recs);
});

test("loadStore returns [] when the seam read throws (never crashes)", () => {
  const io: StoreIO = {
    read() {
      throw new Error("boom");
    },
    write() {},
  };
  assert.deepEqual(loadStore(io), []);
});

test("persistStore returns false when the seam write throws (logged + continue)", () => {
  const io: StoreIO = {
    read: () => null,
    write() {
      throw new Error("disk full");
    },
  };
  assert.equal(persistStore(io, [asgn()]), false);
});

// ---------------------------------------------------------------------------
// Crash-safe dispatch ordering: pending -> finalize (§9).
// ---------------------------------------------------------------------------

test("makePendingRecord is a QUEUED, sessionID-0, UUID-less marker", () => {
  const p = makePendingRecord("q", "K-9", 3, 5000, { title: "T", url: "U" });
  assert.equal(p.state, "QUEUED");
  assert.equal(p.sessionID, 0);
  assert.equal(p.surfaceUUID, undefined);
  assert.equal(p.gridSlot, 3);
  assert.equal(p.sinceMs, 5000);
  assert.equal(p.title, "T");
  assert.equal(p.url, "U");
});

test("finalizeRecord stamps sessionID + UUID and advances to SPAWNED (immutably)", () => {
  const p = makePendingRecord("q", "K-9", 3, 5000);
  const f = finalizeRecord(p, 555, "uuid-x", 6000);
  assert.equal(f.state, "SPAWNED");
  assert.equal(f.sessionID, 555);
  assert.equal(f.surfaceUUID, "uuid-x");
  assert.equal(f.sinceMs, 6000);
  // input unchanged
  assert.equal(p.state, "QUEUED");
  assert.equal(p.sessionID, 0);
});

// ---------------------------------------------------------------------------
// reconcile (§9): active / prune / adopt.
// ---------------------------------------------------------------------------

test("reconcile: record + live surface (sessionID match) => active, UUID refreshed", () => {
  const rec = asgn({ sessionID: 200, surfaceUUID: "stale-uuid" });
  const plan = reconcile([rec], [live({ sessionID: 200, surfaceUUID: "fresh-uuid" })], 9999, 30000);
  assert.equal(plan.actions.length, 1);
  const a = plan.actions[0];
  assert.equal(a.kind, "active");
  if (a.kind === "active") {
    assert.equal(a.assignment.surfaceUUID, "fresh-uuid");
    assert.equal(a.needsAnnotationRestamp, false);
  }
  assert.equal(plan.kept.length, 1);
  assert.equal(plan.kept[0].surfaceUUID, "fresh-uuid");
});

test("reconcile: active but live surface LOST the queueKey annotation => needsAnnotationRestamp", () => {
  const rec = asgn({ sessionID: 200, key: "K-7" });
  // GUI restart dropped the in-memory annotation map: live surface has NO queueKey.
  const plan = reconcile([rec], [live({ sessionID: 200, queueKey: undefined, queueName: undefined })], 1, 30000);
  const a = plan.actions[0];
  assert.equal(a.kind, "active");
  if (a.kind === "active") assert.equal(a.needsAnnotationRestamp, true);
});

test("reconcile: finalized record whose session vanished (PAST grace) => prune (session-gone)", () => {
  // A genuinely-gone session: sinceMs is old (a long-lived RUNNING record keeps its
  // original sinceMs), so now - sinceMs is well past the grace window → prune.
  const rec = asgn({ sessionID: 300, sinceMs: 1000 });
  const plan = reconcile([rec], [], 1000 + 30001, 30000); // no live surfaces at all
  assert.equal(plan.actions.length, 1);
  const a = plan.actions[0];
  assert.equal(a.kind, "prune");
  if (a.kind === "prune") assert.equal(a.reason, "session-gone");
  assert.equal(plan.kept.length, 0);
});

test("reconcile: reconcileStartedMs SHIELDS a long-lived RUNNING record from a transient post-restart empty list (premature-prune fix)", () => {
  // The incident: a long-lived RUNNING record has an OLD sinceMs, so the sinceMs-only
  // grace gave it ZERO protection — a SUCCESSFUL-but-INCOMPLETE post-restart list_surfaces
  // pruned it instantly, abandoning a live agent. With reconcileStartedMs = now, the record
  // is shielded for graceMs after the (re)start even though its sinceMs is ancient.
  const rec = asgn({ sessionID: 300, sinceMs: 1000 });
  const now = 10_000_000; // sinceMs is ~10M ms in the past — way past a sinceMs-only grace
  const plan = reconcile([rec], [], now, 30000, now); // reconcileStartedMs = now
  assert.equal(plan.actions.length, 0, "shielded: no prune within the post-restart grace");
  assert.equal(plan.kept.length, 1, "the live agent's record is kept, not abandoned");
  assert.equal(plan.kept[0].key, rec.key);
});

test("reconcile: past the reconcileStartedMs grace, a genuinely-gone session IS pruned", () => {
  const rec = asgn({ sessionID: 300, sinceMs: 1000 });
  const started = 10_000_000;
  // now is graceMs+1 past BOTH sinceMs and reconcileStartedMs → no longer shielded → prune.
  const plan = reconcile([rec], [], started + 30001, 30000, started);
  assert.equal(plan.actions.length, 1);
  assert.equal(plan.actions[0].kind, "prune");
  if (plan.actions[0].kind === "prune") assert.equal(plan.actions[0].reason, "session-gone");
});

test("reconcile: with NO reconcileStartedMs (default -Infinity) behavior is the pre-fix sinceMs-only grace", () => {
  // Back-compat: the default param must reproduce the old behavior exactly — a long-lived
  // record with an old sinceMs is pruned immediately when missing (no shield).
  const rec = asgn({ sessionID: 300, sinceMs: 1000 });
  const plan = reconcile([rec], [], 1000 + 30001, 30000); // 4 args (no reconcileStartedMs)
  assert.equal(plan.actions.length, 1);
  assert.equal(plan.actions[0].kind, "prune");
});

test("reconcile: a FRESHLY-finalized record whose surface lags list_surfaces (within grace) is KEPT (no prune, no re-dispatch)", () => {
  // The §7 one-sweep-lag guard: dispatch finalizes the record with the spawn's
  // sessionID in one sweep; the surface is only expected in list_surfaces by the NEXT
  // sweep. A finalized record within the grace window since its (recent) sinceMs must
  // NOT be session-gone-pruned, or its key would free with no cooldown and be
  // re-dispatched as a duplicate.
  const rec = asgn({ sessionID: 300, state: "SPAWNED", sinceMs: 20000 });
  // now - sinceMs = 5000 < grace 30000 → keep, no action emitted.
  const plan = reconcile([rec], [], 25000, 30000);
  assert.equal(plan.actions.length, 0, "no prune within grace");
  assert.equal(plan.kept.length, 1, "the freshly-finalized record is kept");
  assert.equal(plan.kept[0].key, rec.key, "its key stays in the active set (blocks re-dispatch)");
});

test("reconcile: still-PENDING record within grace is KEPT (no action, not pruned)", () => {
  const pending = makePendingRecord("q", "K-5", 0, 1000); // sessionID 0
  // now=20000, since=1000 => age 19000 < grace 30000 -> keep silently
  const plan = reconcile([pending], [], 20000, 30000);
  assert.equal(plan.actions.length, 0);
  assert.equal(plan.kept.length, 1);
  assert.equal(plan.kept[0].state, "QUEUED");
});

test("reconcile: still-PENDING record PAST grace => prune (pending-expired)", () => {
  const pending = makePendingRecord("q", "K-5", 0, 1000);
  // now=40000, age 39000 > grace 30000 -> prune
  const plan = reconcile([pending], [], 40000, 30000);
  assert.equal(plan.actions.length, 1);
  const a = plan.actions[0];
  assert.equal(a.kind, "prune");
  if (a.kind === "prune") assert.equal(a.reason, "pending-expired");
  assert.equal(plan.kept.length, 0);
});

test("reconcile: orphan adoption — live queue surface with NO record => adopt (never re-dispatch)", () => {
  // A spawn finalized its surface but crashed before writing the record. The live
  // surface carries the queueKey annotation; no record matches its sessionID.
  const orphan = live({ sessionID: 400, surfaceUUID: "orphan-uuid", queueKey: "K-orphan", queueName: "q", title: "OT", url: "OU" });
  const plan = reconcile([], [orphan], 7777, 30000);
  assert.equal(plan.actions.length, 1);
  const a = plan.actions[0];
  assert.equal(a.kind, "adopt");
  if (a.kind === "adopt") {
    assert.equal(a.assignment.key, "K-orphan");
    assert.equal(a.assignment.sessionID, 400);
    assert.equal(a.assignment.surfaceUUID, "orphan-uuid");
    assert.equal(a.assignment.state, "RUNNING");
    assert.equal(a.assignment.title, "OT");
    assert.equal(a.assignment.url, "OU");
  }
  assert.equal(plan.kept.length, 1);
});

test("reconcile: a live surface WITHOUT a queueKey annotation is NOT adopted (non-queue agent)", () => {
  const nonQueue = live({ sessionID: 500, queueKey: undefined, queueName: undefined });
  const plan = reconcile([], [nonQueue], 1, 30000);
  assert.equal(plan.actions.length, 0);
  assert.equal(plan.kept.length, 0);
});

test("reconcile: sessionID 0 live surface is never matched nor adopted", () => {
  const noSession = live({ sessionID: 0, queueKey: "K-x", queueName: "q" });
  const plan = reconcile([], [noSession], 1, 30000);
  assert.equal(plan.actions.length, 0);
  assert.equal(plan.kept.length, 0);
});

test("reconcile: mixed — active + prune + adopt in one pass", () => {
  const recActive = asgn({ key: "K-A", sessionID: 1 });
  // recGone's session is genuinely gone AND past grace (old sinceMs) → it prunes.
  const recGone = asgn({ key: "K-B", sessionID: 2, sinceMs: 1000 });
  const liveActive = live({ sessionID: 1, surfaceUUID: "u-a", queueKey: "K-A" });
  const liveOrphan = live({ sessionID: 3, surfaceUUID: "u-c", queueKey: "K-C", queueName: "q" });
  const plan = reconcile([recActive, recGone], [liveActive, liveOrphan], 1000 + 30001, 30000);

  const kinds = plan.actions.map((x) => x.kind).sort();
  assert.deepEqual(kinds, ["active", "adopt", "prune"]);
  // kept = active + adopt (NOT the pruned gone one)
  const keptKeys = plan.kept.map((k) => k.key).sort();
  assert.deepEqual(keptKeys, ["K-A", "K-C"]);
});

// ---------------------------------------------------------------------------
// Cross-restart dedup wiring: activeSetFromKept feeds selectCandidates.
// ---------------------------------------------------------------------------

test("activeSetFromKept maps by work-item key (the dedup identity)", () => {
  const m = activeSetFromKept([asgn({ key: "K-A" }), asgn({ key: "K-B", sessionID: 2 })]);
  assert.ok(m.has("K-A"));
  assert.ok(m.has("K-B"));
  assert.equal(m.size, 2);
});

// ---------------------------------------------------------------------------
// Active-run persistence (§8a/§9): the started-run SET survives a restart.
// ---------------------------------------------------------------------------

test("serializeActiveRuns / parseActiveRuns: round-trips the started-run set", () => {
  const runs: ActiveRunRecord[] = [
    { template: "backlog-file", name: "backlog", paused: false, draining: false },
    { template: "hotfix-file", name: "hotfix", paused: true, draining: false },
  ];
  const text = serializeActiveRuns(runs);
  assert.deepEqual(parseActiveRuns(text), runs);
});

test("serializeActiveRuns / parseActiveRuns: round-trips start-time params (§8b)", () => {
  const runs: ActiveRunRecord[] = [
    { template: "example", name: "ExampleOS", paused: false, draining: false, params: { project: "Acme", milestones: "Q3" } },
  ];
  assert.deepEqual(parseActiveRuns(serializeActiveRuns(runs)), runs);
});

test("serializeActiveRuns / parseActiveRuns: round-trips a live maxItems edit (number AND null)", () => {
  const runs: ActiveRunRecord[] = [
    { template: "example", name: "ExampleOS", paused: false, draining: false, maxItemsLive: 10 },
    { template: "other", name: "Other", paused: false, draining: false, maxItemsLive: null },
  ];
  assert.deepEqual(parseActiveRuns(serializeActiveRuns(runs)), runs);
});

test("serializeActiveRuns / parseActiveRuns: round-trips a live concurrency edit", () => {
  const runs: ActiveRunRecord[] = [
    { template: "example", name: "ExampleOS", paused: false, draining: false, concurrencyLive: 9 },
  ];
  assert.deepEqual(parseActiveRuns(serializeActiveRuns(runs)), runs);
});

test("parseActiveRuns: tolerates a malformed concurrencyLive (non-positive / non-int / string / null dropped)", () => {
  for (const v of ["0", "-2", "2.5", '"9"', "true", "null"]) {
    const recs = parseActiveRuns(`{"version":1,"runs":[{"template":"t","name":"t","concurrencyLive":${v}}]}`);
    assert.equal(recs.length, 1, `v=${v} keeps the record`);
    assert.equal(recs[0].concurrencyLive, undefined, `v=${v} drops the bad concurrencyLive`);
  }
  assert.equal(
    parseActiveRuns('{"version":1,"runs":[{"template":"t","name":"t","concurrencyLive":9}]}')[0].concurrencyLive,
    9,
  );
});

test("parseActiveRuns: tolerates a malformed maxItemsLive (non-positive / non-int / string dropped)", () => {
  // A garbage maxItemsLive is DROPPED (record kept without it → falls back to the param/template cap).
  for (const v of ["0", "-2", "2.5", '"5"', "true"]) {
    const recs = parseActiveRuns(`{"version":1,"runs":[{"template":"t","name":"t","maxItemsLive":${v}}]}`);
    assert.equal(recs.length, 1, `v=${v} keeps the record`);
    assert.equal(recs[0].maxItemsLive, undefined, `v=${v} drops the bad maxItemsLive`);
  }
  // null is explicitly honored (unlimited); a positive int is honored.
  assert.equal(
    parseActiveRuns('{"version":1,"runs":[{"template":"t","name":"t","maxItemsLive":null}]}')[0].maxItemsLive,
    null,
  );
  assert.equal(
    parseActiveRuns('{"version":1,"runs":[{"template":"t","name":"t","maxItemsLive":7}]}')[0].maxItemsLive,
    7,
  );
});

test("parseActiveRuns: tolerates a malformed params field (non-object / non-string values dropped)", () => {
  // non-object params → record kept WITHOUT params
  assert.deepEqual(
    parseActiveRuns('{"version":1,"runs":[{"template":"t","name":"t","params":"nope"}]}'),
    [{ template: "t", name: "t", paused: false, draining: false }],
  );
  // mixed value types → only string values survive
  assert.deepEqual(
    parseActiveRuns('{"version":1,"runs":[{"template":"t","name":"t","params":{"a":"x","b":7}}]}'),
    [{ template: "t", name: "t", paused: false, draining: false, params: { a: "x" } }],
  );
});

test("parseActiveRuns: tolerant of malformed input → []", () => {
  assert.deepEqual(parseActiveRuns(null), []);
  assert.deepEqual(parseActiveRuns(""), []);
  assert.deepEqual(parseActiveRuns("not json"), []);
  assert.deepEqual(parseActiveRuns("[]"), [], "a bare array (no envelope) → []");
  assert.deepEqual(parseActiveRuns('{"runs":"x"}'), [], "non-array runs → []");
});

test("parseActiveRuns: an UNKNOWN numeric version → [] (don't misparse a future file as v1)", () => {
  // A future v2 file must NOT be parsed by field-shape as v1; it falls back to the safe
  // dormant-until-start default.
  assert.deepEqual(
    parseActiveRuns(JSON.stringify({ version: 2, runs: [{ template: "f", name: "r" }] })),
    [],
  );
  // An ABSENT / non-numeric version is tolerated and parsed by shape (legacy/hand-edited).
  assert.deepEqual(
    parseActiveRuns(JSON.stringify({ runs: [{ template: "f", name: "r" }] })),
    [{ template: "f", name: "r", paused: false, draining: false }],
    "absent version still parses by shape",
  );
  assert.deepEqual(
    parseActiveRuns(JSON.stringify({ version: "1", runs: [{ template: "f", name: "r" }] })),
    [{ template: "f", name: "r", paused: false, draining: false }],
    "non-numeric version is tolerated",
  );
});

test("parseActiveRuns: drops records with no template basename; defaults name + flags", () => {
  const out = parseActiveRuns(
    JSON.stringify({
      version: 1,
      runs: [
        { template: "ok-file" }, // name defaults to the basename; flags default false
        { name: "no-template" }, // dropped (no template)
        { template: "", name: "empty" }, // dropped (empty template)
        { template: "p-file", name: "p", paused: true, draining: true },
      ],
    }),
  );
  assert.deepEqual(out, [
    { template: "ok-file", name: "ok-file", paused: false, draining: false },
    { template: "p-file", name: "p", paused: true, draining: true },
  ]);
});

test("loadActiveRuns / persistActiveRuns: round-trip through the seam", () => {
  const io = memIO();
  assert.deepEqual(loadActiveRuns(io), [], "absent file → []");
  const runs: ActiveRunRecord[] = [{ template: "f", name: "r", paused: false, draining: true }];
  assert.equal(persistActiveRuns(io, runs), true);
  assert.deepEqual(loadActiveRuns(io), runs);
});

test("persistActiveRuns: a write failure is swallowed (returns false, never throws)", () => {
  const io: StoreIO = {
    read: () => null,
    write: () => {
      throw new Error("disk full");
    },
  };
  assert.equal(persistActiveRuns(io, [{ template: "f", name: "r", paused: false, draining: false }]), false);
});

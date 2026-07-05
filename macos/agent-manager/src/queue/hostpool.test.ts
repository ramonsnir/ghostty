// (ramon fork / cloud-hosts, Phase 5) Unit tests for the PURE weighted-least-loaded host
// selector + `normalizeHostPool` (queue/hostpool.ts). Run via `node --test`.

import test from "node:test";
import assert from "node:assert/strict";

import { normalizeHostPool, selectHost, type HostSpec, type HostLoad } from "./hostpool.js";

/** Build a load map from `{name: [active, lifetime?]}`. */
function load(m: Record<string, [number, number?]>): Map<string, HostLoad> {
  const out = new Map<string, HostLoad>();
  for (const [k, [active, lifetime]] of Object.entries(m)) out.set(k, { active, lifetime: lifetime ?? 0 });
  return out;
}

/** A two-host pool: A cap 2, B cap 4 (weight defaults 1). */
function poolAB(): HostSpec[] {
  return [
    { name: "A", weight: 1, maxConcurrent: 2 },
    { name: "B", weight: 1, maxConcurrent: 4 },
  ];
}

// ---------------------------------------------------------------------------
// normalizeHostPool — scalar back-compat + explicit pool.
// ---------------------------------------------------------------------------

test("normalizeHostPool: scalar host => single UNBOUNDED-capacity entry", () => {
  const p = normalizeHostPool({ host: "cloud-1" });
  assert.deepEqual(p, [{ name: "cloud-1", weight: 1, maxConcurrent: Number.POSITIVE_INFINITY }]);
});

test("normalizeHostPool: omitted host => single unbounded 'local' entry", () => {
  const p = normalizeHostPool({});
  assert.deepEqual(p, [{ name: "local", weight: 1, maxConcurrent: Number.POSITIVE_INFINITY }]);
  // An empty-string host also normalizes to local.
  assert.equal(normalizeHostPool({ host: "" })[0].name, "local");
});

test("normalizeHostPool: explicit hosts[] pass through with weight defaulted to 1", () => {
  const p = normalizeHostPool({
    hosts: [
      { name: "A", maxConcurrent: 2 },
      { name: "B", maxConcurrent: 4, weight: 2, maxItems: 10 },
    ],
  });
  assert.deepEqual(p, [
    { name: "A", weight: 1, maxConcurrent: 2 },
    { name: "B", weight: 2, maxConcurrent: 4, maxItems: 10 },
  ]);
});

test("normalizeHostPool: hosts[] WINS over the scalar host (pool is authoritative)", () => {
  const p = normalizeHostPool({ host: "cloud-1", hosts: [{ name: "A", maxConcurrent: 2 }] });
  assert.equal(p.length, 1);
  assert.equal(p[0].name, "A");
});

test("normalizeHostPool: an EMPTY hosts[] falls back to the scalar/local entry", () => {
  assert.equal(normalizeHostPool({ host: "cloud-1", hosts: [] })[0].name, "cloud-1");
});

// ---------------------------------------------------------------------------
// selectHost — the weighted-least-loaded argmin.
// ---------------------------------------------------------------------------

test("selectHost: an all-empty pool picks the FIRST-DECLARED host (score-tie tie-break)", () => {
  assert.equal(selectHost(poolAB(), new Map()), "A");
});

test("selectHost: routes to the host with the lower active/capacity ratio", () => {
  // A: 1/2 = 0.5 ; B: 1/4 = 0.25 → B wins (bigger box has proportionally more room).
  assert.equal(selectHost(poolAB(), load({ A: [1], B: [1] })), "B");
});

test("selectHost: WEIGHT biases the metric (a heavier host is preferred beyond raw capacity)", () => {
  // Two EQUAL-capacity hosts, but B has weight 2 → its effective per-slot cost is halved.
  const p: HostSpec[] = [
    { name: "A", weight: 1, maxConcurrent: 2 },
    { name: "B", weight: 2, maxConcurrent: 2 },
  ];
  // Both empty → tie → first-declared A.
  assert.equal(selectHost(p, new Map()), "A");
  // A has 1 (score 0.5), B has 1 (score 1/(2·2)=0.25) → B wins despite equal raw capacity.
  assert.equal(selectHost(p, load({ A: [1], B: [1] })), "B");
});

test("selectHost: SKIPS a host at its maxConcurrent (candidacy is independent of score)", () => {
  // A is full (2/2) even though its NOMINAL score (1.0) isn't the max — it's simply not a candidate.
  assert.equal(selectHost(poolAB(), load({ A: [2], B: [3] })), "B"); // B: 3/4 < full
});

test("selectHost: ALL hosts full => null (the item WAITS on hostCapacity)", () => {
  assert.equal(selectHost(poolAB(), load({ A: [2], B: [4] })), null);
});

test("selectHost: exclude (cooldown / down-host fallback) SKIPS a host", () => {
  // B would win on load, but it's excluded (down/cooling) → A.
  assert.equal(selectHost(poolAB(), load({ A: [1], B: [1] }), { exclude: new Set(["B"]) }), "A");
  // Both excluded → null.
  assert.equal(selectHost(poolAB(), new Map(), { exclude: new Set(["A", "B"]) }), null);
});

test("selectHost: per-host maxItems EXHAUSTION excludes a host (forward-compat)", () => {
  const p: HostSpec[] = [
    { name: "A", weight: 1, maxConcurrent: 5, maxItems: 2 },
    { name: "B", weight: 1, maxConcurrent: 5 },
  ];
  // A has lifetime 2 (== maxItems) → spent → not a candidate → B (even though A has lower active).
  assert.equal(selectHost(p, load({ A: [0, 2], B: [3, 3] })), "B");
  // A with lifetime 1 (< maxItems 2) is still a candidate and wins on the lower active ratio.
  assert.equal(selectHost(p, load({ A: [0, 1], B: [0, 0] })), "A");
});

test("selectHost: +Infinity maxConcurrent (scalar back-compat) always wins its singleton", () => {
  const p = normalizeHostPool({ host: "local" });
  assert.equal(selectHost(p, load({ local: [99] })), "local"); // never full; score 0
});

test("selectHost: tie-break is a function of POOL ORDER, NOT load-map insertion order", () => {
  // A one-slot-each pool; the load map is inserted in DIFFERENT orders but the same values.
  const p: HostSpec[] = [
    { name: "A", weight: 1, maxConcurrent: 3 },
    { name: "B", weight: 1, maxConcurrent: 3 },
    { name: "C", weight: 1, maxConcurrent: 3 },
  ];
  // All at active 1 → all score 1/3 → the FIRST-DECLARED (A) must win regardless of map order.
  const m1 = new Map<string, HostLoad>();
  m1.set("C", { active: 1, lifetime: 0 });
  m1.set("A", { active: 1, lifetime: 0 });
  m1.set("B", { active: 1, lifetime: 0 });
  const m2 = new Map<string, HostLoad>();
  m2.set("B", { active: 1, lifetime: 0 });
  m2.set("C", { active: 1, lifetime: 0 });
  m2.set("A", { active: 1, lifetime: 0 });
  assert.equal(selectHost(p, m1), "A");
  assert.equal(selectHost(p, m2), "A");
});

test("selectHost: GREEDY sequence spreads by capacity (recompute after each pick)", () => {
  // A cap 2 (weight 1), B cap 4 (weight 1): filling 6 slots one at a time, updating the load map
  // after each pick, must EXACTLY fill each box to its capacity (never overshoot), routing more to
  // the bigger box. This mirrors the runner's within-sweep greedy seat.
  const p = poolAB();
  const live = new Map<string, HostLoad>();
  const picks: string[] = [];
  for (let i = 0; i < 6; i++) {
    const h = selectHost(p, live);
    assert.notEqual(h, null, `pick ${i} should find a host`);
    picks.push(h!);
    const cur = live.get(h!) ?? { active: 0, lifetime: 0 };
    live.set(h!, { active: cur.active + 1, lifetime: cur.lifetime });
  }
  // 6 picks fully fill A(2) + B(4); the 7th must be null (all full).
  assert.equal(live.get("A")!.active, 2);
  assert.equal(live.get("B")!.active, 4);
  assert.equal(selectHost(p, live), null);
  // Deterministic sequence: empty→A(tie, first-declared), then least-loaded-by-ratio.
  // 0: A(0/2=0 tie→A) 1: B(A 0.5 vs B 0) 2: B(A .5 vs B .25) 3: A?(A .5 vs B .5 tie→A)
  // → A,B,B,A,B,B.
  assert.deepEqual(picks, ["A", "B", "B", "A", "B", "B"]);
});

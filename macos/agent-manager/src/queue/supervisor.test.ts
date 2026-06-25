// Unit tests for the PURE supervisor decision core (§6/§7/§10). Run via `npm test`.
// Everything here is deterministic with an injected nowMs — no I/O, no real clock.

import test from "node:test";
import assert from "node:assert/strict";

import type { Assignment, QueueTemplate, WorkItem } from "./types.js";
import { activeSetFromKept, reconcile, type LiveSurface } from "./store.js";
import {
  ConcurrencyBudget,
  closeSequencePlan,
  cooldownExpired,
  cooldownUntil,
  DEFAULT_EXIT_KEYS,
  foldIdleAnchor,
  nextState,
  remainingSlots,
  selectCandidates,
  type NextStateContext,
} from "./supervisor.js";

// ---------------------------------------------------------------------------
// Fixtures.
// ---------------------------------------------------------------------------

function tmpl(over: Partial<QueueTemplate> = {}): QueueTemplate {
  return {
    name: "q",
    workdir: "/tmp",
    agent: { command: "claude" },
    concurrency: 9,
    maxItems: 200,
    grid: { cols: 3, rows: 3, fill: "columns" },
    intervals: { listMs: 45000, statusMs: 20000 },
    provider: {
      list: { command: ["list"], keyField: "id" },
      status: { command: ["status", "{key}"], doneStates: ["done"] },
    },
    onAgentExit: "leave-and-bell",
    closeOnComplete: true,
    closeStableSeconds: 5,
    params: [],
    ...over,
  };
}

function item(key: string): WorkItem {
  return { key, title: `title ${key}` };
}

function asgn(over: Partial<Assignment> = {}): Assignment {
  return {
    queueName: "q",
    key: "K-1",
    sessionID: 1,
    surfaceUUID: "u-1",
    gridSlot: 0,
    state: "RUNNING",
    sinceMs: 0,
    ...over,
  };
}

function ctx(over: Partial<NextStateContext> = {}): NextStateContext {
  return {
    surfaceLive: true,
    exited: false,
    nowMs: 100000,
    closeStableSeconds: 5,
    ...over,
  };
}

// ---------------------------------------------------------------------------
// ConcurrencyBudget — the supervisor owns its OWN budget.
// ---------------------------------------------------------------------------

test("ConcurrencyBudget caps acquisitions and releases", () => {
  const b = new ConcurrencyBudget(2);
  assert.ok(b.tryAcquire());
  assert.ok(b.tryAcquire());
  assert.ok(!b.tryAcquire());
  assert.equal(b.active, 2);
  b.release();
  assert.ok(b.tryAcquire());
});

// ---------------------------------------------------------------------------
// selectCandidates — within-tick dedup, cooldown, caps.
// ---------------------------------------------------------------------------

test("selectCandidates: within-tick dedup — same key twice in one list dispatched once", () => {
  const items = [item("K-1"), item("K-1"), item("K-2")];
  const out = selectCandidates(items, new Map(), new Map(), new Set(), 0, 10, 10);
  assert.deepEqual(out.map((i) => i.key), ["K-1", "K-2"]);
});

test("selectCandidates: a key already in the active set is skipped (cross-restart dedup)", () => {
  const active = activeSetFromKept([asgn({ key: "K-1" })]);
  const out = selectCandidates([item("K-1"), item("K-2")], active, new Map(), new Set(), 0, 10, 10);
  assert.deepEqual(out.map((i) => i.key), ["K-2"]);
});

test("selectCandidates: a key in cooldown (future until) is skipped; expired is allowed", () => {
  const cooldown = new Map<string, number>([
    ["K-1", 5000], // future at now=1000
    ["K-2", 500], // expired at now=1000
  ]);
  const out = selectCandidates([item("K-1"), item("K-2")], new Map(), cooldown, new Set(), 1000, 10, 10);
  assert.deepEqual(out.map((i) => i.key), ["K-2"]);
});

test("selectCandidates: a key in the dispatched LATCH is skipped (§7.1) — even with no cooldown and slots free", () => {
  const dispatched = new Set<string>(["K-1"]);
  const out = selectCandidates([item("K-1"), item("K-2")], new Map(), new Map(), dispatched, 1000, 10, 10);
  assert.deepEqual(out.map((i) => i.key), ["K-2"], "K-1 suppressed by the latch; K-2 eligible");
});

test("selectCandidates: a latched key is eligible again ONCE removed from the latch (re-arm)", () => {
  const dispatched = new Set<string>(["K-1"]);
  // Before re-arm: suppressed.
  assert.deepEqual(
    selectCandidates([item("K-1")], new Map(), new Map(), dispatched, 1000, 10, 10).map((i) => i.key),
    [],
  );
  // After re-arm (the dispatch sweep clears it when a successful list omits the key):
  dispatched.delete("K-1");
  assert.deepEqual(
    selectCandidates([item("K-1")], new Map(), new Map(), dispatched, 1000, 10, 10).map((i) => i.key),
    ["K-1"],
  );
});

test("selectCandidates: respects the remainingSlots cap (concurrency/grid)", () => {
  const items = [item("K-1"), item("K-2"), item("K-3")];
  const out = selectCandidates(items, new Map(), new Map(), new Set(), 0, 2, 10);
  assert.deepEqual(out.map((i) => i.key), ["K-1", "K-2"]);
});

test("selectCandidates: respects the maxItemsRemaining (lifetime) clamp", () => {
  const items = [item("K-1"), item("K-2"), item("K-3")];
  const out = selectCandidates(items, new Map(), new Map(), new Set(), 0, 10, 1);
  assert.deepEqual(out.map((i) => i.key), ["K-1"]);
});

test("selectCandidates: a non-positive cap yields nothing", () => {
  assert.deepEqual(selectCandidates([item("K-1")], new Map(), new Map(), new Set(), 0, 0, 10), []);
  assert.deepEqual(selectCandidates([item("K-1")], new Map(), new Map(), new Set(), 0, 10, 0), []);
  assert.deepEqual(selectCandidates([item("K-1")], new Map(), new Map(), new Set(), 0, -3, 10), []);
});

test("selectCandidates: keyless items are never dispatched", () => {
  const out = selectCandidates([{ key: "" }, item("K-2")], new Map(), new Map(), new Set(), 0, 10, 10);
  assert.deepEqual(out.map((i) => i.key), ["K-2"]);
});

// ---------------------------------------------------------------------------
// Cross-restart dedup, end-to-end: reconcile re-adopts then selectCandidates skips.
// ---------------------------------------------------------------------------

test("cross-restart dedup: reconcile re-adopts a live key, then selectCandidates skips it", () => {
  // A spawn's record was lost (crash) but the surface is live with its annotation.
  const orphan: LiveSurface = {
    sessionID: 42,
    surfaceUUID: "u-42",
    queueKey: "K-LIVE",
    queueName: "q",
  };
  const plan = reconcile([], [orphan], 1000, 30000);
  const active = activeSetFromKept(plan.kept);
  assert.ok(active.has("K-LIVE")); // re-adopted, not lost

  // The fresh list still includes K-LIVE — it must NOT be re-dispatched.
  const out = selectCandidates([item("K-LIVE"), item("K-NEW")], active, new Map(), new Set(), 1000, 10, 10);
  assert.deepEqual(out.map((i) => i.key), ["K-NEW"]); // zero double-dispatch
});

// ---------------------------------------------------------------------------
// remainingSlots — concurrency vs grid vs global.
// ---------------------------------------------------------------------------

test("remainingSlots: smaller of concurrency room, grid room, global remaining", () => {
  // concurrency 9, grid 3x3=9, active 2 -> room 7; global 100 -> 7
  assert.equal(remainingSlots(tmpl(), 2, 100), 7);
  // grid is the binding cap: 2x2=4, active 1 -> grid room 3 even if concurrency=9
  assert.equal(remainingSlots(tmpl({ grid: { cols: 2, rows: 2, fill: "columns" } }), 1, 100), 3);
  // global is the binding cap
  assert.equal(remainingSlots(tmpl(), 0, 2), 2);
  // floored at 0 when over-subscribed
  assert.equal(remainingSlots(tmpl(), 20, 100), 0);
});

test("remainingSlots: effConcurrency/effGridCap OVERRIDE the template (live set_concurrency)", () => {
  // Template concurrency 6, grid 3x2=6. A live concurrency of 9 (with the lifted grid cap 9)
  // gives room 9-2=7 instead of the template's 6-2=4.
  const t = tmpl({ concurrency: 6, grid: { cols: 3, rows: 2, fill: "columns" } });
  assert.equal(remainingSlots(t, 2, 100), 4, "template values: min(6,6)-2 = 4");
  assert.equal(remainingSlots(t, 2, 100, 9, 9), 7, "lifted to 9: min(9,9)-2 = 7");
  // The grid cap still binds if it is NOT lifted alongside concurrency.
  assert.equal(remainingSlots(t, 2, 100, 9, 6), 4, "grid cap 6 still binds at 9 concurrency");
});

// ---------------------------------------------------------------------------
// nextState — the §6 state machine.
// ---------------------------------------------------------------------------

test("nextState: SPAWNED -> RUNNING when an agentState is observed on a live surface", () => {
  assert.equal(nextState(asgn({ state: "SPAWNED" }), ctx({ agentState: "working" })), "RUNNING");
});

test("nextState: SPAWNED holds while no agentState yet", () => {
  assert.equal(nextState(asgn({ state: "SPAWNED" }), ctx({ agentState: undefined })), "SPAWNED");
});

test("nextState: RUNNING -> DONE_PENDING ONLY on provider statusTerminal (status-only completion)", () => {
  // idle alone, status not terminal -> stays RUNNING (no false-positive completion).
  assert.equal(
    nextState(asgn({ state: "RUNNING" }), ctx({ agentState: "idle", statusTerminal: false })),
    "RUNNING",
  );
  // status terminal -> DONE_PENDING.
  assert.equal(
    nextState(asgn({ state: "RUNNING" }), ctx({ statusTerminal: true })),
    "DONE_PENDING",
  );
});

test("nextState: status terminal also completes a still-SPAWNED fast agent", () => {
  assert.equal(
    nextState(asgn({ state: "SPAWNED" }), ctx({ statusTerminal: true })),
    "DONE_PENDING",
  );
});

test("nextState: idle-debounce gate — idle must be HELD unchanged closeStableSeconds before CLOSING", () => {
  const a = asgn({ state: "DONE_PENDING" });
  const now = 100000;
  // Just became idle (anchor == now): 0s held < 5s -> hold.
  assert.equal(
    nextState(a, ctx({ agentState: "idle", idleStableSinceMs: now, nowMs: now, closeStableSeconds: 5 })),
    "DONE_PENDING",
  );
  // Idle held 4.9s < 5s -> still hold.
  assert.equal(
    nextState(a, ctx({ agentState: "idle", idleStableSinceMs: now - 4900, nowMs: now, closeStableSeconds: 5 })),
    "DONE_PENDING",
  );
  // Idle held exactly 5s -> CLOSING.
  assert.equal(
    nextState(a, ctx({ agentState: "idle", idleStableSinceMs: now - 5000, nowMs: now, closeStableSeconds: 5 })),
    "CLOSING",
  );
});

test("nextState: a finished agent settled in WAITING (not idle) closes once held closeStableSeconds", () => {
  // The real-world stuck case: a finished Claude Code agent fires Stop(idle), then a
  // Notification "waiting for input" nudge flips it to waiting — so it ends in `waiting`,
  // never `idle`. Quiescence (idle OR waiting) is what lets the queue close it.
  const a = asgn({ state: "DONE_PENDING" });
  const now = 100000;
  // waiting, but not yet held the window -> hold.
  assert.equal(
    nextState(a, ctx({ agentState: "waiting", idleStableSinceMs: now - 4900, nowMs: now, closeStableSeconds: 5 })),
    "DONE_PENDING",
  );
  // waiting held exactly closeStableSeconds -> CLOSING.
  assert.equal(
    nextState(a, ctx({ agentState: "waiting", idleStableSinceMs: now - 5000, nowMs: now, closeStableSeconds: 5 })),
    "CLOSING",
  );
});

test("nextState: closeOnComplete=false PINS DONE_PENDING — a stably-idle agent is NOT closed", () => {
  const a = asgn({ state: "DONE_PENDING" });
  const now = 100000;
  // Idle held well past closeStableSeconds — would normally CLOSE — but closeOnComplete
  // is false, so the completed split is LEFT OPEN for manual close (§5/§6/§10).
  assert.equal(
    nextState(
      a,
      ctx({
        agentState: "idle",
        idleStableSinceMs: now - 60000,
        nowMs: now,
        closeStableSeconds: 5,
        closeOnComplete: false,
      }),
    ),
    "DONE_PENDING",
  );
  // The same context with closeOnComplete true (and undefined = default) DOES close.
  assert.equal(
    nextState(a, ctx({ agentState: "idle", idleStableSinceMs: now - 60000, nowMs: now, closeStableSeconds: 5, closeOnComplete: true })),
    "CLOSING",
  );
  assert.equal(
    nextState(a, ctx({ agentState: "idle", idleStableSinceMs: now - 60000, nowMs: now, closeStableSeconds: 5 })),
    "CLOSING",
    "closeOnComplete undefined defaults to auto-close",
  );
});

test("nextState: a Codex/no-hooks agent (no agentState) NEVER reaches CLOSING (documented §14 limit)", () => {
  // Codex emits no agent-state hooks, so a DONE_PENDING assignment never observes a
  // quiescent agentState (idle/waiting); the close gate can therefore never fire — the
  // split would need manual close. This pins that documented limitation.
  const a = asgn({ state: "DONE_PENDING" });
  const now = 100000;
  for (const elapsed of [0, 5000, 60000, 600000]) {
    assert.equal(
      nextState(a, ctx({ agentState: undefined, idleStableSinceMs: undefined, nowMs: now + elapsed, closeStableSeconds: 5 })),
      "DONE_PENDING",
      `no agentState at +${elapsed}ms holds DONE_PENDING (never auto-closes)`,
    );
  }
});

test("nextState: a flap (anchor reset) HOLDS DONE_PENDING — never closes early", () => {
  const a = asgn({ state: "DONE_PENDING" });
  // agentState idle but anchor undefined (it just flapped back to idle this tick was
  // reset) -> hold; and a non-idle observation -> hold.
  assert.equal(
    nextState(a, ctx({ agentState: "idle", idleStableSinceMs: undefined })),
    "DONE_PENDING",
  );
  assert.equal(
    nextState(a, ctx({ agentState: "working", idleStableSinceMs: undefined })),
    "DONE_PENDING",
  );
});

test("nextState: EXITED — child exits before completion in any live pre-state", () => {
  for (const state of ["QUEUED", "SPAWNED", "RUNNING"] as const) {
    assert.equal(nextState(asgn({ state }), ctx({ exited: true })), "EXITED");
  }
});

test("nextState: EXITED takes priority over a same-tick status-terminal", () => {
  // A crash-and-also-done tick: leave-and-bell (EXITED) wins so the slot frees + bell rings.
  assert.equal(
    nextState(asgn({ state: "RUNNING" }), ctx({ exited: true, statusTerminal: true })),
    "EXITED",
  );
});

test("nextState: terminal/transitional states are returned unchanged", () => {
  for (const state of ["CLOSING", "FINISHED", "FAILED", "EXITED", "COOLDOWN"] as const) {
    assert.equal(nextState(asgn({ state }), ctx({ exited: true, statusTerminal: true })), state);
  }
});

test("nextState: DONE_PENDING whose child EXITED short-circuits to CLOSING (no stuck slot)", () => {
  // A provider-done agent's child crashes/exits before ever reporting a stable idle.
  // Without the shortcut it would hold DONE_PENDING forever (the idle gate never fires)
  // and wedge its slot. With it, an exited child advances straight to CLOSING.
  const a = asgn({ state: "DONE_PENDING" });
  assert.equal(
    nextState(a, ctx({ exited: true, agentState: "working", idleStableSinceMs: undefined })),
    "CLOSING",
  );
  // closeOnComplete=false still pins DONE_PENDING even with an exited child (manual close).
  assert.equal(
    nextState(a, ctx({ exited: true, closeOnComplete: false })),
    "DONE_PENDING",
  );
});

test("nextState: closeStableSeconds=0 closes on the FIRST stable-idle observation", () => {
  // A template may set closeStableSeconds:0 (templates permit 0); the boundary
  // nowMs - idleStableSinceMs >= 0 is satisfied immediately, so the first idle closes.
  const a = asgn({ state: "DONE_PENDING" });
  assert.equal(
    nextState(a, ctx({ agentState: "idle", idleStableSinceMs: 100000, nowMs: 100000, closeStableSeconds: 0 })),
    "CLOSING",
  );
});

// ---------------------------------------------------------------------------
// foldIdleAnchor — the idle-debounce anchor folding (a flap resets it).
// ---------------------------------------------------------------------------

test("foldIdleAnchor: quiescent (idle/waiting) with no prior anchor STARTS the clock; with a prior KEEPS it", () => {
  assert.equal(foldIdleAnchor(undefined, "idle", 5000), 5000); // start on idle
  assert.equal(foldIdleAnchor(5000, "idle", 9000), 5000); // held — clock not reset
  assert.equal(foldIdleAnchor(undefined, "waiting", 5000), 5000); // start on waiting too
  assert.equal(foldIdleAnchor(5000, "waiting", 9000), 5000); // held on waiting
});

test("foldIdleAnchor: an idle<->waiting transition KEEPS the anchor (both are quiescent)", () => {
  // A finished Claude Code agent fires Stop(idle) then a Notification(waiting) nudge.
  // That transition must NOT reset the close clock — both states are quiescent.
  assert.equal(foldIdleAnchor(5000, "waiting", 9000), 5000); // idle-anchored, now waiting -> kept
  assert.equal(foldIdleAnchor(5000, "idle", 9000), 5000); // waiting-anchored, now idle -> kept
});

test("foldIdleAnchor: only working/undefined RESET the anchor (a flap)", () => {
  assert.equal(foldIdleAnchor(5000, "working", 9000), undefined);
  assert.equal(foldIdleAnchor(5000, undefined, 9000), undefined);
});

test("idle-debounce full flap scenario: idle held, then flaps, then re-idles -> clock restarts", () => {
  // t=0 idle -> anchor 0
  let anchor = foldIdleAnchor(undefined, "idle", 0);
  assert.equal(anchor, 0);
  // t=3000 still idle -> anchor unchanged 0 (3s held)
  anchor = foldIdleAnchor(anchor, "idle", 3000);
  assert.equal(anchor, 0);
  // t=4000 FLAP to working -> anchor reset
  anchor = foldIdleAnchor(anchor, "working", 4000);
  assert.equal(anchor, undefined);
  // t=5000 re-idle -> anchor restarts at 5000 (NOT 0) — the hold begins again
  anchor = foldIdleAnchor(anchor, "idle", 5000);
  assert.equal(anchor, 5000);
  // at t=9000 only 4s held since the re-idle -> DONE_PENDING still holds (no close).
  assert.equal(
    nextState(asgn({ state: "DONE_PENDING" }), ctx({ agentState: "idle", idleStableSinceMs: anchor, nowMs: 9000, closeStableSeconds: 5 })),
    "DONE_PENDING",
  );
  // at t=10000 -> 5s held -> CLOSING.
  assert.equal(
    nextState(asgn({ state: "DONE_PENDING" }), ctx({ agentState: "idle", idleStableSinceMs: anchor, nowMs: 10000, closeStableSeconds: 5 })),
    "CLOSING",
  );
});

// ---------------------------------------------------------------------------
// closeSequencePlan (§10).
// ---------------------------------------------------------------------------

test("closeSequencePlan: default exit (Ctrl-D) -> sendKey, awaitExited, forceClose", () => {
  const steps = closeSequencePlan(asgn(), tmpl());
  assert.deepEqual(steps, [
    { kind: "sendKey", key: DEFAULT_EXIT_KEYS[0] },
    { kind: "awaitExited" },
    { kind: "forceClose" },
  ]);
});

test("closeSequencePlan: template exit keys are honored in order", () => {
  const steps = closeSequencePlan(asgn(), tmpl({ agent: { command: "x", exit: { keys: ["ctrl_c", "ctrl_d"] } } }));
  assert.deepEqual(steps, [
    { kind: "sendKey", key: "ctrl_c" },
    { kind: "sendKey", key: "ctrl_d" },
    { kind: "awaitExited" },
    { kind: "forceClose" },
  ]);
});

test("closeSequencePlan: a typed exit command (text) types it + presses Enter", () => {
  // Claude Code exits via "/quit" (it swallows Ctrl-D), so the prelude is sendText + Enter.
  const steps = closeSequencePlan(asgn(), tmpl({ agent: { command: "claude", exit: { text: "/quit" } } }));
  assert.deepEqual(steps, [
    { kind: "sendText", text: "/quit" },
    { kind: "sendKey", key: "enter" },
    { kind: "awaitExited" },
    { kind: "forceClose" },
  ]);
});

test("closeSequencePlan: text exit with submit:false types WITHOUT Enter", () => {
  const steps = closeSequencePlan(asgn(), tmpl({ agent: { command: "x", exit: { text: "/quit", submit: false } } }));
  assert.deepEqual(steps, [
    { kind: "sendText", text: "/quit" },
    { kind: "awaitExited" },
    { kind: "forceClose" },
  ]);
});

test("closeSequencePlan: text-only exit does NOT append the default Ctrl-D", () => {
  const steps = closeSequencePlan(asgn(), tmpl({ agent: { command: "x", exit: { text: "/quit" } } }));
  assert.equal(steps.some((s) => s.kind === "sendKey" && s.key === DEFAULT_EXIT_KEYS[0]), false);
});

test("closeSequencePlan: text + keys runs the text prelude THEN the keys", () => {
  const steps = closeSequencePlan(asgn(), tmpl({ agent: { command: "x", exit: { text: "/q", keys: ["ctrl-d"] } } }));
  assert.deepEqual(steps, [
    { kind: "sendText", text: "/q" },
    { kind: "sendKey", key: "enter" },
    { kind: "sendKey", key: "ctrl-d" },
    { kind: "awaitExited" },
    { kind: "forceClose" },
  ]);
});

test("closeSequencePlan: empty exit.keys falls back to the default", () => {
  const steps = closeSequencePlan(asgn(), tmpl({ agent: { command: "x", exit: { keys: [] } } }));
  assert.equal(steps[0].kind, "sendKey");
  assert.deepEqual(steps, [
    { kind: "sendKey", key: DEFAULT_EXIT_KEYS[0] },
    { kind: "awaitExited" },
    { kind: "forceClose" },
  ]);
});

// ---------------------------------------------------------------------------
// Cooldown helpers (§6): blocks immediate re-dispatch, then expires.
// ---------------------------------------------------------------------------

test("cooldown: a finished key blocks immediate re-dispatch then becomes eligible", () => {
  const now = 1000;
  const cooldown = new Map<string, number>();
  cooldown.set("K-DONE", cooldownUntil(now, 2000)); // until = 3000

  // Immediately after finishing: blocked.
  let out = selectCandidates([item("K-DONE")], new Map(), cooldown, new Set(), now + 1, 10, 10);
  assert.deepEqual(out, []);
  assert.ok(!cooldownExpired(cooldown, "K-DONE", now + 1));

  // After the window: eligible again (re-picks a reopened item).
  out = selectCandidates([item("K-DONE")], new Map(), cooldown, new Set(), 3001, 10, 10);
  assert.deepEqual(out.map((i) => i.key), ["K-DONE"]);
  assert.ok(cooldownExpired(cooldown, "K-DONE", 3001));
});

test("cooldownExpired: an absent entry reads as expired", () => {
  assert.ok(cooldownExpired(new Map(), "nope", 0));
});

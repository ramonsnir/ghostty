// Unit tests for the PURE schedule cron + next-start core. Run via `npm test`.
// Deterministic: every time is injected. Times are built with LOCAL `Date`
// constructors (both inputs and expectations), so the assertions hold regardless of
// the test machine's timezone — the production code likewise uses local wall-clock.

import test from "node:test";
import assert from "node:assert/strict";

import {
  CronParseError,
  computeNextStart,
  isDue,
  nextAfter,
  parseCron,
  prevBefore,
  type ScheduleState,
} from "./schedule.js";

// Local-time constructor helper: month is 1-based here for readability.
function at(y: number, mon1: number, day: number, hh = 0, mm = 0, ss = 0, ms = 0): number {
  return new Date(y, mon1 - 1, day, hh, mm, ss, ms).getTime();
}

// ---------------------------------------------------------------------------
// parseCron
// ---------------------------------------------------------------------------

test("parseCron accepts a plain 5-field weekday expression", () => {
  const c = parseCron("0 9 * * 1-5");
  assert.ok(c.minute.has(0) && c.minute.size === 1);
  assert.ok(c.hour.has(9) && c.hour.size === 1);
  assert.ok(c.domStar);
  assert.ok(!c.dowStar);
  assert.deepEqual([...c.dow].sort((a, b) => a - b), [1, 2, 3, 4, 5]);
});

test("parseCron handles lists, ranges, and steps", () => {
  const c = parseCron("0 9,13,17 * * *");
  assert.deepEqual([...c.hour].sort((a, b) => a - b), [9, 13, 17]);
  const s = parseCron("*/15 * * * *");
  assert.deepEqual([...s.minute].sort((a, b) => a - b), [0, 15, 30, 45]);
  const r = parseCron("0 9-11/1 * * *");
  assert.deepEqual([...r.hour].sort((a, b) => a - b), [9, 10, 11]);
});

test("parseCron normalizes day-of-week 7 to 0 (Sunday)", () => {
  const c7 = parseCron("0 9 * * 7");
  const c0 = parseCron("0 9 * * 0");
  assert.ok(c7.dow.has(0));
  assert.deepEqual([...c7.dow], [...c0.dow]);
});

test("parseCron rejects malformed expressions", () => {
  assert.throws(() => parseCron("0 9 * *"), CronParseError); // 4 fields
  assert.throws(() => parseCron("0 9 * * * *"), CronParseError); // 6 fields
  assert.throws(() => parseCron("60 9 * * *"), CronParseError); // minute 60
  assert.throws(() => parseCron("0 24 * * *"), CronParseError); // hour 24
  assert.throws(() => parseCron("0 9 * * 8"), CronParseError); // dow 8
  assert.throws(() => parseCron("*/0 * * * *"), CronParseError); // step 0
  assert.throws(() => parseCron("0 9 32 * *"), CronParseError); // dom 32
});

// ---------------------------------------------------------------------------
// nextAfter / prevBefore
// ---------------------------------------------------------------------------

test("nextAfter is strictly greater and lands on the next daily firing", () => {
  const c = parseCron("0 9 * * *");
  // 2024-03-04 is a Monday (guard so a wrong date fails loudly, not silently).
  assert.equal(new Date(2024, 2, 4).getDay(), 1);
  assert.equal(nextAfter(c, at(2024, 3, 4, 8, 0)), at(2024, 3, 4, 9, 0)); // 8:00 → 9:00
  assert.equal(nextAfter(c, at(2024, 3, 4, 9, 0)), at(2024, 3, 5, 9, 0)); // exactly 9:00 → next day
  assert.equal(nextAfter(c, at(2024, 3, 4, 9, 30)), at(2024, 3, 5, 9, 0)); // 9:30 → next day
});

test("nextAfter skips the weekend for a weekday cron", () => {
  const c = parseCron("0 9 * * 1-5");
  // 2024-03-08 is a Friday; 2024-03-11 is the following Monday.
  assert.equal(new Date(2024, 2, 8).getDay(), 5);
  assert.equal(new Date(2024, 2, 11).getDay(), 1);
  assert.equal(nextAfter(c, at(2024, 3, 8, 10, 0)), at(2024, 3, 11, 9, 0));
});

test("prevBefore is strictly less and finds the prior firing", () => {
  const c = parseCron("0 9,13,17 * * *");
  assert.equal(prevBefore(c, at(2024, 3, 4, 13, 0)), at(2024, 3, 4, 9, 0));
  assert.equal(prevBefore(c, at(2024, 3, 4, 9, 0)), at(2024, 3, 3, 17, 0)); // wraps to prev day 17:00
});

// ---------------------------------------------------------------------------
// computeNextStart — never ran (arm anchor, NO skip)
// ---------------------------------------------------------------------------

test("never-ran fires at the first firing at-or-after the arm time — NO skip", () => {
  const c = parseCron("0 9 * * 1-5");
  // Armed at Mon 08:50 → today 09:00, NOT tomorrow. (The skip must not apply to
  // arming: a daily gap is 24h, so a half-gap skip would wrongly push to tomorrow.)
  assert.equal(new Date(2024, 2, 4).getDay(), 1);
  const state: ScheduleState = { armedAt: at(2024, 3, 4, 8, 50) };
  assert.equal(computeNextStart(c, state), at(2024, 3, 4, 9, 0));
});

test("never-ran armed exactly at a firing fires at that instant", () => {
  const c = parseCron("0 9 * * *");
  const state: ScheduleState = { armedAt: at(2024, 3, 4, 9, 0) };
  assert.equal(computeNextStart(c, state), at(2024, 3, 4, 9, 0));
});

// ---------------------------------------------------------------------------
// computeNextStart — completion-anchored half-of-gap skip
// ---------------------------------------------------------------------------

test("hourly: a run finishing exactly on the hour fires the next hour (no skip)", () => {
  const c = parseCron("0 * * * *");
  const state: ScheduleState = { armedAt: 0, lastCompletionAt: at(2024, 3, 4, 4, 0) };
  assert.equal(computeNextStart(c, state), at(2024, 3, 4, 5, 0));
});

test("hourly: a fast run (finish 04:05) keeps the normal 05:00 cadence", () => {
  const c = parseCron("0 * * * *");
  const state: ScheduleState = { armedAt: 0, lastCompletionAt: at(2024, 3, 4, 4, 5) };
  assert.equal(computeNextStart(c, state), at(2024, 3, 4, 5, 0));
});

test("hourly: a run finishing at the half-gap boundary (04:30) SKIPS to 06:00", () => {
  // The boundary case that pins the STRICTLY-GREATER comparator: 05:00 is exactly
  // completion + gap/2, so it is skipped.
  const c = parseCron("0 * * * *");
  const state: ScheduleState = { armedAt: 0, lastCompletionAt: at(2024, 3, 4, 4, 30) };
  assert.equal(computeNextStart(c, state), at(2024, 3, 4, 6, 0));
});

test("intraday 9/13/17: finish ~11:00 skips 13:00 → 17:00", () => {
  const c = parseCron("0 9,13,17 * * 1-5");
  assert.equal(new Date(2024, 2, 4).getDay(), 1); // Monday
  const state: ScheduleState = { armedAt: 0, lastCompletionAt: at(2024, 3, 4, 11, 0) };
  assert.equal(computeNextStart(c, state), at(2024, 3, 4, 17, 0));
});

test("intraday 9/13/17: finish 10:30 keeps 13:00", () => {
  const c = parseCron("0 9,13,17 * * 1-5");
  const state: ScheduleState = { armedAt: 0, lastCompletionAt: at(2024, 3, 4, 10, 30) };
  assert.equal(computeNextStart(c, state), at(2024, 3, 4, 13, 0));
});

test("intraday 9/13/17: last slot overruns → next weekday morning (overnight gap)", () => {
  const c = parseCron("0 9,13,17 * * 1-5");
  const state: ScheduleState = { armedAt: 0, lastCompletionAt: at(2024, 3, 4, 17, 30) };
  assert.equal(computeNextStart(c, state), at(2024, 3, 5, 9, 0)); // Tue 09:00
});

test("intraday 9/13/17: Friday overrun crosses the weekend to Monday", () => {
  const c = parseCron("0 9,13,17 * * 1-5");
  assert.equal(new Date(2024, 2, 8).getDay(), 5); // Friday
  const state: ScheduleState = { armedAt: 0, lastCompletionAt: at(2024, 3, 8, 17, 30) };
  assert.equal(computeNextStart(c, state), at(2024, 3, 11, 9, 0)); // Mon 09:00
});

// ---------------------------------------------------------------------------
// computeNextStart — 12h CAP on the required rest (the weekend-manual-run fix)
// ---------------------------------------------------------------------------

test("12h cap: weekday-daily, a weekend manual run does NOT cancel Monday (the reported bug)", () => {
  // `0 9 * * 1-5`. The firing before Mon 09:00 is FRI 09:00, so the gap into Monday is 72h and
  // the UNCAPPED half was 36h — a Sunday 10:00 manual run (only ~23h before Monday) sat inside
  // that window and skipped Monday to Tuesday. With the 12h cap, requiredRest = min(36h, 12h) =
  // 12h, and 23h > 12h → Monday 09:00 runs as it should.
  const c = parseCron("0 9 * * 1-5");
  assert.equal(new Date(2024, 2, 3).getDay(), 0); // Sunday 2024-03-03
  const state: ScheduleState = { armedAt: 0, lastCompletionAt: at(2024, 3, 3, 10, 0) };
  assert.equal(computeNextStart(c, state), at(2024, 3, 4, 9, 0)); // Mon 09:00 (NOT skipped)
});

test("12h cap: a run finishing <12h before the next firing is STILL skipped (long gap)", () => {
  // Same weekday-daily long gap, but the completion is only 11h before Monday 09:00 (Sun 22:00).
  // 11h ≤ the 12h cap → Monday IS skipped; Tuesday 09:00 (35h of rest) is then accepted.
  const c = parseCron("0 9 * * 1-5");
  const state: ScheduleState = { armedAt: 0, lastCompletionAt: at(2024, 3, 3, 22, 0) };
  assert.equal(computeNextStart(c, state), at(2024, 3, 5, 9, 0)); // Tue 09:00 (Monday skipped)
});

test("12h cap: EXACTLY 12h before the firing still skips (strictly-greater comparator kept)", () => {
  // Completion exactly 12h before Monday 09:00 (Sun 21:00). requiredRest = 12h, and 12h is NOT
  // strictly > 12h → Monday is skipped. Pins the boundary against the cap.
  const c = parseCron("0 9 * * 1-5");
  const state: ScheduleState = { armedAt: 0, lastCompletionAt: at(2024, 3, 3, 21, 0) };
  assert.equal(computeNextStart(c, state), at(2024, 3, 5, 9, 0)); // Tue 09:00
});

test("12h cap does NOT change short cadences (gap/2 already < 12h): 04:30 hourly still skips to 06:00", () => {
  // The cap is min(gap/2, 12h); for an hourly cron gap/2 = 30min < 12h, so the cap is inert and
  // the existing half-gap boundary behavior is preserved (04:30 finish → 05:00 skipped → 06:00).
  const c = parseCron("0 * * * *");
  const state: ScheduleState = { armedAt: 0, lastCompletionAt: at(2024, 3, 4, 4, 30) };
  assert.equal(computeNextStart(c, state), at(2024, 3, 4, 6, 0));
});

// ---------------------------------------------------------------------------
// No backfill + isDue
// ---------------------------------------------------------------------------

test("no backfill: a schedule idle across missed firings resolves to ONE next start", () => {
  const c = parseCron("0 9 * * 1-5");
  // Ran Mon 09:05; machine then off Tue+Wed. computeNextStart is a single instant
  // (Tue 09:00), not a list — and isDue is true once now passes it. The runner fires
  // exactly one run, then re-anchors from that completion.
  const state: ScheduleState = { armedAt: 0, lastCompletionAt: at(2024, 3, 4, 9, 5) };
  const nextStart = computeNextStart(c, state);
  assert.equal(nextStart, at(2024, 3, 5, 9, 0)); // Tue 09:00 (single value)
  assert.equal(isDue(c, state, at(2024, 3, 7, 10, 0)), true); // Thu 10:00 → due
  assert.equal(isDue(c, state, at(2024, 3, 4, 23, 0)), false); // same Mon night → not yet
});

test("isDue is exactly now >= computeNextStart", () => {
  const c = parseCron("0 9 * * *");
  const state: ScheduleState = { armedAt: at(2024, 3, 4, 8, 0) };
  const nextStart = computeNextStart(c, state);
  assert.equal(isDue(c, state, nextStart - 1), false);
  assert.equal(isDue(c, state, nextStart), true);
});

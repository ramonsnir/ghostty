// (ramon fork / Agent Queue — Schedules) The PURE cron + next-start decision core for
// SCHEDULES: recurring, low-cognition scan agents that periodically sweep a queue's
// project (docs / backlog / code) and open or amend backlog issues. A "schedule" is a
// timing spec + a prose prompt (see AGENT-QUEUE.md → Schedules). This module owns ONLY
// the deterministic timing math — WHEN the next scheduled run should start — mirroring
// the supervisor.ts pure style: no I/O, no clock-of-its-own (every time is injected as
// ms-since-epoch), unit-tested directly. The runner (index.ts) owns the side effects
// (spawn, annotate, persist). NOTHING here is Linear/Git/issue-key aware.
//
// Distinct from queue/supervisor.ts — that is the deterministic dispatch/close CORE of
// the whole Agent Queue engine (the "Supervisor"). Schedules are a per-queue FEATURE
// that rides that engine; the name was chosen to avoid overloading "supervisor".
//
// ── Scheduling model (locked design) ───────────────────────────────────────────────
//  * The cadence is a standard 5-field cron expression in LOCAL wall-clock time
//    ("minute hour day-of-month month day-of-week"), so "every weekday at 9am" is
//    `0 9 * * 1-5` and "every weekday every 4h from 9–5" is `0 9,13,17 * * 1-5`.
//  * COMPLETION-ANCHORED: the next start is computed from when the PREVIOUS run
//    completed (its split closed), NOT from a fixed grid — so a long run pushes the
//    next one out. Single-flight is therefore structural: the runner only computes a
//    next start once the current run has completed; while a scheduled split is open,
//    nothing new is armed.
//  * HALF-OF-LOCAL-GAP SKIP: the next start is the first cron firing `A` (strictly
//    after completion `C`) such that `A > C + (A − prevFiring)/2`, where `prevFiring`
//    is the cron firing immediately before `A` (the local cadence leading into `A`).
//    So a run that finishes deep into a cycle SKIPS the immediately-next firing to
//    preserve at least half-a-gap of rest. Worked examples in schedule.test.ts.
//  * NEVER-RAN: a schedule that has never completed fires at its first cron firing
//    at-or-after its ARM time (when it was first enabled/loaded) — NO skip (arming is
//    not a run; applying the skip here would wrongly delay a freshly-enabled daily
//    schedule by a whole day). `armedAt` is persisted so a restart doesn't re-arm.
//  * NO BACKFILL: firings missed while the sidecar/GUI was down (or the schedule was
//    paused) are not replayed — the runner fires ONE run when `now >= nextStart` and
//    then re-anchors from that completion.

// ---------------------------------------------------------------------------
// Parsed cron matcher.
// ---------------------------------------------------------------------------

/** A parsed 5-field cron expression: a membership Set per field plus whether the
 *  day-of-month / day-of-week fields were `*` (needed for the standard Vixie OR rule:
 *  when BOTH dom and dow are restricted, a day matches if EITHER matches). Minute
 *  0–59, hour 0–23, dom 1–31, month 1–12, dow 0–6 (Sunday=0; input 7 is normalized to
 *  0). PURE data — no behavior. */
export interface ParsedCron {
  minute: ReadonlySet<number>;
  hour: ReadonlySet<number>;
  dom: ReadonlySet<number>;
  domStar: boolean;
  month: ReadonlySet<number>;
  dow: ReadonlySet<number>;
  dowStar: boolean;
}

/** Thrown by `parseCron` on a malformed expression (wrong field count, out-of-range
 *  value, bad step/range). The caller (template validation) rejects the template; the
 *  runner disables just that schedule and logs a warning — never crashes the loop. */
export class CronParseError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CronParseError";
  }
}

/** Parse one comma-list cron field into a Set over [min,max]. Supports a single value
 *  `a`, a range `a-b`, a star `*`, and step suffixes on any of those (`a-b/n`, `a/n`,
 *  and star-step "everything, every n"). Returns `star` = whether the whole field was
 *  a bare `*` (no list/step), used for the dom/dow OR rule. PURE; throws
 *  `CronParseError` on any malformed part or out-of-range value. */
function parseField(
  spec: string,
  min: number,
  max: number,
  fieldName: string,
): { set: Set<number>; star: boolean } {
  const out = new Set<number>();
  const trimmed = spec.trim();
  if (trimmed.length === 0) {
    throw new CronParseError(`empty ${fieldName} field`);
  }
  const bareStar = trimmed === "*";
  for (const partRaw of trimmed.split(",")) {
    const part = partRaw.trim();
    if (part.length === 0) {
      throw new CronParseError(`empty ${fieldName} list element in "${spec}"`);
    }
    // Split an optional step suffix "/n".
    let rangePart = part;
    let step = 1;
    const slash = part.indexOf("/");
    if (slash !== -1) {
      rangePart = part.slice(0, slash);
      const stepStr = part.slice(slash + 1);
      step = Number(stepStr);
      if (!Number.isInteger(step) || step <= 0) {
        throw new CronParseError(`bad step "${stepStr}" in ${fieldName} "${spec}"`);
      }
    }
    let lo: number;
    let hi: number;
    if (rangePart === "*") {
      lo = min;
      hi = max;
    } else {
      const dash = rangePart.indexOf("-");
      if (dash !== -1) {
        lo = Number(rangePart.slice(0, dash));
        hi = Number(rangePart.slice(dash + 1));
      } else {
        lo = Number(rangePart);
        hi = slash !== -1 ? max : lo; // "a/n" means a..max step n
      }
    }
    if (!Number.isInteger(lo) || !Number.isInteger(hi)) {
      throw new CronParseError(`non-integer value in ${fieldName} "${spec}"`);
    }
    if (lo < min || hi > max || lo > hi) {
      throw new CronParseError(
        `${fieldName} value out of range [${min},${max}] in "${spec}"`,
      );
    }
    for (let v = lo; v <= hi; v += step) out.add(v);
  }
  return { set: out, star: bareStar };
}

/** Parse a 5-field cron string ("min hour dom month dow") into a `ParsedCron`. LOCAL
 *  time. Day-of-week accepts 0–7 with 7 normalized to 0 (Sunday). PURE; throws
 *  `CronParseError` on a bad field count or any malformed field. */
export function parseCron(expr: string): ParsedCron {
  const fields = expr.trim().split(/\s+/);
  if (fields.length !== 5) {
    throw new CronParseError(
      `expected 5 cron fields, got ${fields.length} in "${expr}"`,
    );
  }
  const minute = parseField(fields[0], 0, 59, "minute");
  const hour = parseField(fields[1], 0, 23, "hour");
  const dom = parseField(fields[2], 1, 31, "day-of-month");
  const month = parseField(fields[3], 1, 12, "month");
  const dowRaw = parseField(fields[4], 0, 7, "day-of-week");
  // Normalize dow 7 → 0 (both mean Sunday).
  const dow = new Set<number>();
  for (const d of dowRaw.set) dow.add(d === 7 ? 0 : d);
  return {
    minute: minute.set,
    hour: hour.set,
    dom: dom.set,
    domStar: dom.star,
    month: month.set,
    dow,
    dowStar: dowRaw.star,
  };
}

/** Does the local day of `t` match the cron's day fields, per the standard rule: when
 *  BOTH dom and dow are restricted, match if EITHER matches; if only one is restricted,
 *  it governs; if both are `*`, every day matches. PURE. */
function dayMatches(cron: ParsedCron, t: Date): boolean {
  const dom = t.getDate();
  const dow = t.getDay(); // 0=Sun..6=Sat
  const domR = !cron.domStar;
  const dowR = !cron.dowStar;
  if (domR && dowR) return cron.dom.has(dom) || cron.dow.has(dow);
  if (domR) return cron.dom.has(dom);
  if (dowR) return cron.dow.has(dow);
  return true;
}

// A generous scan horizon so a sparse-but-valid cron (e.g. Feb 29) still resolves,
// while an IMPOSSIBLE one (Feb 30) terminates instead of looping forever. Each loop
// iteration advances t by at least a minute (usually much more via fast-forward), so
// this bounds the scan to ~4 years.
const MAX_SCAN_ITERS = 4 * 366 * 24 * 60;

/** The smallest cron firing STRICTLY GREATER than `afterMs` (local time), in
 *  ms-since-epoch. PURE (no own clock). Uses month/day/hour fast-forward so a sparse
 *  cron resolves in O(days), not O(minutes). Throws if no firing exists within ~4
 *  years (an impossible expression like Feb 30). */
export function nextAfter(cron: ParsedCron, afterMs: number): number {
  const t = new Date(afterMs);
  t.setSeconds(0, 0);
  t.setMinutes(t.getMinutes() + 1); // strictly after `afterMs`
  for (let i = 0; i < MAX_SCAN_ITERS; i++) {
    if (!cron.month.has(t.getMonth() + 1)) {
      t.setMonth(t.getMonth() + 1, 1);
      t.setHours(0, 0, 0, 0);
      continue;
    }
    if (!dayMatches(cron, t)) {
      t.setDate(t.getDate() + 1);
      t.setHours(0, 0, 0, 0);
      continue;
    }
    if (!cron.hour.has(t.getHours())) {
      t.setHours(t.getHours() + 1, 0, 0, 0);
      continue;
    }
    if (!cron.minute.has(t.getMinutes())) {
      t.setMinutes(t.getMinutes() + 1, 0, 0);
      continue;
    }
    return t.getTime();
  }
  throw new CronParseError("cron expression has no firing within the scan horizon");
}

/** The largest cron firing STRICTLY LESS than `beforeMs` (local time), in
 *  ms-since-epoch. PURE. Mirror of `nextAfter` with month/day/hour fast-REWIND. Throws
 *  if no earlier firing exists within ~4 years. */
export function prevBefore(cron: ParsedCron, beforeMs: number): number {
  const t = new Date(beforeMs);
  t.setSeconds(0, 0);
  t.setMinutes(t.getMinutes() - 1); // strictly before `beforeMs`
  for (let i = 0; i < MAX_SCAN_ITERS; i++) {
    if (!cron.month.has(t.getMonth() + 1)) {
      // Jump to the last minute of the previous month.
      t.setDate(1);
      t.setHours(0, 0, 0, 0);
      t.setMinutes(t.getMinutes() - 1);
      continue;
    }
    if (!dayMatches(cron, t)) {
      // Jump to 23:59 of the previous day.
      t.setHours(0, 0, 0, 0);
      t.setMinutes(t.getMinutes() - 1);
      continue;
    }
    if (!cron.hour.has(t.getHours())) {
      // Jump to :59 of the previous hour.
      t.setMinutes(0, 0, 0);
      t.setMinutes(t.getMinutes() - 1);
      continue;
    }
    if (!cron.minute.has(t.getMinutes())) {
      t.setMinutes(t.getMinutes() - 1, 0, 0);
      continue;
    }
    return t.getTime();
  }
  throw new CronParseError("cron expression has no earlier firing within the scan horizon");
}

// A safety bound on the skip loop (it always terminates because A grows without bound
// while gap is bounded by the max cadence, so eventually A − C > gap/2 — but guard
// against a pathological cron anyway).
const MAX_SKIP_ITERS = 4096;

/** The persisted per-schedule timing state. `armedAt` = when the schedule was first
 *  enabled/loaded (ms; the never-ran anchor). `lastCompletionAt` = when its most
 *  recent run's split CLOSED (ms; undefined ⇒ never ran). `paused` = user muted it
 *  (vacation). All persisted in the queue store so cadence survives a restart. */
export interface ScheduleState {
  armedAt: number;
  lastCompletionAt?: number;
  paused?: boolean;
  /** (restart re-adoption) The host `sessionID` of the schedule's CURRENTLY-LIVE scan split,
   *  when one is in flight; absent/0 when not running. PERSISTED so a GUI restart (which wipes
   *  the in-memory `queueSchedule`/`scheduleId` annotation the sidecar normally re-adopts from)
   *  can still recognize the surviving scan by its stable sessionID, mark it running again, and
   *  re-stamp its annotation — instead of showing "not running" and re-dispatching a duplicate.
   *  Backfilled from the live surface each sweep (a fresh spawn's id attaches asynchronously, so
   *  it may start 0), cleared on completion. */
  activeSessionID?: number;
}

/**
 * The ms-since-epoch at which the NEXT run of this schedule should start. PURE +
 * deterministic. See the module header for the model:
 *   - never ran (no `lastCompletionAt`) → first firing at-or-after `armedAt`, NO skip;
 *   - ran → the half-of-local-gap skip from `lastCompletionAt`.
 * The runner treats the schedule as DUE when `now >= computeNextStart(...)`. Because
 * the result depends only on persisted anchors (not a volatile `now`), it is stable
 * across sweeps until the schedule next completes.
 */
export function computeNextStart(cron: ParsedCron, state: ScheduleState): number {
  const { armedAt, lastCompletionAt } = state;
  if (lastCompletionAt === undefined) {
    // Never ran: first firing at-or-after arm time (nextAfter of arm−1ms yields the
    // firing at or after armedAt, since firings land on minute boundaries).
    return nextAfter(cron, armedAt - 1);
  }
  // Completed: skip forward to the first firing that leaves at least half the local
  // gap of rest after completion.
  let a = nextAfter(cron, lastCompletionAt);
  for (let i = 0; i < MAX_SKIP_ITERS; i++) {
    const prev = prevBefore(cron, a);
    const gap = a - prev;
    if (a - lastCompletionAt > gap / 2) return a;
    a = nextAfter(cron, a);
  }
  return a;
}

/** Convenience: is the schedule DUE to fire at `nowMs` (given it is not paused and has
 *  no run in flight — those gates live in the runner)? PURE. */
export function isDue(cron: ParsedCron, state: ScheduleState, nowMs: number): boolean {
  return nowMs >= computeNextStart(cron, state);
}

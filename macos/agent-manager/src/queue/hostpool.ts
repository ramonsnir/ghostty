// (ramon fork / cloud-hosts, Phase 5) Per-queue MULTI-HOST load balancing — the PURE
// weighted-least-loaded host selector + its types. See CLOUD-QUEUE-BALANCING.md.
//
// A queue's single `host` becomes a weighted host POOL: the supervisor spreads a queue's
// AGENT splits across N boxes by CAPACITY. Placement is a pure function of current
// occupancy — `argmin(activeOnHost / (maxConcurrent × weight))` over hosts with a free
// slot — so a post-restart sweep re-derives identical loads (from the already-persisted
// `Assignment.hostName`) and makes identical placements with ZERO new persisted selection
// state (no rotation cursor, unlike weighted round-robin). A full/down host is simply not a
// candidate, so work routes to the emptiest live box; when NO host has a free slot the item
// WAITS (the caller attributes a `hostCapacity` block reason), never a silent stall.
//
// TOTALLY PURE: no registry, no clock, no I/O — the load map + pool are the only inputs, so
// the selector is exhaustively unit-testable (hostpool.test.ts). This module imports NOTHING
// from the rest of the queue (normalizeHostPool takes a structural `{host?, hosts?}` so there
// is no import cycle with types.ts, which owns `QueueTemplate`).

/**
 * One host in a queue's pool. The PRIMARY knob is `maxConcurrent` (a bigger box gets
 * proportionally more agents); `weight` is an OPTIONAL capacity-independent bias.
 *
 * Back-compat: the implicit entry synthesized for a scalar/omitted `host` carries
 * `maxConcurrent = +Infinity`, so a not-yet-migrated template is bounded ONLY by the
 * existing per-run `concurrency`/`max-total`/`maxItems` gates — byte-identical to today.
 */
export interface HostSpec {
  /** Registry host name; reserved "local" = the laptop's `pty-host`. REQUIRED. */
  name: string;
  /** OPTIONAL capacity-independent bias, default 1; must be > 0 (0 would divide by zero).
   *  Multiplied INTO the effective-capacity denominator, so weight 2 halves per-slot cost
   *  (leans placement toward the box beyond its raw slot count). */
  weight?: number;
  /** Concurrent-agent cap on THIS box for THIS queue — the PRIMARY knob. A positive int for
   *  an explicit pool entry; `+Infinity` for the implicit scalar/omitted-`host` entry. */
  maxConcurrent: number;
  /** OPTIONAL per-host LIFETIME dispatch budget. FORWARD-COMPAT in v1: the selector honors it
   *  (a host with `lifetime >= maxItems` drops out of selection), but the runner passes
   *  `HostLoad.lifetime = 0` in v1 (concurrency-only — per-host lifetime is not reconstructible
   *  from live occupancy, so it needs a persisted counter, deferred to v1.1). */
  maxItems?: number;
}

/** Current occupancy of ONE host, fed to `selectHost`. A missing map entry defaults to
 *  `{active:0, lifetime:0}` (an empty host). */
export interface HostLoad {
  /** Live agents currently on this host (FLEET-WIDE, across every queue — a box is shared,
   *  same argument as the fleet-wide `agent-queue-hero-max`). */
  active: number;
  /** Lifetime dispatches to this host. v1: always 0 in the runner (per-host `maxItems` is
   *  concurrency-only in v1); present for the selector's forward-compat + its unit tests. */
  lifetime: number;
}

/** Options for `selectHost`. */
export interface SelectHostOpts {
  /** Host names to SKIP entirely, regardless of load. Used for the DOWN-HOST fallback: a box
   *  whose tunnel is down (discovered at spawn time) is cooled for a backoff window and
   *  excluded here so the next sweep routes to a healthy box. Not distinguishable from load
   *  (there is no readiness wire), so it is an explicit skip set. */
  exclude?: ReadonlySet<string>;
}

/**
 * Normalize a template's host declaration into the always-present pool the runtime consumes.
 * PURE. Accepts EITHER the scalar `host` OR the explicit `hosts[]` array:
 *   - `hosts[]` present + non-empty → those entries (weight defaulted to 1; a non-positive /
 *     non-finite `maxConcurrent` from an unvalidated literal falls back to +Infinity, though
 *     `validateHostPool` guarantees a positive int for a loaded template);
 *   - otherwise → a SINGLE implicit entry `{ name: host || "local", weight: 1,
 *     maxConcurrent: +Infinity }`, so a scalar/omitted template is a single UNBOUNDED-capacity
 *     pool — byte-identical to the pre-pool behavior (the only limiter stays the per-run
 *     concurrency/max-total/maxItems gates).
 * Every runtime consumer reads THIS (never the raw `host`/`hosts` union), so a half-migration
 * (a `hosts` array present but a reader still keying off scalar `host`) can't route everything
 * to `local` silently.
 */
export function normalizeHostPool(t: {
  host?: string;
  hosts?: ReadonlyArray<HostSpec>;
}): HostSpec[] {
  if (Array.isArray(t.hosts) && t.hosts.length > 0) {
    return t.hosts.map((h) => ({
      name: h.name,
      weight: typeof h.weight === "number" && h.weight > 0 ? h.weight : 1,
      maxConcurrent:
        typeof h.maxConcurrent === "number" && h.maxConcurrent > 0
          ? h.maxConcurrent
          : Number.POSITIVE_INFINITY,
      ...(typeof h.maxItems === "number" && h.maxItems > 0 ? { maxItems: h.maxItems } : {}),
    }));
  }
  const name = typeof t.host === "string" && t.host.length > 0 ? t.host : "local";
  return [{ name, weight: 1, maxConcurrent: Number.POSITIVE_INFINITY }];
}

/**
 * WEIGHTED-LEAST-LOADED placement. PURE. Returns the chosen host NAME, or `null` when NO host
 * has a free slot (⇒ the item WAITS on `hostCapacity`).
 *
 * Algorithm — argmin over `pool` in DECLARATION ORDER, keeping the running best with a STRICT
 * `<`:
 *   1. CANDIDACY (free-slot predicate, independent of score): `h` is a candidate iff
 *      `active(h) < h.maxConcurrent` AND (`h.maxItems === undefined || lifetime(h) < h.maxItems`)
 *      AND `!exclude.has(h.name)`.
 *   2. SCORE on candidates: `active(h) / (h.maxConcurrent × weight)`. `maxConcurrent` is the
 *      primary knob; `weight` (default 1) is multiplied INTO the denominator (weight 2 halves
 *      per-slot cost). A `+Infinity` `maxConcurrent` (scalar back-compat) scores 0 for any
 *      finite `active`, so it always wins its singleton — correct.
 *   3. argmin(score); its name, or `null` if there were no candidates.
 *
 * TIE-BREAK (fully deterministic): equal scores (notably an all-empty pool = every score 0)
 * resolve to the FIRST-DECLARED candidate — falling out of iterating `pool` in order + updating
 * `best` ONLY on strict `<`. The winner is a function of ONLY (a) pool order and (b) the load
 * map — NEVER Map iteration/insertion order. So a post-restart sweep, re-deriving the same load
 * from `Assignment.hostName`, makes the SAME placement (restart-identical, no persisted cursor).
 */
export function selectHost(
  pool: ReadonlyArray<HostSpec>,
  load: ReadonlyMap<string, HostLoad>,
  opts: SelectHostOpts = {},
): string | null {
  const exclude = opts.exclude;
  let best: { name: string; score: number } | null = null;
  for (const h of pool) {
    if (exclude !== undefined && exclude.has(h.name)) continue;
    const l = load.get(h.name) ?? { active: 0, lifetime: 0 };
    // Candidacy (free-slot) predicate, independent of score.
    if (l.active >= h.maxConcurrent) continue; // concurrency full (never true for +Infinity cap)
    if (h.maxItems !== undefined && l.lifetime >= h.maxItems) continue; // lifetime budget spent
    const weight = typeof h.weight === "number" && h.weight > 0 ? h.weight : 1;
    // effective capacity = maxConcurrent × weight; +Infinity denom ⇒ score 0 for finite active.
    const score = l.active / (h.maxConcurrent * weight);
    if (best === null || score < best.score) best = { name: h.name, score };
  }
  return best === null ? null : best.name;
}

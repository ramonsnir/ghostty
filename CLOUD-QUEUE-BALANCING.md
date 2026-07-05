# Per-queue multi-host load balancing — a queue's `host` becomes a weighted host POOL

Status: **DESIGN + build-ready plan (Phase 5 of cloud-hosts).** Cloud-hosts Phases 1–4 are
implemented + committed at this checkout — a per-queue scalar `host` already places an Agent Queue's
AGENT splits on ONE remote box (provider laptop-side, agent cloud-side), with `Assignment.hostName`
persisted + re-adopted by the `(hostName, sessionID)` pair. This doc turns that single `host` field
into a **weighted host POOL** and spreads a queue's agents across the pool by **weighted-least-loaded**
placement. It is a **peer companion** to `CLOUD-HOSTS-DESIGN.md` (which owns the transport / identity /
reconnect / cross-host-agent story — see its **OQ3** "per-queue host" resolution). Read that first.
The agreed design is refined + grounded, not re-litigated. Every claim about *current* behavior is
grounded in the code at HEAD (citations are `file:line` / `file:symbol`).

**Scope in one line:** sidecar (`macos/agent-manager/src/queue/`) + a small Swift render/decode touch.
**NO host change, NO protocol/wire change** — placement is chosen from already-persisted occupancy
(`Assignment.hostName`) and delivered through the EXISTING `spawn_split_command` `host` arg
(`mcp.ts:317-341`); the only Zig touch is (optionally) a config key + its Swift getter, which is a
lib/xcframework rebuild, never a `ghostty-host` restart.

---

## Summary / motivation

Today an Agent Queue template targets exactly **one** host: `QueueTemplate.host?: string`
(`queue/types.ts:278`, default `"local"`). Every agent the queue dispatches lands on that single box —
`dispatchOne` reads `const templateHost = t.host ?? "local"` (`runner.ts:1751`) and threads it into the
pending record's `hostName` (`runner.ts:1762`) + the spawn `host` arg (`runner.ts:1823`). Phase 4 made a
queue's agents run on **a** cloud box; it did not let a queue spread across **several** boxes. If you own
two or three cloud boxes you must run three separate queues and hand-balance them — the supervisor can't
fill a fleet.

**Goal:** let a single queue declare a **pool** of hosts and let the deterministic engine FILL it. A pool
entry carries a per-host **`maxConcurrent`** (concurrent-agent cap — the primary knob) + an optional
**`weight`** (a capacity-independent bias) + an optional **`maxItems`** (per-host lifetime budget). New
agents are placed by **weighted-least-loaded selection**: dispatch each item to the pool host that
minimizes `activeOnHost / (maxConcurrent × weight)` among hosts with a free slot. A host with no free
slot (or a down tunnel) makes the item **WAIT** with a new `hostCapacity` block reason (reusing the hero
`blockReasons` + health-dropdown UI), never a silent stall or a blank pane.

The enabling facts that make this cheap: (1) placement is a decision about WHERE an agent runs, which
slots in at the single site `runner.ts:1751`, downstream of every existing admission gate; (2) per-host
occupancy is reconstructable for free from the **already-persisted** `Assignment.hostName`
(`types.ts:406-413`; reconcile rebuilds `run.active` from it at `runner.ts:901`), so restart-safety needs
almost no new state; (3) `spawn_split_command` already takes an optional `host` arg (`mcp.ts:317-341`), so
no new MCP tool and no host/protocol change.

**Why weighted-least-loaded, not weighted round-robin (WRR):** least-loaded is a **pure function of
current occupancy** — `argmin(active/(cap·weight))` — and that occupancy is *already reconstructed for
free every sweep*. So a post-restart sweep re-derives identical loads and makes identical placements with
**zero new persisted selection state** (no rotation cursor, unlike WRR). It degrades gracefully by
construction — a full/down host isn't a candidate, so work routes to the emptiest live box, where WRR
would keep handing a saturated/down host its "turn". And it maximizes real utilization: capacity is the
knob the operator cares about, so "fill the box with the most free slots" is the right primitive.

---

## Goals

- One queue declares N hosts (a POOL); the supervisor spreads its agents across them by capacity.
- Placement is **deterministic** and **restart-identical** (same occupancy ⇒ same placement, before and
  after a GUI/sidecar restart), with no LLM and no new persisted selection state.
- `maxConcurrent` is the primary knob (a bigger box gets proportionally more agents); `weight` is an
  OPTIONAL bias **decoupled** from raw capacity (weight 2 leans placement toward a box beyond its slot
  count). Optional per-host `maxItems` bounds lifetime dispatches to a box and drops it from selection
  once spent.
- A full pool / down box makes the item **WAIT** with a clear, attributed `hostCapacity` reason — never
  misattributed to `concurrency`/`maxItems`, never a blank/garbage agent.
- **Back-compat is byte-identical:** a scalar `host: "cloud-1"` (or omitted) keeps working as a
  single-entry pool; `Assignment.hostName` keeps its omit-when-`"local"` serialization; existing
  persisted state round-trips unchanged.
- Restart-safe with **zero** new persistence for the concurrency cap (rides `Assignment.hostName`); only
  the optional per-host `maxItems` needs one new persisted counter.
- Heroes and schedules pick a pool host by the SAME selector without breaking their existing accounting
  (hero "promotion never blocks"; schedule bypasses all caps).
- A down/unreachable box **degrades gracefully** — the item routes to a live box, and a persistently dead
  box is quarantined rather than repeatedly hammered.

## Non-goals (explicit)

- **NO live-migration of a running agent between hosts.** A session is pinned to the box it spawned on
  (`CLOUD-HOSTS-DESIGN.md` → Non-goals). Placement decides only where a *new* agent starts.
- **NO Ghostty-owned capacity model beyond the declared caps.** Ghostty never probes a box's real
  CPU/RAM/GPU headroom; capacity is exactly what the template DECLARES. The engine FILLS declared
  capacity, it does not discover it.
- **NO cross-host scheduler policy beauty.** No bin-packing objective, no cost model, no fairness/priority
  scheduler, no preemption, no item→host affinity. The provider/config declares capacity; the engine
  deterministically fills it with a single argmin. WRR and rotation cursors are explicitly out.
- **NO new MCP tool and NO new protocol/host change.** The pool rides the existing `spawn_split_command`
  `host` arg and the existing `report_queue_status` path.
- **NO SSH preflight of the working set.** The "repo/`{templateDir}`/cwd exists on every pool host"
  precondition is doc-only + runtime-degrade — there is no sidecar→box filesystem probe.

---

## The agreed design (weighted-least-loaded, capacity-primary, optional weight)

A queue's `host` becomes `host: string | HostPoolEntry[]`. The parsed template carries an internal,
always-present normalized `hostPool: HostPoolEntry[]`; every runtime consumer reads `hostPool`, never
the raw union.

```ts
export interface HostPoolEntry {
  name: string;          // registry host name; reserved "local" = the laptop pty-host
  weight: number;        // OPTIONAL bias, default 1; must be > 0 (0 divides by zero)
  maxConcurrent: number; // concurrent-agent cap on THIS box for THIS queue; the PRIMARY knob
  maxItems?: number;     // OPTIONAL per-host lifetime dispatch budget (see the v1 scoping note)
}
```

**Normalization (at load, `templates.ts`):**
- scalar `host: "x"` (or omitted) → `[{ name: "x" | "local", weight: 1, maxConcurrent: +Infinity }]`.
  The implicit entry's `maxConcurrent` is **unbounded**, so a scalar/omitted template is bounded ONLY by
  the existing per-run `concurrency`/`max-total`/`maxItems` gates — **byte-identical** to today.
- explicit array entry → `maxConcurrent` REQUIRED (positive int); `weight` default 1; `maxItems` optional
  positive int.

### The pure selector — `macos/agent-manager/src/queue/hostpool.ts` (NEW)

```ts
export interface HostLoad { active: number; lifetime: number; }

/** Chosen host NAME, or null when NO host has a free slot (⇒ the item WAITS on `hostCapacity`).
 *  TOTALLY PURE: no registry, no clock, no I/O. `pool` is the already-normalized array. `load`
 *  maps host name → current occupancy; a missing entry defaults `{active:0, lifetime:0}`. */
export function selectHost(
  pool: ReadonlyArray<HostPoolEntry>,
  load: ReadonlyMap<string, HostLoad>,
  exclude?: ReadonlySet<string>,   // hosts to skip (down-host fallback)
): string | null;
```

**Algorithm — weighted-least-loaded argmin, iterating `pool` in DECLARATION ORDER, keeping the running
best with a STRICT `<`:**
1. **Candidacy (free-slot) predicate**, independent of score: `h` is a candidate iff
   `active(h) < h.maxConcurrent` AND (`h.maxItems === undefined || lifetime(h) < h.maxItems`) AND
   `!exclude.has(h.name)`. "Tunnel down" is NOT distinguishable here (no readiness wire); it is
   discovered at spawn time and added to `exclude` by the fallback below.
2. **Score on candidates:** `score(h) = active(h) / (h.maxConcurrent × h.weight)`. `maxConcurrent` is the
   PRIMARY knob; `weight` is multiplied INTO the effective-capacity denominator (weight 2 halves per-slot
   cost), decoupled from raw slot count (default 1 ⇒ pure `active/capacity`). `+Infinity` `maxConcurrent`
   (scalar back-compat) scores 0 for any finite `active`, so it always wins its singleton — correct.
3. **argmin(score);** return its name, or `null` if there were no candidates.

**Tie-break (fully deterministic):** equal scores (notably an all-empty pool = every score 0) resolve to
the **FIRST-DECLARED candidate**, falling out of iterating in order + updating `best` only on strict `<`.
The winner is a function of ONLY (a) pool order and (b) the load map — NEVER Map iteration order,
insertion order, or name sort. `weight` already lives in the score, so it is not a second tie-break key.

### Greedy within-sweep occupancy — the load map is LIVE, not a stale snapshot

`selectHost` MUST be evaluated **per `dispatchOne`**, reading a load map that reflects the prior
dispatch's placement — never once per sweep. `dispatchCandidates` dispatches a BATCH in the
`runner.ts:1673-1684` loop; a single pre-loop snapshot would resolve every candidate to the same argmin
host and overshoot `maxConcurrent`. Mirror the existing correct pattern: `dispatchOne` recomputes
`gridOccupancy(run)` fresh each call (`runner.ts:1726`), relying on the SYNCHRONOUS
`run.active.set(item.key, pending)` at `runner.ts:1772` (before the spawn `await`) so dispatch N sees N−1.

**All hosts full ⇒ WAIT (no side effects).** When `selectHost` returns `null`, `dispatchOne` returns
`false` WITHOUT seating: no `run.active.set`, no `run.lifetimeDispatched += 1` (`:1774`), no
`run.dispatched` latch (`:1780`), no per-host counter bump — mirroring the existing `slot === null` early
return at `runner.ts:1735` (correctly BEFORE the mutations at `:1772-1780`). DISTINCT from the
spawn-failure rollback at `:1863-1869` (which unwinds an already-applied latch). Hoisting the pick lets the
caller skip `deps.budget.tryAcquire()` on a null result (`:1673-1684`) so a full pool doesn't waste the
per-sweep batch budget.

---

## Grounded insertion points (the real file:lines)

| # | Where | Current (verified) | Change |
|---|---|---|---|
| 1 | `types.ts:278` `host?: string` | scalar, default `"local"` | overload `string \| HostPoolEntry[]`; add internal `hostPool` |
| 2 | `types.ts:337-341` `BlockReason` | `maxItems\|queueConcurrency\|globalConcurrency\|heroSlots` | add `"hostCapacity"` |
| 3 | `types.ts:396-433` `Assignment.hostName?` (`:413`) | persisted, omit-when-`"local"` | UNCHANGED — records the CHOSEN entry name |
| 4 | `templates.ts:116/164-166/186-204` `validateTemplate` host trio | `optNonEmptyStringOrDefault(rec.host,"local",…)` | replace with pure `validateHostPool` |
| 5 | `templates.ts:218` `validateSchedules` | field-drop chokepoint pattern | template for `validateHostPool` (whitelist or silently dropped) |
| 6 | `runner.ts:1751-1755` `templateHost = t.host ?? "local"` | fixed scalar read | replace with SELECTED host; cwd/templateDir flow unchanged |
| 7 | `runner.ts:1762` pending `hostName: templateHost` | dispatch host on the Assignment | record SELECTED host (restart occupancy) |
| 8 | `runner.ts:1772` `run.active.set(...)` (sync, pre-spawn) | within-sweep dedup | per-host tally increment rides this point |
| 9 | `runner.ts:792` `regularOccupancy` | pure per-run fold | template for `perHostOccupancy(run)` by `hostName` |
| 10 | `runner.ts:832` `totalHeroActiveRegistry` | pure fleet-wide fold | template for `totalActiveOnHostRegistry → Map<string,HostLoad>` |
| 11 | `runner.ts:639/646` seed gates; `:663-664` decrement | fleet gates seeded once + threaded | seed mutable `hostActive` + thread runOne→dispatchCandidates→dispatchOne |
| 12 | `runner.ts:1537-1689` gate stack; `:1673-1684` loop | eligibility → `selectCandidates` → per-item | call `selectHost` per candidate; null ⇒ skip budget + `hostCapacity` |
| 13 | `runner.ts:1726-1735` `lowestFreeSlot`/`slot===null` | post-eligibility placement step | host gate is a SIBLING placement gate; null ⇒ same clean early-return |
| 14 | `runner.ts:1855`/`:1863-1869` spawn + rollback | throw → unwind (key NOT cooled) | down-host fallback: `exclude` + re-`selectHost`; else roll back + cool HOST |
| 15 | `runner.ts:936-947` `no-pty-host` self-disable (whole run) | session-0-past-grace disables RUN | scope to `hostName === "local"` — remote session-0 must NOT wedge run |
| 16 | `runner.ts:1141-1179` status-input build | builds `QueueStatusInputs` | add `anyHostHasFreeSlot`, fed from the SAME pure helper |
| 17 | `status.ts:99-163/245-275/284-302` `blockReasonsFor` | gate↔attribution mirror | add `hostCapacity` input + regular-branch push (after other gates clear) |
| 18 | `runner.ts:2233-2281` `dispatchSchedule` | pins to scalar host | pick via `selectHost`; count `maxConcurrent`; defer when full |
| 19 | `store.ts:554-579/451-471/900` persist/adopt hostName | already persisted + ADOPT-stamped | UNCHANGED — occupancy reconstructs free; orphan-adopt already stamps hostName (`:900`) |
| 20 | `mcp.ts:237-254` `reportQueueStatus`; `:317-341` spawn `host` | wire chokepoint | forward per-host `hosts[]` status (matched Swift pair); spawn arg UNCHANGED |
| 21 | `supervisor.ts:126-134` `remainingSlots`; `runner.ts:462` `effectiveConcurrency` | run-level concurrency gate | LEAVE UNCHANGED — host cap is orthogonal, never folded into `slots` |

**Two facts the grounded code already gives us (no work needed):**
- **Restart occupancy reconstruction is FREE.** `Assignment.hostName` persists non-local (`store.ts:578`,
  `:467-468`), rehydrates into `run.active` (`runner.ts:901`), and the reconcile ORPHAN-ADOPT already
  stamps `hostName` from the `list_surfaces` row (`store.ts:900`, gated on `!== "local"`). The
  "reconcile must stamp hostName onto a survivor" hazard is ALREADY satisfied.
- **The dispatch host already flows correctly.** `:1751` → `:1762` (persist) → `:1823` (spawn); replacing
  the ONE `templateHost` value flows to both with no other edit inside `dispatchOne`. The `:1863-1869`
  rollback is the reusable shape for the down-host fallback.

---

## The down-host failure mode (the #1 design risk) — grounded + mitigated

Least-loaded targets the emptiest host, and a down box looks emptiest (`active===0` ⇒ lowest score). The
sidecar has NO tunnel-health signal (readiness lives GUI-side in
`RemoteTunnelController.readinessPublisher`/`handshaked`, never crosses to TS — the READINESS GAP).
Worse, a spawn to a DOWN remote box does NOT throw: Phase-1's deferred-dial creates a placeholder
`SurfaceView` ("Connecting to <host>…") and `spawn_split_command` returns `{id, sessionId:0}` — a SUCCESS
with session 0 (only a registry miss / genuine error yields `mcp.ts:346`'s `!id → McpError`). So naively:
(1) argmin routes the FIRST items to the down box; (2) the placeholder "succeeds" → `run.active.set` +
`run.lifetimeDispatched += 1` (`:1772-1774`) burns maxItems into blank panes; (3) past the grace window
reconcile classifies the session-0 surface `no-pty-host` and self-disables the WHOLE run (`:936-947`).

The build MUST fix this. Three changes, NONE needing a new wire (v1 minimum), + one recommended:
1. **Host-scope the `no-pty-host` self-disable (`runner.ts:936-947`)** to `hostName === "local"` only — a
   remote deferred-dial session-0 is expected/transient and must NOT wedge the run.
2. **Treat a stuck remote session-0 as a HOST-SCOPED failure:** past grace, roll it back like a spawn
   failure (delete `run.active`, decrement `lifetimeDispatched` — mirror `:1865`, drop the latch, leave
   the KEY uncooled) AND add its host to a per-run **host cooldown** so `selectHost` excludes it for a
   backoff window. Releases the burned maxItems + fails the item over to a healthy box.
3. **Down-host fallback on the spawn throw (`:1855-1872`):** in the catch, add the host to a local
   `exclude`, re-`selectHost`, retry within the same `dispatchOne`; if none remain, roll back fully + cool
   the host.

**The per-run host cooldown is the load-bearing mitigation for the "down-host magnet" blocker** (model on
the existing item-level `run.cooldown`, `:933`/`:972-974`). **RECOMMENDED enhancement (v1.1, still no
host/protocol change):** a `hosts[]` readiness array from `RemoteTunnelController.handshaked` forwarded on
the EXISTING `report_queue_status` path, letting `selectHost` pre-emptively `exclude` an unhandshaked box
(a Swift→sidecar wire on an existing report — NOT a new tool/protocol). v1 works via cooldown +
session-0 rollback; v1.1 makes the degrade instantaneous instead of one-placement-late.

---

## Accounting: per-host cap position, heroes, schedules

**Gate ordering — the per-host cap is an ADDITIONAL orthogonal PLACEMENT gate, LAST.** Existing
eligibility gates are all COUNT gates feeding `selectCandidates` (`runner.ts:1551-1660`); grid placement
is ALREADY a separate post-eligibility step (`lowestFreeSlot`, `:1726-1735`). Order per sweep/item:
(1) run `maxItems` (`:1560-1562`, UNCHANGED); (2) hero split (`:1627-1628`, UNCHANGED); (3) eligibility →
`selectCandidates` batch (regular `remainingSlots(...)` `:1551-1552`+`supervisor.ts:126-134`; hero
`heroRemaining` `:1633-1644`, UNCHANGED); (4) NEW per-host argmin placement gate. **Do NOT fold the host
cap into `slots`** — eligibility answers "may this queue launch"; the host gate answers "is there a box to
seat it" (over-selection wastes a few loop iterations, `if (ok) regular += 1` `:1683` excludes it;
under-selection cannot occur). **Keeping run `concurrency` as the queue-wide ceiling ALSO protects the
grid** (`effectiveConcurrency` `:462` drives both the count AND `maxPanes` `:465-466`), so per-host caps
only SHARD it; Σ caps < concurrency surfaces as `hostCapacity` waits, never grid overflow.

**Per-host `maxConcurrent` occupancy is FLEET-WIDE** (a box is shared across queues — same argument as
fleet-wide `agent-queue-hero-max`; per-run counting would seat 6 on a box two queues each declare
`maxConcurrent:3` for). Add pure `totalActiveOnHostRegistry(registry): Map<string,HostLoad>` modeled on
`totalHeroActiveRegistry` (`:832-836`): fold every run's `run.active` (where `occupiesSlot`) + every
`run.scheduleActive` by `hostName ?? "local"` — count EVERY physical pane (regular+hero+schedule); the
box's CPU/RAM ignores the grid/attention abstraction. Seed the mutable map ONCE per sweep beside
`globalRemaining`/`heroRemaining` (`:639/646`), thread it through `runOne`→`dispatchCandidates`→
`dispatchOne`, INCREMENT `hostActive[chosen].active` at the synchronous seat (`:1772`). The increment (vs.
the coarse across-run decrement `:663-664`) is REQUIRED: per-host granularity within one run's loop is
finer, and other runs seat the same box this sweep.

**Heroes count against `maxConcurrent` but hero placement NEVER hard-blocks.** Heroes are counted in
`totalActiveOnHostRegistry` (real capacity), pick their host via the same `selectHost` (`:1676`, dispatched
first). "Promotion never blocks" is PRESERVED for free — `runPromote` mutates in place and never
re-places, so it never touches the host gate. A fresh hero DISPATCH with every box full surfaces
`hostCapacity` (honest — nowhere to run).

**Schedules count against `maxConcurrent` but BYPASS per-host `maxItems`, and DEFER (not block) when
full.** A schedule's scan agent uses the box's CPU/RAM (bucketed from `run.scheduleActive`), picks via
`selectHost` (matches today's `:2231-2233`), and if no host has a free slot simply defers this sweep
(single-flight tolerates delay) — no waiting/held blockReason (schedules are their own lane).

**Per-host `maxItems` — RECOMMENDED SCOPED OUT of v1; no half-measure.** Per-host lifetime is NOT
reconstructible from live occupancy, so it needs a NEW persisted `run.lifetimeDispatchedByHost` map
mirroring `lifetimeDispatched` at EVERY site (bump `:1774`, roll back `:1865` + the session-0 rollback,
persist in `store.ts`, MAX-rehydrate `:877-878`, floor `:918-919`). No valid non-durable half-measure.
Because "capacity is the primary knob" and this repeats the subtle counter bugs already fixed on
`lifetimeDispatched`, **v1 ships concurrency-only** (`HostLoad.lifetime` stays in the signature for
forward-compat). **OPEN sub-decision for plan review:** ship the persisted map in v1 OR defer to v1.1 —
never a non-durable counter. NOTE: a per-host cap also bounds UNOBSERVABLE per-box billing
(`CLOUD-HOSTS-DESIGN.md` OQ6), the main argument to ship it sooner; the `hosts[]` array should surface
per-box dispatch counts.

---

## `hostCapacity` attribution (the gate↔attribution mirror)

Add `"hostCapacity"` to `BlockReason` (`types.ts:337-341`); compute it ONLY for an item that ALREADY
cleared its pool's other gates — regular:
`regularMaxItemsRemaining>0 ∧ regularConcurrencyRemaining>0 ∧ regularGlobalRemaining>0`; hero:
`heroRemaining>0` — AND no pool host has a free slot. This preserves the `heroSlots` discipline
(`status.ts:245-275`): never tell the operator to bump `maxItems`/`concurrency` when the real block is a
full box. Add `anyHostHasFreeSlot` (or a per-host `hostRoom` map) to `QueueStatusInputs` (`:99-163`); push
in `blockReasonsFor` (`:256-275`) after the other pushes. **Feed the dispatcher's argmin AND the status
attribution from ONE shared pure helper** (`runner.ts:1141-1179` builds inputs from the same primitives —
keep both fed from `totalActiveOnHostRegistry` + `selectHost`'s candidacy so the mirror can't drift,
`status.ts:135-139`). The `QueueBacklogCanvas.swift` `dashboardTooltip` explains "all pool hosts
full/down".

---

## Config schema + `validateHostPool` + back-compat

**Overload the EXISTING `host` key — NO second key.** `QueueTemplate.host: string | HostPoolEntry[]`; the
parsed template gains an internal always-present `hostPool: HostPoolEntry[]` (runtime reads THIS) and
keeps scalar `host?` = `hostPool[0].name` for single-entry so a not-yet-migrated `t.host ?? "local"` read
stays correct. `agentWorkdir`/`remoteTemplateDir` (`types.ts:283/289`) STAY template-level, the default
working set for every entry.

**A new pure `validateHostPool(rec.host, errors)`** replaces the scalar assembly at `templates.ts:164`+
`:188`, modeled on `validateSchedules` (`:218`) + the `validateProviderList` heroField chokepoint lesson
(un-whitelisted fields silently dropped): branch on `typeof rec.host` (undefined → single unbounded local
entry; string → single-entry unbounded; array → per-entry object validation; else error); per entry
whitelist EXACTLY `name` (req), `weight?` (>0, default 1), `maxConcurrent` (req positive int for explicit
entries, `posIntOrDefault`), `maxItems?` (positive int); DEDUP `name` with a `Set` (`:244` shape).
Reserved name `local` allowed.

**Back-compat (byte-identical):** scalar/omitted → single unbounded-`maxConcurrent` entry, so the only
limiter stays `concurrency`/`max-total`/`maxItems`. `Assignment.hostName` keeps omit-when-`"local"`
(`store.ts:578`,`:467-468`,`:900`). The HALF-MIGRATION hazard (loader stores an array but a reader treats
`t.host` as a string → `?? "local"` swallows the mismatch, routing everything to `local` silently) is why
the internal `hostPool[]` is consumed EVERYWHERE and the scalar is kept only as `hostPool[0].name`.

**The mirrored-working-set precondition (DOC-ONLY + runtime-degrade, NO preflight).** The working set
(repo/`{templateDir}`/cwd) must exist on EVERY pool host, but it is unenforceable at the sidecar (no
filesystem/readiness wire; a wrong-cwd `.client` spawn can fall back to `$HOME` and even report `done`).
So: document it LOUDLY (this doc + `AGENT-QUEUE.md` + a template comment) and enforce only the observable
failure (spawn throw / stuck session-0 → down-host fallback + host cooldown).

**Per-entry `workdir?`/`templateDir?` overrides — DEFERRED.** The `agent.command` `{templateDir}` TOKEN is
substituted at LOAD from ONE `remoteTemplateDir` (`wiring.ts substituteTemplateDir`); per-entry dirs would
force that token sub to MOVE to per-dispatch (touching `wiring.ts` + the delivery at `runner.ts:1810-1821`).
The mirrored-working-set precondition already assumes homogeneous layout, so **v1 uses template-level
`agentWorkdir`/`remoteTemplateDir` for every host** (byte-identical to today's single-host delivery,
`:1753-1755`,`:1810-1821`); per-entry overrides are a v1.1. Open sub-decision.

---

## Local-vs-cloud-box test boundary + scope note

Every new pure unit runs entirely in the local sidecar test suite (`*.test.ts`, `node --test`) — NO cloud
box. A cloud box is needed ONLY for the manual end-to-end smoke (real remote agents balancing), a
deployment check, not a unit test. **Sidecar + GUI-lib change: NO host, NO protocol, NO wire change** —
the `spawn_split_command` `host` arg (`mcp.ts:317-341`) + `report_queue_status` path (`:237-254`) already
exist; the only Zig touch (if a config key is added) is a lib/xcframework rebuild, never a host restart.

- **`hostpool.test.ts` (NEW, pure):** empty pool → first-declared; capacity-proportional spread via greedy
  recompute; `weight` bias flips argmin; all-full → null; strict-`<` determinism under SHUFFLED load-map
  insertion order; `exclude` skips a host; `maxItems` exhaustion excludes (forward-compat); `+Infinity`
  maxConcurrent always wins its singleton.
- **`templates.test.ts`:** `validateHostPool` — scalar/omitted → single unbounded; array whitelist + range
  checks (`weight<=0`/`maxConcurrent<=0` rejected); name-dedup; un-whitelisted field dropped.
- **`runner.test.ts` (fake `deps.client`):** two-queue-same-box fleet-wide cap (3 not 6); greedy
  within-sweep spread; argmin determinism + POST-RESTART identity (rebuild from `hostName` → identical);
  reconstruct-from-`hostName`; down-host spawn-throw fallback + cooldown; remote session-0-past-grace
  rolls back + does NOT self-disable the run; hero counts-against-box + promote-never-blocks; schedule
  counts-against-box + defers-when-full; all-full ⇒ WAIT with NO side effects (lifetimeDispatched
  unchanged over N sweeps); per-host maxItems persist/rehydrate/floor (or an explicit "scoped-out" test).
- **`status.test.ts`:** `hostCapacity` pushed ONLY after the other regular gates clear + no host room; NOT
  pushed when a host has room; hero-branch `hostCapacity`.
- **`store.test.ts`:** `hostName` round-trip (covered); pool-record round-trip if maxItems counters land.
- **Swift (GhosttyTests):** decode `hostCapacity` in `QueueStatus.Item.blockReasons` + render it
  (`QueueCommandBridge.swift` / `QueueBacklogCanvas.swift`); decode `hosts[]` if v1.1 ships; config-getter
  test if a key is added.

---

## Phased / task build-ready plan

### Phase 5.0 — Pure core (lands green, unused)
- **T1 `types.ts`:** `HostPoolEntry`; overload `host`; internal `hostPool`; `"hostCapacity"` in `BlockReason`.
- **T2 `hostpool.ts`+`hostpool.test.ts` (NEW):** `HostLoad`, `selectHost` with strict-`<` declaration-order tie-break.
- **T3 `templates.ts`:** `validateHostPool` replacing the scalar `host` assembly (`:164`/`:188`); normalize + whitelist + dedup; test.
- **T4 `runner.ts` pure helpers:** `perHostOccupancy(run)` (template `:792`) + `totalActiveOnHostRegistry(registry)` (template `:832`).

### Phase 5.1 — Wire placement into dispatch
- **T5** Seed + thread the mutable fleet `hostActive` map (`runSweep` `:639/646` → runOne → dispatchCandidates → dispatchOne).
- **T6 `dispatchOne` (`:1751`):** `selectHost(...)` replaces `templateHost` (flows to `:1762`+`:1823`); null → false with NO side effects (mirror `:1735`); increment `hostActive[chosen]` at `:1772`.
- **T7 loop (`:1673-1684`):** skip `budget.tryAcquire()` on null + surface `hostCapacity`.
- **T8 down-host:** host-scope self-disable (`:936-947`); remote session-0-past-grace rollback + per-run host cooldown; spawn-throw re-argmin (`:1863-1869`).
- **T9 `dispatchSchedule` (`:2233`):** `selectHost` pick; count `maxConcurrent`; defer when full.

### Phase 5.2 — Attribution + wire
- **T10 `status.ts`:** `anyHostHasFreeSlot` input (`:99-163`) + `hostCapacity` push in `blockReasonsFor` (`:256-275`) after the other gates.
- **T11 `runner.ts:1141-1179`:** feed it from the SAME `totalActiveOnHostRegistry` + pool caps the dispatcher uses.
- **T12 Swift:** carry+render `hostCapacity` in `QueueStatus.Item` (dropdown/tooltip). No new tool; `report_queue_status` already forwards `next[].blockReasons` (`mcp.ts:237-254`).

### Phase 5.3 — (optional)
- **T13 (v1.1, recommended):** `hosts[]` readiness from `RemoteTunnelController.handshaked` on `report_queue_status`; `selectHost` excludes unhandshaked.
- **T14 (v1.1, OPEN):** per-host `maxItems` persisted `run.lifetimeDispatchedByHost` (full mirror + tests) OR concurrency-only.

### Docs deltas (BLOCKING, same commit)
- **`AGENT-QUEUE.md`** → "Multi-host load balancing" subsection (schema, semantics, `hostCapacity`, precondition, down-host degrade, wiring+tests).
- **`CLAUDE.md`** → one-line bullet + wiring: "queue `host` is now a weighted host POOL; weighted-least-loaded argmin over per-host `maxConcurrent`; full pool ⇒ `hostCapacity`; sidecar+GUI-lib, no host/protocol change."
- **`CLOUD-HOSTS-DESIGN.md`** → refine **OQ3**: per-queue `host` now a POOL; fleet-wide per-host cap; readiness-gap degrade.
- **Example template** (NEUTRAL names only): two-host pool with `maxConcurrent`/`weight`, under `~/.config/ghostty-ramon/agent-manager/queues/`:
  ```jsonc
  { "name": "backlog",
    "host": [ { "name": "local", "maxConcurrent": 2 },
              { "name": "cloud-a", "maxConcurrent": 4, "weight": 1 },
              { "name": "cloud-b", "maxConcurrent": 4, "weight": 2 } ],
    "agentWorkdir": "/home/user/git/project-a",
    "remoteTemplateDir": "/home/user/git/project-a/.ghostty/queues",
    "concurrency": 8, "maxItems": 40 }
  ```

---

## Determinism + safety summary (folding in the critique)

- **Deterministic + restart-identical:** strict-`<` declaration-order tie-break; pick is a function of ONLY pool order + load map; occupancy reconstructs identically from `Assignment.hostName`. No persisted cursor.
- **No maxItems over-burn / no phantom latch:** null-`selectHost` returns before seat/latch/counter (mirror `:1735`); remote session-0-past-grace rolls back the counter (mirror `:1865`).
- **No same-sweep over-placement:** fleet `hostActive` map incremented at each synchronous seat (`:1772`), so dispatch N sees N−1.
- **Down host degrades, doesn't wedge:** host-scoped self-disable + per-run host cooldown + spawn-throw re-argmin; the `handshaked` `hosts[]` hint makes it pre-emptive.
- **Selected == recorded == spawned host:** one `selectHost` result flows to `:1762` + `:1823`, so the `(hostName, sessionID)` reconcile key never diverges.
- **Wire chokepoints honored:** `validateHostPool` whitelist; `hostCapacity` in BOTH TS `BlockReason` + Swift decode; `hosts[]` forwarded in `mcp.ts:237-254` if it ships — each a matched pair or it silently drops.

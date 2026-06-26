// (ramon fork / Agent Queue Supervisor) Durable assignment persistence + crash-safe
// dispatch ordering + restart RECONCILIATION (§9). The supervisor is the SINGLE
// OWNER of run state (§8): assignment records live ONLY here, persisted to the
// sidecar's own JSON file, matched across restarts by the STABLE `sessionID`.
//
// The load-bearing invariant (§9): after ANY restart — sidecar, GUI, or both — every
// still-running queue agent is RE-ADOPTED in its prior state with ZERO double-dispatch
// and ZERO orphaning. That holds because:
//   - persistence is keyed by `sessionID` (stable across a GUI relaunch; the surface
//     UUID is freshly minted each launch and is NOT a stable key);
//   - dispatch writes a PENDING record BEFORE the spawn and FINALIZES it after, so a
//     crash mid-dispatch is recoverable (a live surface carrying the queueKey
//     annotation but no finalized record is an ORPHAN we adopt, never re-dispatch);
//   - `reconcile` is a PURE function run every sweep (and a mandatory first pass
//     before any dispatch) that matches the persisted records against the live
//     `list_surfaces` snapshot and emits an explicit plan: keep-active, prune, adopt.
//
// I/O is an INJECTABLE SEAM (`StoreIO`) so tests use an in-memory impl, never real fs.
// `reconcile` and all classification helpers are PURE (no I/O, no own clock — `nowMs`
// is injected) and unit-tested directly. NOTHING here is Linear/Git/issue-key aware.

import type { Assignment, AssignmentState } from "./types.js";

// ---------------------------------------------------------------------------
// Persistence seam (§8/§9): a typed read/write JSON interface. Production wires
// it to node:fs; tests pass an in-memory impl so no real file is touched.
// ---------------------------------------------------------------------------

/** The injectable persistence seam. `read` returns the previously-written text (or
 *  null when the file is absent / first run); `write` replaces it atomically. Both
 *  may throw — the caller (loadStore / persistStore) maps a failure to a safe empty
 *  store / a logged-and-continue, never a crash into the loop. */
export interface StoreIO {
  read(): string | null;
  write(text: string): void;
}

/** The on-disk store shape. Versioned so a future migration is additive. The records
 *  are a flat list (the supervisor keys them by `sessionID` in memory).
 *
 *  `lifetimeDispatched` is the MONOTONIC count of total dispatches over the run's whole
 *  lifetime (§7) — the durable `maxItems` cap. It is a TOP-LEVEL field (NOT per-record)
 *  precisely because FINISHED/COOLDOWN records are pruned/removed, so a per-record count
 *  would forget completed dispatches that already consumed the budget. It is written on
 *  every persist and rehydrated on load, so a sidecar restart does not reset the cap. */
export interface StoreFile {
  version: 1;
  records: Assignment[];
  lifetimeDispatched: number;
  /** The DISPATCHED-LATCH key set (§7.1): every work-item key the run has dispatched and
   *  not yet re-armed. A key here is SUPPRESSED from re-dispatch until a SUCCESSFUL `list`
   *  no longer reports it (it left the actionable set — claimed/blocked/labeled/moved off
   *  the queried state) and it later reappears. Persisted so the suppression survives a
   *  sidecar/GUI restart — a kill BEFORE the agent claims its item (the item still in the
   *  list) must NOT be re-grabbed on the next sweep just because its key is still actionable.
   *  Additive (absent in a pre-upgrade file → an empty latch, the prior behavior). */
  dispatched: string[];
}

/** The current store schema version. */
export const STORE_VERSION = 1 as const;

/**
 * Parse the persisted store text into a record list. PURE + TOLERANT. A null/empty
 * input (first run), unparseable JSON, a wrong-shaped object, or a non-array
 * `records` all yield `[]` (a fresh store) — a corrupt file never crashes the loop;
 * the worst case is a one-time loss of adoption hints (reconciliation then treats
 * every live queue surface as an orphan to adopt, which is still correct + no
 * double-dispatch). Records missing required fields are dropped individually.
 */
export function parseStore(text: string | null): Assignment[] {
  if (text === null || text.trim().length === 0) return [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return [];
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    return [];
  }
  const recs = (parsed as { records?: unknown }).records;
  if (!Array.isArray(recs)) return [];

  const out: Assignment[] = [];
  for (const raw of recs) {
    const rec = coerceAssignment(raw);
    if (rec !== null) out.push(rec);
  }
  return out;
}

/** Serialize a record list (+ the monotonic lifetime-dispatch counter) into the
 *  persisted store text. PURE. `lifetimeDispatched` defaults to 0 for callers that don't
 *  track it; a negative/non-finite value is floored to 0. */
export function serializeStore(
  records: Assignment[],
  lifetimeDispatched = 0,
  dispatched: string[] = [],
): string {
  const lifetime =
    Number.isFinite(lifetimeDispatched) && lifetimeDispatched > 0
      ? Math.floor(lifetimeDispatched)
      : 0;
  // Sanitize the latch: non-empty strings only, deduped, stable order — defends the file
  // against a hand-edit and keeps the serialization deterministic for tests.
  const latch = [...new Set(dispatched.filter((k) => typeof k === "string" && k.length > 0))];
  const file: StoreFile = {
    version: STORE_VERSION,
    records,
    lifetimeDispatched: lifetime,
    dispatched: latch,
  };
  return JSON.stringify(file, null, 2);
}

/**
 * Parse the persisted store's monotonic `lifetimeDispatched` counter. PURE + TOLERANT.
 * A null/empty input (first run), unparseable JSON, a wrong-shaped object, or a missing /
 * non-numeric / negative `lifetimeDispatched` all yield 0 — so a corrupt or pre-upgrade
 * file simply starts the lifetime cap fresh (never crashes the loop). Read alongside
 * `parseStore` on the first reconcile to rehydrate the §7 lifetime cap across a restart.
 */
export function parseLifetimeDispatched(text: string | null): number {
  if (text === null || text.trim().length === 0) return 0;
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return 0;
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    return 0;
  }
  const n = (parsed as { lifetimeDispatched?: unknown }).lifetimeDispatched;
  if (typeof n !== "number" || !Number.isFinite(n) || n < 0) return 0;
  return Math.floor(n);
}

/** Read + parse the persisted lifetime-dispatch counter via the seam. Returns 0 on any
 *  read/parse failure; never throws into the loop. */
export function loadLifetimeDispatched(io: StoreIO): number {
  let text: string | null;
  try {
    text = io.read();
  } catch {
    return 0;
  }
  return parseLifetimeDispatched(text);
}

/**
 * Parse the persisted DISPATCHED-LATCH key set (§7.1). PURE + TOLERANT. A null/empty
 * input (first run), unparseable JSON, a wrong-shaped object, or a missing / non-array
 * `dispatched` all yield `[]` (an empty latch — the safe pre-upgrade default, which simply
 * means "nothing suppressed yet"). Non-string / empty entries are dropped; the result is
 * deduped. Read alongside `parseStore` on the first reconcile to rehydrate the latch across
 * a restart so a kill-before-claim item stays suppressed.
 */
export function parseDispatched(text: string | null): string[] {
  if (text === null || text.trim().length === 0) return [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return [];
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    return [];
  }
  const arr = (parsed as { dispatched?: unknown }).dispatched;
  if (!Array.isArray(arr)) return [];
  return [...new Set(arr.filter((k): k is string => typeof k === "string" && k.length > 0))];
}

/** Read + parse the persisted dispatched-latch set via the seam. Returns `[]` on any
 *  read/parse failure; never throws into the loop. */
export function loadDispatched(io: StoreIO): string[] {
  let text: string | null;
  try {
    text = io.read();
  } catch {
    return [];
  }
  return parseDispatched(text);
}

/** Coerce arbitrary parsed JSON into a valid Assignment, or null when it lacks the
 *  required identity fields. PURE. (Defensive against a hand-edited / older file.) */
function coerceAssignment(raw: unknown): Assignment | null {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return null;
  const r = raw as Record<string, unknown>;
  const queueName = r.queueName;
  const key = r.key;
  const state = r.state;
  if (typeof queueName !== "string" || queueName.length === 0) return null;
  if (typeof key !== "string" || key.length === 0) return null;
  if (typeof state !== "string" || !isAssignmentState(state)) return null;

  const a: Assignment = {
    queueName,
    key,
    sessionID: typeof r.sessionID === "number" ? r.sessionID : 0,
    gridSlot: typeof r.gridSlot === "number" ? r.gridSlot : 0,
    state,
    sinceMs: typeof r.sinceMs === "number" ? r.sinceMs : 0,
  };
  if (typeof r.surfaceUUID === "string") a.surfaceUUID = r.surfaceUUID;
  if (typeof r.title === "string") a.title = r.title;
  if (typeof r.url === "string") a.url = r.url;
  return a;
}

const ALL_STATES: ReadonlySet<string> = new Set<AssignmentState>([
  "QUEUED",
  "SPAWNED",
  "RUNNING",
  "DONE_PENDING",
  "CLOSING",
  "FINISHED",
  "FAILED",
  "EXITED",
  "COOLDOWN",
]);

/** PURE type-guard for the AssignmentState union. */
export function isAssignmentState(s: string): s is AssignmentState {
  return ALL_STATES.has(s);
}

// ---------------------------------------------------------------------------
// loadStore / persistStore — thin wrappers over the injected seam that never throw
// into the loop.
// ---------------------------------------------------------------------------

/** Read + parse the persisted records via the seam. Returns `[]` on any read/parse
 *  failure (logged by the caller); never throws. */
export function loadStore(io: StoreIO): Assignment[] {
  let text: string | null;
  try {
    text = io.read();
  } catch {
    return [];
  }
  return parseStore(text);
}

/** Serialize + write the records (+ the monotonic lifetime counter) via the seam.
 *  Returns true on success, false on a write failure (the caller logs + continues — a
 *  lost write only costs adoption hints + a possibly under-counted lifetime cap, never
 *  correctness/dedup). Never throws into the loop. `lifetimeDispatched` defaults to 0 for
 *  callers that don't track it (keeps the prior call sites working). */
export function persistStore(
  io: StoreIO,
  records: Assignment[],
  lifetimeDispatched = 0,
  dispatched: string[] = [],
): boolean {
  try {
    io.write(serializeStore(records, lifetimeDispatched, dispatched));
    return true;
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Crash-safe dispatch ordering (§9): write a PENDING record before the spawn,
// FINALIZE it after. Both are pure record transforms; the caller persists between
// them.
// ---------------------------------------------------------------------------

/**
 * Build the PENDING record written to the store BEFORE the spawn `await` (§9 step a).
 * PURE. State = `QUEUED`, `sessionID = 0` and `surfaceUUID` absent (not yet known) —
 * this is the crash-safety marker: if the sidecar dies between this write and the
 * spawn returning, the record has no live surface to match and is pruned (§9), while
 * a surface that DID spawn but lost its finalize is adopted via its queueKey
 * annotation. `nowMs` is injected (the pure core never reads its own clock).
 */
export function makePendingRecord(
  queueName: string,
  key: string,
  gridSlot: number,
  nowMs: number,
  extra?: { title?: string; url?: string },
): Assignment {
  const a: Assignment = {
    queueName,
    key,
    sessionID: 0,
    gridSlot,
    state: "QUEUED",
    sinceMs: nowMs,
  };
  if (extra?.title !== undefined) a.title = extra.title;
  if (extra?.url !== undefined) a.url = extra.url;
  return a;
}

/**
 * FINALIZE a pending record after the spawn returns the surface's UUID + sessionID
 * (§9 step d): stamp the stable `sessionID` + current `surfaceUUID` and advance the
 * state to `SPAWNED`. PURE — returns a NEW record (does not mutate the input). `nowMs`
 * is injected; it stamps `sinceMs` for the new state's timers.
 */
export function finalizeRecord(
  pending: Assignment,
  sessionID: number,
  surfaceUUID: string,
  nowMs: number,
): Assignment {
  return {
    ...pending,
    sessionID,
    surfaceUUID,
    state: "SPAWNED",
    sinceMs: nowMs,
  };
}

// ---------------------------------------------------------------------------
// Reconciliation (§9) — the PURE restart-recovery core.
// ---------------------------------------------------------------------------

/** The minimal live-surface view reconciliation needs: its stable session id, its
 *  current UUID, and whether it ALREADY carries this run's queueKey annotation. The
 *  caller projects `list_surfaces` rows + the annotation read into this. */
export interface LiveSurface {
  sessionID: number;
  surfaceUUID: string;
  /** The queueKey carried by the surface's annotation, if any (the orphan hint). A
   *  surface with a queueKey but no matching record is an orphan to adopt; a record
   *  whose live surface LACKS the queueKey needs the annotation re-stamped (the GUI's
   *  in-memory annotation map does not survive a GUI restart — the store is truth). */
  queueKey?: string;
  /** The queueName the surface's annotation carries, if any (for orphan adoption). */
  queueName?: string;
  /** The work-item title/url the surface's annotation carries (orphan adoption). */
  title?: string;
  url?: string;
}

/** What to do with one reconciled assignment record. */
export type ReconcileAction =
  /** Record + a live surface matched by sessionID → keep it active. The UUID is
   *  refreshed from the live surface (it is re-minted each GUI launch).
   *  `needsAnnotationRestamp` is true when the live surface LACKS the queueKey
   *  annotation (a GUI restart dropped the in-memory map) so the caller re-stamps it
   *  from the durable store. */
  | {
      kind: "active";
      assignment: Assignment;
      needsAnnotationRestamp: boolean;
    }
  /** A persisted record with NO live surface (session gone: host restart, or the
   *  user closed it). Pruned once the grace window since `sinceMs` has elapsed — for
   *  BOTH a still-PENDING (QUEUED, sessionID 0 → "pending-expired") record AND a
   *  finalized (sessionID != 0 → "session-gone") record whose session is not yet in
   *  `list_surfaces`. The finalized grace shields a FRESHLY-finalized record from a
   *  one-sweep `list_surfaces` lag (an immediate prune would free the key with no
   *  cooldown → a duplicate re-dispatch, §7); a long-lived RUNNING record's `sinceMs`
   *  is old, so a genuinely vanished session is past grace and pruned at once. */
  | {
      kind: "prune";
      assignment: Assignment;
      // session-gone: finalized record, session not in list_surfaces (past grace).
      // pending-expired: a sessionID-0 record whose surface never appeared (past grace).
      // no-pty-host: a sessionID-0 record whose surface IS live but its sessionID stayed
      //   0 past grace — the host never attached, i.e. genuinely no pty-host (§2). The
      //   caller self-disables the run on this reason (a transient 0 backfills instead).
      reason: "session-gone" | "pending-expired" | "no-pty-host";
    }
  /** A live surface carrying a queueKey annotation with NO matching record → adopt
   *  it as an assignment (NEVER re-dispatch). Crash-recovery for a spawn that lost
   *  its finalize. */
  | { kind: "adopt"; assignment: Assignment };

/** The full reconciliation plan: the actions + the resulting active record list
 *  (the supervisor's new in-memory active set, post-reconcile). */
export interface ReconcilePlan {
  actions: ReconcileAction[];
  /** The records to KEEP/persist after reconciliation: every `active` + `adopt`
   *  assignment (pruned ones dropped). The caller rebuilds its active map from this
   *  BEFORE any dispatch (§9 first-pass invariant). */
  kept: Assignment[];
}

/**
 * Reconcile persisted records against the live surfaces (§9). PURE + deterministic.
 * `nowMs` is injected; `graceMs` is the window a record (pending OR freshly finalized)
 * is given to have its surface appear in `list_surfaces` before it is pruned (covers
 * the spawn → first `list_surfaces` lag + a crash between the pending-write and the
 * spawn).
 *
 * Matching is by STABLE `sessionID`. Three §9 cases:
 *   - record + live surface (sessionID match) → ACTIVE (refresh UUID from live;
 *     flag `needsAnnotationRestamp` when the live surface lacks the queueKey
 *     annotation — a GUI restart dropped the in-memory map and the store is truth).
 *   - record, no live surface → PRUNE, but GRACE-GATED by `sinceMs` in BOTH cases. A
 *     FINALIZED record (sessionID != 0) is pruned ("session-gone") only once `nowMs -
 *     sinceMs > graceMs`; within grace it is KEPT (no action) so a one-sweep
 *     `list_surfaces` lag right after the finalize can't free the key for an immediate
 *     duplicate re-dispatch (§7). A still-PENDING record (sessionID 0, never finalized)
 *     is likewise pruned only past grace ("pending-expired"); within grace it is kept
 *     (the spawn may still be in flight), with NO action emitted so it neither
 *     dispatches nor double-counts. Because grace keys off `sinceMs` (stamped on each
 *     state change, NOT each steady sweep), a long-lived RUNNING record is past grace
 *     and a genuinely vanished session — host restart, user closed it — is pruned at
 *     once.
 *   - live surface with a queueKey annotation but NO record → ADOPT (orphan; the
 *     spawn finalize was lost to a crash). Reconstruct the assignment from the
 *     annotation + a fresh `sinceMs`; state RUNNING (it is a live, detected surface).
 *
 * The returned `kept` list is the post-reconcile active set: caller rebuilds its
 * in-memory map from it BEFORE dispatching, so re-adoption ALWAYS precedes dispatch
 * (the restart-window double-dispatch gap is closed at the call site by suppressing
 * dispatch on the first sweep until this has run).
 */
export function reconcile(
  records: Assignment[],
  liveSurfaces: LiveSurface[],
  nowMs: number,
  graceMs: number,
  // (premature-prune fix) ms-since-epoch this run STARTED reconciling in the CURRENT
  // process (stamped on the first reconcile after a (re)start; a restart re-stamps it).
  // A finalized record's "session-gone" prune is shielded for `graceMs` after this, NOT
  // only `graceMs` after the record's own `sinceMs`. The old `sinceMs`-only grace gave a
  // LONG-LIVED RUNNING record (old `sinceMs`) ZERO protection against a SUCCESSFUL-but-
  // INCOMPLETE `list_surfaces` right after a GUI restart (surfaces still coming up) — it
  // was pruned instantly, dropping live, tracked agents (active→0) and detaching their
  // tiles (and, with the old quitWhenEmpty, removing the whole run). This floor gives every
  // record a fresh grace window after each (re)start. Default `-Infinity` ⇒ the floor is a
  // no-op (identical to the pre-fix `sinceMs`-only behavior) for callers that don't pass it.
  reconcileStartedMs: number = Number.NEGATIVE_INFINITY,
): ReconcilePlan {
  // Index live surfaces by sessionID (only finalized, non-zero sessions can match a
  // record). A sessionID of 0 is "unknown" and never a match key.
  const liveBySession = new Map<number, LiveSurface>();
  // Also index by UUID: a freshly-dispatched record can carry sessionID 0 (the host
  // attaches asynchronously, so the split's id isn't ready at spawn time — see
  // dispatchOne). Such a record is matched by its stable surfaceUUID until its session
  // attaches, at which point we BACKFILL the real sessionID. (UUID is stable WITHIN a GUI
  // session; across a GUI restart the UUID is re-minted, but by then the surface's
  // session has attached and orphan-adoption by the queueKey annotation recovers it.)
  const liveByUUID = new Map<string, LiveSurface>();
  for (const s of liveSurfaces) {
    if (s.sessionID !== 0) liveBySession.set(s.sessionID, s);
    liveByUUID.set(s.surfaceUUID, s);
  }

  const actions: ReconcileAction[] = [];
  const kept: Assignment[] = [];

  // Track which live surfaces were claimed by a record so the leftovers can be
  // considered for orphan adoption. Claim by sessionID (the match key) AND by UUID (for
  // sessionID-0 records matched by UUID, so they aren't also orphan-adopted).
  const claimedSessions = new Set<number>();
  const claimedUUIDs = new Set<string>();

  for (const rec of records) {
    const live = rec.sessionID !== 0 ? liveBySession.get(rec.sessionID) : undefined;
    if (live !== undefined) {
      claimedSessions.add(rec.sessionID);
      // Refresh the (re-minted) UUID from the live surface; flag a restamp when the
      // surface lost its queueKey annotation (the durable store is the truth).
      const refreshed: Assignment = { ...rec, surfaceUUID: live.surfaceUUID };
      const needsAnnotationRestamp = live.queueKey !== rec.key;
      actions.push({ kind: "active", assignment: refreshed, needsAnnotationRestamp });
      kept.push(refreshed);
      continue;
    }

    // No live surface for this record.
    if (rec.sessionID !== 0) {
      // Finalized but the session is not (yet) in list_surfaces. A FRESHLY-finalized
      // record in a LIVE-AGENT state (its `sinceMs` is recent) is given the SAME grace
      // window as a pending record before it is session-gone-pruned: the normal dispatch
      // flow finalizes the record with the spawn's sessionID in the SAME sweep and the
      // surface is only expected to appear in `list_surfaces` by the NEXT sweep, so if
      // list_surfaces lags the spawn by even one sweep (or a single dropped/slow call) an
      // immediate prune would free the key with NO cooldown → selectCandidates
      // re-dispatches the SAME key → a DUPLICATE agent on the same work item (the §7
      // no-duplicates guarantee). The grace keys off `sinceMs`, so it ONLY shields a
      // record whose state was stamped recently (a freshly SPAWNED/finalized one); a
      // long-lived RUNNING record keeps its old `sinceMs` (state changes stamp it, a
      // steady state does not), so a genuinely vanished session — host restart, user
      // closed it — is past grace and pruned at once. This makes the prune-vs-lag
      // decision explicit + tested at THIS layer rather than resting on the implicit §8.1
      // synchronous-tree-populate invariant.
      //
      // EXITED is EXEMPT from the grace: an EXITED (leave-and-bell) record's surface is
      // either still present (and would have matched above) or genuinely gone because a
      // human closed the dead split — there is no spawn-lag race for it, it occupies NO
      // slot, and §6 wants its freed key promptly into COOLDOWN. So an EXITED record with
      // no live surface prunes immediately regardless of `sinceMs`.
      // Shield for graceMs after EITHER the record's own state change (`sinceMs`, the
      // spawn-lag case) OR the run starting to reconcile in this process
      // (`reconcileStartedMs`, the restart list-lag case) — whichever is LATER. So a
      // long-lived RUNNING record is no longer pruned the instant it's missing from a
      // transient/incomplete post-restart `list_surfaces`.
      const graceFrom = Math.max(rec.sinceMs, reconcileStartedMs);
      if (rec.state !== "EXITED" && nowMs - graceFrom <= graceMs) {
        // In-grace finalized live-agent record: KEEP it (no action) so the lagging surface
        // can still appear next sweep; it neither re-dispatches (its key stays in the
        // active set) nor is lost.
        kept.push(rec);
      } else {
        actions.push({ kind: "prune", assignment: rec, reason: "session-gone" });
      }
      continue;
    }
    // sessionID 0: either a never-finalized pending record (no UUID yet) OR a finalized
    // record whose split's host session hasn't attached yet (has a UUID, session 0).
    // Try to match the live surface by UUID and BACKFILL the session once it attaches.
    const liveByUuid = rec.surfaceUUID !== undefined ? liveByUUID.get(rec.surfaceUUID) : undefined;
    if (liveByUuid !== undefined) {
      claimedUUIDs.add(liveByUuid.surfaceUUID);
      if (liveByUuid.sessionID !== 0) {
        // The host has now attached → BACKFILL the real sessionID (and refresh the UUID).
        claimedSessions.add(liveByUuid.sessionID);
        const refreshed: Assignment = {
          ...rec,
          sessionID: liveByUuid.sessionID,
          surfaceUUID: liveByUuid.surfaceUUID,
        };
        const needsAnnotationRestamp = liveByUuid.queueKey !== rec.key;
        actions.push({ kind: "active", assignment: refreshed, needsAnnotationRestamp });
        kept.push(refreshed);
      } else if (nowMs - rec.sinceMs > graceMs) {
        // The surface is LIVE but its sessionID has stayed 0 past the grace window → the
        // host never attached, i.e. genuinely NO pty-host (§2 hard dep). Prune it with the
        // `no-pty-host` reason so the caller self-disables the run (vs a transient 0, which
        // backfills above). This is the DEFERRED §2 backstop — no false self-disable on a
        // split that simply hasn't attached yet.
        actions.push({ kind: "prune", assignment: rec, reason: "no-pty-host" });
      } else {
        // Live surface, session not yet attached, within grace → KEEP (pending session).
        // It occupies its slot; the agent is running; backfill is expected next sweep.
        kept.push(rec);
      }
      continue;
    }

    // No live surface for this record's UUID (or no UUID yet). Keep within the grace
    // window (the spawn → first list_surfaces lag); prune after.
    if (nowMs - rec.sinceMs > graceMs) {
      actions.push({ kind: "prune", assignment: rec, reason: "pending-expired" });
    } else {
      // In-grace pending: KEEP it (no action) so it neither dispatches nor is lost.
      kept.push(rec);
    }
  }

  // Any live surface carrying a queueKey annotation that no record claimed is an
  // ORPHAN we adopt (never re-dispatch). Dedup by sessionID so one surface is adopted
  // at most once.
  //
  // GRID-SLOT RECLAMATION (§12): an adopted pane MUST get a real, non-negative grid
  // slot. The annotation does not carry the slot, but the run keeps all its splits in
  // ONE tab, so the exact original geometry is not load-bearing — what matters is that
  // an adopted pane COUNTS as occupying a slot. If it carried -1 it would be excluded
  // from the next dispatch's occupied set (`gridSlot >= 0`), so with ONLY adopted panes
  // present the occupied set would be empty → `lowestFreeSlot` returns 0 → `splitPlan`
  // returns `{firstTab:true}` → the next dispatch opens a BRAND-NEW TAB instead of
  // splitting into the run's existing tab, scattering the fleet across tabs after every
  // restart (the common GUI/sidecar-restart-then-dispatch path). So we assign each
  // adopted pane the LOWEST FREE slot index not already used by a kept record or a
  // previously-adopted pane — deterministic, no geometry needed, and enough to keep the
  // dispatch splitting into the adopted tab.
  const usedSlots = new Set<number>();
  for (const k of kept) if (k.gridSlot >= 0) usedSlots.add(k.gridSlot);
  const adoptedSessions = new Set<number>();
  for (const s of liveSurfaces) {
    if (s.sessionID === 0) continue; // can't be persistence-keyed → not adoptable
    if (claimedUUIDs.has(s.surfaceUUID)) continue; // a sessionID-0 record matched it by UUID
    if (claimedSessions.has(s.sessionID)) continue;
    if (adoptedSessions.has(s.sessionID)) continue;
    const queueKey = s.queueKey;
    const queueName = s.queueName;
    if (
      typeof queueKey !== "string" ||
      queueKey.length === 0 ||
      typeof queueName !== "string" ||
      queueName.length === 0
    ) {
      continue; // not a queue surface (no queueKey annotation) → leave it alone
    }
    adoptedSessions.add(s.sessionID);
    // Reclaim the lowest free non-negative slot for this adopted pane.
    let gridSlot = 0;
    while (usedSlots.has(gridSlot)) gridSlot += 1;
    usedSlots.add(gridSlot);
    const adopted: Assignment = {
      queueName,
      key: queueKey,
      sessionID: s.sessionID,
      surfaceUUID: s.surfaceUUID,
      // The original slot is unknown from the annotation, but a run keeps all its splits
      // in one tab so the precise geometry isn't load-bearing — what IS load-bearing is
      // that the adopted pane COUNTS as occupying a slot (so the next dispatch splits
      // into the adopted tab rather than opening a new one, §12). We assign the lowest
      // free slot among kept + already-adopted panes.
      gridSlot,
      state: "RUNNING",
      sinceMs: nowMs,
    };
    if (typeof s.title === "string") adopted.title = s.title;
    if (typeof s.url === "string") adopted.url = s.url;
    actions.push({ kind: "adopt", assignment: adopted });
    kept.push(adopted);
  }

  return { actions, kept };
}

// ---------------------------------------------------------------------------
// Active-run persistence (§8a/§9) — the set of STARTED runs (+ paused/draining flags)
// survives a sidecar restart so a started queue rehydrates without a re-start command (a
// template merely existing on disk does NOT auto-run — only a persisted/started run).
// This is a SEPARATE store file from the per-run assignment records above.
// ---------------------------------------------------------------------------

/** One persisted active run (§8a): the template BASENAME to reload, the run NAME (origin),
 *  and the resumable flags. `aborting` is NOT persisted — an abort terminates the run, so a
 *  restart simply doesn't carry it. */
export interface ActiveRunRecord {
  /** The template basename (`*.json` minus extension) to reload on rehydration. */
  template: string;
  /** The run NAME (= `template.name`, the dashboard origin) at start time. Display-only
   *  hint; the authoritative name is re-derived from the reloaded template. */
  name: string;
  paused: boolean;
  draining: boolean;
  /** (§8b) The start-time parameter answers (name → value) this run was started with, so a
   *  restart re-applies the same provider scope. Omitted when the template declares none. */
  params?: Record<string, string>;
  /** (live maxItems edit) The run-level lifetime-cap OVERRIDE set by a `set_max_items`
   *  command while the run was live. `null` = live-set to unlimited; a positive number = the
   *  live cap. OMITTED when never live-edited (a restart then falls back to the start-time /
   *  template cap). Persisted so a restart re-applies the user's live edit. */
  maxItemsLive?: number | null;
  /** (live concurrency edit) The run-level max-simultaneous-agents OVERRIDE set by a
   *  `set_concurrency` command while the run was live. A positive integer; OMITTED when never
   *  live-edited (a restart then falls back to the template concurrency). Persisted so a
   *  restart re-applies the user's live edit. */
  concurrencyLive?: number;
}

/** The on-disk active-runs file shape. Versioned for additive migration. */
export interface ActiveRunsFile {
  version: 1;
  runs: ActiveRunRecord[];
}

/**
 * Parse the persisted active-runs text into a record list. PURE + TOLERANT (mirrors
 * `parseStore`): a null/empty input, unparseable JSON, a wrong-shaped object, or a
 * non-array `runs` all yield `[]` (no runs rehydrate → the supervisor is dormant until a
 * `start` command arrives, which is the safe default). A record missing a non-empty
 * `template` basename is dropped individually (it can't be reloaded); `name`/flags default.
 */
export function parseActiveRuns(text: string | null): ActiveRunRecord[] {
  if (text === null || text.trim().length === 0) return [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return [];
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    return [];
  }
  // Honor the version gate: a present-but-UNKNOWN numeric version is a future (v2+)
  // file we must not misparse as v1 by field-shape alone — treat it as unparseable and
  // return [] (the safe dormant-until-start default). An ABSENT / non-numeric version is
  // tolerated (legacy/hand-edited file) and parsed by shape, matching the rest of the
  // tolerant parser.
  const version = (parsed as { version?: unknown }).version;
  if (typeof version === "number" && version !== STORE_VERSION) {
    return [];
  }
  const recs = (parsed as { runs?: unknown }).runs;
  if (!Array.isArray(recs)) return [];

  const out: ActiveRunRecord[] = [];
  for (const raw of recs) {
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) continue;
    const r = raw as Record<string, unknown>;
    const template = r.template;
    if (typeof template !== "string" || template.length === 0) continue;
    const rec: ActiveRunRecord = {
      template,
      name: typeof r.name === "string" ? r.name : template,
      paused: r.paused === true,
      draining: r.draining === true,
    };
    // (§8b) tolerate + carry the start-time params object (string→string only).
    if (r.params !== null && typeof r.params === "object" && !Array.isArray(r.params)) {
      const params: Record<string, string> = {};
      for (const [k, val] of Object.entries(r.params as Record<string, unknown>)) {
        if (typeof k === "string" && k.length > 0 && typeof val === "string") params[k] = val;
      }
      if (Object.keys(params).length > 0) rec.params = params;
    }
    // (live maxItems edit) carry a live cap override: null = unlimited; a positive integer =
    // the cap. Anything else (absent / non-finite / <=0 number) is dropped → no live override
    // rehydrates (falls back to the start-time/template cap), matching the tolerant default.
    const mil = r.maxItemsLive;
    if (mil === null) {
      rec.maxItemsLive = null;
    } else if (typeof mil === "number" && Number.isInteger(mil) && mil > 0) {
      rec.maxItemsLive = mil;
    }
    // (live concurrency edit) carry a live concurrency override: a positive integer only.
    // Anything else (absent / non-finite / <=0) is dropped → no override rehydrates (falls
    // back to the template concurrency), matching the tolerant default.
    const cl = r.concurrencyLive;
    if (typeof cl === "number" && Number.isInteger(cl) && cl > 0) {
      rec.concurrencyLive = cl;
    }
    out.push(rec);
  }
  return out;
}

/** Serialize an active-run record list into the persisted text. PURE. */
export function serializeActiveRuns(runs: ActiveRunRecord[]): string {
  const file: ActiveRunsFile = { version: STORE_VERSION, runs };
  return JSON.stringify(file, null, 2);
}

/** Read + parse the persisted active runs via the seam. Returns `[]` on any read/parse
 *  failure; never throws into the loop. */
export function loadActiveRuns(io: StoreIO): ActiveRunRecord[] {
  let text: string | null;
  try {
    text = io.read();
  } catch {
    return [];
  }
  return parseActiveRuns(text);
}

/** Serialize + write the active runs via the seam. Returns true on success, false on a
 *  write failure (a lost write only costs a re-start after a restart, never correctness).
 *  Never throws into the loop. */
export function persistActiveRuns(io: StoreIO, runs: ActiveRunRecord[]): boolean {
  try {
    io.write(serializeActiveRuns(runs));
    return true;
  } catch {
    return false;
  }
}

/**
 * Build the supervisor's in-memory active set (a `Map<key, Assignment>`) from a
 * reconciliation `kept` list. PURE. The dedup invariant (§7) is keyed by work-item
 * `key`, so this is the structure `selectCandidates` consults. On the (degenerate)
 * event of two kept records sharing a key, the LATER one wins — but reconcile already
 * dedups live surfaces by sessionID, and a healthy run never has two records for one
 * key.
 */
export function activeSetFromKept(kept: Assignment[]): Map<string, Assignment> {
  const m = new Map<string, Assignment>();
  for (const a of kept) m.set(a.key, a);
  return m;
}

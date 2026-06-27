// (ramon fork / Agent Queue Supervisor) The PURE decision core (§6/§7/§10). Mirrors
// the summarizer/manager pure style EXACTLY: every function here is deterministic
// (no I/O, no clock-of-its-own — `nowMs` is injected) and unit-tested directly. The
// deterministic TS control loop (index.ts) calls these to decide WHAT to dispatch
// (`selectCandidates`), HOW an assignment's state advances (`nextState`), and the
// CLOSE sequence (`closeSequencePlan`); the loop owns the side effects (MCP spawn,
// persistence, timers). NOTHING here is Linear/Git/issue-key aware.

import type {
  Assignment,
  AssignmentState,
  QueueTemplate,
  WorkItem,
} from "./types.js";

// ---------------------------------------------------------------------------
// Concurrency budget for the supervisor's OWN provider/dispatch fan-out.
// ---------------------------------------------------------------------------

/**
 * A trivial counter capped at `max`. The supervisor pass MUST own its OWN budget
 * (NOT share the summarizer's / manager's) — the manager-budget starvation lesson
 * (CLAUDE.md): a pass that shares another's single budget and runs second can get
 * zero slots every sweep and never act. Identical shape to the summarizer's
 * `ConcurrencyBudget` so the loop treats them uniformly. Not pure state, but a
 * trivial testable value type.
 */
export class ConcurrencyBudget {
  private inFlight = 0;
  constructor(private readonly max: number) {}
  /** Try to acquire a slot; returns true on success. */
  tryAcquire(): boolean {
    if (this.inFlight >= this.max) return false;
    this.inFlight++;
    return true;
  }
  /** Release a slot. */
  release(): void {
    if (this.inFlight > 0) this.inFlight--;
  }
  get active(): number {
    return this.inFlight;
  }
}

// ---------------------------------------------------------------------------
// selectCandidates (§7) — the no-duplicates dispatch core.
// ---------------------------------------------------------------------------

/**
 * Choose which work items to dispatch THIS round, respecting every cap and the
 * dedup guarantee (§7). PURE + deterministic. Items are taken in the provider's
 * EMIT ORDER (the template controls priority via its query sort); an item is SKIPPED
 * when ANY of:
 *   - its key is already in the `active` set (the in-memory + reconciled active map,
 *     keyed by work-item key — covers within-tick AND cross-restart dedup);
 *   - its key is in `cooldown` with an `until` strictly in the future (`nowMs <
 *     until`) — a just-finished key is held so a stale `list` can't immediately
 *     re-dispatch it (§6 COOLDOWN); an expired cooldown entry no longer blocks;
 *   - its key is in the `dispatched` LATCH (§7.1) — it was already dispatched and has
 *     NOT yet left the actionable `list` since. The latch is cleared by the caller only
 *     when a SUCCESSFUL `list` no longer reports the key (it left the actionable set);
 *     until then a re-dispatch is BLOCKED ENTIRELY (not merely time-cooled), so a kill
 *     BEFORE the agent claims its item — the item still in the list — is never re-grabbed.
 *     Re-arm requires the item to leave the list and return (a real status round-trip);
 *   - a DUPLICATE key already chosen earlier in THIS selection round (a flaky
 *     provider can emit the same key twice in one list — we dispatch it once).
 *
 * The result is capped by BOTH `remainingSlots` (= the smaller of remaining
 * concurrency and remaining grid capacity, computed by the caller) AND
 * `maxItemsRemaining` (the run's lifetime `maxItems` budget minus dispatches so
 * far). A non-positive cap yields `[]`.
 *
 * ── WITHIN-TICK DEDUP INVARIANT (load-bearing, §7) ──────────────────────────────
 * This function is PURE and reads `active` ONCE. It returns up to N candidates, but
 * the caller dispatches them one at a time and MUST insert each chosen key into the
 * `active` map SYNCHRONOUSLY (before awaiting that spawn) so a later candidate in
 * the SAME returned batch — or a later sweep before `list_surfaces` reflects the new
 * surface — cannot pick a key already in flight. `selectCandidates` removing
 * intra-batch duplicates covers a duplicate-in-one-list; the synchronous active-set
 * insert at the call site covers the spawn-not-yet-visible window. Both are required.
 */
export function selectCandidates(
  items: WorkItem[],
  active: Map<string, Assignment>,
  cooldown: Map<string, number>,
  dispatched: ReadonlySet<string>,
  nowMs: number,
  remainingSlots: number,
  maxItemsRemaining: number,
): WorkItem[] {
  const cap = Math.min(remainingSlots, maxItemsRemaining);
  if (cap <= 0) return [];

  const chosen: WorkItem[] = [];
  const chosenKeys = new Set<string>();

  for (const item of items) {
    if (chosen.length >= cap) break;
    const key = item.key;
    if (typeof key !== "string" || key.length === 0) continue; // never dispatch keyless
    if (active.has(key)) continue; // already running/tracked (within-tick + cross-restart)
    if (dispatched.has(key)) continue; // §7.1 latch: dispatched + not yet left the list
    if (chosenKeys.has(key)) continue; // duplicate key in this same list
    const until = cooldown.get(key);
    if (until !== undefined && nowMs < until) continue; // cooling down
    chosen.push(item);
    chosenKeys.add(key);
  }
  return chosen;
}

/**
 * The remaining dispatch SLOTS = the smaller of remaining concurrency and the global
 * fleet remaining (§7/§12). PURE. `activeCount` is the number of assignments currently
 * occupying a slot (RUNNING/SPAWNED/etc — the caller decides which states count, but
 * typically every non-terminal, non-cooldown assignment). `globalRemaining` caps the
 * WHOLE fleet across runs (`agent-queue-max-total`). The result is floored at 0.
 *
 * `concurrency` is the run's TOTAL pane budget across ALL its tabs — it is NOT bounded by
 * one tab's `cols*rows` (panes overflow to additional tabs, §12), so the grid is no longer a
 * term here. `effConcurrency` OVERRIDES the template's `concurrency` when given (the live
 * `set_concurrency` edit — see `effectiveConcurrency` in runner.ts); omitted ⇒ the template's
 * own `concurrency`.
 */
export function remainingSlots(
  template: QueueTemplate,
  activeCount: number,
  globalRemaining: number,
  effConcurrency?: number,
): number {
  const concurrency = effConcurrency ?? template.concurrency;
  return Math.max(0, Math.min(concurrency - activeCount, globalRemaining));
}

// ---------------------------------------------------------------------------
// nextState (§6) — the assignment state machine.
// ---------------------------------------------------------------------------

/** The observed context for advancing ONE assignment's state (§6). All fields are
 *  point-in-time observations the loop gathers (provider status, `list_surfaces`
 *  row, the hook-driven agentState). The pure machine never reads a clock — every
 *  time is injected via `nowMs` / `idleStableSinceMs`. */
export interface NextStateContext {
  /** Did the provider `status` probe return a TERMINAL state this tick? `undefined`
   *  = not probed / unknown this tick (NEVER treated as terminal — §13). The ONLY
   *  completion trigger (§8). */
  statusTerminal?: boolean;
  /** Is the surface still present in `list_surfaces`? (false = closed/gone). */
  surfaceLive: boolean;
  /** The hook-driven agentState ("working"/"waiting"/"idle"/undefined). The close
   *  gate keys on this (QUIESCENT = idle OR waiting) — NEVER on `idleSeconds` (a
   *  repainting TUI never idles by `idleSeconds`, §2). A finished Claude Code agent
   *  reliably ends in `waiting` (its `Stop`→idle hook is immediately overwritten by a
   *  `Notification` "waiting for input" nudge), so an idle-ONLY gate would never close
   *  it — hence quiescence spans both. */
  agentState?: string;
  /** Did the surface's child process EXIT (process_exited)? (§6 EXITED). */
  exited: boolean;
  /** ms-since-epoch the agentState last BECAME QUIESCENT (idle OR waiting) UNCHANGED
   *  (the quiescence-debounce anchor). The loop stamps it when it observes a quiescent
   *  state and RESETS it to undefined on any non-quiescent observation (a flap), so a
   *  stable quiescence of `closeStableSeconds` requires the agent to stay quiescent
   *  (idle↔waiting transitions DON'T reset it — both count) continuously. `undefined` =
   *  not currently quiescent (working) or just flapped. */
  idleStableSinceMs?: number;
  /** Current time (ms-since-epoch), injected. */
  nowMs: number;
  /** The template's close-stable window in SECONDS (§10). */
  closeStableSeconds: number;
  /** The template's `closeOnComplete` opt-out (§5/§6/§10). When `false`, a
   *  DONE_PENDING assignment is NEVER advanced to CLOSING — the completed split is
   *  LEFT OPEN for manual close (so the slot stays held until a human closes it).
   *  Defaults to `true` (auto-close) when omitted, preserving the prior behavior. */
  closeOnComplete?: boolean;
  /** (keep) The PER-SPLIT "keep this open" verdict (the dashboard 📌 pin / the template
   *  `keepOnComplete` default), computed by the loop as
   *  `run.keep.get(key) ?? template.keepOnComplete ?? false`. When `true`, a DONE_PENDING
   *  assignment is NEVER advanced to CLOSING — the completed split is left open for manual
   *  work (the slot stays held, exactly like `closeOnComplete:false`). It suppresses BOTH
   *  the idle-hold close AND the exited-short-circuit close, so a kept split is never
   *  auto-torn-down. Independent of `closeOnComplete` (either being a hold reason is enough
   *  — see `nextState`). Defaults to false (auto-close). */
  keep?: boolean;
}

/**
 * Advance ONE assignment's state per the §6 machine. PURE + deterministic — returns
 * the NEXT AssignmentState (the caller stamps `sinceMs` + persists on a change). It
 * does NOT mutate. Transitions (in priority order):
 *
 *   - EARLY EXIT: in any pre-completion live state (SPAWNED/RUNNING/QUEUED), if the
 *     child `exited` BEFORE completion → `EXITED` (leave-and-bell: keep the split,
 *     free the slot, ring the bell — handled by the loop). NOT auto-re-queued.
 *   - SURFACE GONE: a tracked surface vanished from `list_surfaces` while NOT in a
 *     terminal/closing state → stays put for the reconciler to PRUNE (returns the
 *     same state; reconcile, not nextState, removes a gone record). The machine here
 *     only advances LIVE surfaces.
 *   - SPAWNED → RUNNING: the surface shows an `agentState` (or agentKind — the loop
 *     passes agentState as the detection proxy) → it is a live, detected agent.
 *   - RUNNING → DONE_PENDING: `statusTerminal === true` (the provider says done).
 *     The ONLY completion trigger.
 *   - DONE_PENDING → CLOSING: the agent is QUIESCENT (agentState `idle` OR `waiting`)
 *     held UNCHANGED for `closeStableSeconds` — i.e. `idleStableSinceMs` is set AND
 *     `nowMs - idleStableSinceMs >= closeStableSeconds*1000` — AND NOT KEPT
 *     (`keep !== true && closeOnComplete !== false`). `waiting` counts because a finished
 *     Claude Code agent reliably settles in `waiting` (its `Stop`→idle hook is overwritten
 *     by a later `Notification` nudge), so an idle-ONLY gate would never close it.
 *     A flap to working (idleStableSinceMs undefined) HOLDS in DONE_PENDING (never closes early).
 *     A KEPT split (`keep === true`, the per-split 📌 pin / `keepOnComplete` default) or a
 *     template with `closeOnComplete === false` HOLDS in DONE_PENDING forever (the done split
 *     is left open for manual work, §5/§6/§10). `idleSeconds` is NEVER consulted (§10).
 *     EXCEPTION: a DONE_PENDING assignment whose CHILD has already EXITED short-circuits
 *     straight to CLOSING (when NOT kept), since the idle-hold would never be satisfied by a
 *     child that crashed/exited before reporting a stable idle — without this the slot would
 *     be held forever. (A KEPT split suppresses even this exit short-circuit — it is never
 *     auto-closed; force-close it from the dashboard when truly done.)
 *   - TERMINAL/transitional states (CLOSING/FINISHED/FAILED/EXITED/COOLDOWN) are
 *     returned unchanged — the loop, not the machine, drives the close sequence and
 *     the cooldown→eligible transition.
 *
 * Note: a status that goes terminal while still SPAWNED (before RUNNING was ever
 * observed) is honored — SPAWNED also advances to DONE_PENDING on `statusTerminal`,
 * so a fast-completing agent isn't stuck.
 */
export function nextState(a: Assignment, ctx: NextStateContext): AssignmentState {
  const s = a.state;

  // Terminal / transitional: the machine does not move these; the loop owns them.
  if (
    s === "CLOSING" ||
    s === "FINISHED" ||
    s === "FAILED" ||
    s === "EXITED" ||
    s === "COOLDOWN"
  ) {
    return s;
  }

  // A still-pre-completion surface whose CHILD exited early → EXITED (§6). Checked
  // before the surface-gone and completion logic: a crashed agent must free its slot
  // and ring the bell, not be mistaken for done.
  if (ctx.exited && (s === "SPAWNED" || s === "RUNNING" || s === "QUEUED")) {
    return "EXITED";
  }

  // DONE_PENDING gate: close only on idle HELD unchanged for closeStableSeconds —
  // AND only when the template OPTS IN to auto-close. `closeOnComplete === false`
  // pins the assignment in DONE_PENDING forever (the completed split is left open for
  // manual close, §5/§6/§10); `undefined`/`true` keep the auto-close behavior.
  if (s === "DONE_PENDING") {
    // (keep) A KEPT split is exempt from auto-close ENTIRELY — it stays in DONE_PENDING
    // (slot held) so the user can do manual work in it after the task is done. This
    // suppresses BOTH the idle-hold AND the exited-short-circuit below, so a kept split is
    // never torn down by the supervisor (force-close it from the dashboard ⏹ when truly done).
    // `closeOnComplete:false` is the equivalent HARD template-wide hold (no per-split override);
    // either being true holds.
    if (ctx.keep === true || ctx.closeOnComplete === false) {
      return "DONE_PENDING"; // kept / opted out of auto-close → leave open for manual work
    }
    // A provider-done agent whose CHILD has already EXITED is done draining: short-circuit
    // straight to CLOSING (don't wait on the idle-hold, which a crashed-before-idle child
    // would never satisfy → the slot would be held forever). The close sequence then just
    // force-closes the already-exited split.
    if (ctx.exited) {
      return "CLOSING";
    }
    if (
      isQuiescent(ctx.agentState) &&
      typeof ctx.idleStableSinceMs === "number" &&
      ctx.nowMs - ctx.idleStableSinceMs >= ctx.closeStableSeconds * 1000
    ) {
      return "CLOSING";
    }
    return "DONE_PENDING"; // not stably quiescent / flapped → hold
  }

  // Completion: provider status terminal is the ONLY trigger (works from SPAWNED or
  // RUNNING — a fast agent that completes before RUNNING was observed still advances).
  if (ctx.statusTerminal === true && (s === "SPAWNED" || s === "RUNNING")) {
    return "DONE_PENDING";
  }

  // SPAWNED → RUNNING once the agent is detected (an agentState present means a hook
  // reported / the dashboard detected it). A gone surface stays put for reconcile.
  if (s === "SPAWNED") {
    if (
      ctx.surfaceLive &&
      typeof ctx.agentState === "string" &&
      ctx.agentState.length > 0
    ) {
      return "RUNNING";
    }
    return "SPAWNED";
  }

  // QUEUED is a transient pre-spawn marker the loop replaces on finalize; if seen
  // here (no spawn yet) it stays QUEUED.
  return s;
}

/** Is the agent QUIESCENT — settled, awaiting the queue's close (NOT actively
 *  working)? True for `idle` AND `waiting`: a finished Claude Code agent reliably
 *  ends in `waiting` (its `Stop`→idle hook is overwritten by a `Notification` nudge),
 *  so both count as "done, ready to close". `working`/`undefined`/anything else is
 *  NOT quiescent. PURE. */
export function isQuiescent(agentState: string | undefined): boolean {
  return agentState === "idle" || agentState === "waiting";
}

/**
 * Fold the quiescence-debounce ANCHOR. PURE. Given the PRIOR `idleStableSinceMs` and
 * the CURRENTLY-observed agentState + `nowMs`, return the next anchor:
 *   - QUIESCENT (idle OR waiting) AND a prior anchor exists → KEEP the prior anchor
 *     (the agent has been continuously quiescent — do NOT reset the clock; an
 *     idle↔waiting transition therefore KEEPS the hold running, since both qualify).
 *   - QUIESCENT AND no prior anchor → START the clock at `nowMs`.
 *   - NOT quiescent (working / undefined / etc) → RESET to undefined (a flap; the next
 *     quiescent observation restarts the clock from scratch).
 * This is what makes "quiescent UNCHANGED for closeStableSeconds" a true HOLD that a
 * flap to working resets (§6/§10) — `nextState` reads the resulting anchor.
 */
export function foldIdleAnchor(
  priorAnchorMs: number | undefined,
  agentState: string | undefined,
  nowMs: number,
): number | undefined {
  if (isQuiescent(agentState)) {
    return typeof priorAnchorMs === "number" ? priorAnchorMs : nowMs;
  }
  return undefined;
}

// ---------------------------------------------------------------------------
// closeSequencePlan (§10) — the exit→await-exited→force-close steps.
// ---------------------------------------------------------------------------

/** One step of the close sequence (§10). The loop executes them in order, awaiting
 *  the `awaitExited` step (bounded) before the `forceClose`. */
export type CloseStep =
  /** TYPE a literal string into the agent to make it exit — for agents whose exit is a
   *  typed COMMAND, not a control key (e.g. Claude Code's `/quit`, which swallows
   *  Ctrl-D). Routed through the MCP send_text tool (types only, does not submit), so a
   *  submitting `sendKey "enter"` normally follows. */
  | { kind: "sendText"; text: string }
  /** Send a key to make the agent's CHILD exit (default Ctrl-D), so the subsequent
   *  close does not hit the confirm-close dialog. `key` is a template `exit.keys`
   *  entry (e.g. "ctrl-d", "enter"), passed through to the MCP send_key tool verbatim
   *  (must be a name the tool recognizes — see MCPInput.keySpecs(forKey:)). */
  | { kind: "sendKey"; key: string }
  /** Poll `list_surfaces` until the surface's `exited === true` (bounded; on timeout
   *  the loop proceeds to forceClose anyway — §10). */
  | { kind: "awaitExited" }
  /** Confirm-bypass close the now-exited split (`force_close_surface`). */
  | { kind: "forceClose" };

/** The default exit keys when a template's `agent.exit` is absent (§5/§10): Ctrl-D
 *  at the shell prompt. NOTE the HYPHEN form — it must match a key name the MCP
 *  send_key tool recognizes (MCPInput.keySpecs(forKey:) uses "ctrl-d"/"ctrl-c"/…). */
export const DEFAULT_EXIT_KEYS = ["ctrl-d"];

/**
 * Plan the close sequence for a DONE_PENDING+stably-idle assignment (§10). PURE +
 * deterministic. The exit prelude is derived from the template's `agent.exit`:
 *   - `{ text }`  → `sendText(text)` then (unless `submit:false`) `sendKey "enter"` —
 *     for agents that exit via a TYPED command (Claude Code's `/quit`).
 *   - `{ keys }`  → one `sendKey` per key (verbatim).
 *   - both        → the text prelude THEN the keys.
 *   - absent      → the default `["ctrl-d"]` shell-EOF.
 * Then one `awaitExited` (bounded) → one `forceClose`. The loop executes in order:
 * make the child exit, wait (bounded) for `exited`, then confirm-bypass close; on a
 * successful close it frees the key + grid slot and starts the key's COOLDOWN. (On the
 * `awaitExited` timeout the loop force-closes anyway — so an agent like Claude Code
 * whose `/quit` leaves the launching shell alive still tears down.)
 */
export function closeSequencePlan(
  _assignment: Assignment,
  template: QueueTemplate,
): CloseStep[] {
  const ex = template.agent.exit;
  const steps: CloseStep[] = [];
  if (ex?.text !== undefined && ex.text.length > 0) {
    steps.push({ kind: "sendText", text: ex.text });
    if (ex.submit !== false) steps.push({ kind: "sendKey", key: "enter" });
  }
  const keys =
    ex?.keys && ex.keys.length > 0
      ? ex.keys
      : ex?.text
        ? [] // a text-only exit: no implicit Ctrl-D
        : DEFAULT_EXIT_KEYS;
  for (const key of keys) steps.push({ kind: "sendKey", key });
  steps.push({ kind: "awaitExited" });
  steps.push({ kind: "forceClose" });
  return steps;
}

// ---------------------------------------------------------------------------
// Cooldown helpers (§6) — pure time math the loop uses to manage the cooldown map.
// ---------------------------------------------------------------------------

/** The default cooldown window after a key FINISHES/closes (§6): ≈2 minutes, so a
 *  stale `list` can't immediately re-dispatch a just-completed key. */
export const DEFAULT_COOLDOWN_MS = 120_000;

/** The `until` timestamp for a key entering COOLDOWN at `nowMs`. PURE. The loop
 *  records `cooldown.set(key, cooldownUntil(nowMs, ms))`; `selectCandidates` then
 *  skips the key while `nowMs < until`. */
export function cooldownUntil(nowMs: number, cooldownMs: number = DEFAULT_COOLDOWN_MS): number {
  return nowMs + cooldownMs;
}

/** Whether a key's cooldown has EXPIRED at `nowMs` (so the loop can drop the entry).
 *  PURE. An absent entry is treated as expired (true). */
export function cooldownExpired(
  cooldown: Map<string, number>,
  key: string,
  nowMs: number,
): boolean {
  const until = cooldown.get(key);
  if (until === undefined) return true;
  return nowMs >= until;
}

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
 * The remaining dispatch SLOTS = the smaller of remaining concurrency and remaining
 * grid capacity (§7/§12). PURE. `activeCount` is the number of assignments currently
 * occupying a slot (RUNNING/SPAWNED/etc — the caller decides which states count, but
 * typically every non-terminal, non-cooldown assignment). `globalRemaining` caps the
 * WHOLE fleet across runs (`agent-queue-max-total`). The result is floored at 0.
 */
export function remainingSlots(
  template: QueueTemplate,
  activeCount: number,
  globalRemaining: number,
): number {
  const gridCapacity = template.grid.cols * template.grid.rows;
  const concurrencyRoom = template.concurrency - activeCount;
  const gridRoom = gridCapacity - activeCount;
  return Math.max(0, Math.min(concurrencyRoom, gridRoom, globalRemaining));
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
   *  gate keys on this — NEVER on `idleSeconds` (a repainting TUI never idles by
   *  `idleSeconds`, §2). */
  agentState?: string;
  /** Did the surface's child process EXIT (process_exited)? (§6 EXITED). */
  exited: boolean;
  /** ms-since-epoch the agentState last BECAME "idle" UNCHANGED (the idle-debounce
   *  anchor). The loop stamps it when it observes idle and RESETS it to undefined on
   *  any non-idle observation (a flap), so a stable idle of `closeStableSeconds`
   *  requires `agentState==="idle"` held continuously. `undefined` = not currently
   *  idle (or just flapped). */
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
 *   - DONE_PENDING → CLOSING: `agentState === "idle"` held UNCHANGED for
 *     `closeStableSeconds` — i.e. `idleStableSinceMs` is set AND `nowMs -
 *     idleStableSinceMs >= closeStableSeconds*1000` — AND `closeOnComplete !== false`.
 *     A flap (idleStableSinceMs undefined) HOLDS in DONE_PENDING (never closes early).
 *     A template with `closeOnComplete === false` HOLDS in DONE_PENDING forever (the
 *     done split is left open for manual close, §5/§6/§10). `idleSeconds` is NEVER
 *     consulted (§10). EXCEPTION: a DONE_PENDING assignment whose CHILD has already
 *     EXITED short-circuits straight to CLOSING (when `closeOnComplete !== false`),
 *     since the idle-hold would never be satisfied by a child that crashed/exited
 *     before reporting a stable idle — without this the slot would be held forever.
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
    if (ctx.closeOnComplete === false) {
      return "DONE_PENDING"; // opted out of auto-close → leave open for manual close
    }
    // A provider-done agent whose CHILD has already EXITED is done draining: short-circuit
    // straight to CLOSING (don't wait on the idle-hold, which a crashed-before-idle child
    // would never satisfy → the slot would be held forever). The close sequence then just
    // force-closes the already-exited split.
    if (ctx.exited) {
      return "CLOSING";
    }
    if (
      ctx.agentState === "idle" &&
      typeof ctx.idleStableSinceMs === "number" &&
      ctx.nowMs - ctx.idleStableSinceMs >= ctx.closeStableSeconds * 1000
    ) {
      return "CLOSING";
    }
    return "DONE_PENDING"; // not stably idle / flapped → hold
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

/**
 * Fold the idle-debounce ANCHOR. PURE. Given the PRIOR `idleStableSinceMs` and the
 * CURRENTLY-observed agentState + `nowMs`, return the next anchor:
 *   - agentState === "idle" AND a prior anchor exists  → KEEP the prior anchor
 *     (idle has been continuously held — do NOT reset the clock).
 *   - agentState === "idle" AND no prior anchor        → START the clock at `nowMs`.
 *   - any non-idle agentState (working/waiting/etc/undefined) → RESET to undefined
 *     (a flap; the next idle restarts the clock from scratch).
 * This is what makes "idle UNCHANGED for closeStableSeconds" a true HOLD that a flap
 * resets (§6/§10) — `nextState` reads the resulting anchor.
 */
export function foldIdleAnchor(
  priorAnchorMs: number | undefined,
  agentState: string | undefined,
  nowMs: number,
): number | undefined {
  if (agentState === "idle") {
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

// (ramon fork / Agent Queue Supervisor) Shared queue types. Mirrors the locked
// design spec (§4–§14). These are the JSON shape of a queue TEMPLATE (team policy,
// §5), the WorkItem the genericity-boundary providers emit (§5), and the runtime
// Assignment + its state-machine (§6) the supervisor tracks and persists (§9).
//
// PURE type declarations only — no I/O, no behavior. The genericity invariant
// (the #1 requirement) is expressed in the types: a provider is a command (argv
// array, JSON over stdout); item fields reach the agent as ENV VARS, never spliced
// into a shell line. NOTHING here is Linear/Git/issue-key aware.

// ---------------------------------------------------------------------------
// Queue template (§5) — the team-specific policy layer, authored as JSON.
// ---------------------------------------------------------------------------

/** How a grid fills its slots: row-major ("columns" — fill a row of columns
 *  before starting the next row) or column-major ("rows"). See §12. */
export type GridFill = "columns" | "rows";

/** The grid geometry of a queue run's tab (§12). Effective max splits = cols*rows. */
export interface GridSpec {
  cols: number;
  rows: number;
  fill: GridFill;
}

/** Poll cadences (§5). `listMs` = how often to re-poll the source list for new /
 *  newly-unblocked items; `statusMs` = how often to probe per-key completion. */
export interface IntervalsSpec {
  listMs: number;
  statusMs: number;
}

/** The `list` provider command: emits a JSON array of items on stdout; the field
 *  names map source fields → WorkItem. keyField is REQUIRED (the dedup identity);
 *  title/url are optional. The genericity seam (§5). */
export interface ProviderListSpec {
  command: string[];
  keyField: string;
  titleField?: string;
  urlField?: string;
}

/** The `status` provider command: a per-key terminal probe emitting
 *  `{"state":"..."}`. Terminal iff `state ∈ doneStates`. The ONLY completion source
 *  of truth (§8/§13) — never inferred from agent idleness. `{key}` is an argv
 *  element, substituted safely (never shell-spliced). */
export interface ProviderStatusSpec {
  command: string[];
  doneStates: string[];
}

/** The OPTIONAL `claim` provider command (§5/§7): fire-and-forget after dispatch to
 *  remove the item from the source sooner. A LATENCY optimization, NEVER a
 *  correctness dependency — dedup holds with no claim (§7). */
export interface ProviderClaimSpec {
  command: string[];
}

/** The provider triple (§5). */
export interface ProviderSpec {
  list: ProviderListSpec;
  status: ProviderStatusSpec;
  claim?: ProviderClaimSpec;
}

/** The agent launch spec (§5). `command` is the shell command the split runs (item
 *  fields reach it as GHOSTTY_ITEM_* ENV VARS, never spliced — §13). `exit` (optional)
 *  describes how to make the agent EXIT before close so the close doesn't hit the
 *  confirm dialog (§10):
 *    - `text`   : a TYPED exit command (e.g. Claude Code's "/quit", which swallows
 *                 Ctrl-D) — typed via send_text, then submitted with Enter unless
 *                 `submit:false`.
 *    - `submit` : whether to press Enter after `text` (default true).
 *    - `keys`   : control keys to send (e.g. ["ctrl-d"]); names must be ones the MCP
 *                 send_key tool recognizes ("ctrl-d","enter","esc",…).
 *  When `exit` is absent the default is a single Ctrl-D ("ctrl-d"). `text` and `keys`
 *  may be combined (text prelude, then keys). */
export interface AgentSpec {
  command: string;
  exit?: { text?: string; submit?: boolean; keys?: string[] };
}

/** What to do when an agent EXITS early, before provider completion (§6). v1 locks
 *  the single behavior `"leave-and-bell"` (keep the dead split for human review,
 *  free the slot, ring the bell everywhere). Typed as a union so future modes are
 *  additive. */
export type OnAgentExit = "leave-and-bell";

/** A fully-parsed, validated queue template (§5). The runtime engine consumes this;
 *  it is produced by `validateTemplate` from raw JSON. */
export interface QueueTemplate {
  /** Shown as the dashboard ORIGIN (§11). Stable identity of the run. */
  name: string;
  /** The split cwd; `~` is expanded macOS-side (the sidecar passes it through). */
  workdir: string;
  agent: AgentSpec;
  /** Max simultaneous agents, clamped to the grid cap (cols*rows) by the validator. */
  concurrency: number;
  /** Hard ceiling on total LIFETIME dispatches for this run (§7). */
  maxItems: number;
  grid: GridSpec;
  intervals: IntervalsSpec;
  provider: ProviderSpec;
  onAgentExit: OnAgentExit;
  closeOnComplete: boolean;
  /** agentState==idle, unchanged this long, before the close sequence fires (§10). */
  closeStableSeconds: number;
  /** When true, the RUN quits (removes itself from the registry) as soon as a sweep
   *  observes a SUCCESSFUL EMPTY `list` AND it has no active assignments — i.e. there
   *  is nothing left to do, even before `maxItems` is reached. A flaky/failed `list`
   *  (which is treated as "skip", not "empty") never triggers it, and a momentary
   *  empty list while agents are still running does NOT quit (active > 0) — the run
   *  keeps polling for new/unblocked items until BOTH the queue and the fleet are
   *  empty. Default false (poll forever). */
  quitWhenEmpty: boolean;
}

// ---------------------------------------------------------------------------
// Work item (§5) — the genericity-boundary unit a provider emits.
// ---------------------------------------------------------------------------

/** One actionable item from the provider `list`. `key` is the stable dedup
 *  identity (REQUIRED). title/url are optional; `meta` is arbitrary extra fields
 *  surfaced to the agent as GHOSTTY_ITEM_META_* env vars (§13). */
export interface WorkItem {
  key: string;
  title?: string;
  url?: string;
  meta?: Record<string, string>;
}

// ---------------------------------------------------------------------------
// Assignment lifecycle (§6) — the supervisor's unit of tracking + persistence.
// ---------------------------------------------------------------------------

/**
 * The assignment state machine (§6):
 *
 *   QUEUED ──dispatch──► SPAWNED ──agentKind/State seen──► RUNNING
 *                          │ spawn failed                    │ status==done
 *                          ▼                                 ▼
 *                        FAILED                          DONE_PENDING
 *                                                            │ idle held ≥ closeStableSeconds
 *                                                            ▼
 *                                                         CLOSING ──► FINISHED ──► COOLDOWN
 *
 *   EXITED: process exited early (before completion) — keep the split (leave-and-bell),
 *           free the slot. NOT auto-re-queued.
 */
export type AssignmentState =
  | "QUEUED"
  | "SPAWNED"
  | "RUNNING"
  | "DONE_PENDING"
  | "CLOSING"
  | "FINISHED"
  | "FAILED"
  | "EXITED"
  | "COOLDOWN";

/** A live binding of a work-item key to a spawned surface, with lifecycle state.
 *  The supervisor's unit of tracking; persisted by `sessionID` across restarts
 *  (§9). `surfaceUUID` is freshly minted each GUI launch (NOT stable) — match by
 *  `sessionID`. Timestamps are ms-since-epoch supplied by the caller (the pure core
 *  never reads its own clock). */
export interface Assignment {
  /** The owning run's name (= dashboard origin). */
  queueName: string;
  /** The work-item dedup key. */
  key: string;
  /** The stable host session id — the persistence/re-adoption key (§9). 0/absent
   *  until the spawn returns it. */
  sessionID: number;
  /** The current GUI surface UUID (freshly minted each launch; null until known). */
  surfaceUUID?: string;
  /** The grid slot index this assignment occupies (§12). */
  gridSlot: number;
  state: AssignmentState;
  /** ms-since-epoch the assignment ENTERED its current state (for the idle-hold /
   *  cooldown timers). Supplied by the loop's clock; the pure core never reads it. */
  sinceMs: number;
  /** Optional human-readable detail (e.g. the work-item title), display-only. */
  title?: string;
  /** Optional work-item url, display-only / for the dashboard badge. */
  url?: string;
}

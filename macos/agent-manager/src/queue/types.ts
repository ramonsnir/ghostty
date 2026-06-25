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

/** The OPTIONAL `graph` provider command (backlog graph): emits the run's WHOLE scoped
 *  board (ALL states — not just actionable, unlike `list`) as JSON for the dashboard's
 *  backlog-graph canvas. A grooming/debug affordance, NEVER part of dispatch — the engine
 *  only fetches it (throttled at `intervals.listMs`) to cache + push to the GUI; it never
 *  drives a dispatch/completion decision. Absent ⇒ no backlog button (the feature is
 *  silently off). PURE GENERICITY: like `list`/`status`, it is a command emitting JSON; the
 *  SCRIPT decides terminality (`done`) and category (`stateType`) — Ghostty maps neither
 *  to any tracker. */
export interface ProviderGraphSpec {
  command: string[];
}

/** The provider triple (§5) + the optional backlog `graph` source. */
export interface ProviderSpec {
  list: ProviderListSpec;
  status: ProviderStatusSpec;
  claim?: ProviderClaimSpec;
  graph?: ProviderGraphSpec;
}

/** (backlog graph) One node of the OPTIONAL `provider.graph` board — the FULL set of items
 *  in the run's scope (every state), with labels + dependency edges, rendered as a DAG in
 *  the dashboard's backlog canvas. GENERIC: the provider SCRIPT decides `done` (terminal,
 *  like status `doneStates`) and the coarse `stateType` category; Ghostty maps neither to a
 *  tracker. Edges in `blockedBy` may reference keys not present in the node set (e.g. a
 *  blocker outside the scope) — the GUI just ignores dangling edges. */
export interface GraphNode {
  /** Stable item identity (matches a WorkItem.key / the status key). REQUIRED. */
  key: string;
  /** Display title (optional). */
  title?: string;
  /** Item URL for the canvas "open" affordance (optional). */
  url?: string;
  /** Display workflow-state name, e.g. "In Progress" (optional). */
  state?: string;
  /** Coarse workflow-state CATEGORY for the node color (e.g. "started"/"completed");
   *  free-form — the GUI maps known categories to colors and anything else to neutral. */
  stateType?: string;
  /** Provider-declared TERMINAL flag (done/canceled/duplicate/…): excluded from the
   *  backlog count and dimmed in the canvas. The SCRIPT decides (mirrors status doneStates). */
  done: boolean;
  /** Free-form labels (e.g. "Design needed", "Customer input"). */
  labels: string[];
  /** Keys of items that BLOCK this one — the DAG's dependency edges. */
  blockedBy: string[];
  /** GENERIC priority MARK (e.g. "Urgent", "High"): a provider-chosen display string the
   *  canvas renders as a prominent badge + tinted border so high-priority items stand out.
   *  The SCRIPT decides which items get one (its own threshold) and what it says — exactly
   *  like `done`/`stateType`, Ghostty never derives it from the tracker-specific `priority`
   *  int. Absent ⇒ no mark. The canvas colors it from a generic English-priority vocabulary
   *  (urgent/high/medium/low) with a neutral fallback, so an unknown label still renders. */
  priorityLabel?: string;
}

/** (backlog graph) The board snapshot the sidecar caches + pushes via `report_queue_graph`. */
export interface QueueGraph {
  nodes: GraphNode[];
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

/**
 * Where a resolved param value is DELIVERED (§8b):
 *   - "env"      (default): exported under `env` into the PROVIDER's environment (the
 *                `list`/`status`/`claim` commands read it) — scopes "what to work on".
 *   - "maxItems": sets the run's lifetime dispatch cap (overrides the template `maxItems`)
 *                instead of going to the provider. Parsed as a non-negative integer; `0`
 *                (or "unlimited") = no cap. Lets the user pick maxItems at start time
 *                (e.g. 1/2 for a careful run, unlimited otherwise) without editing files.
 */
export type QueueParamTarget = "env" | "maxItems";

/**
 * (§8b) A START-TIME PARAMETER the template declares (e.g. a Linear project or
 * milestone, or the run's maxItems). The GUI prompts for each when the queue is started;
 * the resolved value is delivered per `target` — for the default "env" target it is
 * injected into the PROVIDER's environment under `env` (so the SAME generic template can
 * be pointed at a different scope per run without editing files); for "maxItems" it sets
 * the run's dispatch cap. Keeps the design generic: the TEMPLATE names the env var / opts
 * into the maxItems prompt; Ghostty never hard-codes "Linear". An env param is delivered
 * ONLY to the provider commands, NOT to the agent (the agent gets per-item `GHOSTTY_ITEM_*`).
 */
export interface QueueParam {
  /** Identifier the GUI/command keys the user's answer by (e.g. "project"). */
  name: string;
  /** Where the value goes (default "env"). See QueueParamTarget. */
  target?: QueueParamTarget;
  /** The env var the resolved value is exported as to the provider commands (e.g.
   *  "LINEAR_PROJECT"). REQUIRED for the "env" target; ignored for "maxItems". */
  env?: string;
  /** Human prompt label (defaults to `name` when absent). */
  label?: string;
  /** Pre-filled value in the prompt (the common case is "accept the default"). */
  default?: string;
  /** When true the start is REJECTED if the resolved value is empty. Default false. */
  required?: boolean;
  /**
   * OPTIONAL value-suggestion provider (a GUI-only affordance): an argv command that
   * prints a JSON array of suggested values for this param — either bare strings
   * (`["Acme","Globex"]`) or `{value,label?}` objects. The GUI runs it (with the CURRENT
   * form values exported under the OTHER params' `env`, so a dependent provider — e.g.
   * milestones for the selected project — sees `$LINEAR_PROJECT`) and shows the results
   * as pickable suggestions, so the user doesn't have to type exact names. The SIDECAR
   * does NOT run this (it never dispatches from a suggestion); it is validated here only
   * so the template stays honest. Absent ⇒ no suggestions (free-text only).
   */
  valuesCommand?: string[];
}

/** A fully-parsed, validated queue template (§5). The runtime engine consumes this;
 *  it is produced by `validateTemplate` from raw JSON. */
export interface QueueTemplate {
  /** Shown as the dashboard ORIGIN (§11). Stable identity of the run. */
  name: string;
  /** The split cwd; `~` is expanded macOS-side (the sidecar passes it through). */
  workdir: string;
  agent: AgentSpec;
  /** (§8b) START-TIME parameters the GUI prompts for; each resolved value is injected
   *  into the provider command env. Empty array when absent (no prompt — prior behavior). */
  params: QueueParam[];
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
  // NOTE: there is intentionally NO `quitWhenEmpty`. A run is removed only by an explicit
  // stop/abort; an empty `list` just means "nothing actionable now" and the run keeps
  // polling. The old knob keyed on `active.size === 0`, which a transient/incomplete
  // post-restart `list_surfaces` could falsely produce (by pruning live records) → it would
  // silently abandon live agents + remove the whole run. Removed; any `quitWhenEmpty` in a
  // template JSON is now simply ignored.
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

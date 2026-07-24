// (ramon fork / Agent Queue Supervisor) Shared queue types. Mirrors the locked
// design spec (§4–§14). These are the JSON shape of a queue TEMPLATE (team policy,
// §5), the WorkItem the genericity-boundary providers emit (§5), and the runtime
// Assignment + its state-machine (§6) the supervisor tracks and persists (§9).
//
// PURE type declarations only — no I/O, no behavior. The genericity invariant
// (the #1 requirement) is expressed in the types: a provider is a command (argv
// array, JSON over stdout); item fields reach the agent as ENV VARS, never spliced
// into a shell line. NOTHING here is Linear/Git/issue-key aware.

import type { HostSpec } from "./hostpool.js";

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
  /** (hero) OPTIONAL JSON field name whose TRUTHY value marks the item a HERO — a
   *  load-bearing item that competes for YOUR ATTENTION, not a machine slot (see
   *  HERO-AGENTS.md). Mirrors title/url mapping: sourcing is QUEUE-DEFINED (e.g. a
   *  provider computes a boolean from a special label). Absent ⇒ no items are heroes
   *  from the list (promotion still works). Added to the parser's RESERVED set so the
   *  hero field never leaks into `meta`. */
  heroField?: string;
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
  /** Free-form labels (e.g. "Design needed", "backend", "Customer input") — the FULL
   *  display set, rendered as pills on the node card. NOT all of these necessarily block:
   *  a tracker's labels are a mix of gating markers (e.g. "Design needed") and purely
   *  informational tags (area/team). Use `blockedLabels` for the "why isn't this actionable"
   *  tooltip. */
  labels: string[];
  /** (ramon fork) The SUBSET of labels that are genuine BLOCKING reasons — the human
   *  "why this item isn't actionable yet" (e.g. only the "* needed" labels). The canvas's
   *  "Blocked on:" tooltip lists THESE, not every label. OPTIONAL: absent (undefined) ⇒ the
   *  provider doesn't distinguish, and the canvas falls back to `labels` (legacy behavior);
   *  present-but-empty ⇒ NO label is a blocking reason (labels are display-only). */
  blockedLabels?: string[];
  /** Keys of items that BLOCK this one — the DAG's dependency edges. */
  blockedBy: string[];
  /** GENERIC priority MARK (e.g. "Urgent", "High"): a provider-chosen display string the
   *  canvas renders as a prominent badge + tinted border so high-priority items stand out.
   *  The SCRIPT decides which items get one (its own threshold) and what it says — exactly
   *  like `done`/`stateType`, Ghostty never derives it from the tracker-specific `priority`
   *  int. Absent ⇒ no mark. The canvas colors it from a generic English-priority vocabulary
   *  (urgent/high/medium/low) with a neutral fallback, so an unknown label still renders. */
  priorityLabel?: string;
  /** (ramon fork / Hero Agents) True when this backlog item is a HERO — a load-bearing item
   *  that runs in its own tab, capped by the fleet-wide `agent-queue-hero-max` (see HERO-AGENTS.md).
   *  Sourced two ways, OR'd together (`refreshGraph`): the provider `graph` output may set it
   *  directly (queue-defined, like `done`/`priorityLabel`), AND the sidecar marks any node whose
   *  key is a known hero — a `list` item with a truthy `heroField`, or a PROMOTED key in the
   *  run-level `hero` set. So a hero reads as a hero in the backlog REGARDLESS of whether it is
   *  currently blocked on the hero-slot gate (the `heroSlots` blockReason drives only the extra
   *  "why is it waiting" tooltip). Absent ⇒ regular item. */
  hero?: boolean;
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

/** (ramon fork / Agent Queue — Schedules) One SCHEDULE: a recurring, low-cognition
 *  scan agent that periodically sweeps the queue's project (docs / backlog / code) and
 *  opens or amends backlog issues — "project/tech-debt maintenance" work the human
 *  shouldn't have to remember to trigger. See AGENT-QUEUE.md → Schedules and
 *  queue/schedule.ts for the timing model. A schedule is NOT a WorkItem: it is not
 *  emitted by the provider `list`, not counted against `concurrency`/`maxItems`/
 *  `agent-queue-max-total`, and its "completion" is its SPLIT CLOSING (not a provider
 *  `status` round-trip). It runs in the SAME grid/tab as regular work agents.
 *
 *  Autonomy is entirely a matter of the PROSE (`promptFile`/`prompt`): the prompt tells
 *  the agent what it may do — open issues (with an agreed auto-generated label so they
 *  are recognizable), amend an existing one, or accept it is already in progress — and
 *  Ghostty adds no special issue-creation machinery. Dedup is handled by the cadence
 *  (roughly-once-per-cycle) plus the prose ("check existing issues first"). */
export interface ScheduleSpec {
  /** Stable identity: the single-flight key (never two runs of the SAME id at once)
   *  and the persistence key for this schedule's cadence state. REQUIRED, non-empty. */
  id: string;
  /** Display name for the dashboard Schedules lane (defaults to `id` when absent). */
  name?: string;
  /** The cadence: a 5-field LOCAL-time cron expression (see queue/schedule.ts), e.g.
   *  `0 9 * * 1-5` (weekday 9am) or `0 9,13,17 * * 1-5` (weekdays 9/13/17). REQUIRED;
   *  validated at template load (a bad expression rejects the template). */
  cron: string;
  /** The prose scan instruction. Exactly ONE of `promptFile` (a path relative to the
   *  template's directory) or `prompt` (inline) is REQUIRED; the loader resolves `promptFile`'s
   *  ABSOLUTE path into `promptFilePath` (and its content into `prompt`, for inline callers).
   *
   *  ⚠️ Delivery is via ENV, NOT typed input — and, crucially, the PROSE ITSELF IS NOT PUT ON
   *  THE COMMAND LINE. `spawn_split_command` delivers a split's command as `initialInput` (typed
   *  into the shell, interior newlines collapsed): a large multi-line non-ASCII prose there gets
   *  mangled (em-dashes → control-char garbage, interleaved with the shell's login banner, never
   *  cleanly submitted). So the runner passes a SHORT env instead:
   *    - `promptFile` present ⇒ `GHOSTTY_SCHEDULE_PROMPT_FILE` = its absolute path; the launcher
   *      reads the file (`cat`) — full UTF-8 + newlines preserved.
   *    - inline `prompt` (no file) ⇒ `GHOSTTY_SCHEDULE_PROMPT` = the inline text (keep it SHORT +
   *      single-line-ish; long/multi-line prose MUST use `promptFile`).
   *  Same "context via env" contract as a work item's GHOSTTY_ITEM_* (§13). */
  promptFile?: string;
  prompt?: string;
  /** (INTERNAL — set by the loader, not authored) The resolved ABSOLUTE path of `promptFile`.
   *  Delivered to the agent as `GHOSTTY_SCHEDULE_PROMPT_FILE` (short, ASCII) so the launcher
   *  reads the prose from the file instead of us putting the whole prose on the command line. */
  promptFilePath?: string;
  /** The shell command the scheduled split runs (defaults to the template's `agent.command`
   *  when absent). It receives `GHOSTTY_SCHEDULE_PROMPT_FILE` (or `GHOSTTY_SCHEDULE_PROMPT` for
   *  inline) + `GHOSTTY_SCHEDULE_ID` / `GHOSTTY_SCHEDULE_NAME` + the run's resolved param env
   *  (e.g. LINEAR_PROJECT) and must USE the prompt (a bare interactive `claude` would ignore it),
   *  e.g. `claude "$(cat "$GHOSTTY_SCHEDULE_PROMPT_FILE")"`. NOTE: the default `agent.command` is
   *  the WORK-ITEM launcher, which typically expects GHOSTTY_ITEM_* — a schedule usually needs
   *  its OWN launcher. */
  command?: string;
  /** When true (the DEFAULT), a scheduled split whose agent has EXITED is force-closed
   *  automatically (hands-off cycle). When false, an exited scheduled split is LEFT
   *  OPEN (leave-and-bell) for manual review; you close it when done. EITHER WAY the
   *  schedule's cadence re-arms only once the split actually CLOSES (by any cause —
   *  auto-close, agent exit + auto-close, or a human closing it). NOT hook/idle-driven. */
  closeOnComplete?: boolean;
}

/** A fully-parsed, validated queue template (§5). The runtime engine consumes this;
 *  it is produced by `validateTemplate` from raw JSON. */
export interface QueueTemplate {
  /** Shown as the dashboard ORIGIN (§11). Stable identity of the run. */
  name: string;
  /** (ramon fork / cloud-hosts, Phase 4 O1) The REMOTE host this queue's AGENT splits run
   *  on — a name in the `pty-remote-host` registry (resolved macOS-side to a forwarded socket).
   *  Default `"local"` (the laptop's `pty-host` scalar / prior behavior). The PROVIDER commands
   *  (`list`/`status`/`claim`/`graph`) ALWAYS run laptop-side (adopt option (b)); only the agent
   *  split is placed on `host`. When `host !== "local"` the agent's cwd + template dir are the
   *  HOST-RELATIVE `agentWorkdir` / `remoteTemplateDir` (NOT laptop-expanded). See CLOUD-HOSTS.
   *  OPTIONAL in the type (validateTemplate ALWAYS sets it to "local" when the JSON omits it);
   *  every runtime read defaults `?? "local"`, so a test/template literal without `host` is local.
   *
   *  (ramon fork / cloud-hosts, Phase 5) When the template declares a `hosts[]` POOL, that pool
   *  is authoritative for PLACEMENT (see `hosts`); this scalar `host` remains the single-entry
   *  fallback (and the pre-pool wire) so a template with only `host` is a single-entry pool. */
  host?: string;
  /** (ramon fork / cloud-hosts, Phase 5 — MULTI-HOST load balancing) The weighted host POOL the
   *  supervisor spreads this queue's AGENT splits across by CAPACITY (see CLOUD-QUEUE-BALANCING.md
   *  + queue/hostpool.ts). When present + non-empty it is authoritative for placement (each new
   *  agent goes to `argmin(activeOnHost / (maxConcurrent × weight))` among hosts with a free slot);
   *  a full/down pool makes the item WAIT with a `hostCapacity` block reason. ABSENT ⇒ the scalar
   *  `host` is used as a single UNBOUNDED-capacity pool (byte-identical to the pre-pool behavior).
   *  Runtime code reads the NORMALIZED pool (`normalizeHostPool(template)`), never this field or
   *  the scalar directly, so a half-migration can't silently route everything to `local`. */
  hosts?: HostSpec[];
  /** (ramon fork / cloud-hosts, Phase 4 O1) The agent split's cwd WHEN `host !== "local"` — an
   *  ABSOLUTE path ON THE BOX (host-relative). NOT `~`-expanded against the LAPTOP home (the box's
   *  home differs); passed through verbatim. Absent ⇒ the agent split falls back to `workdir`
   *  (only sensible for a local run). Ignored when `host === "local"`. */
  agentWorkdir?: string;
  /** (ramon fork / cloud-hosts, Phase 4 O1) The template's script directory ON THE BOX (absolute,
   *  host-relative) — routed into the AGENT `agent.command`'s `{templateDir}` token +
   *  `GHOSTTY_QUEUE_TEMPLATE_DIR` when `host !== "local"`, so a shared-repo agent launcher can find
   *  its sibling scripts on the box. The four PROVIDER/param `{templateDir}` sites keep the LAPTOP
   *  dir (they run laptop-side). Absent / local ⇒ the laptop template dir is used everywhere. */
  remoteTemplateDir?: string;
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
  /** (schedules) The recurring scan agents this queue runs (see ScheduleSpec). Empty
   *  array when the template declares none (the prior behavior — no schedules). */
  schedules: ScheduleSpec[];
  /** (keep) The per-QUEUE default for "keep" — when true, a completed split is KEPT OPEN
   *  (held in DONE_PENDING, never auto-closed) by default so you can do manual work in it
   *  after the task is done; a per-split toggle (the dashboard 📌 pin → the `set_keep`
   *  command → the run's `keep` map) OVERRIDES this either way. Default false (auto-close,
   *  the prior behavior). Distinct from `closeOnComplete:false`, which is the HARD,
   *  template-wide never-auto-close with NO per-split override; `keepOnComplete:true` is a
   *  SOFT default the per-split pin can turn off. A kept split still OCCUPIES its slot
   *  (same as `closeOnComplete:false`), so the queue won't dispatch into it until it is
   *  closed. */
  keepOnComplete: boolean;
  /** agentState==idle, unchanged this long, before the close sequence fires (§10). */
  closeStableSeconds: number;
  // NOTE: there is intentionally NO `quitWhenEmpty`. A run is removed only by an explicit
  // stop/abort; an empty `list` just means "nothing actionable now" and the run keeps
  // polling. The old knob keyed on `active.size === 0`, which a transient/incomplete
  // post-restart `list_surfaces` could falsely produce (by pruning live records) → it would
  // silently abandon live agents + remove the whole run. Removed; any `quitWhenEmpty` in a
  // template JSON is now simply ignored.
}

/** (hero) The set of dispatch GATES that can currently block a WAITING item, carried
 *  per-item in the status report (`QueueItemRef.blockReasons`) so the backlog canvas can
 *  say EXACTLY why an item hasn't dispatched (e.g. a hero stuck on `heroSlots` — nobody
 *  should waste time bumping `maxItems`). Dependency-blocked is intentionally NOT a reason
 *  here (the graph edges already show it). See HERO-AGENTS.md → backlog waiting states.
 *   - "maxItems"          — the run's lifetime dispatch budget is exhausted.
 *   - "queueConcurrency"  — the run's `concurrency` slots are all occupied.
 *   - "globalConcurrency" — the fleet-wide `agent-queue-max-total` is exhausted.
 *   - "heroSlots"         — a HERO item and the fleet-wide `agent-queue-hero-max` is full.
 *   - "hostCapacity"      — (cloud-hosts Phase 5) the item cleared its OTHER gates but NO host in
 *                           the queue's pool has a free slot (every box is at its `maxConcurrent`,
 *                           or down + on cooldown). Computed only AFTER the concurrency/maxItems/
 *                           hero gates clear, so the operator is never told to bump `maxItems`
 *                           when the real block is a full/down box. */
export type BlockReason =
  | "maxItems"
  | "queueConcurrency"
  | "globalConcurrency"
  | "heroSlots"
  | "hostCapacity";

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
  /** (hero) True when the provider `heroField` marked this item load-bearing (see
   *  HERO-AGENTS.md). Parsed from `heroField`; absent/false ⇒ a regular item. A hero
   *  dispatches into its OWN tab and is gated by the fleet-wide `agent-queue-hero-max`
   *  cap, orthogonal to the regular concurrency/maxItems/max-total pools. */
  hero?: boolean;
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
   *  until the spawn returns it. NOTE: only unique WITHIN a host — the cross-host
   *  persistence/re-adoption key is the `(hostName, sessionID)` PAIR (see `sessionKey` +
   *  `Assignment.hostName`), so two boxes can each mint session id 5 without colliding. */
  sessionID: number;
  /** (ramon fork / cloud-hosts, Phase 4 Q1) The host this assignment's session lives on —
   *  paired with `sessionID` to form the cross-host identity key (`sessionKey`). Recorded from the
   *  DISPATCH CONTEXT (`template.host`), NOT the spawn reply (which carries only a numeric id).
   *  OPTIONAL / OMITTED ⇒ `"local"` (a laptop/local session, or a pre-migration store record with
   *  no host) — every read defaults to `"local"` and a local record OMITS it, so all existing
   *  single-host state serializes + round-trips BYTE-IDENTICALLY. Set (to a non-"local" name) only
   *  for a remote-host dispatch. */
  hostName?: string;
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
  /** (hero) Whether this assignment is a HERO (see HERO-AGENTS.md). Rehydrated on
   *  restart like `keep`/`dispatched` (run-level state), so a promoted split comes back
   *  a hero after a GUI restart. A hero is counted against the fleet-wide
   *  `agent-queue-hero-max` cap (orthogonal to the regular concurrency/maxItems/max-total
   *  pools), is kept-by-default (never auto-closed), and lives in its own dedicated tab.
   *  Flipped by the `promote`/`demote` commands. */
  hero: boolean;
}

// ---------------------------------------------------------------------------
// (ramon fork / cloud-hosts, Phase 4 Q1/Q2) Cross-host identity key.
// ---------------------------------------------------------------------------

/**
 * The CROSS-HOST session identity key: `"${hostName}:${sessionID}"`. PURE. This is the
 * EXACT composite the macOS `MCPLayout.surfacesJSONData` emits for a `list_surfaces` row's
 * `sessionID` (the matched Q2 emit↔parse pair), so the sidecar keys its reconcile /
 * schedule maps on it. A numeric `sessionID` is unique only WITHIN a host — pairing it with
 * the host lets two boxes each mint id 5 without a false reconcile match.
 */
export function sessionKey(hostName: string, sessionID: number): string {
  return `${hostName}:${sessionID}`;
}

/**
 * Parse a WIRE `sessionID` value (the `list_surfaces` composite string, or a legacy bare
 * number, or absent) into the `(hostName, sessionID)` pair. PURE + TOLERANT — the matched
 * PARSE side of the Q2 emit. Rules (must agree with the macOS emit byte-for-byte):
 *   - a `number` (pre-migration emit) → `{hostName:"local", sessionID:n}`;
 *   - a string with a colon → split on the LAST `:` into `(hostName, u64)`; an empty
 *     left side or an unparseable right side falls back to `"local"` / `0`;
 *   - a string with NO colon → a bare-number legacy value → host `"local"`, id = parsed int;
 *   - anything else (undefined / null / NaN) → `{hostName:"local", sessionID:0}`.
 * A `sessionID` of 0 is "unknown / not yet attached" — never a match key (the caller skips it).
 */
export function parseSessionKey(raw: unknown): { hostName: string; sessionID: number } {
  if (typeof raw === "number") {
    return { hostName: "local", sessionID: Number.isFinite(raw) && raw > 0 ? Math.floor(raw) : 0 };
  }
  if (typeof raw !== "string" || raw.length === 0) {
    return { hostName: "local", sessionID: 0 };
  }
  const idx = raw.lastIndexOf(":");
  if (idx < 0) {
    // Bare-number legacy value with no host prefix.
    const n = Number.parseInt(raw, 10);
    return { hostName: "local", sessionID: Number.isFinite(n) && n > 0 ? n : 0 };
  }
  const host = raw.slice(0, idx);
  const idStr = raw.slice(idx + 1);
  const n = Number.parseInt(idStr, 10);
  return {
    hostName: host.length > 0 ? host : "local",
    sessionID: Number.isFinite(n) && n > 0 ? n : 0,
  };
}

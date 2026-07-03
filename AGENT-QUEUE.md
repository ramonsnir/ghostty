# Agent Queue Supervisor (fork-only)

Turns the [Agent Dashboard](AGENT-DASHBOARD.md) / [Agent Manager](AGENT-MANAGER.md)
from a passive **observer** into an active **supervisor + driver**: you start a
**queue** from a template ("work this repo + this Linear filter") and the manager
opens a tab of splits, launches one CLI agent per work item, never doubles up on the
same item, caps how many run at once, tracks each to completion, and closes its split
when the item is **done** and the agent has gone **quiescent** (idle or waiting) —
periodically re-polling the source for new / newly-unblocked items.

It is **off by default**, macOS-only, and — this is the load-bearing design choice —
**completely generic**: Ghostty links no Linear/GitHub/Jira client and knows nothing
about "issues". *You* write a tiny **queue template** (a JSON file) that names a couple
of shell commands; that template is the only place your team's tooling lives.

## How it works (one paragraph)

The queue runs inside the same **TypeScript sidecar** the Agent Manager uses
(`macos/agent-manager/`), as a third deterministic pass on its ~5s loop — **no LLM in
the control path**. When you start a queue, the sidecar runs the template's **`list`**
command (which prints the actionable work items as JSON), dispatches up to your
**concurrency** limit by opening splits via the in-app MCP server (`spawn_split_command`)
each running the template's **agent command** with the item's fields delivered as
environment variables, polls the template's **`status`** command per item, and once an
item reports a terminal state **and** its agent has been quiescent (idle or waiting) a
few seconds, types the template's exit keys and **force-closes** the split (unless it's KEPT or a
[hero](#hero-agents-a-separate-attention-bounded-pool) — those are held open). The whole thing is restart-proof:
run state is persisted by the sidecar and re-adopted (by stable host session id) after a
sidecar **or** GUI restart, so it never double-dispatches an item or orphans a live
agent. Everything else — bells, the dashboard, per-tile summaries, web-push —
keeps working; queue splits are ordinary agent tiles, now **grouped by their queue**.

## Requirements

The supervisor **self-disables silently** (one info log) unless all of these hold:

1. **pty-host** (`pty-host = …`) — detection (`agentKind`) and the stable session ids the
   restart-resilience relies on both need it.
2. **The sidecar can run** — `mcp-listen`/`mcp-token` set, `node` resolvable, and the sidecar
   built (`cd macos/agent-manager && npm ci && npm run build`). The queue and the Haiku
   summarizer (Agent Manager) share **one sidecar**, but are **independent**: the shared
   sidecar launches when **either** `agent-queue` **or** `agent-manager` is `true`, so you do
   **not** need `agent-manager = true` to run a queue. Set `agent-queue = true` alone and the
   sidecar runs the queue with the summarizer (and its Haiku billing) fully off. (See
   `AGENT-MANAGER.md`; turning on `agent-manager` too just adds the per-tile Haiku summaries.)
3. **Claude Code hooks installed** (the Agent-Dashboard ones) — the close-gate keys off the
   hook-driven agent state: it closes once the item is provider-`done` **and** the agent has
   been **quiescent** (`idle` *or* `waiting`) for a few seconds. *Without the hooks a queue can
   dispatch and track but will not auto-close* (Claude Code is a repainting TUI, so the
   idle heuristic never fires). **Install them the easy way:** run **"Install Claude Agent
   Hooks"** from the Command Palette (cmd+shift+p), or accept the one-time prompt offered on
   launch when the queue/manager is enabled (it backs up + merges `~/.claude/settings.json`
   safely; re-running is a no-op). A manual copy/merge fallback is in `AGENT-DASHBOARD.md`.
   The hooks post to the **installed Release** on the default MCP port, so run real queues
   there, not a dev `+1/+2` build.

> **Codex (and other non-Claude agents):** the launch command is generic and a Codex split
> will run + preview fine, but it **cannot auto-close in v1** — only Claude Code emits the
> agent-state hooks the close-gate needs. You'd close its splits by hand. (Codex hooks: TODO.)

## Enable

Add to `~/.config/ghostty-ramon/config` (fork-only keys — keep them here, not in the
shared `~/.config/ghostty/config`, which an official Ghostty also reads):

```
agent-queue = true
# Where queue templates live. REPEATABLE — a search LIST of base dirs, each scanned
# for `*.json` templates. The built-in default below is ALWAYS searched FIRST, so you
# only ADD extra dirs (e.g. a shared repo of team templates). A basename found in more
# than one dir resolves to the FIRST-in-search-order copy (your personal/default dir
# wins over a shared repo). `~` is expanded. See "Sharing queue templates across a repo".
#   default (always first, no need to list it):
#     ~/.config/ghostty-ramon/agent-manager/queues
#   add a shared repo (repeat the key for more):
# agent-queue-templates-dir = ~/git/your-project/ghostty-queues
# OPTIONAL global cap across ALL running queues combined (per-queue cap is in the
# template). Default 0 = UNLIMITED — a queue is bounded only by its own
# concurrency/maxItems/grid. Set a positive value only to opt into a fleet ceiling:
# agent-queue-max-total = 16
# HERO pool cap — fleet-wide CONCURRENCY ceiling on live HERO agents (the load-bearing,
# attention-scarce kind). Heroes run off the grid (no concurrency slot / max-total), but
# maxItems still caps them. Default 2 (a discipline limit). 0 = DISABLE hero concurrency.
# See "Hero agents" below:
# agent-queue-hero-max = 2
```

Quit + relaunch the fork, and rebuild the sidecar `dist` if you changed it. Nothing runs
until you **start** a queue.

## Writing a queue template

A template is a JSON file in the templates dir (e.g.
`~/.config/ghostty-ramon/agent-manager/queues/backlog.json`). **Nothing in it is
tracker-specific to Ghostty** — `list`, `status`, and the agent `command` are opaque
shell the engine just runs.

```jsonc
{
  "name": "my-team backlog",                 // the dashboard origin / run name
  "workdir": "~/git/ourservice",             // split working dir (~ expanded)
  "agent": {
    // Item fields arrive as ENV VARS — never spliced into the shell (injection-safe):
    //   GHOSTTY_ITEM_KEY  GHOSTTY_ITEM_TITLE  GHOSTTY_ITEM_URL  GHOSTTY_ITEM_META_*
    "command": "claude \"Work on $GHOSTTY_ITEM_KEY: $GHOSTTY_ITEM_TITLE ($GHOSTTY_ITEM_URL)\"",
    // How to make the agent EXIT before the split is closed (so the close doesn't hit
    // the confirm dialog, §10). Choose ONE form:
    //   "exit": { "keys": ["ctrl-d"] }      // control key(s) — DEFAULT is ["ctrl-d"]
    //   "exit": { "text": "/quit" }         // a TYPED command (e.g. Claude Code's /quit,
    //                                       // which swallows Ctrl-D); typed + Enter
    //   "exit": { "text": "/quit", "submit": false }  // type without pressing Enter
    "exit": { "keys": ["ctrl-d"] }
  },
  "concurrency": 3,                          // max simultaneous agents (TOTAL across tabs; may exceed one grid — see below)
  "maxItems": 200,                           // hard ceiling on total lifetime dispatches
  "grid": { "cols": 3, "rows": 3, "fill": "columns" },  // PANES PER TAB = cols×rows; if concurrency exceeds it, extra agents OVERFLOW to new tabs (e.g. concurrency 9 + 3×2 grid = 6 in tab 1 + 3 in tab 2). Panes auto-tile as a balanced split; `fill` / col-vs-row is IGNORED
  // NOTE: there is NO `quitWhenEmpty` — a run is removed only by an explicit Stop/Abort.
  // An empty `list` just means "nothing actionable now"; the run keeps polling. (A `quitWhenEmpty`
  // key here is silently ignored — it was removed after it abandoned live agents on a restart.)
  "intervals": { "listMs": 60000, "statusMs": 30000 },  // provider call cadence (see note below)
  "provider": {
    // LIST: print the actionable items as a JSON array. Expected to ALREADY exclude
    // blocked / claimed / done items (the queue has no dependency graph by design).
    "list": {
      "command": ["sh", "-lc", "linear-queue-list --filter <FILTER_ID>"],
      "keyField": "identifier", "titleField": "title", "urlField": "url",
      // HERO sourcing (optional): a JSON field whose TRUTHY value marks the item a HERO
      // (a load-bearing, attention-scarce item — see "Hero agents" below). Mirrors the
      // title/url mapping — sourcing is YOUR call (e.g. your list script emits `hero:true`
      // for items with a special label). Absent ⇒ no items are heroes from the list
      // (you can still PROMOTE a running regular by hand).
      "heroField": "hero"
    },
    // STATUS: print {"state":"..."} for one item ({key} is a safe argv element).
    "status": {
      "command": ["linear-issue-state", "{key}"],
      "doneStates": ["done", "canceled", "merged"]
    },
    // CLAIM (optional): run once after dispatch to remove the item from the source sooner.
    // Dedup does NOT depend on it — it's a latency optimization only.
    "claim": { "command": ["linear-claim", "{key}"] },
    // GRAPH (optional): print the WHOLE board — every item in scope, ALL states — for the
    // dashboard's "N backlog" button → a dependency-graph canvas. Output:
    //   {"nodes":[{"key","title?","url?","state?","stateType?","done","labels":[],"blockedBy":[],"priority?"}]}
    // `done` (terminal) + `stateType` (color category: backlog/unstarted/started/completed/
    // canceled/triage) are YOUR script's call — Ghostty maps no tracker. Fetched on the
    // `list` cadence; absent ⇒ no backlog button. NOT part of dispatch (grooming/debug only).
    "graph": { "command": ["linear-queue-graph"] }
  },
  "onAgentExit": "leave-and-bell",           // a crashed agent: keep the split for review + ring the bell everywhere
  "closeOnComplete": true,
  "keepOnComplete": false,                   // KEEP DEFAULT: when true, every completed split is left OPEN (held, slot kept) for manual work; the per-split 📌 pin overrides either way. Default false (auto-close).
  "closeStableSeconds": 5
}
```

### Start-time parameters (ask me when starting)

Instead of hard-coding the scope (e.g. a Linear project/milestone) in the provider command
or an env file, a template can declare **`params`** — and the queue **prompts you for them
when you start it**. Each answer is exported as an environment variable to your provider
commands, so one generic template can be pointed at a different project/milestone/etc. each
run with no file edits:

```jsonc
{
  "name": "ExampleOS",
  // … workdir / agent / provider as above …
  "params": [
    { "name": "project",    "env": "LINEAR_PROJECT",    "label": "Linear project",       "required": true,
      "valuesCommand": ["python3", "/abs/path/list-projects.py"] },
    { "name": "milestones", "env": "LINEAR_MILESTONES", "label": "Milestone(s), comma-sep",
      "valuesCommand": ["python3", "/abs/path/list-milestones.py"] },
    { "name": "maxItems",   "target": "maxItems",       "label": "Max items (0 = unlimited)", "default": "1" }
  ]
}
```

- On **Start**, a small form appears with one field per param, pre-filled with its `default`
  — usually you just press Enter. Each value is delivered per its **`target`**:
  - **`"env"` (the default)** → exported as `param.env` in the environment your
    `list`/`status`/`claim` commands run with (so your script reads `$LINEAR_PROJECT`, etc.).
  - **`"maxItems"`** → sets the **run's lifetime dispatch cap** for this start, overriding the
    template's `maxItems`. Enter a positive number to cap it (e.g. `1` or `2` for a careful
    run), or **`0`/`unlimited`** for no cap. Blank or non-numeric falls back to the template's
    `maxItems`. A maxItems param needs no `env` (it tunes the engine, not the provider), and a
    template may declare at most one. This is the recommended way to vary run size — leave
    `maxItems` in the template as a sane fallback and pick the real number at start. You can
    also **change this cap while the run is live** from the dashboard health bar (tap
    `dispatched/cap`) — see *Watch & control* below.
- **Live preview (success signal):** once the required fields are filled, the form runs your
  `list` command with the entered values and shows **how many items would be queued** plus a
  sample of their titles — so a typo (wrong project name → "no matching items" / a provider
  error) is caught before you start, not after.
- **Value suggestions (stop typing exact names):** a param may declare an optional
  **`valuesCommand`** — an argv that prints a JSON array of suggested values (bare strings, or
  `{ "value": …, "label": … }` objects). The form runs it and shows a small menu next to the
  field; pick one to fill it. The command runs with the OTHER fields exported as env, so a
  **dependent** suggester works: a milestones `valuesCommand` that reads `$LINEAR_PROJECT` lists
  the chosen project's milestones (and an empty list when no project is selected yet), and
  re-runs when you change the project. `valuesCommand` is GUI-only (the engine never runs it).
- `required: true` blocks the start until that field is non-empty (the Start button stays
  disabled; the engine also rejects it).
- The chosen values are remembered for the run and **re-applied across a restart** (scope AND
  the maxItems override).
- **The run is NAMED after its scope, and different scopes run in PARALLEL.** A live run's name
  (the dashboard section header, its tiles' origin, and the pause/stop target) is the template's
  `name` plus the chosen env-param **values**, e.g. **"ExampleOS · Acme · v2.0"**. Starting the
  same template again with a **different** scope (another project/milestone) does **not** dedup
  to the first run — it starts a **second run in parallel**, in its **own tab**, so you can drive
  several milestones of one generic template at once. Re-starting with the **same** scope is still
  an idempotent no-op (it won't double up). (`maxItems` is excluded from the name — it tunes the
  engine, not the scope; use the live cap editor to change a running run's cap.)
- A template with **no `params`** starts immediately, exactly as before.
- Stays generic: the *template* names the env var / opts into the maxItems prompt / points at a
  `valuesCommand` — Ghostty has no knowledge of Linear (or any tracker). Keep secrets (e.g. a
  `LINEAR_API_KEY`) in your provider's own env file; use `params` only for the per-run scope /
  size you want to be asked about.

Provider contract (the genericity boundary):
- **`list`** → stdout is a JSON array; `keyField`/`titleField`/`urlField`/`heroField` map fields
  onto each item (the optional `heroField`'s truthy value marks a [hero](#hero-agents-a-separate-attention-bounded-pool)).
  A non-zero exit or unparseable output **skips that poll** (never dispatches garbage).
- **`status {key}`** → `{"state":"…"}`; terminal iff `state` ∈ `doneStates`. A flaky probe is
  treated as "not done" — a split is **never** closed on a bad status. Completion is
  **status-only** (idleness alone never completes an item — no false positives).
- **`claim {key}`** → optional, fire-and-forget.
- Item fields reach the **provider** as argv elements (`{key}`) and the **agent** as
  `GHOSTTY_ITEM_*` env vars — they are never string-spliced into a shell line.

**`intervals` — how often the provider is actually called.** The supervisor runs a ~5s
internal sweep (reconcile / close finished splits / apply dashboard commands / refresh the
health bar all happen every sweep), but it does **not** run your `list`/`status` commands every
sweep — those are throttled to `intervals.listMs` / `intervals.statusMs`. So with the defaults
(`listMs: 60000`, `statusMs: 30000`) your tracker is queried for new work at most once a minute
and each running item's completion is checked at most every 30s. Lower them if you want the
queue to notice newly-unblocked items / completed items faster (at the cost of more API calls);
raise them to be gentler on a rate-limited provider. Two consequences worth knowing: a
**completed** item's split closes within ~`statusMs` of it actually finishing, and bumping a
running queue's **maxItems** (or resuming it) re-enables dispatch but the *new* agent spawns on
the next `list` poll (≤`listMs`) — the dashboard cap/phase updates instantly, only the spawn
waits for the poll.

There's a no-Linear demo (a fake `list`/`status` that drains as you `touch` marker files)
to try the mechanics first — see `scratchpad/queue-example/` in this checkout.

## Sharing queue templates across a repo

Templates + their sibling scripts are just files, so a team can keep them in a **shared git
repo** and everyone points Ghostty at that repo — no more hand-copying a template (and its
`list`/`status`/`valuesCommand` scripts) into each person's `~/.config`. Two mechanisms make
this work; a third note keeps the repo clean and secret-free.

### 1. A search LIST of template dirs (`agent-queue-templates-dir`)

`agent-queue-templates-dir` is a **repeatable list** (a `RepeatableString`, like
`project-directory`), not a single path. The effective **search path** is:

```
1. ~/.config/ghostty-ramon/agent-manager/queues   ← the built-in default, ALWAYS first
2. each configured agent-queue-templates-dir, in the order you wrote them
```

- **Default-first.** The default queues dir is always searched first — you never list it;
  you only ADD extra dirs. So a shared repo is *additive* to your personal templates.
- **First-in-search-order wins on a basename clash.** If both your default dir and a shared
  repo dir contain `backlog.json`, the **default (personal) copy wins** and shadows the
  repo's. The palette badges the winning source (**"· from <dir>"**) whenever a basename is
  duplicated, so a shadow is visible, never silent. To let the repo's copy win, rename your
  personal one (or remove it).
- **Deduped, order-preserving.** Equivalent paths collapse to one entry (dedup key =
  `standardizingPath`, macOS-side — it expands `~`, collapses `.`/`..`, but does **not**
  resolve symlinks, so a symlink is a legitimately distinct dir).
- Set it in `~/.config/ghostty-ramon/config` (repeat the key for more dirs):

  ```
  agent-queue-templates-dir = ~/git/your-project/ghostty-queues
  agent-queue-templates-dir = ~/git/team-shared/queues
  ```

### 2. The `{templateDir}` portability token + `GHOSTTY_QUEUE_TEMPLATE_DIR`

A shared template usually references **sibling scripts** that live next to it in the repo
(`list.py`, `list-projects.py`, …). Hard-coding an absolute path breaks the moment a
colleague clones the repo somewhere else. Two portability hooks fix that:

- **`{templateDir}` token.** The literal string `{templateDir}` inside a command is
  substituted with the template file's **own resolved directory** (no trailing slash) when
  the template loads — so a script sitting beside the template is always found:

  ```jsonc
  "provider": {
    "list":   { "command": ["python3", "{templateDir}/list.py"] },
    "status": { "command": ["python3", "{templateDir}/status.py", "{key}"] }
  },
  "agent":  { "command": "{templateDir}/run-agent.sh" },
  "params": [
    { "name": "project", "env": "PROJECT",
      "valuesCommand": ["python3", "{templateDir}/list-projects.py"] }
  ]
  ```

  It substitutes (as a **substring**, all occurrences) in exactly these sites:
  `provider.list.command`, `provider.status.command`, `provider.graph.command`,
  `agent.command`, and each param `valuesCommand`. It is **not** applied to
  `provider.claim.command` (out of scope for now — raise it if you need it). A template
  with no token is byte-identical after substitution (no-op safe). It is distinct from the
  `{key}` argv placeholder, which is untouched by this substitution.
- **`GHOSTTY_QUEUE_TEMPLATE_DIR` env.** The same directory is also exported into **both** the
  provider exec env (for `list`/`status`/`graph`/`claim`/`valuesCommand`) **and** the spawned
  agent split env, so a script can find its siblings without threading `{templateDir}`
  through every argument (e.g. `"$GHOSTTY_QUEUE_TEMPLATE_DIR/helpers/foo.sh"`).

### 3. Repo-vs-`~/.config` split, secrets, and `.gitignore`

- **What goes in the repo:** the portable template JSON + the sibling scripts it references
  via `{templateDir}`. These are safe to share.
- **What stays machine-local:** anything per-machine or secret. **Secrets (API keys,
  tokens) NEVER go in the repo** — scripts read them from `~/.config` or a git-ignored local
  `*.env`, never from a tracked file. Machine-local overrides live in your personal
  `~/.config/ghostty-ramon/agent-manager/queues` copy (which wins by first-in-order).
- **Per-run STATE never lands in the repo.** The queue's run state (`active-runs.json` and
  per-run `*.state.json`) is always written to
  `~/.config/ghostty-ramon/agent-manager/queues/.state` — hardcoded and **independent of the
  templates search path** — so pointing the queue at a shared repo dir cannot write state
  next to the shared templates.
- **Recommended repo `.gitignore`:**

  ```gitignore
  __pycache__/
  .DS_Store
  .state/
  *.env
  ```

## Starting / controlling a queue

- **Start:** the `start_agent_queue` keybind action (bind it in your fork config, e.g.
  `keybind = ctrl+a>q=start_agent_queue`) or the **"Start Agent Queue…"** command-palette
  entry — opens a fuzzy picker of your templates **shown by each template's `name`** (e.g.
  "ExampleOS", not the file's `example.json`); choose one and the sidecar starts the run on
  its next sweep. `start_agent_queue:<template-name>` (the file basename) skips the picker.
  The picker enumerates the **full search path** (the default dir plus every
  `agent-queue-templates-dir`, default-first) and merges them by basename with
  **first-in-search-order wins**; when a basename exists in more than one dir the winning
  copy's option carries a **"· from <dir>"** source badge so a shadowed template is never
  silently ambiguous. See "Sharing queue templates across a repo".
- **Watch:** the Agent Dashboard now **groups tiles by origin** — one section per running
  queue (plus `(other)` for non-queue agents) — with a per-tile origin **marker** and a
  top **filter bar** to include/exclude origins (see everything, only one queue, or mute a
  noisy one; the filter is view-only — an excluded agent still rings/pushes). Queue tiles
  show their item key + link.
- **Control:** per-queue **Pause / Resume / Stop (drain) / Abort** from the section header.
  Stop = finish in-flight, dispatch no more; Abort = close everything and clear the run.
- **Keep a split (manual work after Done):** each queue tile has a **📌 pin** toggle (next to
  the **Hide** eye-slash / the red **Close** `xmark.octagon`). Pin a split to **exempt it from the queue's auto-close** — when its
  item completes the supervisor leaves it OPEN (held in DONE_PENDING) instead of force-closing
  it, so you can keep working in that pane. Click again to un-pin (allow auto-close). The pin
  shows **persistently** when a split is kept (filled, accent) so a pinned split is obvious
  without hovering; it survives a sidecar/GUI restart. **A kept split still holds its
  concurrency slot** (exactly like `closeOnComplete:false`), so the queue won't dispatch into
  it until you close it — when you're truly done, force-close it with the red **Close** button (or it stays
  as an ordinary pane after a Stop/Abort drains the run). To keep *every* split of a queue by
  default, set `keepOnComplete: true` in the template (the per-split pin still overrides).
- **Health bar:** each running queue's section header shows a live status line — a phase chip
  (**starting → running → paused / draining / disabled**) plus **"N waiting · M running ·
  dispatched/cap"** (the cap is `∞` when unlimited, so a reached `maxItems` like `1/1` is
  obvious) and **"next: …"** the upcoming item keys. The **N waiting / M running** counts are
  clickable dropdowns listing those items with Linear links (and a "go to" jump for running
  ones). This appears the moment you start a queue — **before any split spawns** ("starting ·
  reading the queue…") — so it's never a scary blank, and the bar (with its controls) **stays
  visible even when every tile is hidden or there are no agents yet**, so you can always see the
  queue is there and what's next. The supervisor pushes this every ~5s; a finished/aborted run's
  section disappears.
- **Change the cap live:** the **`dispatched/cap`** part of the health bar is **tap-to-edit** —
  click it for a small popover (presets `1 / 2 / 5 / 10 / ∞` + a custom field) to raise or lower
  a *running* queue's `maxItems` **without restarting it** (e.g. bump `3 → 10` mid-run). Raising
  it re-enables dispatch on the next sweep; lowering it only stops *future* dispatch — agents
  already running are never killed. (A blank/garbage entry is ignored, so a fat-finger can't
  silently remove the cap.) Note a same-scope re-`start` is a no-op, so it can't change a live
  run's cap — this editor is the only in-place way; see *parallel runs* under **Start-time
  parameters** above.
- **Change the concurrency (max parallel agents) live:** next to the cap is a **`⇉ N`** chip
  showing the run's max *simultaneous* agents. Click it for a popover (presets `1 / 2 / 3 / 4 /
  6 / 9` + a custom field) to raise or lower a *running* queue's concurrency **without restarting
  it** (e.g. bump `6 → 9` mid-run). Raising it dispatches more in parallel on the next `list`
  poll; lowering it only stops *future* dispatch — running agents are never killed. There's no
  "unlimited" (concurrency is always a finite count); a blank/garbage/non-positive entry is
  ignored. Raising it past the template's `cols×rows` grid **overflows the extra agents into new
  tabs** (in the run's own window) — `cols×rows` is the per-tab layout, so e.g. bumping `6 → 9`
  with a 3×2 grid spreads 6 panes in tab 1 + 3 in tab 2. Like the cap, a same-scope re-`start`
  won't change it — this chip is the only in-place way.
- **Release HELD items (the dispatch-latch escape):** when an agent **crashed / exited**, OR was
  **killed before it claimed** its item, the item is back in the source `list` but the queue will
  **not re-dispatch it** — the §7.1 dispatch latch suppresses any key it has dispatched once until
  a successful `list` no longer reports it (normally a tracker **status round-trip**). When that
  happens, the health bar shows an orange **`N held`** chip; click it for a popover listing each
  held item (key · title · Linear link) with a **Release** button, plus a **Release all** button.
  Release clears that item's latch (and its cooldown) so the queue **re-dispatches it on the next
  `list` poll — with NO Linear/tracker status round-trip**. This is the in-place way to recover
  the "stuck in limbo, won't get rescheduled" items without editing statuses in your tracker. The
  chip appears only when there ARE held items (latched AND still in the backlog AND no longer
  active); a still-RUNNING agent is never shown as held.
- **Adopt a free split into a queue:** a CLI-agent split you started **by hand** (one the queue
  did NOT launch — `(other)` section, no origin marker) gets an **Adopt…** button (tray icon) in
  its dashboard-tile hover controls, next to **Hide**. Click it to pull that existing agent into
  a running queue so the queue **tracks it like a dispatched item** — physically **moving the
  split into the queue's grid tab** and folding it into the run. Use it when you hand-started an
  agent on a backlog item and now want the supervisor to own it (status-track it, auto-close it
  on done, count it against concurrency). The button is **disabled when no queue is running**.
  The **Adopt…** modal:
  - **Queue picker** — pick which running queue to adopt into; **hidden (auto-selected)** when
    exactly one queue is running, shown as a picker otherwise.
  - **Work-item key field** — the key the queue will track the split as. It is **prefilled by an
    on-demand Haiku read of the split's screen** (a spinner shows while it infers; best-effort —
    if it finds nothing or is unavailable you just type the key). You can always override the
    prefill. A **live title preview** below the field looks the key up in the queue's own backlog
    graph (instant, no round-trip): it shows the item's title if the key is on that queue's board,
    or a soft **"Not on this queue's board — adoptable, but no title"** note if it isn't (you can
    still adopt — you're asserting the split belongs to this key).
  - **Duplicate guard** — if that key is **already running** in the target queue, **Adopt** is
    blocked (no collision) and the modal offers **"Jump to the running one"** instead.
  - **KEEP note** — adopting **follows the template's `keepOnComplete`** (it does NOT force-keep):
    on `status=done` the adopted split **auto-closes like any tracked item unless its 📌 KEEP pin
    is set**, so pin it first (or the template defaults to keep) if you want to keep working in it.
  Adopt **always succeeds** — at capacity (the queue at concurrency / its grid full) the moved
  split **overflows into a new grid row / tab** (the same multi-tab packing the queue uses). It
  occupies a concurrency slot but is **not** counted as a freshly-launched agent (no
  `lifetimeDispatched` bump — it's an existing agent, not a new one). If the template defines a
  `claim` step, adopt fires it for the key (same as a normal dispatch).
- **Promote a running split to a HERO (and demote back):** any tracked queue split has a
  **Promote…** control on its dashboard tile that flips it into the [hero pool](#hero-agents-a-separate-attention-bounded-pool)
  — it moves out of the fungible-throughput accounting into the fleet-wide `agent-queue-hero-max`
  cap, **ejects into its own dedicated tab** (single terminal, out of the grid), becomes
  **kept-by-default** (never auto-closed), and lights up with the hero glyph across all tabs.
  **Promotion never blocks** — it may push you *over* the cap; the only consequence is that no
  *new* heroes dispatch until live heroes drain back under `agent-queue-hero-max`. A hero tile's
  **Demote** flips it back to a regular tracked item (accounting + marker) AND re-packs the split
  back into the run's BSP grid (symmetric with promote's eject), so a promote→demote round-trip
  doesn't strand a plain regular in the hero's dedicated tab. With no seated regular anchor (the
  run's only pane) there's nothing to pack into, so it stays in its own tab.

## Hero agents (a separate, attention-bounded pool)

Most queue work is **fungible throughput** — get a predefined task done, packed into a grid,
auto-closed when done. A **hero** is the opposite: something **load-bearing** that has to be
*right* (research, deep design taste, many small details). The scarce resource a hero competes
for is **your attention**, not a machine slot — you can only hold one or two in your head even
when 10 other agents are running. So a hero is a **per-item property**, not a new subsystem: it
changes four things — *slot accounting, lifecycle, layout, and notification*. (Phases like
research → design → build live in the agent definition + the issue description, exactly as for a
regular item; the engine models none of them.) Full design + wire contract: **`HERO-AGENTS.md`**.

- **Fleet-wide concurrency cap, off the grid, but inside `maxItems`.** Live heroes are bounded for
  CONCURRENCY by the fleet-wide **`agent-queue-hero-max`** (default **2**, `0` = hero concurrency
  disabled) and run OFF the grid — a hero does **not** consume a per-queue `concurrency` slot and is
  **not** counted against `agent-queue-max-total` (the "2–3 heroes **plus** 10 other agents"
  reading, for the concurrent dimension). **But `maxItems` (the queue's lifetime dispatch budget)
  DOES apply to heroes:** a single total `lifetimeDispatched` counter spends `maxItems` across both
  pools, so a hero can't be scheduled once the queue's lifetime cap is hit. The `agent-queue-hero-max`
  cap is a *discipline* limit (how many heroes you can hold in your head), not a resource limit.
- **Two entry paths.** Either the provider marks an item hero up front (the template's
  **`heroField`** — a `list`-output field whose truthy value = hero), or you **promote** a running
  regular from the dashboard (above). Promotion **never blocks** — it may exceed the cap; no *new*
  heroes dispatch until live heroes drain back under it.
- **Kept-by-default lifecycle.** A hero is **never** auto-closed — it is treated as `keep === true`
  regardless of the template `keepOnComplete` / the 📌 pin, so a completed hero holds in
  DONE_PENDING for the quick follow-up PR. The 📌 pin still works on top; demoting it restores
  normal auto-close.
- **Own dedicated tab.** A hero dispatches (or, on promotion, is ejected) into its **own new tab**
  — a single terminal, never in the BSP grid, so heroes never participate in grid packing and are
  easy to find. It carries a distinct **hero glyph** in the tab-accessory slot, visible across all
  tabs (so a hero is spottable even from another tab).
- **Heroes are marked everywhere; waiting states are explained.** In the backlog DAG canvas, **any**
  hero node gets a **purple star** (not gated on being blocked; the star is the marker — no border,
  which would fight the bell frame), and each row of the **"N waiting / M running / N held" health
  dropdowns** gets a purple star — so a hero is spottable wherever a queue item appears. A waiting item's whole-card **hover tooltip lists the exact
  gate(s)** blocking it (`hero slots`, and — for a regular item — `maxItems` / `queue concurrency` /
  `global concurrency`), so when a hero is stuck on a hero slot nobody wastes time bumping `maxItems`.
  (Dependency-blocked is NOT listed — the graph edges show it.) Tooltips use the panel-safe
  `dashboardTooltip` (native `.help()` doesn't fire in the non-key dashboard panel).
- **Louder notification.** A hero uses the **loud attention tier** by default and its phone
  web-push carries a distinct glyph (`kind:"hero"`), so it's immediately clear a *hero* is waiting,
  not routine work. Reuses the existing bell/attention + push plumbing — no new delivery mechanism.

Hero classification (the run-level `hero` set) is persisted in the per-run store and **rehydrated
across a sidecar/GUI restart**, so a promoted split comes back a hero. `maxItems` accounting rides
the single total `lifetimeDispatched` counter (regular + hero), also persisted. Cleared on abort.

## Schedules (recurring scan agents that groom the backlog)

A **schedule** is a recurring, **low-cognition** scan agent a queue runs on a cron cadence — it
periodically sweeps the queue's *project* (docs / backlog / code) and **opens or amends backlog
issues** for the drift, tech-debt, and coverage gaps it finds (e.g. "this customer-facing doc
drifted from the code — open a doc-update issue", "these two tasks are missing to fully cover
objective X", "reorganize these dependencies"). It's project/tech-debt *maintenance* you shouldn't
have to remember to trigger. Schedules run in the **same grid/tab as regular work agents**; they
are a per-queue feature, not a new subsystem.

**Autonomy is entirely the PROSE.** A schedule is just a cron cadence + a prompt (inline `prompt`
or a neighboring `promptFile`). The prompt tells the agent what it may do — open issues (with an
agreed **auto-generated label** so they're recognizable), amend an existing one, or accept it's
already in progress — and Ghostty adds **no** special issue-creation machinery. Dedup rests on the
cadence (roughly one run per cycle) plus the prose ("search existing issues before opening new
ones"). A schedule can be pointed at production tools, MCP servers, etc. — that's your prose's call.

Declare schedules in the template:

```jsonc
{
  // …the usual name/workdir/agent/provider…
  "schedules": [
    {
      "id": "doc-drift",                 // stable id: single-flight key + persistence key
      "name": "Doc drift scan",          // dashboard label (defaults to id)
      "cron": "0 9,14 * * 1-5",          // weekdays at 9am + 2pm, LOCAL time (5-field cron)
      "promptFile": "./schedules/doc-drift.md",   // prose (relative to the template dir); or "prompt": "…"
      "command": "exec ./schedules/schedule-agent.sh", // a launcher that CONSUMES $GHOSTTY_SCHEDULE_PROMPT
      "closeOnComplete": true            // default true — auto-close an exited scan
    }
  ]
}
```

**How the prose reaches the agent — by FILE PATH, not on the command line.** ⚠️ The prose is **not**
put on the launch command. `spawn_split_command` delivers a split's command by TYPING it into the
shell (interior newlines collapsed) — a large multi-line/UTF-8 prose there gets mangled (em-dashes →
control-char garbage, interleaved with the shell's login banner, never cleanly submitted). So the
runner passes a **short** env instead: `promptFile` → **`GHOSTTY_SCHEDULE_PROMPT_FILE`** = its
absolute path (the launcher `cat`s it — full newlines + UTF-8 preserved); a short inline `prompt`
(no file) → `GHOSTTY_SCHEDULE_PROMPT` on the command line. Both come with `GHOSTTY_SCHEDULE_ID`/
`_NAME` and the run's resolved param env (e.g. `LINEAR_PROJECT`/`LINEAR_MILESTONES`, so the scan is
**scoped to the same project/milestone as the run**) — the SAME "context via env" contract as a work
item's `GHOSTTY_ITEM_*`. So the schedule's **`command` must CONSUME the prompt** — a small launcher
like `claude "$(cat "$GHOSTTY_SCHEDULE_PROMPT_FILE")"`. ⚠️ It **defaults to the template
`agent.command`**, the *work-item* launcher (expects `GHOSTTY_ITEM_*`, misfires for a schedule) — so
a schedule almost always sets its own `command` pointing at a schedule launcher. **Use `promptFile`
for anything longer than a short line.**

**Cadence — completion-anchored, with a half-gap skip.** The `cron` is a standard 5-field
expression in **local wall-clock** time (minute hour day-of-month month day-of-week; lists/ranges/
steps supported; day-of-week `0`/`7` = Sunday). The next run is computed from **when the previous
run's split closed**, not a fixed grid — so a long run pushes the next one out — and the next cron
firing is **skipped if it lands within half the local cadence** of the last completion (so a scan
that overran deep into a cycle waits a full further cycle rather than firing right on its heels).
Missed firings while the sidecar/GUI was down (or the schedule was paused) are **not** replayed —
the next due run fires once, then re-anchors. **Single-flight:** a schedule never has two runs at
once (a new run is armed only after the current one closes).

**Completion = the split closing** — by any cause: the agent exits and (with `closeOnComplete`)
the split is auto-closed, *or* you close it yourself. No hook/idle dependency, so it works for
Codex too. A schedule that needs your input just **bells like any agent** and stays open until you
handle + close it; that close is its completion.

**Dashboard — a thin Schedules lane + a tile glyph.** Under each queue's health row, a compact
**Schedules** lane shows one row per schedule — *name · next-run / paused / running · last-run*,
a **Run-now** button, and a **pause/resume** toggle — plus a **pause-all** control (the vacation
switch). A running scheduled split carries a teal recurring-clock glyph on its dashboard tile
(distinct from the hero purple star). Pausing is per-schedule (or all at once); a paused schedule
never fires, but **Run-now still works** so you can kick one off ad hoc.

Schedules bypass the `concurrency` / `agent-queue-max-total` / `maxItems` caps (they're maintenance,
not throughput), but they **do occupy the grid** (overflowing to a new row/tab when full, like a
work item). Cadence + pause state persist in the per-run store and survive a sidecar/GUI restart;
a still-open scheduled split is **re-adopted after a restart with no re-dispatch**. Steady state,
the sidecar tracks a running scan by its `scheduleId` annotation (echoed back by `list_surfaces`).
But a **GUI restart wipes that in-memory annotation**, so a surviving scan comes back carrying no
`scheduleId` — which naively read as "the split closed" (false completion → re-anchor → risk of a
duplicate scan). To close that, each schedule also **persists the running scan's stable host
`sessionID`** (`ScheduleState.activeSessionID`); on restart the sidecar re-adopts the scan by
matching that sessionID against the live surfaces, marks it running again, and **re-stamps the
wiped annotation** so the dashboard re-groups + re-marks the tile. Completion fires only when the
scan is gone by **both** signals (no annotation match **and** no sessionID match); the sessionID is
cleared on completion. (This mirrors the work-item reconcile's `sessionID`-keyed re-adoption.)

> **Grid occupancy is SHARED between work items and schedules (regression fixed 2026-07-03).** A
> schedule holds a real grid slot, so **every** placement decision must count it — both a schedule
> picking its slot AND a work item picking its. The bug: `dispatchOne` (work-item placement) scanned
> only `run.active`, blind to `run.scheduleActive`, so a work item could land on a slot the schedule
> already held and *balanced-split its tab past `cols*rows`* — e.g. a **7th split in a full 3×2 tab**
> — instead of overflowing to a new tab. Two gaps, both closed: (1) a shared `gridOccupancy(run)`
> helper merges work-item + schedule slots and is now used by `dispatchOne`, `dispatchSchedule`, and
> `packRun` (they can no longer disagree on which slots are taken); `dispatchOne`'s slot search is
> widened by the live schedule count so a schedule holding a low slot pushes the work item to an
> overflow tab rather than reporting "full". (2) The restart **re-adopt** path used to assign a
> re-adopted schedule `gridSlot -1` (unknown geometry, excluded from occupancy) — while work-item
> slots ARE restored from the store — so after a restart the still-open schedule was invisible and
> its tab overfilled; re-adopt now **reserves the lowest free slot** so the schedule participates in
> occupancy (post-restart geometry is approximate but each tab stays bounded to its grid cap).

## What it guarantees

- **No duplicate agents per item key** — across the dispatch race (before an item leaves the
  filter), across overlapping polls, and across sidecar/GUI restarts. Works **without** a
  `claim` step.
- **An item dispatched once is not re-grabbed until it leaves the list and comes back.** Once
  the queue launches an agent for an item, that item's key is *latched* — the queue will not
  dispatch it again until a successful `list` stops reporting it (it left the actionable set:
  claimed, blocked, labeled, or moved off the queried state) **and then it reappears**. This is
  the important guard for the common workflow where the agent **waits for your go-ahead before
  it claims** the item: if you kill that split before it claims, the item is still in the list,
  and the latch keeps the queue from immediately re-opening it. To deliberately re-queue a
  killed item, move it out of the queried state and back (e.g. a Linear status round-trip). The
  latch is **persisted**, so a sidecar/GUI restart won't re-grab a killed-before-claim item.
  Consequence: a **crashed** agent whose item stays in the list is **not** auto-retried either —
  re-queue it with the same round-trip (the queue won't blindly re-run a crash on the same item).
  **OR release it in-place:** the dashboard's **`N held`** chip → **Release** (per item or all)
  clears the latch without a tracker round-trip, so the queue re-dispatches it on the next `list`
  poll (see *Release HELD items* above). This is the recovery path for the limbo where a killed/
  crashed item would otherwise never get rescheduled.
- **Concurrency** is never exceeded (per-queue `concurrency` — the total across all the run's
  tabs — and, *if set*, the optional global `agent-queue-max-total`, which defaults to `0` =
  unlimited; `cols×rows` is the per-tab layout, not a cap on
  the total, since panes overflow to new tabs). **Concurrency + `max-total` bound only the REGULAR
  (fungible) pool — [hero](#hero-agents-a-separate-attention-bounded-pool) agents run OFF the grid**,
  capped for concurrency by the fleet-wide `agent-queue-hero-max` (default 2): a hero neither
  consumes a regular concurrency slot nor counts against `max-total` ("2–3 heroes **plus** 10 other
  agents"). **`maxItems`, however, DOES bound heroes** — the queue's lifetime dispatch budget is a
  single total counter spent by both pools, so heroes can't push total launches past `maxItems`.
- **Tabs stay packed** — as agents finish unevenly and tabs fragment (e.g. 3 + 1 + 1 panes
  spread across three tabs), the queue **continuously consolidates**: when a whole tab's panes
  fit into an earlier tab's free space, it moves them there and closes the emptied tab (over a
  few sweeps), so you don't accumulate near-empty tabs. It does this WITHOUT reshuffling a
  balanced layout — e.g. `4 + 4` or `5 + 2` (with a 6-pane grid) are left alone because the
  bigger tab doesn't fit. The move is focus-preserving (it never yanks your focus or raises a
  window).
- **Restart-proof** — a started queue, its tiles, and its in-flight items survive a sidecar
  or GUI restart with no re-dispatch and no orphaned agents. (A *host* restart loses all
  RAM-only sessions, as always.)
- **Closes cleanly** — only when the item is provider-`done` **and** its agent has been
  quiescent (idle *or* waiting) for `closeStableSeconds`, after making the agent's child
  process exit (so no confirmation dialog stalls the teardown). (Waiting counts because a
  finished Claude Code agent reliably settles in `waiting`, not `idle` — an idle-only gate
  would leave the completed split open forever.)
- **A KEPT split is never auto-closed** — a 📌-pinned split (or any split when the template
  sets `keepOnComplete: true`) is exempt from the close gate: when its item completes it is
  held OPEN for manual work (slot kept) until you force-close it. The keep verdict is persisted
  and survives a sidecar/GUI restart.
- **A HERO split is never auto-closed either** — a hero is treated as `keep === true`
  UNCONDITIONALLY (independent of the template `keepOnComplete` / the 📌 pin), so a completed hero
  holds OPEN for the quick follow-up PR that a load-bearing item usually wants. See
  [Hero agents](#hero-agents-a-separate-attention-bounded-pool) below. So the "closes cleanly on
  done + quiescent" guarantee above applies to REGULAR splits; a hero (like a kept split) is
  exempt and stays open until you force-close it.
- **A crashed agent is never silently lost** — its split stays for you to inspect and the
  bell rings across the dashboard, web monitor, and push (`onAgentExit: leave-and-bell`).

## Cost & privacy

The queue engine itself is plain deterministic code — **no model calls**. The per-tile
summaries on queue tiles are the normal Agent Manager summarizer (Haiku via your Claude
Code auth; no API key). Your provider commands run locally with a sanitized env
(the `mcp-token` and other `GHOSTTY_*` credentials are stripped before a provider script
sees them).

## Logs / troubleshooting

The sidecar (queue engine + summarizer) tees its log to a rotating file at
**`~/Library/Logs/ghostty-ramon-agent-manager.log`** (rotates to `.1` at ~5MB). Run
removals, dispatch/prune decisions, and command applications are logged there — `tail -f`
it when a queue does something surprising.

## Status / roadmap

v1 = start / track / close (no autonomous replies). Not yet: priority/dependency ordering
beyond the source `list`, cross-machine coordination, Codex auto-close. Design notes + the
review ledger:
`scratchpad/agent-queue-design.md` (local).

## Implementation notes (for agents touching the code)

The load-bearing facts for an agent working on the Agent Queue Supervisor code. The local
design + review ledger is `scratchpad/agent-queue-design.md` (paths in the iteration worktree).

### Command latency: push-wake + parallel status probes (why adopt/promote used to feel slow)

A dashboard command (adopt / promote / demote / release / set_keep / pause / stop / …) is
DELIVERED by polling, not push: the GUI appends it to a FIFO drained by the MCP
`take_queue_commands` tool at the START of a supervisor sweep. Two things used to stack into a
30–90s felt delay before a command took effect, both fixed here:

1. **No push-wake ⇒ up to a full in-flight sweep + the 5s poll gap.** The queue loop
   (`index.ts queueTick`) is self-paced (`QUEUE_POLL_INTERVAL_MS = 5000`, armed AFTER a sweep
   settles), and a command is only drained at a sweep's start — so a command enqueued mid-sweep
   waited out the rest of that sweep, then up to another 5s, then the next sweep's drain. FIX: a
   **queue-command push-wake** mirroring the bell-reactive loop. A new surface-less
   `MCPEventBus.EventType.queueCommand` (wire value `queue_command`, sentinel id
   `queueCommandSentinelID`) is emitted by `MCPServer.enqueueQueueCommand` **after** the FIFO
   append (`bus.recordQueueCommand()`); the sidecar's new `queueReactiveLoop` long-polls
   `wait_for_event(types:["queue_command"])` and, on an event, fires a **detached, coalesced**
   sweep so a command drains in ~1 round-trip. `queueTick` and the reactive loop share ONE
   `makeCoalescedRunner(runQueueSweepSafe)` so the timer and the wake NEVER overlap (both mutate
   the run store) — a trigger arriving mid-sweep just sets the coalescer's re-run flag. The 5s
   timer stays as the BACKSTOP; the server's 0.5s event-ring coalesce catches a command enqueued
   in the sliver between the old waiter resolving and the loop re-parking, so a command is never
   lost (worst case it waits the ≤5s timer — no worse than before). Gated on a configured queue +
   `wait_for_event` capability; NEVER exits on error (fail-open, re-arms after a short backoff).
   The tool's type whitelist (`MCPTools.dispatch` `knownTypes` + the schema enum) gained
   `queue_command`.
   **⚠️ ANTI-SPIN (fixed 2026-07-03).** That same 0.5s event-ring coalesce could turn the
   reactive loop into an **event STORM**: `MCPEventBus.register` resolves a `wait_for_event`
   IMMEDIATELY if a matching event is within the 0.5s ring window, and the queue loop fires its
   sweep fire-and-forget then re-parks with **no await** — so ONE `recordQueueCommand` kept
   re-resolving the loop's re-parks hundreds of times/sec for the whole window (observed ~471
   wakes/sec), saturating the MCP serial queue until other tool calls (`set_surface_annotation`,
   `report_queue_status`, even `spawn_split_command`) timed out at 15s → the GUI BEACHBALLED.
   (The bell loop is immune: its slow Haiku classify naturally spaces re-parks past the window.)
   Surfaced when a **Schedule** run-now landed during a spin (its split-spawn sweep is heavier).
   FIX: the queue reactive loop sleeps `QUEUE_REACTIVE_MIN_INTERVAL_MS` (750ms, > the 0.5s window)
   after each wake before re-parking, so the just-consumed event ages out and the next park is a
   real park. A command landing during the sleep is still drained ≤750ms later (never lost — the
   FIFO holds it + the 5s timer backstops). Pre-existing latent bug; the schedule dispatch only
   made it visible. Wiring: `index.ts` (`QUEUE_REACTIVE_MIN_INTERVAL_MS` + the `await sleep` in
   `queueReactiveLoop`).

2. **Sequential provider `status` probes ballooned a single sweep.** `advanceStates` probed each
   active agent's provider `status` one-`await`-at-a-time; each probe is a CLI call bounded by
   `DEFAULT_PROVIDER_TIMEOUT_MS` (5s), so N agents made one sweep take ~N×5s — the dominant cost
   a queued command then had to wait out. FIX: the due probes for a run now fire CONCURRENTLY via
   `Promise.all` (collected into a `statusByKey` map), and the anchor-fold + `nextState` stamping
   stay SEQUENTIAL over the same `activeList` (they mutate `run` state) — only the I/O is
   parallelized, so ordering/determinism and the throttle/window-burn semantics (`probed` = "≥1
   probe fired", `statusDue`, no-live-agent-doesn't-burn) are unchanged. A per-probe rejection
   guard keeps one throw from failing the whole batch (`probeStatus` already swallows exec
   failures → `{terminal:false}`).

3. **Adopt fold-in is SAME-SWEEP (no extra reconcile round).** `runAdopt` runs BEFORE `list_surfaces`
   in a sweep, so in principle reconcile could fold an adopted split into `run.active` (health-bar
   count + status tracking) that same sweep — but the queueKey/queueName annotation used to reach the
   dashboard model through TWO async main-thread hops (`set_surface_annotation` posted via
   `main.async` + a Combine `receive(on: main)` sink), landing it a main-thread turn AFTER the
   same-sweep `list_surfaces` snapshot was taken → the fold-in waited for a later sweep (up to the 5s
   timer, since the reactive loop re-parks with no new event). FIX: deliver the annotation
   SYNCHRONOUSLY on main — `MCPServer.applyAnnotation` posts the notification INSIDE its `main.sync`
   block, and `subscribeAnnotation` DROPS `receive(on: main)` so the observer's `model.applyAnnotation`
   runs inline with the post. Now the `await`ed `set_surface_annotation` returns only after the model
   holds the tag, so the SAME sweep's `list_surfaces`/`hookSnapshot()` sees it and reconcile folds the
   split in that sweep — adopt is fully tracked in ~1 round-trip. INVARIANT: this notification is
   posted ONLY by `applyAnnotation` (always on main now); do NOT post it off-main or the synchronous
   sink would mutate `@Published` model state off-main. (Promote had no such round — its hero-pool
   accounting is authoritative in the sidecar's in-memory `run.hero` set, settled same-sweep.)

Wiring: `macos/Sources/Features/MCP/MCPEventBus.swift` (`queueCommand` type + `queueCommandSentinelID`
+ `recordQueueCommand`), `MCPQueueCommands.swift` (`enqueueQueueCommand` fires the wake),
`MCPTools.swift` (`queue_command` in the whitelist + schema), `macos/agent-manager/src/index.ts`
(`QUEUE_WAIT_MS`/`QUEUE_WAIT_RETRY_MS` + `runQueueSweepCoalesced` + `queueReactiveLoop` + arm),
`macos/agent-manager/src/queue/runner.ts` (`advanceStates` parallel probe batch);
`macos/Sources/Features/MCP/MCPAnnotation.swift` (`applyAnnotation` synchronous main.sync post) +
`macos/Sources/Features/AgentDashboard/AgentDashboardController.swift` (`subscribeAnnotation` drops
`receive(on:)` — the same-sweep adopt fold-in). Tests:
`runner.test.ts` (`advanceStates: due status probes … run CONCURRENTLY`), `MCPServerTests.swift`
(`dispatchWaitForEventQueueCommandType`, `dispatchWaitForEventUnknownTypeRejected`,
`queueCommandEventTypeWireValueAndSentinel`). **GUI relaunch + rebuilt sidecar `dist`; NO Zig/lib
or host change** (pure Swift + TS).

### `agent-queue-max-total` — optional fleet cap, default 0 = UNLIMITED (and the getter bug)

- **`agent-queue-max-total` defaults to `0` = UNLIMITED** (was `8`). It is an OPTIONAL
  fleet-wide ceiling across ALL runs; unset/`0` means a queue is bounded only by its own
  `concurrency`/`maxItems`/grid. A positive value opts into a global cap. Threading:
  `Config.zig` (`u32 = 0`) → `Ghostty.Config.swift agentQueueMaxTotal` getter →
  `AgentManagerController.applyAgentQueueEnv` forwards `GHOSTTY_AGENT_QUEUE_MAX_TOTAL`
  (decimal string, `"0"` when unlimited) → `index.ts` `parsePositiveInt(env, 0) || Infinity`
  → `QueueDeps.maxTotal` (`Infinity` ⇒ `globalRemaining` is `Infinity`, never binds; the
  `ConcurrencyBudget(Infinity)` always grants).
- **⚠️ GETTER BUG (fixed 2026-06-29) — the value was NEVER read.** The Swift getter declared
  `var v: UInt32?` and passed `&v` to `ghostty_config_get`. The C side writes the raw u32
  value bytes but knows nothing about Swift's Optional tag, so `v` always read back `nil` and
  the getter ALWAYS returned its hardcoded `defaultValue` (8) regardless of the config file —
  the global cap was permanently pinned at 8, ignoring any `agent-queue-max-total` value AND
  any per-queue `concurrency` above 8. Fix: a NON-optional `var v: UInt32 = defaultValue` +
  `_ = ghostty_config_get(...)` (the pattern every other numeric getter uses). Any new numeric
  config getter MUST use a non-optional var for the same reason.
- Wiring: `src/config/Config.zig` (field default + doc + `agent-queue: parse and default`
  test), `macos/Sources/Ghostty/Ghostty.Config.swift` (`agentQueueMaxTotal`),
  `macos/agent-manager/src/index.ts` (`0`/absent ⇒ `Infinity`). Tests:
  `runner.test.ts` (`maxTotal = Infinity … imposes no fleet cap`). **GUI relaunch + rebuilt
  lib/xcframework (Zig default changed) + rebuilt sidecar `dist`; no host restart** (the host
  ignores the key).

### Shared templates — search-list `agent-queue-templates-dir` + `{templateDir}` (user doc: "Sharing queue templates across a repo")

- **`agent-queue-templates-dir` became a `RepeatableString` search LIST** (was a scalar
  `?[:0]const u8`), modeled exactly on `project-directory`. No new C plumbing: it reuses the
  `ghostty_config_string_list_s` bridge (`RepeatableString.list_c`), so the macOS getter is a
  string-list read like `projectDirectories`. The scalar `ghostty_config_get` NOTE in the old
  doc is gone.
- **Search path is GUI-authoritative** (`§1` of `SHARED-QUEUES-SPEC.md`). The macOS side
  computes `[default] + configured`, `expandingTildeInPath` + `standardizingPath` each, drops
  empties, dedups by the standardized path (order-preserving), and emits the final ordered
  list. There is ONE implementation, not two "kept-in-sync" copies:
  `AgentManagerController.effectiveTemplateSearchPath(configured:defaultDir:)` (sidecar
  transport) is authoritative, and `QueuePaletteView.effectiveSearchDirs(configured:)`
  (palette discovery) DELEGATES to it with its `defaultTemplatesDir`, so the two can never
  desync (a differential test, `effectiveSearchDirsMatchesControllerTwin`, also runs both on
  the same non-trivial input as a guard). Pure (expansion/standardization only, no
  filesystem). The default dir constant is mirrored as
  `AgentManagerController.defaultTemplatesDir` / `QueuePaletteView.defaultTemplatesDir`
  (identical strings) and must match the sidecar's `defaultTemplatesDir()`.
- **GUI→sidecar env is the PLURAL `GHOSTTY_AGENT_QUEUE_TEMPLATES_DIRS`** = the full search
  path, tilde-expanded macOS-side, joined by **newlines**. The legacy singular
  `GHOSTTY_AGENT_QUEUE_TEMPLATES_DIR` is STRIPPED when enabled and both are stripped when
  disabled. The sidecar `parseTemplatesDirs(env)` splits the plural on `"\n"` (drops blanks),
  falls back to the singular as a one-element list, else `[defaultTemplatesDir()]`; it
  consumes the list VERBATIM (does NOT re-canonicalize — the GUI already deduped; a weaker
  TS-side key is fine and harmless).
- **First-wins basename resolution.** `resolveTemplatePath(searchPath, basename)` (TS) returns
  the first `join(dir, basename+".json")` that exists; the palette's `discoverTemplates(dirs:)`
  merges per-dir results by basename with first-in-order wins, tags each kept entry's winning
  `sourceDir`, and flags `hasDuplicate` when a later dir also had it (drives the "· from <dir>"
  source badge). The per-dir primitive `discoverTemplates(dir:)` is unchanged; params/probe for
  a merged entry resolve against `entry.sourceDir`.
- **`{templateDir}` substitution** is a PURE TS helper `substituteTemplateDir(t, dir)` in
  `queue/templates.ts` (`TEMPLATE_DIR_TOKEN = "{templateDir}"`), a **substring** replace (all
  occurrences) in the five contract sites (`provider.list`/`status`/`graph.command`,
  `agent.command`, param `valuesCommand`) — **NOT** `provider.claim.command` (deliberate). It
  runs in `loadTemplateAtPath(path)` AFTER load/validate + `workdir` `~`-expansion, with
  `dir = dirname(path)` (no trailing slash). `loadTemplateByName(searchPath, basename)` is a
  thin `resolveTemplatePath` → `loadTemplateAtPath` wrapper.
- **`GHOSTTY_QUEUE_TEMPLATE_DIR` env** rides `run.templateDir` (= `dirname(run.templatePath)`,
  set by `makeQueueRun`; `""` for test-constructed runs → key omitted). Provider exec: a helper
  `queueProviderEnv(run)` overlays it onto `resolveParamsEnv(...)` at ALL FIVE exec sites
  (list/status-probe-batch/graph/claim×2 — the status-probe batch is a `const env` binding, not
  an inline `env:`, so it's enumerated explicitly). Agent split: injected on BOTH delivery paths
  — the `env` field (`.exec`) AND a `GHOSTTY_QUEUE_TEMPLATE_DIR=<quoted> ` command prefix
  (`.client`, whose spawn `env` is dropped — same dual-delivery as `GHOSTTY_ITEM_*`), via
  `shellSingleQuote`.
- **Palette exec-path parity (the SECOND exec path).** The start-form's live `list` PREVIEW
  and each param's `valuesCommand` SUGGESTION probe run provider argv GUI-side
  (`QueueParamProber` → `QueueProviderProbe.run`), independent of the sidecar loader, so the
  palette substitutes `{templateDir}` and exports `GHOSTTY_QUEUE_TEMPLATE_DIR` ITSELF —
  otherwise a shared-repo template's sibling-script preview/suggestions silently break even
  though the real run works. `QueuePaletteView.substituteTemplateDir(_:dir:)` (pure, mirrors
  the TS helper's substring semantics) is applied to `templateProbe`'s `list.command` and
  `templateParams`' `valuesCommand`, using the SAME resolved dir the reader computes
  (`expandingTildeInPath` of `entry.sourceDir`); that dir rides `QueueTemplateProbe.templateDir`
  / `QueueParamPrompt.templateDir` into `QueueParamProber`, which overlays
  `GHOSTTY_QUEUE_TEMPLATE_DIR` onto the `providerEnv` for BOTH the preview and suggestion execs.
- **Rehydration determinism.** `ActiveRunRecord.templatePath?` persists the RESOLVED abs path;
  `activeRunRecords` writes it (omitted when empty), `parseActiveRuns` tolerantly carries it
  (non-empty string only), `serializeActiveRuns` round-trips it. `rehydrateActiveRuns` prefers
  `rec.templatePath` when it still exists (so a later-added dir that shadows the basename cannot
  re-point a running queue), else falls back to first-wins `resolveTemplatePath`, else drops the
  run.
- **State stays out of shared repos.** `defaultStateDir()` is hardcoded to
  `~/.config/…/queues/.state`, INDEPENDENT of the templates search path — a hygiene invariant
  (no code change), so per-run state never lands next to a shared template.
- Wiring: core — `src/config/Config.zig` (`@"agent-queue-templates-dir": RepeatableString`
  field + doc + `agent-queue-templates-dir: RepeatableString parse` test; the `agent-queue:
  parse and default` test dropped its scalar assertions). macOS —
  `Ghostty.Config.swift` (`agentQueueTemplatesDirs` list getter, replacing the scalar),
  `MCPKnowledge.swift` (reader joins the list for `get_effective_config`),
  `AgentManagerController.swift` (`agentQueueTemplatesDirs` field + `defaultTemplatesDir` +
  `effectiveTemplateSearchPath` + the plural-env emit/strip in `applyAgentQueueEnv`),
  `QueuePalette.swift` (`templatesDirs` + `effectiveSearchDirs` + multi-dir `discoverTemplates`
  + `QueueTemplateEntry.sourceDir`/`hasDuplicate` + source-badge subtitle +
  `substituteTemplateDir`/`templateDirToken` + `QueueTemplateProbe.templateDir`/
  `QueueParamPrompt.templateDir` + `QueueParamProber` `GHOSTTY_QUEUE_TEMPLATE_DIR` overlay),
  `TerminalView.swift` (passes `agentQueueTemplatesDirs`). Sidecar —
  `queue/templates.ts` (`TEMPLATE_DIR_TOKEN`/`substituteTemplateDir`), `queue/wiring.ts`
  (`parseTemplatesDirs`/`resolveTemplatePath`/`loadTemplateAtPath` + `makeFileRunFactory`/
  `rehydrateActiveRuns` take a `searchPath`), `queue/runner.ts` (`QueueRun.templatePath`/
  `templateDir` + `queueProviderEnv` + agent-split env/prefix + `activeRunRecords`),
  `queue/store.ts` (`ActiveRunRecord.templatePath` parse/serialize), `index.ts`
  (`parseTemplatesDirs(process.env)` → `searchPath` threaded to rehydrate/factory).
- Tests: Zig `agent-queue-templates-dir: RepeatableString parse` (default/single/multiple/
  reset/cval/formatEntry round-trip). Sidecar `templates.test.ts` (`substituteTemplateDir`
  sites + substring + no-op + claim-not-touched + `{key}` untouched), `wiring.test.ts`
  (`parseTemplatesDirs`/`resolveTemplatePath` first-wins/`loadTemplateAtPath`/`makeFileRunFactory`
  path threading/`rehydrateActiveRuns` determinism), `store.test.ts` (`templatePath`
  carry/round-trip), `runner.test.ts` (`GHOSTTY_QUEUE_TEMPLATE_DIR` in provider env + agent
  env + command prefix; empty-dir omits). Swift `QueuePaletteTests.swift`
  (`discoverTemplates(dirs:)` first-wins + `hasDuplicate`/`sourceDir` + `effectiveSearchDirs`
  default-first/dedup + winning-dir params + `substituteTemplateDir` +
  `templateProbe`/`templateParams` `{templateDir}` substitution), `AgentManagerControllerTests.swift`
  (`GHOSTTY_AGENT_QUEUE_TEMPLATES_DIRS` build/expand/dedup + legacy strip + disabled strip +
  pure `effectiveTemplateSearchPath`). **GUI relaunch + rebuilt lib/xcframework (Zig field
  changed) + rebuilt sidecar `dist`; NO host restart / no protocol change / no new C API.**

### `agent-queue-hero-max` + the HERO pool (concurrency cap off the grid, `maxItems` shared)

- **`agent-queue-hero-max` (`u32`, default `2`, fork-only) is the fleet-wide CONCURRENCY cap** on
  live HERO agents across ALL runs. Heroes run OFF the grid — no per-queue `concurrency` slot, not
  counted against `agent-queue-max-total`. **NOTE the inversion vs `max-total`:** `0` here means hero
  concurrency **DISABLED** (hero-marked items wait on the `heroSlots` gate), whereas
  `agent-queue-max-total = 0` means UNLIMITED. **`maxItems` is NOT bypassed — it caps heroes too**
  (see the next bullet). Threading: `Config.zig` (`u32 = 2` + doc + parse test) →
  `Ghostty.Config.swift agentQueueHeroMax` (**non-optional read**, like the `agentQueueMaxTotal`
  getter-bug fix) → `AgentManagerController.applyAgentQueueEnv` forwards `GHOSTTY_AGENT_QUEUE_HERO_MAX`
  (decimal) → `index.ts` → `QueueDeps.heroMax`.
- **Two-pool dispatch accounting, ONE shared lifetime counter (`runner.ts`/`supervisor.ts`).**
  `dispatchCandidates` → `selectCandidates` splits the actionable list by `item.hero`. The regular
  pool is gated by `remainingSlots(effConcurrency, activeRegular, globalRegularRemaining)` (counting
  **only non-hero** actives for concurrency) **plus** the `maxItems` budget. The hero pool is gated
  by `heroRemaining = heroMax − heroActiveGlobal` (`totalHeroActiveRegistry` counts heroes across ALL
  runs; fleet-wide) **plus the SAME `maxItems` budget**. **`maxItems` is spent by a SINGLE total
  `run.lifetimeDispatched` counter (regular + hero)** — every dispatch of either pool bumps it — so
  the queue's lifetime cap applies to heroes too. Within a sweep heroes are picked first, then
  regulars get the remaining budget (`maxItemsRemaining − heroCandidates.length`), so a sweep never
  dispatches more than the budget total across both pools. **A single counter makes promote/demote
  counter-NEUTRAL** (no separate hero counter to hand off, no reconcile double-count): an item counts
  once, forever, regardless of pool — so promotion can neither refund a `maxItems` slot (the shipped
  over-launch bug) nor double-count. The reconcile floor raises `lifetimeDispatched` to the WHOLE
  live fleet (`regularOccupancy + heroOccupancy`).
- **`effectiveHero(run, key) = run.hero.has(key)`** is the AUTHORITATIVE run-level classification
  (PURE; `heroRecord(run)` snapshots the set for persist). It's re-stamped onto each reconciled
  `Assignment.hero` at the top of every sweep, so the accounting + the annotation + the tab marker
  all agree. The `hero` set is persisted in the per-run store (`StoreFile.hero`) + rehydrated on the
  first reconcile (`loadHero`) + cleared on abort — mirroring the `keep`/`dispatched` latch machinery.
- **`promote`/`demote` commands (`commands.ts`, shaped like `adopt` — `{run, surfaceUUID, key?}`).**
  The reducer does the PURE, SYNCHRONOUS part only: `promote` does `run.hero.add(key)` +
  `run.keepDirty.add(key)` (reusing the per-sweep restamp signal — keep + hero ride ONE annotation);
  `demote` does `run.hero.delete(key)` + the same restamp mark. Both return a NEW `ApplyResult.kind`
  (`"promoted"`/`"demoted"`) that is NOT in `applyCommands`'s `changed` whitelist — hero membership
  lives in the PER-RUN store, not `active-runs.json`. **⭐ Both are whitelisted in `mcp.ts`
  `coerceQueueCommands` (`QUEUE_ACTIONS`) — omission SILENTLY drops the GUI emit** (the same
  chokepoint that bit `adopt` twice). They carry the existing `surfaceUUID`/`key` fields (no new
  wire field).
- **Promotion NEVER blocks (design decision #2).** `promote` mutates a RUNNING assignment rather
  than dispatching, so it can push `heroActiveGlobal` past `heroMax`; the hero gate then yields
  `heroRemaining ≤ 0` and no NEW heroes dispatch until it drains under. The reducer does not consult
  the cap at all.
- **The physical side effects run in the sweep's post-`applyCommands` loop (`runner.ts`
  `runPromote`/`runDemote`, like `runAdopt`).** `runPromote` **ejects** the split into its own new
  tab via the `move_split_to_new_tab` keybind (out of the BSP grid; the grid slot is reassigned to a
  `-1` ejected sentinel so the packer + next dispatch's occupied-set ignore it) and re-stamps the
  hero annotation; `runDemote` drops the hero annotation. Side effects are best-effort (a failed
  eject is logged; the split stays put but is still a hero — the run-level set is authoritative).
- **HERO dispatch opens its OWN tab (`dispatchOne`).** A hero-classified dispatch SKIPS `splitPlan`
  entirely (`const sp = isHero ? undefined : splitPlan(...)`) and spawns with the same `firstTab` +
  `windowAnchorUUID` shape an overflow tab uses (single terminal, anchored on a live pane so it
  shares the run's window), so a hero never lands in the grid.
- **Keep-forces-hero close gate (`runner.ts` builds `ctx.keep`; `supervisor.ts` `nextState` reuses
  its existing keep branch, no hero-specific state).** At the `runner.ts` call site the stamped
  `keep` (passed in as `ctx.keep`) is `effectiveKeep(run, a.key) || effectiveHero(run, a.key)` —
  so a hero is ALWAYS treated as `keep === true` (held in DONE_PENDING forever, never force-closed),
  INDEPENDENT of the template `keepOnComplete` / the 📌 pin (which still work on top). `nextState`
  in `supervisor.ts` contains NO hero logic — it just consumes the generic `keep` bool — so this
  reuses the existing keep close-gate with no new state.
- **Status report + backlog block-reasons (`status.ts` + `QueueBacklogCanvas.swift`).**
  `QueueStatusReport` gains fleet-wide `heroMax` + `heroActive` (echoed on EVERY run's report, from
  the `heroMax`/`heroActive` inputs), and each WAITING `next[]` `QueueItemRef` gains optional
  `blockReasons: BlockReason[]` (`"maxItems" | "queueConcurrency" | "globalConcurrency" |
  "heroSlots"`). The pure builder attributes reasons from the per-run gate ROOM inputs
  (`regularConcurrencyRemaining`/`regularGlobalRemaining`/`regularMaxItemsRemaining` for a regular,
  `heroMax − heroActive` for a hero; a gate is "blocking" when its room ≤ 0). A reason set is OMITTED
  when nothing blocks (the item WOULD dispatch). Dependency-blocked is intentionally NOT a reason.
  Swift `QueueStatus`/`QueueStatusPayload.fromArguments` parse `heroMax`/`heroActive` (default 0
  when absent) and thread them through every `withX()` optimistic-copy helper; `QueueItemRef`
  carries `blockReasons`. **Heroes are marked independent of block state:** each `QueueItemRef` also
  carries `hero?` (sidecar sets it from `heroKeys` = promoted `run.hero` ∪ active hero assignments ∪
  `list` `heroField`, plus the assignment bit for running items), and each `GraphNode` carries `hero`
  (`refreshGraph` OR's a provider graph `hero` + `heroField` + `run.hero`). `QueueBacklogCanvas`
  renders a purple `star.circle.fill` + purple border on ANY hero node, and the health dropdowns show
  a `star.fill` per hero row (`AgentDashboardView`). The whole-card tooltip
  (`QueueBacklogReasons.tooltipLines`, pure + SwiftUI-free) lists each blocking gate. (The
  `heroMax`/`heroActive` globals are wired end-to-end for a future fleet-wide `N/heroMax heroes`
  health chip.)
- **Web-push (`WebMonitorPush.swift`).** A hero surface's push uses `PushKind.hero` (payload
  `"kind":"hero"`, a distinct title glyph, built by the pure `pushTitle`/`pushPayload` seams). The
  hero verdict rides the EXISTING `.ghosttyAgentNeedsAttention` path:
  `AgentDashboardController.postNeedsAttention` reads the stored `queueHero` annotation and adds
  `AgentStateUserInfoKey.hero` to the userInfo; `WebPushManager`'s observer calls `onHero` when the
  flag is true, else `onAttention`. No new notification/delivery mechanism.
- **The surface annotation is the GUI's view of hero-ness.** `set_surface_annotation` gains a `hero`
  Bool arg (`MCPAnnotation.swift`/`MCPTools.swift`); the Swift `AgentAnnotation` gains `queueHero`
  (mirrors `queueKeep`, partial-merge). `list_surfaces` emits `hero: true` on a hero row
  (`MCPLayout.SurfaceRow.hero` + `surfacesJSONData`) — the **reconcile-visibility chokepoint** (the
  same class as the `queueKey` echo the adopt path relies on): the sidecar reads hero state back off
  the rows. The tab marker is a per-tab `surfaceIsHero: Bool` on `TerminalWindow` (parallel to
  `surfaceIsZoomed`) driving a hero-glyph accessory (parallel to `ResetZoomAccessoryView`), set by
  `TerminalController` from a `heroSurfaceIDs` set (fed by the annotation-change notification)
  intersected with the tab's current surface tree — a hero tab is
  single-terminal so it can never be zoomed, so the two accessories never collide.
- **NO new MCP tool — count stays 26** (`promote`/`demote` ride `take_queue_commands`; `hero`
  rides `set_surface_annotation`). **NO host/Zig protocol change** beyond the one additive default-on
  config key `agent-queue-hero-max` (so the fork-only agent-queue config keys are now 4:
  `agent-queue`, `agent-queue-templates-dir`, `agent-queue-max-total` (all default-off) plus the
  default-on `agent-queue-hero-max`).
- **Wiring.** Core: `src/config/Config.zig` (`agent-queue-hero-max` + doc + parse test),
  `Ghostty.Config.swift` (`agentQueueHeroMax`), `AgentManagerController.swift`
  (`GHOSTTY_AGENT_QUEUE_HERO_MAX` forward). Sidecar: `queue/types.ts` (`WorkItem.hero`,
  `Assignment.hero`, `ProviderListSpec.heroField`, `BlockReason`), `queue/provider.ts` (parse
  `heroField`), **`queue/templates.ts` (`validateProviderList` MUST carry `heroField` — the
  validator whitelists list-spec fields, so omitting it silently drops `heroField` on template
  load and the live parse never marks list heroes; the `coerceQueueCommands` chokepoint lesson,
  shipped-then-fixed 2026-07-02)**, `queue/runner.ts` (two-pool accounting sharing ONE total `lifetimeDispatched`,
  `QueueRun.hero`, `effectiveHero`/`heroRecord`, `runPromote`/`runDemote` (counter-neutral), own-tab
  dispatch, keep-forces-hero stamp, rehydrate/persist), `queue/supervisor.ts` (`selectCandidates`
  two-pool split + `nextState` keep-forces-hero), `queue/commands.ts` (`promote`/`demote` reducer +
  `ApplyResult`), `queue/status.ts` (`heroMax`/`heroActive` + per-item `blockReasons` + `hero`),
  `queue/store.ts` (`StoreFile.hero` serialize/parse/load + `persistStore` args), `mcp.ts`
  (`coerceQueueCommands` `promote`/`demote` whitelist; `Annotation.hero`/`setAnnotation`;
  `list_surfaces` hero read-back), `index.ts` (`heroMax` dep + fleet-wide hero-active bookkeeping).
  macOS: `QueueCommandBridge.swift` (`.promote`/`.demote` + `QueueStatus.heroMax`/`heroActive` +
  `QueueStatus.Item.blockReasons` + `withX` threading), `MCPAnnotation.swift`/`MCPTools.swift`
  (`hero` parse + schema), `AgentStateBridge.swift` (`AgentAnnotation.queueHero` + merge),
  `MCPLayout.swift` (`SurfaceRow.hero` + emit), `AgentDashboardController.swift`
  (`promoteToHero`/`demoteFromHero`, `HookSnapshotEntry.queueHero`, `postNeedsAttention` hero
  userInfo), `AgentPreviewTile.swift`/`AgentDashboardView.swift` (Promote/Demote buttons + hero tile
  visual), `QueueBacklogCanvas.swift` (hero-waiting icon + tooltip + `QueueBacklogReasons`),
  `TerminalWindow.swift`/`TitlebarTabsVenturaTerminalWindow.swift`/`TerminalController.swift`
  (`surfaceIsHero` + hero accessory), `WebMonitorPush.swift` (`PushKind.hero` + `onHero` +
  `pushTitle`/`pushPayload`). Tests: Zig `agent-queue-hero-max` parse/default/round-trip; sidecar
  two-pool accounting / promotion-over-cap-never-blocks + drain / demote re-enters regular pool /
  keep-forces-hero / `heroField` parse / `promote`/`demote` apply + coerce / `blockReasons`+
  `heroMax`/`heroActive` in the report / persist+rehydrate; Swift `QueueCommandBridge` promote/demote
  round-trip, `MCPAnnotation` `hero` parse + merge, `SurfaceRow`→`surfacesJSONData` hero emit, backlog
  hero-waiting icon/tooltip reason set, `surfaceIsHero`→accessory visibility. **GUI relaunch +
  rebuilt lib/xcframework (Zig default changed) + rebuilt sidecar `dist`; no host restart.** See
  **`HERO-AGENTS.md`** for the full design + the locked wire contract.

### Generic by design + the provider contract (injection seam)

- **GENERIC by design — the #1 requirement.** Ghostty/sidecar link NO tracker (Linear/
  GitHub/Jira) code. The queue source is a **command-based provider** the template
  defines: `list` (prints actionable items as JSON; expected to already exclude
  blocked/claimed/done — NO dependency graph in v1), `status {key}` (prints
  `{"state":…}`; terminal iff in `doneStates`), optional `claim`. Item fields reach the
  PROVIDER as argv elements (`{key}`) and the AGENT as **`GHOSTTY_ITEM_*` env vars** —
  NEVER string-spliced into a shell line (the one injection seam, closed). Completion is
  **status-only** (idleness alone never completes — no false positives).

### Engine architecture

- **Engine = a deterministic, independent loop in the existing TS sidecar** (`macos/agent-manager/`,
  `src/queue/{types,provider,grid,templates,store,supervisor,runner,wiring,commands}.ts`) —
  NO LLM in the control path (the summarizer pass is orthogonal, still runs on the tiles on
  its own timer). It has its OWN `ConcurrencyBudget` (the starvation lesson — a slow LLM pass
  must never deny it a slot). Pure core (selectCandidates/nextState/grid/reconcile/applyCommand)
  is `node --test`-tested.

### Hard deps + self-disable

- **HARD DEPS, self-disables silently otherwise (§2):** pty-host (detection `agentKind` +
  STABLE session ids for persistence — `sessionID==0` without it) AND the Claude
  agent-state hooks (the close-gate keys off hook-driven `agentState==idle` held
  `closeStableSeconds`; `idleSeconds` is deliberately NOT a fallback — a repainting TUI
  never idles by it). Hooks post to the INSTALLED RELEASE port, so real queues run there,
  not a dev `+1/+2` build. **Codex can dispatch/preview but CANNOT auto-close in v1** (no
  hooks) — documented limitation.

### No-duplicates guarantee

- **No-duplicates guarantee, robust WITHOUT `claim`** (§7/§9): synchronous pre-`await`
  active-set insert (within-tick), durable sidecar store keyed by `sessionID` +
  reconcile-each-sweep (cross-tick/restart), cooldown (re-dispatch of a just-finished key).
  `claim` is a latency optimization only. **Resilience is first-class:** a started queue +
  its in-flight items survive a sidecar OR GUI restart with NO re-dispatch and NO orphaning
  — the **first sweep is dispatch-suppressed until reconcile runs**, crash-safe dispatch
  ordering (pending record → spawn → annotate → finalize), orphan adoption, finalized-record
  prune is grace-gated against a one-sweep `list_surfaces` lag. (These three — the lag grace,
  orphan grid-slot reclamation, and the `sessionID:0` self-disable — were the adversarial-
  review blockers; all fixed + regression-tested.)

### DISPATCH LATCH (§7.1)

- **DISPATCH LATCH (§7.1) — block re-dispatch ENTIRELY until the item leaves the list and
  returns.** The ~2-min `cooldown` is NOT enough on its own: the dispatch→claim gap is
  HUMAN-GATED (the agent waits for the user's go-ahead before `/todo claim`, which is what
  moves the item off the queried state), so a split KILLED in that window leaves the item
  STILL in the `list` — and the cooldown would expire and re-grab it (and a restart drops the
  cooldown map → re-grab immediately). So every dispatched key joins a PERSISTED `dispatched`
  latch (`QueueRun.dispatched`, in the per-run store file); `selectCandidates` suppresses any
  latched key OUTRIGHT (not time-cooled). The latch is RE-ARMED (cleared) only when a
  SUCCESSFUL `list` no longer reports the key (it left the actionable set — claimed / blocked /
  labeled / moved off the queried state); a FAILED list never re-arms (no false re-enable on a
  transient provider error). So re-dispatch requires a real **status round-trip** (leave the
  list, return) — the user's explicit "block it off unless it literally changes status and back
  to Todo." Consequence: a crashed (EXITED) agent whose item stays listed is
  NOT auto-retried — it needs the round-trip too (a crashed agent is not
  blindly re-run on the same item). Latched at dispatch intent (rolled back only if the spawn
  itself fails), persisted on every store write, rehydrated on the first reconcile (so the
  suppression survives a sidecar/GUI restart), and cleared on `abort` (a deliberate re-start is
  fresh). Wiring: `store.ts` (`StoreFile.dispatched` + `serializeStore`/`parseDispatched`/
  `loadDispatched` + `persistStore` 4th arg), `supervisor.ts` (`selectCandidates` `dispatched`
  param), `runner.ts` (`QueueRun.dispatched` + latch add/rollback in `dispatchOne` + re-arm in
  `dispatchCandidates` + rehydrate on first reconcile). Tests: `store.test.ts`
  (serialize/parse/persist round-trips + tolerance), `supervisor.test.ts` (`selectCandidates`
  latch skip + re-arm), `runner.test.ts` (kill-before-claim NOT re-dispatched w/o a round-trip,
  crashed-EXITED cooled-then-latched, latch persists across restart).

### RELEASE held items — the in-place latch escape (§7.1)

- **RELEASE — clear the latch WITHOUT a tracker round-trip.** The §7.1 latch is deliberately
  sticky (it needs the item to leave + re-enter the `list`), which leaves a real dead-end: an
  agent that **crashed/exited** OR was **killed before claiming** leaves its item in the `list`
  forever-suppressed, "in limbo, won't get rescheduled." A new `release` command is the escape.
  - **HELD set (what's surfaced):** `status.ts queueStatusReport` now derives `held`/`heldCount`
    = `listItems ∩ latchedKeys ∩ ¬activeKeys` (runner passes `run.dispatched` as `latchedKeys`
    and `new Set(run.active.keys())` as `activeKeys`). A latched key NOT in the current list is
    omitted (the re-arm will clear it); a latched key still ACTIVE (running, or EXITED with its
    split open) is omitted (it's tracked, not stuck). So the chip shows exactly the items the
    user means by "dispatched once, agent gone, still in the backlog."
  - **`release{run, key?}` command** (`commands.ts`, whitelisted in `mcp.ts coerceQueueCommands`,
    reusing the existing optional `key` field): with a `key`, clears `run.dispatched.delete(key)`
    + `run.cooldown.delete(key)`; with NO key, clears every HELD item (latched ∩ listed ∩ ¬active,
    mirroring the surfaced set — a not-listed or still-active latched key is left alone). PURE
    (mutates only per-run state); the cleared latch is persisted by the run's next reconcile sweep
    (`persistStore` at the end of `reconcile`, every sweep — like `set_keep`, so `applyCommands`
    does NOT count `release` as an active-runs change). Once cleared, `selectCandidates` no longer
    suppresses the key, so the next `dispatchCandidates` (≤`listMs`) re-dispatches it fresh.
  - **GUI:** `QueueStatus` gains `held`/`heldCount` (parsed by `QueueStatusPayload`, forwarded by
    `mcp.ts reportQueueStatus`, declared in the `report_queue_status` schema —
    `additionalProperties:false`, so the fields MUST be declared). `QueueCommand.Action.release`
    (lowercase wire value). `AgentDashboardController.releaseQueueItem(run:key:)` posts the command
    + optimistically drops the released key(s) via `QueueStatus.withHeld`. `OriginSectionHeader`
    renders the orange **`N held`** chip → `heldPopover` (per-item **Release** + **Release all**),
    shown only when `heldCount > 0`. Wiring: sidecar `status.ts`/`runner.ts`/`commands.ts`/`mcp.ts`;
    Swift `QueueCommandBridge.swift` (action + `held`/`heldCount` + `withHeld` + parse),
    `MCPTools.swift` (schema), `AgentDashboardController.swift` (`releaseQueueItem`),
    `AgentDashboardView.swift` (`N held` chip + `heldPopover` + the two `onRelease*` closures).
    Tests: sidecar `status.test.ts` (held derivation/dedup/cap/empty), `commands.test.ts` (release
    single + bulk + tolerant + unknown-run no-op + not-counted), `mcp.test.ts` (coerce release w/
    optional key; `reportQueueStatus` forwards held); Swift `MCPServerTests`
    (`queueCommandReleaseSerializes*`, `queueStatusPayloadParsesHeld*`, `queueStatusWithHeld*`).
    **GUI relaunch + rebuilt sidecar `dist`; no host/Zig change.**

### Adopting a free split into a queue (the `adopt` + `infer_key` commands)

- **WHAT** — a dashboard tile **Adopt…** button (on a non-queue CLI-agent tile) pulls a
  human-created split into a running Agent Queue so the queue tracks it like a dispatched item:
  it MOVES the split into the run's grid tab, LATCHES the work-item key, follows the template's
  `keepOnComplete`, fires the provider `claim`, and lets reconcile's existing orphan-adoption
  fold the annotated surface in. Title preview is a LOCAL `report_queue_graph` node lookup
  (instant, no round-trip); the key field is prefilled by an on-demand Haiku call.
- **⭐ The coercer gate (the chokepoint, `mcp.ts coerceQueueCommands`, NOT index.ts).** Two new
  actions `adopt` + `infer_key` are added to the `QUEUE_ACTIONS` whitelist and the coercer body
  carries two new string fields `surfaceUUID` + `url`. WITHOUT this the GUI's emitted commands
  are SILENTLY DROPPED before the reducer and the whole feature is a no-op. (Regression-guarded
  by `mcp.test.ts coerceCarriesAdoptFields` / `coerceKeepsInferKey`.)
- **The latch-at-adoption crux (`commands.ts`).** `applyCommand`'s new `case "adopt"` does the
  PURE, SYNCHRONOUS part only — the LATCH + dedup decision (the physical move/annotate/claim are
  runner side effects, below). It validates run/key/surfaceUUID, then `adoptDecision(run, key)`
  (extracted + unit-tested): **`"reject-duplicate"`** when `run.active.has(key)` (block the
  collision — the GUI offers "jump to the running one"), else **`"latch"`** ⇒ `run.dispatched.add(key)`
  **BEFORE any `await`**, so even if the sweep is interrupted between latch and move,
  `selectCandidates` already suppresses the key — the crux that blocks a SECOND dispatch for an
  item still actionable in the provider `list`. Returns the new `ApplyResult.kind` `"adopted"`,
  which (like `keepSet`/`released`) is NOT in `applyCommands`'s `changed` whitelist — the latch
  lives in the per-run store, not `active-runs.json`.
- **`infer_key` resolved control flow (no contradiction).** It IS whitelisted (else the coercer
  drops it) and DOES flow through `applyCommand` as an EXPLICIT `case "infer_key": return {kind:"noop"}`
  (named, NOT a `default` fallthrough — mutates nothing, naturally excluded from `changed`). The
  real Haiku work runs in the sweep's post-`applyCommands` SIDE-EFFECT loop.
- **Runner side effects (`runner.ts runAdopt`).** After `applyCommands` + its persist + the snappy
  report loop, `runQueueSweep` re-iterates the drained `commands`: `adopt` → `runAdopt`, `infer_key`
  → `runInferKey`. `runAdopt`: re-checks the dedup against the LIVE `run.active`; resolves the run's
  first SEATED anchor pane (`firstSeatedUUID`) and `moveSurfaceIntoTab({sourceUUID, targetAnchorUUID,
  balanced, maxCols, maxRows})` — REUSING the existing cross-window move + grid-cap overflow (LOCKED
  #5: at capacity the split overflows to a new grid row/tab; adopt always succeeds); if the run has
  NO seated pane it does NOT move (the adopted split becomes the run's seed). **On a MOVE failure it
  ROLLS BACK the latch** (`run.dispatched.delete(key)` + persist) so the item stays dispatchable.
  Then it stamps the annotation (`queueKey`/`queueName`/`queueUrl` + `keep = effectiveKeep(run, key)`
  — FOLLOWS the template, NOT a forced true), fires the provider `claim` (consistent with
  `dispatchOne`), and persists the latch. It NEVER writes `run.active` (reconcile is its sole owner)
  and never spawns, so the adopted pane occupies a concurrency slot WITHOUT bumping
  `lifetimeDispatched`.
- **Reuse of reconcile's orphan-adoption (NOT a parallel path).** `store.ts reconcile` already
  folds a live surface carrying `queueKey`+`queueName` with no matching record into the run as a
  RUNNING assignment (fresh `sinceMs`, lowest-free grid slot). So "adopt" = stamp the annotation +
  add the latch; the NEXT reconcile sweep absorbs it. **PRECONDITION (relied upon + documented):**
  the adopted surface MUST have a NON-ZERO `sessionID` — reconcile skips `sessionID === 0`
  (store.ts: "can't be persistence-keyed → not adoptable"). A human pty-host split always has a
  real session, and the Adopt button is gated behind the same pty-host HARD DEP the dashboard/queue
  require, so a 0-session target is unreachable through the UI. We add NO 0-session fallback
  (inventing a persistence key reconcile can't match is exactly the divergence we avoid).
- **⭐ SECOND chokepoint — `list_surfaces` MUST echo the queue tags (shipped + fixed 2026-06-30).**
  reconcile reads `queueName`/`queueKey` off the `list_surfaces` ROWS (the sidecar's `listSurfaces`
  passes rows through as `Surface[]`; `store.ts` keys orphan-adoption on `r.queueName`/`r.queueKey`).
  The Swift row builder `MCPLayout.surfacesJSONData` originally emitted `notes`/`agentKind`/etc. but
  NOT the queue tags, so reconcile was BLIND to every adopted surface → it was annotated + grouped
  in the dashboard (which reads its OWN `annotations` model, independent of `list_surfaces`) but
  NEVER folded into `run.active` → the health bar's `N running` never incremented AND the supervisor
  never status-polled / auto-closed it. Fix: the tags flow `annotation` → `HookSnapshotEntry`
  (`queueKey`/`queueName`/`queueUrl`, AgentDashboardController) → `MCPLayout.SurfaceRow` →
  `surfacesJSONData` (emit when non-nil, omit otherwise). Pure-JSON, tested by
  `MCPServerTests.surfacesJSONDataEmitsQueueTagsWhenPresentOmitsWhenNil`. (Distinct from the FIRST
  chokepoint — the `coerceQueueCommands` whitelist that carries the command INTO the sidecar; this
  one carries the annotation BACK so reconcile can act on it.)
- **Haiku key inference seam (`queue/infer.ts` + index.ts).** PURE, SDK-free helpers:
  `composeInferPrompt(viewportTail, candidateKeys)` (bespoke "extract a single work-item KEY"
  prompt; hint block OMITTED when no candidates), `parseInferredKey(raw)` (trim/strip fences+quotes,
  first non-empty line, first token on interior whitespace, reject >64-char junk → key | null),
  `collectCandidateKeys(registry, runName)` (graph ∪ list keys, deduped; `[]` for empty/unknown
  run). The impure DRIVER `runInferKeyWithDeps(surfaceUUID, runName, deps)` (also in `infer.ts`,
  with the model `summarize` INJECTED — never imported, so the queue module keeps its
  no-npm-deps property): read the surface → tail → compose → `summarize` (warm-base aware,
  `isUsable = parseInferredKey !== null`) → write the inferred key (or `""`) as the
  `queueKeySuggested` annotation. **BEST-EFFORT: ANY failure writes the `""` sentinel** so the GUI
  modal drops its spinner. Wired in index.ts as `deps.queue.inferKey`, tagging usage
  `feature:"issue-key-infer"` (the third Haiku feature — see AGENT-MANAGER.md).
- **The `queueKeySuggested` annotation sentinel (`mcp.ts`).** New optional `Annotation` field
  forwarded by `setAnnotation` even when `""` (`!== undefined`, NOT truthiness): NON-EMPTY = the
  inferred key; `""` = "the sidecar tried, found nothing" (a definite negative, ALWAYS written on
  the infer path); ABSENT = "no suggestion yet". The MCP `set_surface_annotation` tool schema gains
  the field (additive — **no new tool, count stays 26**; `adopt`/`infer_key` ride the existing
  `take_queue_commands` tool). The GUI clears any stale value DIRECTLY at modal open (not via the
  never-nils `merging`) and prefills from the next sidecar write — see the Swift wiring.
- **Wiring (sidecar):** `mcp.ts` (⭐ `coerceQueueCommands` whitelist + `surfaceUUID`/`url` carry +
  `queueKeySuggested` `Annotation`/`setAnnotation`), `queue/commands.ts` (`adopt` latch/dedup +
  `adoptDecision` + `infer_key` no-op + `ApplyResult` `"adopted"`), `queue/runner.ts` (`runAdopt`
  move/annotate/claim/rollback + `runInferKey` + the `deps.inferKey` seam + the sweep side-effect
  loop), `queue/infer.ts` (NEW: prompt/parse/candidates + `runInferKeyWithDeps`), `index.ts`
  (`deps.queue.inferKey` seam + `issue-key-infer` usage tag). **Tests:** `mcp.test.ts`
  (coerce adopt/infer_key + carried fields + unknown-action-still-dropped + `queueKeySuggested`
  incl. `""`), `queue/commands.test.ts` (`adoptDecision`, latch, reject-duplicate, missing-args,
  `infer_key` no-op, not-an-active-run-change for both), `queue/runner.test.ts` (runAdopt
  moves/annotates/claims/persists, move-failure rollback, no-anchor seed, adopt+reconcile fold,
  0-session not-folded, infer_key dispatch + no-seam no-op), `queue/infer.test.ts` (parse/compose/
  candidates + `runInferKeyWithDeps` writes key / `""` / `""`-on-error). **GUI relaunch + rebuilt
  sidecar `dist`; no host/Zig change.**
- **Wiring (macOS / Swift):** `QueueCommandBridge.swift` — `QueueCommand.Action` gains `.adopt`
  (`"adopt"`) + `.inferKey` (`"infer_key"`); new `surfaceUUID: String?` + `url: String?` stored
  props (defaulted in `init`), emitted by `jsonObject` ONLY when non-nil + non-empty (the matched
  pair to the ⭐ `mcp.ts` coercer carry — BOTH must land or the commands are dropped and the
  feature is a no-op). `AgentStateBridge.swift` — `AgentAnnotation.queueKeySuggested: String?`
  (3-state sentinel: nil = no suggestion yet, `""` = inferred nothing, non-empty = the key) added
  to `init` + `merging` (`other ?? self`); plus the PURE `clearingSuggestion()` helper that nils
  ONLY `queueKeySuggested` (preserving every other field) — the deliberate bypass for `merging`'s
  never-nils asymmetry (an unrelated summarizer write would otherwise keep a stale suggestion alive
  via `?? self`). `MCPAnnotation.swift` + `MCPTools.swift` — `set_surface_annotation` parser reads
  `queueKeySuggested` **keeping `""`** (NOT trimmed-to-nil, so the negative sentinel survives) +
  adds it to the at-least-one-field guard; schema gains the `queueKeySuggested` string property
  (additive — **NO new tool, `toolsListHasAllTools` count stays 26**). `AgentDashboardController.swift`
  — `adoptSplit(id:run:key:url:)` (posts `.adopt` on the `.ghosttyQueueCommand` FIFO, NO optimistic
  flip — reconcile is the sole owner of `run.active`), `requestInferKey(id:run:)` (clears the stale
  suggestion DIRECTLY via `clearingSuggestion()` — NOT through `merging` — then posts `.inferKey`;
  early-returns on an empty run), `runNamesForAdopt()` (present runs, sorted; empty ⇒ button
  disabled, single ⇒ auto-select), `graphNodeForAdopt(run:key:)` (LOCAL `QueueGraph.nodes` lookup
  — the title-preview source, no round-trip), `activeKeysForRun(_:)` (running-key set, the GUI-side
  duplicate proxy; the sidecar's `run.active.has(key)` is the authoritative guard), `jumpToKey(run:key:)`
  (presents on the existing `ghosttyPresentTerminal` path). `AgentPreviewTile.swift` — the hover
  **Adopt…** button (gated `!isQueueOwned && entry.agent != nil`, disabled when no run) + the real
  `.sheet` modal (queue picker auto-hidden for one run + re-fires infer on a picker change for the
  multi-run case; key `TextField` with an "inferring…" spinner overlay bound to `queueKeySuggested`
  + an ~8s `.task(id:)` timeout fallback; live graph-local title preview / off-board note; duplicate
  guard + "Jump to the running one" link; the KEEP-pin footnote; Adopt disabled on empty run/key or
  duplicate). `AgentDashboardView.swift` — passes the 7 closures into the tile. **Tests (Swift):**
  `QueuePaletteTests.swift` (`adoptJSONObjectShape` / `adoptJSONObjectOmitsEmptyURL` /
  `inferKeyJSONObjectShape`), `MCPAnnotationTests.swift` (`parseQueueKeySuggestedAloneAndEmptyKept`,
  `mergingPreservesQueueKeySuggested`, `mergingOverlaysQueueKeySuggested`,
  `clearingSuggestionNilsItAndPreservesRest`), `MCPServerTests.swift` (comment at
  `toolsListHasAllTools` noting count stays 26). The single-parameter `.onChange(of:)` form is used
  throughout (the deployment target is macOS 13; the two-param old/new form needs macOS 14).

### On-demand command channel + `take_queue_commands` (§8a)

- **ON-DEMAND lifecycle via a GUI→sidecar COMMAND CHANNEL** (§8a) — the sidecar is the MCP
  CLIENT so the GUI can't push; commands are DRAINED. `MCPServer` holds a thread-safe FIFO
  (enqueued on its serial queue via a `.ghosttyQueueCommand` observer the palette/dashboard
  post to; `QueueCommandBridge.swift`/`MCPQueueCommands.swift`), drained by the new MCP tool
  **`take_queue_commands`**. The sidecar applies start/pause/stop(drain)/abort/resume
  (`commands.ts applyCommand`), persists the active-run SET (`active-runs.json`) + rehydrates
  it on restart. **A template merely on disk does NOT auto-run** (replaced Phase-1
  `loadRuns(all)`) — only a started/persisted run.

### START-TIME PARAMS + maxItems override (§8b)

- **START-TIME PARAMS (§8b) — prompt for project/milestone/maxItems/etc. at start, don't hard-code.**
  A template can declare `params: [{name, target?, env?, label?, default?, required?}]`; on start the
  QueuePalette PROMPTS for each (a form, pre-filled with `default`), and each answer is delivered
  per its `target`. **`target` (default `"env"`)** picks the delivery: an `"env"` param is
  injected into the PROVIDER command env under `param.env` (the `list`/`status`/`claim` calls
  read it) — so ONE generic template is re-pointed at a different scope per run with no file
  edits; a **`"maxItems"`** param instead sets the RUN's lifetime dispatch cap (overriding the
  template `maxItems`), so the user picks 1/2/unlimited at start (the headline ask — "run it
  careful with maxItems=1, or unlimited"). STAYS GENERIC: the TEMPLATE names the env var / opts
  into the maxItems prompt; Ghostty never hard-codes "Linear". An env param scopes "what to work
  on" and is delivered ONLY to the provider, NOT the agent (the agent gets per-item
  `GHOSTTY_ITEM_*`); a maxItems param reaches NEITHER (it tunes the engine). Env resolution is
  `answer ?? default ?? omit` (`resolveParamsEnv`, pure); a REQUIRED param with no answer+no
  default REJECTS the start (`missingRequiredParams`, enforced in the factory + the GUI Start
  button is disabled). The maxItems override (`resolveMaxItemsOverride`, pure): blank/garbage →
  `undefined` (use the template `maxItems`, a safe finite); `"0"`/`"unlimited"`/`"none"`/`"inf"`/`"∞"`
  → unlimited (no lifetime cap — `maxItemsRemaining` is Infinity in `dispatchCandidates`, the
  global `agent-queue-max-total`+grid+concurrency still bound it); a positive integer → that cap.
  Validation: `target` must be `"env"`|`"maxItems"`; an env param needs a valid `env`; AT MOST ONE
  maxItems param (a 2nd is rejected). Params persist in the active-runs record (`params` map) so a
  restart re-applies the same scope AND maxItems. A template with no params starts directly (prior
  behavior). **The Swift palette is UNCHANGED** — its `templateParams` parser reads name/label/
  default/required and is `env`/`target`-agnostic, so the maxItems param prompts like any other
  with no GUI code change. Wiring: sidecar ONLY — `types.ts` (`QueueParam.target`/`QueueParamTarget`,
  `env` now optional), `templates.ts` (`validateParams` target + `resolveParamsEnv` skips non-env +
  new `resolveMaxItemsOverride`), `runner.ts` (`dispatchCandidates` applies the override). The
  env-param plumbing (`runner.ts` `QueueRun.params`, `commands.ts`, `store.ts`, `mcp.ts`,
  `wiring.ts`, `QueueCommandBridge.swift`, `QueuePalette.swift`) is unchanged — the maxItems answer
  just rides the existing `params` map. Tests: sidecar `templates.test.ts` (target validate +
  `resolveParamsEnv` skip + `resolveMaxItemsOverride` cases), `runner.test.ts` (override CAPS a
  sweep below list size + `"0"` unlimited dispatches PAST the template cap), plus the existing
  `commands.test.ts`/`store.test.ts`/`mcp.test.ts` and Swift `QueuePaletteTests`. **A rebuilt
  sidecar `dist` is enough (the GUI respawns it); no GUI relaunch / host / Zig change.**

### Start-form live preview + value suggestions (§8b UX)

- **START-FORM LIVE PREVIEW + VALUE SUGGESTIONS (§8b UX, GUI-only, no sidecar/host/Zig change).**
  The start-form is no longer blind free-text — two GUI-SIDE probes run the template's
  provider commands directly (via `Process`, off-main, debounced ~0.35s, generation-guarded so
  stale results are discarded) as fields change:
  - **Live `list` PREVIEW** — once all REQUIRED fields are filled, the form runs
    `provider.list.command` with the CURRENT values as provider env and shows a success signal:
    "N items would be queued" + a sample of titles, or "no matching items" (amber), or the
    provider's last stderr line (red). Catches typos immediately (wrong project → empty/error).
    Gated on `canStart` so it doesn't spam "missing scope" errors while you're still typing.
  - **Per-param VALUE SUGGESTIONS** — a param may declare an OPTIONAL `valuesCommand` (argv) that
    prints a JSON array of suggested values (bare strings OR `{value,label?}`). The form runs it
    with the current values as env and shows a small menu next to the field; picking one fills it
    (no typing exact names). Because the env carries the OTHER fields, a DEPENDENT provider works:
    milestones' `valuesCommand` reads `$LINEAR_PROJECT` and re-runs when the project field changes
    (empty list when no project chosen). Every `valuesCommand` re-runs on each debounced change
    (simple + handles dependencies; a failed probe keeps the prior list rather than blanking).
  - **The probe is the GUI running the provider, NOT the sidecar** — the sidecar is the MCP client
    and can't be queried by the GUI, so the form execs the argv itself via `/usr/bin/env <argv>`
    (so a bare `python3`/`node` resolves on PATH) in the template `workdir`, inheriting the GUI env
    + the form's provider env. The env build mirrors the sidecar's `resolveParamsEnv`
    (`QueueProviderProbe.providerEnv`: env-target non-blank only; maxItems/blank skipped).
  - **Schema:** `QueueParam.valuesCommand?: string[]` (TS type + `validateParams` validates it as an
    optional argv even though only the GUI runs it; `env` stays optional). Wiring: sidecar —
    `types.ts`/`templates.ts` (`valuesCommand` field + validation); Swift — `QueuePalette.swift`
    (`QueueParamSpec` gains `env`/`isMaxItems`/`valuesCommand`; new `QueueTemplateProbe` +
    `templateProbe()`; `QueueParamProber` @MainActor debounced probe model; `QueueProviderProbe`
    pure `providerEnv`/`parseValues`/`previewState` + the blocking `run`; `QueueParamFormView` adds
    the suggestion menus + preview footer). Linear value scripts live in the untracked config
    (`example-projects.py` = all projects; `example-milestones.py` = milestones for `$LINEAR_PROJECT`,
    `[]` when none). Tests: sidecar `templates.test.ts` (valuesCommand validate); Swift
    `QueuePaletteTests` (`templateParamsParsesTargetAndValuesCommand`, `templateProbe*`,
    `providerEnv*`, `parseValues*`, `previewState*`). **GUI relaunch to pick up (Swift change); the
    `valuesCommand` field needs no sidecar restart (the running sidecar ignores unknown param fields).**

### GRID layout — balanced BSP + multi-tab overflow (§12)

- **GRID layout = BALANCED BSP, GUI-placed, with MULTI-TAB OVERFLOW (§12; reworked from the
  old slot-geometry planner — then extended from single-tab to overflow).** A run lays its
  splits out as up to `cols×rows` panes PER TAB and OVERFLOWS to additional tabs (in the run's
  own window) when `concurrency` exceeds one tab — so concurrency 9 with a 3×2 grid fills tab 1
  (6) then spills 3 into tab 2, and 18 fills three tabs. The engine no longer computes split
  geometry from an abstract grid: `grid.ts` is pure OCCUPANCY ACCOUNTING — slots are integers in
  `[0, concurrency)`, slot `i` lives in **tab `floor(i / capPerTab)`** (`tabIndexForSlot`), and
  `lowestFreeSlot` fills the lowest tab first (reusing a closed split's hole before opening a
  higher slot). `splitPlan(occupied, newSlot, capPerTab)` → `firstTab` (the run's first tab) |
  `{newTab, windowAnchorSlotIndex}` (the first pane of a fresh OVERFLOW tab — open a new tab in
  the run's window, anchored on any live pane so all the run's tabs share ONE window) |
  `{balanced, anchorSlotIndex}` (a split WITHIN the target slot's tab, anchored at the lowest
  occupied slot OF THAT TAB). The
  actual tiling is a **balanced binary-space-partition done GUI-side**: `spawn_split_command`
  with `balanced:true` splits the **LARGEST pane in the run's tab along its longer side**
  (`SplitTree.largestLeafSplit(within: realPixelBounds)` — wider/square → `.right`, taller →
  `.down`). **Why BSP, not slot-neighbor planning:** Ghostty's binary tree
  RE-FLOWS when a pane closes (the sibling absorbs the parent region), so a slot→grid-neighbor
  planner diverges from real geometry after any agent finishes and a refill splits a
  geometrically-wrong pane → **stray extra columns/rows**. The BSP places every split from
  the REAL tree, so it stays evenly tiled and self-heals across closures. **CRITICAL:**
  `largestLeafSplit` MUST use real pixel `bounds` (the window content size) — `spatial()`'s
  no-bounds fallback uses artificial 1×1 column/row units where every leaf looks square →
  always `.right` → a single row of N columns (it's scoped per-TAB — each tab is its own
  `TerminalController.surfaceTree`, so the BSP correctly tiles within one tab). `cols×rows` is
  now the PER-TAB pane cap; `concurrency` is the TOTAL across tabs and MAY exceed it (overflow),
  clamped to `cols×rows × MAX_QUEUE_TABS` (8) so a fat-finger can't open hundreds of tabs. The
  template `grid.fill` / col-vs-row split is IGNORED for placement (only `cols*rows` = the
  per-tab cap matters). `remainingSlots` bounds dispatch by `min(concurrency − active, global)` —
  the grid is NO longer a term (overflow handles >grid). Wiring: sidecar — `grid.ts`
  (`tabIndexForSlot` + tab-aware `splitPlan` + `MAX_QUEUE_TABS`), `runner.ts` (`dispatchOne` slot
  `[0,concurrency)` + 3-case spawn: firstTab / newTab+windowAnchorUUID / balanced+targetUUID;
  `effectiveConcurrency` clamps to `capPerTab*MAX_QUEUE_TABS`),
  `supervisor.ts` (`remainingSlots` drops the grid term), `templates.ts` (`clampConcurrency` →
  `[1, cap*MAX_QUEUE_TABS]`), `mcp.ts` (`spawnSplitCommand` `windowAnchorUUID` arg). Swift —
  `SplitTree.swift` (`largestLeafSplit(within:)`, pure), `MCPLayout.swift` (`newSplitCommand`
  `balanced` path → window content size → `largestLeafSplit`; `windowAnchorUUID` → open the
  overflow tab in that pane's window), `MCPTools.swift`
  (`spawn_split_command` `balanced` + `windowAnchorUUID` schema + dispatch; direction required only when NOT
  balanced). Tests: sidecar `grid.test.ts` (rewritten: cap/lowestFreeSlot + `tabIndexForSlot` +
  `splitPlan` firstTab/newTab-overflow/balanced/anchor), `runner.test.ts` (refill asserts `balanced:true` + anchor, no
  direction; **concurrency>grid OVERFLOWS to a new tab** — slot 0 firstTab, slot in-tab balanced,
  overflow slot newTab+windowAnchorUUID), `supervisor.test.ts` (`remainingSlots` concurrency-only +
  effConcurrency override), `templates.test.ts` (concurrency may exceed one grid, clamps at
  `cap*MAX_QUEUE_TABS`); Swift `SplitTreeTests` (`largestLeafSplit*`: empty/single-aspect/2-col-down/
  biggest-pane/zero-bounds). **GUI relaunch + rebuilt sidecar `dist`; no host/Zig change.**

### GRID-CONSTRAINED BSP — never exceed cols columns / rows rows (§12)

- **GRID CAP (§12) — the balanced BSP now RESPECTS the template grid SHAPE, not just
  `cols×rows` as a pane cap.** Previously `largestLeafSplit` was grid-BLIND: on an ultrawide
  (3840×1010) a 4th pane tiled as a 4th COLUMN (a single row of four) even with `grid:{cols:3,
  rows:2}`. Now the template `grid.cols`/`grid.rows` are threaded as HARD CAPS so a tab never
  exceeds `cols` columns or `rows` rows: once the layout reaches `cols` columns, further splits
  STACK into rows, and once it reaches `rows` rows, further splits ADD columns. The decision is
  purely structural/geometric and lives in the macOS Swift spatial layer — **no Zig/host/
  protocol change**.
- **The algorithm** (`SplitTree.largestLeafSplit(within:maxCols:maxRows:)`): pick the
  LARGEST-area leaf that can still split WITHIN the caps; for it, prefer the longer-side
  direction but force `.down` if `.right` would exceed `maxCols`, and force `.right` if `.down`
  would exceed `maxRows`. A leaf whose ROW BAND already has `cols` columns AND whose COLUMN BAND
  already has `rows` rows is "both-capped" and is SKIPPED (walking down by area) — this is the
  fix that keeps the canonical 3×2 ultrawide case from inserting a forbidden 4th column (the
  largest-area leaf can be both-capped). If NO leaf can split within caps (grid genuinely full)
  it falls back to largest-leaf + aspect (defensive only — the per-tab `cols*rows` cap spills to
  a new tab first). **Band counting:** columns in a leaf's row band = DISTINCT `minX` positions
  (epsilon-deduped, 0.5px) among leaf slots whose Y-range overlaps it; rows in its column band =
  distinct `minY` among leaves whose X-range overlaps it. Leading-edge (`minX`/`minY`) keying is
  the robust grid-cell identity because BSP leaves share exact leading edges within a row/column.
- **BACK-COMPAT is byte-identical:** `maxCols`/`maxRows` ≤ 0 (or absent) short-circuit BEFORE
  any grid math to today's pure-aspect rule on the single largest leaf. The no-arg
  `largestLeafSplit(within:)` is now a thin wrapper delegating with `maxCols:0,maxRows:0`, so
  every non-queue caller and old sidecar is unaffected. The MCP schema fields are OPTIONAL; the
  dispatch reads them via `(NSNumber).intValue` and keeps only positive values (a malformed cap
  falls back to no-cap, never errors). The sidecar sends them only when positive.
- **Threading path:** template `grid.cols/rows` → `runner.ts` `dispatchOne` (balanced spawnArgs)
  / `packRun` (`moveSurfaceIntoTab`) → `mcp.ts` `spawnSplitCommand`/`moveSurfaceIntoTab`
  (`maxCols?`/`maxRows?`, wired only when >0) → MCP wire (`spawn_split_command`/
  `move_surface_into_tab` OPTIONAL `maxCols`/`maxRows`) → `MCPTools.swift` dispatch (`positiveInt`
  parse) → `MCPLayout.newSplitCommand`/`moveSurfaceIntoTab` (`maxCols:Int?`/`maxRows:Int?`) →
  `BaseTerminalController.moveSurfaceIntoThisTab` (pack only) → `largestLeafSplit(within:maxCols:
  maxRows:)`. The `firstTab`/`newTab` spawn branches do NOT pass caps (a fresh tab's first leaf
  has no grid context). The PACKING path carries the grid too (for layout consistency — packing a
  fragmented run must not re-introduce a 4th column). Wiring: Swift — `SplitTree.swift`
  (no-arg wrapper + grid-aware overload), `MCPLayout.swift`, `BaseTerminalController.swift`,
  `MCPTools.swift` (schema + `positiveInt` parse + forward in both arms); sidecar — `mcp.ts`,
  `runner.ts`. Tests: Swift `SplitTreeTests` (`grid*`: back-compat == aspect, ultrawide
  3rd/4th/5th pane, both-capped-leaf-skipped, cols1/rows1 stacks + single-leaf, single-leaf
  follows aspect with caps, tall 2×3 walk, every-leaf-capped fallback, epsilon overlap); sidecar
  `runner.test.ts` (balanced spawn + pack forward grid caps; firstTab/newTab omit them),
  `mcp.test.ts` (client sends caps when positive, omits when undefined/≤0), `grid.test.ts`
  (`gridCap == cols*rows` consistency). **GUI relaunch + rebuilt sidecar `dist`; no host/Zig
  change.**

### Continuous packing — `packMove` (§12)

- **CONTINUOUS PACKING (§12) — consolidate fragmented tabs by MOVING panes.** When agents
  finish unevenly a run fragments (e.g. tabs of 3 + 1 + 1 panes that could sit in one tab).
  Each healthy sweep (after close, BEFORE dispatch) the engine computes ONE merge via pure
  `packMove(occupied, capPerTab)` — the HIGHEST non-empty tab whose panes ALL fit the free
  space of the LEFTMOST earlier tab — and physically MOVES that whole tab's panes there,
  closing the emptied source tab. Applying one merge per sweep CONVERGES to the fewest tabs
  WITHOUT reshuffling a balanced layout: `4+4` / `5+2` (cap 6) never move because the higher
  tab doesn't FIT the lower tab's free space; `3+1+1` packs to one tab over two sweeps. No
  hard-coded numbers — everything derives from `capPerTab` + occupancy. The move is a
  FOCUS-PRESERVING cross-tab relocation reusing Ghostty's proven drag-and-drop primitive
  (`surfaceTree.inserting` on the destination + `removeSurfaceNode` on the source), so it
  never steals focus or raises a window; a moved pane's `gridSlot` is reassigned to the
  target tab's range (tab membership). SAFE-DEFERS: if any source pane is not yet seated
  (host still attaching, no `surfaceUUID`) the WHOLE merge defers to a later sweep (never a
  half-move that re-fragments); a failed move stops the sweep (next retries). Runs only on
  the dispatch-eligible gate (armed, not disabled/paused/draining). Wiring: sidecar —
  `grid.ts` (`packMove` + `PackMove`), `runner.ts` (`packRun` — exported; `seatedAtSlot`;
  called in `runOne` before `dispatchCandidates`), `mcp.ts` (`moveSurfaceIntoTab` client).
  Swift — `BaseTerminalController.moveSurfaceIntoThisTab(source:balanced:)` (focus-preserving
  cross-tab move), `MCPLayout.moveSurfaceIntoTab(sourceUUID:targetAnchorUUID:balanced:)`,
  `MCPTools.swift` (`move_surface_into_tab` tool — now 20 tools). Tests: sidecar
  `grid.test.ts` (`packMove`: 3+1+1 merge / 4+4 + 5+2 no-reshuffle / full-tab-skip / hole
  reuse / multi-pane), `runner.test.ts` (`packRun` moves + reassigns slot / single+balanced
  no-op / defers-when-unseated), `mcp.test.ts` (`moveSurfaceIntoTab` forwarding); Swift
  `MCPServerTests` (`toolsListHasAllTools` now 20). **GUI relaunch + rebuilt sidecar `dist`;
  no host/Zig change.**

### Exit forms (template knob)

- **Exit forms (template knob):** `agent.exit` supports a TYPED exit
  command (`{text:"/quit"}` → send_text + Enter; `submit:false` to skip Enter) AND/OR control
  `{keys:[…]}` — DEFAULT `["ctrl-d"]`. NOTE the hyphen form: the MCP `send_key` tool only
  recognizes hyphenated names (`ctrl-d`/`ctrl-c`/`enter`/…) — a non-hyphenated `"ctrl_d"`
  silently no-ops. Claude Code swallows Ctrl-D, so use
  `{text:"/quit"}`. The close sequence is sendText/sendKey-prelude → `awaitExited`
  (bounded; force-closes anyway on timeout, so a `/quit` that leaves the launching shell alive
  still tears down) → forceClose. **There is no `quitWhenEmpty`** — a run is removed only by an
  explicit stop/abort.

### Close path — `force_close_surface` (§10)

- **Close path (§10) — the subtle one:** `close_surface`/`request_close` HONORS
  `confirm-close-surface` and would pop a modal for a live agent. So the supervisor sends the
  template `agent.exit` prelude (→ child exits) then calls **`force_close_surface`**, which
  routes a LAST/ONLY-pane (tree-root) close to the confirm-FREE
  `closeTabImmediately()`/`closeWindowImmediately()` (NOT `closeTab`/`closeWindow`, which
  re-check `needsConfirmQuit`) — `TerminalController.closeSurface` override. `onAgentExit:
  leave-and-bell` keeps a crashed split for review + rings the bell everywhere via
  **`signal_attention`** (posts `.ghosttyBellDidRing` with the SurfaceView as `object`, so
  the dashboard aggregate + web monitor + push all fire), and FREES the slot (no deadlock).

### New MCP tools (the engine's "hands")

- **New MCP tools (Swift, the engine's "hands"):** `spawn_split_command` (opens the run's
  first tab or splits a target surface running a command, returns `{id, sessionId}` —
  `MCPLayout.newSplitCommand` reads the new leaf's UUID + `ghostty_surface_session_id` back
  as VALUE types on the main hop), `force_close_surface`, `signal_attention`,
  `take_queue_commands`, plus `sessionID` added to `list_surfaces` rows and queue annotation
  fields (`queueKey`/`queueName`/`queueUrl`, partial-merge like summary/suggestion). No host/
  Zig protocol change — only 4 additive config keys (`agent-queue`, `agent-queue-templates-dir`,
  `agent-queue-max-total` — all default-off — plus the default-*on* `agent-queue-hero-max`,
  see the hero section above) + the `start_agent_queue` action.

### Dashboard — grouping / filtering / controls (§11)

- **Dashboard** (§11): tiles **grouped by origin** (queue name, or `(other)` for non-queue
  agents), per-tile origin **marker**, a top **filter bar** (include/exclude origins,
  persisted; VIEW-only — an excluded ringing/waiting agent still alerts), per-queue
  Pause/Stop/Abort header buttons (post `.ghosttyQueueCommand`). Start via the
  `start_agent_queue` action (+ `:template-name`) → `QueuePalette` (mirrors `ProjectPalette`)
  → posts a `start` command. Wiring: sidecar `src/queue/*`; Swift
  `macos/Sources/Features/MCP/{MCPLayout,MCPTools,MCPServer,MCPAnnotation,MCPQueueCommands,
  QueueCommandBridge}.swift`, `AgentDashboard/{AgentDashboardController,View,PreviewTile,
  AgentStateBridge}.swift`, `Command Palette/QueuePalette.swift`, `Terminal/
  {TerminalController,BaseTerminalController,TerminalView}.swift`, `Ghostty/{Ghostty.App,
  Ghostty.Config}.swift`; core `src/config/Config.zig` + `src/input/{Binding,command}.zig` +
  `src/apprt/action.zig` + `src/Surface.zig`. Tests: sidecar `node --test` (337+), Swift
  `MCPServerTests`/`MCPAnnotationTests`/`AgentDashboardTests`/`QueuePaletteTests`, Zig
  `agent-queue` config + `start_agent_queue` binding. **GUI relaunch + rebuilt sidecar
  `dist` to enable; no host restart.**

### Per-tile CLOSE button (wedged-slot escape hatch)

- **Per-tile CLOSE button (GUI-only, queue tiles only) — the wedged-slot escape hatch.** On
  hover each tile shows the existing **Hide** (`eye.slash`, secondary; view-only declutter — the
  split keeps running) and, ONLY on a **queue-owned** tile (one carrying a `queueName` annotation), a red
  **`xmark.octagon`** Close that **force-closes** the split: it ends the agent + frees the queue
  slot (the surface vanishing makes the next sweep reconcile + prune the record). It routes
  through the confirm-FREE `MCPLayout.forceClose` (same path the queue's own auto-close uses),
  so it works on a live agent without the `confirm-close-surface` modal — gated behind a
  confirmation dialog (no undo). It's the manual remedy when auto-close is wedged (e.g. a
  stuck-`working` hook). Queue-only by design: on a non-queue `(other)` agent a force-close is
  an unscoped "kill this terminal" next to the harmless Hide. Wiring:
  `AgentPreviewTile.swift` (`isQueueOwned` = `entry.annotation?.queueName` non-empty + the
  `onClose` button + `confirmationDialog`), `AgentDashboardController.swift`
  (`AgentDashboardModel.closeSurface(_:)` → `MCPLayout.forceClose`), `AgentDashboardView.swift`
  (`onClose:` wiring). Tests: `AgentDashboardTests` (`capDraft*` neighborhood; the button +
  gating are SwiftUI, not unit-tested). **GUI-only, GUI relaunch to pick up; no sidecar/host/Zig change.**

### QUEUE HEALTH bar (§11)

- **QUEUE HEALTH bar (§11, sidecar→GUI push).** The dashboard shows each running queue's
  health in its section header — even BEFORE any split spawns and even when every tile is
  hidden/filtered (the "scary blank at start" + "all hidden" fixes). The supervisor PUSHES
  a run-level snapshot EVERY 5s sweep (incl. the dispatch-suppressed arm sweep) via a new
  MCP tool **`report_queue_status`**: `{queueName, present, phase, queued, listOk, active,
  dispatched, maxItems|null, next:[{key,title?}]}`. The header renders a phase chip
  (starting/running/paused/draining/disabled) + `QueueHealthFormat.healthText` ("N waiting ·
  M running · dispatched/cap", ∞ = unlimited — so a reached `maxItems` like `1/1` is
  obvious) + "next: KEY,KEY,…". **`present:false`** (reported on drain/abort/quit removal)
  clears the section. The "show with no tiles" behavior: `AgentDashboardModel.groupByOrigin`
  gained a `presentQueues` param that injects an EMPTY section for any present queue with no
  (visible) entries, and `sections` passes the (filter-minus) `queueStatuses` keys; the
  `content` body now falls through to the sectioned list (not the "no agents" placeholder)
  whenever `queueStatuses` is non-empty. **The ~170s "only one item, then a delay" the user
  saw was NOT serialization** — the engine dispatches up to min(concurrency, grid, maxTotal,
  maxItemsRemaining) per 5s sweep; the gap was the 2nd item only becoming actionable in the
  `list` later. Health-bar visibility makes that observable. Sidecar wiring: `status.ts`
  (pure `queueStatusReport` + `QueueStatusReport`), `runner.ts` (`lastListItems`/`lastListOk`
  cache + `effectiveMaxItemsCap` + `reportQueueStatus`/`reportRunGone` each sweep, single
  funnel for the dispatch-decision returns so the report ALWAYS fires), `mcp.ts`
  (`reportQueueStatus`). Swift: `QueueCommandBridge.swift` (`QueueStatus` +
  `QueueStatusPayload.fromArguments` + `.ghosttyQueueStatusDidChange` +
  `MCPServer.applyQueueStatus`), `MCPTools.swift` (schema + dispatch), `MCPServer`
  (handler), `AgentDashboardController.swift` (`queueStatuses` @Published + `applyQueueStatus`
  + `subscribeQueueStatus` + `groupByOrigin(presentQueues:)` + `sections`),
  `AgentDashboardView.swift` (`OriginSectionHeader` status line + `QueueHealthFormat` +
  the `content` fall-through). Tests: sidecar `status.test.ts` + `mcp.test.ts`
  (`reportQueueStatus`) + `runner.test.ts` (a sweep reports starting→counts); Swift
  `MCPServerTests` (`queueStatusPayload*`, `toolsListHasAllTools` now 18) +
  `AgentDashboardTests` (`AgentQueueHealthTests`: apply/clear, empty-section grouping,
  `healthText`). **GUI relaunch + rebuilt sidecar `dist`; no host/Zig change.**

#### Clickable count DROPDOWNS

- **Clickable count DROPDOWNS (mirrors the hidden-agents popover).** The "N waiting" and
  "M running" counts in the header are buttons that open a popover listing those items
  with **Linear links** (key badge · title · `Link` for http(s) urls; "… and N more" when
  the waiting list is capped). This required the report to carry per-item DETAIL, not just
  counts: `QueueStatusReport.next` items gained `url`, and a new `running: QueueItemRef[]`
  (key/title/url per slot-occupying agent) was added — `runner.ts reportQueueStatus` builds
  `runningItems` from the active assignments (title/url captured at dispatch) and sends
  `nextLimit:25`; the pure builder's `active` is now `runningItems.length`. Swift mirrors it:
  `QueueStatus.Item` (was `NextItem`, +`url`, `Identifiable`) + `running: [Item]`, parsed by a
  shared `items(_:)` helper in `QueueStatusPayload`; `report_queue_status` schema gains `url`
  on next + a `running` array; `OriginSectionHeader` renders `countButton`→`itemsPopover`
  (Linear `Link` via `itemLink`, http(s)-gated like `queueURLLink`) and `QueueHealthFormat`
  swapped `healthText`→`progressText` (just the "dispatched/cap" suffix; the counts are now
  buttons). Tests: sidecar `status.test.ts` (next url + running echo) + `mcp.test.ts`
  (running forward); Swift `MCPServerTests` (parse url+running) + `AgentDashboardTests`
  (`progressText`, `applyKeepsNextAndRunningItems`). **GUI relaunch + rebuilt sidecar `dist`.**

#### BACKLOG DEPENDENCY GRAPH

- **BACKLOG DEPENDENCY GRAPH (the "N backlog" button → DAG canvas; sidecar→GUI push).**
  The header gets an "N backlog" button that opens a resizable window rendering the run's
  WHOLE board (every state — not just actionable) as a left→right layered dependency graph:
  columns by blocked-by depth, arrows for "blocked by", node cards colored by workflow-state
  category with label chips, a green ring on running items, click→jump-to-split (running) or
  open the tracker URL. **The data needs a NEW OPTIONAL `provider.graph` command** (sibling of
  `list`/`status`; absent ⇒ no button) — kept SEPARATE from `list` because `list` must stay
  "actionable-only" (it drives dispatch). It is fetched on the SAME cadence as `list`
  (`intervals.listMs`, reusing a `lastGraphAtMs` throttle), INDEPENDENT of dispatch (runs while
  paused/draining, skipped only when `disabled`), cached on `QueueRun.lastGraph`, and PUSHED via
  a new MCP tool **`report_queue_graph`** (`{queueName,present,backlog,nodes[]}`; `present:false`
  on run removal, alongside `reportRunGone`). The `backlog` count is the GROOMABLE/SCHEDULABLE
  remainder: non-terminal nodes that are NOT currently waiting/running AND NOT already
  in-progress (`backlogCount`, pure — exclude = the actionable-list keys ∪ active assignment
  keys, plus any node whose `stateType` is in `IN_PROGRESS_STATE_TYPES` = {`started`}). The
  in-progress exclusion fixes the "2 backlog but only 1 schedulable" report: an In-Progress
  issue is non-terminal and not in the actionable Todo `list`, so it WOULD have been counted as
  backlog even though the queue can never dispatch it (the `list` provider only yields Todo).
  It is still RENDERED in the DAG (blue node) — only the badge number drops it; an absent/unknown
  `stateType` still counts (safe default). STAYS GENERIC: the node's `done` (terminal,
  excluded+dimmed) and `stateType` (color category) are PROVIDER-decided — Ghostty maps no
  tracker; `QueueBacklogColors` is a cosmetic category→color map with a neutral fallback. The
  DAG layout (`QueueBacklogLayout.assignLayers`) is longest-path-from-roots, cycle-safe (a
  blocked-by cycle is broken via a `resolving` guard) and ignores edges to keys outside the
  scope. **CROSSING REDUCTION (so a busy 28-item board stays readable):** the within-column
  ORDER is no longer raw input order — `QueueBacklogLayout.orderedColumns` runs the Sugiyama
  crossing-reduction step (alternating down/up MEDIAN sweeps over the `blockedBy` edges,
  pulling each node toward the median row of its left/right neighbors) and KEEPS the ordering
  with the FEWEST crossings across sweeps, so the result is never worse than the seed; it is
  pure + deterministic (stable tie-break by current row) and the metric is
  `QueueBacklogLayout.crossingCount` (adjacent-column bipartite inversions, summed over every
  column pair so skip-layer edges count). The view also **vertically centers a short column**
  within the tallest one (`centersByKey`), so a small column's nodes sit beside their
  neighbors (less arrow slant) instead of pinned to the top; the board height is unchanged
  (still the tallest column), so the fit-to-content window sizing is unaffected. `columns`
  (raw, by-layer, input-order) is kept for the geometry sizing (ordering doesn't change a
  column's row COUNT) and remains separately tested. The canvas window is one-per-run via `QueueBacklogWindowManager` (MainActor; strong
  ref + `willClose` observer that drops both the window and itself — no leak/double-open). Its
  DEFAULT size is fit-to-content (the whole board, no scrolling) floored at a minimum and
  CLAMPED to the display: shared geometry `QueueBacklogGeometry` (the card/gap constants the
  view also uses) computes `preferredWindowSize(nodes)`, and `QueueBacklogWindowManager.defaultContentSize(nodes:screen:)`
  floors it at `minContentSize` (480×360) + clamps to `screen − screenMargin` (both pure +
  unit-tested).
  Wiring: sidecar — `types.ts` (`ProviderGraphSpec`/`GraphNode`/`QueueGraph`), `provider.ts`
  (`parseGraphOutput`/`fetchGraphResult`), `status.ts` (`QueueGraphReport`/`backlogCount`),
  `templates.ts` (`validateProviderGraph`), `runner.ts` (`QueueRun.lastGraph`/`lastGraphAtMs` +
  `refreshGraph`/`reportGraphGone`), `mcp.ts` (`reportQueueGraph`). Swift —
  `QueueCommandBridge.swift` (`QueueGraph`/`QueueGraphPayload`/`.ghosttyQueueGraphDidChange`/
  `applyQueueGraph`), `MCPTools.swift` (`report_queue_graph` tool — now 19 tools),
  `AgentDashboardController.swift` (`queueGraphs` @Published + `applyQueueGraph` +
  `subscribeQueueGraph`), `AgentDashboardView.swift` (`backlogButton` in `OriginSectionHeader`),
  `AgentDashboard/QueueBacklogCanvas.swift` (layout + canvas + window mgr; iOS-excluded in
  `project.pbxproj`). Config (untracked, Linear-specific): `example-graph.py` (mirrors
  `example-list.py` scope/auth but emits the FUTURE board — every NON-TERMINAL issue
  (completed/canceled/duplicate EXCLUDED) + labels + blockedBy + stateType, and DROPS
  "blocked by" edges to done blockers so a task gated only by finished work reads as a
  ready root) + `provider.graph` in `example.json`. Tests: sidecar `provider.test.ts` (parseGraph/fetchGraph),
  `status.test.ts` (`backlogCount`), `templates.test.ts` (graph validate), `mcp.test.ts`
  (`reportQueueGraph`), `runner.test.ts` (graph fetch throttled + push + present:false-on-abort +
  no-graph-no-fetch); Swift `MCPServerTests` (`queueGraphPayload*`, tool count 19),
  `AgentDashboardTests` (`QueueBacklogTests`: assignLayers chain/diamond/cycle/dangling +
  columns + applyQueueGraph + `crossingCount`/`orderedColumns` reduces-crossings/
  never-worse/preserves-layers/deterministic). **GUI relaunch + rebuilt sidecar `dist`; no host/Zig change.**

#### HIGH/URGENT PRIORITY MARK on backlog nodes

- **HIGH/URGENT PRIORITY MARK on backlog nodes (generic; provider-decided).** A backlog
  node can carry an OPTIONAL generic `priorityLabel` string (e.g. "Urgent"/"High"); the
  canvas renders any node that has one with a prominent filled badge in the title row + a
  louder TINTED BORDER (2pt) so high-priority items pop on the DAG (running's green border
  still wins; a `done` node keeps its dim, no loud border). STAYS GENERIC exactly like
  `done`/`stateType`: the PROVIDER SCRIPT decides which items get a mark and what it says —
  Ghostty NEVER interprets the tracker-specific numeric `priority` int (Linear's 1=urgent
  differs per tracker), it only renders whatever word lands in `priorityLabel`. The badge
  color comes from a generic English-priority vocabulary (`QueueBacklogColors.priorityColor`:
  urgent/critical→red, high→orange, medium/med/normal→yellow, low→gray) with an
  ACCENT fallback so an unknown-but-non-empty label still reads as "marked"; nil/empty ⇒ no
  mark. The Linear conversion lives in `example-graph.py` (`PRIORITY_LABELS = {1:"Urgent",
  2:"High"}`, emitted only for those — none/medium/low omit it; edit that map to mark
  more/fewer, no Ghostty change). (Do NOT use the raw tracker `priority` int — it's a
  tracker-specific footgun; `priorityLabel` is the only priority signal. If numeric ordering
  is ever wanted, add a generic provider-decided `priorityRank`, not the raw int.) Wiring:
  sidecar — `types.ts` (`GraphNode.priorityLabel`),
  `provider.ts` (`parseGraphOutput` keeps a non-empty string; `mcp.ts` forwards `nodes`
  verbatim, no change); Swift — `MCPTools.swift` (`report_queue_graph` node schema +
  `priorityLabel`), `QueueCommandBridge.swift` (`QueueGraph.Node.priorityLabel` + parse),
  `QueueBacklogCanvas.swift` (badge + tinted border + `QueueBacklogColors.priorityColor`).
  Config (untracked, Linear-specific): `example-graph.py`. Tests: sidecar
  `provider.test.ts` (priorityLabel round-trip + non-empty-string rule); Swift `MCPServerTests`
  (`queueGraphPayloadParsesFullArgs` carries it), `AgentDashboardTests`
  (`priorityColorMarksKnownAndUnknownButNotEmpty`). **GUI relaunch + rebuilt sidecar `dist`;
  no host/Zig change.**

### Close-gate fires on QUIESCENT (idle OR waiting)

- **CLOSE-GATE fires on QUIESCENT (idle OR waiting), not idle-only (sidecar-only fix).** The
  DONE_PENDING→CLOSING gate used to require `agentState==="idle"` held `closeStableSeconds`.
  But a finished Claude Code agent reliably settles in **`waiting`** — its `Stop`→idle hook is
  immediately overwritten by a `Notification` "waiting for input" nudge — so an idle-ONLY gate
  NEVER fired and the completed split was never auto-closed (real stuck case: EX-1446 sat
  DONE_PENDING with status=Done, agentState=waiting, forever). Fix: a pure `isQuiescent(agentState)`
  = `idle || waiting`; `supervisor.ts` `nextState` gates on `isQuiescent`, and `foldIdleAnchor`
  anchors the hold on EITHER state AND **keeps the anchor across an idle↔waiting transition**
  (only `working`/`undefined` resets it) — so the `Stop`→`Notification` flip keeps the close clock
  running instead of resetting it. Status-only completion is unchanged (idleness alone still never
  completes); this only governs WHEN a provider-DONE item's split tears down. Tests:
  `supervisor.test.ts` (close-on-waiting-held, foldIdleAnchor anchors-on-waiting + keeps-anchor-
  across-transition). **Sidecar-only — rebuilt `dist` + sidecar restart; no GUI/host/Zig change.**

### KEEP — exempt a split from auto-close (manual work after Done)

- **KEEP a split open for manual work** — a per-split toggle (the dashboard **📌 pin**) + a
  template default (`keepOnComplete`) that EXEMPTS a completed split from the close gate so the
  user can keep working in it. A kept split is HELD in DONE_PENDING (slot kept — same semantics
  as `closeOnComplete:false`, the user's explicit choice), never force-closed; force-close it
  with the per-tile **Close** (`xmark.octagon`) when done.
- **State model (mirrors the `dispatched` latch):** per-split keep is a RUN-LEVEL
  `QueueRun.keep: Map<key, boolean>` (NOT per-record — so reconcile, which rebuilds the active
  map from store records every sweep, never wipes it), persisted in the per-run store
  (`StoreFile.keep`) + rehydrated on the first reconcile (so a kept split survives a sidecar/GUI
  restart), cleared on abort. `effectiveKeep(run, key) = run.keep.get(key) ?? template.keepOnComplete`.
  `nextState` holds DONE_PENDING when `ctx.keep === true || ctx.closeOnComplete === false`
  (keep suppresses BOTH the idle-hold AND the exited-short-circuit close); `closeOnComplete:false`
  stays the separate HARD never-close (no per-split override), `keepOnComplete:true` is the SOFT
  default the pin overrides.
- **Toggle path:** the pin posts a `set_keep{run,key,keep}` command (the GUI→sidecar FIFO, like
  the other run controls; the GUI optimistically merges the annotation's `queueKeep` for instant
  feedback). `applyCommand` set_keep sets `run.keep` + marks `run.keepDirty` (a non-persisted
  per-sweep set); `runOne` drains `keepDirty` → restamps the annotation so the pin reflects the
  new state immediately (belt-and-suspenders over the per-sweep `restampAnnotation`, which already
  fires for every active assignment because `list_surfaces` never echoes the queueKey →
  `needsAnnotationRestamp` is always true). `set_keep` is NOT an active-runs change (keep lives in
  the per-run store, persisted by the run's own sweep).
- **GUI state via the annotation:** the supervisor stamps `keep: effectiveKeep` onto the surface
  annotation (`restampAnnotation` every sweep + `dispatchOne`); the GUI reads
  `entry.annotation?.queueKeep` to draw the pin (filled/accent when kept, shown persistently;
  outline on hover otherwise). The pin is QUEUE-tile-only (gated on `queueName`, like the `xmark.octagon` Close).
- Wiring: sidecar — `types.ts` (`QueueTemplate.keepOnComplete`), `templates.ts`
  (`TEMPLATE_DEFAULTS.keepOnComplete` + validate), `store.ts` (`StoreFile.keep` +
  serialize/`parseKeep`/`loadKeep` + `persistStore` 5th arg), `supervisor.ts`
  (`NextStateContext.keep` + the gate), `runner.ts` (`QueueRun.keep`/`keepDirty` + `effectiveKeep`
  + `keepRecord` + rehydrate + ctx pass + annotation stamps + keepDirty drain), `commands.ts`
  (`set_keep` action + `key`/`keep` + reducer + keepDirty mark), `mcp.ts` (`Annotation.keep` +
  `setAnnotation` send + `QUEUE_ACTIONS` + `coerceQueueCommands` carry key/keep). macOS —
  `QueueCommandBridge.swift` (`.setKeep` + `key`/`keep` + `jsonObject`), `AgentStateBridge.swift`
  (`AgentAnnotation.queueKeep` + merge), `MCPAnnotation.swift` (parse `keep`), `MCPTools.swift`
  (`set_surface_annotation` schema `keep` + error string), `AgentDashboardController.swift`
  (`setQueueKeep` optimistic), `AgentDashboardView.swift` (`onKeep` wiring),
  `AgentPreviewTile.swift` (`onKeep` + `isKept` + the 📌 pin). Tests: sidecar `supervisor.test.ts`
  (keep holds DONE_PENDING + suppresses exit short-circuit), `store.test.ts` (keep
  serialize/parse/persist/load), `commands.test.ts` (set_keep apply/guards + not-an-active-runs-change),
  `templates.test.ts` (keepOnComplete default/parse), `runner.test.ts` (pin holds + stamps annotation
  + persists; keepOnComplete default holds; rehydrate), `mcp.test.ts` (coerce carries key+keep;
  setAnnotation sends keep); Swift `MCPServerTests` (`queueCommandJSONObjectSetKeep*`),
  `MCPAnnotationTests` (parse/merge keep), `AgentDashboardTests` (`setQueueKeepOptimistically*`).
  **GUI relaunch + rebuilt sidecar `dist`; no host/Zig change.**

### LIVE maxItems EDIT (§8b)

- **LIVE maxItems EDIT — change a running queue's cap from the dashboard, no restart (§8b).**
  A new `set_max_items{run,maxItems}` command re-sets a LIVE run's lifetime dispatch cap WITHOUT
  restarting it (the headline ask: bump 3→10 mid-run). The dashboard header's "dispatched/cap"
  suffix is now **tap-to-edit** → a popover with preset buttons (1/2/5/10/∞) + a custom field; the
  raw string is posted (the sidecar parses it, so a fat-finger never silently removes the cap).
  Bumping the cap above `lifetimeDispatched` re-enables dispatch on the next sweep (`maxItemsRemaining`
  recomputes); LOWERING it only stops FUTURE dispatch — running agents are never killed. **NOTE the
  run-identity semantics** (UPDATED by the per-scope-identity change — see the "PER-SCOPE RUN
  IDENTITY" bullet below): after the `queue-parallel` merge a run is keyed by **template basename +
  resolved scope** (`identityScope` = the resolved provider env, e.g. project/milestone — see
  `commands.ts applyCommand`). A re-`start` with the SAME basename AND SAME scope is an idempotent
  NO-OP that ignores the second start's maxItems — so you can't rescope or re-cap a live run by
  re-starting it; `set_max_items` is the in-place cap edit. A DIFFERENT scope of the same template is
  a DISTINCT run that proceeds in PARALLEL (own tab + state file), so two milestones run at once from
  ONE template — you do NOT need two template files.
  Engine: a new
  mutable `QueueRun.maxItemsLive` (`undefined`=no edit, `null`=unlimited, N=cap) that `effectiveMaxItemsCap`
  consults FIRST (over the start-time param + template cap); persisted in the active-runs record
  (`maxItemsLive`) so a restart re-applies it. A shared pure `parseMaxItemsValue` (null=unlimited,
  N=cap, undefined=blank/garbage→ignored) backs both this and the start-time `resolveMaxItemsOverride`.
  Wiring: sidecar — `templates.ts` (`parseMaxItemsValue` + `resolveMaxItemsOverride` reuse), `runner.ts`
  (`QueueRun.maxItemsLive` + `effectiveMaxItemsCap` + `makeQueueRun` opt + `activeRunRecords`),
  `commands.ts` (`set_max_items` action + `maxItems` field + reducer case + `applyCommands` change-bit),
  `store.ts` (`ActiveRunRecord.maxItemsLive` + tolerant parse), `wiring.ts` (rehydrate), `mcp.ts`
  (`coerceQueueCommands` whitelists + carries `maxItems`). Swift — `QueueCommandBridge.swift`
  (`QueueCommand.Action.setMaxItems`="set_max_items" + `maxItems` field + `jsonObject`),
  `AgentDashboardController.swift` (`setQueueMaxItems(run:value:)`), `AgentDashboardView.swift`
  (`OriginSectionHeader` cap button + `capEditorPopover` + `QueueHealthFormat.capDraft`). Tests:
  sidecar `templates.test.ts` (`parseMaxItemsValue`), `commands.test.ts` (set_max_items apply/unlimited/
  ignore-garbage/unknown-run/change-bit), `runner.test.ts` (`effectiveMaxItemsCap` live override + bump-
  re-enables-dispatch), `store.test.ts` (round-trip + tolerant parse), `mcp.test.ts` (coerce carries it);
  Swift `MCPServerTests` (`queueCommandJSONObjectSetMaxItems*`), `AgentDashboardTests` (`capDraft*`).
  **GUI relaunch + rebuilt sidecar `dist`; no host/Zig change.**

### LIVE concurrency EDIT

- **LIVE concurrency EDIT — change a running queue's max SIMULTANEOUS agents from the dashboard,
  no restart (the headline ask: bump example 6→9 mid-run).** Mirrors the live maxItems edit. A new
  `set_concurrency{run,concurrency}` command re-sets a LIVE run's max parallel agents WITHOUT
  restarting it (a re-`start` is a same-scope no-op, so this is the only in-place path). The
  dashboard header gets a tap-to-edit **`⇉ N` parallel chip** (`rectangle.split.3x1` +
  presets 1/2/3/4/6/9 + a custom field; shown once the run reports `concurrency > 0`). Engine:
  a mutable `QueueRun.concurrencyLive?: number` (`undefined`=no edit; always a positive int — NO
  "unlimited", an unbounded fan-out would spawn a pane per item). `effectiveConcurrency(run)` =
  `concurrencyLive ?? template.concurrency`, CLAMPED to `[1, capPerTab*MAX_QUEUE_TABS]`. It is the
  run's TOTAL pane budget across ALL its tabs — concurrency above one tab's `cols×rows` OVERFLOWS
  to additional tabs (§12 multi-tab — see the GRID layout bullet), so bumping example 6→9 with a
  3×2 grid spreads 6 panes in tab 1 + 3 in tab 2 (NOT crammed into one tab). `remainingSlots`
  bounds dispatch by `min(effectiveConcurrency − active, global)` (the grid is no longer a term);
  `dispatchOne` allocates `lowestFreeSlot(occupied, effectiveConcurrency)` and `splitPlan` routes
  overflow slots to new tabs. Parsed by a pure `parseConcurrencyValue` (positive int
  only; blank/garbage/zero/negative → ignored, so a fat-finger never changes parallelism). Persisted
  in the active-runs record (`concurrencyLive`) so a restart re-applies it; surfaced in the §11
  health report (`QueueStatusReport.concurrency` = effective value) so the dashboard shows + edits it.
  The GUI optimistically updates the chip (`QueueStatus.withConcurrency` +
  `parseConcurrencyOptimistic`) before the sidecar's authoritative push. Lowering it only stops
  FUTURE dispatch (running agents are never killed); raising it re-enables dispatch on the next
  list-DUE sweep (≤`listMs`). Wiring: sidecar — `templates.ts` (`parseConcurrencyValue`),
  `supervisor.ts` (`remainingSlots` `effConcurrency` param), `runner.ts` (`QueueRun.concurrencyLive` +
  `effectiveConcurrency` clamp + `makeQueueRun` opt + `activeRunRecords` + dispatch
  gate + `reportQueueStatus`), `status.ts` (`QueueStatusReport.concurrency` + inputs + builder),
  `commands.ts` (`set_concurrency` action + `concurrency` field + reducer + `applyCommands`
  change-bit), `store.ts` (`ActiveRunRecord.concurrencyLive` + tolerant parse), `wiring.ts`
  (rehydrate), `mcp.ts` (`coerceQueueCommands` whitelist + `reportQueueStatus` forward). Swift —
  `QueueCommandBridge.swift` (`QueueCommand.Action.setConcurrency`="set_concurrency" + `concurrency`
  field + `jsonObject`; `QueueStatus.concurrency` + `withConcurrency`/`parseConcurrencyOptimistic` +
  payload parse), `MCPTools.swift` (`report_queue_status` schema `concurrency`),
  `AgentDashboardController.swift` (`setQueueConcurrency(run:value:)`), `AgentDashboardView.swift`
  (`OriginSectionHeader` `⇉ N` chip + `concurrencyEditorPopover` + `onSetConcurrency`). Tests:
  sidecar `templates.test.ts` (`parseConcurrencyValue`), `supervisor.test.ts` (`remainingSlots` eff
  override), `runner.test.ts` (`effectiveConcurrency` clamp + bump-dispatches-3rd + overflow-new-tab),
  `commands.test.ts` (set_concurrency apply/ignore-garbage/unknown-run/change-bit), `store.test.ts`
  (round-trip + tolerant parse), `mcp.test.ts` (coerce + report forward), `status.test.ts`
  (concurrency passthrough); Swift `MCPServerTests` (`queueCommandJSONObjectSetConcurrency*` +
  `queueStatusPayload` concurrency), `AgentDashboardTests` (`parseConcurrencyOptimistic*` +
  `setQueueConcurrencyOptimistically*`). **GUI relaunch + rebuilt sidecar `dist`; no host/Zig change.**

### Instant command feedback

- **INSTANT command feedback (snappiness fix for ALL queue commands).** A queue command
  (`set_max_items`/`set_concurrency`/pause/resume/stop/abort) only reflected in the dashboard on the sidecar's
  NEXT health push — i.e. after the ~5s `QUEUE_POLL_INTERVAL_MS` poll gap AND that sweep's
  provider round-trips (per-agent `status` probes + `list`), since `reportQueueStatus` is the
  LAST step of a sweep. Felt like 5–15s ("really slow"). Two-part fix: **(GUI optimistic)**
  `AgentDashboardModel.setQueueMaxItems`/`sendRunCommand` update the local `queueStatuses`
  entry IMMEDIATELY before posting — cap via `QueueStatus.parseCapOptimistic` (mirrors the
  sidecar's `parseMaxItemsValue`; `.none`=blank/garbage→leave as-is so we never fake a change
  the engine ignores) + `withMaxItems`; phase via `withPhase` (pause→paused/resume→running/
  stop→draining); abort removes the section. The sidecar's next authoritative push reconciles
  (and corrects a mis-parsed value). **(Sidecar fast confirm)** `runQueueSweep` pushes
  `reportQueueStatus` for every (non-aborting) run IMMEDIATELY after `applyCommands` changes
  the registry — BEFORE the sweep's `status`/`list` round-trips — so the authoritative number
  lands within the drain, not at sweep end. Wiring: `QueueCommandBridge.swift`
  (`QueueStatus.withMaxItems`/`withPhase`/`parseCapOptimistic`),
  `AgentDashboardController.swift` (optimistic mutation in both posters), `runner.ts`
  (post-`applyCommands` immediate report loop). Tests: `AgentDashboardTests`
  (`parseCapOptimisticMirrorsSidecar`, `setQueueMaxItemsOptimisticallyUpdatesCap`,
  `sendRunCommandOptimisticallyUpdatesPhase`); the sidecar suite still green. **GUI relaunch +
  rebuilt sidecar `dist`; no host/Zig change.**

### Provider-call throttling — honor `intervals.listMs`/`statusMs`

- **PROVIDER-CALL THROTTLING — honor `intervals.listMs`/`statusMs` (the real "5s too
  frequent" fix).** The supervisor sweep stays at the 5s `QUEUE_POLL_INTERVAL_MS` base cadence
  (reconcile / close / command-drain / §11 health report run EVERY sweep), but the PROVIDER
  calls are now throttled to the template's `intervals` instead of firing every sweep — so a
  tracker like Linear is hit at most once per `listMs` (`list`) and once per `statusMs`
  (`status`), not every 5s. Previously both knobs were DEAD (`runner.ts` called `fetchListResult`
  + `probeStatus` every sweep, ignoring `intervals`). Engine: two new non-persisted
  `QueueRun.lastListAtMs`/`lastStatusAtMs` (init `NEGATIVE_INFINITY` ⇒ the first sweep always
  fetches, and no `now===0` sentinel collision). `dispatchCandidates` skips the whole list
  fetch+dispatch and returns 0 when `nowMs - lastListAtMs < intervals.listMs` — the §11 health
  report (fired by `runOne` AFTER dispatch) reads the CACHED `lastListItems`/`lastListOk`, so the
  dashboard counts stay live between polls; the latch re-arm just waits
  for the next due fetch. The window is consumed on the ATTEMPT (set before the fetch), so even a
  FAILED list waits a full interval — a hard cap of one `list` call per `listMs` regardless of
  outcome. `advanceStates` gates the per-agent `status` probe on `statusDue =
  nowMs - lastStatusAtMs >= statusMs` (decided once for the whole batch so all agents share one
  round); when not due, `statusTerminal` stays undefined so no status-driven completion happens
  that sweep (idle-anchor fold + close-gate still run every sweep — completion is delayed at
  most `statusMs`, never lost). The status window is consumed ONLY if a probe actually fired
  (`probed` flag), so a due sweep with no live SPAWNED/RUNNING agent (host-attach lag) doesn't
  burn the interval — the next sweep with a live agent probes immediately. BEHAVIOR NOTE: a
  `set_max_items` bump / `resume` re-enables dispatch, but the NEW dispatch lands on the next
  list-DUE sweep (≤`listMs`), not the next 5s sweep — the dashboard cap/phase still updates
  INSTANTLY (the optimistic + fast-confirm path above); only the actual spawn waits for the
  poll. **Default is `{listMs:60000, statusMs:30000}`.** Wiring:
  `runner.ts` (`QueueRun.lastListAtMs`/`lastStatusAtMs` + `makeQueueRun` init + list gate in
  `dispatchCandidates` + status gate in `advanceStates`), `templates.ts`
  (`TEMPLATE_DEFAULTS.intervals` → 60000/30000). Tests: `runner.test.ts` (list throttled +
  throttled-sweep-still-reports-from-cache + status throttled + due-sweep-no-agent-doesn't-burn;
  the shared `tmpl()` fixture sets `intervals:{0,0}` = throttle-off so the existing every-sweep
  dispatch/state tests are preserved), `templates.test.ts` (default pinned to 60000/30000).
  **Sidecar-only — rebuilt `dist` + sidecar respawn (GUI relaunch); no host/Zig/GUI-Swift change.**

### PER-SCOPE RUN IDENTITY

- **PER-SCOPE RUN IDENTITY — one template, parallel runs per project/milestone (palette shows the
  template `name`).** Three coupled changes so a generic template (e.g. Example) is re-usable in
  parallel for different env-param scopes:
  - **(1) Palette shows the template `name`, not the filename.** The "Start Agent Queue…" picker lists
    each template by its JSON `name` (e.g. "ExampleOS"), not the file basename ("example"), sorted by
    display name. The START command + `templateParams`/`templateProbe` still key off the BASENAME (the
    sidecar loads templates by it). `QueuePalette.discoverTemplates` now returns `[QueueTemplateEntry]`
    (`basename` + `displayName`, read via the new `templateDisplayName`, basename fallback); the option
    title + the param-form title use `displayName`; `QueueParamPrompt` gained `displayName`.
  - **(2) A run's live IDENTITY is `runName` = `template.name` + its non-empty ENV-param VALUES,
    " · "-joined** (e.g. "ExampleOS · Acme · v2.0"; maxItems params excluded — engine tuning, not
    scope). `runName` REPLACES `template.name` everywhere the run identity flows: the annotation
    `queueName` (dispatchOne + restampAnnotation), the §11 health report, the `activeRunRecords` name,
    and the reconcile `projectLiveSurfaces` filter — so two scoped runs of one template are shown
    (separate dashboard sections) AND controlled (pause/stop/abort/set_max_items target the `runName`)
    independently. Pure helper `runDisplayName(template, values)` in `templates.ts`.
  - **(3) Dedup is now per-SCOPE, so different scopes run IN PARALLEL (separate tabs).** `applyCommand`
    builds the candidate run, then dedups on (basename + `identityScope`) where `identityScope` =
    `runIdentityScope(template, values)` = the resolved provider env (sorted `name=value`, pure). Same
    (template + scope) = idempotent no-op (unchanged); DIFFERENT scope = a second run, keyed in the
    registry by its `runName`. The per-run STATE FILE gets a scope-hash suffix (`<basename>.<slug>.state.json`
    via `scopeSlug(runIdentityScope(...))`) so parallel runs of one template don't collide on disk;
    rehydration recomputes the same path. **Separate tabs are automatic** — each run starts with an empty
    `occupied` set, so its first dispatch's `splitPlan` returns `firstTab` → a new tab per run.
  - **(3a) State-file MIGRATION across the rename (bug fix).** The scope-suffix renamed the per-run
    state file (`example.state.json` → `example.<slug>.state.json`), so a run that was IN FLIGHT across
    the upgrade rehydrated under the NEW path, found no file, and **reset `lifetimeDispatched` to 0** (it
    also lost the live maxItems edit + re-adopted its agents as orphans). Fix: `rehydrateActiveRuns`
    RENAMES a surviving bare `<basename>.state.json` to the scoped path on first rehydrate (pure decision
    `shouldMigrateLegacyState(scoped, legacy, scopedExists, legacyExists)` — migrate only when the scoped
    file is absent, the legacy exists, and the paths differ; best-effort rename). Done ONLY on the
    rehydrate path (a run that WAS active) — a FRESH `start` must NOT adopt a stale bare file. Normal
    restarts (no rename) already persisted the count via the stable scoped path; this only covers the
    one-time upgrade boundary. Wiring: `wiring.ts` (`shouldMigrateLegacyState` + the rename in
    `rehydrateActiveRuns`); test: `wiring.test.ts` (`shouldMigrateLegacyState`).
  - **(3b) REHYDRATION must key the registry by `runName`, NOT `template.name` (bug fix).** The
    `start` path (`applyCommand`) keys the registry by `run.runName`, but `index.ts` populated a
    RESTORED run (from `active-runs.json` on restart) with `registry.set(run.template.name, run)` —
    so after a restart a scoped run was keyed by the bare `"ExampleOS"` while the dashboard / health
    report target its `runName` (`"ExampleOS · Acme Foods · Visual Prototype"`). Every control
    command (`set_max_items`, pause, stop, abort) then `registry.get(cmd.run)`→undefined → silent
    "unknown run" no-op (the "changing maxItems does nothing after restart" bug), and two parallel
    scoped runs of one template would COLLIDE on the bare name. Fix: a shared
    `registerRehydratedRuns(registry, runs)` in `commands.ts` keys by `run.runName` — the SAME key
    `start` uses — and `index.ts` calls it instead of the inline loop. So a restored run behaves
    identically to a freshly started one. Wiring: `commands.ts` (`registerRehydratedRuns`),
    `index.ts` (call it). Tests: `commands.test.ts` (keyed-by-runName + `set_max_items` resolves
    after rehydrate + two parallel scoped runs coexist).
  `makeQueueRun` computes `runName`/`identityScope` from (template + params); a `runName` collision from a
  DIFFERENT identity is rejected (no clobber). Wiring: sidecar — `templates.ts` (`runDisplayName`/
  `runIdentityScope`/`scopeSlug`), `runner.ts` (`QueueRun.runName`/`.identityScope` + identity usages),
  `commands.ts` (scope-aware dedup + key-by-`runName`), `wiring.ts` (`runStatePath` scope-suffixed state
  file, factory + rehydrate). macOS — `QueuePalette.swift` (`QueueTemplateEntry` + `templateDisplayName` +
  `discoverTemplates` return type + `QueueParamPrompt.displayName` + option/form titles). Tests: sidecar
  `templates.test.ts` (`runDisplayName`/`runIdentityScope`/`scopeSlug`), `commands.test.ts` (parallel
  different-scope start + same-scope no-op + factory-consulted-on-restart); Swift `QueuePaletteTests`
  (`discoverUsesJSONNameForDisplayAndSort`, `templateDisplayNameFallsBackToBasename`, updated discovery
  assertions to `[QueueTemplateEntry]`). **GUI relaunch + rebuilt sidecar `dist`; no host/Zig change.**

### Restart-survival hardening

- **RESTART-SURVIVAL HARDENING.** A started run + its in-flight items survive a sidecar/GUI restart
  without the queue vanishing or its splits detaching. (Removing `quitWhenEmpty` — above — is part of
  this: a transient SUCCESSFUL-but-INCOMPLETE post-restart `list_surfaces` must not self-remove a live
  run.) Two further sidecar-only safeguards:
  - **(A) PREMATURE-PRUNE FIX — reconcile-start grace.** `reconcile` takes an optional
    `reconcileStartedMs` (default `-Infinity` = no grace); a finalized record's session-gone prune
    is shielded for `pendingGraceMs` (30s) after the LATER of its `sinceMs` AND the run's first
    reconcile in the current process (`run.reconcileStartedMs`, stamped once per process; a restart
    re-stamps). So a long-lived RUNNING record survives a transient/incomplete post-restart list for a
    full grace window. Conservative — can only DELAY a prune (hold a slot longer), never cause a
    duplicate. Wiring: `store.ts reconcile` (param + `Math.max(sinceMs, reconcileStartedMs)` gate),
    `runner.ts` (`QueueRun.reconcileStartedMs` stamp + pass-through). Tests: `store.test.ts`
    (shield within grace / prune past grace / default-arg = no-grace behavior); the latch-persists
    restart test expects the held-then-pruned sequence.
  - **(B) PERSISTENT SIDECAR LOG.** The Swift controller pipes the sidecar's stdout to an UNREAD pipe
    and sends stderr to `nullDevice`, so the engine's run/prune/command logs have no other durable
    trail. `src/logfile.ts` tees `console.{log,info,warn,error}` to a ROTATING file
    `~/Library/Logs/ghostty-ramon-agent-manager.log` (append, rotate at ~5MB → `.1`); best-effort
    (any fs error falls back to console only, never throws); installed first thing in `index.ts main()`.
    Pure `formatLogLine`/`defaultLogPath` unit-tested (`logfile.test.ts`). **Sidecar-only — rebuilt
    `dist` + sidecar restart; no host/Zig/GUI-Swift change.**

- **Schedules (recurring scan agents).** A per-queue array of cron-scheduled scan agents (see
  "Schedules" above). NO config key + NO new MCP tool + NO Zig/host change — GUI relaunch +
  rebuilt sidecar `dist`. Cadence is PURE (`queue/schedule.ts`): a vendored 5-field cron parser
  (`parseCron`/`nextAfter`/`prevBefore`, LOCAL time) + `computeNextStart(cron, state)` implementing
  the completion-anchored **half-of-local-gap skip** (`A > C + (A − prevFiring)/2`, strictly
  greater; never-ran uses the arm anchor with NO skip). The runner's `scheduleSweep` (runner.ts,
  called every sweep from `runOne`) arms/prunes cadence state, tracks liveness via **two signals**
  (the `scheduleId` annotation echoed by `list_surfaces` OR the persisted `activeSessionID` matched
  against the live surfaces — `liveSurfaceFor(id)`), detects completion only when a tracked schedule
  is gone by BOTH (→ `lastCompletionAt = now`, `activeSessionID = undefined`), re-adopts a live
  scheduled surface after a restart, auto-closes an EXITED split (when `closeOnComplete`), and
  dispatches a due/run-now schedule via a grid-packed split (`dispatchSchedule`). The prose reaches
  the agent as the `GHOSTTY_SCHEDULE_PROMPT` env (+ a single-quoted command PREFIX for the pty-host
  backend, like GHOSTTY_ITEM_*), ALONGSIDE `GHOSTTY_SCHEDULE_ID`/`_NAME` and the run's resolved
  param env (`resolveParamsEnv` — so a scan is scoped to the same project/milestone as the run);
  the agent's `command`/launcher CONSUMES it (`claude "$GHOSTTY_SCHEDULE_PROMPT"`) rather than us
  typing it (a fresh raw-mode TUI drops pre-first-input typing). The dispatch BYPASSES the
  concurrency/maxItems/max-total caps (it
  is NOT in `run.active`) but still packs into the grid. **Grid-slot placement is shared:**
  `gridOccupancy(run)` (a pure helper) merges `run.active` (work items) + `run.scheduleActive`
  (schedules) into one `{occupied, slotUUID}` view, used by `dispatchOne`, `dispatchSchedule`, AND
  `packRun` — so a work item can never land on a schedule's slot and over-crowd its tab past
  `cols*rows` (the 2026-07-03 "7th split in a full 3×2 tab" regression; `dispatchOne` used to scan
  only `run.active`). `dispatchOne`'s slot search is widened by `run.scheduleActive.size` so a
  schedule holding a low slot pushes the work item to an overflow tab. The restart **re-adopt**
  branch of `scheduleSweep` now RESERVES the lowest free slot for a surviving scheduled surface
  (was `gridSlot -1` = invisible to occupancy, the other half of the same regression). A scheduled
  split carries a `queueName` +
  `schedule`/`scheduleId` annotation but **no `queueKey`**, so the work-item `reconcile` leaves it
  alone (it only adopts keyed surfaces). Single-flight is structural (`run.scheduleActive`, keyed by
  schedule id, rebuilt each sweep from the live surfaces resolved by `liveSurfaceFor`). Cadence +
  pause persist in the per-run store (`StoreFile.schedules`, `{armedAt, lastCompletionAt?, paused?,
  activeSessionID?}`) + rehydrate on the first reconcile. **Restart re-adoption (the "running status
  didn't survive a restart" fix):** a GUI restart wipes the in-memory annotation, so a still-open
  scan comes back with no `scheduleId` on its `list_surfaces` row; without a second signal the scan
  read as completed → re-anchor + duplicate-dispatch risk. So `dispatchSchedule` persists the spawn's
  stable host `sessionID` in `ScheduleState.activeSessionID` (also backfilled each sweep since a fresh
  spawn's id attaches asynchronously), and `scheduleSweep` re-adopts a surviving scan by matching that
  sessionID against the live surfaces, then **re-stamps the wiped annotation** (`setAnnotation` with
  `queueName`/`schedule`/`scheduleId`) so the dashboard re-groups + re-marks the tile and
  `list_surfaces` carries `scheduleId` again; the sessionID is cleared on real completion. **Wire contract (both sides must match — the `coerceQueueCommands` lesson):**
  template `schedules[]` is a validation chokepoint (`templates.ts validateSchedules` whitelists the
  fields + parses the cron; the loader resolves `promptFile`→`prompt`); commands
  `pause_schedule`/`resume_schedule`/`run_schedule_now`/`pause_all_schedules` carrying `{run,
  scheduleId?}` are in the `coerceQueueCommands` `QUEUE_ACTIONS` whitelist (mcp.ts) — omission
  SILENTLY DROPS them; `list_surfaces` emits `scheduleId` (the reconcile-visibility chokepoint,
  `MCPLayout.surfacesJSONData`); the status report carries a `schedules[]` array
  (`{id,name,paused,running,nextRunAt?,lastCompletionAt?}`) for the dashboard lane. Wiring:
  sidecar `queue/schedule.ts` (NEW), `queue/types.ts` (`ScheduleSpec` + `QueueTemplate.schedules`),
  `queue/templates.ts` (`validateSchedules` + promptFile resolution), `queue/store.ts`
  (`StoreFile.schedules` + `parseSchedules`/serialize), `queue/runner.ts` (`scheduleSweep`/
  `dispatchSchedule`/`scheduleStatuses`/`scheduleRecord`/`persistRun` + rehydrate), `queue/commands.ts`
  (4 actions + `scheduleId`), `queue/status.ts` (`ScheduleStatus` + report echo), `mcp.ts`
  (`coerceQueueCommands` whitelist + `scheduleId` + `Annotation`/`Surface` fields + report wire);
  macOS `MCPAnnotation.swift`/`AgentStateBridge.swift` (`queueSchedule`/`scheduleId` on
  `AgentAnnotation` + parse + merge), `MCPTools.swift` (`set_surface_annotation` schema),
  `MCPLayout.swift` (`SurfaceRow.scheduleId` + emit), `AgentDashboardController.swift`
  (`HookSnapshotEntry.scheduleId`, `pauseSchedule`/`resumeSchedule`/`runScheduleNow`/
  `pauseAllSchedules`), `QueueCommandBridge.swift` (4 `Action` cases + `scheduleId` + jsonObject +
  `QueueStatus.ScheduleStatus` decode), `AgentPreviewTile.swift` (teal schedule glyph),
  `AgentDashboardView.swift` (the thin Schedules lane). Tests: sidecar `queue/schedule.test.ts`
  (cron + skip matrix), `queue/templates.test.ts` (validate + promptFile), `queue/store.test.ts`
  (persist round-trip + `activeSessionID` round-trip), `queue/commands.test.ts` (4 actions),
  `queue/runner.test.ts` (dispatch / single-flight / prose / completion / auto-close /
  **restart re-adopt-by-sessionID + re-stamp**), `mcp.test.ts` (coerce whitelist), `status.test.ts`;
  Swift `MCPAnnotationTests` (parse + merge), `MCPServerTests` (`scheduleId` emit), `QueuePaletteTests`
  (command round-trip + status decode).

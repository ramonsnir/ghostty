# Agent Queue Supervisor (fork-only)

Turns the [Agent Dashboard](AGENT-DASHBOARD.md) / [Agent Manager](AGENT-MANAGER.md)
from a passive **observer** into an active **supervisor + driver**: you start a
**queue** from a template ("work this repo + this Linear filter") and the manager
opens a tab of splits, launches one CLI agent per work item, never doubles up on the
same item, caps how many run at once, tracks each to completion, and closes its split
when the item is **done** and the agent has gone **quiescent** (idle or waiting) —
periodically re-polling the source for new / newly-unblocked items.

It is **off by default**, macOS-only, and — the load-bearing design choice —
**completely generic**: Ghostty links no Linear/GitHub/Jira client and knows nothing
about "issues". *You* write a tiny **queue template** (a JSON file) that names a couple
of shell commands; that template is the only place your team's tooling lives.

> **Implementation notes** (for agents touching the code) live in two companion docs:
> **`AGENT-QUEUE-INTERNALS.md`** (engine, dispatch, config, adopt, start-time params) and
> **`AGENT-QUEUE-INTERNALS-UI.md`** (grid/layout, dashboard, health, live controls,
> operational hardening). Read the relevant one before changing the code.

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
   summarizer (Agent Manager) share **one sidecar** but are **independent**: it launches when
   **either** `agent-queue` **or** `agent-manager` is `true`. So `agent-queue = true` alone runs
   the queue with the summarizer (and its Haiku billing) fully off; turning on `agent-manager`
   too just adds the per-tile Haiku summaries. (See `AGENT-MANAGER.md`.)
3. **Claude Code hooks installed** (the Agent-Dashboard ones) — the close-gate keys off the
   hook-driven agent state: it closes once the item is provider-`done` **and** the agent has
   been **quiescent** (`idle` *or* `waiting`) for a few seconds. *Without the hooks a queue can
   dispatch and track but will not auto-close* (Claude Code is a repainting TUI, so the idle
   heuristic never fires). **Install them the easy way:** run **"Install Claude Agent Hooks"**
   from the Command Palette (cmd+shift+p), or accept the one-time launch prompt (it backs up +
   merges `~/.claude/settings.json` safely; re-running is a no-op). Manual fallback: `AGENT-DASHBOARD.md`.
   The hooks post to the **installed Release** on the default MCP port, so run real queues there,
   not a dev `+1/+2` build.

> **Codex (and other non-Claude agents):** the launch command is generic and a Codex split
> runs + previews fine, but it **cannot auto-close in v1** — only Claude Code emits the
> agent-state hooks the close-gate needs. You'd close its splits by hand. (Codex hooks: TODO.)

## Enable

Add to `~/.config/ghostty-ramon/config` (fork-only keys — keep them here, not in the shared
`~/.config/ghostty/config`, which an official Ghostty also reads and errors on unknown keys):

```
agent-queue = true
# Where queue templates live. REPEATABLE — a search LIST of base dirs, each scanned for
# `*.json` templates. The built-in default is ALWAYS searched FIRST, so you only ADD extra
# dirs (e.g. a shared repo of team templates). A basename in more than one dir resolves to
# the FIRST-in-search-order copy (your personal/default dir wins). `~` is expanded.
#   default (always first, no need to list it): ~/.config/ghostty-ramon/agent-manager/queues
#   add a shared repo (repeat the key for more):
# agent-queue-templates-dir = ~/git/your-project/ghostty-queues
# OPTIONAL global cap across ALL running queues combined (per-queue cap is in the template).
# Default 0 = UNLIMITED — a queue is bounded only by its own concurrency/maxItems/grid.
# agent-queue-max-total = 16
# HERO pool cap — fleet-wide CONCURRENCY ceiling on live HERO agents (the load-bearing,
# attention-scarce kind). Heroes run off the grid (no concurrency slot / max-total), but
# maxItems still caps them. Default 2 (a discipline limit). 0 = DISABLE hero concurrency.
# agent-queue-hero-max = 2
```

Quit + relaunch the fork, and rebuild the sidecar `dist` if you changed it. Nothing runs
until you **start** a queue.

## Writing a queue template

A template is a JSON file in the templates dir (e.g.
`~/.config/ghostty-ramon/agent-manager/queues/backlog.json`). **Nothing in it is
tracker-specific to Ghostty** — `list`, `status`, and the agent `command` are opaque shell
the engine just runs.

```jsonc
{
  "name": "my-team backlog",                 // the dashboard origin / run name
  "workdir": "~/git/ourservice",             // split working dir (~ expanded)
  "agent": {
    // Item fields arrive as ENV VARS — never spliced into the shell (injection-safe):
    //   GHOSTTY_ITEM_KEY  GHOSTTY_ITEM_TITLE  GHOSTTY_ITEM_URL  GHOSTTY_ITEM_META_*
    "command": "claude \"Work on $GHOSTTY_ITEM_KEY: $GHOSTTY_ITEM_TITLE ($GHOSTTY_ITEM_URL)\"",
    // How to make the agent EXIT before the split is closed (so the close doesn't hit the
    // confirm dialog, §10). Choose ONE form:
    //   "exit": { "keys": ["ctrl-d"] }      // control key(s) — DEFAULT is ["ctrl-d"]
    //   "exit": { "text": "/quit" }         // a TYPED command (e.g. Claude Code's /quit,
    //                                       // which swallows Ctrl-D); typed + Enter
    //   "exit": { "text": "/quit", "submit": false }  // type without pressing Enter
    "exit": { "keys": ["ctrl-d"] }
  },
  "concurrency": 3,                          // max simultaneous agents (TOTAL across tabs; may exceed one grid — see below)
  "maxItems": 200,                           // hard ceiling on total lifetime dispatches
  "grid": { "cols": 3, "rows": 3, "fill": "columns" },  // PANES PER TAB = cols×rows; if concurrency exceeds it, extra agents OVERFLOW to new tabs (e.g. concurrency 9 + 3×2 grid = 6 in tab 1 + 3 in tab 2). `cols` is a COLUMN CAP: panes auto-tile as the most COMPACT grid within it — 3→3 columns, 4→2×2, 5→3×2 (one cell empty), 6→3×2 — so adding a pane may reshuffle the tab. `fill` is IGNORED
  // NOTE: there is NO `quitWhenEmpty` — a run is removed only by an explicit Stop/Abort. An
  // empty `list` just means "nothing actionable now"; the run keeps polling. (A `quitWhenEmpty`
  // key is silently ignored — it was removed after it abandoned live agents on a restart.)
  "intervals": { "listMs": 60000, "statusMs": 30000 },  // provider call cadence (see note below)
  "provider": {
    // LIST: print the actionable items as a JSON array. Expected to ALREADY exclude
    // blocked / claimed / done items (the queue has no dependency graph by design).
    "list": {
      "command": ["sh", "-lc", "linear-queue-list --filter <FILTER_ID>"],
      "keyField": "identifier", "titleField": "title", "urlField": "url",
      // HERO sourcing (optional): a JSON field whose TRUTHY value marks the item a HERO (a
      // load-bearing, attention-scarce item — see "Hero agents"). Mirrors the title/url mapping.
      // Absent ⇒ no items are heroes from the list (you can still PROMOTE a running regular).
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
    // canceled/triage) are YOUR script's call — Ghostty maps no tracker. Fetched on the `list`
    // cadence; absent ⇒ no backlog button. NOT part of dispatch (grooming/debug only).
    "graph": { "command": ["linear-queue-graph"] }
  },
  "onAgentExit": "leave-and-bell",           // a crashed agent: keep the split for review + ring the bell everywhere
  "closeOnComplete": true,
  "keepOnComplete": false,                   // KEEP DEFAULT: when true, every completed split is left OPEN (held, slot kept) for manual work; the per-split 📌 pin overrides either way. Default false (auto-close).
  "closeStableSeconds": 5
}
```

Provider contract (the genericity boundary):
- **`list`** → stdout is a JSON array; `keyField`/`titleField`/`urlField`/`heroField` map fields
  onto each item (the optional `heroField`'s truthy value marks a [hero](#hero-agents-a-separate-attention-bounded-pool)).
  A non-zero exit or unparseable output **skips that poll** (never dispatches garbage).
- **`status {key}`** → `{"state":"…"}`; terminal iff `state` ∈ `doneStates`. A flaky probe is
  treated as "not done" — a split is **never** closed on a bad status. Completion is
  **status-only** (idleness alone never completes an item — no false positives).
- **`claim {key}`** → optional, fire-and-forget.
- Item fields reach the **provider** as argv elements (`{key}`) and the **agent** as
  `GHOSTTY_ITEM_*` env vars — never string-spliced into a shell line.

**`intervals` — how often the provider is actually called.** The supervisor runs a ~5s
internal sweep (reconcile / close finished splits / apply dashboard commands / refresh the
health bar every sweep), but it does **not** run your `list`/`status` commands every sweep —
those are throttled to `intervals.listMs` / `intervals.statusMs`. With the defaults
(`listMs: 60000`, `statusMs: 30000`) your tracker is queried for new work at most once a minute
and each running item's completion at most every 30s. Lower them to notice new/completed items
faster (more API calls); raise them to be gentler on a rate-limited provider. Two consequences:
a **completed** item's split closes within ~`statusMs` of finishing, and bumping a running
queue's **maxItems** (or resuming it) re-enables dispatch but the *new* agent spawns on the next
`list` poll (≤`listMs`) — the dashboard cap/phase updates instantly, only the spawn waits.

There's a no-Linear demo (a fake `list`/`status` that drains as you `touch` marker files) to try
the mechanics first — see `scratchpad/queue-example/` in this checkout.

### Start-time parameters (ask me when starting)

Instead of hard-coding the scope (e.g. a Linear project/milestone) in the provider command,
a template can declare **`params`** — and the queue **prompts you for them when you start it**.
Each answer is exported as an environment variable to your provider commands, so one generic
template can be pointed at a different project/milestone each run with no file edits:

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

- On **Start**, a small form appears with one field per param, pre-filled with its `default`.
  Each value is delivered per its **`target`**:
  - **`"env"` (the default)** → exported as `param.env` in the environment your
    `list`/`status`/`claim` commands run with (so your script reads `$LINEAR_PROJECT`, etc.).
  - **`"maxItems"`** → sets the **run's lifetime dispatch cap** for this start, overriding the
    template's `maxItems`. A positive number caps it; **`0`/`unlimited`** removes the cap;
    blank/non-numeric falls back to the template's `maxItems`. Needs no `env` (it tunes the
    engine); a template may declare at most one. This is the recommended way to vary run size.
    You can also **change this cap while the run is live** from the health bar (tap `dispatched/cap`).
- **Live preview (success signal):** once the required fields are filled, the form runs your
  `list` command with the entered values and shows **how many items would be queued** plus a
  sample of titles — so a typo (wrong project → "no matching items" / a provider error) is
  caught before you start.
- **Value suggestions (stop typing exact names):** a param may declare an optional
  **`valuesCommand`** — an argv that prints a JSON array of suggested values (bare strings, or
  `{ "value": …, "label": … }` objects). The form runs it and shows a menu next to the field.
  It runs with the OTHER fields exported as env, so a **dependent** suggester works: a milestones
  `valuesCommand` that reads `$LINEAR_PROJECT` lists the chosen project's milestones and re-runs
  when you change the project. `valuesCommand` is GUI-only (the engine never runs it).
- `required: true` blocks the start until that field is non-empty.
- The chosen values are remembered for the run and **re-applied across a restart** (scope AND
  the maxItems override).
- **The run is NAMED after its scope, and different scopes run in PARALLEL.** A live run's name
  (the dashboard section header, its tiles' origin, and the pause/stop target) is the template's
  `name` plus the chosen env-param **values**, e.g. **"ExampleOS · Acme · v2.0"**. Starting the
  same template with a **different** scope starts a **second run in parallel** in its own tab, so
  you can drive several milestones of one generic template at once. Re-starting with the **same**
  scope is an idempotent no-op. (`maxItems` is excluded from the name — use the live cap editor
  to change a running run's cap.)
- A template with **no `params`** starts immediately.
- Stays generic: the *template* names the env var / opts into the maxItems prompt / points at a
  `valuesCommand` — Ghostty has no knowledge of any tracker. Keep secrets (e.g. a `LINEAR_API_KEY`)
  in your provider's own env file; use `params` only for the per-run scope/size you want to be asked.

## Sharing queue templates across a repo

Templates + their sibling scripts are just files, so a team can keep them in a **shared git repo**
and everyone points Ghostty at it — no hand-copying a template (and its `list`/`status`/
`valuesCommand` scripts) into each person's `~/.config`. Three mechanisms:

1. **A search LIST of template dirs (`agent-queue-templates-dir`).** It's a **repeatable list**
   (a `RepeatableString`, like `project-directory`). The effective **search path** is the built-in
   default (`~/.config/ghostty-ramon/agent-manager/queues`, **always first** — you never list it)
   followed by each configured dir in order. So a shared repo is *additive*. On a basename clash
   the **first-in-search-order (personal/default) copy wins** and shadows the repo's; the palette
   badges the winning source (**"· from <dir>"**) so a shadow is visible. Equivalent paths dedup
   (order-preserving, by `standardizingPath` — which does NOT resolve symlinks, so a symlink is a
   distinct dir). Repeat the key for more dirs:

   ```
   agent-queue-templates-dir = ~/git/your-project/ghostty-queues
   agent-queue-templates-dir = ~/git/team-shared/queues
   ```

2. **The `{templateDir}` portability token + `GHOSTTY_QUEUE_TEMPLATE_DIR`.** A shared template
   usually references **sibling scripts** next to it in the repo, and a hard-coded absolute path
   breaks when a colleague clones elsewhere. The literal string `{templateDir}` in a command is
   substituted with the template file's **own resolved directory** (no trailing slash) at load,
   in exactly these sites: `provider.list.command`, `provider.status.command`,
   `provider.graph.command`, `agent.command`, and each param `valuesCommand` — but **not**
   `provider.claim.command`. (Distinct from the `{key}` argv placeholder, which is untouched.)

   ```jsonc
   "provider": {
     "list":   { "command": ["python3", "{templateDir}/list.py"] },
     "status": { "command": ["python3", "{templateDir}/status.py", "{key}"] }
   },
   "agent":  { "command": "{templateDir}/run-agent.sh" },
   "params": [ { "name": "project", "env": "PROJECT",
                 "valuesCommand": ["python3", "{templateDir}/list-projects.py"] } ]
   ```

   The same directory is also exported as **`GHOSTTY_QUEUE_TEMPLATE_DIR`** into both the provider
   exec env and the spawned agent split env, so a script can find its siblings without threading
   `{templateDir}` through every argument (e.g. `"$GHOSTTY_QUEUE_TEMPLATE_DIR/helpers/foo.sh"`).

3. **Repo-vs-`~/.config` split, secrets, `.gitignore`.** The portable template JSON + its
   `{templateDir}` sibling scripts go in the repo. **Secrets (API keys, tokens) NEVER go in the
   repo** — scripts read them from `~/.config` or a git-ignored local `*.env`. Machine-local
   overrides live in your personal queues copy (which wins by first-in-order). Per-run **state**
   (`active-runs.json`, per-run `*.state.json`) is always written to
   `~/.config/ghostty-ramon/agent-manager/queues/.state` — hardcoded, **independent of the
   templates search path** — so a shared repo dir never gets state written next to it. Recommended
   repo `.gitignore`: `__pycache__/`, `.DS_Store`, `.state/`, `*.env`.

## Running a queue's agents on a remote host (cloud-hosts)

*(fork-only, cloud-hosts Phase 4.)* A queue can dispatch its **agent splits onto a cloud box**
while its **provider commands stay on the laptop** — the "provider-laptop / agent-cloud" split.
Set a per-queue **`host`** in the template (a name from your `pty-remote-host` registry; default
`"local"` = the laptop's `pty-host`):

```jsonc
{
  "name": "cloud backlog",
  "host": "cloud-1",                         // agents run on this box (must be a pty-remote-host name)
  "workdir": "~/git/proj",                   // LAPTOP path — the PROVIDER cwd (list/status/claim)
  "agentWorkdir": "/home/user/git/proj",     // BOX path — the AGENT split's cwd (host-relative, NOT ~-expanded)
  "remoteTemplateDir": "/home/user/git/proj/.queues", // BOX path — the agent's sibling scripts
  "provider": { "list": …, "status": …, "claim": … },
  "agent":    { "command": "{templateDir}/run-agent.sh" }
}
```

- **The provider is laptop-side, always.** `list` / `status` / `claim` / `graph` (and every param
  `valuesCommand`) run on your Mac with your local creds. Only the **agent split** is placed on
  `host`. No provider scripts ship to the box.
- **`workdir` vs `agentWorkdir`.** `workdir` is the laptop provider cwd (and a LOCAL agent's cwd).
  When `host !== "local"` the agent split's cwd is `agentWorkdir` — an **absolute path ON THE BOX**,
  passed through verbatim (NOT `~`-expanded against your laptop home). Omit it and a remote agent
  falls back to `workdir` (rarely right).
- **`{templateDir}` DIVERGES between the two sides.** It (and `GHOSTTY_QUEUE_TEMPLATE_DIR`) resolves
  to the **laptop** template dir in the four provider/param sites (laptop-side) but to
  **`remoteTemplateDir`** in `agent.command` (box-side). A local queue substitutes the same dir
  everywhere — byte-identical to before.
- **Reattach is per-`(host, session)`.** A cloud agent's split survives a GUI restart and re-adopts
  by the `(host, session id)` PAIR — two boxes can each mint the same numeric session id without a
  false match. A **schedule** runs on the queue's `host` too and re-adopts by the same pair.
- **Prereqs.** The `host` name must be a configured `pty-remote-host` (see `CLOUD-HOSTS-DESIGN.md`);
  an unknown name FAILS the spawn (never a silent local fallback). The box needs a running
  `ghostty-host` and — for per-tile agent state on Linux — a host rebuilt with the `/proc` arm. The
  cloud agent bills the box's own Claude account (`AGENT-MANAGER.md` → billing scope).

## Multi-host load balancing — `host` becomes a weighted host POOL (cloud-hosts Phase 5)

*(fork-only; sidecar + GUI-lib only, NO host/protocol change.)* A single queue can declare a
**POOL of hosts** and let the supervisor **spread its agents across them by capacity**. Instead of
the scalar `host`, give the template a **`hosts[]`** array; each entry carries a per-host
**`maxConcurrent`** (the PRIMARY knob) plus an optional **`weight`** and **`maxItems`**:

```jsonc
{
  "name": "backlog",
  "hosts": [
    { "name": "local",   "maxConcurrent": 2 },
    { "name": "cloud-a",  "maxConcurrent": 4, "weight": 1 },
    { "name": "cloud-b",  "maxConcurrent": 4, "weight": 2 }
  ],
  "agentWorkdir": "/home/user/git/project-a",
  "remoteTemplateDir": "/home/user/git/project-a/.ghostty/queues",
  "concurrency": 8, "maxItems": 40
}
```

- **Placement = weighted-LEAST-LOADED** — each agent goes to the pool host minimizing
  `activeOnHost / (maxConcurrent × weight)` among hosts with a free slot (deterministic argmin;
  ties → first-declared). Not round-robin; a restart re-derives identical placements.
- **`maxConcurrent` is FLEET-WIDE** (a box is shared across queues) and counts every physical pane
  (regular + hero + schedule).
- **A full / down pool makes the item WAIT** with a clear **`hostCapacity`** reason. A spawn to a
  down box is rolled back and the box goes on a short cooldown so the next sweep routes elsewhere.
- **Back-compat is byte-identical.** Omit `hosts[]` and the scalar `host` (default `"local"`) is one
  UNBOUNDED-capacity pool. `hosts[]` WINS over `host` when both are present.
- **Precondition (doc-only, unenforced):** the working set (repo / `agentWorkdir` / `{templateDir}`)
  must exist on EVERY pool host.

Full design, the selector, and every edge case: **`CLOUD-QUEUE-BALANCING.md`**.

## Starting / controlling a queue

- **Start:** the `start_agent_queue` keybind action (e.g. `keybind = ctrl+a>q=start_agent_queue`)
  or the **"Start Agent Queue…"** command-palette entry — a fuzzy picker of your templates **shown
  by each template's `name`** (e.g. "ExampleOS", not the file `example.json`).
  `start_agent_queue:<template-name>` (the file basename) skips the picker. The picker enumerates
  the **full search path** (default-first) and merges by basename with **first-in-search-order
  wins**; a shadowed basename carries a **"· from <dir>"** source badge.
- **Watch:** the Agent Dashboard **groups tiles by origin** — one section per running queue (plus
  `(other)` for non-queue agents) — with a per-tile origin **marker** and a top **filter bar** to
  include/exclude origins (the filter is view-only — an excluded agent still rings/pushes). Queue
  tiles show their item key + link.
- **Control:** per-queue **Pause / Resume / Stop (drain) / Abort** from the section header. Stop =
  finish in-flight, dispatch no more; Abort = close everything and clear the run.
- **Keep a split (manual work after Done):** each queue tile has a **📌 pin** toggle (next to the
  **Hide** eye-slash / red **Close** `xmark.octagon`). Pin a split to **exempt it from auto-close** —
  when its item completes the supervisor leaves it OPEN (held in DONE_PENDING) so you can keep
  working. The pin shows **persistently** when kept and survives a sidecar/GUI restart. **A kept
  split still holds its concurrency slot**, so the queue won't dispatch into it until you force-close
  it (the red **Close** button) or a Stop/Abort drains the run. To keep *every* split by default, set
  `keepOnComplete: true` (the per-split pin still overrides).
- **Health bar:** each running queue's section header shows a live status line — a phase chip
  (**starting → running → paused / draining / disabled**) plus **"N waiting · M running ·
  dispatched/cap"** (cap is `∞` when unlimited, so a reached `maxItems` like `1/1` is obvious) and
  **"next: …"** upcoming item keys. The **N waiting / M running** counts are clickable dropdowns
  listing those items with Linear links (and a "go to" jump for running ones). It appears the moment
  you start a queue — **before any split spawns** ("starting · reading the queue…") — and **stays
  visible even when every tile is hidden or there are no agents yet**. Pushed every ~5s; a
  finished/aborted run's section disappears.
- **Change the cap live:** the **`dispatched/cap`** part is **tap-to-edit** — a popover (presets
  `1 / 2 / 5 / 10 / ∞` + custom) raises or lowers a *running* queue's `maxItems` **without restarting**
  it. Raising re-enables dispatch next sweep; lowering only stops *future* dispatch (running agents
  are never killed). A blank/garbage entry is ignored. A same-scope re-`start` is a no-op, so this
  editor is the only in-place way.
- **Change the concurrency live:** next to the cap is a **`⇉ N`** chip (max simultaneous agents).
  Click for a popover (presets `1 / 2 / 3 / 4 / 6 / 9` + custom) to raise/lower a *running* queue's
  concurrency without restarting. There's no "unlimited". Raising past the template's `cols×rows`
  grid **overflows the extra agents into new tabs** (e.g. `6 → 9` with a 3×2 grid = 6 in tab 1 + 3
  in tab 2).
- **Release HELD items (the dispatch-latch escape):** when an agent **crashed/exited**, OR was
  **killed before it claimed** its item, the item is back in the source `list` but the queue will
  **not re-dispatch it** — the §7.1 dispatch latch suppresses any dispatched key until a successful
  `list` no longer reports it (normally a tracker **status round-trip**). The health bar then shows
  an orange **`N held`** chip; click it for a popover listing each held item (key · title · link)
  with a **Release** button + a **Release all**. Release clears that item's latch (and cooldown) so
  the queue **re-dispatches it on the next `list` poll — with NO tracker status round-trip**. The
  chip appears only when there ARE held items (latched AND still in the backlog AND no longer active);
  a still-RUNNING agent is never shown as held.
- **Adopt a free split into a queue:** a CLI-agent split you started **by hand** (the `(other)`
  section, no origin marker) gets an **Adopt…** button (tray icon) in its tile hover controls. Click
  it to pull that agent into a running queue so the queue **tracks it like a dispatched item** —
  physically **moving the split into the queue's grid tab** and folding it into the run. The button
  is **disabled when no queue is running**. The **Adopt…** modal:
  - **Queue picker** — hidden (auto-selected) when exactly one queue is running, shown otherwise.
  - **Work-item key field** — prefilled by an on-demand Haiku read of the split's screen
    (best-effort; override anytime). A **live title preview** looks the key up in the queue's own
    backlog graph (instant): shows the title if it's on that board, or a soft "Not on this queue's
    board — adoptable, but no title" note if not (you can still adopt).
  - **Duplicate guard** — if that key is **already running** in the target queue, Adopt is blocked
    and the modal offers **"Jump to the running one"**.
  - **KEEP note** — adopting **follows the template's `keepOnComplete`** (it does NOT force-keep):
    on `status=done` the adopted split auto-closes unless its 📌 KEEP pin is set (pin it first, or
    let the template default to keep, if you want to keep working in it).
  Adopt **always succeeds** — the split lands in the tab holding the run's **lowest free grid slot**
  (a later tab, or a reused hole — NOT always the first tab), overflowing into its own new tab when
  every tab is full. It occupies a concurrency slot but is **not** counted as a fresh launch (no
  `lifetimeDispatched` bump). If the template defines a `claim`, adopt fires it for the key.
- **Promote a running split to a HERO (and demote back):** any tracked queue split has a
  **Promote…** control that flips it into the [hero pool](#hero-agents-a-separate-attention-bounded-pool)
  — it moves out of the fungible-throughput accounting into the fleet-wide `agent-queue-hero-max` cap,
  **ejects into its own dedicated tab**, becomes **kept-by-default** (never auto-closed), and lights up
  with the hero glyph across all tabs. **Promotion never blocks** — it may push you *over* the cap; the
  only consequence is no *new* heroes dispatch until live heroes drain back under the cap. A hero tile's
  **Demote** flips it back to a regular tracked item AND re-packs the split into the run's grid (targeting
  the tab with the run's lowest free slot; a full grid overflows to a fresh tab).

## Hero agents (a separate, attention-bounded pool)

Most queue work is **fungible throughput** — a predefined task, packed into a grid, auto-closed when
done. A **hero** is the opposite: something **load-bearing** that has to be *right* (research, deep
design, many small details). The scarce resource it competes for is **your attention**, not a machine
slot. So a hero is a **per-item property** that changes four things — slot accounting, lifecycle,
layout, and notification:

- **Fleet-wide concurrency cap, off the grid, but inside `maxItems`.** Live heroes are bounded for
  CONCURRENCY by the fleet-wide **`agent-queue-hero-max`** (default **2**, `0` = hero concurrency
  disabled) and run OFF the grid — a hero does **not** consume a per-queue `concurrency` slot and is
  **not** counted against `agent-queue-max-total`. **But `maxItems` DOES apply to heroes:** one total
  `lifetimeDispatched` counter spends `maxItems` across both pools. `agent-queue-hero-max` is a
  *discipline* limit (how many heroes you can hold in your head), not a resource limit.
- **Two entry paths.** The provider marks an item hero up front (the template's **`heroField`**), or
  you **promote** a running regular from the dashboard. Promotion **never blocks**.
- **Kept-by-default lifecycle.** A hero is **never** auto-closed (treated as `keep === true` regardless
  of `keepOnComplete` / the 📌 pin), so a completed hero holds in DONE_PENDING for the follow-up PR.
- **Own dedicated tab** — a hero dispatches (or, on promotion, is ejected) into its own new tab, out of
  the BSP grid, carrying a distinct **hero glyph** in the tab-accessory slot (visible across all tabs).
- **Marked everywhere; waiting states explained.** A hero node gets a **purple star** in the backlog DAG
  and in the health dropdowns; a waiting item's hover tooltip lists the exact gate(s) blocking it
  (`hero slots`, and for a regular `maxItems` / `queue concurrency` / `global concurrency`), so nobody
  wastes time bumping `maxItems` when a hero is stuck on a hero slot.
- **Louder notification.** A hero uses the **loud attention tier** and its phone web-push carries a
  distinct glyph (`kind:"hero"`). Reuses the existing bell/attention + push plumbing.

Hero classification is persisted per-run and **rehydrated across a sidecar/GUI restart**; `maxItems`
accounting rides the single total `lifetimeDispatched` counter (also persisted). Cleared on abort. Full
design + the locked wire contract: **`HERO-AGENTS.md`**.

## Schedules (recurring scan agents that groom the backlog)

A **schedule** is a recurring, **low-cognition** scan agent a queue runs on a cron cadence — it
periodically sweeps the queue's *project* (docs / backlog / code) and **opens or amends backlog issues**
for the drift, tech-debt, and coverage gaps it finds ("this doc drifted from the code — open a
doc-update issue", "these two tasks are missing to fully cover objective X"). Schedules run in the
**same grid/tab as regular work agents**; they're a per-queue feature, not a new subsystem.

**Autonomy is entirely the PROSE.** A schedule is a cron cadence + a prompt (inline `prompt` or a
neighboring `promptFile`). The prompt tells the agent what it may do — open issues (with an agreed
**auto-generated label** so they're recognizable), amend an existing one, or accept it's already in
progress — and Ghostty adds **no** special issue-creation machinery. Dedup rests on the cadence plus
the prose ("search existing issues before opening new ones").

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
put on the launch command: `spawn_split_command` delivers a split's command by TYPING it into the shell
(interior newlines collapsed), so a large multi-line/UTF-8 prose there gets mangled. Instead the runner
passes a **short** env: `promptFile` → **`GHOSTTY_SCHEDULE_PROMPT_FILE`** = its absolute path (the
launcher `cat`s it — full newlines + UTF-8 preserved); a short inline `prompt` (no file) →
`GHOSTTY_SCHEDULE_PROMPT` on the command line. Both come with `GHOSTTY_SCHEDULE_ID`/`_NAME` and the
run's resolved param env (e.g. `LINEAR_PROJECT`, so the scan is **scoped to the same project/milestone
as the run**) — the same "context via env" contract as a work item's `GHOSTTY_ITEM_*`. So the schedule's
**`command` must CONSUME the prompt** (e.g. `claude "$(cat "$GHOSTTY_SCHEDULE_PROMPT_FILE")"`). ⚠️ It
**defaults to the template `agent.command`** (the work-item launcher, which expects `GHOSTTY_ITEM_*` and
misfires for a schedule), so a schedule almost always sets its own `command`. **Use `promptFile` for
anything longer than a short line.**

**Cadence — completion-anchored, with a half-gap skip.** The `cron` is a standard 5-field expression in
**local wall-clock** time (lists/ranges/steps supported; day-of-week `0`/`7` = Sunday). The next run is
computed from **when the previous run's split closed**, not a fixed grid — so a long run pushes the next
one out — and the next cron firing is **skipped if it lands within half the local cadence** of the last
completion. **That "half the cadence" rest is CAPPED at 12 hours**, so a run that finished ≥12h before a
firing is never skipped (the cap stops a weekend-inflated gap — e.g. a weekday-daily's Fri→Mon 72h gap,
uncapped half 36h — from wrongly cancelling Monday's run after a weekend catch-up). Missed firings while
the sidecar/GUI was down (or the schedule was paused) are **not** replayed — the next due run fires once,
then re-anchors. **Single-flight:** a schedule never has two runs at once. The dashboard's **"next in …"**
always shows this post-skip value.

**Completion = the split closing** — by any cause (the agent exits and is auto-closed, or you close it).
No hook/idle dependency, so it works for Codex too. A schedule needing your input just **bells like any
agent** and stays open until you handle + close it.

**Dashboard — a thin Schedules lane + a tile glyph.** Under each queue's health row, a compact
**Schedules** lane shows one row per schedule — *name · next-run / paused / running · last-run*, a
**Run-now** button, a **pause/resume** toggle, and a **pause-all** (vacation) control. A running
scheduled split carries a teal recurring-clock glyph (distinct from the hero purple star). Pausing is
per-schedule (or all at once); a paused schedule never fires, but **Run-now still works**. Its tile omits
the 📌 KEEP pin and Promote/Demote (a schedule isn't a keyed work item); the generic **Close** and
**Hide** remain.

Schedules bypass the `concurrency` / `agent-queue-max-total` / `maxItems` caps (they're maintenance, not
throughput), but they **do occupy the grid** (overflowing to a new row/tab when full). Cadence + pause
state persist per-run and survive a sidecar/GUI restart; a still-open scheduled split is **re-adopted
after a restart with no re-dispatch** (tracked by its `scheduleId` annotation OR the persisted host
`sessionID` — completion fires only when it's gone by BOTH signals).

## What it guarantees

- **No duplicate agents per item key** — across the dispatch race, overlapping polls, and sidecar/GUI
  restarts. Works **without** a `claim` step.
- **An item dispatched once is not re-grabbed until it leaves the list and comes back.** Once the queue
  launches an agent, that item's key is *latched* until a successful `list` stops reporting it (claimed,
  blocked, labeled, or moved off the queried state) **and then it reappears**. This is the guard for the
  common workflow where the agent **waits for your go-ahead before it claims**: if you kill that split
  before it claims, the item is still in the list, and the latch keeps the queue from re-opening it. To
  deliberately re-queue a killed item, move it out of the queried state and back (a status round-trip);
  the latch is **persisted**, so a restart won't re-grab it. A **crashed** agent whose item stays listed
  is **not** auto-retried either. **OR release it in-place:** the dashboard's **`N held`** chip →
  **Release** clears the latch without a tracker round-trip, re-dispatching on the next `list` poll.
- **Concurrency** is never exceeded — per-queue `concurrency` (total across all the run's tabs) and, if
  set, the optional global `agent-queue-max-total` (default `0` = unlimited); `cols×rows` is the per-tab
  layout, not a total cap (panes overflow to new tabs). Concurrency + `max-total` bound only the REGULAR
  pool — [hero](#hero-agents-a-separate-attention-bounded-pool) agents run OFF the grid, capped for
  concurrency by `agent-queue-hero-max` (default 2). **`maxItems`, however, DOES bound heroes** (a single
  total `lifetimeDispatched` counter across both pools).
- **Tabs tile as a compact grid** — the most compact grid the `grid.cols` cap allows: 3 → 3 columns,
  **4 → 2×2**, 5 → 3×2 with one empty, 6 → 3×2. Because the split tree can't restructure in place, adding
  a pane may **reshuffle** the tab. Contraction (an agent finishing) is left to the tree's natural reflow.
- **Tabs stay packed** — as agents finish unevenly and tabs fragment (3 + 1 + 1 across three tabs), the
  queue **continuously consolidates**: when a whole tab's panes fit an earlier tab's free space it moves
  them there and closes the emptied tab (over a few sweeps). It leaves a balanced layout alone (`4 + 4`,
  `5 + 2` with a 6-pane grid). The move is focus-preserving (never yanks focus or raises a window).
- **A suspended agent keeps its slot** — if you [suspend](SUSPEND-RESUME-DESIGN.md) a queue-managed split
  (to reclaim RAM), it stays counted against the queue's concurrency AND its grid cell: the queue will
  **not** pack a replacement into the freed space, so the tab never over-fills. The suspended pane parks a
  running slot until you **Resume** it (which rejoins the run) or close it. (Before this, a suspended split
  vanished from the queue's count and a 6-slot tab could grow to 7 panes.)
- **Restart-proof** — a started queue, its tiles, and its in-flight items survive a sidecar or GUI restart
  with no re-dispatch and no orphaned agents. (A *host* restart loses all RAM-only sessions, as always.)
- **Closes cleanly** — only when the item is provider-`done` **and** its agent has been quiescent (idle
  *or* waiting) for `closeStableSeconds`, after making the agent's child process exit (so no confirmation
  dialog stalls teardown). Waiting counts because a finished Claude Code agent reliably settles in
  `waiting`, not `idle`.
- **A KEPT split is never auto-closed** — a 📌-pinned split (or any split when `keepOnComplete: true`) is
  exempt from the close gate and held OPEN for manual work until you force-close it. Persisted across
  restart.
- **A HERO split is never auto-closed either** — treated as `keep === true` UNCONDITIONALLY, so a
  completed hero holds OPEN for the quick follow-up PR (see [Hero agents](#hero-agents-a-separate-attention-bounded-pool)).
- **A crashed agent is never silently lost** — its split stays for inspection and the bell rings across
  the dashboard, web monitor, and push (`onAgentExit: leave-and-bell`).

## Cost & privacy

The queue engine is plain deterministic code — **no model calls**. The per-tile summaries are the normal
Agent Manager summarizer (Haiku via your Claude Code auth; no API key). Your provider commands run
locally with a sanitized env (the `mcp-token` and other `GHOSTTY_*` credentials are stripped before a
provider script sees them).

## Logs / troubleshooting

The sidecar (queue engine + summarizer) tees its log to a rotating file at
**`~/Library/Logs/ghostty-ramon-agent-manager.log`** (rotates to `.1` at ~5MB). Run removals,
dispatch/prune decisions, and command applications are logged there — `tail -f` it when a queue does
something surprising.

## Status / roadmap

v1 = start / track / close (no autonomous replies). Not yet: priority/dependency ordering beyond the
source `list`, cross-machine coordination, Codex auto-close. Design notes + the review ledger:
`scratchpad/agent-queue-design.md` (local).

## Implementation notes (for agents touching the code)

The load-bearing facts — file wiring, invariants, chokepoints, tests, and the redeploy classification
for each piece — live in three companion docs (this doc was split from one file that exceeded Claude
Code's 25k-token single-file Read cap; the impl notes are identifier-dense enough that they need three
files to stay individually readable):

- **`AGENT-QUEUE-INTERNALS.md`** — part 1: engine architecture, command latency, config keys
  (`agent-queue-max-total` / shared templates / `agent-queue-hero-max` + the HERO pool), the provider
  contract, hard deps, the no-duplicates guarantee, the DISPATCH LATCH + RELEASE, **adopt** (`adopt` +
  `infer_key`), the command channel, and start-time params.
- **`AGENT-QUEUE-INTERNALS-UI.md`** — part 2: grid layout (balanced BSP + multi-tab overflow +
  grid-constrained + compact re-tile + `packMove`), exit/close paths, the MCP tools, dashboard
  grouping/health bar + count dropdowns + backlog dependency graph + priority marks, the quiescent
  close-gate, KEEP, LIVE maxItems/concurrency edits, and instant command feedback.
- **`AGENT-QUEUE-INTERNALS-OPS.md`** — part 3: operational hardening — provider-call throttling,
  per-scope run identity, restart-survival hardening (+ the schedules impl), and the cloud-hosts split
  (per-queue `host` → multi-host load balancing).

⚠️ Recurring chokepoint across all three: a new queue command / annotation / template field must be
whitelisted in `coerceQueueCommands` / `validateTemplate` (`mcp.ts` / `queue/templates.ts`) **and**
emitted on `list_surfaces` rows (`MCPLayout.surfacesJSONData`) or it is **silently dropped**.

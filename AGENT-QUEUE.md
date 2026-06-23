# Agent Queue Supervisor (fork-only)

Turns the [Agent Dashboard](AGENT-DASHBOARD.md) / [Agent Manager](AGENT-MANAGER.md)
from a passive **observer** into an active **supervisor + driver**: you start a
**queue** from a template ("work this repo + this Linear filter") and the manager
opens a tab of splits, launches one CLI agent per work item, never doubles up on the
same item, caps how many run at once, tracks each to completion, and closes its split
when the item is **done** and the agent has gone **idle** — periodically re-polling the
source for new / newly-unblocked items.

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
item reports a terminal state **and** its agent has been idle a few seconds, types the
template's exit keys and **force-closes** the split. The whole thing is restart-proof:
run state is persisted by the sidecar and re-adopted (by stable host session id) after a
sidecar **or** GUI restart, so it never double-dispatches an item or orphans a live
agent. Everything else — bells, the dashboard, per-tile summaries/suggestions, web-push —
keeps working; queue splits are ordinary agent tiles, now **grouped by their queue**.

## Requirements

The supervisor **self-disables silently** (one info log) unless all of these hold:

1. **pty-host** (`pty-host = …`) — detection (`agentKind`) and the stable session ids the
   restart-resilience relies on both need it.
2. **Agent Manager enabled + built** — see `AGENT-MANAGER.md` (this is the same sidecar):
   `agent-manager = true`, `mcp-listen`/`mcp-token` set, `node` resolvable, and
   `cd macos/agent-manager && npm ci && npm run build`.
3. **Claude Code hooks installed** (the Agent-Dashboard ones) — the close-gate keys off the
   hook-driven `working`/`idle` state. *Without the hooks a queue can dispatch and track but
   will not auto-close* (Claude Code is a repainting TUI, so the idle heuristic never fires).
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
# where queue templates live (default shown):
# agent-queue-templates-dir = ~/.config/ghostty-ramon/agent-manager/queues
# global cap across ALL running queues (per-queue cap is in the template):
# agent-queue-max-total = 8
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
  "concurrency": 3,                          // max simultaneous agents (clamped to the grid)
  "maxItems": 200,                           // hard ceiling on total lifetime dispatches
  "grid": { "cols": 3, "rows": 3, "fill": "columns" },  // auto-layout; fill columns before rows
  "quitWhenEmpty": false,                    // true => the run quits when the queue drains
                                             //   AND no agents are left (even before maxItems)
  "intervals": { "listMs": 45000, "statusMs": 20000 },
  "provider": {
    // LIST: print the actionable items as a JSON array. Expected to ALREADY exclude
    // blocked / claimed / done items (the queue has no dependency graph by design).
    "list": {
      "command": ["sh", "-lc", "linear-queue-list --filter <FILTER_ID>"],
      "keyField": "identifier", "titleField": "title", "urlField": "url"
    },
    // STATUS: print {"state":"..."} for one item ({key} is a safe argv element).
    "status": {
      "command": ["linear-issue-state", "{key}"],
      "doneStates": ["done", "canceled", "merged"]
    },
    // CLAIM (optional): run once after dispatch to remove the item from the source sooner.
    // Dedup does NOT depend on it — it's a latency optimization only.
    "claim": { "command": ["linear-claim", "{key}"] }
  },
  "onAgentExit": "leave-and-bell",           // a crashed agent: keep the split for review + ring the bell everywhere
  "closeOnComplete": true,
  "closeStableSeconds": 5
}
```

Provider contract (the genericity boundary):
- **`list`** → stdout is a JSON array; `keyField`/`titleField`/`urlField` map fields onto each
  item. A non-zero exit or unparseable output **skips that poll** (never dispatches garbage).
- **`status {key}`** → `{"state":"…"}`; terminal iff `state` ∈ `doneStates`. A flaky probe is
  treated as "not done" — a split is **never** closed on a bad status. Completion is
  **status-only** (idleness alone never completes an item — no false positives).
- **`claim {key}`** → optional, fire-and-forget.
- Item fields reach the **provider** as argv elements (`{key}`) and the **agent** as
  `GHOSTTY_ITEM_*` env vars — they are never string-spliced into a shell line.

There's a no-Linear demo (a fake `list`/`status` that drains as you `touch` marker files)
to try the mechanics first — see `scratchpad/queue-example/` in this checkout.

## Starting / controlling a queue

- **Start:** the `start_agent_queue` keybind action (bind it in your fork config, e.g.
  `keybind = ctrl+a>q=start_agent_queue`) or the **"Start Agent Queue…"** command-palette
  entry — opens a fuzzy picker of your templates; choose one and the sidecar starts the run
  on its next sweep. `start_agent_queue:<template-name>` skips the picker.
- **Watch:** the Agent Dashboard now **groups tiles by origin** — one section per running
  queue (plus `(other)` for non-queue agents) — with a per-tile origin **marker** and a
  top **filter bar** to include/exclude origins (see everything, only one queue, or mute a
  noisy one; the filter is view-only — an excluded agent still rings/pushes). Queue tiles
  show their item key + link.
- **Control:** per-queue **Pause / Resume / Stop (drain) / Abort** from the section header.
  Stop = finish in-flight, dispatch no more; Abort = close everything and clear the run.

## What it guarantees

- **No duplicate agents per item key** — across the dispatch race (before an item leaves the
  filter), across overlapping polls, and across sidecar/GUI restarts. Works **without** a
  `claim` step.
- **Concurrency** is never exceeded (per-queue `concurrency`, the `cols×rows` grid, and the
  global `agent-queue-max-total`).
- **Restart-proof** — a started queue, its tiles, and its in-flight items survive a sidecar
  or GUI restart with no re-dispatch and no orphaned agents. (A *host* restart loses all
  RAM-only sessions, as always.)
- **Closes cleanly** — only when the item is provider-`done` **and** its agent has been idle
  `closeStableSeconds`, after making the agent's child process exit (so no confirmation
  dialog stalls the teardown).
- **A crashed agent is never silently lost** — its split stays for you to inspect and the
  bell rings across the dashboard, web monitor, and push (`onAgentExit: leave-and-bell`).

## Cost & privacy

The queue engine itself is plain deterministic code — **no model calls**. The per-tile
summaries/suggestions on queue tiles are the normal Agent Manager passes (Haiku/Opus via
your Claude Code auth; no API key). Your provider commands run locally with a sanitized env
(the `mcp-token` and other `GHOSTTY_*` credentials are stripped before a provider script
sees them).

## Status / roadmap

v1 = start / track / close, suggest-only on the tiles (no autonomous replies — that stays
gated behind your Approve tap). Not yet: priority/dependency ordering beyond the source
`list`, cross-machine coordination, Codex auto-close. Design notes + the review ledger:
`scratchpad/agent-queue-design.md` (local).
```

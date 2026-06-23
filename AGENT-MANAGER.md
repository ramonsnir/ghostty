# Agent Manager (fork-only)

A **Haiku status summarizer** layered on the [Agent Dashboard](AGENT-DASHBOARD.md):
each agent tile shows a live, one-line **semantic** status instead of just the raw
working/waiting chip — optimized for *which agent needs you* and *what each is doing*:

- `Waiting: httpOnly cookie or localStorage for the JWT refresh token?`
- `Implementing the counties API timeout fix — tests passing`
- `Reviewing the diff before committing`
- `Idle — task done`

And — once a session is **waiting on you** — it also proposes a **reply you can send**
(Phase 2), shown on the tile with **Approve / Edit / Dismiss**, plus a **per-session
notes** field where you tell it the session's goals.

It is **off by default**, macOS-only, and bills through your existing Claude Code
auth (no API key). **Phases 1 (summarizer) and 2 (suggest-only manager) are built**;
auto-apply and a cross-session coordinator are future phases. It **never sends on its
own** — a suggestion only reaches the agent when *you* tap Approve.

## How it works (one paragraph)

A small **TypeScript sidecar** (`macos/agent-manager/`, built with the Claude Agent
SDK) runs alongside the GUI. Every ~5s it asks the in-app **MCP server** for the live
surfaces, picks the ones the dashboard has detected as agents, reads each one's
viewport, makes a single **Haiku** call to summarize it, and writes the one-liner back
onto the tile via the MCP `set_surface_annotation` tool. The summary call uses no tools
and the SDK authenticates the same way the `claude` CLI does — so there is **no API key
in Ghostty** and usage is billed to your normal plan. On a separate, slower pass it
also runs a **manager** (Opus) for any session that is *waiting* — assembling its goals
(your notes + recent prompts) + screen and proposing a reply, written to the same tile.
The sidecar **never types into a session**: the suggestion is rendered on the tile and
only sent if you tap Approve — a single tap that **types it in *and* submits it** (your
deliberate authorization; nothing autonomous ever sends).

## Requirements

1. **pty-host + Agent Dashboard** enabled (the summarizer annotates dashboard tiles):
   `pty-host = …` and `agent-dashboard = true` already in your fork config.
2. **MCP server** enabled — the sidecar's only transport:
   `mcp-listen = 127.0.0.1:8765` plus an `mcp-token` (in `~/.config/ghostty-ramon/local`).
3. **node** on your login shell `PATH` (the GUI probes `command -v node`), or set
   `agent-manager-node-path` explicitly.
4. **The sidecar must be built** (it is not bundled into the app yet):
   ```sh
   cd ~/git/ghostty/macos/agent-manager && npm ci && npm run build
   ```
5. **Claude Code hooks** (the same ones the Agent Dashboard uses — see
   `AGENT-DASHBOARD.md`) for the *best* summaries: they feed your latest prompt and the
   working/waiting state, which make the one-liners specific. Without them the summarizer
   falls back to the on-screen text alone and reads thinner.

## Enable

Add to `~/.config/ghostty-ramon/config` (fork-only keys — keep them here, not in the
shared `~/.config/ghostty/config`):

```
agent-manager = true
# optional, only if `node` isn't on your login-shell PATH:
# agent-manager-node-path = /usr/local/bin/node
```

Quit + relaunch the fork. On launch the app checks the gate (enabled + MCP configured +
node resolvable); if any is missing it stays **silently dormant** (one info log, the
dashboard is unaffected). Otherwise it spawns + supervises the sidecar.

## Suggestions + notes (Phase 2)

When a session is **waiting** on you, its tile shows a proposed reply with three actions:

- **Approve** — **types the suggestion into the agent's prompt *and* submits it** in one
  tap (it sends a Return for you). Still suggest-only: the tap is *your* authorization,
  not the sidecar acting on its own. Edit first if you want to tweak it.
- **Edit** — tweak the text in place, then Approve types + submits your edited version.
- **Dismiss** — clear the suggestion (the status summary stays). After a dismissal the
  manager **stops re-proposing for that session until the situation meaningfully
  changes** (a new prompt/tool/state or a real screen change), so a reply you rejected
  doesn't keep coming back unchanged.

**The manager proposes a reply ONLY when it would actually move the session forward** —
it answers a question the agent is blocked on, makes a decision it's waiting for, or
gives concrete next direction grounded in your goals. When it has nothing value-adding
to say (the agent is just finishing/notifying, or it would only be guessing), it
**abstains and shows nothing** — no "OK, thanks" filler. So an agent that's waiting but
not truly blocked on *you* will often show just its status summary, which is correct.

Each shown suggestion has an inline **confidence %** — the manager's honest self-rating
of how grounded/advancing it is. Very-low-confidence replies are **suppressed** (hidden
entirely); borderline ones (≈35–50%) are **dimmed** so strong, goal-advancing ones stand
out. Want more (or fewer) suggestions on a session? Give it **notes** (below) — concrete
goals make more replies "grounded"; vague sessions correctly stay quiet.

Each tile also has a **notes** field: type the session's goal/guidance there (e.g.
"after the fix, add tests and update the changelog") and the manager weights it in
future suggestions. Notes persist per session across relaunches.

Suggestions only fire on `waiting` (debounced, ~20s) and use the manager's
accumulated-session-context memory. The manager has **no tools and cannot act** — it
only proposes text; the sole send path is your Approve tap.

## Tuning the prompts (no rebuild)

Both passes take an optional override file, appended to the built-in prompt and reloaded
on change (cannot change the output format or grant any capability — both run with no tools):

```
~/.config/ghostty-ramon/agent-manager/summarizer.md   # the status one-liner
~/.config/ghostty-ramon/agent-manager/manager.md       # the waiting-reply suggestions
```

e.g. summarizer: "Prefer the file/feature name over the verb; flag failing tests."
e.g. manager: "Be terse; never propose destructive commands; ask a clarifying question
if the goal is ambiguous."

## Verifying / troubleshooting

- Console.app → filter subsystem = your bundle id, category = `agent-manager`. Expect
  `Agent Manager sidecar started` and a per-surface `surface <uuid>: "<summary>"` line.
- **Dormant?** The one info log says why (`agent-manager is off` / `mcp-listen is not
  set` / `mcp-token is not set` / `node could not be resolved`).
- **No summaries on tiles?** Confirm the dashboard shows the agent as a tile at all
  (detection is shared); confirm the sidecar is built (`macos/agent-manager/dist/index.js`
  exists); confirm `mcp-listen`/`mcp-token` are set.
- **Summaries look generic?** That's the no-hooks fallback (viewport-only). Install the
  Claude Code hooks so your prompt + working/waiting state reach the summarizer.
- **No suggestion on a waiting tile?** Often correct: the manager **abstains** unless it
  has a grounded, value-adding reply (it won't pad with acknowledgments). It also needs the
  hooks (the `waiting` state comes from them), fires only after the ~20s debounce, and
  suppresses anything it rates low-confidence. To get a suggestion where you expect one,
  add **notes** stating the goal so a reply becomes "grounded." (Separately: the manager has
  its OWN budget, so a busy fleet doesn't starve it — if you see summaries but the manager
  *never* suggests on ANY genuinely-blocked tile, that's a regression worth reporting.)

## Cost & privacy

Each summary is one Haiku call, gated by a per-session debounce (~12s) and an
idle-skip, with a small concurrency cap — so a wall of idle/unchanged sessions costs
nothing. The session's recent on-screen text is sent to the model for summarization;
disable the feature (or close the tile) for any session you don't want summarized.

## Status / roadmap

**Built:** Phase 1 (read-only summarizer) + Phase 2 (suggest-only manager — proposes a
reply on `waiting`, you Approve/Edit/Dismiss; never sends on its own). **Not built:**
Phase 3 (opt-in *auto-apply*, gated server-side at the MCP boundary, never trusted to
the model) and Phase 4 (a cross-session coordinator). Architecture/notes:
`.claude/plans/agent-manager-design.md`.

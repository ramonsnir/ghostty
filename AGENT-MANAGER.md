# Agent Manager (fork-only)

A **Haiku status summarizer** layered on the [Agent Dashboard](AGENT-DASHBOARD.md):
each agent tile shows a live, one-line **semantic** status instead of just the raw
working/waiting chip — optimized for *which agent needs you* and *what each is doing*:

- `Waiting: httpOnly cookie or localStorage for the JWT refresh token?`
- `Implementing the counties API timeout fix — tests passing`
- `Reviewing the diff before committing`
- `Idle — task done`

It is **off by default**, macOS-only, **read-only** (it never types into a session —
it only annotates the tile), and bills through your existing Claude Code auth (no API
key). Its Haiku traffic can optionally be routed to a **separate account** so it never
drains your main quota (see *Account routing* below).

## How it works (one paragraph)

A small **TypeScript sidecar** (`macos/agent-manager/`, built with the Claude Agent
SDK) runs alongside the GUI. Every ~5s it asks the in-app **MCP server** for the live
surfaces, picks the ones the dashboard has detected as agents, reads each one's
viewport, makes a single **Haiku** call to summarize it, and writes the one-liner back
onto the tile via the MCP `set_surface_annotation` tool. The summary call uses no tools
and the SDK authenticates the same way the `claude` CLI does — so there is **no API key
in Ghostty** and usage is billed to your normal plan. (A second, independent loop in the
same sidecar drives the [Agent Queue](AGENT-QUEUE.md) when it is configured — that is a
deterministic, LLM-free dispatcher and is unrelated to the summarizer.)

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

## Account routing (optional — bill the summarizer to a separate account)

The summarizer polls continuously, so on a busy fleet its Haiku calls can eat into the
account you also code with. You can route them to a **different** account instead.

By default there is **no routing** — the summarizer inherits whatever Claude Code auth
is ambient (it works fine on a machine with no multi-account setup at all). To route it,
write an account spec to:

```
~/.config/ghostty-ramon/agent-manager/account
```

The value is one of:

- a **bare account name** (e.g. `dev`) — resolved to `~/.claude-accounts/<name>`, the
  convention used by a `claude-accounts`/`claude-pool` setup; or
- an **absolute or `~`-relative path** — used directly as the account's `CLAUDE_CONFIG_DIR`.

The summarizer's model calls then run with that `CLAUDE_CONFIG_DIR` (HOME/PATH/OAuth are
otherwise preserved), so they bill against that account. If the spec doesn't resolve to a
real directory, it's ignored and the summarizer falls back to the ambient auth (a warning
is logged). The `GHOSTTY_AGENT_MANAGER_ACCOUNT` environment variable, if set, takes
precedence over the file.

This is a **sidecar-side** setting: change the file and restart the sidecar (the GUI
respawns it; no app relaunch needed for the value to take effect on the next spawn).

## Tuning the prompt (no rebuild)

The summarizer takes an optional override file, appended to the built-in prompt and
reloaded on change (it cannot change the output format or grant any capability — the call
runs with no tools):

```
~/.config/ghostty-ramon/agent-manager/summarizer.md   # the status one-liner
```

e.g. "Prefer the file/feature name over the verb; flag failing tests."

## Verifying / troubleshooting

- Console.app → filter subsystem = your bundle id, category = `agent-manager`. Expect
  `Agent Manager sidecar started` and a per-surface `surface <uuid>: "<summary>"` line.
  If account routing is active you'll also see `summarizer billing routed to CLAUDE_CONFIG_DIR=…`.
- **Dormant?** The one info log says why (`agent-manager is off` / `mcp-listen is not
  set` / `mcp-token is not set` / `node could not be resolved`).
- **No summaries on tiles?** Confirm the dashboard shows the agent as a tile at all
  (detection is shared); confirm the sidecar is built (`macos/agent-manager/dist/index.js`
  exists); confirm `mcp-listen`/`mcp-token` are set.
- **Summaries look generic?** That's the no-hooks fallback (viewport-only). Install the
  Claude Code hooks so your prompt + working/waiting state reach the summarizer.

## Cost & privacy

Each summary is one Haiku call, gated by a per-session debounce (~12s) and an
idle-skip, with a small concurrency cap — so a wall of idle/unchanged sessions costs
nothing. The session's recent on-screen text is sent to the model for summarization;
disable the feature (or close the tile) for any session you don't want summarized. Use
*Account routing* above to keep this traffic off your primary account.

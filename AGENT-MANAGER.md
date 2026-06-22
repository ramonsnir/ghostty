# Agent Manager (fork-only)

A **Haiku status summarizer** layered on the [Agent Dashboard](AGENT-DASHBOARD.md):
each agent tile shows a live, one-line **semantic** status instead of just the raw
working/waiting chip — optimized for *which agent needs you* and *what each is doing*:

- `Waiting: httpOnly cookie or localStorage for the JWT refresh token?`
- `Implementing the counties API timeout fix — tests passing`
- `Reviewing the diff before committing`
- `Idle — task done`

It is **off by default**, macOS-only, and bills through your existing Claude Code
auth (no API key). This is **Phase 1** of a larger design (a per-session manager that
suggests/auto-applies replies, and a cross-session coordinator, are future phases —
not built yet).

## How it works (one paragraph)

A small **TypeScript sidecar** (`macos/agent-manager/`, built with the Claude Agent
SDK) runs alongside the GUI. Every ~5s it asks the in-app **MCP server** for the live
surfaces, picks the ones the dashboard has detected as agents, reads each one's
viewport, makes a single **Haiku** call to summarize it, and writes the one-liner back
onto the tile via the MCP `set_surface_annotation` tool. The summary call uses no tools
and the SDK authenticates the same way the `claude` CLI does — so there is **no API key
in Ghostty** and usage is billed to your normal plan. The sidecar is read-only: it
never types into a session.

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

## Tuning the summaries (no rebuild)

The summarizer's wording/priorities are tunable at runtime via an optional override
file, appended to the built-in prompt and reloaded on change:

```
~/.config/ghostty-ramon/agent-manager/summarizer.md
```

e.g. "Prefer the file/feature name over the verb. Flag any failing test or error
prominently." The override **cannot** change the output format or grant the summarizer
any capability (it runs with no tools).

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

## Cost & privacy

Each summary is one Haiku call, gated by a per-session debounce (~12s) and an
idle-skip, with a small concurrency cap — so a wall of idle/unchanged sessions costs
nothing. The session's recent on-screen text is sent to the model for summarization;
disable the feature (or close the tile) for any session you don't want summarized.

## Status / roadmap

Phase 1 (this) is the read-only summarizer. Future phases (a per-session manager that
proposes — and, opt-in, auto-applies — replies, and a cross-session coordinator) are
designed but not built; auto-apply will be gated server-side at the MCP boundary, never
trusted to the model. Architecture/notes: `.claude/plans/agent-manager-design.md`.

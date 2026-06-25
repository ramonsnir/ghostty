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

## Rate-limit (and other) attention bells

The summarizer also doubles as an **attention watchdog**: when a session hits the
Claude **usage/rate-limit prompt** — the interactive *"Stop and wait for limit to
reset / Ask your admin for more usage"* screen that silently halts the agent without
ringing a bell — the sidecar **rings the bell for that surface** (via the MCP
`signal_attention` tool). That fans out exactly like a real terminal bell: the 🔔 tab
title, the Agent Dashboard aggregate, the web monitor, and a phone push all light up,
so you notice even when you've stepped away.

**Haiku is the sole classifier — there is no text/regex match.** The summary call
already reads the screen every time it runs; it now also returns an optional `alert`
tag in its structured output, and it is told to judge the **current, live** state at
the bottom of the screen — so it sets `rate_limited` only while the agent is *actually
halted on that prompt right now*, and drops it the moment the agent resumes (even if the
old prompt text is still scrolled up in view). The loop rings on the **rising edge** of
that tag and clears when Haiku reports no alert — so:

- It **rings once** when the prompt appears and won't nag every 5s while it sits there.
- **Recovery un-rings correctly** — as soon as Haiku reclassifies the live screen, the
  bell re-arms. Stale text scrolled up in history never (re-)fires it, because the
  decision isn't a substring match.

Why no regex backstop: a regex matches the text *anywhere* in the viewport and can't
tell a live prompt from one scrolled up in history — so it would both miss recovery and
*falsely re-ring* after recovery. Letting Haiku own the whole decision is what fixes
both. To recognize a new condition, just teach the summarizer prompt a new `alert` tag
(`macos/agent-manager/src/prompts.ts`) — no code change.

> **One caveat — route the summarizer to a separate account.** Because the watchdog is
> the summarizer's own Haiku call, if that call bills to *the same account that just got
> rate-limited*, it fails too and the **first** detection can't fire (a held alert still
> stays armed; only the initial ring is at risk). Point the summarizer at a different
> account via **[Account routing](#account-routing-optional--bill-the-summarizer-to-a-separate-account)**
> so the watchdog survives the very limit it is watching for. This is the recommended
> setup.

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

## Tuning cost (no rebuild)

The summarizer decides *when* to call Haiku with a few gates you can tune in an optional
JSON file (sibling of `summarizer.md`), so you can dial usage down without a rebuild —
**restart the sidecar to apply** (kill the `node` child, or quit + relaunch the fork; the
GUI respawns it):

```
~/.config/ghostty-ramon/agent-manager/config.json
```

```jsonc
{
  "debounceMs": 30000,          // min ms between calls per session (default 30000)
  "changeRatioThreshold": 0.2,  // 0..1 — fraction of the screen tail that must differ
                                //   to count as a real change (default 0.2; 0 = any diff)
  "skipHidden": true,           // never summarize a tile you've hidden in the dashboard
  "idleSkipSeconds": 45,        // unchanged + idle this long => skip (default 45)
  "maxConcurrent": 10           // also the per-sweep batch cap
}
```

Unknown / out-of-range keys are ignored (the default is kept), and an absent or malformed
file just uses the defaults. What each lever buys you:

- **`skipHidden`** — the cheapest win: hidden tiles cost nothing. Hide the agents you
  aren't watching.
- **`changeRatioThreshold`** — the screen is compared *fuzzily*: spinner glyphs and
  elapsed-time/token counters are normalized out, and a session only re-summarizes when
  more than this fraction of its recent lines actually change. A higher value = fewer
  calls (and slightly staler summaries); a lower value = fresher (and more calls).
- **`debounceMs`** — the hard floor between calls for one session. Raise it to cut the
  rate across the board.
- A **waiting/idle** agent whose footer is merely animating is skipped regardless — its
  summary wouldn't change anyway.

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

Each summary is one Haiku call, gated by a per-session debounce (~30s), a fuzzy
change-detector (animation-proof), a hidden-tile skip, and an idle-skip, with a small
concurrency cap — so a wall of idle/unchanged sessions costs nothing. See *Tuning cost*
above to dial it further. The session's recent on-screen text is sent to the model for
summarization; hide the tile (or disable the feature) for any session you don't want
summarized. Use *Account routing* above to keep this traffic off your primary account.

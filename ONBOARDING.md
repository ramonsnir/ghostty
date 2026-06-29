# Getting started with Ghostty (ramon)

A personal fork of [Ghostty](https://ghostty.org) — a fast, native macOS terminal —
with extra tools for working alongside CLI coding agents (Claude Code / Codex). It
runs **side by side** with the official Ghostty and won't touch your existing Ghostty
setup. This is the first thing to read after installing.

## Install (2 minutes)

1. Download `Ghostty.dmg` from the [Releases page](https://github.com/ramonsnir/ghostty/releases/latest).
2. Drag **Ghostty (ramon)** into `/Applications`.
3. Open it. It's signed + notarized, so it should open cleanly; if macOS ever objects,
   right-click the app → **Open**.
4. **Relaunch it once.** The first launch sets up a small background "host" process and
   writes your config; after one relaunch your sessions are *hosted* (they survive
   quitting and reopening the app) and the agent features are fully live.

(Update / uninstall details live in `SHARING.md`.)

## What this fork adds

**You don't need to learn any keybindings.** Everything below is reachable from the
**Command Palette** — press **⌘⇧P** (or **View ▸ Command Palette**) and type a word like
"split", "tab", "project", or "agent".

- **Agent Dashboard** — a side panel of live previews of every split running a CLI agent,
  across all your tabs and windows. Click a tile to jump straight to it. It opens on its
  own; toggle it from the Command Palette → "Toggle Agent Dashboard".
- **Split & tab power-tools** — flip / swap / merge splits, eject a pane into its own tab,
  mark-and-pull a split across tabs and windows, equalize splits, "go to last split", and
  a fuzzy project picker. All in the Command Palette.
- **Let an agent drive your terminal (MCP)** — a local MCP server (auto-configured AND
  auto-registered with Claude Code on first launch) lets Claude Code or Codex list your
  splits, type into them, reorganize your layout, and watch for prompts. → `MCP-SERVER.md`
- **Agent Manager** — a live one-line status on each agent tile, plus a **rate-limit
  bell watchdog** that rings when an agent gets throttled so you're not left staring at a
  stuck session. → `AGENT-MANAGER.md`
- **Agent Queue** (opt-in) — a supervisor that runs a whole queue of agents from a JSON
  template, one per split, and tears each down when it's done. → `AGENT-QUEUE.md`
- **Phone monitor** (opt-in) — watch and drive your splits from your phone over Tailscale.
  → `WEB-MONITOR.md`

## What works out of the box vs. needs setup

| Capability | Out of the box? | Notes |
|---|---|---|
| Terminal, splits, tabs, all fork actions (via Command Palette) | ✅ | nothing to configure |
| Signed / notarized launch | ✅ | right-click → Open if Gatekeeper objects |
| Auto-updates (from the fork's own feed) | ✅ | notify-only by default |
| Hosted sessions (survive app quit/relaunch) | ✅ after **one relaunch** | first launch installs the host; relaunch once and it's reliable thereafter |
| Agent Dashboard (live agent previews) | ✅ | shows tiles once a `claude`/`codex` is actually running in a split |
| MCP server (let an agent drive your terminal) | ✅ | auto-configured AND auto-registered with Claude Code on first launch (localhost + a random token in `~/.config/ghostty-ramon/local`) |
| Agent Manager status + rate-limit bell watchdog | ✅ if `node` + `claude` installed | uses your installed Claude Code CLI (your own subscription); self-disables if either is missing |
| Agent Queue (supervised runs) | ⚙️ opt-in | `node` + the Claude hooks + a template — see `AGENT-QUEUE.md` |
| Phone monitor | ⚙️ opt-in | Tailscale + a bind address in `local` — see `WEB-MONITOR.md` |

**Two optional prerequisites unlock the agent tooling**, and both self-disable cleanly if
absent (nothing crashes):

- **`node` on your PATH** — runs the small Agent Manager / Queue sidecar.
- **Claude Code installed** — its `claude` CLI powers the per-tile status summaries and the
  rate-limit watchdog, billed to *your own* Claude subscription. (Nothing is bundled or
  charged separately.)

## Optional power features — "is this for me?"

- **An agent driving your terminal (MCP).** Already configured **and** auto-registered with
  Claude Code on first launch (if `claude` is on your PATH) — open a new `claude` session and
  the `ghostty` MCP is just there. Nothing to run. If you installed `claude` *after* Ghostty,
  relaunch Ghostty once (it registers on the next launch), or do it by hand:
  `claude mcp add ghostty --scope user -- "$HOME/.local/bin/ghostty-mcp"` (the shim is on your
  PATH and reads the auto-generated token for you). → `MCP-SERVER.md`
- **Rich agent status + auto-close (Manager / Queue).** Install the Claude Code agent-state
  hooks the easy way: run **"Install Claude Agent Hooks"** from the Command Palette (⌘⇧P), or
  accept the one-time prompt offered on launch when the queue/manager is enabled. (It safely
  backs up + merges `~/.claude/settings.json`; a manual copy/merge fallback is in
  `AGENT-DASHBOARD.md`.) Then set `agent-queue = true` and add a template to run a queue.
- **Phone monitor.** Set `web-monitor-listen` + a token in `~/.config/ghostty-ramon/local`
  and put `tailscale serve` in front. → `WEB-MONITOR.md`

## Keybindings — optional, and *not* required

The fork ships with **no keybindings active by default** — every feature above is in the
Command Palette. The author personally drives all of it from a **tmux-style `ctrl+a`
prefix**, and that entire layout ships **commented out** at the bottom of
`~/.config/ghostty-ramon/config`. To adopt it, uncomment that block; or bind the same
*actions* to keys you prefer. (Heads up: `ctrl+a` deliberately shadows readline's
start-of-line — a tmux habit that's a matter of taste.)

Run **`ghostty-ramon +list-keybinds`** to see whatever bindings you actually have active.

<details>
<summary>The author's <code>ctrl+a</code> cheat sheet (optional reference)</summary>

Each is a chord: press `ctrl+a`, release, then the key.

| Press `ctrl+a` then… | Does |
|---|---|
| `%` / `"` | split right / split down |
| arrows | move focus between splits |
| `o` / `;` | cycle to next / previous split |
| `x` | close split · `z` zoom split · `space` equalize splits |
| `{` / `}` | swap split with previous / next |
| `h` `j` `k` `l` | resize (hold to repeat); `shift+` = bigger step |
| `q` | mark split · `m` pull the marked split here · `shift+!` eject pane to new tab |
| `c` | new tab · `n` / `p` next / prev tab · `1`–`9` go to tab N |
| `w` | tab overview · `,` rename tab · `shift+&` close tab |
| `f` | project picker · `d` Agent Dashboard |
| `ctrl+a` | jump to last split · `shift+:` command palette · `r` reload config |

There's also a non-prefix `ctrl+cmd+shift+f` = flip split horizontally (plus more flip /
toggle-direction / merge-tab bindings, all commented in the config).

</details>

## Discovering more

- **`ghostty-ramon` CLI** (installed on your PATH):
  - `ghostty-ramon +list-keybinds` — your currently-active bindings.
  - `ghostty-ramon +show-config --default --docs` — every config option, with docs.
- **Command Palette** (⌘⇧P) — type to find every fork action.
- **Ask a connected agent** — once MCP is connected, an agent can answer "what can this do
  / how do I enable X / what did I misconfigure" using the built-in knowledge tools
  (`docs_for_feature`, `describe_config_key`, `list_config_keys`, `get_effective_config`).
- **Feature docs** at the repo root: `SHARING.md`, `MCP-SERVER.md`, `WEB-MONITOR.md`,
  `AGENT-DASHBOARD.md`, `AGENT-QUEUE.md`, `AGENT-MANAGER.md`, `BELL-ATTENTION.md`.

## Troubleshooting

**All my terminals are blank / empty.** The fork uses a small background "host" process
(a launchd agent) that owns your sessions; if it didn't start, panes show up empty. Fix:
quit and reopen the app. If it persists, check the host log at
`~/Library/Logs/ghostty-ramon-host.log`. (Restarting the host ends live sessions — they're
in memory only.)

**Agent Dashboard / Manager / Queue features do nothing.** They need `node` on your PATH
(the sidecar) and, for status summaries + the rate-limit watchdog, **Claude Code
installed** (`command -v node` and `command -v claude` should both succeed). The Agent
Queue additionally needs the Claude hooks installed (`Contents/Resources/claude-hooks/`,
see `AGENT-DASHBOARD.md`).

**The Agent Dashboard panel is empty.** Expected until a CLI agent (`claude` / `codex`) is
actually running in one of your splits — start one and it appears.

**Updating / uninstalling.** Updates arrive automatically (notify-only, from the fork's own
release feed). To uninstall: drag the app to the Trash; optionally remove
`~/.config/ghostty-ramon/` and
`~/Library/LaunchAgents/com.mitchellh.ghostty-ramon.host.plist`.

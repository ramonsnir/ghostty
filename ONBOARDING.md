# Getting started with Ghostty (ramon)

Welcome. This is a personal fork of [Ghostty](https://ghostty.org) with extra
tmux-style split/tab commands and an agent dashboard, packaged to run **side by
side** with an official Ghostty (different name, icon, and config — it won't
disturb your existing Ghostty).

This is the **first thing to read** after installing. It covers:

1. [The keybind cheat sheet](#keybind-cheat-sheet) — the headline gestures.
2. [What works out of the box vs. needs setup](#what-works-out-of-the-box-vs-needs-setup).
3. [Discovering the rest](#discovering-the-rest) — how to find every keybind and
   config key **without scrolling the command palette**.

> Install/update mechanics (DMG, Sparkle auto-update, uninstall, secrets in
> `local`, connecting an agent) live in **`SHARING.md`**. This file is about
> *using* the fork.

---

## Keybind cheat sheet

The fork's headline actions hang off a tmux-style **`ctrl+a` prefix**. This is a
**chord**, not a held combo: press and release `ctrl+a`, then press the next key.
For example, "split right" is `ctrl+a` then `%`.

These are the bindings the seeded `~/.config/ghostty-ramon/config` ships with —
they're all editable, and `ghostty-ramon +list-keybinds` always prints what's
actually active on your machine.

### Splits

| Gesture | Action |
|---|---|
| `ctrl+a` then `%` | Split right (new pane to the right) |
| `ctrl+a` then `"` | Split down (new pane below) |
| `ctrl+a` then `←/→/↑/↓` | Move focus between splits (wraps around at the edge) |
| `ctrl+a` then `o` / `;` | Cycle to next / previous split |
| `ctrl+a` then `z` | Zoom the focused split (toggle full-tab) |
| `ctrl+a` then `x` | Close the focused split |
| `ctrl+a` then `{` / `}` | Swap focused split with the previous / next one |

### Resize (hold-repeat)

| Gesture | Action |
|---|---|
| `ctrl+a` then `h/j/k/l` | Resize left/down/up/right by 10 (hold the key to repeat) |
| `ctrl+a` then `shift+h/j/k/l` | Resize by 50 (bigger steps) |
| `ctrl+a` then `space` | Equalize all splits |

After `ctrl+a>h` (etc.) the sequence stays armed for ~0.5s, so you can tap `h h h`
to keep resizing without re-pressing the prefix.

### Move panes between tabs

| Gesture | Action |
|---|---|
| `ctrl+a` then `q` | Mark the focused split (orange border; press again to unmark) |
| `ctrl+a` then `m` | Pull the marked split next to the focused one (cross-tab / cross-window) |
| `ctrl+a` then `shift+!` | Eject the focused split into its own new tab |

### Tabs

| Gesture | Action |
|---|---|
| `ctrl+a` then `c` | New tab |
| `ctrl+a` then `n` / `p` | Next / previous tab |
| `ctrl+a` then `1`..`9` | Go to tab N |
| `ctrl+a` then `w` | Tab overview |
| `ctrl+a` then `,` | Rename the current tab |
| `ctrl+a` then `shift+&` | Close the current tab |

### Find / jump

| Gesture | Action |
|---|---|
| `ctrl+a` then `f` | Project picker (needs `project-directory` set — see below) |
| `ctrl+a` then `d` | Toggle the Agent Dashboard |
| `ctrl+a` then `ctrl+a` | Jump to the last split (toggles back on a second press) |

### Misc

| Gesture | Action |
|---|---|
| `ctrl+a` then `shift+:` | Command palette |
| `ctrl+a` then `r` | Reload config |

> Tip: don't memorize these — run `ghostty-ramon +list-keybinds` to print them all,
> and edit `~/.config/ghostty-ramon/config` to change any of them.

---

## What works out of the box vs. needs setup

After installing the DMG and **relaunching once** (the hosted backend takes effect
on the second launch), here's the lay of the land:

| Feature | Status |
|---|---|
| Fork keybinds (`ctrl+a` splits/tabs/resize/move) | **Works OOTB** — seeded config |
| Hosted backend (sessions survive a GUI quit/relaunch; live previews) | **Works OOTB** after one relaunch |
| Agent Dashboard (live tiles of your Claude/Codex splits) | **Works OOTB** — on by default (`ctrl+a>d`) |
| `ghostty-ramon` discovery CLI | **Works OOTB** — installed to `~/.local/bin` |
| Project selector (`ctrl+a>f`) | Set `project-directory` (one line in config) |
| MCP server (let an agent drive your splits) | Set `mcp-listen` + `mcp-token` in `local` |
| Web monitor (drive splits from your phone) | Set `web-monitor-listen` in `local` (+ Tailscale) |
| Agent **Queue** (one CLI agent per work item) | `node` on PATH + agent-state hooks + a template |
| Agent **Manager** Haiku tile summaries | **Dev-only** — needs npm packages not shipped in the DMG |

"OOTB" = nothing to configure. The rest are deliberate opt-ins. The quick recipes:

- **Project picker (`ctrl+a>f`).** Point it at where you keep your repos. In
  `~/.config/ghostty-ramon/config`, uncomment and edit:
  ```ini
  project-directory = ~/git
  ```
  Each immediate subdirectory of that base becomes an entry in the fuzzy picker.

- **MCP server (agent control).** Put a localhost bind + a token (a
  shell-execution credential) in the **untracked** `~/.config/ghostty-ramon/local`,
  then relaunch:
  ```ini
  mcp-listen = 127.0.0.1:8765
  mcp-token  = <openssl rand -hex 24>
  ```
  Then connect Claude Code: `claude mcp add ghostty -- "$HOME/.local/bin/ghostty-mcp"`.
  See **MCP-SERVER.md**.

- **Web monitor (phone).** Bind to this Mac's Tailscale IP in `local` and relaunch
  — see **WEB-MONITOR.md**.

- **Agent Queue.** Turn on `agent-queue = true` in config, set `mcp-listen`/
  `mcp-token` in `local`, install the Claude Code agent-state hooks (see
  **AGENT-DASHBOARD.md** — the source ships at `…/Ghostty (ramon).app/Contents/
  Resources/claude-hooks/`), have `node` on your PATH, and author a queue template
  (see **AGENT-QUEUE.md**).

> The Agent Dashboard panel may open **empty** on the very first run — live previews
> need the hosted backend, which only kicks in on the second launch. Quit and reopen
> once and the tiles fill in.

---

## Discovering the rest

The fork adds a lot of keybinds and config keys. **Don't go hunting in the command
palette** — it's a long list and you won't scroll it. Use these concrete
entrypoints instead:

### The `ghostty-ramon` CLI

Installed to `~/.local/bin/ghostty-ramon` on first launch (a symlink to the app's
multitool, named `ghostty-ramon` so it never collides with an official `ghostty`
CLI on your PATH):

```sh
ghostty-ramon +list-keybinds   # every active keybind — your seeded + custom bindings
ghostty-ramon +show-config     # your effective configuration
```

If `~/.local/bin` isn't on your `PATH`, add it (e.g. `export PATH="$HOME/.local/bin:$PATH"`).

### Ask a connected agent

If you've connected Claude Code to the MCP server (above), it can answer "what can
I configure?" / "is feature X on?" for you, using the read-only **knowledge** tools:

- **`get_effective_config`** — your current config values + which differ from the
  defaults (secrets are redacted to `<set>`).
- **`docs_for_feature`** — a feature's summary, the keys that control it, the steps
  to enable it, whether it's currently ON, and any unmet requirements (computed live).
- **`describe_config_key`** — one key's documentation + its current value.
- **`list_config_keys`** — every config key with a one-line summary (filter by name,
  or fork-only keys).

See **MCP-SERVER.md** for the full tool list.

### The feature docs

Each opt-in feature has its own user guide at the repo root (also useful as a deep
reference even after the cheat sheet above):

- **`SHARING.md`** — install / update / uninstall, secrets in `local`.
- **`MCP-SERVER.md`** — agent control: tools, transport, connecting an agent.
- **`WEB-MONITOR.md`** — watch/drive splits from a phone over Tailscale.
- **`AGENT-DASHBOARD.md`** — the live-tile panel + the Claude Code agent-state hooks.
- **`AGENT-QUEUE.md`** / **`AGENT-MANAGER.md`** — the queue supervisor + tile summaries.
- **`BELL-ATTENTION.md`** — bell vs. "needs you" two-tier alerting.

## Troubleshooting

**All my terminals are blank / empty.** The fork runs a small background "host" process
(a launchd agent) that owns the terminal sessions; if it didn't start, every pane shows
up empty. Fix: quit and relaunch the app (the first launch installs the host; the second
launch connects to it). If it persists, check the host log at
`~/Library/Logs/ghostty-ramon-host.log` for errors. (Note: restarting the host ends any
live sessions — they live in memory only.)

**Agent Dashboard / Queue features do nothing.** Those need `node` on your `PATH` and the
Claude Code agent-state hooks installed. Check `command -v node` in a shell; if it's
missing, install Node. The hooks ship inside the app at
`Contents/Resources/claude-hooks/` — see `AGENT-DASHBOARD.md` for the one-time install.

**The Agent Dashboard panel is empty.** That's expected until a CLI agent (`claude` /
`codex`) is actually running in one of your splits — start one and it appears.

**Updating / uninstalling.** Updates arrive automatically (Sparkle, from the fork's own
release feed). To uninstall, drag the app to the Trash; optionally remove
`~/.config/ghostty-ramon/` and `~/Library/LaunchAgents/com.mitchellh.ghostty-ramon.host.plist`.

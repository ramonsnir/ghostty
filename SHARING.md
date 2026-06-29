# Sharing the fork ("Ghostty (ramon)") with colleagues

This is the **install/update/release** guide for the **distribution build** of the
fork. It runs **side-by-side** with an official Ghostty (different bundle id, name,
and config domain), so installing it won't disturb a colleague's existing Ghostty.

> **If you just received a Ghostty (ramon) DMG — start with `ONBOARDING.md`.** It is
> the colleague-facing walkthrough: the keybind cheat sheet, what works out of the
> box vs. what needs a one-time setup, and how to discover the fork's features
> (without scrolling the command palette — you won't). This file (SHARING.md) is the
> install/update reference; `ONBOARDING.md` is what to read first. After install, the
> bundled copy lives at `…/Ghostty (ramon).app/Contents/Resources/ONBOARDING.md`, and
> the first-run notification + your seeded config both point you there too.

For the build/release internals (CI, signing, Sparkle wiring) see the
"Distribution / sharing the fork" section of `CLAUDE.md`.

## What works out of the box vs. what needs setup

After installing the DMG and relaunching once, this is the lay of the land:

| Feature | Status after install |
|---|---|
| Fork features (splits/tabs/move/find, Agent Dashboard, …) | **Works OOTB** via the Command Palette |
| Hosted backend (session survival, live previews) | **Works OOTB** after one relaunch |
| Agent Dashboard (live CLI-agent tiles) | **Works OOTB** (on by default) |
| `ghostty-ramon` discovery CLI | **Works OOTB** — installed to `~/.local/bin` |
| MCP server (let an agent drive splits) | **Works OOTB** — bind + token auto-written to `local` on first launch |
| Fork keybinds (a tmux-style `ctrl+a` layer) | **Opt-in** — shipped COMMENTED in the seed; uncomment to adopt |
| Project selector | Needs `project-directory` set (1 line in config) |
| Web monitor (drive splits from a phone) | Needs `web-monitor-listen` (+ Tailscale) in `local` |
| Agent **Queue** (one agent per work item) | Needs `node` on PATH + agent-state hooks + a template |
| Agent **Manager** Haiku tile summaries + rate-limit watchdog | **Works** with `node` + `claude` on PATH (billed to your Claude subscription) |

"OOTB" = nothing to configure; the rest are deliberate opt-ins (see the `local` and
node sections below). `ONBOARDING.md` walks through each.

## What a colleague needs

- **macOS 13 or later** (Apple Silicon or Intel — the build is universal).
- **Nothing else.** The DMG is self-contained: the GUI app, the `ghostty-host`
  daemon, the terminfo/resources, and the auto-updater are all bundled.
- **Optional — Tailscale**, only if they want the phone web-monitor feature.

## Install

1. Download `Ghostty.dmg` from the fork's
   [GitHub Releases](https://github.com/ramonsnir/ghostty/releases/latest).
2. Open the DMG and drag **Ghostty (ramon)** to `/Applications`.
3. Launch it. Because the release is Developer-ID signed + notarized, it opens
   with no Gatekeeper warning. (If you ever sideload an *unsigned* build instead,
   you'd need `xattr -dr com.apple.quarantine "/Applications/Ghostty (ramon).app"`
   — the notarized DMG avoids that.)

### What happens on first launch

The app does a one-time, idempotent setup:

- **Seeds `~/.config/ghostty-ramon/config`** (only if you don't already have one)
  with the fork's feature settings + sensible defaults. The personal tmux-style
  `ctrl+a` keybind layer is shipped **COMMENTED OUT** — nothing is bound for you;
  every fork action is in the Command Palette, and you can uncomment the block (or
  bind your own keys) if you want it. Safe to edit afterward — it's never overwritten.
- **Auto-provisions `~/.config/ghostty-ramon/local`** with a localhost MCP bind
  (`mcp-listen = 127.0.0.1:8765`) + a freshly-generated random `mcp-token`, so the
  MCP server (and the agent-control features built on it) works out of the box with
  no hand-written token. It never rotates or clobbers a token you already set there.
- **Installs a launchd LaunchAgent** (`com.mitchellh.ghostty-ramon.host`) that
  supervises the bundled `ghostty-host` daemon. This is what powers session
  survival across app restarts, live agent-dashboard previews, and the
  color/scrollback web monitor. (Run synchronously+early on launch so the daemon is
  up before terminals connect — no blank-pane race.)
- **Opens the Agent Dashboard panel** (a sidebar of live previews of any
  Claude/Codex splits) — it's enabled by default. On the very first launch it may
  appear empty until you relaunch (previews need the hosted backend, below). Toggle
  it any time from the Command Palette → "Toggle Agent Dashboard", or set
  `agent-dashboard = false` in `~/.config/ghostty-ramon/config` to keep it off.

> **Relaunch once after the first run.** The hosted (`pty-host`) backend is enabled
> by the seeded config, which is only read at the *next* launch. So the very first
> launch uses the simpler in-process backend (everything works, just no
> session-survival/live-preview); quit and reopen once to get the full feature set.
> From then on the host is brought up before terminals connect, so the hosted backend
> is reliable on every launch (no more occasional blank panes on a cold start).

## Updates (no git, no rebuild)

Updates are **automatic** via Sparkle, pointed at the fork's own GitHub Releases
(never the official Ghostty feed). You'll be prompted when a new build is
available; you can also trigger a check from **Ghostty (ramon) → Check for
Updates…**. Updating replaces the app in place and reloads the host daemon.

> Updating the app **restarts the host daemon**, which ends any live hosted
> sessions (they live only in the daemon's RAM). Open fresh tabs afterward.

## Optional: secrets / per-machine settings (`local`)

Per-machine values and secrets live in an **untracked** file the seeded config
already includes:

```
~/.config/ghostty-ramon/local
```

**The MCP server's bind + token are written here for you on first launch** —
localhost-only with a random token — so the MCP feature works with no setup. To
**rotate** the token, just edit the `mcp-token` line in that file.

Add the web-monitor lines by hand if you want that feature:

```ini
# Web monitor (watch/drive splits from your phone over Tailscale).
# Bind LOOPBACK and reach it over HTTPS via `tailscale serve` — the ONLY
# supported setup (the server speaks plain HTTP to loopback only, which a phone
# can't reach directly). Do NOT bind a Tailscale IP/0.0.0.0 (plain HTTP, breaks
# Web Push). After setting these + relaunching, run:
#   tailscale serve --bg --https=8787 127.0.0.1:18787
# then open https://<machine>.<tailnet>.ts.net:8787/  — see WEB-MONITOR.md.
web-monitor-listen = 127.0.0.1:18787
web-monitor-token  = <openssl rand -hex 24>

# MCP server — auto-provisioned on first launch (shown for reference). The token
# is a shell-execution credential (it can spawn tabs and run commands).
mcp-listen = 127.0.0.1:8765
mcp-token  = <random, generated for this machine>
```

### Connecting an agent to the MCP server

**This is automatic.** On first launch the app installs the `ghostty-mcp` stdio shim to
`~/.local/bin/ghostty-mcp` (refreshed on each update) AND — if `claude` is on your PATH —
registers it with Claude Code for you (`claude mcp add ghostty --scope user`), so a fresh
`claude` session in any directory just shows the `ghostty` MCP. `mcp-listen` + `mcp-token`
are auto-provisioned in `local` (above), and the registration carries no secret (the shim
reads the token from `local`).

If you installed `claude` *after* Ghostty, relaunch Ghostty once and it registers on the
next launch — or do it by hand:

```sh
claude mcp add ghostty --scope user -- "$HOME/.local/bin/ghostty-mcp"
```

Restart Claude Code afterward. (If `~/.local/bin` is on your `PATH`, `claude mcp add
ghostty --scope user -- ghostty-mcp` works too.) See **MCP-SERVER.md** for the tool list.

### Optional: Agent Dashboard / Queue (needs `node`)

The Agent Dashboard (live tiles of your CLI-agent splits) and the Agent **Queue** (a
supervisor that launches one agent per work item) are bundled in the app. To turn them on:
set `agent-dashboard = true` (and, for the queue, `agent-queue = true` + `agent-manager =
true`) in `~/.config/ghostty-ramon/config` — MCP is already configured in `local` for you —
and **have `node` on your `PATH`** — the queue/manager sidecar runs under node, and silently
stays off (one log line, no error) if node is missing. The queue also wants the Claude Code
agent-state hooks installed (see **AGENT-DASHBOARD.md**) so it can auto-close finished agents,
and a queue **template** describing your tracker (see **AGENT-QUEUE.md**). The one-line Haiku
tile *summaries* + the rate-limit attention watchdog (the "Agent Manager") **now work for
colleagues too** — they use your already-installed `claude` CLI (so also have `claude` on your
`PATH`), billed to your own Claude subscription; if `claude` isn't found the summaries stay off
while the queue keeps running.

## Day-2 discovery (find the fork's features)

The fork adds a lot of keybinds and config keys. **Don't go hunting in the command
palette** — use the concrete entrypoints instead:

- **`ONBOARDING.md`** — the curated cheat sheet (also bundled at
  `…/Ghostty (ramon).app/Contents/Resources/ONBOARDING.md`).
- **`ghostty-ramon` CLI** (installed to `~/.local/bin/ghostty-ramon` on first launch):
  ```sh
  ghostty-ramon +list-keybinds   # every active keybind (your seeded + custom bindings)
  ghostty-ramon +show-config     # your effective configuration
  ```
  It's a symlink to the app's multitool, named `ghostty-ramon` so it never collides
  with an official `ghostty` CLI. (If `~/.local/bin` isn't on your `PATH`, add it.)
- **The MCP "knowledge" tools** — if you've connected an agent (above), it can answer
  "what can I configure?" / "is feature X on?" for you without any of the above:
  - `get_effective_config` — your current config values + which differ from defaults
    (secrets are redacted to `<set>`).
  - `docs_for_feature` — a feature's summary, the keys that control it, the steps to
    enable it, whether it's currently ON, and any unmet requirements (computed live).
  - `describe_config_key` — one key's documentation + current value.
  - `list_config_keys` — every config key with a one-line summary (filter by
    name, or `forkOnly:true` for just the fork's keys).

  See **MCP-SERVER.md** for the full tool list.

## Uninstall

```sh
# Stop + remove the host daemon's LaunchAgent
launchctl bootout gui/$(id -u)/com.mitchellh.ghostty-ramon.host 2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.mitchellh.ghostty-ramon.host.plist
rm -f ~/.ghostty-ramon-host.sock

# Remove the app + (optionally) config
rm -rf "/Applications/Ghostty (ramon).app"
# rm -rf ~/.config/ghostty-ramon    # only if you want to drop your fork config too
```

## Troubleshooting

- **Empty/blank terminals after an update or first hosted launch.** The host
  daemon didn't come up. Check its log:
  `tail -50 ~/Library/Logs/ghostty-ramon-host.log` and its launchd state:
  `launchctl print gui/$(id -u)/com.mitchellh.ghostty-ramon.host | grep -iE 'pid =|last exit|runs ='`.
  As a reset, quit the app and reload the agent:
  `launchctl bootout gui/$(id -u)/com.mitchellh.ghostty-ramon.host && launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.mitchellh.ghostty-ramon.host.plist`.
- **Want to opt out of the hosted backend entirely.** Comment out the
  `pty-host = …` line in `~/.config/ghostty-ramon/config` and relaunch; the app
  falls back to the in-process backend (no session survival / live previews).

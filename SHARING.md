# Sharing the fork ("Ghostty (ramon)") with colleagues

This is the user-facing install/update guide for the **distribution build** of the
fork. It runs **side-by-side** with an official Ghostty (different bundle id, name,
and config domain), so installing it won't disturb a colleague's existing Ghostty.

For the build/release internals (CI, signing, Sparkle wiring) see the
"Distribution / sharing the fork" section of `CLAUDE.md`.

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
  with the fork's keybinds + sensible defaults. Safe to edit afterward — it's
  never overwritten.
- **Installs a launchd LaunchAgent** (`com.mitchellh.ghostty-ramon.host`) that
  supervises the bundled `ghostty-host` daemon. This is what powers session
  survival across app restarts, live agent-dashboard previews, and the
  color/scrollback web monitor.
- **Opens the Agent Dashboard panel** (a sidebar of live previews of any
  Claude/Codex splits) — it's enabled by default. On the very first launch it may
  appear empty until you relaunch (previews need the hosted backend, below).
  Toggle it any time with `ctrl+a>d`, or set `agent-dashboard = false` in
  `~/.config/ghostty-ramon/config` to keep it off.

> **Relaunch once after the first run.** The hosted (`pty-host`) backend is enabled
> by the seeded config, which only takes effect on the *next* launch. So the very
> first launch uses the simpler in-process backend (everything works, just no
> session-survival/live-preview); quit and reopen once to get the full feature set.

## Updates (no git, no rebuild)

Updates are **automatic** via Sparkle, pointed at the fork's own GitHub Releases
(never the official Ghostty feed). You'll be prompted when a new build is
available; you can also trigger a check from **Ghostty (ramon) → Check for
Updates…**. Updating replaces the app in place and reloads the host daemon.

> Updating the app **restarts the host daemon**, which ends any live hosted
> sessions (they live only in the daemon's RAM). Open fresh tabs afterward.

## Optional: secrets / per-machine settings (`local`)

Some features need a per-machine value or a secret. Those live in an **untracked**
file the seeded config already includes:

```
~/.config/ghostty-ramon/local
```

Create it by hand if you want either of these:

```ini
# Web monitor (watch/drive splits from your phone over Tailscale).
# Bind to this Mac's Tailscale IP. The token is a shell-execution credential.
web-monitor-listen = 100.x.y.z:8787
web-monitor-token  = <openssl rand -hex 24>

# MCP server (let a local Claude Code / Codex drive splits/tabs). Localhost-only,
# and ALWAYS set a token — it can spawn tabs and run commands.
mcp-listen = 127.0.0.1:8765
mcp-token  = <openssl rand -hex 24>
```

If `local` is absent the app still launches fine; those two features just stay off.

### Connecting an agent to the MCP server

The app installs the `ghostty-mcp` stdio shim to `~/.local/bin/ghostty-mcp` on first
launch (and refreshes it on each update). Once `mcp-listen` + `mcp-token` are set in
`local`, point your local Claude Code at it:

```sh
claude mcp add ghostty -- "$HOME/.local/bin/ghostty-mcp"
```

No token in that command — the shim reads `mcp-token` from `~/.config/ghostty-ramon/local`.
Restart Claude Code afterward. (If `~/.local/bin` is on your `PATH`, `claude mcp add
ghostty -- ghostty-mcp` works too.) See **MCP-SERVER.md** for the tool list.

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

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
| Fork keybinds (`ctrl+a` splits/tabs/resize/move) | **Works OOTB** — seeded config |
| Hosted backend (session survival, live previews) | **Works OOTB** after one relaunch |
| Agent Dashboard (live CLI-agent tiles) | **Works OOTB** (on by default; `ctrl+a>d`) |
| `ghostty-ramon` discovery CLI | **Works OOTB** — installed to `~/.local/bin` |
| Project selector (`ctrl+a>f`) | Needs `project-directory` set (1 line in config) |
| MCP server (let an agent drive splits) | Needs `mcp-listen` + `mcp-token` in `local` |
| Web monitor (drive splits from a phone) | Needs `web-monitor-listen` (+ Tailscale) in `local` |
| Agent **Queue** (one agent per work item) | Needs `node` on PATH + agent-state hooks + a template |
| Agent **Manager** Haiku tile summaries | **Dev-only** — needs npm packages not in the DMG |

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

### Optional: Agent Dashboard / Queue (needs `node`)

The Agent Dashboard (live tiles of your CLI-agent splits) and the Agent **Queue** (a
supervisor that launches one agent per work item) are bundled in the app. To turn them on:
set `agent-dashboard = true` (and, for the queue, `agent-queue = true` + `agent-manager =
true`) in `~/.config/ghostty-ramon/config`, set `mcp-listen`/`mcp-token` in `local` (above),
and **have `node` on your `PATH`** — the queue/manager sidecar runs under node, and silently
stays off (one log line, no error) if node is missing. The queue also wants the Claude Code
agent-state hooks installed (see **AGENT-DASHBOARD.md**) so it can auto-close finished agents,
and a queue **template** describing your tracker (see **AGENT-QUEUE.md**). Note: the one-line
Haiku tile *summaries* (the "Agent Manager") need extra node packages that are NOT shipped in
the DMG, so they stay off for colleagues — the **queue itself works without them**.

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

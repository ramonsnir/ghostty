# Web monitor — watch & drive Ghostty splits from your phone

Fork-only feature of **"Ghostty (ramon)"** (bundle id `com.mitchellh.ghostty-ramon`).
A single GUI-embedded HTTP server *inside the running app* serves both a mobile web
page **and** a small JSON API on one port. From a phone (e.g. over **Tailscale**) you can:
list the live terminal surfaces, watch one update, and **send input — notably approving
CLI-agent (Claude Code) prompts** — without being at the Mac.

**OFF by default.** No second process; one app, one rebuild/restart.

---

## Quick start — the config to add (later is fine)

Put these in `~/.config/ghostty-ramon/config` (fork-only file; the official Ghostty
never sees it, so it won't error on the unknown keys). Then **relaunch** the app —
config is read at launch.

```ini
# Web monitor (fork-only). Empty/unset listen => disabled.
web-monitor-listen = 100.x.y.z:8787      # your Tailscale IP : port  (the BIND address)
web-monitor-token  = <16+ char secret>   # required; refuses to start if empty/too short
```

- **`web-monitor-listen`** — `addr:port` to bind. Use **your Tailscale IP** so it's
  reachable only on your tailnet (and so the built-in Host-header check matches). This is
  purely a *bind address*, **not** an IP allowlist.
- **`web-monitor-token`** — shared secret, **≥ 16 chars**. Generate one with
  `openssl rand -hex 24`. Treat it as a **shell credential** (a holder can type into your
  shells); rotate it (and relaunch) if a device is lost. The server **refuses to start**
  with an empty/short token.

---

## Using it from the phone

1. On your tailnet, open: `http://100.x.y.z:8787/?token=<secret>`
   (the token is stashed in `sessionStorage`, scrubbed from the visible URL, and sent via
   the `X-Ghostty-Token` header on subsequent requests). Bookmark the tokened URL.
2. You get a **list of live surfaces** (title + cwd). Tap one to open it.
3. The screen **polls every ~700 ms** (plain text, no ANSI color). Controls: viewport ⇄
   scrollback toggle, wrap toggle, font-size, jump-to-bottom.
4. **Send input:** a text field (Enter sends with a newline; a Raw button sends without),
   plus one-tap quick-keys — **Enter · y · n · Esc · Tab · Ctrl-C**, the **digits 1 2 3 4**
   (for numbered agent permission menus), and **arrows**. Taps flash locally so you know
   they registered even on a laggy link.
5. If the watched surface closes (404) or the connection drops, you get a visible
   **"Session closed." / "connection lost"** banner — it will **not** silently keep showing
   a stale screen (important before you approve a prompt).

---

## Security model (read once)

- **No TLS** — the tailnet (WireGuard) already encrypts transport. **Do not** expose the
  port outside your tailnet.
- **The token is the authentication boundary and is load-bearing** (≈ shell exec). It gates
  *every* request; `?token=` is accepted only on the initial `GET /`, and every `/api/*`
  route requires the `X-Ghostty-Token` header. Comparison is length-checked + constant-time.
- **Defense in depth** (backs up the token + tailnet, doesn't replace them): a Host-header
  allowlist (DNS-rebinding guard — a Host-less request is still token-gated), a per-peer
  failed-token backoff (5 strikes → 429, decays after ~60 s), and per-connection bounds (a
  ~10 s idle watchdog + a ~15 s absolute deadline + a 32-concurrent-connection cap).
- The web page renders all terminal/output text via `textContent` (never `innerHTML`), so
  terminal output can't inject HTML/JS.

---

## Known limits (v1)

- **Plain text only** (no color). Full-fidelity/scrollback rendering would need a raw-byte +
  xterm.js path — intentionally out of scope for v1.
- **Polling, no push** — a waiting prompt becomes visible within ~1 s, not instantly.
- **No live config reload** — changing `web-monitor-listen` / `web-monitor-token` needs a
  relaunch.

---

## Status

Implemented and **independently reviewed across code / design / UX / test-coverage to
A+ / 98** (zero blocker/major). Covered by a Swift unit suite
(`GhosttyTests/WebMonitorServerTests`, ~200 cases) + a Zig config-parse test; the macOS app
builds clean. Committed on `ramon-fork`.

## Where the code lives (for later hacking)

| Piece | File |
|---|---|
| Server + embedded HTML/JS page | `macos/Sources/Features/WebMonitor/WebMonitorServer.swift` |
| Unit tests | `macos/Tests/WebMonitor/WebMonitorServerTests.swift` |
| Config keys (`web-monitor-listen` / `-token`) | `src/config/Config.zig` |
| macOS config getters | `macos/Sources/Ghostty/Ghostty.Config.swift` (`webMonitorListen` / `webMonitorToken`) |
| Start on launch / stop on quit | `macos/Sources/App/macOS/AppDelegate.swift` |
| Full architecture / security / wiring notes | **`CLAUDE.md`** ("Web monitor" entry) |

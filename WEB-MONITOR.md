# Web monitor — watch & drive Ghostty splits from your phone

Fork-only feature of **"Ghostty (ramon)"** (bundle id `com.mitchellh.ghostty-ramon`).
A single GUI-embedded HTTP server *inside the running app* serves a mobile web page,
a small JSON API, **and a live raw-byte stream** on one port. From a phone (e.g. over
**Tailscale**) you can: list the live terminal surfaces, **watch one in color with
scrollback and live updates**, **send input** (notably approving CLI-agent prompts),
and **scroll / drive** a remote TUI.

**OFF by default.** One app, one rebuild/restart — no second process.

> **You reach it over HTTPS via `tailscale serve` — that's the only supported setup.**
> The server itself only speaks plain HTTP to **loopback** (`127.0.0.1`), which a phone
> can't reach directly; `tailscale serve` terminates TLS and proxies to it. This is
> **required to connect at all**, not just for push notifications. Binding the monitor
> directly to a Tailscale IP over plain HTTP technically works but is **unsupported and
> untested** — it breaks push, isn't maintained, and will rot. Don't rely on it.

---

## Quick start — the config

Put this in `~/.config/ghostty-ramon/config` (fork-only file; the official Ghostty never
sees it, so it won't error on the unknown keys). **Relaunch** the app afterward — config is
read at launch. Then do the **Setup** below (the `tailscale serve` front end) — the config
alone isn't reachable from the phone.

```ini
# Web monitor (fork-only). Empty/unset listen => disabled.
# Bind loopback; `tailscale serve` fronts it with HTTPS (REQUIRED — see "Setup" below).
web-monitor-listen = 127.0.0.1:18787
# web-monitor-token = <16+ char secret>   # OPTIONAL — omit to run OPEN on the tailnet
```

- **`web-monitor-listen`** — `addr:port` to bind. Use the loopback **`127.0.0.1:18787`** and put
  **`tailscale serve` in front for HTTPS** (see **Setup** for the one-line command) — this is the
  one supported way to reach the monitor. A loopback bind isn't reachable from the phone on its
  own, so `tailscale serve` is **required**, not merely a push add-on. It also keeps the line
  **machine-independent** — identical on every laptop (only the `ts.net` hostname differs). It's
  purely a *bind address*, **not** an IP allowlist. Empty/unset ⇒ the monitor is disabled.
- **`web-monitor-token`** — *optional.* **Empty/unset ⇒ the server runs OPEN** (access control
  is your Tailscale ACL alone); it logs a one-line warning so that's a deliberate choice. If
  you *do* set a token (≥16 chars; `openssl rand -hex 24`), it's enforced on every request and
  is a **shell-execution credential** — rotate it if a device is lost.

> **Color/scrollback needs `pty-host`.** The live xterm.js view is fed by the host's raw PTY
> output (see Architecture), so it requires the fork's `pty-host` backend to be active. Without
> `pty-host` (plain `.exec`), the page falls back to a plain-text snapshot poll.

---

## Setup — HTTPS via `tailscale serve` (required)

The monitor speaks plain HTTP to **loopback only**, so you reach it through `tailscale serve`,
which terminates TLS with the auto-provisioned `*.ts.net` certificate and proxies to the loopback
bind. This is **required to connect at all** from the phone (and is also what makes background
push possible — see **Notify on bell**). The setup is the same on every machine — the config line
is loopback, hence identical; only your `ts.net` hostname differs:

1. In the **Tailscale admin** → DNS, enable **MagicDNS** and **HTTPS Certificates** (once per
   tailnet).
2. Set the monitor's **internal (loopback)** listen line (`~/.config/ghostty-ramon/config`, or
   your machine-local `~/.config/ghostty-ramon/local`). Use a port **distinct from the external
   HTTPS port** (see the box below for why) — the convention is the `1`-prefixed twin, `18787`:
   ```ini
   web-monitor-listen = 127.0.0.1:18787
   ```
   (`tailscale serve` only proxies to `127.0.0.1`. It forwards the **original** tailnet
   `Host: <machine>.<tailnet>.ts.net` header — it does **not** rewrite `Host` to the loopback
   backend — and the monitor's Host-header allowlist accepts any `*.ts.net` host, so no extra
   config is needed.)
   > **Why internal ≠ external.** The monitor binds the **port on all interfaces** (`*:18787`);
   > it uses only the port from this line, not the host. If you served HTTPS on that *same* port,
   > `tailscale serve --https=18787` would grab the tailnet IP's `:18787` first and the monitor's
   > wildcard bind would then fail with `EADDRINUSE` — the monitor never starts and the proxy
   > 502s. So keep the external HTTPS port and the internal bind port different.
   >
   > **Per-identity offset (code, `WebMonitorServer.portOffset`).** All three fork builds share
   > this config line, so the loopback port is shifted per identity so they coexist —
   > Release `+0` (18787), ReleaseLocal `+1` (18788), Debug `+2` (18789). Mirrors `MCPServer`.
3. Start the proxy — serve each external HTTPS port to its identity's loopback port (persists
   across reboots). For the installed **Release** build, keep the friendly external port `8787`:
   ```sh
   tailscale serve --bg --https=8787 127.0.0.1:18787      # Release
   ```
   Your monitor is now at **`https://<machine>.<tailnet>.ts.net:8787/`**. To also reach the dev
   builds from the phone, add their pairs (each external maps to the offset loopback port):
   ```sh
   tailscale serve --bg --https=8788 127.0.0.1:18788      # ReleaseLocal (+1)
   tailscale serve --bg --https=8789 127.0.0.1:18789      # Debug (+2)
   ```
   `tailscale serve status` lists all rules; clear a stale one with
   `tailscale serve --https=<port> off`.

> **Second laptop / fresh machine:** identical steps. Copy the same
> `web-monitor-listen = 127.0.0.1:18787` line, run the same `tailscale serve --bg --https=8787
> 127.0.0.1:18787` (Release), and open *that* machine's `https://<machine>.<tailnet>.ts.net:8787/`.

---

## Using it from the phone

1. On your tailnet, open **`https://<machine>.<tailnet>.ts.net:8787/`** (the `tailscale serve`
   endpoint from **Setup** above). No token needed when running open; if a token is set, open
   `…/?token=<secret>` once — it's then stashed in `sessionStorage` and sent via the
   `X-Ghostty-Token` header.
2. You get a **list of live surfaces** (title + cwd). Tap one to open it.
3. The screen renders in **`xterm.js`** — **full ANSI color, native scrollback, live updates**
   (fed by the host raw-byte stream; the terminal is sized to the host's grid so TUIs line up),
   in the **same JetBrains Mono Nerd Font Ghostty uses** (vendored as woff2 and served by the
   app, so it renders correctly on a phone that doesn't have the font installed).
   It scrolls horizontally if the host grid is wider than the phone; use the **font-size**
   control to fit. If the stream is unavailable it falls back to a plain-text snapshot poll.
4. **Input:**
   - **Text field + Send** — *types* the text into the terminal; it does **not** submit.
   - **Enter** quick-key — submits (a real Enter keypress).
   - Quick-keys: **Enter · y · n · Esc · Tab · ⌫ Backspace · Clear (Ctrl-U) · Ctrl-C**, the
     **digits 1–4** (numbered agent menus), and **arrows**.
   - **Scroll ↑ / Scroll ↓** — remote-control scroll (a real mouse wheel to the host), so a TUI
     (Claude Code / `less` / `vim`) scrolls and the result streams back.
   - **Press-and-hold to auto-repeat** on **scroll, arrows, and backspace** (a tap still fires
     once); Enter/Ctrl-C/etc. are single-fire on purpose.
   - All input is sent as **real key/wheel events** (`ghostty_surface_key` / `_mouse_scroll`),
     not pasted — so Enter actually submits and control keys actually fire.
5. Closed surface (404) or a dropped link shows a visible **"Session closed." / "connection
   lost"** banner — it won't silently leave a stale screen.

---

## Notify on bell (background push notifications)

Get a **push notification on your phone when any split rings a bell** — even with the
browser tab closed and the phone locked. Use it to step away from the laptop and still get
pinged when a long command finishes or a CLI agent wants approval. The header has a **🔔
Notify** toggle: **arm it when you walk away, mute it when you're back** (it's a single
server-side switch, so muting from any device mutes all bells).

This is real **Web Push** (VAPID + service worker), done in-process with **zero new
dependencies** — we self-generate a VAPID keypair (CryptoKit), so **no Firebase/Google
project is involved**.

Push reuses the **HTTPS you already set up** (see **Setup**) — browsers only register a service
worker on a **secure context**, which is exactly what `tailscale serve` provides. No extra
proxy/config; just enable it on each device:

1. On Android Chrome, open the **https** URL from **Setup** (append `?token=…` once if a token is
   set), tap **🔔 Notify**, and **grant** the notification permission. Done — bells now push to
   that device.
2. Each device you want pinged subscribes itself by tapping **🔔 Notify** on the page
   (subscriptions are per-browser and stored server-side per machine).

If the page is somehow opened over plain HTTP (i.e. not through `tailscale serve`), the toggle
shows **"🔔 n/a"** and explains it needs HTTPS, rather than failing silently.

### Notes

- The toggle is a **global arm/mute flag**; the VAPID keypair, the device subscriptions, and the
  flag persist (UserDefaults), so they survive a relaunch. Default is **muted**.
- Bells are **debounced ~3s per surface** so a chatty bell doesn't spam.
- An expired subscription (push endpoint returns 404/410) is dropped automatically.
- This is **GUI-only** — no host change, so enabling/changing it is a relaunch, never a
  `ghostty-host` restart.

---

## Security model (read once)

- **No TLS in the server itself** — it speaks plain HTTP to loopback; `tailscale serve`
  terminates HTTPS at the node's edge and the tailnet (WireGuard) encrypts the hop to your
  phone. **Do not** expose the port beyond your tailnet (never `tailscale funnel` it).
- **Auth is the optional token.** Open (no token) ⇒ the **tailnet/Tailscale ACL is the entire
  boundary** — appropriate on a private tailnet. With a token set, it gates every route
  (constant-time compare; `?token=` only on the bootstrap GET `/` + asset routes, header for
  `/api/*`).
- **Defense in depth** (independent of the token): a Host-header allowlist (DNS-rebinding
  guard), a per-peer failed-token backoff (only when a token is set), and per-connection bounds
  (idle watchdog + absolute deadline + a 32-connection cap). The raw stream is exempt from the
  watchdogs (it's long-lived).
- The page renders untrusted list/snapshot text via `textContent` (never `innerHTML`); the
  live view is `xterm.js`, which parses the byte stream itself.

---

## Architecture (how color/history works under `pty-host`)

Under the fork's `pty-host` backend, terminal emulation runs in the long-lived `ghostty-host`
daemon and the GUI is a thin `.client` whose screen mirror is **viewport-only** — so color and
real scrollback can't come from the GUI. Instead:

- The **host tees raw PTY output**: a per-session bounded ring buffer (recent history for
  replay-on-connect) + a broadcast of new bytes, exposed via two additive, version-negotiated
  protocol frames — `subscribe_raw` (client→host) and `raw_output` (host→client).
- A Swift **host-protocol client** (`WebMonitorHostClient`, POSIX `AF_UNIX`) connects to the
  `pty-host` socket, does the `Hello` handshake, `subscribe_raw`s a session, and decodes the
  `raw_output` stream.
- The server's **`GET /api/surface/{uuid}/stream`** pipes those raw bytes to the browser as a
  long-lived `application/octet-stream`, with the host grid size in `X-Ghostty-Cols/-Rows`
  headers; the page feeds it to `xterm.js` (sized to that grid).
- Input/scroll go back the other way as real key/wheel events on the GUI surface, forwarded by
  the `.client` backend to the host.

---

## HTTP API

| Route | Purpose |
|---|---|
| `GET /` | the embedded mobile page (`?token=` accepted here when a token is set) |
| `GET /xterm.js`, `GET /xterm.css` | the vendored xterm.js assets (`?token=` accepted) |
| `GET /jetbrains-mono-{regular,bold}.woff2` | vendored JetBrains Mono Nerd Font (`?token=` accepted) |
| `GET /api/surfaces` | JSON `[{id,title,pwd}]` of live surfaces |
| `GET /api/surface/{uuid}/stream` | live raw-byte stream (xterm.js source; needs `pty-host`) |
| `GET /api/surface/{uuid}/screen?mode=viewport\|scrollback` | plain-text snapshot (fallback) |
| `POST /api/surface/{uuid}/input` | real key events (raw text, or `{"key":…}`) |
| `POST /api/surface/{uuid}/scroll` | `{"dy":±ticks}` → real mouse wheel to the host |
| `GET /sw.js` | the Web Push service worker (bootstrap; `?token=` accepted) |
| `GET /api/push/config` | JSON `{vapidPublicKey, enabled, subscriptions}` |
| `POST /api/push/subscribe` | register a browser `PushSubscription` |
| `POST /api/push/unsubscribe` | `{endpoint}` → drop a subscription |
| `POST /api/push/enabled` | `{enabled:bool}` → arm/mute the Notify toggle |

---

## Known limits

- **Color/scrollback require `pty-host`**; otherwise the plain-text snapshot fallback is used
  (no color). The raw stream is per-session bytes from the host, sized to the host grid.
- **No live config reload** — changing `web-monitor-listen` / `web-monitor-token` needs a
  relaunch.
- Scrollback replay on connect is bounded by the host ring buffer; xterm.js then keeps its own
  scrollback for everything streamed since connecting (and Scroll ↑/↓ drives the host for
  deeper/alt-screen history).

---

## Status

Implemented and reviewed across code / design / UX / test-coverage. Covered by a Swift unit
suite (`GhosttyTests/WebMonitorServerTests`, 250+ cases) + host integration/protocol tests
(`zig build test -Dtest-filter=host`) + a Zig config-parse test; the macOS app builds clean.
Committed on `ramon-fork` (not pushed).

## Where the code lives

| Piece | File |
|---|---|
| Server + embedded `xterm.js` page (routing, `/stream`, `/scroll`, assets, Notify toggle) | `macos/Sources/Features/WebMonitor/WebMonitorServer.swift` |
| Web Push crypto (VAPID/RFC 8292 + RFC 8291 `aes128gcm`) + subscription store / bell→push | `macos/Sources/Features/WebMonitor/WebMonitorPush.swift` |
| Host-protocol client (subscribe to `raw_output`) | `macos/Sources/Features/WebMonitor/WebMonitorHostClient.swift` |
| Vendored xterm.js | `macos/Sources/Features/WebMonitor/vendor/xterm.{js,css}` |
| Vendored JetBrains Mono Nerd Font (woff2) | `macos/Sources/Features/WebMonitor/vendor/JetBrainsMonoNerdFont-{Regular,Bold}.woff2` |
| Unit tests | `macos/Tests/WebMonitor/WebMonitorServerTests.swift` |
| Host raw-output tee + frames + ring buffer | `src/host/{Session,Server,protocol}.zig`, `src/termio/Termio.zig` (output observer) |
| Config keys + `pty-host` (`[:0]`-terminated so it's C-gettable) | `src/config/Config.zig` |
| macOS config getters | `macos/Sources/Ghostty/Ghostty.Config.swift` (`webMonitorListen` / `webMonitorToken` / `ptyHost`) |
| Start on launch / stop on quit | `macos/Sources/App/macOS/AppDelegate.swift` |
| Full architecture / wiring notes | **`CLAUDE.md`** ("Web monitor" entry) |

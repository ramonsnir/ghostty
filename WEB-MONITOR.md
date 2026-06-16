# Web monitor — watch & drive Ghostty splits from your phone

Fork-only feature of **"Ghostty (ramon)"** (bundle id `com.mitchellh.ghostty-ramon`).
A single GUI-embedded HTTP server *inside the running app* serves a mobile web page,
a small JSON API, **and a live raw-byte stream** on one port. From a phone (e.g. over
**Tailscale**) you can: list the live terminal surfaces, **watch one in color with
scrollback and live updates**, **send input** (notably approving CLI-agent prompts),
and **scroll / drive** a remote TUI.

**OFF by default.** One app, one rebuild/restart — no second process.

---

## Quick start — the config

Put this in `~/.config/ghostty-ramon/config` (fork-only file; the official Ghostty never
sees it, so it won't error on the unknown keys). **Relaunch** the app afterward — config is
read at launch.

```ini
# Web monitor (fork-only). Empty/unset listen => disabled.
# Bind loopback; `tailscale serve` puts HTTPS in front (see "Notify on bell" below).
web-monitor-listen = 127.0.0.1:8787
# web-monitor-token = <16+ char secret>   # OPTIONAL — omit to run OPEN on the tailnet
```

- **`web-monitor-listen`** — `addr:port` to bind. Use **`127.0.0.1:8787`**: a loopback bind
  fronted by `tailscale serve` for HTTPS (see **Notify on bell** for the one-line command).
  HTTPS is required for push notifications, and a loopback bind makes the line
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

## Using it from the phone

1. On your tailnet, open **`https://<machine>.<tailnet>.ts.net:8787/`** (set up via
   `tailscale serve`, see **Notify on bell**). No token needed when running open; if a token is
   set, open `…/?token=<secret>` once — it's then stashed in `sessionStorage` and sent via the
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

### Requirement: HTTPS via `tailscale serve`

Browsers only register a service worker (needed for background push) on a **secure context**,
so the plain-HTTP-over-Tailscale-IP setup above **can't** do push. Put **`tailscale serve`** in
front to terminate TLS with the auto-provisioned `*.ts.net` certificate. One-time setup:

This setup is the same on every machine (the config line is loopback, hence identical; only
your `ts.net` hostname differs):

1. In the **Tailscale admin** → DNS, enable **MagicDNS** and **HTTPS Certificates** (once per
   tailnet).
2. Bind the monitor to **loopback** so `tailscale serve` can proxy to it
   (`~/.config/ghostty-ramon/config`):
   ```ini
   web-monitor-listen = 127.0.0.1:8787
   ```
   (`tailscale serve` only proxies to `127.0.0.1`. It rewrites `Host` to the loopback backend,
   so the monitor's existing Host-header allowlist already accepts it — no extra config.)
3. Start the proxy — serve HTTPS on the **same 8787**, proxying to the loopback 8787
   (persists across reboots):
   ```sh
   tailscale serve --bg --https=8787 8787
   ```
   Your monitor is now at **`https://<machine>.<tailnet>.ts.net:8787/`**. Using 8787 for both
   the bind and the HTTPS port is fine — they're on different addresses (loopback vs the tailnet
   IP), so they don't collide. This keeps `443` (and any other port/path) free for serving other
   things from the same machine (`tailscale serve status` lists all rules).
4. On Android Chrome, open that **https** URL (append `?token=…` once if a token is set), tap
   **🔔 Notify**, and **grant** the notification permission. Done — bells now push to that device.

If the page is opened over plain HTTP (no `tailscale serve`), the toggle shows **"🔔 n/a"** and
explains it needs HTTPS, rather than failing silently.

> **Second laptop / fresh machine:** identical steps. Copy the same
> `web-monitor-listen = 127.0.0.1:8787` line, run the same `tailscale serve --bg --https=8787
> 8787`, and open *that* machine's `https://<machine>.<tailnet>.ts.net:8787/`. Each device you
> want pinged subscribes itself by tapping **🔔 Notify** on the page (subscriptions are
> per-browser and stored server-side per machine).

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

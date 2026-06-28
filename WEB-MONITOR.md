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
   - **Agent filters** sit above the list: **Agents only** (keep only splits the
     **Agent Dashboard** detects as a CLI agent) and **Hide hidden** (drop splits you've
     hidden in the dashboard). Both default **ON** (so by default you see only your
     non-hidden agents) and are remembered per device. They mirror the dashboard exactly,
     so they're **disabled** (greyed, with a note) when the Agent Dashboard isn't running.
     Turn both off to see every surface again.
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
   - **Scroll ↑ / Scroll ↓** — *smart* remote-control scroll. The page reads the **live
     terminal mode** off `xterm.js` and picks the right gesture per app: a real **mouse wheel**
     to the host on the normal screen (scrollback) or for an app that captures the mouse (Claude
     Code, `htop`, `vim` with mouse), but **PageUp / PageDown** for a full-screen TUI that owns
     the screen with no scrollback to wheel through (`less`, `man`, plain `vim`). So the one pair
     of buttons "just scrolls" whatever you're looking at.
   - **Press-and-hold to auto-repeat** on **scroll, arrows, and backspace** (a tap still fires
     once); Enter/Ctrl-C/etc. are single-fire on purpose.
   - All input is sent as **real key/wheel events** (`ghostty_surface_key` / `_mouse_scroll`),
     not pasted — so Enter actually submits and control keys actually fire.
5. Closed surface (404) or a dropped link shows a visible **"Session closed." / "connection
   lost"** banner — it won't silently leave a stale screen.

---

## Notify on bell (background push notifications)

> If [**Bell Attention**](BELL-ATTENTION.md) is enabled, the session list shows a raw bell
> and a promoted "needs you" with the **same 🔔 glyph** (the two are visually unified — the
> hourglass read as unclear), each routed by whether `monitor` is on its tier; each split
> still offers a **separate** clear for the two states (distinguished by tooltip, not icon).
> Whether a raw bell *pushes* (vs. only a promotion) likewise follows the `push` flag's tier;
> both push kinds also share the 🔔 title prefix on the phone.

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
| `GET /api/surfaces` | JSON `{agentDashboard:Bool, surfaces:[{id,title,pwd,…,isAgent,hidden}]}` of live surfaces (`agentDashboard` = is the dashboard running; `isAgent`/`hidden` drive the list filters and are only meaningful when it is) |
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
- **Why Scroll is "smart" (PageUp/PageDown for alt-screen TUIs).** Under `pty-host` the GUI's
  mirror terminal is viewport-only and its **alt-screen state is intentionally not applied**
  (`src/termio/Client.zig`, documented residual): the only thing that reads the local
  `active_key` is the wheel→arrow alternate-scroll translation, so for an alt-screen TUI that
  does **not** capture the mouse (`less`/`man`/plain `vim`) a wheel event is a dead no-op (no
  scrollback in the alt screen; the translation is skipped). The page sidesteps this entirely:
  `xterm.js` exposes the live mode (`term.buffer.active.type` + `term.modes.mouseTrackingMode`),
  so `smartScroll` sends **PageUp/PageDown** in exactly that case and a real **wheel** otherwise.
  Purely page-side — no Zig/host change. (The underlying mirror-alt-screen residual is a separate,
  larger fix that would also benefit real trackpad scrolling under `pty-host`.)

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

---

## Implementation notes (for agents touching the code)

The deep dev-internals below were relocated from `CLAUDE.md`. They are the load-bearing
facts for an agent working on the web-monitor code — preserved verbatim/near-verbatim,
including every gotcha.

### Scope — phone workflows ONLY

> **SCOPE — phone workflows ONLY.** The web monitor is the phone-usage feature
> (list/render/input/scroll from a handset over Tailscale) and nothing else. Do
> **not** build new features on top of it — it is not maintained as a highly-stable
> foundation. Other work (e.g. an MCP server / agent control) may *reuse its
> architecture and copy code* (the host-protocol client, `keySpecs` input mapping,
> `decideRoute`/`RequestParser` patterns, the serial-queue + main-hop threading
> model), but should stand on its own and build directly on Ghostty + the host's
> existing abstractions — there is already enough tooling there. Keep the web
> monitor's surface frozen to what phone usage needs.

The server lives INSIDE the app — one binary, one rebuild/restart, NO second process. A
SINGLE `NWListener` (dedicated serial queue) serves the page, the JSON API, the vendored
`xterm.js` assets, the raw stream, and input/scroll on ONE port.

### Config (dev nuance)

**Config (fork-only, default null/off so an official Ghostty sharing `~/.config/ghostty/config`
never trips):** `web-monitor-listen` (`addr:port`; empty = disabled; purely a BIND address,
NOT an IP allowlist — see the bind caveat) and `web-monitor-token` (OPTIONAL). **Token is
optional:** empty ⇒ the server runs OPEN (`start()` logs a warning; `decideRoute` skips the
token gate + backoff entirely — access control is the TAILNET/Tailscale ACL alone) — this
is the user's deliberate choice for a private tailnet. If SET, it is fully enforced
(constant-time compare; `?token=` only on the bootstrap `GET /` + asset routes, which can't
send a header; `/api/*` requires the `X-Ghostty-Token` header) and is a SHELL-EXECUTION
credential (rotate if leaked). `tokenAcceptable` (≥16 chars) is a soft warning, not a
refusal.

### Color/scrollback architecture (the core of v2)

Under the fork's `pty-host` `.client` backend the GUI's screen mirror is VIEWPORT-ONLY and
colorless, so the live view comes from the HOST. `src/termio/Termio.zig` gained a nullable
`output_observer` (null for `.exec` ⇒ byte-identical GUI behavior; set by the host
`Session`). The host `Session` keeps a bounded 256KB per-session RAW RING BUFFER
(replay-on-connect) and broadcasts new bytes; two ADDITIVE, version-negotiated (minor 0→1),
crash-safe frames carry it: `subscribe_raw` (client→host) + `raw_output` (host→client) in
`src/host/protocol.zig`, routed by `src/host/Server.zig` raw subscribers. A Swift
host-protocol client — `WebMonitorHostClient` (POSIX `AF_UNIX`) — connects to the `pty-host`
socket, does the `Hello` handshake, `subscribe_raw`s a session, and decodes the `raw_output`
stream. `GET /api/surface/{uuid}/stream` pipes those bytes to the browser as a long-lived
`application/octet-stream` with the host grid in `X-Ghostty-Cols`/`X-Ghostty-Rows` headers
(from `ghostty_surface_size`); the page `term.resize()`s `xterm.js` to that grid so
cursor-addressed TUIs render aligned. **Without `pty-host`** (or if the stream can't start →
501) the page falls back to the plain-text snapshot poll.

### Font

The page + the `xterm.js` terminal render in **JetBrains Mono Nerd Font** (the GUI's own
default font), vendored as woff2 (Regular + Bold, from `src/font/res/`, TTF→woff2
~2.2MB→~900KB each) at `vendor/JetBrainsMonoNerdFont-{Regular,Bold}.woff2` and served via two
`assetRoutes` (`/jetbrains-mono-{regular,bold}.woff2`, `font/woff2`, bootstrap/`?token=` like
xterm.css). The phone has no such system font, so shipping it is REQUIRED. The `@font-face`
is injected **client-side** (page asset-loader IIFE) — NOT in the static `<style>` — so the
woff2 `src` URLs carry `?token=` via `url()` exactly like the xterm assets;
`font-display:swap` + an eager `document.fonts.load()` nudge, and the existing
resize-to-host-grid re-measures xterm metrics so a slightly-late font swap self-corrects.
Font is a faithful match to Ghostty, not config-driven (changing `font-family` in ghostty
config won't follow); regenerate the woff2 if you want a different face. NOT exempt from the
iOS-target exclusion set in `project.pbxproj` (listed alongside xterm.{js,css}). GUI-only —
relaunch, no host restart.

### HTTP API (routes + status codes)

`GET /` (page); `GET /xterm.js`, `GET /xterm.css` (vendored assets, `?token=` accepted like
the bootstrap); `GET /api/surfaces` (`{agentDashboard:Bool,
surfaces:[{id,title,pwd,…,isAgent,hidden}]}` — the response is an OBJECT, not a bare array;
see the agent-filters note below); `GET /api/surface/{uuid}/stream` (raw-byte xterm source;
needs `pty-host`); `GET /api/surface/{uuid}/screen?mode=viewport|scrollback` (plain-text
fallback, reuses `cachedVisibleContents`/`cachedScreenContents`); `POST
/api/surface/{uuid}/input`; `POST /api/surface/{uuid}/scroll` (`{"dy":±ticks}`).

Status codes: Unknown id/path → 404, wrong method → 405, bad/negative/oversized
Content-Length → 400, chunked → 411, oversized → 413, bad Host → 403, throttled (token mode)
→ 429.

### Agent filters (fork-only, GUI-only) — list-only "Agents only" / "Hide hidden"

The page's session list has two checkboxes that MIRROR the Agent Dashboard: keep only
detected CLI-agent splits, and/or drop splits hidden in the dashboard. Both DEFAULT ON (so
the phone opens showing only your non-hidden agents) and persist per device in `localStorage`
(`ghostty_filter_agents`/`ghostty_filter_visible`). Filtering is PAGE-SIDE in `loadList`; the
server just enriches each `/api/surfaces` row with `isAgent`/`hidden` and adds the top-level
`agentDashboard` flag (whether the dashboard controller exists). The signal comes from
`AgentDashboardController.webMonitorFilterState()` (`model.liveAgentIDs` + `model.hidden`,
value types, read on the existing main hop in `surfacesJSON()` via `MainActor.assumeIsolated`
like `MCPLayout.surfaceRows`). When the dashboard ISN'T running (`agentDashboard:false`) the
checkboxes are DISABLED + greyed with a note and no filtering is applied — "filters can be
disabled" by design. The detector pauses while the dashboard panel is hidden/occluded, so
`isAgent` reflects last-known detection then (acceptable). ZERO host/Zig change; GUI relaunch
to pick up. Wiring: `AgentDashboardController.webMonitorFilterState()`,
`WebMonitorServer.swift` (`SurfaceRow.isAgent`/`.hidden`, `surfacesJSON()` read,
`surfacesJSONData(_:agentDashboard:)` now returns the OBJECT envelope, page filter bar +
`applyFilterAvailability` + `loadList`/`refreshBellButton` parse `data.surfaces`). Tests:
`WebMonitorServerTests` (`surfacesJSONCarriesAgentDashboardFlag`,
`surfacesJSONCarriesAgentAndHiddenFlags`, `htmlPageHasAgentFilters`, updated `surfacesJSON*`).

### Input = REAL key/wheel events, NOT paste (critical)

`ghostty_surface_text` routes through `completeClipboardPaste` (clipboard path) — pasted `\n`
is a literal newline (never submits), control bytes aren't real keys, and newline pastes trip
Mac paste-protection. So input is sent via `ghostty_surface_key`: a pure testable `KeySpec`
mapping (`keySpecs(forKey:)` / `keySpecs(forText:)`) → press+release. **`KeySpec.keycode`
MUST be the NATIVE macOS virtual keycode** (Return=36, Esc=53, Tab=48, Backspace=51,
C=8+ctrl, U=32+ctrl, arrows 123–126) — the core resolves the physical key via
`input.keycodes` `entry.native == keycode`, so the `GHOSTTY_KEY_*` enum value is WRONG and
silently no-ops. Printable text rides the `text` field (keycode 0); `\n`/`\r` → a real
Return. Scroll = `ghostty_surface_mouse_scroll` (non-precision wheel, `scroll_mods=0`; the
host routes it per the app's mode: SGR wheel / alternate-scroll arrows / scrollback). Page
input model: **Send (and Return-in-field) TYPE the text only — they do NOT submit**; the
**Enter quick-key submits**; quick-keys are
enter/y/n/esc/tab/backspace/ctrl-u(Clear)/ctrl-c, digits 1–4, arrows, and Scroll ↑/↓.
`keySpecs(forKey:)` also maps **pageup/pagedown/home/end** (native macOS keycodes 116/121/115/119)
for the smart-scroll path below.
**Press-and-hold auto-repeat** (`addRepeat`: 350ms delay → 90ms repeat; `touch-action:none` +
preventDefault) on scroll/arrows/backspace only; the rest are single-fire.

**Smart scroll (`smartScroll`, page-side).** The Scroll ↑/↓ buttons do NOT blindly POST a wheel
delta. They read the LIVE terminal mode off the `xterm.js` instance — `term.buffer.active.type`
(`normal`/`alternate`) and `term.modes.mouseTrackingMode` — exposed to the page by adding `term`
to the stream handle (`{ dispose, term }`). Decision: **alt screen AND no mouse tracking** ⇒
`sendKey("pageup"/"pagedown")` (less/man/vim own the screen, have no scrollback, and the
mirror's wheel→arrow translation is a no-op under `pty-host` — see Known limits); **otherwise**
⇒ `sendScroll(±3)` (normal-screen scrollback, or a mouse-capturing app like Claude Code that
handles the wheel itself). With no live `xterm` (plain-text poll fallback) there is no mode to
read, so it falls back to the plain wheel. This is the answer to "how do I know dynamically
whether to scroll or page" — the terminal's own mode tells us, and `xterm.js` already tracks it.

### Security defense-in-depth

Independent of the token: `hostHeaderAllowed` (DNS-rebinding guard), a decaying+capped
per-peer failed-token backoff (only applies when a token is set), and per-connection bounds
(~10s idle watchdog + ~15s absolute deadline armed once in `handle()` + 32-connection cap) —
the long-lived `/stream` connection is EXEMPT from the watchdogs. The page renders untrusted
list/snapshot text via `textContent` (never `innerHTML`); the live view is `xterm.js` parsing
the byte stream.

### Threading (correctness-critical)

The listener + all connections run on a DEDICATED background SERIAL queue (never
`DispatchQueue.main`), which makes the `DispatchQueue.main.sync` hops deadlock-safe; `stop()`
tears down with `queue.async` (a `queue.sync` from main would invert against a handler's
`main.sync`). Every handler touching AppKit / `TerminalController.all` / `SurfaceView` /
`ghostty_surface_*` hops to main and returns ONLY value types — never a
`ghostty_surface_t`/`SurfaceView` across the hop. `WebMonitorHostClient` runs its socket read
loop on its OWN background thread; `onBytes` writes straight to the (thread-safe)
`NWConnection`. **Routing is a PURE function** `decideRoute(...) -> RouteDecision` (no
AppKit/socket/mutation); it + `hostHeaderAllowed`, `keySpecs`, `scrollDeltaY`, `parseListen`,
`RequestParser`, `surfacesJSONData`, `HTTPResponse`, and the host-client framing helpers are
`internal` + unit-tested.

### Push notifications on bell (Notify toggle, fork-only, GUI-only)

A background **Web Push** so a bell pushes to a subscribed phone with the tab CLOSED / phone
LOCKED — the "I stepped away" feature. The page header has a **🔔 Notify** toggle = a single
SERVER-SIDE arm/mute flag (mute at the laptop, arm when away). Full Web Push, ZERO new deps:
a self-generated **VAPID** P-256 keypair (RFC 8292 ES256 JWT) — **NO Firebase/Google
project**; Chrome returns an `fcm.googleapis.com` endpoint we POST to directly with **RFC
8291 `aes128gcm`** payload encryption (ephemeral ECDH + HKDF-SHA256 + AES-128-GCM), ALL via
**CryptoKit**. `WebPushCrypto` (encrypt + JWT + base64url) is PURE and unit-tested against the
**RFC 8291 §5 worked example** (byte-for-byte) + a VAPID sign/verify round-trip.
`WebPushManager` persists the keypair + device subscriptions + the enable flag in
**UserDefaults** (per-bundle-id; default MUTED), observes `.ghosttyBellDidRing` like
`MCPEventBus`, and fans each bell out via `URLSession` (debounced ~3s/surface; 404/410 ⇒ drop
the dead subscription).

**HARD REQUIREMENT: a SECURE CONTEXT** — service workers only register over HTTPS, so the
plain-HTTP-over-Tailscale-IP setup CANNOT push. The chosen TLS path is **`tailscale serve`**
in front: bind the monitor to a **loopback INTERNAL port** (`web-monitor-listen =
127.0.0.1:18787`) and `tailscale serve --bg --https=<external> 127.0.0.1:<internal>` proxies
`https://<machine>.<tailnet>.ts.net:<external>` → loopback.

**The external HTTPS port and the internal bind port MUST DIFFER** — the monitor binds the
port on ALL interfaces (`*:<internal>`, host part ignored), so serving HTTPS on that same
port makes `tailscaled` grab the tailnet IP's `:<port>` first and the monitor's wildcard bind
then fails with `EADDRINUSE` (never starts → proxy 502s). Convention: external `8787`,
internal `18787` (the `1`-prefixed twin).

**Per-identity offset** (`WebMonitorServer.portOffset`, mirrors `MCPServer`) shifts the shared
loopback port so the three builds coexist: Release `+0` (18787), ReleaseLocal `+1` (18788),
Debug `+2` (18789); `tailscale serve` maps each external (8787/8788/8789) to its identity's
loopback port. Pure helpers `portOffset(forBundleID:)` / `applyPortOffset(_:offset:)` are
unit-tested (`WebMonitorServerTests`).

`tailscale serve` only proxies to `127.0.0.1` but it does NOT rewrite `Host` to the loopback
backend; it forwards the ORIGINAL tailnet `Host: <machine>.<tailnet>.ts.net:<external port>`
(also in `X-Forwarded-Host`, with `X-Forwarded-Proto: https` + Tailscale identity headers).
So `hostHeaderAllowed` explicitly **accepts any `*.ts.net` host on any port** (verified
against the real forwarded request); reaching that endpoint already requires tailnet
membership, and a browser cannot forge a `*.ts.net` Host against the loopback bind, so
DNS-rebinding protection for the loopback/configured-host paths is unaffected. The token still
gates — **NO Zig changes were needed; this is entirely Swift + page-side.** Routes (all on the
same listener): `GET /sw.js` (the service worker — a BOOTSTRAP path, `?token=` accepted, since
`serviceWorker.register()` can't set the header), `GET /api/push/config` (`{vapidPublicKey,
enabled, subscriptions}`), `POST /api/push/{subscribe,unsubscribe,enabled}` (header-token like
every `/api/*`). The page's Notify button is disabled with a "needs HTTPS" note when
`!window.isSecureContext`. The body parsers (`pushSubscription`/`pushEndpoint`/`pushEnabledFlag`
`fromBody:`) + the route decisions are `internal` + unit-tested.

### Liveness/errors

Via `UNUserNotificationCenter` + log (Console.app subsystem = bundle id, category =
`web-monitor`). No live config-reload (relaunch to change listen/token). Zero new SPM deps
(Foundation + Network + AppKit; `xterm.js` is a vendored static asset, bundled via the
synchronized Sources group + iOS exclusion). **DEPLOY caveat:** the host raw-tee is a HOST
change — rebuilding/restarting `ghostty-host` LOSES all live sessions (RAM-only); the
GUI/page parts are GUI-only (a relaunch reattaches).

### Wiring

- `src/config/Config.zig` (`web-monitor-listen` + `web-monitor-token` + `pty-host` — the
  last is now `?[:0]const u8` so `ghostty_config_get` can return it as a C string for the
  `ptyHost` getter)
- `macos/Sources/Ghostty/Ghostty.Config.swift` (`webMonitorListen`/`webMonitorToken`/`ptyHost`)
- `macos/Sources/Features/WebMonitor/WebMonitorServer.swift` (server + xterm page + routes +
  Notify toggle + `/sw.js` + `/api/push/*`)
- `macos/Sources/Features/WebMonitor/WebMonitorPush.swift` (`WebPushCrypto` + `WebPushManager`)
- `macos/Sources/Features/WebMonitor/WebMonitorHostClient.swift` (host-protocol client)
- `macos/Sources/Features/WebMonitor/vendor/xterm.{js,css}`
- `src/host/{Session,Server,protocol}.zig` + `src/termio/Termio.zig` (raw-tee + ring + frames
  + observer)
- `macos/Sources/App/macOS/AppDelegate.swift` (start/stop)
- `macos/Ghostty.xcodeproj/project.pbxproj` (iOS exclusion of the new macOS-only files)

### Tests

- `macos/Tests/WebMonitor/WebMonitorServerTests.swift` (auto-discovered by the `GhosttyTests`
  filesystem-synchronized group)
- host frame/ring/integration tests in `src/host/test.zig` (`zig build test
  -Dtest-filter=host`)

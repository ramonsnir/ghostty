# Web monitor — watch & drive Ghostty splits from a phone or a second laptop

Fork-only feature of **"Ghostty (ramon)"** (bundle id `com.mitchellh.ghostty-ramon`).
A single GUI-embedded HTTP server *inside the running app* serves ONE responsive,
capability-adaptive web page, a small JSON API, **and a live raw-byte stream** on one
port — the same page adapts to a phone AND a second laptop on the tailnet (persistent
sidebar on a wide screen, drawer on a phone; see "Scope" under Implementation notes).
From either device (e.g. over **Tailscale**) you can: list the live terminal surfaces,
**watch one in color with scrollback and live updates**, **send input** (notably
approving CLI-agent prompts, or full-keyboard driving from a laptop), and **scroll /
drive** a remote TUI.

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
   - **★ Focus on heroes** (a third toggle, default OFF) is an OVERRIDE: while on it shows ONLY
     [hero](HERO-AGENTS.md) splits and **ignores** Agents-only / Hide-hidden (a hero is
     load-bearing — you want it regardless of hide state), greying those two out; turn it off to
     return to regular mode. Each **hero split is marked with a purple ★** at the start of its row
     (matching the dashboard tile / tab marker). Hero-ness comes from the Agent Dashboard, so this
     toggle is disabled when the dashboard isn't running.
   - Each row has a **Hide / Show** button (shown only when the Agent Dashboard is running). It
     toggles the **same** hide set as the dashboard's eye-slash button / `hide_dashboard_split`
     keybind — so hiding a split **from the phone is a hide in the dashboard too** (unified), and
     the **Hide hidden** filter then drops it. Auto-unhide-on-bell still applies (an agent that
     rings reappears). This is how you hide an agent split from the phone.
   - **＋ New tab** sits above the list (both the phone drawer and the laptop sidebar). It opens a
     fresh terminal tab on the Mac — same as ⌘T there — and **jumps you straight into it**, so you
     can start a new shell (or launch a CLI agent) from the phone. It opens in the frontmost Mac
     terminal window (a brand-new window if none is open). The auto-jump is deliberate: a plain new
     shell isn't a detected agent, so the default **Agents only** filter would otherwise hide it
     from the list and the button would look like it did nothing.
   - **＋ Split** sits on each tab's header in the list. It adds a plain shell split to **that**
     tab on the Mac and jumps you into it (same reason as ＋ New tab). There is no direction to
     pick — you can't see the physical layout from here, so the Mac **packs** it like the Agent
     Queue does: the new pane is born at the largest pane, then the whole tab is re-tiled into its
     densest grid (`ceil(√N)` columns, the `compact_splits` shape). The new shell inherits the
     tab's focused pane (cwd etc.) like ⌘D, and takes focus on the Mac. It lives in the list,
     not the terminal view, so it costs no screen space where you're reading.
   - **Queues** (shown above the list only while an [Agent Queue](AGENT-QUEUE.md) run is live):
     one row per run — `name · phase · dispatched/cap` — with a **+1** button that raises the
     run's lifetime **max items** by one (the dashboard's cap editor, live, no restart). The +1
     is disabled for an unlimited (`∞`) cap. It always allows exactly one MORE dispatch, so an
     exhausted `10/10` becomes `10/11`, and a cap lowered below the lifetime count still frees
     one slot.
3. The screen renders in **`xterm.js`** — **full ANSI color, native scrollback, live updates**
   (fed by a host byte stream over **Server-Sent Events**, which streams incrementally on every
   browser — notably iOS Safari, which *buffers* a plain `fetch()` stream and would otherwise show
   stale content; the terminal is sized to the host's grid so TUIs line up),
   in the **same JetBrains Mono Nerd Font Ghostty uses** (vendored as woff2 and served by the
   app, so it renders correctly on a phone that doesn't have the font installed).
   It scrolls horizontally if the host grid is wider than the phone; use the **font-size**
   control to fit. If the stream is unavailable it falls back to a plain-text snapshot poll.
4. **Input:**
   - **Text field + Send** — *types* the text into the terminal; it does **not** submit.
     **Autocorrect + spellcheck are ON** on this field (so a prose reply to an agent gets
     corrected — iOS honors these hints); autocapitalize stays OFF so a typed shell command
     isn't capitalized. (The token box is the opposite — strict-off — a secret is never
     autocorrected.)
   - **First-tap on iOS:** the on-screen buttons (quick-keys, Send) register on the **first**
     tap even while the text field is focused. Previously iOS ate the first tap dismissing the
     keyboard, so a button needed two or three taps; the page now keeps the field's focus on tap
     so the button fires immediately (and the keyboard stays up for the next reply).
   - **Enter** quick-key — submits (a real Enter keypress).
   - Quick-keys: **Enter · y · n · Esc · Tab · ⌫ Backspace · Clear (Ctrl-U) · Ctrl-C**, the
     **digits 1–4** (numbered agent menus), and **arrows**.
   - **Scroll ↑ / Scroll ↓** — always **frame mode** (for anything with a live view): drives a
     real mouse wheel to the app or shell (which scrolls its own transcript / scrollback, exactly
     like the Mac desktop wheel) and shows the **host's authoritative render** of each frame — in
     **full color**, identical to your desktop, with no garble. A **● Live** button (or Back)
     returns to the live view. This is the fix for both the previously-dead Claude Code scroll and
     the garbled re-emulation (see the note under **Known limits**). One pair of buttons "just
     scrolls" whatever you're looking at — shell or full-screen TUI alike.
   - **Press-and-hold to auto-repeat** on **scroll, arrows, and backspace** (a tap still fires
     once); Enter/Ctrl-C/etc. are single-fire on purpose.
   - All input is sent as **real key/wheel events** (`ghostty_surface_key` / `_mouse_scroll`),
     not pasted — so Enter actually submits and control keys actually fire.
5. **⛶ Maximize** (in the viewer header, right next to **← Sessions**) — when the split you're watching is a small pane on
   the Mac, what you see here is small too: the viewport you're rendering **is** the host
   session's grid, and that grid is sized by the pane on the laptop. Maximize **zooms that
   split on the Mac** (the same thing `toggle_split_zoom` does), so it takes over its tab and
   the grid — and your view — gets bigger. The button becomes **⛶ Restore** to put it back.
   Things worth knowing:
   - It **does not focus** the split on the Mac, so it won't steal your keyboard focus there or
     dismiss a bell.
   - The pane's PTY resizes both ways, so the program **reflows** (a TUI repaints; a shell
     re-wraps). That's the same cost as pressing the zoom keybind on the Mac.
   - The stream **reconnects automatically** a moment after the resize (a brief "resizing…"),
     because the terminal here is sized once when the stream opens.
   - It's **disabled** when the split is the only pane in its tab — there'd be nothing to
     maximize into.
   - A maximize left on **persists** (it survives a Mac GUI restart, like any zoom). That's
     deliberate: unzoom it on the Mac with `ctrl+a>z`, or hit Restore here. Maximizing a
     different split in the same tab simply moves the zoom — a tab is only ever zoomed to one
     split.
6. Closed surface (404) or a dropped link shows a visible **"Session closed." / "connection
   lost"** banner — it won't silently leave a stale screen.

---

## Using it from a laptop

It's the **same URL and the same page** — the client is one responsive, capability-adaptive
web page (there's no separate "desktop" address). On a wide screen it simply lays out
differently and lights up the capabilities a laptop has:

1. **Persistent split-picker sidebar.** On a wide window (≥ ~860px) the session list stays
   pinned in a left sidebar (with the same **★ Focus on heroes / Agents only / Hide hidden**
   filters and per-row **Hide / Show**), and picking a split swaps the **viewer** beside it
   **without** hiding the list — so you can jump between splits without going "back" each time.
   The active split's row is highlighted. Narrow it below ~860px and the sidebar collapses back
   into the phone-style drawer with a **← Sessions** button.
2. **Full-keyboard driving.** Just click into the terminal and type — keystrokes go straight to
   the surface as **real key events**: printable text, **Enter / Esc / Tab / Backspace /
   arrows / Home / End**, **Ctrl-<letter>** (Ctrl-C, Ctrl-D, Ctrl-Z, Ctrl-A, Ctrl-R, …), and
   **PageUp / PageDown** (scrollback, via frame mode). This is inert without a physical keyboard
   (so a phone is unaffected) and it steps aside whenever a form control (the Send field, the
   filter checkboxes, the token box) is focused, so those keep normal keyboard behavior.
   > **Mac-client / standard-layout assumption.** Named and positional keys are routed by the
   > client's *native macOS virtual keycode*, so a non-Mac client or a non-standard physical
   > layout may mis-map them (printable text still works). The header shows a small
   > "Mac client, standard layout assumed" note as a reminder (hidden on a phone).
3. **Browser copy / paste.** Select text in the terminal and **⌘C** copies it; **⌘V** pastes the
   clipboard into the surface (as real input — newlines become Enter); **⌘A** selects the whole
   terminal. This uses the browser clipboard and so needs a **secure context** (which
   `tailscale serve` already provides); without one, use the **Copy** button / **Send** field
   fallback. ⌘ is never forwarded to the shell (⌘R still reloads the page).
4. Everything from **Using it from the phone** still applies — the on-screen quick-key row, the
   Send field, scroll/frame-mode, the notify-on-bell toggle, jump-to-bottom, and the poll
   fallback are all present (harmless extras on a laptop). Switching a laptop tab away and back
   **cleanly resyncs** the live stream, so a backgrounded tab that stalled recovers on return.

---

## Notify on bell (background push notifications)

> If [**Bell Attention**](BELL-ATTENTION.md) is enabled, the session list shows a raw bell
> and a promoted "needs you" with the **same 🔔 glyph** (the two are visually unified — the
> hourglass read as unclear), each routed by whether `monitor` is on its tier; each split
> still offers a **separate** clear for the two states (distinguished by tooltip, not icon).
> Whether a raw bell *pushes* (vs. only a promotion) likewise follows the `push` flag's tier;
> the raw-bell and needs-you push kinds share the 🔔 title prefix on the phone. A **hero**
> ([**Hero Agents**](HERO-AGENTS.md)) is the exception: an idle hero pushes with a **distinct
> ⭐ glyph** so you can tell a load-bearing hero apart from routine work at a glance — see
> **Notify on bell → Hero push** below.

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

### Hero push (distinct glyph for an idle hero)

A **hero** ([**Hero Agents**](HERO-AGENTS.md)) is load-bearing queue work that competes for
*your attention* rather than a machine slot, and lives in its own dedicated tab. When a hero
surface goes idle / wants your input it fires a **distinct push** so on your phone it's
immediately clear a **hero** is waiting, not routine throughput:

- **Title glyph: ⭐** (vs. the 🔔 the bell and needs-you pushes share) — so a hero reads apart
  at a glance in the notification tray. Title is `⭐ <surface title>` (or `⭐ Ghostty` when the
  title is empty).
- **Payload carries `"kind":"hero"`** (the routine pushes carry `"kind":"bell"` / `"kind":"attention"`),
  so the page / service worker can tell a hero push apart from a routine one.
- **Independent debounce.** A hero push has its own per-surface ~3s debounce, separate from the
  bell/attention kinds — a chatty bell can never swallow the headline "a hero needs you" push.

There is **no new delivery mechanism** — a hero rides the exact same Web Push + arm/mute toggle
+ VAPID plumbing as every other push (same subscriptions, same secure-context requirement). The
only difference is the glyph, the payload `kind`, and the independent debounce. A hero **routes
into the loud attention tier**: it uses the existing `.ghosttyAgentNeedsAttention` path, and the
observer picks the ⭐ hero push (vs. the 🔔 attention push) off the surface's hero flag — an
un-flagged surface still gets the plain attention push (back-compat).

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
- The server's **`GET /api/surface/{uuid}/stream-sse`** pipes those raw bytes to the browser as
  **Server-Sent Events** — each host chunk base64-framed as one SSE `data:` event, with the host
  grid size sent in-band as the first `event: size` (EventSource can't read response headers) and
  a periodic keepalive comment on an idle stream; the page (`EventSource`) base64-decodes each
  frame back to bytes and feeds them to `xterm.js` (sized to that grid). **Why SSE, not a raw
  `fetch()` stream:** iOS WebKit *buffers* a `fetch().body.getReader()` stream — it delivers
  chunks in large batches, so a low-rate terminal shows **stale** content until a reconnect —
  whereas `EventSource` delivers incrementally on every browser. The raw `application/octet-stream`
  **`/stream`** route (grid size in `X-Ghostty-Cols/-Rows` headers) is kept as an alternative but
  the page no longer uses it.
- Input/scroll go back the other way as real key/wheel events on the GUI surface, forwarded by
  the `.client` backend to the host.

---

## HTTP API

| Route | Purpose |
|---|---|
| `GET /` | the embedded responsive page — serves both phone and laptop (`?token=` accepted here when a token is set) |
| `GET /xterm.js`, `GET /xterm.css` | the vendored xterm.js assets (`?token=` accepted) |
| `GET /jetbrains-mono-{regular,bold}.woff2` | vendored JetBrains Mono Nerd Font (`?token=` accepted) |
| `GET /api/surfaces` | JSON `{agentDashboard:Bool, surfaces:[{id,title,pwd,…,splitCount,isAgent,hidden,hero,maximized}], queues:[{run,phase,active,queued,dispatched,maxItems}]}` of live surfaces (+ live queue runs, `maxItems` null = unlimited) (`agentDashboard` = is the dashboard running; `isAgent`/`hidden`/`hero` drive the list filters + the purple hero ★ and are only meaningful when it is; `maximized`+`splitCount` drive the ⛶ Maximize control) |
| `POST /api/new-tab` | open a fresh Ghostty tab on the Mac (frontmost window, or a new window if none) → `{ok:true,id:<uuid>}` so the page navigates into it. `500` if nothing was created |
| `POST /api/queue/max-items` | `{"run":<name>,"delta"?:1}` → raise a live queue run's lifetime cap to `max(cap, dispatched) + delta` → `{ok:true,maxItems:N}`. `400` bad body (delta must be an integer 1…100), `404` unknown run, `409` unlimited cap, `503` Agent Dashboard not running |
| `GET /api/surface/{uuid}/stream-sse` | **live stream over Server-Sent Events — the page's primary live transport** (xterm.js source; needs `pty-host`). Same host bytes as `/stream`, base64-framed as SSE `data:` events; the grid size is the first `event: size` (EventSource can't read response headers) and the token rides `?token=` (EventSource can't set a header). iOS-safe: iOS WebKit **buffers** a plain `fetch()`-body stream so the terminal shows stale content, while EventSource delivers incrementally on every browser. |
| `GET /api/surface/{uuid}/stream` | live **raw** byte stream (`application/octet-stream`; header-token only). Kept as an alternative; the page no longer uses it (iOS buffers it — see `/stream-sse`) |
| `GET /api/surface/{uuid}/screen?mode=viewport\|scrollback` | plain-text snapshot (fallback) |
| `POST /api/surface/{uuid}/input` | real key events (raw text, or `{"key":…}`) |
| `GET /api/surface/{uuid}/frame` | host's authoritative render as a self-contained ANSI frame (color); for frame-mode scrolling. 501 without pty-host |
| `POST /api/surface/{uuid}/scroll` | `{"dy":±ticks}` → seed cursor at surface center, then a real mouse wheel to the app |
| `POST /api/surface/{uuid}/hidden` | `{"hidden":bool}` → hide/reveal in the Agent Dashboard hide set (503 if the dashboard isn't running) |
| `POST /api/surface/{uuid}/maximize` | `{"maximized":bool}` → split-zoom / unzoom this split's tab on the Mac, so its grid (and the viewport here) grows. `409` when the split is alone in its tab |
| `POST /api/surface/{uuid}/split` | add a PACKED plain-shell split to the tab holding `{uuid}` (largest pane, then the densest-grid re-tile; no direction) → `{ok:true,id:<uuid>}` so the page navigates into it. `404` if the surface is gone / the split failed |
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
  scrollback (10000 lines) for everything streamed since connecting. Scroll ↑/↓ always uses frame
  mode: it drives a real wheel to the app/shell and paints the host's authoritative color frame —
  see the fix notes below.
- **Why Scroll is "smart" — and the Claude Code fix (position matters).** Claude Code (and `htop`,
  `vim`+mouse, …) render on the **alt-screen with mouse tracking ON**, so the terminal forwards a
  wheel to the app AS AN SGR MOUSE EVENT and the app scrolls its own view + redraws (that redraw
  streams back to the phone in color). The catch: `scrollCallback` reports the wheel at the
  **current cursor position** (`getCursorPos()` in `src/Surface.zig`), and the web monitor never
  moves a mouse — so it defaulted to **(0,0)**, the top row (Claude's header), which the app ignores.
  That was the dead-no-op; the desktop "just works" only because the pointer sits over the transcript.
  **Fix:** `/scroll` seeds the cursor at the surface CENTER (`ghostty_surface_mouse_pos`, logical
  points = `width_px / backingScaleFactor / 2`) so the SGR report lands in the transcript and the app
  scrolls — verified live (`vim -c 'set mouse=a'` and Claude Code both scroll). **But seed ONLY on the
  FIRST scroll of a viewing** (`{seed:true}`; page tracks `scrollSeededFor`, reset in `showSurface`):
  seeding is a mouse MOVE, and Claude RESETS its scroll on a move (`?1003` any-event), so seeding
  before EVERY wheel made consecutive scrolls non-cumulative (they capped ~1 screen — "scrolls up 3-4×
  then stops"). The desktop does ONE move then MANY wheels (accumulate to the full history); seed-once
  + bare wheels after (the position persists on the surface) matches it (proven: on the seed-every
  build a single `dy=30` reached deeper than 25×`dy=3`). The page's `smartScroll` **always uses
  frame mode** when a live xterm is present. An earlier build tried to be "smart" — scroll
  `xterm.js`'s OWN scrollback locally when `term.buffer.active.baseY>0` (a shell) and only enter
  frame mode when `baseY==0` (a full-screen TUI) — but `baseY` is NOT a reliable shell-vs-TUI
  discriminator: a full-screen app (Claude Code) can accumulate stray xterm.js scrollback from the
  connect-time replay (`baseY>0`), which mis-routed it to LOCAL re-emulation scrolling → the garble
  came back AND no ● Live button appeared (inconsistent between two surfaces). Frame mode is correct
  for EVERYTHING: `sendScroll` drives the host wheel (the host applies the app's REAL mode — SGR
  wheel for a mouse app, alternate-scroll arrows otherwise, or real scrollback for a shell) and the
  page paints the host's authoritative `/frame`. Trade-off accepted: a plain shell no longer gets
  instant local scroll, but it scrolls correctly via the host — consistent, colored, never garbled.
  No live xterm (poll fallback) → the poll loop reads the host-scrolled mirror, so a plain host wheel
  suffices. Purely GUI/page-side — no host/Zig change.
  - *Aside:* a host-side viewport `scroll_viewport` emits no bytes back on the raw stream (it repins
    the mirror, not the child), so scrolling the host viewport is NOT how this works — the wheel goes
    to the CHILD (Claude), which redraws. Note also that Claude renders its transcript inside a fixed
    sub-region (`ESC[2;41r` + `CSI S`), so its scrolled-off lines don't enter the terminal's own
    scrollback; the wheel scrolls Claude's IN-APP transcript, not terminal scrollback.

---

## Status

Implemented and reviewed across code / design / UX / test-coverage. Covered by a Swift unit
suite (`GhosttyTests/WebMonitorServerTests`, 250+ cases — including the SSE-transport framing
+ route + query-token tests and the mobile-input page-content guards) + host integration/protocol
tests (`zig build test -Dtest-filter=host`) + a Zig config-parse test; the macOS app builds clean
and the full `GhosttyTests` unit suite passes (1306 cases, 0 failures). Committed on `ramon-fork`
(not pushed).

## Where the code lives

| Piece | File |
|---|---|
| Server + embedded `xterm.js` page (routing, `/stream-sse` + raw `/stream`, `/scroll`, assets, Notify toggle, mobile input fixes) | `macos/Sources/Features/WebMonitor/WebMonitorServer.swift` |
| Web Push crypto (VAPID/RFC 8292 + RFC 8291 `aes128gcm`) + subscription store / bell→push | `macos/Sources/Features/WebMonitor/WebMonitorPush.swift` |
| Host-protocol client (subscribe to `raw_output`) | `macos/Sources/Features/WebMonitor/WebMonitorHostClient.swift` |
| Vendored xterm.js | `macos/Sources/Features/WebMonitor/vendor/xterm.{js,css}` |
| Vendored JetBrains Mono Nerd Font (woff2) | `macos/Sources/Features/WebMonitor/vendor/JetBrainsMonoNerdFont-{Regular,Bold}.woff2` |
| Unit tests | `macos/Tests/WebMonitor/WebMonitorServerTests.swift` |
| Host raw-output tee + frames + ring buffer | `src/host/{Session,Server,protocol}.zig`, `src/termio/Termio.zig` (output observer) |
| Authoritative frame serializer (frame-mode scroll) | `src/terminal/render.zig` (`RenderState.dumpAnsi`), `src/apprt/embedded.zig` (`ghostty_surface_read_ansi`), `include/ghostty.h` |
| Config keys + `pty-host` (`[:0]`-terminated so it's C-gettable) | `src/config/Config.zig` |
| macOS config getters | `macos/Sources/Ghostty/Ghostty.Config.swift` (`webMonitorListen` / `webMonitorToken` / `ptyHost`) |
| Start on launch / stop on quit | `macos/Sources/App/macOS/AppDelegate.swift` |
| Full architecture / wiring notes | **`CLAUDE.md`** ("Web monitor" entry) |

---

## Implementation notes (for agents touching the code)

The deep dev-internals below were relocated from `CLAUDE.md`. They are the load-bearing
facts for an agent working on the web-monitor code — preserved verbatim/near-verbatim,
including every gotcha.

### Scope — ONE responsive, capability-adaptive client (phone + desktop)

> **SCOPE — a single responsive client serving BOTH phone and desktop.** The web
> monitor is **one page** (`htmlPage`, served at `GET /`) that adapts to whatever
> device opens it — a handset over Tailscale AND a second laptop on the tailnet
> alike. There is **no `/desktop` route and no second `desktopHtmlPage`**; the
> earlier "phone-only, frozen page / standalone desktop copy" governance is
> **retired** (see `DESKTOP-MONITOR-DESIGN.md`, now SUPERSEDED). Layout is
> **responsive** (a persistent split-picker sidebar on a wide screen, collapsing to
> a full-width drawer on a phone) and capabilities are **feature-detected, never
> guessed from the viewport** (copy/paste gated on secure-context + clipboard; the
> global keydown driver attaches universally and is inert without a physical
> keyboard). Other work (e.g. an MCP server / agent control) may still *reuse its
> architecture and copy code* (the host-protocol client, `keySpecs` input mapping,
> `decideRoute`/`RequestParser` patterns, the serial-queue + main-hop threading
> model), but should stand on its own and build directly on Ghostty + the host's
> existing abstractions.

### The responsive, capability-adaptive client (fork-only, GUI/page-only)

There is now **ONE page** (`htmlPage`, `GET /`) for every device — no second route,
no `desktopHtmlPage`. It reuses the frozen server plumbing (`/api/surfaces`,
`/stream`, `/frame`, `/input`, `/scroll`, the vendored `xterm.js` / JetBrains Mono
assets) and adds a responsive layout + capability gates + the keyboard driver a
laptop needs. **GUI/page-only — no Zig, no host, no protocol change; no host restart
/ no session loss to ship.** Reach it at `https://<machine>.<tailnet>.ts.net:<port>/`
(the same `tailscale serve` front end); `?token=` on `GET /` still authenticates the
bootstrap and is stashed + sent as `X-Ghostty-Token` on `/api/*`.

**Responsive layout — one `data-view` state machine, 860px breakpoint.** A single
`data-view` attribute on `#app` drives both modes off pure CSS; there is no "phone
page" vs "desktop page":
- **Wide (≥860px):** a PERSISTENT surface-picker sidebar (`id="sidebar"`, `id="list"`)
  beside a flex-fill viewer (`id="main"`). Selecting a row swaps the viewer in place
  (`highlightActive` marks the active `data-id` row) **without hiding the list** — the
  sidebar keeps refreshing while you drive a surface.
- **Narrow (<860px, the phone behavior):** the sidebar becomes a full-width **drawer**
  and the two panes are mutually exclusive — `data-view="list"` shows the picker,
  `data-view="surface"` hides it and shows the viewer, with a back/menu control
  (`#menubtn`, CSS-hidden on wide, where the sidebar is always present) to reopen the
  drawer (`menuBtn.onclick` → `showPlaceholder()` + `loadList()`). The transitions are
  the load-bearing part: `showSurface` flips `#app` to `data-view="surface"` and
  `showPlaceholder` back to `"list"` (guarded by `htmlPageDataViewStateMachineTransitions`).

**Always-visible chrome + header layout (narrow-safety).** Two elements are laid out so
the narrow drawer can't hide a message or overflow sideways: (1) **`#banner` + `#notice`
are TOP-LEVEL** (siblings above `#app`, not nested in `#main`) — the body is a flex
column with the banners at the top and `#app` flex-filling — so a status banner
(connection-lost / session-closed / hide-failed) and the token-recovery `role=alert`
notice stay visible even in the narrow `data-view="list"` drawer where `#main` is
`display:none` (the regression they fix). (2) **`#viewhdr` is `flex-wrap:wrap`** and the
desktop **`#maclayoutnote` is hidden inside the `@media (max-width:859px)` block** (with
`overflow-x:hidden` on `#app` as a backstop), so the header's fixed children (menu + mac
note + Copy + Clear) wrap instead of scrolling the page body sideways on a phone. Also,
`showSurface` deliberately does **NOT** `inp.focus()` (unlike the old phone page): an
always-focused Send field would make the global keydown driver bail (`isTypingField`),
disabling desktop keyboard driving — the phone trade-off is the soft keyboard no longer
auto-pops on open. The 3s list timer **skips the `loadList()` refetch when the sidebar is
collapsed** (narrow + `data-view="surface"`) since its DOM is off-screen, still refreshing
the viewed split's Clear buttons.

The sidebar carries the SAME three filters as before — **★ Focus on heroes**
(`f-heroes`), **Agents only** (`f-agents`), **Hide hidden** (`f-visible`),
localStorage-persisted (`ghostty_filter_*`), availability driven by
`applyFilterAvailability` + `data.agentDashboard`. The **single-surface invariant** is
preserved (selecting a row disposes the old stream then opens the new). The live
viewer, host-grid sizing (`X-Ghostty-Cols`/`-Rows`), frame-mode scroll
(`smartScroll`/`enterFrameMode`/`paintFrame`/`exitFrameMode` + `/frame`), and the
`/screen` poll fallback (`fallbackToPoll`, `id="screen"`) are unchanged. Chrome is
theme-aware (a `@media (prefers-color-scheme: light)` block over the dark default);
only the CHROME is themed — the terminal colors come from the host's ANSI stream.

**Capability gates — feature-detected, never viewport-guessed.** Both the keyboard
driver and copy/paste attach on every device and light up only where the capability
exists:
- The **global keydown driver attaches UNIVERSALLY** — it is inert without a physical
  keyboard (a phone with no keyboard simply never fires `keydown`), so there is no
  desktop-only gating. Copy/paste is gated on **secure context + `navigator.clipboard`**
  (`window.isSecureContext`), satisfied by the same `tailscale serve` HTTPS the Web
  Push already needs, and falls back to the Send field when unavailable.

**Universal keyboard driver + the form-control guard.** A **CAPTURE-phase global
keydown handler** (`addEventListener("keydown", …, true)`) maps browser keystrokes to
`POST /api/surface/{uuid}/input` and `preventDefault()`s so the browser doesn't also
act. It only fires while a surface is selected (`if (!current) return;`) and **guards
focused form controls** so on-screen UI keeps native keyboard behavior: it bails on
`isTypingField(e.target)` (the Send / token fields) AND on any focused `INPUT`/`SELECT`/
`TEXTAREA`/`BUTTON`/`OPTION`/`A` (so the sidebar filter checkboxes, the mode `<select>`,
and buttons keep Space-toggles / Enter-activates / arrow-moves) — with the **one
exception** of xterm.js's own hidden `.xterm-helper-textarea` (that IS the terminal, so
it falls through), and body-level focus (nothing focused) also falls through so typing
after a click on the terminal still reaches the surface. The mapping:
- **Printable characters** are batched (`queueType`/`flushType`) and sent via the
  `text/plain` path (server → `keySpecs(forText:)`), kinder to the core's 64-slot IO
  mailbox than one POST per key.
- **Named / arrow keys** map `KeyboardEvent.code`/`.key` → the server `key` names
  (`keyNameFor`) that `keySpecs(forKey:)` knows (`enter`, `esc`, `tab`, `backspace`,
  arrows, `pageup`/`pagedown` → frame-mode scroll, `home`/`end`, `space`).
- **Ctrl-`<letter>`** rides the one server-side extension: `keySpecs(forKey:)` has a
  **general `ctrl-<letter>` rule** (`ctrlLetterKeycodes` table, a–z → native macOS
  virtual keycodes read from `src/input/keycodes.zig`) so Ctrl-D/Z/A/E/R/L/… all
  deliver, not just the original explicit `ctrl-c`=8/`ctrl-u`=32 (which are unchanged —
  regression-guarded). A non-letter `ctrl-…` returns nil (400). The page derives it as
  `sendKey("ctrl-" + code.slice(3).toLowerCase())` when `/^Key[A-Z]$/.test(code)` and
  Ctrl is held.
- **⌘ (Meta) is REPURPOSED for clipboard/selection, NOT forwarded to the shell**
  (`if (e.metaKey)` → ⌘A → `stream.term.selectAll()`; ⌘C/⌘V/⌘X fall through so the
  native copy/cut/paste DOM events fire; ⌘R still reloads). Most ⌘ combos are
  browser/OS-owned and undeliverable anyway (⌘W/T/N/L/Q/Tab, browser zoom). The
  on-screen quick-key row (Enter/Ctrl-C/Clear/…) is kept as a fallback.
- **⚠️ NATIVE-keycode caveat + Mac-client assumption.** `KeySpec.keycode` is a NATIVE
  macOS virtual keycode (the core matches `entry.native == keycode`; a `GHOSTTY_KEY_*`
  enum value silently no-ops), and it is a **physical-position** code. Named/control/arrow
  keys therefore assume **a Mac client with a standard layout** (the "my other MacBook"
  case) — documented here. Off-Mac, positional keys may mis-map, but **printable text
  still works** (it rides the `text` field with `keycode 0`).

**Copy / paste.** DOM `paste` → `e.clipboardData.getData("text")` → `text/plain` `/input`
(newlines become real Enter via `keySpecs(forText:)`); DOM `copy`/`cut` +
`stream.term.getSelection()` → `e.clipboardData` synchronously (via `writeSelectionToEvent`). Using the clipboard
event rather than `navigator.clipboard` means copy/paste work without a secure context;
there is no on-screen Copy button, and the Send field is the manual fallback for typing.

**Reconnect-on-refocus (universal).** A `visibilitychange` handler does a **clean
resync** of the active stream on foreground (`document.visibilityState === "visible"`
→ `showSurface(current, curEl.textContent, false)` = dispose + re-open the stream,
idempotent, replaying the host ring and rebuilding xterm.js state); with no surface
selected it just refreshes the sidebar (`loadList()`). This covers a backgrounded tab
(phone or laptop) whose stream silently stalled — the same reconnect `exitFrameMode`
uses.

**Resize is a non-goal** (inherited): the client VIEWS at the host's grid size
(`term.resize` sizes only the xterm.js client) and never resizes the PTY, sidestepping
the two-clients-one-PTY size conflict.

**Security reuse.** No new auth model or attack surface: `GET /` passes through the
SAME `decideRoute` gate (Host-header allowlist, token gate, per-peer failed-auth
backoff, per-connection bounds) as every route.

Wiring (all `WebMonitorServer.swift`): the SINGLE `htmlPage` static string carries the
responsive layout + capability gates + the universal keydown/copy/paste/reconnect
wiring; the `keySpecs(forKey:)` general `ctrl-<letter>` rule + `ctrlLetterKeycodes`
table is the only server-side addition. (The former `/desktop` route,
`RouteDecision.desktopPage`, `isBootstrapPath("/desktop")`, and `desktopHtmlPage` are
**removed** — one page, one route.) Tests (`WebMonitorServerTests.swift`): the
`htmlPage*` content guards (`htmlPageHasResponsiveSidebar` — the `data-view` machine +
860px breakpoint, `htmlPageReusesXtermAssets`, `htmlPageHasGlobalKeydownWiring`,
`htmlPageHasCopyPasteHooks`, `htmlPageHasReconnectOnRefocus`,
`htmlPageHasThemeAwareChromeAndPollFallback`, and the layout/state-machine guards
`htmlPageDataViewStateMachineTransitions`, `htmlPageSidebarHideRuleIsNarrowOnly` (the
sidebar-hide rule stays inside the narrow `@media`), `htmlPageViewHeaderWrapsAndHidesMacNoteOnNarrow`,
`htmlPageBannersAreTopLevelChrome`, `htmlPageHasBackToListControl`,
`htmlPageKeydownBailsInTypingFields`); the `keySpecs` extension tests
(`keySpecsCtrlLetterIsRealCtrlKeyEvent`, `keySpecsCtrlLetterCoversAllTwentySixLetters`,
`keySpecsCtrlCAndCtrlUUnchangedByGeneralRule`, `keySpecsUnknownCtrlComboIsNil`).

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
stream. The page streams those bytes over **Server-Sent Events** (`stream-sse`, see below);
`term.resize()`s `xterm.js` to the host grid so cursor-addressed TUIs render aligned.
**Without `pty-host`** (or if the stream can't start → 501) the page falls back to the
plain-text snapshot poll.

### iOS-safe live transport = SSE, NOT a `fetch()` byte stream (fork-only, GUI/page-only)

**Symptom this fixes:** on iOS Safari the terminal preview showed **stale** content — you had to
maximize/restore or reload to force a reconnect, then it went stale again; desktop Chrome and
Android Chrome were fine. **Root cause:** iOS WebKit **buffers** a `fetch().body.getReader()`
response — it delivers stream chunks in large batches, so a low-rate terminal (the common case)
sits in WebKit's buffer and never reaches the reader until enough bytes accumulate. A reconnect
replays the host ring buffer as one burst (clears the buffer threshold → looks current), then it
freezes again as new bytes trickle in. Chrome/Blink (desktop + Android) delivers incrementally,
so only iOS was affected.

**Fix (page transport swap, no host/Zig change):** the same host bytes now stream as
**Server-Sent Events**, which `EventSource` delivers incrementally on every browser. Both the
`.raw` and `.sse` framings reuse the identical resolve + `WebMonitorHostClient` pipe (a
`StreamFraming` param on `routeStream`/`startStream`); `.sse` differs only in:
- **Head** `sseStreamResponseHead()` → `Content-Type: text/event-stream` (+ `no-store,
  no-transform`, `nosniff`, `Connection: close`, no `Content-Length`).
- **Grid size in-band** `sseSizeEvent(cols,rows)` → `event: size\ndata: {"cols":C,"rows":R}\n\n`
  written BEFORE any output frame (EventSource can't read the `X-Ghostty-Cols/-Rows` headers the
  raw stream uses). The page listens for `event: size` and `term.resize`s first.
- **Per-chunk frame** `sseDataFrame(bytes)` → `data: <base64>\n\n` (base64 is single-line and
  survives SSE's UTF-8/newline framing; the page `b64ToBytes`→`term.write(Uint8Array)` so xterm
  does its own UTF-8 decode, byte-exact — multi-byte glyphs split across chunks reassemble).
- **Keepalive** a repeating `sseKeepalive` comment (`: keepalive\n\n`, every
  `sseKeepaliveInterval`=25s) so an idle/silent stream isn't dropped by iOS / an intermediary —
  its own `streamKeepaliveTimers` timer, cancelled in the `.cancelled/.failed` state handler,
  the host client's `onClose`, and `stop()`.
- **Auth** EventSource can't set a header, so `stream-sse` accepts `?token=` — the ONE
  non-bootstrap route in `acceptsQueryToken` (`isBootstrapPath || isStreamSSEPath`); the raw
  `/stream` stays header-only, and every other `/api/*` route still ignores the query token.
- **Reconnect model** the page does NOT rely on EventSource's silent auto-reconnect (a
  reconnect re-subscribes → the host replays its ring → **duplicate** output on the same
  terminal). On `es.onerror` it `close()`s and falls back to the `/screen` poll (which cleanly
  detects a 404 → "Session closed."); the existing `visibilitychange` resync / reselecting the
  split re-opens a fresh live view. This is the same fall-back-then-recover shape the old
  `fetch` path used, and it is why background tabs behave the same as before (iOS suspends a
  backgrounded tab for ANY transport — the `visibilitychange` handler is the real resume path).

The raw `.raw`/`application/octet-stream` `/stream` route is kept (still routed + tested) as an
alternative but the page no longer uses it. GUI/page-only — relaunch, no host restart.

### Mobile input fixes (fork-only, GUI/page-only)

- **Autocorrect on the Send field.** iOS honors `autocorrect`/`spellcheck` (Android largely
  ignores them), so the Send `#inp` explicitly-off attributes meant "redume" was never corrected
  to "resume". Now `autocorrect="on" spellcheck="true"` (with `autocapitalize="off"` so a typed
  shell command isn't capitalized). The token `#tokeninput` stays strict-off — a secret is never
  autocorrected.
- **First-tap-eaten on iOS.** While the Send field is focused (soft keyboard up), iOS consumes
  the FIRST tap on a button dismissing the keyboard, so a `click`-wired button only fired on the
  2nd/3rd tap. `keepFocusOnTap` `preventDefault`s `pointerdown`/`mousedown` on the static buttons
  so the tap no longer reads as "dismiss keyboard" — the `click` fires on the first tap and the
  field keeps focus (keyboard stays up for the next reply). Keyboard Tab-activation is unaffected
  (only pointer focus-steal is prevented). The auto-repeat buttons already acted on
  `pointerdown`, which is why arrows/scroll always worked first-tap.

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
needs `pty-host`); `GET /api/surface/{uuid}/frame` (host authoritative ANSI frame with color, via
`ghostty_surface_read_ansi`; for frame-mode scrolling; 501 without `pty-host`); `GET
/api/surface/{uuid}/screen?mode=viewport|scrollback` (plain-text
fallback, reuses `cachedVisibleContents`/`cachedScreenContents`); `POST
/api/surface/{uuid}/input`; `POST /api/surface/{uuid}/scroll` (`{"dy":±ticks}`); `POST
/api/surface/{uuid}/hidden` (`{"hidden":bool}` → toggle the Agent Dashboard hide set, see the
hide note below); `POST /api/new-tab` (open a fresh tab on the Mac → `{ok:true,id:<uuid>}`, see
the new-tab note below); `POST /api/surface/{uuid}/split` (packed split in that tab →
`{ok:true,id}`) and `POST /api/queue/max-items` (`{run,delta?}` → `{ok:true,maxItems}`), see
their notes below.

Status codes: Unknown id/path → 404, wrong method → 405, bad/negative/oversized
Content-Length → 400, chunked → 411, oversized → 413, bad Host → 403, throttled (token mode)
→ 429; `/hidden` → 503 when the dashboard isn't running; `/api/new-tab` → 500 when nothing
was created; `/split` → 404 when the anchor is gone or the split failed; `/api/queue/max-items`
→ 400 bad body / 404 unknown run / 409 unlimited cap / 503 dashboard not running.

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

### Hide a split from the phone (fork-only, GUI-only) — per-row Hide/Show

Each list row has a **Hide/Show** button (shown only when the dashboard is running) that toggles
the **SAME** persisted, UUID-keyed hide set as the dashboard eye-slash button /
`hide_dashboard_split` keybind — so hiding from the phone IS a dashboard hide, and the existing
**Hide hidden** filter then drops it (auto-unhide-on-bell still applies). Route `POST
/api/surface/{uuid}/hidden` (body `{"hidden":bool}`; lenient — accepts a JSON bool, `0`/`1`, or
`"true"`/`"false"` via the pure `hiddenFlag(body:)`). The handler hops to main and calls
`AppDelegate.setWebMonitorHidden(surfaceID:hidden:)` (wrapped in `MainActor.assumeIsolated` like
`surfacesJSON()`'s dashboard read), which lazily creates the controller (like the keybind handlers,
so a hide persists even with the panel closed) and calls `AgentDashboardController.setHidden(...)`
→ `model.hide`/`model.show`. Returns 503 when no dashboard controller exists (the button is hidden
then anyway). The `hidden` flag is by UUID and independent of whether the surface is live, so it
succeeds even for a not-currently-resolvable surface. NOTE the `/api/surfaces` response is cached
~1s (`surfacesCacheTTL`), so a freshly-toggled hide shows up on the next list refresh, not
instantly. ZERO host/Zig change; GUI relaunch. Wiring: `WebMonitorServer.swift`
(`.setHidden` route + `hiddenFlag` + handler), `AppDelegate.swift` (`setWebMonitorHidden`),
`AgentDashboardController.swift` (`setHidden(surfaceID:hidden:)`), page `loadList` row Hide/Show
button + `setHidden(id,hidden)`. Tests: `WebMonitorServerTests`
(`decideRouteSetHiddenPost`/`…GetMethodNotAllowed`, `hiddenFlagDecode`).

### Open a new tab from the list (fork-only, GUI/page-only) — ＋ New tab

A **＋ New tab** button in the list screen (above `#list`, so it shows in BOTH the wide sidebar
and the narrow drawer — one DOM) opens a fresh Ghostty tab on the Mac and navigates the page
straight into it. Route `POST /api/new-tab` — **NOT surface-scoped** (no `{uuid}`), header-token
gated like every `/api/*` route (it is not a bootstrap path, so a query `?token=` is rejected —
`decideRouteNewTabIsNotABootstrapPathSoQueryTokenIsRejected` guards this).

The handler hops to main (`respondFromMain` + `MainActor.assumeIsolated`, like `setHidden`) and
calls **`MCPLayout.newTabReturningID(cwd:nil, command:nil, sourceUUID:nil)`** — a new UUID-returning
core that `MCPLayout.newTab` (the Bool the MCP `new_tab` tool uses) now delegates to, so the MCP
path is untouched. No source ⇒ the tab opens in the **frontmost terminal window** (a brand-new
window if none is open), exactly like ⌘T / the MCP tool's no-source path; the new tab's split tree
is populated SYNCHRONOUSLY so the created leaf's id is read back immediately (`surfaceTree.first?.id`).
It returns `{ok:true,id:<uuid>}`, or **500** if nothing was created.

**The auto-navigate is load-bearing, not a nicety.** A brand-new plain shell isn't a detected CLI
agent, so with the default **Agents only** filter ON it would never appear in the list — the button
would look like a silent no-op. On `{id}` the page calls `showSurface(id, "New tab", false)` and
jumps into the new surface's live view (the id is the same `.uuidString` form the list rows use, so
`highlightActive` matches). The button is **disabled while the POST is in flight** to swallow
double-taps, re-enabled on completion, and a failure shows a sticky banner (a 401 pops the
token-recovery box, matching `loadList`). ZERO host/Zig/protocol change; GUI relaunch only. Wiring:
`WebMonitorServer.swift` (`RouteDecision.newTab` + the `/api/new-tab` route arm + the handler), page
`#listactions`/`#newtab` button + CSS + `newTab()` + `newTabBtn.onclick`; `MCPLayout.swift`
(`newTabReturningID` core + the thin `newTab` Bool wrapper). Tests: `WebMonitorServerTests`
(`decideRouteNewTabPost`/`…GetMethodNotAllowed`/`…IsNotABootstrapPathSoQueryTokenIsRejected`,
`htmlPageHasNewTabControl`, `htmlPageNewTabButtonSitsAboveTheList`).

### Add a packed split from the list (fork-only, GUI/page-only) — per-tab ＋ Split

Each tab's `.grouphdr` in the list carries a `.splitbtn` "＋ Split" (deliberately in the LIST, not
the viewer toolbar — the terminal view's real estate is the scarce resource). It POSTs
`/api/surface/{uuid}/split` with the tab's FIRST visible row as the anchor — any pane of the tab
works, since the anchor only selects the TAB. Surface-scoped, POST only, header-token only (not a
bootstrap path, so `?token=` is rejected — `decideRouteSplitRejectsQueryToken`).

**No direction on the wire, by design.** The remote viewer can't see the physical layout, so the
Mac chooses: `MCPLayout.newPackedSplitReturningID(anchorUUID:)` mirrors the Agent Queue's balanced
spawn — `largestLeafSplit(within:)` (real pixel bounds, no grid caps) picks where the pane is born,
then `retileCompactGrid(order: before + [new], focus: new, maxCols: densestGridColumns(N), maxRows: 0)`
rebuilds the tab into the densest grid (`ceil(√N)` columns = `SplitTree.compactedToDensestGrid`,
i.e. `compact_splits`), the new pane LAST in row-major order. Passing a real `maxCols` is what
makes `retileCompactGrid` act (it no-ops without a cap). This DOES reshuffle the tab's existing
layout — the same trade the queue and `compact_splits` make. The new surface's config is
`ghostty_surface_inherited_config(…, GHOSTTY_SURFACE_CONTEXT_SPLIT)` from the tab's focused pane
(falling back to the anchor), i.e. ⌘D semantics (cwd, etc.). It TAKES Mac focus (`newSplit` +
the re-tile's `moveFocusTo`) — unlike ⛶ Maximize, you're creating the pane to use it.

The page navigates into `{id}` (`showSurface(data.id, "New split", false)`) for the ＋ New tab
reason (a plain shell is dropped by "Agents only"), and that also sidesteps the stale-grid
problem: every pane in the tab re-grids, and the new split opens a fresh, correctly-sized stream.
A tab entirely filtered out of the list has no header, so no ＋ Split — relax the filters to reach
it. In a queue's tab the extra pane is a plain shell the queue doesn't own; its next pack/re-tile
treats the tab as it finds it. The button is disabled while in flight; failures raise a sticky
banner (401 → token recovery). Wiring: `WebMonitorServer.swift` (`RouteDecision.newSplit` + the
`split` arm + handler; page `.splitbtn` CSS + group-header button + `newSplit()`), `MCPLayout.swift`
(`newPackedSplitReturningID` + pure `densestGridColumns`). Tests: `decideRouteSplit*`,
`htmlPageHasPerTabSplitControl`, `densestGridColumns`.

### +1 max items on a queue run (fork-only, GUI/page-only) — Queues section

`/api/surfaces` gains a top-level `queues` array (`QueueRow` = `{run, phase, active, queued,
dispatched, maxItems}`, `maxItems` JSON `null` = unlimited), projected from the dashboard model's
`queueStatuses` via `AgentDashboardController.webMonitorQueues()` (sorted by name) inside
`surfacesJSON()`'s existing on-main `assumeIsolated` read. So it rides the list's existing refresh
+ ~1s cache — no new poll. The page's `renderQueues()` (called in `loadList` BEFORE the "no
sessions" early returns) fills `#queues` (above `#list`, hidden when empty): `name · phase ·
dispatched/cap · [+1]`.

`POST /api/queue/max-items`, body `{"run":<name>,"delta"?:<int>}` — NOT surface-scoped, and the run
rides the BODY (run names carry spaces/`·`). Pure `queueBumpRequest(body:)` requires a non-empty
trimmed string `run` and an integer `delta` in `1…maxQueueBumpDelta` (100; default 1; a JSON bool
is rejected rather than read as 1). The handler calls
`AppDelegate.webMonitorBumpQueueMaxItems` → `AgentDashboardModel.bumpQueueMaxItems(run:by:)`,
which computes the new cap **on main from the model's current status**, not the page's copy:
`QueueStatus.bumpedCap = max(maxItems, dispatched) + delta`. Two load-bearing consequences: (1)
rapid taps compound (11, then 12) because `setQueueMaxItems` updates `queueStatuses`
OPTIMISTICALLY before the sidecar's next push; (2) a cap lowered below the lifetime count still
frees exactly `delta` dispatches instead of a +1 that changes nothing. It then posts through the
existing `setQueueMaxItems` → `set_max_items` path (the dashboard cap editor's), so NO sidecar
change. Outcomes: `.bumped(N)` → `{ok:true,maxItems:N}`; `.unlimited` → 409; `.unknownRun` → 404;
no dashboard → 503 (unlike `/hidden`, it does NOT lazily create the controller — no dashboard, no
queue runs). The page disables +1 for an unlimited cap and while its POST is in flight
(`queueBumping[run]`, survives re-renders), paints the returned cap immediately, then reloads the
list after the ~1s cache TTL. Wiring: `WebMonitorServer.swift` (`RouteDecision.queueMaxItems` +
route + handler, `queueBumpRequest`, `QueueRow`, `surfacesJSONData(queues:)`; page `#queues` CSS/DOM
+ `renderQueues`/`bumpQueue`/`queueMeta`), `AgentDashboardController.swift`
(`AgentDashboardModel.MaxItemsBump` + `bumpQueueMaxItems`, `webMonitorQueues`,
`webMonitorBumpMaxItems`), `QueueCommandBridge.swift` (`QueueStatus.bumpedCap`), `AppDelegate.swift`
(`webMonitorBumpQueueMaxItems`). Tests: `WebMonitorServerTests` (`decideRouteQueueMaxItems*`,
`queueBumpRequestDecode`, `surfacesJSONCarriesQueues`/`…QueuesDefaultsEmpty`,
`htmlPageHasQueuesSectionAboveTheList`), `AgentQueueHealthTests` (`bumpedCapRaises…`,
`bumpQueueMaxItemsCompounds…`, `bumpQueueMaxItemsUnlimitedAndUnknownRun`).

### Maximize a split from the phone/laptop (fork-only, GUI/page-only) — ⛶ Maximize/Restore

**The whole point:** what a viewer renders is the host session's GRID, and the grid is sized by
the pane on the Mac. A split squeezed into a corner of a busy tab therefore shows a tiny viewport
remotely, and NOTHING page-side can fix that — there is exactly one grid per session. So the only
lever is to make the pane bigger, which is precisely `toggle_split_zoom`.

Route `POST /api/surface/{uuid}/maximize`, body `{"maximized":bool}` — an EXPLICIT SET, not a
toggle, so a client working from a stale list can't invert the state it thinks it's changing.
Body parsing is the lenient pure `maximizedFlag(body:)`; it and `hiddenFlag` now both delegate to
a shared `boolFlag(body:key:)` so the two set-a-flag routes can't drift.

The handler resolves `controllerAndView(forUUID:)` and sets the tab's zoom **DIRECTLY** —
`controller.surfaceTree = .init(root: root, zoomed: node)`, the same `SplitTree(root:zoomed:)`
reset `revealIfZoomedAway` performs. **Deliberately NOT `MCPLayout.performAction("toggle_split_zoom")`**,
which FOCUSES the surface first: a remote "let me see more" gesture must not yank the Mac's
keyboard focus (and, via the sustained-focus debounce, potentially dismiss a bell).

The decision is the pure, fully-tested `maximizeOutcome(want:leafCount:isZoomedHere:)` →
`.zoom` / `.unzoom` / `.noop(maximized:)` / `.unsupported`:
- **`.unsupported` (409) — maximizing a SINGLE-PANE tab.** There is no other pane to take space
  from, so it would silently do nothing. The page DISABLES the control off the row's
  `splitCount`; the 409 is the backstop for a stale client. (RESTORING a single-pane tab is a
  plain `.noop`, not unsupported — the objection only applies to maximizing.)
- **Restore is honored only when THIS surface is the zoomed one** (`isZoomedHere`, via
  `tree.zoomedLeaves()`). Otherwise it's a `.noop`: a stale client must not clear a zoom someone
  set on the Mac for a DIFFERENT split.

`SurfaceRow` gains `maximized` (defaulted like `hero`), computed once per tab from
`Set(c.surfaceTree.zoomedLeaves().map(\.id))` and emitted on every `/api/surfaces` row; paired
with the pre-existing `splitCount`, that row IS the single source of truth for the button's
label + disabled state (`setMaximizeState(row)`, fed by both `refreshBellButton` and the
`loadList` timer, so the control self-corrects when someone zooms/unzooms on the Mac).

**⚠️ The load-bearing page-side detail: the stream MUST be reconnected after the resize.**
`openStream` sizes xterm.js EXACTLY ONCE from the `X-Ghostty-Cols`/`X-Ghostty-Rows` response
headers, and there is no mid-stream resize signal — so leaving the old size against a re-gridded
host wraps and clips the re-emulated output. After a successful POST the page waits
`maximizeReconnectDelay` (450ms, for the SwiftUI relayout + host resize round-trip to settle) and
calls `showSurface(...)`, the same dispose+reopen `exitFrameMode` uses. The button also `blur()`s
itself on click, because a focused `BUTTON` makes the global keydown driver bail (`isTypingField`)
and would silently kill desktop keyboard driving.

**Accepted behaviors (all deliberate).** The PTY resizes both ways so the program reflows
(SIGWINCH) on maximize AND on restore — identical to pressing the zoom keybind on the Mac. A
maximize left on PERSISTS across a GUI restart (`SplitTree`'s `Codable` encodes the `zoomed`
path, and the fork forces window-state restoration on). Per-tab exclusivity is free — `zoomed` is
a single field, so maximizing another split in the same tab just moves the zoom. Sibling splits
are HIDDEN, not resized (they leave the view hierarchy and keep their grid), so the other agents
in that tab are undisturbed; the cost is that their bells degrade to the `zoomedHiddenBell` badge
and their dashboard tiles take the zoom-hidden geometry path `hostGeomBox`/`mergeHostGeom` already
covers. `SplitTree.inserting`/`combined`/`resizing` all reset `zoomed` to nil, so a queue spawning
into that tab or any resize silently clears the maximize — a fail-safe, not a bug.

**⚠️ Header ORDER is layout, not cosmetics: `#maximize` must come BEFORE `#cur`.** `#cur` (the
title) is `flex: 1 1 auto` and grows to fill the header, so anything placed after it is the first
thing pushed onto a second row once `#viewhdr` wraps on a narrow viewport — which is exactly what
the button did when it first shipped after the title (a wasted header row). Placing it between
`#menubtn` and `#cur` packs it beside the ← Sessions control and lets the title ellipsize around
it (`#cur` is `min-width: 0` + `text-overflow: ellipsis`, so it shrinks rather than wrapping the
row). On wide layouts `#menubtn` is `display: none`, so Maximize simply leads the header. Locked
by `htmlPageMaximizeSitsBesideTheBackControl`.

ZERO host/Zig/protocol change; GUI relaunch only. Wiring (all `WebMonitorServer.swift`):
`RouteDecision.setMaximized` + the `"maximize"` route arm + the handler; `boolFlag`/`hiddenFlag`/
`maximizedFlag`; `MaximizeOutcome`/`maximizeOutcome`; `SurfaceRow.maximized` + `surfacesJSON`
population + `surfacesJSONData` emit; page `#maximize` button + CSS + `setMaximizeState` +
`maxBtn.onclick` + `maximizeReconnectDelay` + the `loadList`/`refreshBellButton`/`showSurface`/
`showPlaceholder` hooks. Tests: `WebMonitorServerTests` (`decideRouteSetMaximizedPost`/
`…GetMethodNotAllowed`, `maximizedFlagDecode`, `maximizeOutcomeSinglePaneTabIsUnsupported`/
`…ZoomsAndUnzooms`/`…IsIdempotent`/`…RestoreOfANonZoomedSplitLeavesTheTabAlone`/
`…RestoreOnSinglePaneIsANoop`, `surfacesJSONEmitsMaximized`, `htmlPageHasMaximizeControl`,
`htmlPageMaximizeIsDisabledOnASinglePaneTab`, `htmlPageMaximizeReconnectsTheStream`,
`htmlPageMaximizeSitsBesideTheBackControl`).

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
(available as quick-keys; not used by the scroll path anymore).
**Press-and-hold auto-repeat** (`addRepeat`: 350ms delay → 90ms repeat; `touch-action:none` +
preventDefault) on scroll/arrows/backspace only; the rest are single-fire.

**Smart scroll (`smartScroll`, page-side) + the position fix (server-side).** The load-bearing
facts, and the fix for the previously-dead Claude Code scroll:
- A full-screen TUI (Claude Code, `htop`, `vim`+mouse) runs on the **alt-screen with mouse tracking
  ON**. Under `.client` the host's ModeFrame syncs `mouse_event` onto the GUI's local terminal, so
  `Surface.scrollCallback` takes the `isMouseReporting()` branch and encodes the wheel as an **SGR
  mouse event AT `getCursorPos()`**, forwarded to the child; the child scrolls its own view and
  redraws, which streams back to the phone **in color**. This is the desktop wheel's exact path.
- **Bug 1 (wheel ignored):** the web monitor never moved a mouse, so `getCursorPos()` was the default
  **(0,0)** — the top row (Claude's header) — and the app ignored the wheel. The desktop works only
  because the pointer sits over the transcript. **Fix:** call `ghostty_surface_mouse_pos` to seed the
  cursor at the surface CENTER. `mouse_pos` takes **logical points** ×`content_scale`, and
  `ghostty_surface_size` returns **physical px**, so center = `width_px / backingScaleFactor / 2`
  (default scale 2.0 when the view has no window).
- **Bug 2 (scroll capped ~1 screen — "scrolls up 3-4× then stops"):** seeding is a mouse MOVE, and
  Claude RESETS its scroll on a move (`?1003` any-event tracking). Seeding before EVERY wheel meant
  each POST reset then scrolled a little — never accumulating (proven: a single `dy=30` reached
  deeper than 25×`dy=3`, because fewer moves = deeper). **Fix:** seed ONLY on the FIRST scroll of a
  viewing — server seeds iff the body has `{"seed":true}` (pure `scrollSeed`); the page sends it once
  per surface (`scrollSeededFor`, reset in `showSurface`) then bare wheels. The cursor position
  persists on the surface, so later wheels land in the transcript without a move → consecutive scrolls
  ACCUMULATE, exactly like the desktop's one-move-then-many-wheels (wheels carry a position but Claude
  resets only on a MOVE, else the desktop wouldn't accumulate either). Verified live: `vim -c 'set
  mouse=a'` and Claude Code scroll from the phone, bidirectionally.
- **The page (`smartScroll`) can't trust `xterm.js`'s mode.** The phone's `xterm.js` only sees bytes
  since it connected, so an app that enabled alt-screen / mouse tracking BEFORE connect (a
  long-running Claude Code) looks like a plain normal buffer here (`buffer.active.type` /
  `modes.mouseTrackingMode` are wrong). The one reliable local signal is `term.buffer.active.baseY`
  (local scrollback depth), so the decision is: `baseY>0` (a shell, or anything with real newlines) ⇒
  `term.scrollLines(∓3)` LOCALLY, in color, no round-trip; `baseY==0` (full-screen TUI) ⇒
  `sendScroll(±3)` — a real host wheel, and the HOST applies the app's REAL mode (SGR wheel for a
  mouse app, alternate-scroll arrows otherwise). No live `xterm` (poll fallback) ⇒ the poll loop
  reads the host-scrolled mirror, so a plain host wheel suffices.
- **Bug 3 (garble — the wheel reaches the app, but the scrolled redraw is interleaved).** The phone's
  `xterm.js` RE-EMULATES the raw byte stream, and its emulation of the app's scroll-region redraw
  DRIFTS from the host's during a multi-step scroll (proven by feeding the same captured bytes to a
  headless xterm.js: idle frames matched the host exactly — so it is NOT a character-WIDTH issue — but
  a scrolled frame diverged, while the host's own `/screen` render stayed clean). The desktop never
  drifts because it displays the host's AUTHORITATIVE render, not a re-emulation. **Fix — frame mode:**
  a `baseY==0` scroll stops trusting xterm.js's emulation and instead PAINTS the host's authoritative
  frame. `GET /api/surface/{uuid}/frame` → `ghostty_surface_read_ansi` → `RenderState.dumpAnsi`
  serializes the GUI's render mirror to a self-contained ANSI frame: `ESC[2J`, then per row `CUP` +
  per-cell SGR (via `Style.formatterVt()` with the palette set, so colors are EXACT RGB — a client
  with a different default palette matches precisely) + `ESC[K`; never a newline, so it repaints in
  place without scrolling the client or growing scrollback. The page (`smartScroll` → `enterFrameMode`
  / `paintFrame`) drives the wheel then writes the frame into xterm.js (full repaint = clean AND
  color), and PAUSES the live pump (`if (!frameMode) term.write(...)` in `openStream`) so re-emulated
  bytes don't fight the painted frame. **● Live**/Back (`exitFrameMode`) snaps the app to the bottom
  and RECONNECTs the stream — the paused pump left xterm.js's internal state (scroll region, cursor,
  modes) stale, so a full replay-resync is needed rather than just resuming. `dumpAnsi`/`read_ansi`
  are DEAD CODE in `ghostty-host` (only the GUI's `.client` mirror ever calls them), so this is a
  lib/xcframework rebuild with **no host restart / no session loss** (same as `mirror_grid_size`).
- *Aside:* a host-side `scroll_viewport` emits no bytes back on `raw_output` (it repins the mirror,
  not the child), so this is NOT viewport scrolling — the wheel goes to the child. And Claude renders
  its transcript inside a fixed sub-region (`ESC[2;41r` + `CSI S`), so its scrolled-off lines don't
  enter the terminal's own scrollback; the wheel scrolls Claude's IN-APP transcript.

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

### Hero push (fork-only / Hero Agents — distinct glyph + `kind`)

A hero (see `HERO-AGENTS.md`) is queue work that competes for the user's attention and lives in
its own tab; an idle hero pushes with a DISTINCT ⭐ glyph so the phone shows a *hero* is waiting,
not routine work. This reuses the EXISTING bell/attention + Web Push plumbing — no new delivery
mechanism, no new route, no host/Zig change.

- **`PushKind.hero`** joins `.bell`/`.attention` in `WebPushManager`. `PushKind.payloadValue`
  maps the cases to `"bell"`/`"attention"`/`"hero"`. Because the per-surface debounce key is
  `(id, kind)`, the hero kind self-debounces INDEPENDENTLY — a chatty bell can't swallow the
  headline hero push (or vice-versa).
- **Two pure, unit-tested seams** build the notification: `WebPushManager.pushTitle(glyph:rawTitle:)`
  → `"<glyph> <title>"` (or `"<glyph> Ghostty"` when the title is empty) — 🔔 for bell/attention,
  ⭐ for hero — and `WebPushManager.pushPayload(title:body:surface:kind:)` → the payload dict
  `{title, body, surface, kind}`, where `kind` is the raw `PushKind.payloadValue` so the
  page/service worker can tell a hero push apart. `onBell`/`onAttention`/`onHero` all fan out
  through the SAME `enqueuePush`; only the glyph + kind differ (`onHero`'s body prefers the
  "needs input" message over the pwd, like `onAttention`).
- **Routing.** The hero verdict rides the EXISTING `.ghosttyAgentNeedsAttention` path. When a
  surface enters `.waiting`, `AgentDashboardController.postNeedsAttention` reads the stored
  `queueHero` annotation and adds `AgentStateUserInfoKey.hero: Bool` to the userInfo;
  `WebPushManager`'s observer calls `onHero` (⭐, `kind:"hero"`) when that flag is true, else
  `onAttention` (🔔). Absent flag ⇒ regular attention push (back-compat).

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
  Notify toggle + `/sw.js` + `/api/push/*`; the ⛶ Maximize route `.setMaximized` +
  `maximizeOutcome` + `SurfaceRow.maximized` + the page's Maximize/Restore control; the ＋ New tab
  route `.newTab` + `/api/new-tab` handler + the page's `#newtab` button + `newTab()`; the ＋ Split
  route `.newSplit` + the page's per-tab `.splitbtn` + `newSplit()`; the queue +1 route
  `.queueMaxItems` + `queueBumpRequest` + `QueueRow`/`queues` + the page's `#queues` +
  `renderQueues()`/`bumpQueue()`)
- `macos/Sources/Features/MCP/MCPLayout.swift` (`newTabReturningID` — the UUID-returning new-tab
  core the ＋ New tab route uses; `newTab` is now a thin Bool wrapper over it, so the MCP `new_tab`
  tool is unchanged; `newPackedSplitReturningID` + `densestGridColumns` for ＋ Split)
- `macos/Sources/Features/WebMonitor/WebMonitorPush.swift` (`WebPushCrypto` + `WebPushManager`;
  Hero Agents: `PushKind.hero`/`payloadValue`, `onHero`, pure `pushTitle`/`pushPayload` seams,
  the `AgentStateUserInfoKey.hero`→`onHero` route in the attention observer)
- `macos/Sources/Features/AgentDashboard/AgentDashboardController.swift`
  (`postNeedsAttention` adds `AgentStateUserInfoKey.hero` off the surface's `queueHero`
  annotation so the observer routes to `onHero`)
- `macos/Sources/Features/WebMonitor/WebMonitorHostClient.swift` (host-protocol client)
- `macos/Sources/Features/WebMonitor/vendor/xterm.{js,css}`
- `src/host/{Session,Server,protocol}.zig` + `src/termio/Termio.zig` (raw-tee + ring + frames
  + observer)
- `macos/Sources/App/macOS/AppDelegate.swift` (start/stop)
- `macos/Ghostty.xcodeproj/project.pbxproj` (iOS exclusion of the new macOS-only files)

### Tests

- `macos/Tests/WebMonitor/WebMonitorServerTests.swift` (auto-discovered by the `GhosttyTests`
  filesystem-synchronized group; Hero Agents: `WebPushPayloadTests` — the `pushTitle` ⭐/🔔 glyph
  + empty-title fallback and the `pushPayload` `kind` field)
- host frame/ring/integration tests in `src/host/test.zig` (`zig build test
  -Dtest-filter=host`)

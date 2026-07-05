# Design: "Desktop mode" for the web monitor — a standalone desktop web client

> **STATUS: SUPERSEDED — the separate-page design below was NOT the shipped shape.**
> This document proposed a **standalone second page** at `GET /desktop`
> (`desktopHtmlPage` + `RouteDecision.desktopPage` + `isBootstrapPath("/desktop")`),
> framed to respect a "phone-only, frozen `htmlPage`" scope lock. **That governance
> was subsequently changed:** the web monitor is now **ONE responsive,
> capability-adaptive page** (`htmlPage`, served at `GET /`) that serves BOTH phone
> and desktop — there is **no `/desktop` route and no `desktopHtmlPage`**. Layout is
> responsive off a single `data-view` state machine (a persistent split-picker
> sidebar on a wide screen ≥860px, collapsing to a full-width drawer on a phone), and
> capabilities are **feature-detected, never guessed from the viewport** (copy/paste
> gated on secure-context + `navigator.clipboard`; the global keydown driver attaches
> universally with a focused-form-control guard, inert without a physical keyboard).
> The one server-side change this design called for — the general `ctrl-<letter>`
> rule in `keySpecs(forKey:)` (`ctrlLetterKeycodes`, native macOS keycodes) — **did**
> ship and is kept EXACTLY as designed. It remains GUI/page-only (no Zig, no host, no
> protocol change; no host restart / no session loss). The current shape is documented
> in `WEB-MONITOR.md` (→ "Scope" / "The responsive, capability-adaptive client") and
> the `CLAUDE.md` "Web monitor" bullet. **The rest of this document is retained only as
> the historical design record** — the goals, non-goals, keyboard-fidelity analysis,
> and security reasoning below still hold, but every reference to a separate `/desktop`
> page / `desktopHtmlPage` / "standalone copy" / "the frozen phone page" is obsolete:
> read it as the ONE responsive page instead.

---

## Summary / motivation

The fork already ships a **web monitor** (`macos/Sources/Features/WebMonitor/`): a
GUI-embedded HTTP server inside the running app that, from a **phone** over Tailscale,
lists live terminal surfaces, renders **one** in full color via a vendored `xterm.js`
fed the host's raw PTY byte stream, sends input as **real key events**, and scrolls a
remote TUI via "frame mode." It is deliberately **scope-locked to phone workflows only**
(see `WEB-MONITOR.md` → "Scope — phone workflows ONLY": *"do not build new features on
it … Other work … may reuse its architecture and copy code … but should stand on its
own"*).

**Desktop mode** is a new, deliberate scope: a **standalone desktop web client** for
driving a Ghostty surface from a *second laptop* on the tailnet — a real work driver, not
a glance. It is the replacement for the abandoned "attached head" idea (a native second
Mac GUI mirroring laptop 1 one-to-one). We **explicitly rejected** native 1:1-chrome
mirroring as not worth the cost; a desktop-scale web page that reuses the monitor's
proven raw-stream + xterm.js + real-key-events + frame-mode plumbing gets ~95% of the
value for a fraction of the work, and requires **no new native app**.

The KEY difference from the phone page is layout and keyboard fidelity: a **persistent
split-picker sidebar** (you never lose the list when you enter a surface), **desktop-scale
CSS** (sidebar + large viewer, bigger fonts, uses the screen), and **full keyboard
handling** (browser keystrokes → real key events on the surface, plus copy/paste). It
respects the scope lock by **standing alone** — a separate route + page + CSS + JS served
by the *same* `WebMonitorServer`, reusing the existing host-client and streaming APIs
without modifying the frozen phone page.

**Hard limitation, stated up front (see Non-goals):** this is an "A-replacement" that
works **only while laptop 1 is awake** — laptop 1 runs the GUI, the web monitor server,
and the `pty-host` daemon that owns emulation. It does **not** survive laptop-1
hibernation and does **not** provide cloud RAM/CPU/GPU. Cloud-hosted terminals over SSH
are a **separate feature specced elsewhere**; do not conflate the two.

---

## Goals

1. A desktop-scale web client, served by the existing `WebMonitorServer`, for driving a
   single Ghostty surface from a second laptop on the tailnet.
2. **Single-surface** viewing — exactly one terminal shown at a time (like the phone).
3. A **persistent sidebar** listing all splits with the same live metadata the phone list
   shows; selecting one loads it in the main viewer **without hiding the picker**.
4. **Full keyboard fidelity** for real work: reliable modifiers, arrows, function/ctrl
   keys, browser-clipboard paste → surface, and xterm.js selection → clipboard copy.
5. **Reconnect-on-refocus**: a backgrounded tab resyncs the live stream when it returns to
   the foreground.
6. Reuse the frozen phone page's server-side plumbing; **GUI/page-only, no Zig/host
   change** (verified below).

## Non-goals (explicit)

- **NOT multi-pane.** One terminal at a time. No grid, no tiling, no simultaneous streams.
- **Never owns resize.** Desktop mode VIEWS at laptop-1's grid size; it does **not** resize
  the PTY. This deliberately sidesteps the two-clients-one-PTY size conflict (see
  "Resize is a non-goal" below).
- **No hibernation-survival.** Dead the moment laptop 1 sleeps / the host stops. RAM-only
  sessions on the host are lost on a host restart regardless.
- **No cloud compute.** No cloud RAM/CPU/GPU; that is a separate SSH-terminals feature.
- **No native chrome mirroring.** We rejected a native second-Mac GUI; this is a web page.
- **No live config reload, no new auth model, no push changes.** Inherited as-is.

---

## Current state — what the phone monitor already does (and we reuse)

All of the following exist today and are the load-bearing substrate for desktop mode.
Citations are into `macos/Sources/Features/WebMonitor/WebMonitorServer.swift` unless noted.

**Server / routing**
- One `NWListener` on a dedicated **serial** background queue; all mutable state is queue-
  serialized; handlers that touch AppKit hop to main and return only value types
  (`WebMonitorServer.queue`, class header comment lines ~45–57; threading notes in
  `WEB-MONITOR.md` → "Threading").
- **`decideRoute(...) -> RouteDecision`** is a PURE function (no AppKit/socket/mutation)
  — the security-load-bearing router (Host allowlist, token gate, per-peer backoff,
  method/path table). This is where a new desktop route is added
  (`WebMonitorServer.decideRoute`, `WebMonitorServer.RouteDecision`).
- Bootstrap routes accept `?token=` (can't set a header); `/api/*` requires the
  `X-Ghostty-Token` header (`WebMonitorServer.isBootstrapPath`, token gate in
  `decideRoute`).

**The page (single embedded HTML string, `WebMonitorServer.htmlPage`, ~line 1938)**
- `showList()` (line 2620) and `showSurface(id, title, bell)` (line 2665) **toggle
  visibility**: entering a surface sets `listEl.style.display = "none"` /
  `filterBar.style.display = "none"` and shows `viewer`; going back reverses it. **This
  hide-the-list behavior is exactly what desktop mode changes.**
- The surface list is fetched from **`GET /api/surfaces`** and rendered by `loadList()`
  (line 2313), with page-side filters: **★ Focus on heroes** (`f-heroes`), **Agents only**
  (`f-agents`), **Hide hidden** (`f-visible`) — persisted in `localStorage`
  (`ghostty_filter_heroes/agents/visible`), availability driven by `applyFilterAvailability`
  and the top-level `agentDashboard` flag (lines 2745–2750, 2340–2341).
- Live view: **`openStream(uuid)`** (line 2553) creates an `xterm.js` `Terminal`, fetches
  **`GET /api/surface/{uuid}/stream`**, reads `X-Ghostty-Cols`/`-Rows` headers and calls
  `term.resize(hc, hr)` to match the **host** grid (line 2589), then pumps raw bytes into
  `term.write(...)`. **`term.resize` sizes the xterm.js CLIENT only — it never resizes the
  PTY** (there is no `set_size` call anywhere in the input path; confirmed below).
- **Frame mode** for scrolling a full-screen app: `smartScroll(dir)` (line 2970) →
  `enterFrameMode()` (2929) drives a host wheel via `sendScroll` then `paintFrame()` (2911)
  writes the host's authoritative ANSI frame (`GET /api/surface/{uuid}/frame`) into xterm.js;
  `exitFrameMode()` (2942) snaps to bottom and **reconnects the stream to resync** — the
  "clean resync" path re-calls `showSurface(want, …)` (line 2951). Poll fallback exists when
  xterm.js isn't present or the stream fails.
- **Reconnect logic already exists.** `showSurface` disposes any prior stream and opens a
  fresh one (`disposeStream()` + `openStream` at 2681–2682), and `exitFrameMode` reuses it
  as a "reconnect → clean resync." There is also a **`visibilitychange`** handler (line 2983)
  that re-polls / re-lists on foreground — but note: **while a live xterm stream is active it
  intentionally does nothing** (`if (stream) return;`, line 2988), leaving the long-lived
  stream to keep running. Desktop mode extends this (see "Reconnect-on-refocus").

**Input = real key events (not paste)**
- Input posts to **`POST /api/surface/{uuid}/input`**; the server decodes via
  `keySpecs(body:contentType:)` (line 1291): `application/json` `{"key":…}` →
  `keySpecs(forKey:)` (line 1345); any other Content-Type → raw UTF-8 text →
  `keySpecs(forText:)` (line 1385).
- Each `KeySpec` (line 1223) is sent as a real press+release via `ghostty_surface_key`
  (`KeySpec.send`, line 1251). **`KeySpec.keycode` MUST be the NATIVE macOS virtual
  keycode** (the core resolves the physical key via `input.keycodes` `entry.native ==
  keycode`; a `GHOSTTY_KEY_*` enum value silently no-ops) — see the doc comment at lines
  1224–1228 and `keySpecs(forKey:)`: Return=36, Esc=53, Tab=48, Backspace=51,
  Ctrl-C=8+ctrl, Ctrl-U=32+ctrl, arrows 123–126, PageUp/Down/Home/End=116/121/115/119.
  Printable text rides the `text` field with `keycode 0` and `unshiftedCodepoint` set
  (`keySpecs(forText:)`).
- The phone page has **NO global keydown→key mapping**. It uses on-screen quick-key
  **buttons** (`data-key` handlers, line 2854) plus a Send text field whose only keydown
  handler intercepts Enter to "type" the field (line 2804). **Desktop mode adds the missing
  piece: a real global keydown handler.**

**List metadata available per surface** (`WebMonitorServer.SurfaceRow`, line 1459;
shaped by `surfacesJSONData`, line 1569): `id, title, pwd, window, tab, tabTitle,
splitIndex, splitCount, bell, attentionNeeded, isAgent, hidden, hero`, plus a derived
`attnIndicator` and the top-level `agentDashboard` flag. **The sidebar reuses this JSON
verbatim** — no new data.

**Security / transport** (`WEB-MONITOR.md` → "Security model", "Setup"): plain HTTP to
loopback only; reached over HTTPS via **`tailscale serve`**; optional `web-monitor-token`
(constant-time compare, `?token=` on bootstrap only, header on `/api/*`); Host-header
allowlist accepts any `*.ts.net`; per-peer failed-token backoff; per-connection bounds
(`/stream` exempt).

---

## Proposed design

### Routing / page structure — a second page on the same server

**Recommendation: a second page + asset routes on the same `WebMonitorServer`, NOT a
second server.** Rationale:

- It respects the scope lock: the phone page (`htmlPage`) is **untouched**; desktop mode is
  its own HTML/CSS/JS string and its own route decision. It "stands alone" as a page while
  sharing only the frozen plumbing (host client, `/stream`, `/frame`, `/input`, `/scroll`,
  `/api/surfaces`), which is exactly the "reuse architecture, don't extend the phone page"
  posture the scope note allows.
- It is the **lighter** option: no second `NWListener`, no second port, no second
  `tailscale serve` mapping, no duplicated auth/backoff/threading. A second server would
  duplicate all of that for zero benefit.
- The API surface it needs **already exists** and is per-surface + stateless, so two client
  pages can share it. (Two clients pointing at the *same* surface is fine for viewing; input
  races are the user's problem, same as two people at one tmux pane.)

Concretely:

- Add a bootstrap route **`GET /desktop`** → serves a new static HTML string
  `WebMonitorServer.desktopHtmlPage`. Add it to `decideRoute` as a new
  `RouteDecision.desktopPage` case, and add `"/desktop"` (and any desktop-only asset paths)
  to `isBootstrapPath` so `?token=` works from a plain link. The existing `.page` handling in
  `routeRequest` is the template to copy (line 726–728: `clearAuthFailures(peer)` +
  `send(.html(...))`).
- Desktop mode reuses the **same** vendored assets already served by `assetRoutes`
  (`/xterm.js`, `/xterm.css`, `/jetbrains-mono-{regular,bold}.woff2`) — no new asset routes
  needed. If any desktop-specific JS/CSS is large enough to warrant its own file, add it to
  `assetRoutes` (bootstrap-token-accepting) rather than inlining; but inlining into the
  single HTML string (as the phone page does) is simpler and preferred for v1.
- All data/stream/input/scroll/frame calls hit the **existing** `/api/*` routes unchanged.

You reach it at `https://<machine>.<tailnet>.ts.net:8787/desktop` (Release), i.e. the same
`tailscale serve` front end with `/desktop` appended.

### Layout — persistent sidebar + large viewer

The one structural change from the phone flow: **the picker never disappears.** Instead of
`showList`/`showSurface` toggling visibility, desktop mode renders a **fixed sidebar** on
the left (the surface list, with the same three filters) and a **main viewer** on the right
that swaps its contents when you pick a surface. Selecting a row updates the viewer in
place and marks the row active; the sidebar stays visible and keeps refreshing.

```
+----------------------------------------------------------------------------------+
| Ghostty desktop monitor         [🔔 Notify]  [● Live]  status/banner ...          |
+------------------------+---------------------------------------------------------+
| FILTERS                |  title: ~/git/project — split 2/3        [Copy] [⌫][esc]|
|  [x] Agents only       | +-----------------------------------------------------+ |
|  [x] Hide hidden       | |                                                     | |
|  [ ] ★ Focus on heroes | |   xterm.js viewer (host-grid sized, big font)       | |
+------------------------+ |                                                     | |
| SURFACES               | |   $ ...                                             | |
|  ● ~/git/project  2/3  | |                                                     | |
|    🔔 build.sh    1/1  | |                                                     | |
|  ★  agent: refactor    | |                                                     | |
|    shell          1/2  | +-----------------------------------------------------+ |
|    logs           2/2  |  [ type here ................................ ] [Send]  |
|                        |  scroll ↑ ↓ · arrows · enter · esc · tab · ctrl-c ...   |
+------------------------+---------------------------------------------------------+
```

- **Sidebar** reuses `loadList()`'s fetch + filter logic (from `/api/surfaces`) and the
  per-row rendering (title, `splitIndex/splitCount` badge, the 🔔 bell/attention glyph, the
  purple ★ hero mark, and — when `agentDashboard` is true — the Hide/Show button). This is a
  **layout/CSS refactor of the existing list rendering**, not new data or new server code.
  The active surface's row is highlighted.
- **Viewer** is the existing `openStream`/`xterm.js` path, sized to the host grid via the
  `X-Ghostty-Cols/-Rows` headers exactly as today. Frame-mode scroll (`smartScroll` /
  `enterFrameMode` / `paintFrame` / `exitFrameMode`) is carried over unchanged.
- Picking a new row while viewing one **disposes the old stream and opens the new** — reuse
  the `disposeStream()` + `openStream(id)` sequence from `showSurface` (lines 2681–2682).
  Single-surface invariant preserved: exactly one live stream at a time.
- **Poll fallback** (no `pty-host` / stream failure) works the same — the `/screen` poll
  viewer is shown in the main area instead of xterm.js.

### Desktop CSS approach

- CSS grid / flex: fixed-width sidebar (min ~260px, resizable is optional/nice-to-have) +
  a flex-fill viewer column; the xterm.js container fills the viewer and scrolls its own
  overflow. Bigger base `fontSize` for the terminal than the phone's 14 (e.g. 15–16;
  optionally a font-size control like the phone has). Sensible `min-width` on the whole page
  so it degrades gracefully on a small window.
- **Theme-aware if cheap:** honor `prefers-color-scheme` for the page chrome (sidebar,
  header, banners) with a light + dark palette. The xterm.js terminal colors come from the
  host stream (ANSI), so the terminal itself is not theme-toggled — only the surrounding
  chrome. Keep this to a `@media (prefers-color-scheme: dark)` block; do not overinvest.

### Keyboard handling (the core new work)

Add a **global `keydown` listener** on the viewer (or `document`, gated to when a surface is
focused/active) that maps a browser `KeyboardEvent` to a `POST /api/surface/{uuid}/input`
call, then `preventDefault()`s so the browser doesn't also act on it. The mapping targets
the **existing** `keySpecs` server contract, which means the page must send **native macOS
virtual keycodes** for non-text keys and the raw character for text keys:

- **Printable characters** (`e.key.length === 1`, no Ctrl/Meta): send as **text** via the
  `text/plain` body path (`sendText`-style), which the server maps through
  `keySpecs(forText:)`. This already coalesces runs and rides the `text` field. Note the
  phone's `sendText` does NOT append a newline; desktop mode should send each character (or a
  small debounced batch) as it's typed for a live-typing feel — but batching consecutive
  printables into one POST is friendlier to the core's 64-slot IO mailbox (see the
  `keySpecs(forText:)` comment at line 1385 about mailbox overflow).
- **Named / control keys**: send `{"key":"…"}` JSON for the keys `keySpecs(forKey:)` knows:
  `enter, esc, tab, backspace, ctrl-c, ctrl-u, up, down, left, right, pageup, pagedown,
  home, end, y, n, space`. Map `e.key`/`e.code` → these names client-side (e.g.
  `ArrowUp`→`up`, `Escape`→`esc`, `Enter`→`enter`, `Backspace`→`backspace`).
- **Ctrl-<letter> beyond c/u**: this is the **first real gap**. `keySpecs(forKey:)` only
  knows `ctrl-c` and `ctrl-u` today. Desktop mode needs a general Ctrl-letter path (Ctrl-D,
  Ctrl-Z, Ctrl-A, Ctrl-E, Ctrl-R, Ctrl-L, …). **Recommended: extend `keySpecs(forKey:)`**
  with a general rule — for a `key` like `"ctrl-d"`, synthesize a `KeySpec(keycode:
  <native for the letter>, mods: GHOSTTY_MODS_CTRL, unshiftedCodepoint: <letter>)`. This
  needs the native macOS keycode for each letter (A=0, S=1, D=2, … the standard NSEvent
  keyCode table). This is a **small, additive, pure change to `keySpecs(forKey:)`** (plus a
  unit test), still GUI/page-only. Alternatively, extend the JSON `{"key":…}` schema to carry
  an explicit `{keycode, mods, text}` triple so the page owns the mapping — but that widens
  the server contract more than the enumerated-name approach; prefer extending the name table.
- **Modifiers**: Shift is handled naturally by `e.key` already being the shifted character
  for printables. Ctrl composes as above. **Meta (⌘) and Alt/Option** are the hard part — see
  the gaps table.
- **Function keys (F1–F12)** and other special keys are **not** in `keySpecs(forKey:)` today.
  If needed, add them the same way (native keycodes) — treat as an optional extension, not v1
  blocking.

**Native-keycode reality (critical caveat):** the input path resolves the physical key from
the NATIVE macOS virtual keycode (`KeySpec` doc comment, lines 1224–1228, and the core's
`entry.native == keycode` match). The keycode is a **physical-position** code on a Mac
keyboard. This is **correct when the desktop client is a Mac with a standard US-ish
layout**, because the browser's `KeyboardEvent.code` (e.g. `KeyD`, `ArrowUp`) maps cleanly
to those physical positions. From a **non-Mac client** (Windows/Linux laptop) or a
substantially different physical layout, the position codes may **mis-map** — a keycode that
means "D" on a Mac may not correspond to the same physical key elsewhere, and text-bearing
keys are safer than keycode-bearing ones. **Desktop mode therefore ASSUMES a Mac client with
a standard layout** (the realistic "my other MacBook" case). What breaks off-Mac: named/
control/arrow/function keys routed by keycode may land on the wrong key or no-op; **printable
text still works** because it rides the `text` field (`keycode 0`), not a position code.
State this assumption in the UI (a one-line note) and in the docs.

> **Prefer `code` over `keyCode` for named keys.** Use `KeyboardEvent.code` (physical
> position, e.g. `"KeyC"`, `"ArrowUp"`) to derive the server `key` name, since it's the
> closest browser analog to the native positional keycode the server wants. Use
> `KeyboardEvent.key` for the *text* of printables. Do not use the deprecated numeric
> `keyCode`.

### Copy / paste

- **Paste (browser ⌘V/Ctrl+V → surface):** listen for the DOM `paste` event on the viewer,
  read `e.clipboardData.getData("text")`, and POST it via the **`text/plain` input path**
  (server maps through `keySpecs(forText:)`, which sends it as typed text — newlines become
  real Enter key events; see line 1380). This is the correct existing path and needs **no
  server change**. Reading the clipboard requires a **secure context** — satisfied by
  `tailscale serve` HTTPS (see Security). Guard on `navigator.clipboard`/`isSecureContext`
  and fall back to the Send text field if unavailable.
- **Copy (xterm.js selection → clipboard):** xterm.js tracks a text selection
  (`term.getSelection()`). Wire a `copy` DOM event (and/or a "Copy" button in the viewer
  header) to `navigator.clipboard.writeText(term.getSelection())`. Also secure-context-gated.
  This is **entirely client-side** — no server involvement.
- Mouse selection in xterm.js: leave xterm's default selection behavior on so the user can
  drag-select. (Note: a full-screen mouse-tracking TUI may capture the mouse; that's inherent
  and acceptable — the user can still copy visible text where the app isn't grabbing it.)

### Reconnect-on-refocus

A long-open desktop tab gets throttled/discarded by the browser when backgrounded. Two
layers:

1. **The browser already helps.** Chrome/Safari discard-and-reload a backgrounded tab; a
   reload re-bootstraps the whole page and re-opens the stream from scratch. Much of the
   problem is covered for free.
2. **A small `visibilitychange` handler** (extend the existing one at line 2983). The phone
   handler intentionally **skips** re-arming while a live stream exists (`if (stream)
   return;`, line 2988) — but a backgrounded stream may have silently stalled. For desktop
   mode, on `visibilityState === "visible"` **while viewing a surface**, do a **clean resync**:
   the same operation `exitFrameMode` already uses — re-call `showSurface(current, …)` (the
   analog in desktop mode: dispose + re-`openStream`). This replays the host ring buffer and
   rebuilds xterm.js state cleanly. Cheap and idempotent; safe to do on every foreground.
   Reuse the existing "reconnect → clean resync" comment/logic at line 2951 as the template.

### Resize is a non-goal (confirmed)

The current monitor **never resizes the host session.** The only `resize` call is
`term.resize(hc, hr)` in `openStream` (line 2589), which resizes the **xterm.js client** to
match the host grid read from the `X-Ghostty-Cols/-Rows` headers — the native GUI on laptop
1 owns the actual PTY grid. There is **no** `ghostty_surface_set_size` (or equivalent) on any
input/scroll/stream path. Desktop mode inherits this: it VIEWS at laptop-1's size and paints
into an equally-sized xterm.js. If the desktop browser window is smaller than the host grid,
the terminal scrolls/clips (like the phone's horizontal scroll); if larger, there is empty
margin. This deliberately avoids the two-clients-one-PTY size conflict.

---

## Keyboard fidelity — reality, gaps, mitigations

### The native-keycode reality (restated)

Input is delivered as real `ghostty_surface_key` events whose `keycode` is a **native macOS
virtual keycode** (`KeySpec`, lines 1223–1280). Text rides the `text` field with
`keycode 0`. This is faithful on a **Mac client, standard layout**; positional keycodes may
mis-map from a non-Mac client (text still works). Desktop mode assumes a Mac client.

### Browser-intercept gaps

Some keystrokes never reach the page — the browser (or OS) eats them before `keydown` fires,
or `preventDefault()` can't reclaim them. These **cannot** be delivered to the surface:

| Keystroke | What the browser does | Deliverable? | Mitigation |
|---|---|---|---|
| ⌘W | Close tab | No (some browsers block preventDefault) | On-screen button / avoid; user learns not to press it |
| ⌘T / ⌘N | New tab / window | No | n/a — OS/browser-owned |
| ⌘L | Focus address bar | No | n/a |
| ⌘Q / ⌘H / ⌘M | Quit / hide / minimize app | No | OS-owned |
| ⌘Tab | App switch | No | OS-owned |
| ⌘R | Reload page | Usually preventable, but risky | Do NOT intercept; let it reload (reconnect-on-load covers it) |
| ⌘C / ⌘V / ⌘X | Copy / paste / cut | **Repurposed** | Wire to xterm selection copy / clipboard paste (see Copy/paste) — do NOT forward as Ctrl to the shell |
| ⌘A | Select all | Repurpose or pass | Prefer letting xterm select-all in the viewer; not sent to shell |
| ⌘+ / ⌘- / ⌘0 | Browser zoom | No (usually) | Offer an in-page font-size control instead |
| F1–F12, ⌘-digits | Sometimes browser/OS shortcuts | Partial | Best-effort; intercept where preventable, document the rest |
| Option/Alt-<key> | Composes special chars / browser menus | Partial | Map Alt→ESC-prefix (meta) where the terminal expects it; document that Option-composition may differ |

**Mitigation summary:**
- The workhorse keys for a terminal — letters, digits, punctuation, Enter, Tab, Esc,
  Backspace, arrows, **Ctrl-<letter>** (once `keySpecs(forKey:)` is extended), PageUp/Down,
  Home/End — **are** deliverable and are the ones that matter for shell/TUI/agent work.
- **⌘ combos are browser/OS-owned** and mostly undeliverable. This is inherent to a web
  client and is the price of not building a native app. Repurpose ⌘C/⌘V/⌘X/⌘A for
  clipboard/selection (which is what a user expects on a Mac anyway) rather than trying to
  forward them to the shell.
- Provide the **on-screen quick-key row** (like the phone) as a fallback for anything the
  keyboard can't deliver, so no action is truly stranded.
- **Mac-client assumption**: documented in the UI and here. Off-Mac, printable text works;
  positional keys may not.

---

## Security / auth

Desktop mode **reuses the web monitor's existing security model unchanged** (confirmed in
`WEB-MONITOR.md` → "Security model", "Setup", and the `decideRoute` token gate):

- **Transport:** plain HTTP to loopback only; reached over HTTPS via **`tailscale serve`**
  (the only supported setup). The `/desktop` page is served on the same listener/port and
  fronted by the same `tailscale serve --bg --https=8787 127.0.0.1:18787` mapping.
- **Auth:** the optional `web-monitor-token`. `/desktop` is a **bootstrap** route, so it
  accepts `?token=…` once (stashed in `sessionStorage`, sent as `X-Ghostty-Token` on `/api/*`
  — same as the phone page). Open (no token) ⇒ the tailnet ACL is the whole boundary.
- **Secure context is required anyway** for the clipboard APIs (copy/paste). `tailscale
  serve` HTTPS provides it — the same secure context the phone's Web Push already depends on
  (`WEB-MONITOR.md` → "Push reuses the HTTPS you already set up"). If the page is somehow
  opened over plain HTTP, copy/paste degrade to the Send field (guard on `isSecureContext`),
  mirroring how the phone disables Notify with a "needs HTTPS" note.
- **Defense in depth** (Host-header allowlist, per-peer failed-token backoff, per-connection
  bounds) is inherited for free — it lives in `decideRoute` / the connection layer, which the
  new route passes through unchanged. No new attack surface beyond one more static HTML page.

---

## Wiring touchpoints (for the implementer)

Everything is in `macos/Sources/Features/WebMonitor/WebMonitorServer.swift` unless noted.
**This should be GUI/page-only — no Zig, no host, no protocol change** (verified: the sidebar
reuses `/api/surfaces`; the viewer reuses `/stream`/`/frame`; input reuses `/input`; scroll
reuses `/scroll`; all already exist and are per-surface + stateless).

1. **`RouteDecision`** — add `case desktopPage` (near `.page`, ~line 529).
2. **`decideRoute(...)`** — add `if path == "/desktop" { return method == "GET" ?
   .desktopPage : .methodNotAllowed }` (near the `path == "/"` branch, ~line 615).
3. **`isBootstrapPath(_:)`** — add `path == "/desktop"` (line 574) so `?token=` works.
4. **`routeRequest(...)`** — add a `case .desktopPage:` mirroring `.page` (line 726):
   `clearAuthFailures(peer); send(.html(Self.desktopHtmlPage), on: conn)`.
5. **`desktopHtmlPage`** — a NEW `static let` HTML string (sibling to `htmlPage`, ~line
   1938). Contains the desktop CSS (sidebar + viewer, theme-aware), the sidebar list
   rendering (reusing the `/api/surfaces` fetch + the three filters), the xterm.js viewer
   (reusing `openStream`/frame-mode logic), the **global keydown handler**, **paste/copy**
   handlers, and the **reconnect-on-refocus** `visibilitychange` handler. Reuse the vendored
   `assetRoutes` (`/xterm.js`, `/xterm.css`, JetBrains Mono woff2) — no new asset routes.
6. **`keySpecs(forKey:)`** (line 1345) — **extend** with a general `ctrl-<letter>` rule (and
   optionally F-keys), mapping each to its native macOS keycode + `GHOSTTY_MODS_CTRL`. Small,
   additive, pure. (Only server-side change required beyond the new page; still GUI-only.)
7. **`AppDelegate.swift`** — no change expected (the same `WebMonitorServer` instance serves
   both pages; it's already started on launch). Confirm no gating assumes a single page.
8. **`project.pbxproj`** — no new files if `desktopHtmlPage` is inlined into
   `WebMonitorServer.swift` (already in the build). If desktop JS/CSS is split into a
   vendored asset file, add it to the iOS exclusion set like the existing vendor files.
9. **Docs (BLOCKING, per fork rules):** update `WEB-MONITOR.md` (a "Desktop mode" section —
   but keep the phone-scope note intact and frame desktop mode as the sanctioned standalone
   copy), the `CLAUDE.md` "Web monitor" bullet (one-line summary + wiring), and this doc's
   status banner when implemented.

No changes to: `WebMonitorHostClient.swift` (the host client is reused as-is by `/stream`),
`WebMonitorPush.swift`, any `src/` Zig, `ghostty-host`, or the protocol. **No host restart /
no session loss** to ship it.

---

## Testing plan

Follow the existing pattern in **`macos/Tests/WebMonitor/WebMonitorServerTests.swift`** —
pure, deterministic tests of the routing/decision + pure helpers (the server's whole design
keeps the security-load-bearing logic in pure functions for exactly this). Concretely:

- **Route-decision tests** (mirror `decideRouteSetHiddenPost`, `decideRouteFrame*`): a `GET
  /desktop` returns `.desktopPage`; a `POST /desktop` returns `.methodNotAllowed`; `/desktop`
  with `?token=` under a configured token authorizes (bootstrap path) while `/api/*` still
  requires the header.
- **`isBootstrapPath("/desktop")`** is true.
- **Page-content assertions** (mirror `htmlPageHasAgentFilters`, `htmlPage…` string checks):
  `desktopHtmlPage` contains the sidebar container, the three filter inputs
  (`f-heroes`/`f-agents`/`f-visible`), the xterm asset references, the keydown wiring hook,
  and the paste/copy hooks — cheap `.contains(...)` guards so the page can't silently lose a
  feature.
- **`keySpecs(forKey:)` extension tests** (mirror the existing keyspec tests): `ctrl-d` →
  one `KeySpec(keycode: <native d>, mods: ctrl, unshiftedCodepoint: 'd')`; unknown `ctrl-…`
  → nil; existing `ctrl-c`/`ctrl-u` unchanged (regression guard); each new named key maps to
  the correct native keycode.
- No new host/Zig tests needed (no host/Zig change). The Swift suite is auto-discovered by
  the filesystem-synchronized `GhosttyTests` group.

---

## Phased implementation plan

Small, sequential phases a fresh session can execute and verify one at a time.

1. **Route + empty page.** Add `RouteDecision.desktopPage`, the `decideRoute` branch,
   `isBootstrapPath`, the `routeRequest` case, and a minimal `desktopHtmlPage` (just "hello,
   desktop"). Add the route-decision + bootstrap tests. Verify `/desktop` loads over
   `tailscale serve` with a token. **(Server plumbing proven before any UI.)**
2. **Sidebar + list.** Port `loadList()` + the three filters + per-row rendering into a
   fixed sidebar layout (desktop CSS). Clicking a row sets an "active" state (no viewer yet).
   Add page-content tests for the filters/sidebar markers.
3. **Viewer (single stream).** Port `openStream` + the poll fallback into the main viewer;
   picking a row disposes the prior stream and opens the new one. Verify color/live/host-grid
   sizing on a real surface. Frame-mode scroll ported next or here (reuse `smartScroll` et al).
4. **Keyboard input.** Add the global keydown handler → `/input` (text path for printables,
   `{"key":…}` for named/arrow/ctrl keys). **Extend `keySpecs(forKey:)`** for general
   `ctrl-<letter>` and add its tests. Keep the on-screen quick-key row as fallback. Verify a
   real shell + a TUI (e.g. an editor) drive correctly from the keyboard.
5. **Copy / paste.** Wire xterm selection → `navigator.clipboard.writeText` (copy) and DOM
   `paste` → `text/plain` `/input` (paste), both secure-context-gated with a Send-field
   fallback.
6. **Reconnect-on-refocus.** Extend `visibilitychange` to do a clean resync of the active
   stream on foreground.
7. **Polish + docs.** Theme-aware chrome, min-widths, the Mac-client note in the UI, and the
   BLOCKING docs updates (`WEB-MONITOR.md`, `CLAUDE.md`, this banner). Full Swift test run +
   a `ReleaseLocal` build + manual smoke from a second Mac.

---

## Open questions (honest)

1. **General Ctrl-<letter> keycode table.** Extending `keySpecs(forKey:)` needs the full
   native macOS keycode for each letter/digit. The values for a handful are known from the
   existing code (C=8, U=32); the rest must be filled from the NSEvent keyCode table. Verify
   each against the core's `input.keycodes` `entry.native` resolution before trusting it —
   this is the one place a wrong constant silently no-ops (the exact trap the `KeySpec` doc
   comment warns about).
2. **Meta/⌘ semantics.** Beyond repurposing ⌘C/⌘V/⌘X/⌘A for clipboard, are any ⌘ combos
   wanted as terminal input? Most are browser/OS-eaten anyway; recommend treating ⌘ as
   clipboard-only and not forwarding it. Confirm this matches the intended workflow.
3. **Alt/Option handling.** Terminals often expect Alt-<key> as an ESC-prefix (meta). Whether
   to synthesize that client-side (send ESC then the key) or rely on a keycode+mods spec is
   unresolved — the current `keySpecs` has no Option/meta path. Defer to a follow-up unless a
   concrete need appears; document as a known limitation.
4. **Typing batching vs. latency.** Send each printable keydown immediately (lowest latency,
   more POSTs) or debounce/batch consecutive printables into one `text/plain` POST (kinder to
   the core's 64-slot mailbox, slight lag)? The `keySpecs(forText:)` mailbox-overflow note
   (line 1385) argues for batching *pasted* runs; live single-keystroke typing is one char per
   event and unlikely to overflow, so per-keystroke is probably fine. Needs a quick live
   check under fast typing.
5. **Two clients, one surface.** Desktop mode and the phone (or the native GUI) can view/drive
   the same surface simultaneously. Viewing is fine; concurrent *input* interleaves. Is any
   coordination wanted, or is "don't do that" acceptable (as with tmux)? Recommended:
   acceptable, no coordination.
6. **Off-Mac clients.** Confirmed unsupported for positional keys (printables work). If a
   Windows/Linux client ever becomes a requirement, the fix is a `code`→native-keycode
   translation table client-side — out of scope for v1, noted here so it isn't rediscovered.

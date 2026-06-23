# Ghostty — ramon fork

Personal macOS fork of Ghostty that adds split/tab-reorganization commands and
runs side-by-side with an official Ghostty. Single working branch: **`ramon-fork`**.
Upstream conventions still apply (`AGENTS.md`, `macos/AGENTS.md`); this file only
covers what's specific to the fork.

> **PTY-host (emulation-on-host) work** is now **merged into `ramon-fork`** (it
> formerly lived on a `ptyhost/phase-2b` branch, since merged and deleted — the
> code came in via `3eb0ba26a Merge branch 'ptyhost/phase-2b' into ramon-fork`).
> If you are resuming or touching that work (the `.client` termio backend,
> `ghostty-host`, reattach-across-restart), read the top-level **`PTYHOST.md`**
> first — it has the architecture decisions, invariants/gotchas, and open items.
> (`.claude/` is gitignored / local-only; feature docs live at the repo root.)

## Functional changes — new keybind actions (also in the command palette)
All act on the focused surface. flip/toggle walk **up** to the nearest enclosing
split of the given orientation (like `resize_split`), so outer splits are
reachable from nested panes. The split tree is strictly binary.

**Keybind authoring note (upstream, not fork-specific):** trigger keys in
sequences are case-insensitive — `ctrl+a>q` and `ctrl+a>Q` resolve to the
same trigger, with the second binding silently clobbering the first. To bind
a shift-modified key, write the modifier explicitly: `ctrl+a>shift+q=…`.
The same applies to **any symbol that requires shift to type on your layout**
— `!`, `%`, `&`, `"`, `?`, etc. `ctrl+a>!=foo` parses without complaint but
stores empty mods, while the keypress always arrives with `mods={shift}`,
so the trigger never matches. `Set.getEvent` (`src/input/Binding.zig`) only
strips mods for `catch_all`, not for unicode keys. Write `ctrl+a>shift+!=foo`
instead (matches via the utf8 codepoint fallback); `ctrl+a>shift+1=foo` also
works (matches via the unshifted_codepoint fallback). Tripped over this
during the mark/pull smoke test and again on `prefix !`; safe rule of thumb:
never rely on letter case alone to disambiguate two bindings at the same
prefix, and always write `shift+` for keys that need shift to type.

The same silent-clobber applies to **two _identical_ triggers** at one prefix:
the last definition wins and the earlier one is dead, no error. Crucially the
**`repeatable:` flag is not part of trigger identity** — `ctrl+a>j=pull_marked_split`
and `repeatable:ctrl+a>j=resize_split:down,2` are the *same* trigger, so the
resize (defined later) silently ate the pull until the pull was moved to
`ctrl+a>m`. When two actions want the same key, one has to move; a flag prefix
won't disambiguate them.

- `flip_split:horizontal|vertical` — mirror the nearest left/right or up/down split (swap its two sides; divider stays put).
- `toggle_split_direction:horizontal|vertical` — re-orient the nearest split of that orientation (L/R ⇄ U/D).
- `move_split_to_new_tab` — eject the focused pane into its own new tab.
- `merge_tabs:{next,previous}_{horizontal,vertical}` — merge a neighboring tab into this one with a split.
- `new_tab[:<dir>]` — extends upstream `new_tab` with an optional working directory (e.g. `new_tab:~/git/ghostty`); `~/` is expanded by the apprt. Bare `new_tab` keeps the existing inherit-from-source behavior. The format roundtrips: actions equal to their type's `default` decl serialize without the `:value` suffix (also affects `new_split`, `close_tab`, etc., which already accepted a bare form on parse).
- `new_tab_command:<command>` — opens a new tab (inheriting cwd from the source surface, like bare `new_tab`) and runs `<command>` in it as the first input. Implemented as `initial_input`, **not** `command`: the tab launches your normal shell, then `<command>\n` is fed to it as if typed, so you're left at a live interactive prompt afterward (vs. upstream `command:`, which replaces the shell and exits/waits). The whole value after the colon is the command, sent verbatim — **no `~` expansion**, so use an absolute path or a shell that expands `~`. The trailing newline is appended in `src/Surface.zig`; the binding action maps onto the existing apprt `.new_tab` action, which gained an `initial_input` field (`src/apprt/action.zig` + `include/ghostty.h` + `Ghostty.App.swift`'s `newTab` handler). No command-palette entry (it needs an argument, like `csi:`/`esc:`).
- `mark_split` / `clear_split_mark` / `pull_marked_split:<right\|down\|left\|up\|auto>` — tmux-style `select-pane -m` / `select-pane -M` / `join-pane`. `mark_split` **toggles** (re-marking the marked pane clears it), so a single binding can both set and unset; the explicit `clear_split_mark` is still useful as a "clear from anywhere" command-palette entry. The mark is a single app-wide weak reference on `Ghostty.App`; if the marked pane is closed externally it silently goes away. `pull_marked_split` moves the marked pane into the focused tab next to the focused pane in the requested direction, works cross-tab and cross-window, and closes the source tab if it becomes empty. The marked pane gets a visible 3pt orange inset border in any window that holds it.
- `swap_split:<previous\|next\|up\|down\|left\|right>` — exchange the focused pane with another pane in the same tab. tmux's `swap-pane -U`/`-D` plus directional variants. Tree structure and divider ratios preserved; only the two leaves trade positions. Repeated `:next` walks a pane to the bottom-right in N-1 presses (DFS leaf order).
- **`repeatable:` flag prefix** (tmux `bind -r`) — on a leaf inside a key sequence, keeps the sequence armed at the same depth for 500ms after the action fires, so `ctrl+a>L L L L` keeps resizing without re-issuing the prefix. Timer is `Surface.sequence_repeat_timeout_ms` (hardcoded for now; config knob is a follow-up). Implemented in `src/input/Binding.zig` (Flags + parser) and `src/Surface.zig` (`maybeHandleBinding` keeps `sequence_set` armed + deadline; lookup expires the deadline before matching).
- `goto_last_surface` — payload-less action (chord `ctrl+a>ctrl+a`) that focuses the **previously focused surface**, the tmux `last-pane` analog but **GLOBAL across tabs AND windows** (tmux's `last-pane` is window-local). **Two-deep toggle**: press once to jump to the previous surface, press again to return. Focus history is two app-wide weak refs on `Ghostty.App` — `globalCurrentSurface` / `globalPreviousSurface` — a most-recently-used pair maintained like `markedSurface` (plain `weak var`s, no observers; closed surfaces auto-drop). **Not** the per-view SwiftUI `lastFocusedSurface` env value in `TerminalView.swift` (same idea, different scope) — the global refs are the new thing. The refs are updated by `recordFocusedSurface(_:)`, called only off the AppKit focus path (`SurfaceView.focusDidChange(true)`); re-focusing the current surface is a no-op so the toggle stays correct. The action **reuses** the existing `ghosttyPresentTerminal` present mechanism (same path as the locate-pane/highlight feature), so the jumped-to pane raises its window, selects its tab, and gets the standard highlight flash — intentional, helps you spot a cross-window jump. Correctness rests on a synchronous-read/async-record ordering: the handler reads `globalPreviousSurface` synchronously at press time, while `recordFocusedSurface` mutates the refs only after focus actually lands, so each press reads pre-jump state. No-op (logged at debug) when there is no previous surface or it equals the current one. The handler `gotoLastSurface` lives in `Ghostty.App` alongside the mark/pull/swap/project-selector handlers (not in `BaseTerminalController`); it required widening `Ghostty.App.appState(fromView:)` from `static private func` to `static func` for the new cross-file caller in `SurfaceView_AppKit.swift`. Has a command-palette entry ("Go to Last Split"). Fork-only, so keep the keybind in `~/.config/ghostty-ramon/config` (e.g. `keybind = ctrl+a>ctrl+a=goto_last_surface`; the `ctrl+a>ctrl+a` double-tap was unbound in the fork config, so nothing was displaced — it's the natural tmux "last" double-prefix gesture, now the global pane-level analog).
- **`goto_split` directional cycling** (fork-only tweak to the upstream `goto_split:left|right|up|down` action; no config key — always on) — when there is no split in the requested direction, focus now **wraps around** to the extreme split on the opposite side, so repeated presses cycle through every split instead of stopping at the edge. For a row `left | center | right`, repeated `goto_split:right` walks `left → center → right → left → …`; `goto_split:left` from the leftmost jumps to the rightmost (same for up/down). A single-pane tree still no-ops. Implemented purely in the macOS spatial layer: `SplitTree.focusTarget(for:.spatial(_):from:)` falls back to a new `SplitTree.Spatial.wrapSlots(in:from:)` when `slots(in:from:)` is empty. `wrapSlots` considers **leaf slots only** (split slots span their children and would distort the extreme edge), finds the extreme opposite edge (min `minX` for right, max `maxX` for left, etc.), and among ties prefers the slot nearest the reference on the perpendicular axis so the wrap keeps its row/column in a grid. The `.next`/`.previous` (tmux `o`/`;`) traversal already wrapped via `indexWrapping`; this brings the directional variants in line. Wiring: `macos/Sources/Features/Splits/SplitTree.swift`. Tests: `macos/Tests/Splits/SplitTreeTests.swift` (`focusTargetSpatialWraps*`, `focusTargetSpatialNoWrapWhenSinglePane`).
- `toggle_project_selector` — payload-less action (chord `ctrl+a>f`) that opens a fuzzy palette of project directories; picking one opens it in a new tab. Projects are discovered **dynamically** from the fork-only `project-directory` config key, a `RepeatableString` whose entries are BASE directories — each base's immediate subdirectories become the offered projects (deduped across bases by canonical path, sorted case-insensitively, hidden dirs skipped; `~/` expanded macOS-side). Selecting a project posts the same `ghosttyNewTab` notification the `new_tab:<dir>` action uses, but with a **bare** `SurfaceConfiguration` carrying only `workingDirectory` — so unlike bare `new_tab` it does NOT inherit the source tab's context; the project tab starts from app defaults in the chosen dir. If `project-directory` is unset or yields no subdirs, the palette shows a single informational row (and logs a warning) so the toggle is never a silent no-op. Has a command-palette entry ("Open Project…"). Both the action and `project-directory` are fork-only, so keep the keybind and the `project-directory` lines in `~/.config/ghostty-ramon/config` (an official Ghostty would error on the unknown key/action). Wiring is below; the C bridge for the string list is `ghostty_config_string_list_s` (header) backed by a parallel `list_c` pointer-view inside `RepeatableString` (`src/config/Config.zig`).

Wiring — core: `src/input/Binding.zig`, `src/apprt/action.zig` (+`include/ghostty.h`),
`src/Surface.zig`, `src/input/command.zig`, `src/config/Config.zig` (`project-directory` +
`RepeatableString` cval/C). macOS: `SplitTree.swift` (pure transforms),
`BaseTerminalController.swift`/`TerminalController.swift` (handlers, `newTab(tree:)`),
`Ghostty.App.swift`, `GhosttyPackage.swift`, plus the project selector's
`Ghostty.Config.swift` (`projectDirectories`), `TerminalView.swift`, and the new
`macos/Sources/Features/Command Palette/ProjectPalette.swift` (added to the iOS
exclusion set in `project.pbxproj`); `goto_last_surface` adds its focus-history
refs + handler to `Ghostty.App.swift` and the `recordFocusedSurface` hook to
`macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`. Tests:
`macos/Tests/Splits/SplitTreeTests.swift`; `RepeatableString cval*` +
`Binding toggle_project_selector` + `Binding goto_last_surface` (Zig).

- `bell-features-focused: BellFeatures` (fork-only config key) — a second bell-feature
  set governing the bell when the ringing surface is **truly in focus**: focused split
  / first responder AND `window.isKeyWindow` AND `NSApp.isActive` (a surface on another
  Space, in a backgrounded app, or a non-focused split counts as OUT OF FOCUS). When in
  focus, this set is used; otherwise the existing `bell-features` (unchanged, the
  OUT-OF-FOCUS set) is used. Same value format and same `BellFeatures` type
  (`system,audio,attention,title,border`); defaults are IDENTICAL to `bell-features`
  (`attention`+`title`), so behavior is unchanged until set. For "sound only when
  focused" set `bell-features-focused = audio,no-attention,no-title` (or `system,...`).
  The focus decision is made at RING time (not render) in a shared SurfaceView helper
  `bellFeaturesForCurrentFocus(_:)` / `bellIsFocused`, reused by both AppDelegate's bell
  handler (system/audio/attention) and SurfaceView's own handler (title/border via the
  single `bell` bool). Because `bell=true` is an all-or-nothing gate for title+border+
  dock-badge, the SurfaceView handler only arms it when the chosen set has `.title` or
  `.border`; the downstream `.title`/`.border` checks still read static `bell-features`,
  so enabling title/border in `bell-features-focused` while disabling them in
  `bell-features` would NOT show them (acceptable: the intended use is focused = no
  title/border). Fork-only — keep it in `~/.config/ghostty-ramon/config` (an official
  Ghostty shares `~/.config/ghostty/config` and would error on the unknown key).
  Wiring: `src/config/Config.zig` (field + doc + parse test), reusing `BellFeatures`;
  `macos/Sources/Ghostty/Ghostty.Config.swift` (`bellFeaturesFocused` getter, reusing
  the `BellFeatures` OptionSet); `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`
  (`bellIsFocused`, `bellFeaturesForCurrentFocus(_:)`, gated `ghosttyBellDidRing`);
  `macos/Sources/App/macOS/AppDelegate.swift` (`ghosttyBellDidRing` branches the set).

- **Bell visibility across splits/zoom** (fork-only tweak to upstream macOS Swift; no
  config key — always on) — two fixes so a bell in a non-focused or zoomed-away split is
  never silently lost (previously only the dock badge lit up). **(A) Tab-title
  aggregation:** the 🔔 title prefix now reflects the **window-level aggregate** bell
  (ANY surface in the tab rang), not just the focused surface — `setupTitleListener`
  combines `titleSurface.$title` with `self.$bell` (the same aggregate the dock badge
  uses, from `setupBellNotificationPublisher`) instead of `titleSurface.$bell`, and
  `applyTitleToWindow`'s `titleOverride` branch reads `self.bell`. **(B) Hidden-split
  bell badge under zoom:** while a split is zoomed, a hidden split that rings can't draw
  its own bell border (hidden splits aren't in the SwiftUI hierarchy — `TerminalSplitTreeView`
  renders only the zoomed subtree), so a small amber `bell.badge` pill is shown
  top-trailing on the zoomed view, driven by a new `BaseTerminalController.zoomedHiddenBell`
  (`@Published`, derived in `setupZoomedHiddenBellPublisher` by combining `$surfaceTree`
  with `surfaceValuesPublisher(\.bell)` → `SplitTree.hasBellOutsideZoom(bells:)`; reads
  the tree from the combineLatest tuple, NOT `self.surfaceTree`, because `@Published`
  emits in `willSet` so the stored prop still holds the old tree mid-cycle). The badge is
  gated on the same static `bell-features` `.border` as the border, so badge-under-zoom
  and amber-border-on-unzoom are a symmetric handoff; its corner-pill geometry stays
  visually distinct from the full-perimeter amber bell border and the orange marked-pane
  inset. Wiring: `macos/Sources/Features/Splits/SplitTree.swift` (`zoomedLeaves()` +
  `hasBellOutsideZoom(bells:)` pure transforms), `BaseTerminalController.swift` (title
  aggregate + `zoomedHiddenBell` publisher), `macos/Sources/Features/Terminal/TerminalView.swift`
  (`zoomedHiddenBell` protocol requirement + `HiddenSplitBellBadge`). Tests:
  `macos/Tests/Splits/SplitTreeTests.swift` (`hasBellOutsideZoom*`, `zoomedLeaves*`).

- **Web monitor** (fork-only, OFF by default) — a GUI-embedded HTTP server inside the
  running macOS app that, from a phone (e.g. over Tailscale), lists live terminal surfaces,
  > **SCOPE — phone workflows ONLY.** The web monitor is the phone-usage feature
  > (list/render/input/scroll from a handset over Tailscale) and nothing else. Do
  > **not** build new features on top of it — it is not maintained as a highly-stable
  > foundation. Other work (e.g. an MCP server / agent control) may *reuse its
  > architecture and copy code* (the host-protocol client, `keySpecs` input mapping,
  > `decideRoute`/`RequestParser` patterns, the serial-queue + main-hop threading
  > model), but should stand on its own and build directly on Ghostty + the host's
  > existing abstractions — there is already enough tooling there. Keep the web
  > monitor's surface frozen to what phone usage needs.
  **renders one in full ANSI color with scrollback + live updates** (a browser `xterm.js`
  fed the host's raw PTY byte stream), **sends input** (notably approving CLI-agent prompts),
  and **remote-controls scroll**. The server lives INSIDE the app — one binary, one
  rebuild/restart, NO second process. A SINGLE `NWListener` (dedicated serial queue) serves
  the page, the JSON API, the vendored `xterm.js` assets, the raw stream, and input/scroll on
  ONE port. **See `WEB-MONITOR.md` for the user-facing config/usage.** Detailed notes:
  - **Config (fork-only, default null/off so an official Ghostty sharing `~/.config/ghostty/config`
    never trips):** `web-monitor-listen` (`addr:port`; empty = disabled; purely a BIND address,
    NOT an IP allowlist — see the bind caveat) and `web-monitor-token` (OPTIONAL). **Token is
    optional:** empty ⇒ the server runs OPEN (`start()` logs a warning; `decideRoute` skips the
    token gate + backoff entirely — access control is the TAILNET/Tailscale ACL alone) — this
    is the user's deliberate choice for a private tailnet. If SET, it is fully enforced
    (constant-time compare; `?token=` only on the bootstrap `GET /` + asset routes, which can't
    send a header; `/api/*` requires the `X-Ghostty-Token` header) and is a SHELL-EXECUTION
    credential (rotate if leaked). `tokenAcceptable` (≥16 chars) is now a soft warning, not a
    refusal.
  - **Color/scrollback architecture (the core of v2):** under the fork's `pty-host` `.client`
    backend the GUI's screen mirror is VIEWPORT-ONLY and colorless, so the live view comes from
    the HOST. `src/termio/Termio.zig` gained a nullable `output_observer` (null for `.exec` ⇒
    byte-identical GUI behavior; set by the host `Session`). The host `Session` keeps a bounded
    256KB per-session RAW RING BUFFER (replay-on-connect) and broadcasts new bytes; two ADDITIVE,
    version-negotiated (minor 0→1), crash-safe frames carry it: `subscribe_raw` (client→host) +
    `raw_output` (host→client) in `src/host/protocol.zig`, routed by `src/host/Server.zig` raw
    subscribers. A Swift host-protocol client — `WebMonitorHostClient` (POSIX `AF_UNIX`) —
    connects to the `pty-host` socket, does the `Hello` handshake, `subscribe_raw`s a session,
    and decodes the `raw_output` stream. `GET /api/surface/{uuid}/stream` pipes those bytes to
    the browser as a long-lived `application/octet-stream` with the host grid in
    `X-Ghostty-Cols`/`X-Ghostty-Rows` headers (from `ghostty_surface_size`); the page
    `term.resize()`s `xterm.js` to that grid so cursor-addressed TUIs render aligned. **Without
    `pty-host`** (or if the stream can't start → 501) the page falls back to the plain-text
    snapshot poll.
  - **Font:** the page + the `xterm.js` terminal render in **JetBrains Mono Nerd Font** (the
    GUI's own default font), vendored as woff2 (Regular + Bold, from `src/font/res/`, TTF→woff2
    ~2.2MB→~900KB each) at `vendor/JetBrainsMonoNerdFont-{Regular,Bold}.woff2` and served via two
    `assetRoutes` (`/jetbrains-mono-{regular,bold}.woff2`, `font/woff2`, bootstrap/`?token=` like
    xterm.css). The phone has no such system font, so shipping it is REQUIRED. The `@font-face` is
    injected **client-side** (page asset-loader IIFE) — NOT in the static `<style>` — so the woff2
    `src` URLs carry `?token=` via `url()` exactly like the xterm assets; `font-display:swap` +
    an eager `document.fonts.load()` nudge, and the existing resize-to-host-grid re-measures
    xterm metrics so a slightly-late font swap self-corrects. Font is a faithful match to Ghostty,
    not config-driven (changing `font-family` in ghostty config won't follow); regenerate the
    woff2 if you want a different face. NOT exempt from the iOS-target exclusion set in
    `project.pbxproj` (listed alongside xterm.{js,css}). GUI-only — relaunch, no host restart.
  - **HTTP API:** `GET /` (page); `GET /xterm.js`, `GET /xterm.css` (vendored assets, `?token=`
    accepted like the bootstrap); `GET /api/surfaces` (`[{id,title,pwd}]`); `GET
    /api/surface/{uuid}/stream` (raw-byte xterm source; needs `pty-host`); `GET
    /api/surface/{uuid}/screen?mode=viewport|scrollback` (plain-text fallback, reuses
    `cachedVisibleContents`/`cachedScreenContents`); `POST /api/surface/{uuid}/input`; `POST
    /api/surface/{uuid}/scroll` (`{"dy":±ticks}`). Unknown id/path → 404, wrong method → 405,
    bad/negative/oversized Content-Length → 400, chunked → 411, oversized → 413, bad Host → 403,
    throttled (token mode) → 429.
  - **Input = REAL key/wheel events, NOT paste (critical):** `ghostty_surface_text` routes
    through `completeClipboardPaste` (clipboard path) — pasted `\n` is a literal newline (never
    submits), control bytes aren't real keys, and newline pastes trip Mac paste-protection. So
    input is sent via `ghostty_surface_key`: a pure testable `KeySpec` mapping (`keySpecs(forKey:)`
    / `keySpecs(forText:)`) → press+release. **`KeySpec.keycode` MUST be the NATIVE macOS virtual
    keycode** (Return=36, Esc=53, Tab=48, Backspace=51, C=8+ctrl, U=32+ctrl, arrows 123–126) —
    the core resolves the physical key via `input.keycodes` `entry.native == keycode`, so the
    `GHOSTTY_KEY_*` enum value is WRONG and silently no-ops. Printable text rides the `text` field
    (keycode 0); `\n`/`\r` → a real Return. Scroll = `ghostty_surface_mouse_scroll` (non-precision
    wheel, `scroll_mods=0`; the host routes it per the app's mode: SGR wheel / alternate-scroll
    arrows / scrollback). Page input model: **Send (and Return-in-field) TYPE the text only — they
    do NOT submit**; the **Enter quick-key submits**; quick-keys are enter/y/n/esc/tab/backspace/
    ctrl-u(Clear)/ctrl-c, digits 1–4, arrows, and Scroll ↑/↓. **Press-and-hold auto-repeat**
    (`addRepeat`: 350ms delay → 90ms repeat; `touch-action:none` + preventDefault) on scroll/
    arrows/backspace only; the rest are single-fire.
  - **Security defense-in-depth** (independent of the token): `hostHeaderAllowed` (DNS-rebinding
    guard), a decaying+capped per-peer failed-token backoff (only applies when a token is set),
    and per-connection bounds (~10s idle watchdog + ~15s absolute deadline armed once in
    `handle()` + 32-connection cap) — the long-lived `/stream` connection is EXEMPT from the
    watchdogs. The page renders untrusted list/snapshot text via `textContent` (never
    `innerHTML`); the live view is `xterm.js` parsing the byte stream.
  - **Threading (correctness-critical):** the listener + all connections run on a DEDICATED
    background SERIAL queue (never `DispatchQueue.main`), which makes the `DispatchQueue.main.sync`
    hops deadlock-safe; `stop()` tears down with `queue.async` (a `queue.sync` from main would
    invert against a handler's `main.sync`). Every handler touching AppKit / `TerminalController.all`
    / `SurfaceView` / `ghostty_surface_*` hops to main and returns ONLY value types — never a
    `ghostty_surface_t`/`SurfaceView` across the hop. `WebMonitorHostClient` runs its socket
    read loop on its OWN background thread; `onBytes` writes straight to the (thread-safe)
    `NWConnection`. **Routing is a PURE function** `decideRoute(...) -> RouteDecision` (no AppKit/
    socket/mutation); it + `hostHeaderAllowed`, `keySpecs`, `scrollDeltaY`, `parseListen`,
    `RequestParser`, `surfacesJSONData`, `HTTPResponse`, and the host-client framing helpers are
    `internal` + unit-tested.
  - **Push notifications on bell (Notify toggle, fork-only, GUI-only):** a background **Web
    Push** so a bell pushes to a subscribed phone with the tab CLOSED / phone LOCKED — the
    "I stepped away" feature. The page header has a **🔔 Notify** toggle = a single SERVER-SIDE
    arm/mute flag (mute at the laptop, arm when away). Full Web Push, ZERO new deps: a
    self-generated **VAPID** P-256 keypair (RFC 8292 ES256 JWT) — **NO Firebase/Google project**;
    Chrome returns an `fcm.googleapis.com` endpoint we POST to directly with **RFC 8291
    `aes128gcm`** payload encryption (ephemeral ECDH + HKDF-SHA256 + AES-128-GCM), ALL via
    **CryptoKit**. `WebPushCrypto` (encrypt + JWT + base64url) is PURE and unit-tested against
    the **RFC 8291 §5 worked example** (byte-for-byte) + a VAPID sign/verify round-trip.
    `WebPushManager` persists the keypair + device subscriptions + the enable flag in
    **UserDefaults** (per-bundle-id; default MUTED), observes `.ghosttyBellDidRing` like
    `MCPEventBus`, and fans each bell out via `URLSession` (debounced ~3s/surface; 404/410 ⇒
    drop the dead subscription). **HARD REQUIREMENT: a SECURE CONTEXT** — service workers only
    register over HTTPS, so the plain-HTTP-over-Tailscale-IP setup CANNOT push. The chosen TLS
    path is **`tailscale serve`** in front: bind the monitor to a **loopback INTERNAL port**
    (`web-monitor-listen = 127.0.0.1:18787`) and `tailscale serve --bg --https=<external>
    127.0.0.1:<internal>` proxies `https://<machine>.<tailnet>.ts.net:<external>` → loopback.
    **The external HTTPS port and the internal bind port MUST DIFFER** — the monitor binds the
    port on ALL interfaces (`*:<internal>`, host part ignored), so serving HTTPS on that same
    port makes `tailscaled` grab the tailnet IP's `:<port>` first and the monitor's wildcard
    bind then fails with `EADDRINUSE` (never starts → proxy 502s). Convention: external `8787`,
    internal `18787` (the `1`-prefixed twin). **Per-identity offset** (`WebMonitorServer.portOffset`,
    mirrors `MCPServer`) shifts the shared loopback port so the three builds coexist: Release `+0`
    (18787), ReleaseLocal `+1` (18788), Debug `+2` (18789); `tailscale serve` maps each external
    (8787/8788/8789) to its identity's loopback port. Pure helpers `portOffset(forBundleID:)` /
    `applyPortOffset(_:offset:)` are unit-tested (`WebMonitorServerTests`).
    `tailscale serve` only proxies to `127.0.0.1` but — contrary to an earlier wrong note here —
    it does NOT rewrite `Host` to the loopback backend; it forwards the ORIGINAL tailnet
    `Host: <machine>.<tailnet>.ts.net:<external port>` (also in `X-Forwarded-Host`, with
    `X-Forwarded-Proto: https` + Tailscale identity headers). So `hostHeaderAllowed` explicitly
    **accepts any `*.ts.net` host on any port** (verified against the real forwarded request);
    reaching that endpoint already requires tailnet membership, and a browser cannot forge a
    `*.ts.net` Host against the loopback bind, so DNS-rebinding protection for the
    loopback/configured-host paths is unaffected. The token still gates — **NO Zig changes were
    needed; this is entirely Swift + page-side.** Routes (all on the same listener): `GET /sw.js` (the service
    worker — a BOOTSTRAP path, `?token=` accepted, since `serviceWorker.register()` can't set the
    header), `GET /api/push/config` (`{vapidPublicKey, enabled, subscriptions}`), `POST
    /api/push/{subscribe,unsubscribe,enabled}` (header-token like every `/api/*`). The page's
    Notify button is disabled with a "needs HTTPS" note when `!window.isSecureContext`. The body
    parsers (`pushSubscription`/`pushEndpoint`/`pushEnabledFlag` `fromBody:`) + the route
    decisions are `internal` + unit-tested.
  - **Liveness/errors** via `UNUserNotificationCenter` + log (Console.app subsystem = bundle id,
    category = `web-monitor`). No live config-reload (relaunch to change listen/token). Zero new
    SPM deps (Foundation + Network + AppKit; `xterm.js` is a vendored static asset, bundled via
    the synchronized Sources group + iOS exclusion). **DEPLOY caveat:** the host raw-tee is a HOST
    change — rebuilding/restarting `ghostty-host` LOSES all live sessions (RAM-only); the GUI/page
    parts are GUI-only (a relaunch reattaches). Wiring: `src/config/Config.zig` (`web-monitor-listen`
    + `web-monitor-token` + `pty-host` — the last is now `?[:0]const u8` so `ghostty_config_get` can
    return it as a C string for the `ptyHost` getter); `macos/Sources/Ghostty/Ghostty.Config.swift`
    (`webMonitorListen`/`webMonitorToken`/`ptyHost`); `macos/Sources/Features/WebMonitor/WebMonitorServer.swift`
    (server + xterm page + routes + Notify toggle + `/sw.js` + `/api/push/*`);
    `macos/Sources/Features/WebMonitor/WebMonitorPush.swift` (`WebPushCrypto` + `WebPushManager`);
    `macos/Sources/Features/WebMonitor/WebMonitorHostClient.swift`
    (host-protocol client); `macos/Sources/Features/WebMonitor/vendor/xterm.{js,css}`;
    `src/host/{Session,Server,protocol}.zig` + `src/termio/Termio.zig` (raw-tee + ring + frames +
    observer); `macos/Sources/App/macOS/AppDelegate.swift` (start/stop);
    `macos/Ghostty.xcodeproj/project.pbxproj` (iOS exclusion of the new macOS-only files). Tests:
  `macos/Tests/WebMonitor/WebMonitorServerTests.swift` (auto-discovered by the
  `GhosttyTests` filesystem-synchronized group) + host frame/ring/integration tests in
  `src/host/test.zig` (`zig build test -Dtest-filter=host`).

- **MCP server** (fork-only, OFF by default) — a GUI-embedded **MCP server** that lets an
  orchestrating agent (Claude Code / Codex) **control** the fork (reorganize splits/tabs,
  open tabs / run commands) and **watch + respond to** live sessions (bell / process-exit /
  prompt; read the screen; type input / approve CLI-agent prompts). **See `MCP-SERVER.md`
  for the user-facing config/usage + the full tool list.** The load-bearing facts for an
  agent working on this code:
  - **Built on EXISTING abstractions; ZERO host changes.** Read/respond go through the
    libghostty C API on the GUI surface (`ghostty_surface_read_text` viewport,
    `ghostty_surface_key` real key events, `ghostty_surface_text`,
    `ghostty_surface_mouse_scroll`); watch is a Swift event bus over existing GUI state
    (`ghosttyBellDidRing`, `process_exited`, a `needsConfirmQuit` transition); layout calls
    the existing `TerminalController`/`SplitTree` handlers. The host (`ghostty-host`) has
    **no MCP awareness** — the only Zig change is two additive, default-null config keys it
    ignores. So enabling/changing MCP needs a **GUI relaunch only, never a host restart**.
  - **Standalone module that COPIES the web monitor, never depends on it** (per the
    web-monitor scope rule above): the serial-queue + main-hop threading model, the
    `keySpecs` NATIVE-keycode input mapping (Return=36, Esc=53, …; the `GHOSTTY_KEY_*` enum
    value silently no-ops — see the web-monitor `fix7` notes), the `decideRoute`/
    `RequestParser` shape, and the token/Host-header/backoff defenses are all re-homed in
    `macos/Sources/Features/MCP/`, not imported from `WebMonitor`.
  - **Config (fork-only, default null/off):** `mcp-listen` (`addr:port`, empty = disabled;
    purely a BIND address) + `mcp-token`. **Unlike `web-monitor-token`, the MCP token should
    ALWAYS be set** — it is a SHELL-EXECUTION credential (the tools spawn tabs + run
    commands), so the recommended bind is **localhost** (`127.0.0.1:8765`) with a token, NOT
    an open tailnet bind. Empty token ⇒ runs OPEN + logs a warning. Keep both in
    `~/.config/ghostty-ramon/config`. **Per-identity port offset (automatic, code not
    config):** the three fork identities share one config file (hence one `mcp-listen`
    port) and would fight over it side-by-side, so `MCPServer.init` shifts the port by a
    per-bundle-id offset — Release `+0` (keeps the configured port), ReleaseLocal `+1`,
    Debug `+2` (so `:8765` ⇒ 8765 / 8766 / 8767). Pure overflow-safe helpers
    `portOffset(forBundleID:)` / `applyPortOffset(_:offset:)` in `MCPServer.swift`,
    unit-tested (`MCPServerTests`). The stdio shim defaults to Release (`8765`); use
    `GHOSTTY_MCP_URL` to hit a dev build.
  - **Transport:** in-GUI HTTP JSON-RPC 2.0 on its own `NWListener` (`POST /mcp`:
    `initialize` / `tools/list` / `tools/call`) + a standalone stdio shim
    (`macos/mcp-shim`, `ghostty-mcp`, a dumb stdin↔HTTP pipe, NOT in `Ghostty.xcodeproj`,
    built with `swift build`) so `claude mcp add ghostty -- ghostty-mcp` works. The shim's
    default URL is `http://127.0.0.1:8765/mcp`; `GHOSTTY_MCP_URL`/`GHOSTTY_MCP_TOKEN` override.
  - **Durable registration (the "works on a new laptop" story).** A committed
    **`.mcp.json`** at the repo root registers the server project-scoped as
    `ghostty -- ghostty-mcp` (bare PATH name, **no secret, no clone-specific path**), so any
    Claude Code session opened in the repo auto-gets the 12 tools after a one-time approval +
    restart. Two pieces make a secret-less, path-less registration work: (1) the shim is
    installed on PATH at **`~/.local/bin/ghostty-mcp`** (release build, alongside
    `ghostty-host`; new-machine: `cd macos/mcp-shim && swift build -c release && cp
    .build/release/ghostty-mcp ~/.local/bin/`); (2) the shim **falls back to reading
    `mcp-token` from `~/.config/ghostty-ramon/local`** when `GHOSTTY_MCP_TOKEN` is unset
    (`tokenFromLocalConfig()` in `main.swift` — same canonical secret store the agent-state
    hook reads), so the committed JSON needs no token. The OLD doc registered a brittle
    `.build/debug/ghostty-mcp` absolute path with the token baked into the `claude mcp add`
    invocation — replaced by this. Dev identities still reachable via
    `GHOSTTY_MCP_URL=…:8766/:8767`. Wiring: `.mcp.json` (repo root), `macos/mcp-shim/Sources/ghostty-mcp/main.swift`
    (`tokenFromLocalConfig`); see `MCP-SERVER.md` → "Connecting an agent".
  - **12 tools:** `list_surfaces`, `read_surface`, `get_layout`, `send_text`, `send_key`,
    `scroll`, `wait_for_event`, `watch_for_pattern`, `focus_surface`, `new_tab`,
    `close_surface`, `perform_action` (the keybind-action grammar string). All address a
    surface by **stable UUID**; `wait_for_event`/`watch_for_pattern` are long-poll
    (idle-watchdog-exempt, bounded by a clamped `timeoutMs` 1000–120000).
    `list_surfaces` rows carry `id, title, pwd, window/tab/split position, focused, bell,
    exited, atPrompt` plus three OPTIONAL (omitted-when-unknown) fields: `processName` /
    `command` (foreground process + full cmdline) and `idleSeconds` (seconds since the screen
    last changed). **`processName`/`command` are HOST-GATED**: under `.client` the GUI mirror
    can't read the foreground process (the PTY is in the host), so the host resolves them
    (libproc/sysctl in `src/os/proc_info.zig`) and PUSHES an additive `process_info` frame
    (protocol minor 3, gated on the conn's negotiated minor in `Server.zig`) — they stay
    absent until the **host is restarted** to a minor-3 build, even after a GUI upgrade.
    **`idleSeconds` is GUI-only** (stamped in `Client.zig` on each applied `grid_frame`; ships
    at the next GUI relaunch, no host restart) and is a coarse heuristic (a TUI that repaints
    on a timer never idles; null on backends without a host frame stream).
  - **Two deliberate v1 limits (documented honestly, don't "fix" by guessing):**
    (a) **`read_surface` is VIEWPORT-ONLY** — under `pty-host` the GUI mirror is
    viewport-sized (real scrollback is on the host), so there is no honest scrollback read;
    the `mode` param was REMOVED rather than lie. Reach scrolled-off output via `scroll` +
    re-read. (b) **`prompt`/`atPrompt` rides the coarse `needsConfirmQuit` bit, NOT OSC 133**
    — gated by `confirm-close-surface` (`false` ⇒ never fires; `always` ⇒ inverted); prefer
    `watch_for_pattern` for "agent waiting on me". A real OSC-133 bit needs host plumbing
    (out of scope). Relative layout verbs focus the target first (anchor-parameterizing
    `SplitTree` is a follow-up). Wiring: `src/config/Config.zig` (`mcp-listen`/`mcp-token` +
    parse test); `macos/Sources/Features/MCP/{MCPServer,MCPRPC,MCPTools,MCPInput,MCPLayout,
    MCPEventBus}.swift`; `Ghostty.Config.swift` (`mcpListen`/`mcpToken`); `AppDelegate.swift`
    (start on launch); `project.pbxproj` (iOS exclusion); `macos/mcp-shim/*`. The
    `processName`/`command`/`idleSeconds` feature adds: HOST — `src/os/proc_info.zig`
    (pid→name+cmdline resolver, pure `parseProcArgs2`), the `process_info` frame +
    `Conn.negotiated_minor` gate (`src/host/{protocol,Server,Session}.zig`, minor bumped to 3);
    CORE/lib — `src/termio/Client.zig` (cache + `last_activity_ms` stamp on `grid_frame` only +
    accessors), `src/Surface.zig` (`foregroundProcessName`/`foregroundCommand`/`idleMillis`
    getters; `.exec` resolves locally via `proc_info`), `src/apprt/embedded.zig` +
    `include/ghostty.h` (`ghostty_surface_process_name`/`_command`/`_idle_ms` exports);
    macOS — `Surface View/SurfaceView_AppKit.swift` (the three computed vars), `MCPLayout.swift`
    (`SurfaceRow` fields + JSON), `MCPTools.swift` (schema doc). Tests:
    `macos/Tests/MCP/MCPServerTests.swift` + the `mcp` Zig config test
    (`zig build test -Dtest-filter=mcp`); the `process_info` frame round-trip/bounds +
    minor-3 tests in `src/host/test.zig` and the `proc_info parseProcArgs2` tests in
    `src/os/proc_info.zig` (`zig build test -Dtest-filter=host` / `-Dtest-filter=proc_info`),
    plus the `process_info`/`idleMillis` Client tests in `src/termio/Client.zig`.

- **Agent Dashboard** (fork-only, macOS, OFF by default) — a persistent sidebar
  `NSPanel` showing a live, natively-rendered preview of every terminal split running a
  CLI agent (Claude Code / Codex) across ALL tabs and windows, stacked as **full-width
  rows** each showing the split's **latest rows** (preview is bottom-anchored, top
  clipped); click a row to jump to that split (raise window + select tab + un-zoom if
  hidden), Hide ✕ to declutter, bell-ring auto-unhides. The panel is **normal-level by
  default** (other windows can cover it) with a visible title ("Agent Dashboard") +
  standard-window AX subrole; the fork-only **`agent-dashboard-pin`** key flips it to a
  **floating window level** (native always-on-top). The pin is in-process precisely
  because an external window manager keyed on bundle id (Rectangle Pro's "pin one app to
  a side") CANNOT distinguish the panel from the terminals — they share one bundle id —
  so its pin manages the terminals too; pinning here sidesteps that. The AX subrole stays
  `.standardWindow` even when pinned (a floating subrole is filtered out by most window
  managers; only the window *level* changes). **Pinning ALSO drops `.nonactivatingPanel`**
  from the style mask: the default overlay never activates Ghostty so it never becomes the
  app's focused window, and Rectangle/Rectangle Pro keyboard shortcuts act on "the
  frontmost app's focused window" — so a non-activating pinned panel is UNMOVABLE by
  Rectangle (Rectangle itself manages any window with level < 21, so the floating level 3
  is fine; the blocker was the non-activating panel never being the focused window). As an
  activating window it can become key/focused on click, so Rectangle can move/snap it while
  the floating level keeps it on top; it STILL never becomes `main` (`canBecomeMain = false`
  unchanged), so "new window inherits from main" is unaffected. Trade-off: clicking a
  pinned dashboard activates Ghostty (fine — clicking a tile jumps into a terminal anyway).
  **See `AGENT-DASHBOARD.md` for the user-facing config/usage.** The load-bearing facts for
  an agent touching this code:
  - **Action + config (fork-only, default off):** the payload-less keybind action
    `toggle_agent_dashboard` (also a command-palette entry "Toggle Agent Dashboard");
    `agent-dashboard` (master enable) + `agent-dashboard-commands` (exe names that count
    as an agent; comma-split OR repeated, default `claude,codex`; both reuse
    `RepeatableString`) + **`agent-dashboard-pin`** (bool, default false → floating window
    level + activating window when true; wired `Config.zig` → `Ghostty.Config.agentDashboardPin`
    → `AgentDashboardPanel(pinned:)`, which sets `level = pinned ? .floating : .normal` AND
    drops `.nonactivatingPanel` from the style mask when pinned). Keep all in
    `~/.config/ghostty-ramon/config`. Read at launch (relaunch to change).
  - **Live previews need `pty-host`.** Each tile mounts a read-only **mirror**
    `SurfaceView` (`mirror = true` + the host session id) and lets the existing
    `SurfaceWrapper` render it natively (full color, viewport-only — right for a
    thumbnail), scaled aspect-fit-by-width + bottom-anchored so the latest rows show.
    Without pty-host there's no session to mirror ⇒ metadata-only tiles under a banner.
  - **Detection is HOST-GATED on a NEW protocol frame.** Under `.client` the GUI mirror
    can't read the foreground process, so the host pushes the raw foreground pid via an
    additive `foreground_pid` frame (**protocol minor bumped 3→4**); the GUI walks that
    pid's process subtree locally with libproc and path-component-matches the configured
    commands. **Detection silently finds nothing until `ghostty-host` is on a minor-4
    build** — a GUI upgrade alone is not enough (this was the multi-bug detection-failure
    chase: stale xcframework left the app on minor 3, plus `proc_listchildpids` is
    unreliable on macOS — use `proc_listpids`+`proc_pidinfo` parent links — plus a
    versioned exe basename isn't the command name, hence path-component match).
  - **Threading / cost:** the detector is a ~2s off-main `.utility` poll (pure
    `matchAgent`/`resolve` behind an injectable `ProcEnumerator`); paused while the panel
    is hidden/occluded, and mirror renderers pause via `ghostty_surface_set_occlusion` —
    a hidden panel costs ~nothing. The model is `@MainActor`; the detector hops to main
    only to snapshot value types `(uuid, foregroundPID)` and to publish results. Hide set
    persists in the per-bundle-id UserDefaults; a ringing agent is never left hidden.
    GUI-only changes relaunch the GUI; the `foreground_pid` frame is a HOST change (host
    rebuild + LaunchAgent reload, see below). Wiring: core — `src/config/Config.zig`
    (`agent-dashboard`/`-commands`), `src/input/{Binding,command}.zig` +
    `src/apprt/action.zig` (action), the minor-4 frame in
    `src/host/{protocol,Server,Session}.zig` + `src/termio/Client.zig` +
    `ghostty_surface_foreground_pid` (`include/ghostty.h`, `src/apprt/embedded.zig`,
    `src/Surface.zig`); macOS — `macos/Sources/Features/AgentDashboard/*` (Controller +
    Model + Panel + View + PreviewTile + Detector), `AppDelegate.swift`,
    `Ghostty.Config.swift`, `Ghostty.Surface.swift` (`foregroundPID`), `project.pbxproj`
    (iOS exclusion). Tests: `macos/Tests/AgentDashboard/AgentDashboardTests.swift`; Zig
    `agent-dashboard config` + `Binding toggle_agent_dashboard` + the minor-4/
    `ForegroundPid` round-trip in `src/host/test.zig` + the `foreground_pid` Client decode.
  - **Per-tile agent state via Claude Code hooks (fork-only, GUI + hooks ONLY, ZERO
    Zig/host change).** Each tile can show an authoritative `working`/`waiting`/`idle`
    chip (+ `lastTool`/`lastPrompt`) driven by Claude Code's lifecycle hooks, NOT a
    heuristic. A tiny shell hook (`example/claude-hooks/ghostty-agent-state.sh`, wired by
    `example/claude-hooks/settings-hooks.json` into `~/.claude/settings.json`) fires on
    `UserPromptSubmit`/`PreToolUse`/`SessionStart` (→ `working`), `Notification` (→
    `waiting`), `Stop`/`SessionEnd` (→ `idle`) and **POSTs `{tty,state,prompt?,tool?,
    message?}` to the EXISTING in-GUI MCP server** at `POST /agent-state` (`X-Ghostty-Token`,
    `127.0.0.1:8765`; `GHOSTTY_MCP_PORT` overrides for the 8766/8767 dev offsets). The hook
    is fire-and-forget (backgrounded `curl --max-time 2`, never blocks/fails the agent),
    debounces only the chatty `PreToolUse`/`working` with a ~1s per-tty stamp file, and
    reads the token from `$GHOSTTY_MCP_TOKEN` or `~/.config/ghostty-ramon/local`. **tty
    correlation is the load-bearing trick:** the hook reports the surface's controlling
    tty — but Claude Code spawns hooks (like Bash tool calls) **DETACHED from the
    controlling terminal**, so the hook's OWN tty is `??`/none. The script therefore
    **walks up its ppid chain** (`ps -o tty= -p <pid>`, then `ps -o ppid=`) and takes the
    nearest ancestor with a real tty — the `claude` process itself runs on the surface's
    tty (e.g. `ttys030`). (The original "read your own `ps -o tty=`" assumption was WRONG
    and made the hook silently `exit 0` with a blank tty — see the 2026-06-22 debug note.)
    The MCP handler
    (`MCPServer.handleAgentState`) resolves it to a surface UUID by reading each surface's
    **host-pushed minor-4 `foregroundPID`** (the SAME pid the dashboard detector already
    consumes — no new frame) and mapping that pid → controlling tty via libproc
    `proc_pidinfo(PROC_PIDTBSDINFO).pbi_e_tdev` → `devname()`, normalizing both sides
    (`/dev/ttysNNN`/`ttysNNN`/`sNNN` → `ttysNNN`). A no-match returns 200 (the hook is
    fire-and-forget; a momentary miss isn't an error). The handler posts
    `.ghosttyAgentStateDidChange`; `AgentDashboardModel.applyAgentState` is
    **hook-authoritative + alongside** (any surface that ever POSTed joins `hookBacked` and
    thereafter MUTES the `idleSeconds` heuristic), app-side **coalesces** an unchanged state
    (the second `PreToolUse` debounce), auto-unhides + sorts-first on `.waiting` (mirrors
    the bell auto-unhide), and on the working/idle→`.waiting` EDGE posts
    `.ghosttyAgentNeedsAttention`, which `WebPushManager` observes to fire a Web Push (an
    `⏳ ` push, reusing the bell fan-out via the shared `enqueuePush`; the per-surface
    ~3s debounce is keyed per-kind so a bell never swallows the waiting push). **No TTL** — the ~2s detector poll
    removes dead agents; a missed `Stop` is an accepted cosmetic stale-`working`.
    **Persisted across GUI restart** (hooks only POST on transitions, so a relaunched
    GUI would otherwise show blank chips until the agent next acts): the model
    write-throughs each state to an `AgentStateStore` (UserDefaults) keyed by the
    **stable host session id** — NOT the surface UUID, which is freshly minted each
    launch — and `rebuild(live:)` rehydrates it onto the new UUID by session id
    (silent restore — no push / no waiting-edge re-fire; the next live hook takes
    over). Records age-prune (14d / 256-cap, timestamp touched for live sessions).
    Caveat: a HOST restart resets the session-id counter, so a stale record could
    briefly hydrate a reused id with wrong state until the next hook self-corrects
    (host restarts are rare + lose all sessions anyway). `prune` /
    `AgentStateStore` / `UserDefaultsAgentStateStore` are unit-tested.
    Claude-Code-only (Codex tiles stay preview-only). Pinned shared symbols
    (`AgentState`/`AgentStatePayload`/the two `Notification.Name`s/`AgentStateUserInfoKey`)
    live in `macos/Sources/Features/AgentDashboard/AgentStateBridge.swift`. Wiring: hooks —
    `example/claude-hooks/*`; MCP — `macos/Sources/Features/MCP/MCPAgentState.swift` (pure
    parser + tty normalize/match + the injectable `TTYResolver` proc seam) +
    `MCPServer.swift` (`/agent-state` route + `handleAgentState`); dashboard —
    `AgentStateBridge.swift` + `AgentDashboardController.swift` (model state + observer +
    `postNeedsAttention` + drop-stale) + `AgentPreviewTile.swift` (state chip + waiting
    border/pill + tool/prompt); push — `macos/Sources/Features/WebMonitor/WebMonitorPush.swift`
    (attention observer → `onAttention`/`enqueuePush`); `project.pbxproj` (iOS exclusion of
    the 2 new source files). Tests: `macos/Tests/MCP/MCPAgentStateTests.swift` (parse /
    normalizeTTY / ttyMatches / resolveSurface w/ injected resolver / decideRoute
    `/agent-state`) + the `applyAgentState` model tests in
    `macos/Tests/AgentDashboard/AgentDashboardTests.swift`. **GUI relaunch only** to pick it
    up (no host restart); the user copies the hook to `~/.config/ghostty-ramon/claude-hooks/`
    + merges the settings block — see `AGENT-DASHBOARD.md`.

- **Agent Manager** (fork-only, macOS, OFF by default) — layers a **Haiku status
  summarizer** on top of the Agent Dashboard: each agent tile shows a live, one-line
  semantic status (needs-you-FIRST, then task+phase — e.g. "Waiting: which DB to migrate?",
  "Implementing auth fix — writing tests") instead of just the raw working/waiting chip.
  **Phases 1 + 2 are BUILT** (`.claude/plans/agent-manager-design.md`, local): Phase 1 =
  the summarizer (below); **Phase 2 = an Opus manager that SUGGESTS replies** (suggest-only,
  see its own bullet below). Phase 3 = opt-in auto-apply, Phase 4 = a cross-session
  coordinator — NOT built yet. **See `AGENT-MANAGER.md` for user-facing config/usage.** The
  load-bearing facts for an agent touching this code:
  - **A warm TypeScript Agent SDK sidecar is the brain; the MCP server is its hands.**
    `claude -p` was rejected (cold-boots the CLI per call). Instead a persistent TS program
    (`macos/agent-manager/`, `@anthropic-ai/claude-agent-sdk`, NOT in `Ghostty.xcodeproj`,
    built with `npm ci && npm run build`) keeps warm and drives Ghostty's existing **MCP
    server** as a tool provider. **Billing rides Claude Code's own auth** (subscription/pool
    creds the SDK reads on disk) — **NO Anthropic API key in Ghostty** (verified: a bare
    `query()` with no `ANTHROPIC_API_KEY`/`CLAUDE_CODE_OAUTH_TOKEN` succeeds via the pool).
  - **Deterministic loop, single-shot LLM (NOT agentic).** `src/index.ts` polls
    `list_surfaces` every 5s, applies PURE gates (`src/summarizer.ts`:
    `isAgentSurface`/`shouldSummarize`/`fingerprint`/debounce/skip-idle/`ConcurrencyBudget`),
    `read_surface`s the viewport, composes a prompt (baked base `src/prompts.ts` + the
    `~/.config/ghostty-ramon/agent-manager/summarizer.md` override, mtime-cached), makes ONE
    Haiku call (`src/model.ts`: `tools:[]`, `maxTurns:1`, NO `mcpServers` — the summary call
    touches no tools), parses strict JSON, and writes `set_surface_annotation`. MCP I/O is a
    dependency-free fetch JSON-RPC client (`src/mcp.ts`) — no MCP-client dep; tests are
    Node's built-in `node --test`.
  - **Agent DETECTION is via `agentKind`, NOT `processName` (load-bearing gotcha).** Under
    the `claude-pool` wrapper the surface's foreground process is `bash` (and even bare,
    `claude` reports its versioned-binary basename e.g. `2.1.185`), so a
    `processName ∈ {claude,codex}` check NEVER matches a real agent. The Agent Dashboard
    already detects agents via a foreground-pid **subtree walk**; Phase 0 exposes that result
    as `list_surfaces.agentKind` (`AgentDashboardModel.agents` → `HookSnapshotEntry.agentKind`
    → `MCPLayout.SurfaceRow.agentKind` → JSON → `Surface.agentKind`), and `isAgentSurface`
    keys off it (then `agentState`, then `processName`). This also keeps the summarizer's
    notion of "agent" identical to the dashboard's tiles.
  - **Rich summaries need the Claude hooks.** The strongest inputs — the user's `lastPrompt`
    and `agentState` (working/waiting) — arrive via the same Agent-Dashboard `/agent-state`
    hooks (so they only populate on the build the hooks POST to, i.e. the **installed
    Release** on the default MCP port, NOT a dev `+1/+2` port). Without them the summarizer
    falls back to the viewport tail alone and reads thin ("Idle — repo ready"); with them it
    reads rich. Prompt is tunable live via the override file (no rebuild).
  - **SELF-DISABLE (hard requirement, unit-tested).** `AgentManagerController.start()` runs
    the §8 gate `agentManagerShouldStart(enabled, mcpListen, mcpToken, nodePath)` off-main:
    unless `agent-manager` is on AND `mcp-listen`+`mcp-token` are set AND `node` resolves
    (config `agent-manager-node-path`, else a login-shell `command -v node` probe — GUI apps
    don't inherit `PATH`), it stays fully dormant with EXACTLY ONE info log; the dashboard is
    unaffected. The sidecar is spawned/supervised via `Process` (lazy, bounded restart
    backoff — both pure + tested), torn down on quit, run with `GHOSTTY_AGENT_MANAGER=1` so
    its own model activity can't recurse through the agent-state hook.
  - **Phase 0/1 = read-only; ZERO autonomous send, ZERO host/Zig protocol change.** The only
    Zig change is two additive default-off config keys. Safety stays at the MCP boundary
    (later auto-apply will be a separate server-gated tool, not trusted to the sidecar).
    Wiring: core — `src/config/Config.zig` (`agent-manager`/`agent-manager-node-path` + parse
    test); macOS — `macos/Sources/Features/AgentManager/AgentManagerController.swift`,
    `macos/Sources/Features/MCP/MCPAnnotation.swift` (`set_surface_annotation` tool + pure
    `AgentAnnotationPayload.fromArguments` + main-hop handler posting
    `.ghosttyAgentAnnotationDidChange`), `MCPLayout.swift`/`MCPTools.swift` (`agentKind` +
    `list_surfaces` enrichment), `AgentDashboardController.swift`
    (`HookSnapshotEntry.agentKind` + `annotations` store + observer) +
    `AgentPreviewTile.swift` (renders the summary), `Ghostty.Config.swift`
    (`agentManagerEnabled`/`agentManagerNodePath`), `AppDelegate.swift` (off-main start),
    `project.pbxproj` (iOS exclusion); sidecar — `macos/agent-manager/*`. Tests:
    `macos/Tests/AgentManager/AgentManagerControllerTests.swift` (self-disable truth table +
    backoff + URL), `macos/Tests/MCP/MCPAnnotationTests.swift`, the `agentKind`
    `surfacesJSONData` cases in `macos/Tests/MCP/MCPServerTests.swift`, the `agent-manager`
    Zig config test, and the sidecar's `node --test` suite (`npm test` in `macos/agent-manager`).
    **GUI relaunch only** to enable (no host restart); the sidecar must be built
    (`npm ci && npm run build` in `macos/agent-manager`) — not bundled into the app yet, so
    the dev-path `#filePath` resolution points at the repo's `macos/agent-manager/dist`.
  - **PHASE 2 — manager SUGGEST-ONLY (built; refined by Phase 2.1 below).** On a `waiting` tile
    the manager proposes a reply the user can **Approve / Edit / Dismiss**; as of Phase 2.1
    Approve TYPES the (possibly edited) reply into the agent AND submits it in one user-initiated
    tap (was: type-without-submit). **ZERO autonomous send** — the sidecar/manager has
    no send tools; the ONLY send path is Swift, gated behind an explicit Approve tap. Pieces:
    - **Manager pass (`macos/agent-manager/src/manager.ts`, `MANAGER_MODEL=claude-opus-4-8`):**
      a SECOND sweep pass alongside the summarizer, gated `waiting`-only with its own debounce
      + unchanged-skip (`shouldSuggest`), fed goals (`userNotes` + recent prompts) + screen,
      writing a `suggestion` via the merge tool. Like the summarizer it runs `tools:[]` / no
      `mcpServers` (text-only). **SDK-persistence caveat:** the chosen "persistent per-session
      conversation" is NOT cleanly supported by `@anthropic-ai/claude-agent-sdk` v0.3.185, so
      it uses the documented **single-shot-with-accumulated-context** fallback (goals + prior
      suggestion + screen fed each call) — revisit if the SDK gains clean session resume.
    - **Annotation channel is now a MERGE:** `set_surface_annotation` takes summary-OR-suggestion
      and MERGES partial updates into the stored per-surface `AgentAnnotation`, so the summarizer
      (`summary`) and manager (`suggestion`) update INDEPENDENTLY without clobbering
      (`AgentAnnotationPayload.fromArguments` is the partial parser; the model merges).
    - **Per-session `userNotes`** (distinct from `notes`=summary): a persisted-by-`sessionID`
      store mirroring `AgentStateStore` (rehydrated on rebuild), a tile `TextField`, and a
      `list_surfaces.userNotes` enrichment fed to the manager as explicit goals (omitted-when-nil
      — absent until you type a note).
    - **Safety helper (UNUSED in Phase 2):** `macos/Sources/Features/MCP/MCPSafety.swift` —
      a pure destructive-reply denylist (`isAffirmativeReply`, dangerous-screen patterns) +
      tests, staged for the Phase-3 auto-apply gate; no Phase-2 path calls it.
    - Wiring: sidecar — `manager.ts` (+`prompts.ts` `MANAGER_BASE_PROMPT` + `manager.md`
      override + `model.ts` `suggest()` + `index.ts` second pass); macOS — `MCPAnnotation.swift`
      (merge), `AgentStateBridge.swift` (`AgentAnnotation`), `AgentDashboardController.swift`
      (`userNotes` store + merge + observer), `AgentPreviewTile.swift` (suggestion render +
      Approve/Edit/Dismiss + notes field), `MCPInput.swift` (the type-without-submit helper
      Approve calls), `MCPLayout.swift`/`MCPTools.swift` (`userNotes`), `MCPSafety.swift`
      (+iOS exclusion). Tests: `MCPSafetyTests.swift`, the merge/`userNotes` cases in
      `MCPAnnotationTests`/`MCPServerTests`/`AgentDashboardTests`, and the sidecar
      `manager.test.ts` (+ updated `index`/`model`/`prompt` suites). **GUI relaunch + a rebuilt
      sidecar `dist` to enable; no host/Zig change.**
  - **PHASE 2.1 — polish (built; still SUGGEST-ONLY, no autonomous send).** Three changes:
    - **Approve = TYPE + SUBMIT (one tap).** Approve now types the (possibly edited) reply AND
      sends a real Return so it submits in a single user-initiated tap — no second keystroke.
      Still a human tap, not autonomy: `AgentDashboardController.approveSuggestion` calls
      `MCPInput.sendText(submit: true)` (was `false`), reusing the real-key path (Return =
      `KeySpec(keycode: 36)`). `MCPInput.singleLine` STILL collapses INTERIOR newlines so a
      multi-line edit produces exactly ONE trailing Return, not N partial submits — only the
      final trailing Return flipped from suppressed to appended.
    - **Dismiss suppresses re-suggestion until a meaningful change.** "Meaningful" = the
      summarizer's `fingerprint` (agentState|lastPrompt|lastTool + viewport tail) changes.
      Swift: `AgentDashboardModel` tracks per-surface `suggestionDismissed` (set on Dismiss,
      cleared when a merge carries a NEW `suggestion`), plumbed `suggestionDismissed: Bool`
      identically to `userNotes` → `HookSnapshotEntry` → `MCPLayout.SurfaceRow` →
      `list_surfaces` JSON (emitted UNCONDITIONALLY, a plain bool) → TS `Surface.suggestionDismissed?`.
      Sidecar: per-session `suppressedFingerprint` on the loop deps (like the summarizer's
      `lastBySession`); the PURE `shouldSuggest` skips while
      `suppressedFingerprint != null && currentFp == suppressedFingerprint`, and a changed
      fingerprint clears the suppression + re-suggests. Both stores reset independently on a
      fresh suggestion (Swift dashboard flag + TS loop memory) so UI and loop agree.
    - **Suggestion confidence + dim-the-weak.** Manager output JSON gains `confidence` (0..1 =
      the manager's honest self-rating of goal-advancement; `MANAGER_BASE_PROMPT` defines the
      ~0.8–1.0 / ~0.0–0.4 / mid scale). TS `parseSuggestion` parses + clamps to [0,1],
      defaulting ~0.5 when absent/invalid; written via `set_surface_annotation { suggestion,
      confidence }` (Swift `AgentAnnotation.confidence` already shipped in Phase 0). The tile
      renders EVERY suggestion but visually de-emphasizes ones below
      `AgentPreviewTile.CONF_DIM_THRESHOLD` (0.5) via the pure, tested
      `suggestionStyle(confidence:)` (reduced opacity + secondary color) and shows a small inline
      `%` indicator. Tests: sidecar `manager.test.ts` (`shouldSuggest` dismissed cases +
      `parseSuggestion` confidence clamp), `mcp.test.ts` (`setAnnotation` confidence forwarding),
      `index.test.ts` (suppression end-to-end + confidence carry); Swift `AgentDashboardTests`
      (`suggestionStyle` + dismissed-flag lifecycle), `MCPServerTests` (`suggestionDismissed`
      JSON). **GUI relaunch + rebuilt sidecar `dist`; no host/Zig change.**
  - **FIX — manager was never suggesting in a busy fleet (own budget + maxTurns).** Symptom:
    summaries appeared but ZERO suggestions; the sidecar log showed only summarizer lines.
    Two causes: (1) the manager pass SHARED the summarizer's single `ConcurrencyBudget` and
    ran SECOND in `runSweep`, so with ≥`cfg.maxConcurrent` due summaries every sweep (≈12
    agents vs cap 10) the summarizer grabbed all slots and the manager's `tryAcquire()` always
    failed → it never reached its model call. (2) `maxTurns:1` frequently returned
    `subtype=error_max_turns` (the SDK doesn't always settle a clean result in one turn even
    with `tools:[]`), so summarize/suggest calls errored + retried, keeping the shared budget
    saturated. **Fix (sidecar-only):** the manager now has its OWN `ConcurrencyBudget`
    (`ManagerConfig.maxConcurrent`, default 4) — `runSweep` pass 2 + `manageOne` use
    `deps.managerBudget`, never `deps.budget` — so a busy summarizer can't starve it; and
    `model.ts` `maxTurns` 1→3 (no tool loop, so still one text answer — just headroom to reach
    a success result). Regression test: `index.test.ts` "manager is NOT starved when the
    summarizer budget is exhausted". Deploy is a sidecar rebuild + restart only (the GUI's
    `AgentManagerController` respawns it from the repo `dist` — no app relaunch).

## Fork-identity / non-functional changes
- **Bundle id** `com.mitchellh.ghostty-ramon` for Release, `.local` for the in-tree ReleaseLocal dev build, `.debug` for Debug — all coexist with the official `com.mitchellh.ghostty`, each with its own state/defaults domain. (`macos/Ghostty.xcodeproj/project.pbxproj`, `DockTilePlugin.swift` reads the host bundle id at runtime so each domain reads its own defaults.)
- **Display name** "Ghostty (ramon)" for Release, "Ghostty (ramon-local)" for ReleaseLocal — so the installed app and the in-tree dev build are visually distinguishable in the dock and ⌘-Tab.
- **Single-instance guard** in `AppDelegate.applicationWillFinishLaunching`: if another process with the same bundle id is already running from a different bundle URL, that one is activated and this process exits. Stops two copies of the same fork identity from racing each other (e.g. dock-attention bouncing one while you click the other).
- **Icon** defaults to `chalkboard` (`macos-icon` default in `src/config/Config.zig`); macOS swaps it per build at runtime so each identity is distinct at a glance — Release stays on `chalkboard`, ReleaseLocal becomes `paper`, Debug becomes `blueprint`. The swap fires only when the resolved icon is the fork default, so an explicit non-chalkboard `macos-icon` still wins. (`macos/Sources/Features/Custom App Icon/AppIcon.swift`)
- **Auto-update via Sparkle, pinned to the fork's OWN GitHub Releases feed** (was hard-disabled; re-enabled for colleague distribution). Sparkle starts normally but `UpdateDelegate.feedURLString` points at `github.com/ramonsnir/ghostty/releases/latest/download/appcast.xml`, never ghostty.org, so the fork is never replaced by an official build. Dev builds still don't auto-check (`Ghostty-Info.plist` ships `SUEnableAutomaticChecks=false`); the CI release build deletes that key. The committed `SUPublicEDKey` is the fork's OWN real public key (generated at enrollment via Sparkle `generate_keys`; public keys aren't secret), matching the `SPARKLE_PRIVATE_KEY` CI secret; CI re-injects `SPARKLE_PUBLIC_KEY` as belt-and-suspenders. (`UpdateController.hasPlaceholderUpdateKey` still guards the all-zero placeholder so a future placeholder build fails closed.) See "Distribution / sharing the fork" below. (`macos/Sources/Features/Update/{UpdateController,UpdateDelegate}.swift`)
- **App Nap opt-out (fork-only, macOS; always on)** — `AppDelegate.applicationDidFinishLaunching` holds a process-lifetime `ProcessInfo.beginActivity(.userInitiatedAllowingIdleSystemSleep)` token (`appNapAssertion`) so macOS never naps/throttles the GUI while backgrounded or occluded. **Load-bearing for the `.client` backend:** the host connection is opened from per-surface IO threads at surface creation and is **single-shot (no retry — see `src/termio/Client.zig` `connectAndAttach`)**, so if the GUI is relaunched into the background with **no active display** (a remote restart while away), App Nap can suspend those threads before they connect to `ghostty-host`, leaving every restored surface permanently blank until a manual restart-while-present. This is exactly the 2026-06 weekend symptom ("restarted Ghostty remotely while away → monitor showed empty surfaces all weekend; restarting while at the Mac fixed it"). The `...AllowingIdleSystemSleep` option opts out of App Nap **without** preventing system/display sleep (it omits the idle-sleep-disable bits), so battery/sleep behavior is unchanged — we only decline to be napped (it also disables sudden/automatic termination, desirable for a terminal). Note: a connect-retry/reconnect in the `.client` backend was considered and **deliberately skipped** — the host is a KeepAlive LaunchAgent (≈always up, so connect rarely fails) and a dropped host can't restore RAM-only sessions anyway, so it was high-risk surgery on the most delicate lifecycle code for an unobserved failure mode. (`macos/Sources/App/macOS/AppDelegate.swift`)
- **Config separation**: the fork additionally loads `~/.config/ghostty-ramon/config` on top of the shared `~/.config/ghostty/config`. Put fork-only keybinds **and fork-only config keys** there so an official Ghostty (which shares `~/.config/ghostty/config`) never errors on unknown actions or keys. Fork-only config keys so far: `project-directory`, `bell-features-focused`, `web-monitor-listen`, `web-monitor-token`, `mcp-listen`, `mcp-token`, `agent-dashboard`, `agent-dashboard-commands`, `agent-dashboard-pin`, `agent-manager`, `agent-manager-node-path`. (`src/config/file_load.zig` `forkXdgPath`, `Config.zig` `loadDefaultFiles`)

- **Config files & secrets** (tracked example copies): the repo keeps reference
  copies of both live config files under **`example/`** — `example/ghostty/config`
  (mirror of the shared `~/.config/ghostty/config`) and `example/ghostty-ramon/config`
  (mirror of the fork-only `~/.config/ghostty-ramon/config`). These are the starting
  point for setting the fork up on a new Mac (clone, build, copy these two into
  `~/.config/`). **Keep them byte-for-byte identical to the on-disk files** — whenever
  you change either live config, re-copy it into `example/` in the same commit. **They
  must contain NO secrets and NO per-machine values.** Secrets + machine-specific
  values instead live in the **untracked** `~/.config/ghostty-ramon/local`, which the
  tracked fork config pulls in via an optional include
  (`config-file = ?~/.config/ghostty-ramon/local` — the `?` suppresses the
  file-not-found error, and config-file entries load *after* the file that defines
  them, so `local` cleanly supplies/overrides values). What lives in `local` today:
  `mcp-token` (a shell-execution credential) and `web-monitor-listen` (this Mac's
  Tailscale IP). When adding a new secret or per-machine key, put it in `local`, not in
  the tracked config. On a new machine, create `local` by hand (generate a fresh
  `mcp-token` with `openssl rand -hex 24`, set that Mac's own Tailscale IP); if `local`
  is absent the fork still launches (web monitor + MCP just disabled / token-less).

## Distribution / sharing the fork (colleague builds, CI release, auto-update)

The fork can be shared with colleagues as a signed/notarized DMG, auto-released by
CI on every push to `main`, with in-app Sparkle updates. **User-facing guide:
`SHARING.md`.** The load-bearing facts for an agent touching this code:

- **Sparkle is RE-ENABLED but pinned to the fork's OWN feed.** `UpdateController`'s
  three methods (startUpdater/checkForUpdates/validateMenuItem) are restored to the
  real upstream implementation; `UpdateDelegate.feedURLString` points BOTH channels
  at `https://github.com/ramonsnir/ghostty/releases/latest/download/appcast.xml`
  (never ghostty.org — so the fork is never replaced by an official build). The
  committed `Ghostty-Info.plist` still ships `SUEnableAutomaticChecks=false`, so dev
  builds never auto-check; the CI release build DELETES that key (enables checks) and
  injects the fork's `SUPublicEDKey`. Wiring: `macos/Sources/Features/Update/{UpdateController,UpdateDelegate}.swift`.

- **First-launch setup (`ForkSetup`, GUI-only, distribution builds).** On launch the
  app (off-main, in `AppDelegate.applicationDidFinishLaunching`) runs
  `ForkSetup.perform()`, which is idempotent and does three jobs: (1) seed a sanitized
  `~/.config/ghostty-ramon/config` if absent (embedded `seedTemplate`, `__HOME__`
  substituted, personal launchers commented out, open `mcp-listen`/`web-monitor-listen`
  disabled — opt-in via `local`); (2) install/version-reload a launchd LaunchAgent for
  a `ghostty-host` BUNDLED at `Contents/MacOS/ghostty-host`; (3) install the bundled
  `ghostty-mcp` shim onto PATH (see the MCP-shim bullet below). **Two safety gates make it
  impossible to clobber a hand-managed host** (Ramon's own dev setup uses the SAME label
  `com.mitchellh.ghostty-ramon.host`): it only acts when a host is actually bundled
  (local/dev builds skip — they don't bundle it), and it writes an ownership marker
  (`GhosttyAppManaged` = bundle id) into any plist it creates, refusing to touch a
  pre-existing plist that lacks the marker. The version-aware reload (bootout+bootstrap,
  never kill) re-derives launchd's LWCR after a Sparkle update gives the bundled host a
  new cdhash — encoding the LWCR gotcha (below) into the app. Pure planner `plan(...)`,
  `makeSpec`, `configSeedContents`, `readPlistMarker` are unit-tested. Wiring:
  `macos/Sources/Features/ForkSetup/ForkSetup.swift`, `AppDelegate.swift` (the
  off-main call), `project.pbxproj` (iOS exclusion). Tests:
  `macos/Tests/ForkSetup/ForkSetupTests.swift`.

- **PRIMARY release path = LOCAL + FREE (`dist/macos/release-local.sh`).** Builds +
  signs + notarizes + DMGs + appcasts + `gh release`-publishes on your Mac. **Why not
  CI:** GitHub macOS runners bill at ~10x, the actool/Liquid-Glass-icon crash forces the
  scarce native `macos-26` image (long queues), and a backlogged Apple notary can sit
  `In Progress` until the 90-min job timeout — one run cost ~$9 of macOS minutes for a
  release that never even published. Notarization is Apple's FREE service; only the CI
  *runner time* costs money, so doing it locally is $0 (notary slowness = wall-clock
  only). Release assets are free and separate from Git LFS. Run it from `ramon-fork`
  on the main tree. **One-time per machine:** Developer ID cert in the login keychain;
  Sparkle private key in the keychain (`sign_update` uses it automatically — no file);
  `sign_update`+`generate_keys` on PATH (copied to `~/.local/bin`) and `create-dmg`
  (`npm i -g create-dmg`); a notary keychain profile —
  `xcrun notarytool store-credentials ghostty-ramon-notary --key <AuthKey.p8> --key-id <ID> --issuer <UUID>`.
  **NOTARY GOTCHA (cost me a real chase):** a freshly-enrolled Apple Developer account's
  FIRST notarizations can sit `status: In Progress` for HOURS (Apple-side provisioning /
  service backlog) — NOT a bug in our artifact (it'd be `Invalid`, with a `notarytool log`,
  if the zip were bad). Don't burn CI on it (that's how the ~$9 evaporated). Check
  `developer.apple.com/system-status` (Developer ID Notary Service) + that no Program
  License Agreement is pending in the account, then just re-run the local script once
  the service is healthy; `xcrun notarytool history --keychain-profile ghostty-ramon-notary`
  shows whether old submissions ever drained.
- **CI release (`.github/workflows/fork-release.yml`) — MANUAL-ONLY fallback.** Its
  `on:` is `workflow_dispatch` only (NOT `push`) precisely so normal pushes don't burn
  macOS minutes; trigger it by hand only if you can't build locally (and expect
  `macos-26` queue + notary cost). It builds on `macos-26` (the `macos-15` image crashes
  AssetCatalogAgent on the Liquid Glass `.icon` via a MediaToolbox override cryptex).
  Fork-only (`if:
  github.repository == 'ramonsnir/ghostty'`); the inherited upstream workflows are
  already inert on the fork (owner/tag/repo guards), so no neutering. Builds the
  xcframework + `ghostty-host` (`nix develop -c zig build … -Demit-macos-app=false`),
  builds the app (`xcodebuild -configuration Release` → already the fork's Release id +
  display name), bundles + signs the host AND the `ghostty-mcp` shim inside the app, injects
  `CFBundleVersion=git rev-list --count HEAD` (monotonic — Sparkle compares this),
  signs/notarizes/staples, builds the DMG (`create-dmg`), generates a SINGLE-item signed
  appcast (`dist/macos/fork_appcast.py`, enclosure → the release's DMG URL), and
  publishes a `build-<N>` GitHub Release marked `--latest` (so the
  `releases/latest/download/{Ghostty.dmg,appcast.xml}` URLs resolve). **Signing is
  gated on secrets** (`HAS_SIGNING`): without them the job is a build-only smoke test
  that uploads the unsigned `.app` as an artifact and creates NO release. Secrets
  (fork-owned): `MACOS_CERTIFICATE`/`_PWD`/`_NAME`, `MACOS_CI_KEYCHAIN_PWD`,
  `APPLE_NOTARIZATION_ISSUER`/`_KEY_ID`/`_KEY`, `SPARKLE_PRIVATE_KEY`/`SPARKLE_PUBLIC_KEY`.

- **The host is bundled IN the app for colleagues** (vs. Ramon's `~/.local/bin`
  hand-deploy), so Sparkle — which only updates the `.app` — carries new host builds,
  and notarization covers the host automatically. A colleague's update flow restarts
  the host (ends live sessions, RAM-only) exactly like Ramon's manual reload.

- **The `ghostty-mcp` shim is bundled + installed-to-PATH for colleagues too** — same
  pattern as the host, so the MCP agent-control feature isn't dropped from the DMG. CI
  `swift build -c release`s the shim and copies+signs it into `Contents/MacOS/ghostty-mcp`
  (alongside the host, inside the notarized bundle, carried by Sparkle). On first launch
  `ForkSetup.installShimIfNeeded` copies it onto PATH at `~/.local/bin/ghostty-mcp`
  (version-aware via `kInstalledShimVersion`; reinstalls on a Sparkle bump or a manual
  delete). **Safety is symmetric with the host:** `planShimInstall` only acts when a shim
  is actually BUNDLED, and the whole of `perform()` early-returns unless a host is bundled
  — so a dev/local build never overwrites Ramon's hand-installed `~/.local/bin/ghostty-mcp`.
  The copy is a byte-level `Data.write(.atomic)` (NOT `copyItem`) so the bundle's quarantine
  xattr doesn't propagate to the loose copy. A colleague then registers with
  `claude mcp add ghostty -- "$HOME/.local/bin/ghostty-mcp"` (token auto-read from `local`);
  the committed `.mcp.json` (bare `ghostty-mcp`) serves repo-clone developers, not DMG users.
  Wiring: `.github/workflows/fork-release.yml` (build+bundle+sign steps),
  `macos/Sources/Features/ForkSetup/ForkSetup.swift` (`ShimPlan`/`planShimInstall`/
  `installShimIfNeeded`); tests in `macos/Tests/ForkSetup/ForkSetupTests.swift` (`shim*`).

## PTY-host runs under a launchd LaunchAgent (deploy + new-machine setup)

The `ghostty-host` process (the fork's emulation-on-host backend — see
top-level `PTYHOST.md`) is **not** launched by the GUI app or a login script. It
runs as a **user LaunchAgent** `com.mitchellh.ghostty-ramon.host`
(`~/Library/LaunchAgents/com.mitchellh.ghostty-ramon.host.plist`, `KeepAlive=true` +
`RunAtLoad=true`). The GUI merely connects to its socket
(`pty-host = ~/.ghostty-ramon-host.sock` in the fork config). One long-lived host
serves every GUI restart; a **host** restart still loses all live sessions
(RAM-only). Locations: binary `~/.local/bin/ghostty-host`, socket
`~/.ghostty-ramon-host.sock`, combined stdout+stderr log
`~/Library/Logs/ghostty-ramon-host.log`.

**Canonical plist — replicate verbatim on every laptop for environment consistency.**
launchd requires ABSOLUTE paths (no `~`/env expansion in `ProgramArguments` or the
socket path), so **replace `/Users/ramon` with that machine's home** (and keep
`pty-host` in the config pointing at the same absolute socket path):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.mitchellh.ghostty-ramon.host</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/ramon/.local/bin/ghostty-host</string>
        <string>--listen=/Users/ramon/.ghostty-ramon-host.sock</string>
    </array>
    <!-- ReleaseFast host honors GHOSTTY_RESOURCES_DIR first; point it at the installed
         bundle so the child shell gets TERM=xterm-ghostty + a valid TERMINFO. -->
    <key>EnvironmentVariables</key>
    <dict>
        <key>GHOSTTY_RESOURCES_DIR</key>
        <string>/Applications/Ghostty (ramon).app/Contents/Resources/ghostty</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardOutPath</key><string>/Users/ramon/Library/Logs/ghostty-ramon-host.log</string>
    <key>StandardErrorPath</key><string>/Users/ramon/Library/Logs/ghostty-ramon-host.log</string>
</dict>
</plist>
```

**New-machine setup (one-time):** (1) build the host
(`zig build -Demit-macos-app=false -Doptimize=ReleaseFast`) and copy
`zig-out/bin/ghostty-host` → `~/.local/bin/ghostty-host`; (2) write the plist above
(fix the home path) to `~/Library/LaunchAgents/…`; (3)
`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.mitchellh.ghostty-ramon.host.plist`
(RunAtLoad starts it); (4) ensure `pty-host = <that socket>` is in the fork config.

### ⚠️ After redeploying the host binary, RELOAD the agent — NEVER just `kill` it
launchd pins a code-signing launch requirement (**LWCR**) to the host binary's
**code identity (cdhash)**. The fork builds `ghostty-host` **ad-hoc / linker-signed**,
so **every rebuild has a new cdhash**. If you swap `~/.local/bin/ghostty-host` under a
running job and then merely `kill` it, `KeepAlive` respawns the NEW binary under the
OLD pinned requirement → launchd rejects it → it **exits 78 (`EX_CONFIG`) before it
can even write a log line** → hot crash loop (`launchctl print …` shows
`last exit code = 78`, `needs LWCR update`, and `runs` climbing) → nothing binds the
socket → **the GUI shows empty screens**. The binary is fine — it runs perfectly
standalone, even with the exact plist env; only launchd rejects it. (This cost a long
debug session on 2026-06-17; the symptom "I killed the host and a new window didn't
relaunch it / empty screens" is THIS.)

**Correct deploy-then-restart of the host** (run from a NON-ramon terminal —
Terminal.app or the official Ghostty — since it ends every session, including this
Claude Code one if it lives under the host):
```sh
# 1) deploy without disturbing the running host: atomic rename keeps the live
#    process's inode (a plain `cp` over it risks ETXTBSY / corrupting it).
cp /path/to/repo/zig-out/bin/ghostty-host ~/.local/bin/ghostty-host.new
chmod +x ~/.local/bin/ghostty-host.new
mv -f ~/.local/bin/ghostty-host.new ~/.local/bin/ghostty-host
# 2) RELOAD (bootout+bootstrap) so launchd re-derives the LWCR from the new binary.
#    Do NOT `kill` — KeepAlive would crash-loop the new binary under the stale LWCR.
launchctl bootout   gui/$(id -u)/com.mitchellh.ghostty-ramon.host
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.mitchellh.ghostty-ramon.host.plist
# 3) verify healthy: pid set, runs=1, "(never exited)", and "server listening" in the log.
launchctl print gui/$(id -u)/com.mitchellh.ghostty-ramon.host | grep -iE 'pid =|last exit|runs ='
```
After the host comes back, **open fresh tabs/windows** — surfaces attached to the
pre-restart sessions are dead (sessions are RAM-only). Note: `pkill`/`pgrep -f
ghostty-host` do NOT match the host's cmdline on macOS; to find the pid use
`ps ax -o pid,command | grep '[g]hostty-host --listen'`. A stale socket file is NOT a
problem — the host unlinks-and-rebinds.

## Iteration lifecycle (macOS)

> 🛑 **STOP — READ THIS BEFORE YOUR FIRST `Edit`/`Write`.** Claude keeps
> violating this rule: it reads the task, jumps straight to editing files on
> the main tree's `ramon-fork` checkout, and only *then* commits there. **That
> is wrong every single time, even for a "one-line" / "trivial" change, even
> when you're "already on `ramon-fork`", even when the user says "just commit
> it".** Being on `ramon-fork` is NOT permission to edit it — it is the exact
> state the worktree rule exists to protect. The very fact that you're tempted
> to skip the worktree "because it's small" is the violation. The installed
> Release fork builds from this checkout and hosts the live Claude Code
> session; a dirty/half-edited `ramon-fork` here can break the next rebuild
> under you. So: **before editing ANY tracked file, your FIRST action is to
> create a worktree** (command below) and `cd` into it. If you've already made
> edits on the main tree before realizing this, stop, `git stash`, move to a
> worktree, and `git stash pop` there. When the work is done, merge the branch
> back into `ramon-fork` as described at the end of this section. No exceptions,
> no "this once."

**Always work on a git worktree, never directly on the main tree's `ramon-fork`
checkout.** Create a worktree for each task **inside `.claude/worktrees/`**
(`git worktree add .claude/worktrees/<task> -b <branch> ramon-fork`) — **NOT in
the repo's parent dir (`../ghostty-<task>`), which clutters `~/git/`**. The
`.claude/worktrees/` dir is gitignored, so the nested checkout (and its build
artifacts) never show up in the main tree's `git status`. Do all editing/testing
there, keep the main tree's `ramon-fork` checkout clean, and remove the worktree
when done (`git worktree remove .claude/worktrees/<task>`). **Release builds must ALWAYS come from `ramon-fork`
on the main tree** — never build a Release (the installed `/Applications/Ghostty
(ramon).app`) from a worktree branch. So when the work is done: **merge the
worktree branch into `ramon-fork`, switch the main tree to `ramon-fork`, and
rebuild there.** (The reason the worktree exists is precisely so the installed
Release that hosts this session keeps building from a stable `ramon-fork`.)

Toolchain: full **Xcode** (not just Command Line Tools) + Metal toolchain + accepted
license; **Homebrew `zig@0.15`** (the official 0.15.2 tarball has a broken linker on
this macOS); `nushell` for `build.nu`.

1. Edit code (Zig core in `src/`, macOS in `macos/Sources/`).
2. **Zig tests**: `zig build test -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=<name>`.
3. **Rebuild lib** (required after any Zig change before the app build): `zig build -Demit-macos-app=false -Doptimize=ReleaseFast`.
   - **⚠️ Rebuild the lib WITH the xcframework — never pass `-Demit-xcframework=false` here.** The app links the **xcframework**, not the bare lib, so if you skip emitting it (as you correctly do for the *test* command in step 2) the app silently links the **stale** xcframework and your Zig change is invisible to the GUI, even though `zig build` succeeded and the Zig/host tests pass. The default emits it; just `zig build -Demit-macos-app=false -Doptimize=ReleaseFast`. **Symptom of the trap:** host + Zig tests green, the `ghostty-host` binary behaves correctly, but the GUI acts as if the lib change isn't there — e.g. after bumping the host protocol minor, the app kept advertising the OLD minor, so the host withheld the new frame and a whole feature silently no-op'd (this cost most of the Agent Dashboard detection-debug session). Same class of mistake as the LWCR/host-reload gotcha below: the build "succeeds" but ships a stale artifact. After a protocol/lib change, also `rm -rf macos/build/ReleaseLocal` before the app build so Xcode can't reuse a stale embedded framework.
4. **Swift tests**: `macos/build.nu --action test` (or `xcodebuild … -only-testing:GhosttyTests/SplitTreeTests test`).
5. **Build the app**: `macos/build.nu --configuration ReleaseLocal --action build` → `macos/build/ReleaseLocal/Ghostty.app` (optimized, no debug banner). This produces "Ghostty (ramon-local)" with bundle id `com.mitchellh.ghostty-ramon.local` — runs side-by-side with the installed Release identity.
6. **Install/update the fork** over `/Applications/Ghostty (ramon).app`. Verified to be safe to run while the installed Release fork is still hosting Claude Code's shell — `ditto` and `PlistBuddy` don't disturb the running mmap'd binary, and `codesign` succeeds after stripping Apple's `com.apple.provenance` xattrs. The new binary only takes effect on the next launch, so the user still has to quit + relaunch themselves.

   **You MAY run this block WITHOUT asking — but ONLY when BOTH hold: (a) the
   ReleaseLocal app being installed was built from `ramon-fork` on the main tree,
   NOT from a worktree/feature branch (see the worktree rule above — a branch build
   must first be merged to `ramon-fork` and rebuilt there); AND (b) the change is
   GUI-only and does NOT touch the host (`src/host/`, `src/termio/`, or any core that
   links into `ghostty-host`).** When both hold, the deploy is non-disruptive: it
   overwrites the installed binary but `ditto`/`PlistBuddy`/`codesign` don't disturb
   the running mmap'd process, it does NOT restart the host, and the new binary only
   takes effect on the user's next relaunch — so it can't break this session and GUI
   restarts are free. **ASK FIRST if EITHER condition fails** — a host change forces a
   LaunchAgent reload that ends every live session (schedule it deliberately — see the
   "Host code changed too?" note below), and a branch build must not become the
   installed Release. The block:
   ```sh
   APP="/Applications/Ghostty (ramon).app"
   ditto macos/build/ReleaseLocal/Ghostty.app "$APP"
   /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.mitchellh.ghostty-ramon' "$APP/Contents/Info.plist"
   /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Ghostty (ramon)' "$APP/Contents/Info.plist"
   xattr -cr "$APP"                          # codesign rejects provenance xattrs
   codesign --force --deep --sign - "$APP"
   ```
   Note this is NOT a straight copy: ReleaseLocal is its OWN identity ("Ghostty
   (ramon-local)", bundle id `…ghostty-ramon.local`, MCP/web-monitor ports `+1`,
   `paper` icon). The two `PlistBuddy` lines **re-stamp it INTO the Release identity**
   by overwriting `CFBundleIdentifier` → `com.mitchellh.ghostty-ramon` + the display
   name; everything else identity-derived (the MCP/web-monitor port offset and the
   runtime icon swap) keys off the bundle id at launch, so that one re-stamp converts
   the whole identity to Release (`+0`, `chalkboard`). Never touch `/Applications/Ghostty.app`.

   **Host code changed too?** The installed app and `ghostty-host` are SEPARATE
   deploys. If your change touched anything the host runs (`src/host/`,
   `src/termio/`, emulation/core that links into the host), the new `ghostty-host`
   must be deployed **and the LaunchAgent reloaded via bootout+bootstrap (never
   `kill`)** — see *PTY-host runs under a launchd LaunchAgent* above. That restart
   ends every live session; schedule it deliberately.
7. **Commit** to `ramon-fork`.

## ⚠️ Safety
**Two remotes — push ONLY to `fork`, NEVER to `origin`.**
- `origin` = *upstream* `ghostty-org/ghostty` (the official repo). **Never push here.**
  A push to `origin` would shove personal work at the official project.
- `fork` = personal backup `git@github.com:ramonsnir/ghostty.git`. Back it up with a
  **bare `git push fork`** (no refspec). The `fork` remote has a pinned push refspec
  (`remote.fork.push = refs/heads/ramon-fork:refs/heads/main`), so `git push fork`
  **always** pushes local `ramon-fork` → `fork/main`, **regardless of which branch is
  currently checked out** — you can run it from any local feature branch and it still
  backs up `ramon-fork`, never the feature branch.
  - **Do NOT add an explicit refspec** like `git push fork HEAD:main` — an explicit
    refspec overrides the pinned one and, from a feature branch, would overwrite
    `fork/main` with the wrong branch. Always use the bare `git push fork`.

So pushing to `fork` is now allowed and is the backup path; just confirm the
remote is `fork` before pushing, and **never** `git push origin`. Any local-only
feature branches (the old `ptyhost/*` ones are gone, merged into `ramon-fork`) have
no remote set — leave them local-only unless explicitly asked to back them up to
`fork`, and remember a bare `git push fork` backs up `ramon-fork`, not them.

NEVER run `osascript -e 'quit app "Ghostty"'` — the fork and the official build are
both *named* "Ghostty", so it's ambiguous and can quit the user's real, working
Ghostty.

**Also never quit the installed Release fork (`com.mitchellh.ghostty-ramon`) — it
normally hosts the shell Claude Code is running in, so quitting it (even by
bundle id) terminates this session mid-task.** The three identities exist
specifically so iteration doesn't touch the host:

| Identity | Bundle id | Path | Safe to quit/launch? |
|---|---|---|---|
| Release (installed) | `com.mitchellh.ghostty-ramon` | `/Applications/Ghostty (ramon).app` | **No** — usually hosts this session |
| ReleaseLocal | `com.mitchellh.ghostty-ramon.local` | `macos/build/ReleaseLocal/Ghostty.app` | Yes |
| Debug | `com.mitchellh.ghostty-ramon.debug` | `macos/build/Debug/Ghostty.app` | Yes |

To restart the dev fork, target precisely:
`osascript -e 'tell application id "com.mitchellh.ghostty-ramon.local" to quit'`
(or `.debug`), or kill the PID whose path is under `macos/build/`. For the
installed Release, the install block in step 6 of the iteration lifecycle is
safe to run while the host is live (ditto/plist/codesign don't disturb the
running binary) and **may be run WITHOUT confirmation** when the deploy is
GUI-only from a `ramon-fork` build (see step 6 for the exact two conditions; a
host change or a branch build still needs to be raised with the user first).
Either way, let the user quit + relaunch the installed Release themselves to
pick up the new binary.

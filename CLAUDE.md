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
    accepted like the bootstrap); `GET /api/surfaces` (`{agentDashboard:Bool,
    surfaces:[{id,title,pwd,…,isAgent,hidden}]}` — the response is an OBJECT, not a bare
    array; see the agent-filters note below); `GET
    /api/surface/{uuid}/stream` (raw-byte xterm source; needs `pty-host`); `GET
    /api/surface/{uuid}/screen?mode=viewport|scrollback` (plain-text fallback, reuses
    `cachedVisibleContents`/`cachedScreenContents`); `POST /api/surface/{uuid}/input`; `POST
    /api/surface/{uuid}/scroll` (`{"dy":±ticks}`). Unknown id/path → 404, wrong method → 405,
    bad/negative/oversized Content-Length → 400, chunked → 411, oversized → 413, bad Host → 403,
    throttled (token mode) → 429.
  - **Agent filters (fork-only, GUI-only) — list-only "Agents only" / "Hide hidden".** The
    page's session list has two checkboxes that MIRROR the Agent Dashboard: keep only detected
    CLI-agent splits, and/or drop splits hidden in the dashboard. Both DEFAULT ON (so the phone
    opens showing only your non-hidden agents) and persist per device in `localStorage`
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
    - **Smart bottom-anchor — skip empty rows AND the info-less footer (fork-only,
      always on, no config, PURE-SWIFT / ZERO Zig).** A bottom-anchored thumbnail of a
      partially-filled screen (a fresh agent chat, a TUI not yet at the bottom) wastes
      the preview on empty trailing rows; worse, an idle Claude Code/Codex agent ALWAYS
      pins its input box + mode/status lines at the bottom, so the meaningful content is
      pushed off-view. So the preview shifts the bottom-anchored mirror DOWN by the
      number of trailing rows to drop — blanks PLUS a detected footer — so the LAST row
      of CONTENT lands at the bottom (the dropped rows fall below the clip). It does NOT
      collapse interior repeated/blank lines (the native Metal mirror renders the host
      grid as-is — no seam to inject a "… N more …" marker; that would need a separate
      self-rendered text preview that loses color/TUI fidelity — deliberately not done).
      - **Row source is the existing `cachedVisibleContents`, NOT a new core getter.**
        Under pty-host the GUI mirror's `dumpText` is row-accurate (exactly one text line
        per grid row, no soft-wrap, blank rows preserved, every row newline-terminated),
        so `realSurface.cachedVisibleContents.get()` split on `\n` (drop one trailing "")
        IS the viewport grid. (An EARLIER attempt added a Zig `RenderState.trailingBlankRows()`
        core getter + C export for a grid-accurate blank count — reverted in favor of this,
        since the mirror text is already row-accurate and pure-Swift keeps it GUI-only +
        tunable with no host-linking change.) `read_text`'s general path is NOT usable for
        a row count (it uses `unwrap=true` + trims trailing blanks) — but the **mirror**
        path (the only one the dashboard hits) does neither, which is what makes this work.
      - **Footer detection is CONSERVATIVE — never hides content** (the load-bearing
        design constraint, found by reading real screens). `AgentMirrorPreview.chromeTrailingSkip(rows:)`
        (pure, tested) peels trailing chrome and stops at the first row with REAL content,
        so nothing meaningful is hidden. It peels, from the bottom: (1) up to
        `maxStatusLines` (3) status/help lines — plain text with NO box-drawing (e.g.
        `⏵⏵ auto mode on…`, `↑↓ select · x stop workflow…`); the no-box-drawing test is what
        distinguishes an outside-the-box status line from a filled box-interior row (which
        carries `│`); then (2) it REQUIRES a horizontal-rule row (`─`×≥12 — a box's bottom
        border; ASCII `-` does NOT count, so markdown rules are safe) or it bails to
        blanks-only; then (3) it peels the box's structural rows upward — borders (incl. a
        border carrying embedded status text, e.g. the claude-pool line), empty interior
        cells (`│   │`), the empty `❯` prompt, and blank gap — stopping at the first
        real-content row. This handles BOTH the input box AND content boxes: the
        `/workflows` viewer's filled phase rows are real content (kept), while its empty
        interior tail + bottom border + help line are dropped; a permission prompt keeps its
        question/options and only loses the bottom border. (The earlier version special-cased
        a SMALL empty-interior input box and rejected tall boxes via a `maxBoxRows` cap — that
        preserved the whole `/workflows` box including its wasted empty bottom; the unified
        peel replaced it.) **GOTCHA
        (the "nothing changed for two builds" bug, fixed):** Claude Code pads the prompt
        line with a **NO-BREAK SPACE U+00A0**, not a normal space — `❯\u{00A0}…` — and the
        rule rows are real U+2500 (confirmed by hexdumping the live `cachedVisibleContents`).
        `isEmptyInteriorRow`/`isBlankRow` therefore test the **Unicode whitespace property**
        (covers U+00A0), NOT just U+0020/U+0009; the old codepoint-only check read the NBSP
        as content, so the interior never looked empty and `chromeTrailingSkip` returned 0
        for EVERY footer. The per-tile refresh also runs off a `.task` poll tied to view
        identity (not a `Timer.publish`, which restarts on every re-render). Handles both
        Claude Code footer shapes (full-width `───`/`❯`/`───` rules and rounded `╭─╮`/`│ │`/
        `╰─╯` boxes). When a footer IS found it also drops the ENTIRE blank gap above it
        (not just one separator) — a near-empty session has content at the TOP, a big blank
        gap, then the footer pinned at the bottom, so absorbing the whole gap lands the last
        real content row at the bottom instead of a blank row mid-gap.
      - The offset is a pure, tested `AgentMirrorPreview.bottomAnchorOffset(skipRows:…)`
        (clamped to `rows-1` so an all-blank screen keeps one row visible), refreshed by
        `refreshSkipRows()` on a light ~0.8s per-tile `.task` poll (live frames render off
        the Metal path, not via `@Published`, so a poll — not an observer — drives it).
        Limitation: a placeholder prompt (`❯ Try "…"`) reads as non-empty interior → the
        box is shown (conservative); most active agents show a bare `❯`. **GUI-only, no
        Zig/host change, GUI relaunch to pick up.** Wiring: `AgentDashboard/AgentPreviewTile.swift`
        (`chromeTrailingSkip` + `isRuleRow`/`isEmptyInteriorRow`/`isBlankRow` +
        `bottomAnchorOffset` + `refreshSkipRows` + `.offset` + timer). Tests:
        `macos/Tests/AgentDashboard/AgentDashboardTests.swift` (`ChromeTrailingSkipTests`
        — grounded in real captured footers — + `BottomAnchorOffsetTests`).
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
  It is **read-only** — it annotates the tile and NEVER types into a session. **See
  `AGENT-MANAGER.md` for user-facing config/usage.** The load-bearing facts for an agent
  touching this code:
  - **A warm TypeScript Agent SDK sidecar is the brain; the MCP server is its hands.**
    `claude -p` was rejected (cold-boots the CLI per call). Instead a persistent TS program
    (`macos/agent-manager/`, `@anthropic-ai/claude-agent-sdk`, NOT in `Ghostty.xcodeproj`,
    built with `npm ci && npm run build`) keeps warm and drives Ghostty's existing **MCP
    server** as a tool provider. **Billing rides Claude Code's own auth** (subscription/pool
    creds the SDK reads on disk) — **NO Anthropic API key in Ghostty** (verified: a bare
    `query()` with no `ANTHROPIC_API_KEY`/`CLAUDE_CODE_OAUTH_TOKEN` succeeds via the pool).
  - **Deterministic loop, single-shot LLM (NOT agentic).** `src/index.ts` polls
    `list_surfaces` every 5s, applies PURE gates (`src/summarizer.ts`:
    `isAgentSurface`/`shouldSummarize`/change-detection/debounce/skip-idle/`ConcurrencyBudget`),
    `read_surface`s the viewport, composes a prompt (baked base `src/prompts.ts` + the
    `~/.config/ghostty-ramon/agent-manager/summarizer.md` override, mtime-cached), makes ONE
    Haiku call (`src/model.ts`: `tools:[]`, `maxTurns:3`, NO `mcpServers` — the summary call
    touches no tools), parses strict JSON, and writes `set_surface_annotation`. MCP I/O is a
    dependency-free fetch JSON-RPC client (`src/mcp.ts`) — no MCP-client dep; tests are
    Node's built-in `node --test`.
  - **COST CONTROLS — skip-hidden + animation-proof fuzzy change + quiescent-skip +
    config (the "Haiku burns my usage" fix).** Four levers cut the call rate; the dominant
    sink was a quiescent (`waiting`/`idle`) agent whose ANIMATED footer (spinner / "esc to
    interrupt" / elapsed-time counter) flipped the old exact-hash `fingerprint` every poll,
    so it re-summarized every debounce window forever. **(1) Skip hidden tiles:** the
    dashboard's `hidden` set is now exposed through `list_surfaces` (Swift:
    `HookSnapshotEntry.hidden` unioned from `model.hidden` → `MCPLayout.SurfaceRow.hidden`,
    emitted only when true; TS: `Surface.hidden`), and BOTH `preGate` (so a hidden tile skips
    the `read_surface` entirely) and `shouldSummarize` short-circuit `{reason:"hidden"}` when
    `cfg.skipHidden` (default true). **(2) Fuzzy change detection (replaces the binary
    `fingerprint`):** `LastSummary` now stores `signals` (exact hash of the AUTHORITATIVE hook
    tuple agentState|lastPrompt|lastTool — any diff = change) + `tail` (the NORMALIZED
    change-tail kept as TEXT). `changeTail` strips spinner glyphs (Braille U+2800–28FF + dot/
    bar spinners) and collapses digit-runs→`#` and whitespace via `normalizeChangeLine`, so an
    animated footer normalizes to a STABLE string; `tailChangeRatio` is the Jaccard distance
    over the NON-BLANK line MULTISETS (scroll-tolerant), and the screen counts as CHANGED only
    when `ratio > cfg.changeRatioThreshold` (default 0.2). **(3) Quiescent-skip:** an unchanged
    `waiting`/`idle` agent (`isQuiescent`) is skipped REGARDLESS of `idleSeconds` (its summary
    won't change); a non-quiescent unchanged surface keeps the old idle-seconds skip / else
    re-summarizes so a `working` agent's phase still tracks. **(4) Config overlay
    (`src/config.ts`, no rebuild):** `~/.config/ghostty-ramon/agent-manager/config.json` (pure
    `parseConfig` overlay on `DEFAULT_CONFIG` over an injected `readFile`, restart-to-apply,
    malformed/unknown keys ignored) tunes `debounceMs` (default RAISED 12000→**30000**),
    `changeRatioThreshold`, `skipHidden`, `idleSkipSeconds`, `maxConcurrent`,
    `agentProcessNames`. The `fingerprint()` fn is GONE (replaced by
    `changeSignals`/`changeTail`/`tailChangeRatio`/`isQuiescent`/`normalizeChangeLine`/
    `lineMultiset`, all pure + tested). Wiring: Swift — `AgentDashboardController.swift`
    (`HookSnapshotEntry.hidden`), `MCPLayout.swift` (`SurfaceRow.hidden` + JSON emit); sidecar
    — `mcp.ts` (`Surface.hidden`), `summarizer.ts` (config fields + `LastSummary` shape + the
    new pure helpers + `shouldSummarize`/`preGate`), `config.ts` (NEW), `index.ts` (`loadConfig`
    in `main`, record `signals`/`tail`). Tests: Swift `MCPServerTests`
    (`surfacesJSONDataEmitsHiddenWhenTrue` + omit-when-false), `AgentDashboardTests`
    (`hookSnapshot` hidden bit); sidecar `summarizer.test.ts` (change-detection +
    quiescent/hidden truth table), `config.test.ts` (NEW), `index.test.ts` (record shape).
    **GUI relaunch (for the `hidden` field) + rebuilt sidecar `dist` + sidecar restart; no
    host/Zig change.**
  - **RATE-LIMIT AUTO-BACKOFF (sidecar-only) — when the summarizer's OWN account is
    rate-limited, slow way down until one call succeeds (the limit resets).** When the
    summarizer bills to a depleted account, its `summarize()` calls fail (throw) or return
    an unusable/unparseable reply — and without this it would keep firing one call per
    surface per `debounceMs`, hammering the limited account. An ACCOUNT-WIDE adaptive
    backoff (`LoopDeps.summarizerBackoff = {failureStreak, nextProbeMs}`, pure
    `backoffDelayMs(streak, base, max) = min(max, base·2^(streak-1))`, default cap
    `cfg.rateLimitBackoffMaxMs` 600000) governs `runSweep`: `summarizeOne` now returns
    `"ok"|"fail"|"skip"` ("ok" = a model call parsed = account healthy; "fail" = threw OR
    unparseable; "skip" = gate not-due, no call). NORMAL sweep fires the due batch
    concurrently and aggregates — ANY "ok" resets the streak to 0; else if any "fail",
    streak++ and arm `nextProbeMs`. BACKED-OFF sweep (streak>0): if `now < nextProbeMs`
    return with ZERO calls; once the window elapses, probe candidates SEQUENTIALLY until
    ONE makes a real call (not a gate-skip, so a leading quiescent tile can't waste the
    probe) — "ok" clears the backoff + logs "resuming", "fail" extends it. So a depleted
    account is poked ~once per 10 min (one probe), and the first success snaps back to full
    cadence — fully automatic. Unparseable counts as "fail" deliberately (a rate-limit
    message often renders as un-parseable text, not an exception, so "until one SUCCEEDS"
    means "until one returns a real summary"). Wiring: sidecar ONLY — `summarizer.ts`
    (`rateLimitBackoffMaxMs` cfg + `backoffDelayMs`), `config.ts` (parse the key), `index.ts`
    (`summarizerBackoff` on `LoopDeps` + `SummarizeResult` return + `runSweep`
    gate/probe/aggregate + `main` init). Tests: `summarizer.test.ts` (`backoffDelayMs`),
    `config.test.ts` (parse), `index.test.ts` (`backoff:` group — engage-on-all-fail,
    success-keeps-0, cooldown-no-calls, one-probe-recovers, failed-probe-extends,
    unparseable-is-fail). **Rebuilt sidecar `dist` + sidecar restart only; no GUI/host/Zig
    change.**
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
  - **Read-only; ZERO autonomous send, ZERO host/Zig protocol change.** The only Zig change
    is two additive default-off config keys.
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
    **GUI relaunch only** to enable (no host restart). For Ramon's dev tree the sidecar runs
    from `macos/agent-manager/dist` via the `#filePath` fallback in `resolveSidecarDir()` (build
    it with `npm ci && npm run build`).
    **COLLEAGUE / DMG distribution — the sidecar IS bundled (dist-only), so the QUEUE works.**
    Both release paths (`dist/macos/release-local.sh` step 3b + `.github/workflows/fork-release.yml`)
    build the sidecar and copy **`dist/` + `package.json` ONLY** into
    `Contents/Resources/agent-manager` — the path `resolveSidecarDir()` prefers over the dev
    `#filePath`. **`node_modules` is deliberately NOT bundled** (~271MB and it ships a native
    `claude` binary that would break notarization), so the bundle is pure-JS data — notarization-
    safe, no extra signing (the app seal covers `Resources/`). Three things make this work:
    (1) the Agent **Queue** engine has ZERO npm deps (Node built-ins + global `fetch`); (2)
    `model.ts` imports the SDK as a **TYPE-ONLY import + a LAZY `await import()`** inside
    `summarize()`, so `dist/index.js` loads with no `node_modules` and only a real summary call
    pulls the SDK (a missing SDK throws → the summarizer self-disables per-surface, queue
    unaffected); (3) `package.json` is bundled so node treats `dist/*.js` as ESM (`"type":"module"`).
    **RUNTIME PREREQ: `node` on PATH** — the controller's §8 self-disable gate probes a login-shell
    `command -v node` and stays dormant (one log line, no crash) if absent, so a colleague without
    node just doesn't get the features. **So for a colleague: the Agent QUEUE works** (given node +
    the usual opt-in: `agent-queue`/`agent-manager` on, `mcp-listen`/`mcp-token` set, the agent-state
    hooks installed, a template) — **but the Haiku tile SUMMARIZER stays dev-only** (it needs the
    un-bundled `node_modules`; without it, the SDK import throws and the summarizer self-disables
    while the queue runs fine). Verified the dist-only bundle boots with no `node_modules`. Wiring:
    `model.ts` (type-only + lazy import), `dist/macos/release-local.sh` (step 3b),
    `.github/workflows/fork-release.yml` ("Build + bundle agent-manager sidecar").
  - **Account routing (optional) — bill the summarizer to a SEPARATE account.** By default the
    summarizer inherits the ambient Claude Code auth (works with NO multi-account setup); set a
    spec in `~/.config/ghostty-ramon/agent-manager/account` (sibling of `summarizer.md`) OR the
    `GHOSTTY_AGENT_MANAGER_ACCOUNT` env (env wins) to route its Haiku calls to a specific
    account. The spec is a bare account NAME → `~/.claude-accounts/<name>` (the `claude-accounts`
    convention) or an absolute/`~` PATH used directly as `CLAUDE_CONFIG_DIR`; a spec that doesn't
    resolve to a real dir is ignored (warn + inherit, so a stale name never breaks anyone). The
    resolver (`src/account.ts`: `readAccountSpec`/`resolveAccountDir`, PURE over an injected fs
    seam + `account.test.ts`) feeds `LoopDeps.summarizerConfigDir`, which `summarizeOne` threads
    into the model call; `model.ts summarize()` then passes `env:{...process.env,
    CLAUDE_CONFIG_DIR}` (spread so HOME/PATH/OAuth survive — only the config dir is re-pointed).
    SIDECAR-only: edit the file + restart the sidecar (the GUI respawns it; no app relaunch).
  - **Attention bell on rate-limit (fork-only, sidecar-only, ZERO Swift/Zig/host change).**
    The summarizer doubles as an attention watchdog: when a session hits the Claude
    usage/rate-limit BLOCKING prompt ("Stop and wait for limit to reset / Ask your admin
    for more usage" — which halts the agent WITHOUT ringing a terminal bell), the sidecar
    rings the bell via the EXISTING MCP `signalAttention` tool (`client.signalAttention`,
    already used by the Queue's leave-and-bell) — fanning out to the 🔔 tab title, dashboard
    aggregate, web monitor, and push, all off the one `.ghosttyBellDidRing` post. **No new
    MCP tool / no Swift / no host work** — the bell path already existed; this just triggers
    it. **HAIKU IS THE SOLE CLASSIFIER — NO regex/text match (deliberate, see below).** An
    extensible `alert?: string` field was added to the Haiku STRUCTURED OUTPUT contract
    (`src/prompts.ts`, parsed in `parseSummary` → `ParsedSummary.alert`, lower-cased/trimmed);
    the prompt tells Haiku to judge the CURRENT/LIVE state at the BOTTOM of the screen and set
    `"rate_limited"` only while the agent is actually halted on that prompt right now — NOT
    when the same text merely sits scrolled-up in history. **Why no deterministic regex
    backstop (the design pivot — an earlier version had one, removed):** a regex matches the
    text ANYWHERE in the viewport, so it (a) can't detect RECOVERY (the prompt scrolls up but
    stays in view → would never clear) and (b) on the idle-skip/model-fail paths would
    re-scan and FALSELY RE-RING after Haiku had already cleared it. Only a whole-screen
    classifier can tell "live prompt" from "scrolled-up history", so the regex was dropped
    entirely. The alert state therefore changes ONLY when a Haiku call SUCCEEDS + parses:
    `maybeSignalAlert(parsed.alert)` runs on the due path only; idle-skip / parse-fail /
    model-throw branches LEAVE the alert state untouched (a held alert stays armed, nothing
    rings or clears without a fresh classify). EDGE-TRIGGERED via a per-surface
    `alertBySession: Map<id,tag>` on `LoopDeps` (pure `alertEdge(prev,current)` →
    ring/clear/none): rings ONCE on a rising/changed edge, clears when Haiku reports no alert
    (this is how recovery un-rings, immune to scrolled-up text), re-arms after; cleaned up
    alongside `lastBySession` for dead surfaces; a failed `signalAttention` rolls the record
    back so a later sweep retries. **HONEST COST of pure-Haiku:** if the summarizer's OWN
    account is the rate-limited one, its calls fail and the FIRST detection can't fire (a held
    alert still stays armed; only the initial ring is at risk) — mitigate by routing the
    summarizer to a SEPARATE account (the existing Account-routing feature; the recommended
    watchdog setup). Detection still lands on the change-edge: the prompt appearing changes
    the screen → `shouldSummarize` returns `changed` (beats idle-skip) → Haiku runs → rings;
    latency ≈ debounce + a sweep (~5–15s). Wiring: sidecar ONLY — `prompts.ts` (contract +
    `alert` rule), `summarizer.ts` (`ParsedSummary.alert` + `parseSummary` parse +
    `ALERT_RATE_LIMITED` + pure `alertEdge`), `index.ts` (`LoopDeps.alertBySession` +
    `maybeSignalAlert` edge handler on the success branch only + `alertReason` + dead-id prune
    + main init). Tests: `summarizer.test.ts` (`alertEdge` + `parseSummary` alert parsing) +
    `index.test.ts` (`bell:` group — ring-once, held-no-rering-under-idle-skip, recovery-clears,
    scrolled-up-text-inert, model-failure-leaves-untouched, model-alert-rings-regardless-of-text,
    changed-tag-rerings, failed-ring rollback, non-agent never rung, dead-id prune). **Rebuilt
    sidecar `dist` + a sidecar restart (kill the node child or relaunch the GUI) is enough; no
    host/Zig change, no GUI relaunch needed for the GUI itself.**
  - **NO reply-suggestion feature (removed end-to-end).** An earlier "manager" pass proposed
    replies on `waiting` tiles (Approve/Edit/Dismiss + a per-tile notes field); it drained quota
    for low value and is GONE — both the TS sidecar pass (`manager.ts` + `model.ts suggest()` +
    `MANAGER_BASE_PROMPT` + the manager override loader + the second sweep pass) AND the entire
    Swift UI (`AgentPreviewTile` suggestion/notes rows + confidence dimming, `AgentDashboardController`
    `approveSuggestion`/`dismissSuggestion`/`setUserNotes`/`userNotes`/`suggestionDismissed` +
    the `UserNotesStore`, `AgentAnnotation.suggestion`/`confidence` + `Surface.userNotes`/
    `suggestionDismissed`, `MCPSafety.swift`). `AgentAnnotation` / the `set_surface_annotation`
    tool now carry ONLY `summary`/`phase`/`needsUser` + the Agent Queue tags
    (`queueKey`/`queueName`/`queueUrl`); the MERGE tool stays because the Queue uses it. The
    only send path left is the `send_text`/`send_key` MCP tools (used by the Queue's exit
    prelude). No Zig/host change. Wiring touched: macOS — `AgentDashboard/{AgentStateBridge,
    AgentDashboardController,AgentPreviewTile,AgentDashboardView}.swift`, `MCP/{MCPAnnotation,
    MCPLayout,MCPTools,MCPInput}.swift` (deleted `MCPSafety.swift`), `project.pbxproj`; sidecar —
    `mcp.ts` (dropped the dead `Surface`/`Annotation` fields). Tests updated in
    `AgentDashboardTests`/`MCPAnnotationTests`/`MCPServerTests` + sidecar `mcp.test.ts`.

- **Agent Queue Supervisor** (fork-only, macOS, OFF by default) — turns the Agent
  Dashboard/Manager into an active **supervisor + driver**: start a **queue** from a
  user-authored JSON **template** and the manager opens a tab of splits, launches one CLI
  agent per work item, never doubles up on an item key, caps concurrency, tracks each to
  completion, and force-closes its split when the item is done + the agent idle —
  re-polling for new/unblocked items. **See `AGENT-QUEUE.md` for user-facing config/usage**
  and the local design + review ledger `scratchpad/agent-queue-design.md` (paths in the
  iteration worktree). The load-bearing facts for an agent touching this code:
  - **GENERIC by design — the #1 requirement.** Ghostty/sidecar link NO tracker (Linear/
    GitHub/Jira) code. The queue source is a **command-based provider** the template
    defines: `list` (prints actionable items as JSON; expected to already exclude
    blocked/claimed/done — NO dependency graph in v1), `status {key}` (prints
    `{"state":…}`; terminal iff in `doneStates`), optional `claim`. Item fields reach the
    PROVIDER as argv elements (`{key}`) and the AGENT as **`GHOSTTY_ITEM_*` env vars** —
    NEVER string-spliced into a shell line (the one injection seam, closed). Completion is
    **status-only** (idleness alone never completes — no false positives).
  - **Engine = a deterministic, independent loop in the existing TS sidecar** (`macos/agent-manager/`,
    `src/queue/{types,provider,grid,templates,store,supervisor,runner,wiring,commands}.ts`) —
    NO LLM in the control path (the summarizer pass is orthogonal, still runs on the tiles on
    its own timer). It has its OWN `ConcurrencyBudget` (the starvation lesson — a slow LLM pass
    must never deny it a slot). Pure core (selectCandidates/nextState/grid/reconcile/applyCommand)
    is `node --test`-tested.
  - **HARD DEPS, self-disables silently otherwise (§2):** pty-host (detection `agentKind` +
    STABLE session ids for persistence — `sessionID==0` without it) AND the Claude
    agent-state hooks (the close-gate keys off hook-driven `agentState==idle` held
    `closeStableSeconds`; `idleSeconds` is deliberately NOT a fallback — a repainting TUI
    never idles by it). Hooks post to the INSTALLED RELEASE port, so real queues run there,
    not a dev `+1/+2` build. **Codex can dispatch/preview but CANNOT auto-close in v1** (no
    hooks) — documented limitation.
  - **No-duplicates guarantee, robust WITHOUT `claim`** (§7/§9): synchronous pre-`await`
    active-set insert (within-tick), durable sidecar store keyed by `sessionID` +
    reconcile-each-sweep (cross-tick/restart), cooldown (re-dispatch of a just-finished key).
    `claim` is a latency optimization only. **Resilience is first-class:** a started queue +
    its in-flight items survive a sidecar OR GUI restart with NO re-dispatch and NO orphaning
    — the **first sweep is dispatch-suppressed until reconcile runs**, crash-safe dispatch
    ordering (pending record → spawn → annotate → finalize), orphan adoption, finalized-record
    prune is grace-gated against a one-sweep `list_surfaces` lag. (These three — the lag grace,
    orphan grid-slot reclamation, and the `sessionID:0` self-disable — were the adversarial-
    review blockers; all fixed + regression-tested.)
  - **DISPATCH LATCH (§7.1) — block re-dispatch ENTIRELY until the item leaves the list and
    returns.** The ~2-min `cooldown` is NOT enough on its own: the dispatch→claim gap is
    HUMAN-GATED (the agent waits for the user's go-ahead before `/todo claim`, which is what
    moves the item off the queried state), so a split KILLED in that window leaves the item
    STILL in the `list` — and the cooldown would expire and re-grab it (and a restart drops the
    cooldown map → re-grab immediately). So every dispatched key joins a PERSISTED `dispatched`
    latch (`QueueRun.dispatched`, in the per-run store file); `selectCandidates` suppresses any
    latched key OUTRIGHT (not time-cooled). The latch is RE-ARMED (cleared) only when a
    SUCCESSFUL `list` no longer reports the key (it left the actionable set — claimed / blocked /
    labeled / moved off the queried state); a FAILED list never re-arms (no false re-enable on a
    transient provider error). So re-dispatch requires a real **status round-trip** (leave the
    list, return) — the user's explicit "block it off unless it literally changes status and back
    to Todo." BEHAVIOR CHANGE this subsumes: a crashed (EXITED) agent whose item stays listed is
    no longer auto-retried after cooldown — it needs the round-trip too (a crashed agent is not
    blindly re-run on the same item). Latched at dispatch intent (rolled back only if the spawn
    itself fails), persisted on every store write, rehydrated on the first reconcile (so the
    suppression survives a sidecar/GUI restart), and cleared on `abort` (a deliberate re-start is
    fresh). Wiring: `store.ts` (`StoreFile.dispatched` + `serializeStore`/`parseDispatched`/
    `loadDispatched` + `persistStore` 4th arg), `supervisor.ts` (`selectCandidates` `dispatched`
    param), `runner.ts` (`QueueRun.dispatched` + latch add/rollback in `dispatchOne` + re-arm in
    `dispatchCandidates` + rehydrate on first reconcile). Tests: `store.test.ts`
    (serialize/parse/persist round-trips + tolerance), `supervisor.test.ts` (`selectCandidates`
    latch skip + re-arm), `runner.test.ts` (kill-before-claim NOT re-dispatched w/o a round-trip,
    crashed-EXITED cooled-then-latched, latch persists across restart).
  - **ON-DEMAND lifecycle via a GUI→sidecar COMMAND CHANNEL** (§8a) — the sidecar is the MCP
    CLIENT so the GUI can't push; commands are DRAINED. `MCPServer` holds a thread-safe FIFO
    (enqueued on its serial queue via a `.ghosttyQueueCommand` observer the palette/dashboard
    post to; `QueueCommandBridge.swift`/`MCPQueueCommands.swift`), drained by the new MCP tool
    **`take_queue_commands`**. The sidecar applies start/pause/stop(drain)/abort/resume
    (`commands.ts applyCommand`), persists the active-run SET (`active-runs.json`) + rehydrates
    it on restart. **A template merely on disk does NOT auto-run** (replaced Phase-1
    `loadRuns(all)`) — only a started/persisted run.
  - **START-TIME PARAMS (§8b) — prompt for project/milestone/maxItems/etc. at start, don't hard-code.**
    A template can declare `params: [{name, target?, env?, label?, default?, required?}]`; on start the
    QueuePalette PROMPTS for each (a form, pre-filled with `default`), and each answer is delivered
    per its `target`. **`target` (default `"env"`)** picks the delivery: an `"env"` param is
    injected into the PROVIDER command env under `param.env` (the `list`/`status`/`claim` calls
    read it) — so ONE generic template is re-pointed at a different scope per run with no file
    edits; a **`"maxItems"`** param instead sets the RUN's lifetime dispatch cap (overriding the
    template `maxItems`), so the user picks 1/2/unlimited at start (the headline ask — "run it
    careful with maxItems=1, or unlimited"). STAYS GENERIC: the TEMPLATE names the env var / opts
    into the maxItems prompt; Ghostty never hard-codes "Linear". An env param scopes "what to work
    on" and is delivered ONLY to the provider, NOT the agent (the agent gets per-item
    `GHOSTTY_ITEM_*`); a maxItems param reaches NEITHER (it tunes the engine). Env resolution is
    `answer ?? default ?? omit` (`resolveParamsEnv`, pure); a REQUIRED param with no answer+no
    default REJECTS the start (`missingRequiredParams`, enforced in the factory + the GUI Start
    button is disabled). The maxItems override (`resolveMaxItemsOverride`, pure): blank/garbage →
    `undefined` (use the template `maxItems`, a safe finite); `"0"`/`"unlimited"`/`"none"`/`"inf"`/`"∞"`
    → unlimited (no lifetime cap — `maxItemsRemaining` is Infinity in `dispatchCandidates`, the
    global `agent-queue-max-total`+grid+concurrency still bound it); a positive integer → that cap.
    Validation: `target` must be `"env"`|`"maxItems"`; an env param needs a valid `env`; AT MOST ONE
    maxItems param (a 2nd is rejected). Params persist in the active-runs record (`params` map) so a
    restart re-applies the same scope AND maxItems. A template with no params starts directly (prior
    behavior). **The Swift palette is UNCHANGED** — its `templateParams` parser reads name/label/
    default/required and is `env`/`target`-agnostic, so the maxItems param prompts like any other
    with no GUI code change. Wiring: sidecar ONLY — `types.ts` (`QueueParam.target`/`QueueParamTarget`,
    `env` now optional), `templates.ts` (`validateParams` target + `resolveParamsEnv` skips non-env +
    new `resolveMaxItemsOverride`), `runner.ts` (`dispatchCandidates` applies the override). The
    env-param plumbing (`runner.ts` `QueueRun.params`, `commands.ts`, `store.ts`, `mcp.ts`,
    `wiring.ts`, `QueueCommandBridge.swift`, `QueuePalette.swift`) is unchanged — the maxItems answer
    just rides the existing `params` map. Tests: sidecar `templates.test.ts` (target validate +
    `resolveParamsEnv` skip + `resolveMaxItemsOverride` cases), `runner.test.ts` (override CAPS a
    sweep below list size + `"0"` unlimited dispatches PAST the template cap), plus the existing
    `commands.test.ts`/`store.test.ts`/`mcp.test.ts` and Swift `QueuePaletteTests`. **A rebuilt
    sidecar `dist` is enough (the GUI respawns it); no GUI relaunch / host / Zig change.**
  - **START-FORM LIVE PREVIEW + VALUE SUGGESTIONS (§8b UX, GUI-only, no sidecar/host/Zig change).**
    The start-form is no longer blind free-text — two GUI-SIDE probes run the template's
    provider commands directly (via `Process`, off-main, debounced ~0.35s, generation-guarded so
    stale results are discarded) as fields change:
    - **Live `list` PREVIEW** — once all REQUIRED fields are filled, the form runs
      `provider.list.command` with the CURRENT values as provider env and shows a success signal:
      "N items would be queued" + a sample of titles, or "no matching items" (amber), or the
      provider's last stderr line (red). Catches typos immediately (wrong project → empty/error).
      Gated on `canStart` so it doesn't spam "missing scope" errors while you're still typing.
    - **Per-param VALUE SUGGESTIONS** — a param may declare an OPTIONAL `valuesCommand` (argv) that
      prints a JSON array of suggested values (bare strings OR `{value,label?}`). The form runs it
      with the current values as env and shows a small menu next to the field; picking one fills it
      (no typing exact names). Because the env carries the OTHER fields, a DEPENDENT provider works:
      milestones' `valuesCommand` reads `$LINEAR_PROJECT` and re-runs when the project field changes
      (empty list when no project chosen). Every `valuesCommand` re-runs on each debounced change
      (simple + handles dependencies; a failed probe keeps the prior list rather than blanking).
    - **The probe is the GUI running the provider, NOT the sidecar** — the sidecar is the MCP client
      and can't be queried by the GUI, so the form execs the argv itself via `/usr/bin/env <argv>`
      (so a bare `python3`/`node` resolves on PATH) in the template `workdir`, inheriting the GUI env
      + the form's provider env. The env build mirrors the sidecar's `resolveParamsEnv`
      (`QueueProviderProbe.providerEnv`: env-target non-blank only; maxItems/blank skipped).
    - **Schema:** `QueueParam.valuesCommand?: string[]` (TS type + `validateParams` validates it as an
      optional argv even though only the GUI runs it; `env` stays optional). Wiring: sidecar —
      `types.ts`/`templates.ts` (`valuesCommand` field + validation); Swift — `QueuePalette.swift`
      (`QueueParamSpec` gains `env`/`isMaxItems`/`valuesCommand`; new `QueueTemplateProbe` +
      `templateProbe()`; `QueueParamProber` @MainActor debounced probe model; `QueueProviderProbe`
      pure `providerEnv`/`parseValues`/`previewState` + the blocking `run`; `QueueParamFormView` adds
      the suggestion menus + preview footer). Linear value scripts live in the untracked config
      (`example-projects.py` = all projects; `example-milestones.py` = milestones for `$LINEAR_PROJECT`,
      `[]` when none). Tests: sidecar `templates.test.ts` (valuesCommand validate); Swift
      `QueuePaletteTests` (`templateParamsParsesTargetAndValuesCommand`, `templateProbe*`,
      `providerEnv*`, `parseValues*`, `previewState*`). **GUI relaunch to pick up (Swift change); the
      `valuesCommand` field needs no sidecar restart (the running sidecar ignores unknown param fields).**
  - **GRID layout** (§12): all of a run's splits in ONE tab, auto-arranged up to `cols×rows`
    filling `columns`-or-`rows` first (template; default 3×3 columns-first), built from binary
    splits via a pure `grid.ts splitPlan` (target+direction); holes from closed splits are
    left + refilled lowest-slot-first (no re-flow). `concurrency` clamps to `cols×rows`.
  - **Exit forms (template knob):** `agent.exit` supports a TYPED exit
    command (`{text:"/quit"}` → send_text + Enter; `submit:false` to skip Enter) AND/OR control
    `{keys:[…]}` — DEFAULT `["ctrl-d"]`. NOTE the hyphen form: the MCP `send_key` tool only
    recognizes hyphenated names (`ctrl-d`/`ctrl-c`/`enter`/…) — the engine's old `"ctrl_d"`
    default silently no-op'd (saved only by the force-close timeout) until `ctrl-d` was added to
    `MCPInput.keySpecs(forKey:)` (keycode 2 + ctrl). Claude Code swallows Ctrl-D, so use
    `{text:"/quit"}`. The close sequence is sendText/sendKey-prelude → `awaitExited`
    (bounded; force-closes anyway on timeout, so a `/quit` that leaves the launching shell alive
    still tears down) → forceClose. **`quitWhenEmpty` was REMOVED** — see the hardening bullet at
    the end of this section; a run is now removed only by an explicit stop/abort.
  - **Close path (§10) — the subtle one:** `close_surface`/`request_close` HONORS
    `confirm-close-surface` and would pop a modal for a live agent. So the supervisor sends the
    template `agent.exit` prelude (→ child exits) then calls **`force_close_surface`**, which
    routes a LAST/ONLY-pane (tree-root) close to the confirm-FREE
    `closeTabImmediately()`/`closeWindowImmediately()` (NOT `closeTab`/`closeWindow`, which
    re-check `needsConfirmQuit`) — `TerminalController.closeSurface` override. `onAgentExit:
    leave-and-bell` keeps a crashed split for review + rings the bell everywhere via
    **`signal_attention`** (posts `.ghosttyBellDidRing` with the SurfaceView as `object`, so
    the dashboard aggregate + web monitor + push all fire), and FREES the slot (no deadlock).
  - **New MCP tools (Swift, the engine's "hands"):** `spawn_split_command` (opens the run's
    first tab or splits a target surface running a command, returns `{id, sessionId}` —
    `MCPLayout.newSplitCommand` reads the new leaf's UUID + `ghostty_surface_session_id` back
    as VALUE types on the main hop), `force_close_surface`, `signal_attention`,
    `take_queue_commands`, plus `sessionID` added to `list_surfaces` rows and queue annotation
    fields (`queueKey`/`queueName`/`queueUrl`, partial-merge like summary/suggestion). No host/
    Zig protocol change — only 3 additive default-off config keys (`agent-queue`,
    `agent-queue-templates-dir`, `agent-queue-max-total`) + the `start_agent_queue` action.
  - **Dashboard** (§11): tiles **grouped by origin** (queue name, or `(other)` for non-queue
    agents), per-tile origin **marker**, a top **filter bar** (include/exclude origins,
    persisted; VIEW-only — an excluded ringing/waiting agent still alerts), per-queue
    Pause/Stop/Abort header buttons (post `.ghosttyQueueCommand`). Start via the
    `start_agent_queue` action (+ `:template-name`) → `QueuePalette` (mirrors `ProjectPalette`)
    → posts a `start` command. Wiring: sidecar `src/queue/*`; Swift
    `macos/Sources/Features/MCP/{MCPLayout,MCPTools,MCPServer,MCPAnnotation,MCPQueueCommands,
    QueueCommandBridge}.swift`, `AgentDashboard/{AgentDashboardController,View,PreviewTile,
    AgentStateBridge}.swift`, `Command Palette/QueuePalette.swift`, `Terminal/
    {TerminalController,BaseTerminalController,TerminalView}.swift`, `Ghostty/{Ghostty.App,
    Ghostty.Config}.swift`; core `src/config/Config.zig` + `src/input/{Binding,command}.zig` +
    `src/apprt/action.zig` + `src/Surface.zig`. Tests: sidecar `node --test` (337+), Swift
    `MCPServerTests`/`MCPAnnotationTests`/`AgentDashboardTests`/`QueuePaletteTests`, Zig
    `agent-queue` config + `start_agent_queue` binding. **GUI relaunch + rebuilt sidecar
    `dist` to enable; no host restart.**
  - **Per-tile CLOSE button (GUI-only, queue tiles only) — the wedged-slot escape hatch.** On
    hover each tile shows the existing **Hide ✕** (view-only declutter; the split keeps
    running) and, ONLY on a **queue-owned** tile (one carrying a `queueName` annotation), a red
    **⏹ `stop.circle`** that **force-closes** the split: it ends the agent + frees the queue
    slot (the surface vanishing makes the next sweep reconcile + prune the record). It routes
    through the confirm-FREE `MCPLayout.forceClose` (same path the queue's own auto-close uses),
    so it works on a live agent without the `confirm-close-surface` modal — gated behind a
    confirmation dialog (no undo). It's the manual remedy when auto-close is wedged (e.g. a
    stuck-`working` hook). Queue-only by design: on a non-queue `(other)` agent a force-close is
    an unscoped "kill this terminal" next to the harmless Hide. Wiring:
    `AgentPreviewTile.swift` (`isQueueOwned` = `entry.annotation?.queueName` non-empty + the
    `onClose` button + `confirmationDialog`), `AgentDashboardController.swift`
    (`AgentDashboardModel.closeSurface(_:)` → `MCPLayout.forceClose`), `AgentDashboardView.swift`
    (`onClose:` wiring). Tests: `AgentDashboardTests` (`capDraft*` neighborhood; the button +
    gating are SwiftUI, not unit-tested). **GUI-only, GUI relaunch to pick up; no sidecar/host/Zig change.**
  - **QUEUE HEALTH bar (§11, sidecar→GUI push).** The dashboard shows each running queue's
    health in its section header — even BEFORE any split spawns and even when every tile is
    hidden/filtered (the "scary blank at start" + "all hidden" fixes). The supervisor PUSHES
    a run-level snapshot EVERY 5s sweep (incl. the dispatch-suppressed arm sweep) via a new
    MCP tool **`report_queue_status`**: `{queueName, present, phase, queued, listOk, active,
    dispatched, maxItems|null, next:[{key,title?}]}`. The header renders a phase chip
    (starting/running/paused/draining/disabled) + `QueueHealthFormat.healthText` ("N waiting ·
    M running · dispatched/cap", ∞ = unlimited — so a reached `maxItems` like `1/1` is
    obvious) + "next: KEY,KEY,…". **`present:false`** (reported on drain/abort/quit removal)
    clears the section. The "show with no tiles" behavior: `AgentDashboardModel.groupByOrigin`
    gained a `presentQueues` param that injects an EMPTY section for any present queue with no
    (visible) entries, and `sections` passes the (filter-minus) `queueStatuses` keys; the
    `content` body now falls through to the sectioned list (not the "no agents" placeholder)
    whenever `queueStatuses` is non-empty. **The ~170s "only one item, then a delay" the user
    saw was NOT serialization** — the engine dispatches up to min(concurrency, grid, maxTotal,
    maxItemsRemaining) per 5s sweep; the gap was the 2nd item only becoming actionable in the
    `list` later. Health-bar visibility makes that observable. Sidecar wiring: `status.ts`
    (pure `queueStatusReport` + `QueueStatusReport`), `runner.ts` (`lastListItems`/`lastListOk`
    cache + `effectiveMaxItemsCap` + `reportQueueStatus`/`reportRunGone` each sweep, single
    funnel for the dispatch-decision returns so the report ALWAYS fires), `mcp.ts`
    (`reportQueueStatus`). Swift: `QueueCommandBridge.swift` (`QueueStatus` +
    `QueueStatusPayload.fromArguments` + `.ghosttyQueueStatusDidChange` +
    `MCPServer.applyQueueStatus`), `MCPTools.swift` (schema + dispatch), `MCPServer`
    (handler), `AgentDashboardController.swift` (`queueStatuses` @Published + `applyQueueStatus`
    + `subscribeQueueStatus` + `groupByOrigin(presentQueues:)` + `sections`),
    `AgentDashboardView.swift` (`OriginSectionHeader` status line + `QueueHealthFormat` +
    the `content` fall-through). Tests: sidecar `status.test.ts` + `mcp.test.ts`
    (`reportQueueStatus`) + `runner.test.ts` (a sweep reports starting→counts); Swift
    `MCPServerTests` (`queueStatusPayload*`, `toolsListHasAllTools` now 18) +
    `AgentDashboardTests` (`AgentQueueHealthTests`: apply/clear, empty-section grouping,
    `healthText`). **GUI relaunch + rebuilt sidecar `dist`; no host/Zig change.**
    - **Clickable count DROPDOWNS (mirrors the hidden-agents popover).** The "N waiting" and
      "M running" counts in the header are buttons that open a popover listing those items
      with **Linear links** (key badge · title · `Link` for http(s) urls; "… and N more" when
      the waiting list is capped). This required the report to carry per-item DETAIL, not just
      counts: `QueueStatusReport.next` items gained `url`, and a new `running: QueueItemRef[]`
      (key/title/url per slot-occupying agent) was added — `runner.ts reportQueueStatus` builds
      `runningItems` from the active assignments (title/url captured at dispatch) and sends
      `nextLimit:25`; the pure builder's `active` is now `runningItems.length`. Swift mirrors it:
      `QueueStatus.Item` (was `NextItem`, +`url`, `Identifiable`) + `running: [Item]`, parsed by a
      shared `items(_:)` helper in `QueueStatusPayload`; `report_queue_status` schema gains `url`
      on next + a `running` array; `OriginSectionHeader` renders `countButton`→`itemsPopover`
      (Linear `Link` via `itemLink`, http(s)-gated like `queueURLLink`) and `QueueHealthFormat`
      swapped `healthText`→`progressText` (just the "dispatched/cap" suffix; the counts are now
      buttons). Tests: sidecar `status.test.ts` (next url + running echo) + `mcp.test.ts`
      (running forward); Swift `MCPServerTests` (parse url+running) + `AgentDashboardTests`
      (`progressText`, `applyKeepsNextAndRunningItems`). **GUI relaunch + rebuilt sidecar `dist`.**
    - **BACKLOG DEPENDENCY GRAPH (the "N backlog" button → DAG canvas; sidecar→GUI push).**
      The header gets an "N backlog" button that opens a resizable window rendering the run's
      WHOLE board (every state — not just actionable) as a left→right layered dependency graph:
      columns by blocked-by depth, arrows for "blocked by", node cards colored by workflow-state
      category with label chips, a green ring on running items, click→jump-to-split (running) or
      open the tracker URL. **The data needs a NEW OPTIONAL `provider.graph` command** (sibling of
      `list`/`status`; absent ⇒ no button) — kept SEPARATE from `list` because `list` must stay
      "actionable-only" (it drives dispatch). It is fetched on the SAME cadence as `list`
      (`intervals.listMs`, reusing a `lastGraphAtMs` throttle), INDEPENDENT of dispatch (runs while
      paused/draining, skipped only when `disabled`), cached on `QueueRun.lastGraph`, and PUSHED via
      a new MCP tool **`report_queue_graph`** (`{queueName,present,backlog,nodes[]}`; `present:false`
      on run removal, alongside `reportRunGone`). The `backlog` count is the GROOMABLE remainder:
      non-terminal nodes NOT currently waiting/running (`backlogCount`, pure — exclude = the
      actionable-list keys ∪ active assignment keys). STAYS GENERIC: the node's `done` (terminal,
      excluded+dimmed) and `stateType` (color category) are PROVIDER-decided — Ghostty maps no
      tracker; `QueueBacklogColors` is a cosmetic category→color map with a neutral fallback. The
      DAG layout (`QueueBacklogLayout.assignLayers`) is longest-path-from-roots, cycle-safe (a
      blocked-by cycle is broken via a `resolving` guard) and ignores edges to keys outside the
      scope. The canvas window is one-per-run via `QueueBacklogWindowManager` (MainActor; strong
      ref + `willClose` observer that drops both the window and itself — no leak/double-open). Its
      DEFAULT size is fit-to-content (the whole board, no scrolling) floored at a minimum and
      CLAMPED to the display: shared geometry `QueueBacklogGeometry` (the card/gap constants the
      view also uses) computes `preferredWindowSize(nodes)`, and `QueueBacklogWindowManager.defaultContentSize(nodes:screen:)`
      floors it at `minContentSize` (480×360) + clamps to `screen − screenMargin` (both pure +
      unit-tested).
      Wiring: sidecar — `types.ts` (`ProviderGraphSpec`/`GraphNode`/`QueueGraph`), `provider.ts`
      (`parseGraphOutput`/`fetchGraphResult`), `status.ts` (`QueueGraphReport`/`backlogCount`),
      `templates.ts` (`validateProviderGraph`), `runner.ts` (`QueueRun.lastGraph`/`lastGraphAtMs` +
      `refreshGraph`/`reportGraphGone`), `mcp.ts` (`reportQueueGraph`). Swift —
      `QueueCommandBridge.swift` (`QueueGraph`/`QueueGraphPayload`/`.ghosttyQueueGraphDidChange`/
      `applyQueueGraph`), `MCPTools.swift` (`report_queue_graph` tool — now 19 tools),
      `AgentDashboardController.swift` (`queueGraphs` @Published + `applyQueueGraph` +
      `subscribeQueueGraph`), `AgentDashboardView.swift` (`backlogButton` in `OriginSectionHeader`),
      `AgentDashboard/QueueBacklogCanvas.swift` (layout + canvas + window mgr; iOS-excluded in
      `project.pbxproj`). Config (untracked, Linear-specific): `example-graph.py` (mirrors
      `example-list.py` scope/auth but ALL states + labels + blockedBy + done/stateType) +
      `provider.graph` in `example.json`. Tests: sidecar `provider.test.ts` (parseGraph/fetchGraph),
      `status.test.ts` (`backlogCount`), `templates.test.ts` (graph validate), `mcp.test.ts`
      (`reportQueueGraph`), `runner.test.ts` (graph fetch throttled + push + present:false-on-abort +
      no-graph-no-fetch); Swift `MCPServerTests` (`queueGraphPayload*`, tool count 19),
      `AgentDashboardTests` (`QueueBacklogTests`: assignLayers chain/diamond/cycle/dangling +
      columns + applyQueueGraph). **GUI relaunch + rebuilt sidecar `dist`; no host/Zig change.**
  - **CLOSE-GATE fires on QUIESCENT (idle OR waiting), not idle-only (sidecar-only fix).** The
    DONE_PENDING→CLOSING gate used to require `agentState==="idle"` held `closeStableSeconds`.
    But a finished Claude Code agent reliably settles in **`waiting`** — its `Stop`→idle hook is
    immediately overwritten by a `Notification` "waiting for input" nudge — so an idle-ONLY gate
    NEVER fired and the completed split was never auto-closed (real stuck case: EX-1446 sat
    DONE_PENDING with status=Done, agentState=waiting, forever). Fix: a pure `isQuiescent(agentState)`
    = `idle || waiting`; `supervisor.ts` `nextState` gates on `isQuiescent`, and `foldIdleAnchor`
    anchors the hold on EITHER state AND **keeps the anchor across an idle↔waiting transition**
    (only `working`/`undefined` resets it) — so the `Stop`→`Notification` flip keeps the close clock
    running instead of resetting it. Status-only completion is unchanged (idleness alone still never
    completes); this only governs WHEN a provider-DONE item's split tears down. Tests:
    `supervisor.test.ts` (close-on-waiting-held, foldIdleAnchor anchors-on-waiting + keeps-anchor-
    across-transition). **Sidecar-only — rebuilt `dist` + sidecar restart; no GUI/host/Zig change.**
  - **LIVE maxItems EDIT — change a running queue's cap from the dashboard, no restart (§8b).**
    A new `set_max_items{run,maxItems}` command re-sets a LIVE run's lifetime dispatch cap WITHOUT
    restarting it (the headline ask: bump 3→10 mid-run). The dashboard header's "dispatched/cap"
    suffix is now **tap-to-edit** → a popover with preset buttons (1/2/5/10/∞) + a custom field; the
    raw string is posted (the sidecar parses it, so a fat-finger never silently removes the cap).
    Bumping the cap above `lifetimeDispatched` re-enables dispatch on the next sweep (`maxItemsRemaining`
    recomputes); LOWERING it only stops FUTURE dispatch — running agents are never killed. **NOTE the
    run-identity semantics** (UPDATED by the per-scope-identity change — see the "PER-SCOPE RUN
    IDENTITY" bullet below): after the `queue-parallel` merge a run is keyed by **template basename +
    resolved scope** (`identityScope` = the resolved provider env, e.g. project/milestone — see
    `commands.ts applyCommand`). A re-`start` with the SAME basename AND SAME scope is an idempotent
    NO-OP that ignores the second start's maxItems — so you can't rescope or re-cap a live run by
    re-starting it; `set_max_items` is the in-place cap edit. A DIFFERENT scope of the same template is
    a DISTINCT run that proceeds in PARALLEL (own tab + state file), so two milestones run at once from
    ONE template — you do NOT need two template files (this supersedes the earlier basename-only dedup).
    Engine: a new
    mutable `QueueRun.maxItemsLive` (`undefined`=no edit, `null`=unlimited, N=cap) that `effectiveMaxItemsCap`
    consults FIRST (over the start-time param + template cap); persisted in the active-runs record
    (`maxItemsLive`) so a restart re-applies it. A shared pure `parseMaxItemsValue` (null=unlimited,
    N=cap, undefined=blank/garbage→ignored) backs both this and the start-time `resolveMaxItemsOverride`.
    Wiring: sidecar — `templates.ts` (`parseMaxItemsValue` + `resolveMaxItemsOverride` reuse), `runner.ts`
    (`QueueRun.maxItemsLive` + `effectiveMaxItemsCap` + `makeQueueRun` opt + `activeRunRecords`),
    `commands.ts` (`set_max_items` action + `maxItems` field + reducer case + `applyCommands` change-bit),
    `store.ts` (`ActiveRunRecord.maxItemsLive` + tolerant parse), `wiring.ts` (rehydrate), `mcp.ts`
    (`coerceQueueCommands` whitelists + carries `maxItems`). Swift — `QueueCommandBridge.swift`
    (`QueueCommand.Action.setMaxItems`="set_max_items" + `maxItems` field + `jsonObject`),
    `AgentDashboardController.swift` (`setQueueMaxItems(run:value:)`), `AgentDashboardView.swift`
    (`OriginSectionHeader` cap button + `capEditorPopover` + `QueueHealthFormat.capDraft`). Tests:
    sidecar `templates.test.ts` (`parseMaxItemsValue`), `commands.test.ts` (set_max_items apply/unlimited/
    ignore-garbage/unknown-run/change-bit), `runner.test.ts` (`effectiveMaxItemsCap` live override + bump-
    re-enables-dispatch), `store.test.ts` (round-trip + tolerant parse), `mcp.test.ts` (coerce carries it);
    Swift `MCPServerTests` (`queueCommandJSONObjectSetMaxItems*`), `AgentDashboardTests` (`capDraft*`).
    **GUI relaunch + rebuilt sidecar `dist`; no host/Zig change.**
  - **INSTANT command feedback (snappiness fix for ALL queue commands).** A queue command
    (`set_max_items`/pause/resume/stop/abort) only reflected in the dashboard on the sidecar's
    NEXT health push — i.e. after the ~5s `QUEUE_POLL_INTERVAL_MS` poll gap AND that sweep's
    provider round-trips (per-agent `status` probes + `list`), since `reportQueueStatus` is the
    LAST step of a sweep. Felt like 5–15s ("really slow"). Two-part fix: **(GUI optimistic)**
    `AgentDashboardModel.setQueueMaxItems`/`sendRunCommand` update the local `queueStatuses`
    entry IMMEDIATELY before posting — cap via `QueueStatus.parseCapOptimistic` (mirrors the
    sidecar's `parseMaxItemsValue`; `.none`=blank/garbage→leave as-is so we never fake a change
    the engine ignores) + `withMaxItems`; phase via `withPhase` (pause→paused/resume→running/
    stop→draining); abort removes the section. The sidecar's next authoritative push reconciles
    (and corrects a mis-parsed value). **(Sidecar fast confirm)** `runQueueSweep` pushes
    `reportQueueStatus` for every (non-aborting) run IMMEDIATELY after `applyCommands` changes
    the registry — BEFORE the sweep's `status`/`list` round-trips — so the authoritative number
    lands within the drain, not at sweep end. Wiring: `QueueCommandBridge.swift`
    (`QueueStatus.withMaxItems`/`withPhase`/`parseCapOptimistic`),
    `AgentDashboardController.swift` (optimistic mutation in both posters), `runner.ts`
    (post-`applyCommands` immediate report loop). Tests: `AgentDashboardTests`
    (`parseCapOptimisticMirrorsSidecar`, `setQueueMaxItemsOptimisticallyUpdatesCap`,
    `sendRunCommandOptimisticallyUpdatesPhase`); the sidecar suite still green. **GUI relaunch +
    rebuilt sidecar `dist`; no host/Zig change.**
  - **PROVIDER-CALL THROTTLING — honor `intervals.listMs`/`statusMs` (the real "5s too
    frequent" fix).** The supervisor sweep stays at the 5s `QUEUE_POLL_INTERVAL_MS` base cadence
    (reconcile / close / command-drain / §11 health report run EVERY sweep), but the PROVIDER
    calls are now throttled to the template's `intervals` instead of firing every sweep — so a
    tracker like Linear is hit at most once per `listMs` (`list`) and once per `statusMs`
    (`status`), not every 5s. Previously both knobs were DEAD (`runner.ts` called `fetchListResult`
    + `probeStatus` every sweep, ignoring `intervals`). Engine: two new non-persisted
    `QueueRun.lastListAtMs`/`lastStatusAtMs` (init `NEGATIVE_INFINITY` ⇒ the first sweep always
    fetches, and no `now===0` sentinel collision). `dispatchCandidates` skips the whole list
    fetch+dispatch and returns 0 when `nowMs - lastListAtMs < intervals.listMs` — the §11 health
    report (fired by `runOne` AFTER dispatch) reads the CACHED `lastListItems`/`lastListOk`, so the
    dashboard counts stay live between polls; the latch re-arm just waits
    for the next due fetch. The window is consumed on the ATTEMPT (set before the fetch), so even a
    FAILED list waits a full interval — a hard cap of one `list` call per `listMs` regardless of
    outcome. `advanceStates` gates the per-agent `status` probe on `statusDue =
    nowMs - lastStatusAtMs >= statusMs` (decided once for the whole batch so all agents share one
    round); when not due, `statusTerminal` stays undefined so no status-driven completion happens
    that sweep (idle-anchor fold + close-gate still run every sweep — completion is delayed at
    most `statusMs`, never lost). The status window is consumed ONLY if a probe actually fired
    (`probed` flag), so a due sweep with no live SPAWNED/RUNNING agent (host-attach lag) doesn't
    burn the interval — the next sweep with a live agent probes immediately. BEHAVIOR NOTE: a
    `set_max_items` bump / `resume` re-enables dispatch, but the NEW dispatch lands on the next
    list-DUE sweep (≤`listMs`), not the next 5s sweep — the dashboard cap/phase still updates
    INSTANTLY (the optimistic + fast-confirm path above); only the actual spawn waits for the
    poll. **Default ALIGNED to `{listMs:60000, statusMs:30000}`** (was 45000/20000) and the user's
    near-identical 60/30 override was REMOVED from `example.json` so config == default. Wiring:
    `runner.ts` (`QueueRun.lastListAtMs`/`lastStatusAtMs` + `makeQueueRun` init + list gate in
    `dispatchCandidates` + status gate in `advanceStates`), `templates.ts`
    (`TEMPLATE_DEFAULTS.intervals` → 60000/30000). Tests: `runner.test.ts` (list throttled +
    throttled-sweep-still-reports-from-cache + status throttled + due-sweep-no-agent-doesn't-burn;
    the shared `tmpl()` fixture sets `intervals:{0,0}` = throttle-off so the existing every-sweep
    dispatch/state tests are preserved), `templates.test.ts` (default pinned to 60000/30000).
    **Sidecar-only — rebuilt `dist` + sidecar respawn (GUI relaunch); no host/Zig/GUI-Swift change.**
  - **PER-SCOPE RUN IDENTITY — one template, parallel runs per project/milestone (palette shows the
    template `name`).** Three coupled changes so a generic template (e.g. Example) is re-usable in
    parallel for different env-param scopes:
    - **(1) Palette shows the template `name`, not the filename.** The "Start Agent Queue…" picker lists
      each template by its JSON `name` (e.g. "ExampleOS"), not the file basename ("example"), sorted by
      display name. The START command + `templateParams`/`templateProbe` still key off the BASENAME (the
      sidecar loads templates by it). `QueuePalette.discoverTemplates` now returns `[QueueTemplateEntry]`
      (`basename` + `displayName`, read via the new `templateDisplayName`, basename fallback); the option
      title + the param-form title use `displayName`; `QueueParamPrompt` gained `displayName`.
    - **(2) A run's live IDENTITY is `runName` = `template.name` + its non-empty ENV-param VALUES,
      " · "-joined** (e.g. "ExampleOS · Acme · v2.0"; maxItems params excluded — engine tuning, not
      scope). `runName` REPLACES `template.name` everywhere the run identity flows: the annotation
      `queueName` (dispatchOne + restampAnnotation), the §11 health report, the `activeRunRecords` name,
      and the reconcile `projectLiveSurfaces` filter — so two scoped runs of one template are shown
      (separate dashboard sections) AND controlled (pause/stop/abort/set_max_items target the `runName`)
      independently. Pure helper `runDisplayName(template, values)` in `templates.ts`.
    - **(3) Dedup is now per-SCOPE, so different scopes run IN PARALLEL (separate tabs).** `applyCommand`
      builds the candidate run, then dedups on (basename + `identityScope`) where `identityScope` =
      `runIdentityScope(template, values)` = the resolved provider env (sorted `name=value`, pure). Same
      (template + scope) = idempotent no-op (unchanged); DIFFERENT scope = a second run, keyed in the
      registry by its `runName`. The per-run STATE FILE gets a scope-hash suffix (`<basename>.<slug>.state.json`
      via `scopeSlug(runIdentityScope(...))`) so parallel runs of one template don't collide on disk;
      rehydration recomputes the same path. **Separate tabs are automatic** — each run starts with an empty
      `occupied` set, so its first dispatch's `splitPlan` returns `firstTab` → a new tab per run.
    - **(3a) State-file MIGRATION across the rename (bug fix).** The scope-suffix renamed the per-run
      state file (`example.state.json` → `example.<slug>.state.json`), so a run that was IN FLIGHT across
      the upgrade rehydrated under the NEW path, found no file, and **reset `lifetimeDispatched` to 0** (it
      also lost the live maxItems edit + re-adopted its agents as orphans). Fix: `rehydrateActiveRuns`
      RENAMES a surviving bare `<basename>.state.json` to the scoped path on first rehydrate (pure decision
      `shouldMigrateLegacyState(scoped, legacy, scopedExists, legacyExists)` — migrate only when the scoped
      file is absent, the legacy exists, and the paths differ; best-effort rename). Done ONLY on the
      rehydrate path (a run that WAS active) — a FRESH `start` must NOT adopt a stale bare file. Normal
      restarts (no rename) already persisted the count via the stable scoped path; this only covers the
      one-time upgrade boundary. Wiring: `wiring.ts` (`shouldMigrateLegacyState` + the rename in
      `rehydrateActiveRuns`); test: `wiring.test.ts` (`shouldMigrateLegacyState`).
    - **(3b) REHYDRATION must key the registry by `runName`, NOT `template.name` (bug fix).** The
      `start` path (`applyCommand`) keys the registry by `run.runName`, but `index.ts` populated a
      RESTORED run (from `active-runs.json` on restart) with `registry.set(run.template.name, run)` —
      so after a restart a scoped run was keyed by the bare `"ExampleOS"` while the dashboard / health
      report target its `runName` (`"ExampleOS · Acme Foods · Visual Prototype"`). Every control
      command (`set_max_items`, pause, stop, abort) then `registry.get(cmd.run)`→undefined → silent
      "unknown run" no-op (the "changing maxItems does nothing after restart" bug), and two parallel
      scoped runs of one template would COLLIDE on the bare name. Fix: a shared
      `registerRehydratedRuns(registry, runs)` in `commands.ts` keys by `run.runName` — the SAME key
      `start` uses — and `index.ts` calls it instead of the inline loop. So a restored run behaves
      identically to a freshly started one. Wiring: `commands.ts` (`registerRehydratedRuns`),
      `index.ts` (call it). Tests: `commands.test.ts` (keyed-by-runName + `set_max_items` resolves
      after rehydrate + two parallel scoped runs coexist).
    `makeQueueRun` computes `runName`/`identityScope` from (template + params); a `runName` collision from a
    DIFFERENT identity is rejected (no clobber). Wiring: sidecar — `templates.ts` (`runDisplayName`/
    `runIdentityScope`/`scopeSlug`), `runner.ts` (`QueueRun.runName`/`.identityScope` + identity usages),
    `commands.ts` (scope-aware dedup + key-by-`runName`), `wiring.ts` (`runStatePath` scope-suffixed state
    file, factory + rehydrate). macOS — `QueuePalette.swift` (`QueueTemplateEntry` + `templateDisplayName` +
    `discoverTemplates` return type + `QueueParamPrompt.displayName` + option/form titles). Tests: sidecar
    `templates.test.ts` (`runDisplayName`/`runIdentityScope`/`scopeSlug`), `commands.test.ts` (parallel
    different-scope start + same-scope no-op + factory-consulted-on-restart); Swift `QueuePaletteTests`
    (`discoverUsesJSONNameForDisplayAndSort`, `templateDisplayNameFallsBackToBasename`, updated discovery
    assertions to `[QueueTemplateEntry]`). **GUI relaunch + rebuilt sidecar `dist`; no host/Zig change.**
  - **RESTART-SURVIVAL HARDENING (the "queue vanished on restart" + "splits detached" fix).** A real
    incident: a run with `quitWhenEmpty:true` self-removed at 19:34 while its 3 agents were still ALIVE,
    so a later GUI restart found an empty `active-runs.json` → no queue, detached splits. Root cause
    (confirmed by reading `reconcile`): the session-gone prune grace keys off the record's `sinceMs`,
    which for a LONG-LIVED RUNNING record is ancient → ZERO protection against a SUCCESSFUL-but-INCOMPLETE
    `list_surfaces` right after a (re)start (surfaces still coming up). So a transient post-restart list
    pruned live records → `active.size→0` → `quitWhenEmpty` removed the whole run (abandoning live agents).
    Three sidecar-only fixes:
    - **(A) `quitWhenEmpty` REMOVED end-to-end.** The template knob + the `runOne` quit branch +
      `QueueRun.sawEmptyListThisSweep` are gone; a run is removed ONLY by explicit stop/abort. An empty
      `list` just means "nothing actionable now" → keep polling. A `quitWhenEmpty` key in template JSON
      is now silently ignored (tolerant parse). Wiring: `types.ts` (field removed), `templates.ts`
      (default + parse removed), `runner.ts` (quit branch + field removed). Tests: `runner.test.ts`
      "an empty list + no active agents does NOT remove the run" (replaced the 3 quitWhenEmpty tests).
    - **(B) PREMATURE-PRUNE FIX — reconcile-start grace.** `reconcile` gained an optional
      `reconcileStartedMs` (default `-Infinity` = old behavior); a finalized record's session-gone prune
      is now shielded for `pendingGraceMs` (30s) after the LATER of its `sinceMs` AND the run's first
      reconcile in the current process (`run.reconcileStartedMs`, stamped once per process; a restart
      re-stamps). So a long-lived RUNNING record survives a transient/incomplete post-restart list for a
      full grace window. Conservative — can only DELAY a prune (hold a slot longer), never cause a
      duplicate. Wiring: `store.ts reconcile` (param + `Math.max(sinceMs, reconcileStartedMs)` gate),
      `runner.ts` (`QueueRun.reconcileStartedMs` stamp + pass-through). Tests: `store.test.ts`
      (shield within grace / prune past grace / default-arg = pre-fix behavior); the latch-persists
      restart test updated to expect the held-then-pruned sequence.
    - **(C) PERSISTENT SIDECAR LOG (so the next incident is debuggable).** The Swift controller pipes the
      sidecar's stdout to an UNREAD pipe and sends stderr to `nullDevice`, so the engine's run/prune/command
      logs had NO durable trail (this incident was undiagnosable after the fact). New `src/logfile.ts`
      tees `console.{log,info,warn,error}` to a ROTATING file `~/Library/Logs/ghostty-ramon-agent-manager.log`
      (append, rotate at ~5MB → `.1`); best-effort (any fs error falls back to console only, never throws);
      installed first thing in `index.ts main()`. Pure `formatLogLine`/`defaultLogPath` unit-tested
      (`logfile.test.ts`). **Sidecar-only — rebuilt `dist` + sidecar restart; no host/Zig/GUI-Swift change.**

## Fork-identity / non-functional changes
- **Bundle id** `com.mitchellh.ghostty-ramon` for Release, `.local` for the in-tree ReleaseLocal dev build, `.debug` for Debug — all coexist with the official `com.mitchellh.ghostty`, each with its own state/defaults domain. (`macos/Ghostty.xcodeproj/project.pbxproj`, `DockTilePlugin.swift` reads the host bundle id at runtime so each domain reads its own defaults.)
- **Display name** "Ghostty (ramon)" for Release, "Ghostty (ramon-local)" for ReleaseLocal — so the installed app and the in-tree dev build are visually distinguishable in the dock and ⌘-Tab.
- **Single-instance guard** in `AppDelegate.applicationWillFinishLaunching`: if another process with the same bundle id is already running from a different bundle URL, that one is activated and this process exits. Stops two copies of the same fork identity from racing each other (e.g. dock-attention bouncing one while you click the other).
- **Icon** defaults to `chalkboard` (`macos-icon` default in `src/config/Config.zig`); macOS swaps it per build at runtime so each identity is distinct at a glance — Release stays on `chalkboard`, ReleaseLocal becomes `paper`, Debug becomes `blueprint`. The swap fires only when the resolved icon is the fork default, so an explicit non-chalkboard `macos-icon` still wins. (`macos/Sources/Features/Custom App Icon/AppIcon.swift`)
- **Auto-update via Sparkle, pinned to the fork's OWN GitHub Releases feed** (was hard-disabled; re-enabled for colleague distribution). Sparkle starts normally but `UpdateDelegate.feedURLString` points at `github.com/ramonsnir/ghostty/releases/latest/download/appcast.xml`, never ghostty.org, so the fork is never replaced by an official build. Dev builds still don't auto-check (`Ghostty-Info.plist` ships `SUEnableAutomaticChecks=false`); the CI release build deletes that key. The committed `SUPublicEDKey` is the fork's OWN real public key (generated at enrollment via Sparkle `generate_keys`; public keys aren't secret), matching the `SPARKLE_PRIVATE_KEY` CI secret; CI re-injects `SPARKLE_PUBLIC_KEY` as belt-and-suspenders. (`UpdateController.hasPlaceholderUpdateKey` still guards the all-zero placeholder so a future placeholder build fails closed.) See "Distribution / sharing the fork" below. (`macos/Sources/Features/Update/{UpdateController,UpdateDelegate}.swift`)
- **App Nap opt-out (fork-only, macOS; always on)** — `AppDelegate.applicationDidFinishLaunching` holds a process-lifetime `ProcessInfo.beginActivity(.userInitiatedAllowingIdleSystemSleep)` token (`appNapAssertion`) so macOS never naps/throttles the GUI while backgrounded or occluded. **Load-bearing for the `.client` backend:** the host connection is opened from per-surface IO threads at surface creation and is **single-shot (no retry — see `src/termio/Client.zig` `connectAndAttach`)**, so if the GUI is relaunched into the background with **no active display** (a remote restart while away), App Nap can suspend those threads before they connect to `ghostty-host`, leaving every restored surface permanently blank until a manual restart-while-present. This is exactly the 2026-06 weekend symptom ("restarted Ghostty remotely while away → monitor showed empty surfaces all weekend; restarting while at the Mac fixed it"). The `...AllowingIdleSystemSleep` option opts out of App Nap **without** preventing system/display sleep (it omits the idle-sleep-disable bits), so battery/sleep behavior is unchanged — we only decline to be napped (it also disables sudden/automatic termination, desirable for a terminal). Note: a connect-retry/reconnect in the `.client` backend was considered and **deliberately skipped** — the host is a KeepAlive LaunchAgent (≈always up, so connect rarely fails) and a dropped host can't restore RAM-only sessions anyway, so it was high-risk surgery on the most delicate lifecycle code for an unobserved failure mode. (`macos/Sources/App/macOS/AppDelegate.swift`)
- **Config separation**: the fork additionally loads `~/.config/ghostty-ramon/config` on top of the shared `~/.config/ghostty/config`. Put fork-only keybinds **and fork-only config keys** there so an official Ghostty (which shares `~/.config/ghostty/config`) never errors on unknown actions or keys. Fork-only config keys so far: `project-directory`, `bell-features-focused`, `web-monitor-listen`, `web-monitor-token`, `mcp-listen`, `mcp-token`, `agent-dashboard`, `agent-dashboard-commands`, `agent-dashboard-pin`, `agent-manager`, `agent-manager-node-path`, `agent-queue`, `agent-queue-templates-dir`, `agent-queue-max-total`. (`src/config/file_load.zig` `forkXdgPath`, `Config.zig` `loadDefaultFiles`)

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
  on the main tree. **It PUSHES `ramon-fork` → `fork/main` FIRST (after a `[y/N]`
  confirmation; `RELEASE_YES=1` skips the prompt for unattended/monitor runs), then
  tags the release at the EXACT built commit** (`gh release create --target <sha>`),
  with a UNIQUE per-commit tag `build-<N>-<shortsha>`. This is load-bearing: the script
  builds the LOCAL working tree, so without the push the released binary's source isn't
  on GitHub and `gh` would otherwise tag `fork/main`'s (stale) head — the binary/tag/
  build-number mismatch that bit us once (released `build-16645` from local `f174b8a27`
  while the tag pointed at the older pushed `243f953`). Distinct commits → distinct
  preserved releases (old ones never deleted; only the `--latest` pointer moves);
  re-running on the SAME commit re-publishes that one tag idempotently. A guard refuses
  to release unless `HEAD == ramon-fork`. **One-time per machine:** Developer ID cert in the login keychain;
  Sparkle private key in the keychain (`sign_update` uses it automatically — no file);
  `sign_update`+`generate_keys` on PATH (copied to `~/.local/bin`) and `create-dmg`
  (`npm i -g create-dmg`). **nvm note:** when `create-dmg`/`node` live under nvm and
  aren't on a non-login/GUI shell's PATH (and `node`/`npm` are recursive lazy-load
  shims), the script SELF-HEALS — it `unset -f node npm` and prepends the nvm node bin
  that has `create-dmg`, so an unattended/monitor run from such a shell still works (no
  manual PATH setup). A Homebrew `create-dmg` already on PATH makes that a no-op. A
  notary keychain profile —
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
  pattern as the host, so the MCP agent-control feature isn't dropped from the DMG. **BOTH
  release paths** `swift build -c release`s the shim and copies+signs it into
  `Contents/MacOS/ghostty-mcp` (alongside the host, inside the notarized bundle, carried by
  Sparkle): `dist/macos/release-local.sh` step 3a (the PRIMARY local path — it was MISSING
  this until 2026-06-24, so locally-cut DMGs shipped no shim) and the CI workflow
  (`.github/workflows/fork-release.yml`, the manual-only fallback). On first launch
  `ForkSetup.installShimIfNeeded` copies it onto PATH at `~/.local/bin/ghostty-mcp`
  (version-aware via `kInstalledShimVersion`; reinstalls on a Sparkle bump or a manual
  delete). **Safety is symmetric with the host:** `planShimInstall` only acts when a shim
  is actually BUNDLED, and the whole of `perform()` early-returns unless a host is bundled
  — so a dev/local build never overwrites Ramon's hand-installed `~/.local/bin/ghostty-mcp`.
  The copy is a byte-level `Data.write(.atomic)` (NOT `copyItem`) so the bundle's quarantine
  xattr doesn't propagate to the loose copy. A colleague then registers with
  `claude mcp add ghostty -- "$HOME/.local/bin/ghostty-mcp"` (token auto-read from `local`);
  the committed `.mcp.json` (bare `ghostty-mcp`) serves repo-clone developers, not DMG users.
  Wiring: `dist/macos/release-local.sh` (step 3a build+bundle + the `sign` line) and
  `.github/workflows/fork-release.yml` (build+bundle+sign steps),
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

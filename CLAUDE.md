# Ghostty — ramon fork

Personal macOS fork of Ghostty that adds split/tab-reorganization commands and
runs side-by-side with an official Ghostty. Single working branch: **`ramon-fork`**.
Upstream conventions still apply (`AGENTS.md`, `macos/AGENTS.md`); this file only
covers what's specific to the fork.

> **PTY-host (emulation-on-host) work** lives on the **`ptyhost/phase-2b`** branch,
> not `ramon-fork`. If you are resuming or touching that work (the `.client` termio
> backend, `ghostty-host`, reattach-across-restart), read
> **`.claude/docs/ptyhost.md`** first — it has the architecture decisions,
> invariants/gotchas, the commit range, and open items. It is `git add -f`'d (the
> rest of `.claude/` is local-only).

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
  - **Liveness/errors** via `UNUserNotificationCenter` + log (Console.app subsystem = bundle id,
    category = `web-monitor`). No live config-reload (relaunch to change listen/token). Zero new
    SPM deps (Foundation + Network + AppKit; `xterm.js` is a vendored static asset, bundled via
    the synchronized Sources group + iOS exclusion). **DEPLOY caveat:** the host raw-tee is a HOST
    change — rebuilding/restarting `ghostty-host` LOSES all live sessions (RAM-only); the GUI/page
    parts are GUI-only (a relaunch reattaches). Wiring: `src/config/Config.zig` (`web-monitor-listen`
    + `web-monitor-token` + `pty-host` — the last is now `?[:0]const u8` so `ghostty_config_get` can
    return it as a C string for the `ptyHost` getter); `macos/Sources/Ghostty/Ghostty.Config.swift`
    (`webMonitorListen`/`webMonitorToken`/`ptyHost`); `macos/Sources/Features/WebMonitor/WebMonitorServer.swift`
    (server + xterm page + routes); `macos/Sources/Features/WebMonitor/WebMonitorHostClient.swift`
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
    `~/.config/ghostty-ramon/config`.
  - **Transport:** in-GUI HTTP JSON-RPC 2.0 on its own `NWListener` (`POST /mcp`:
    `initialize` / `tools/list` / `tools/call`) + a standalone stdio shim
    (`macos/mcp-shim`, `ghostty-mcp`, a dumb stdin↔HTTP pipe, NOT in `Ghostty.xcodeproj`,
    built with `swift build`) so `claude mcp add ghostty -- ghostty-mcp` works. The shim's
    default URL is `http://127.0.0.1:8765/mcp`; `GHOSTTY_MCP_URL`/`GHOSTTY_MCP_TOKEN` override.
  - **12 tools:** `list_surfaces`, `read_surface`, `get_layout`, `send_text`, `send_key`,
    `scroll`, `wait_for_event`, `watch_for_pattern`, `focus_surface`, `new_tab`,
    `close_surface`, `perform_action` (the keybind-action grammar string). All address a
    surface by **stable UUID**; `wait_for_event`/`watch_for_pattern` are long-poll
    (idle-watchdog-exempt, bounded by a clamped `timeoutMs` 1000–120000).
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
    (start on launch); `project.pbxproj` (iOS exclusion); `macos/mcp-shim/*`. Tests:
    `macos/Tests/MCP/MCPServerTests.swift` + the `mcp` Zig config test
    (`zig build test -Dtest-filter=mcp`).

## Fork-identity / non-functional changes
- **Bundle id** `com.mitchellh.ghostty-ramon` for Release, `.local` for the in-tree ReleaseLocal dev build, `.debug` for Debug — all coexist with the official `com.mitchellh.ghostty`, each with its own state/defaults domain. (`macos/Ghostty.xcodeproj/project.pbxproj`, `DockTilePlugin.swift` reads the host bundle id at runtime so each domain reads its own defaults.)
- **Display name** "Ghostty (ramon)" for Release, "Ghostty (ramon-local)" for ReleaseLocal — so the installed app and the in-tree dev build are visually distinguishable in the dock and ⌘-Tab.
- **Single-instance guard** in `AppDelegate.applicationWillFinishLaunching`: if another process with the same bundle id is already running from a different bundle URL, that one is activated and this process exits. Stops two copies of the same fork identity from racing each other (e.g. dock-attention bouncing one while you click the other).
- **Icon** defaults to `chalkboard` (`macos-icon` default in `src/config/Config.zig`); macOS swaps it per build at runtime so each identity is distinct at a glance — Release stays on `chalkboard`, ReleaseLocal becomes `paper`, Debug becomes `blueprint`. The swap fires only when the resolved icon is the fork default, so an explicit non-chalkboard `macos-icon` still wins. (`macos/Sources/Features/Custom App Icon/AppIcon.swift`)
- **Auto-update hard-disabled** in code: Sparkle never starts, `checkForUpdates` is a no-op, menu item disabled — independent of config. (`macos/Sources/Features/Update/UpdateController.swift`)
- **Config separation**: the fork additionally loads `~/.config/ghostty-ramon/config` on top of the shared `~/.config/ghostty/config`. Put fork-only keybinds **and fork-only config keys** there so an official Ghostty (which shares `~/.config/ghostty/config`) never errors on unknown actions or keys. Fork-only config keys so far: `project-directory`, `bell-features-focused`, `web-monitor-listen`, `web-monitor-token`. (`src/config/file_load.zig` `forkXdgPath`, `Config.zig` `loadDefaultFiles`)

## Iteration lifecycle (macOS)
Toolchain: full **Xcode** (not just Command Line Tools) + Metal toolchain + accepted
license; **Homebrew `zig@0.15`** (the official 0.15.2 tarball has a broken linker on
this macOS); `nushell` for `build.nu`.

1. Edit code (Zig core in `src/`, macOS in `macos/Sources/`).
2. **Zig tests**: `zig build test -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=<name>`.
3. **Rebuild lib** (required after any Zig change before the app build): `zig build -Demit-macos-app=false -Doptimize=ReleaseFast`.
4. **Swift tests**: `macos/build.nu --action test` (or `xcodebuild … -only-testing:GhosttyTests/SplitTreeTests test`).
5. **Build the app**: `macos/build.nu --configuration ReleaseLocal --action build` → `macos/build/ReleaseLocal/Ghostty.app` (optimized, no debug banner). This produces "Ghostty (ramon-local)" with bundle id `com.mitchellh.ghostty-ramon.local` — runs side-by-side with the installed Release identity.
6. **Install/update the fork** over `/Applications/Ghostty (ramon).app`. Verified to be safe to run while the installed Release fork is still hosting Claude Code's shell — `ditto` and `PlistBuddy` don't disturb the running mmap'd binary, and `codesign` succeeds after stripping Apple's `com.apple.provenance` xattrs. The new binary only takes effect on the next launch, so the user still has to quit + relaunch themselves.

   **Always ask the user to confirm before running this block — it overwrites the running host app.** The block:
   ```sh
   APP="/Applications/Ghostty (ramon).app"
   ditto macos/build/ReleaseLocal/Ghostty.app "$APP"
   /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.mitchellh.ghostty-ramon' "$APP/Contents/Info.plist"
   /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Ghostty (ramon)' "$APP/Contents/Info.plist"
   xattr -cr "$APP"                          # codesign rejects provenance xattrs
   codesign --force --deep --sign - "$APP"
   ```
   Never touch `/Applications/Ghostty.app`.
7. **Commit** to `ramon-fork`.

## ⚠️ Safety
**Two remotes — push ONLY to `fork`, NEVER to `origin`.**
- `origin` = *upstream* `ghostty-org/ghostty` (the official repo). **Never push here.**
  A push to `origin` would shove personal work at the official project.
- `fork` = personal backup `git@github.com:ramonsnir/ghostty.git`. Back it up with a
  **bare `git push fork`** (no refspec). The `fork` remote has a pinned push refspec
  (`remote.fork.push = refs/heads/ramon-fork:refs/heads/main`), so `git push fork`
  **always** pushes local `ramon-fork` → `fork/main`, **regardless of which branch is
  currently checked out** — you can run it from a `ptyhost/*` branch and it still backs
  up `ramon-fork`, never the feature branch.
  - **Do NOT add an explicit refspec** like `git push fork HEAD:main` — an explicit
    refspec overrides the pinned one and, from a feature branch, would overwrite
    `fork/main` with the wrong branch. Always use the bare `git push fork`.

So pushing to `fork` is now allowed and is the backup path; just confirm the
remote is `fork` before pushing, and **never** `git push origin`. The `ptyhost/*`
branches have no remote set — leave them local-only unless explicitly asked to back
them up to `fork`.

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
running binary), but **always ask the user to confirm** before running it, and
let them quit + relaunch the installed Release themselves to pick up the new
binary.

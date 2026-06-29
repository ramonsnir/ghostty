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

## 📝 Documentation discipline (BLOCKING)

**Every code change MUST update the relevant Markdown docs in the same change — this is
not optional.** When you touch a feature, update its feature doc at the repo root (e.g.
`AGENT-QUEUE.md`, `AGENT-DASHBOARD.md`, `AGENT-MANAGER.md`, `BELL-ATTENTION.md`,
`WEB-MONITOR.md`, `MCP-SERVER.md`, `PTYHOST.md`) AND the matching summary bullet + wiring
list in this `CLAUDE.md`, so the docs never drift from the code. A new config key / keybind
action / template knob / MCP tool / protocol field is incomplete until it is documented
(user-facing behavior in the feature doc, the load-bearing facts + file wiring in the
"Implementation notes" section, and the one-line summary here). Treat a docs update as part
of the definition of done for the work — land it in the same commit, not "later."

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
- **`equalize_splits` visual-grid equalization across direction changes** (fork-only tweak to the upstream `equalize_splits` action, chord/`ctrl+cmd+=`; no config key — always on) — equalize now sizes dividers so every **visible column is the same width and every visible row the same height**, independent of how the binary tree nests the splits. A pane that *shares* a column/row (a nested stack) is correspondingly smaller in area — that's intended (equal column/row, not equal area). The bug was direction changes: upstream's `weightForDirection` flattened any *perpendicular* nested split to weight 1, hiding a grid nested inside it and mis-placing the divider — so e.g. a tab with a 2×2 grid on the left beside a stacked pair on the right equalized to **50/50** (left columns 25% wide, right column 50%) instead of three equal-width columns. The fix is one line of intent in `weightForDirection`: a perpendicular split's extent along the queried axis is the **MAX of its children** (`Swift.max(...)`), not 1 — so the 2×2 counts as 2 columns vs the right's 1, the outer divider lands at **2/3 vs 1/3**, and all three columns come out 1/3 wide (rows stay 1/2). `equalizeWithWeight` still drives each split's `ratio = leftExtent / totalExtent` along the split's own axis (columns for `.horizontal`, rows for `.vertical`). NOTE: leaf-count/equal-*area* was considered and rejected — it over-widens a column that holds a stack. Wiring: `macos/Sources/Features/Splits/SplitTree.swift` (`weightForDirection` max-recursion + `equalizeWithWeight`). Tests: `macos/Tests/Splits/SplitTreeTests.swift` (`equalizedAdjustsRatioByLeafCount`, `equalizedStackedPairIsOneColumn`, `equalizedCountsNestedGridColumns`).
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

- **Bell Attention v2 — two-tier, fail-open "bell vs needs-you"** (fork-only, OFF by
  default; config `bell-features` / `attention-features` / `agent-manager-bell-filter`).
  Every bell fires `bell-features`; a bell PROMOTED by the Agent Manager's cheap per-bell
  fail-open classify additionally fires `attention-features` (the loud tier). Expanded
  `BellFeatures` vocabulary: `system,audio,attention,title,border,bounce,badge,dashboard,push,
  monitor` (a Zig packed struct ⇄ Swift OptionSet by FIXED bit position, pinned by a bit-ABI
  test). Load-bearing gotchas: parse is ADDITIVE over the type defaults (NOT reset-to-listed —
  dial down with explicit `no-*`); promotion is FAIL-OPEN (only a confident `attention===false`
  suppresses — do NOT use the lax `coerceBool`); promotion is EVENT-DRIVEN and must NOT depend
  on `view.bell`; the GUI never auto-sets `attentionNeeded` (only the sidecar via
  `set_attention`). **A truly focused surface (`bellIsFocused`) is NEVER promoted** — two
  guards close the "random bell from a healthy session" delayed-promotion race: (1)
  `MCPEventBus` skips emitting the `.bell` event for a focused surface, so the sidecar spends
  NO Haiku classify on it; (2) `SurfaceView.ghosttyAttentionDidChange` ignores a late
  `set_attention(true)` while focused (a clear always applies — this also covers the
  poll-driven rate-limit watchdog, which bypasses the bell event). Same mechanism as the Agent
  Manager's rate-limit watchdog. **See
  `BELL-ATTENTION.md` (→ Implementation notes) for the vocabulary table, launch gating, per-tier
  consumer routing, wiring + tests.** GUI relaunch + rebuilt sidecar `dist`; no host change.

- `bell-features-focused: BellFeatures` (fork-only config key) — a second bell-feature
  set governing the bell when the ringing surface is **truly in focus**: focused split
  / first responder AND `window.isKeyWindow` AND `NSApp.isActive` (a surface on another
  Space, in a backgrounded app, or a non-focused split counts as OUT OF FOCUS). When in
  focus, this set is used; otherwise the existing `bell-features` (unchanged, the
  OUT-OF-FOCUS set) is used. This is the **focused variant of tier 1** in the Bell
  Attention v2 model above (the ATTENTION tier has NO focused variant — a promotion clears
  on focus). Same value format and same (now v2-expanded) `BellFeatures` type
  (`system,audio,attention,title,border,bounce,badge,dashboard,push,monitor`); defaults are
  IDENTICAL to `bell-features`, so behavior is unchanged until set. For "sound only when
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

- **Bell/attention diagnostics** (fork-only, OFF by default; config `bell-diagnostics`) — when
  on, the GUI **and** the Agent Manager sidecar append a structured JSONL lifecycle trace to
  `~/Library/Logs/ghostty-ramon-bell-diagnostics.jsonl` so you can answer "why did the bell just
  fire", "why DIDN'T it fire an hour ago", and average ring→attention delay. One object per line
  `{ts, src:"gui"|"sidecar", ev, …}`: GUI `ring` (every bell + `focused`), `attention` (every
  `set_attention` + `reason` + `applied`=not-suppressed-by-focus), `clear` (focus dismissed a
  pending bell/attn); sidecar `classify` (per-bell `verdict`∈true/false/omitted/unparseable/error
  + `decision`∈promote/ignore + `durationMs`=Haiku-call time + `error`/`errorKind` on errors),
  `alert` edges (rate-limit WATCHDOG — fake bell from a prompt on the agent's screen), and
  `backoff` edges (the CLASSIFIER's OWN account throttled ⇒ bells fail-open into fake promotions
  until clear). Two "fake bell" sources are thus both visible. Delay = GUI-side `ring`→`attention`
  (user-perceived) + the `classify` `durationMs` (model portion); no sidecar ring-timestamp
  threading. GUI side is a pure-
  Foundation `BellDiagnostics` appender (O_APPEND, no AppKit ⇒ no pbxproj exclusion) gated per
  call site on `config.bellDiagnostics` (no global state); sidecar side is `diag.ts` gated by
  `GHOSTTY_BELL_DIAG=1` (forwarded by `AgentManagerController` when the config is on). Append-only
  (turn it off when done). GUI relaunch + rebuilt sidecar `dist`; no host change. **See
  `BELL-ATTENTION.md` (→ Diagnostics) for the schema + jq recipes.** Wiring: `src/config/Config.zig`,
  `Ghostty.Config.swift` (`bellDiagnostics`), `BellDiagnostics.swift`, `AppDelegate.swift`,
  `SurfaceView_AppKit.swift`, `AgentManagerController.swift`, `agent-manager/src/{diag,index}.ts`.
  Tests: `Config.zig` (`bell-diagnostics`), `BellDiagnosticsTests.swift`, `diag.test.ts`.

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

- **Bell/attention persist across GUI restart** (fork-only tweak to upstream macOS Swift; no
  config key — always on) — `bell` (🔔) + `attentionNeeded` ("needs you") were @Published
  runtime-only state on `SurfaceView`, ABSENT from its `Codable` `CodingKeys`, so every GUI
  restart-for-a-new-build reset them to `false` and the indicators silently vanished. Fix:
  persist BOTH in the SAME window-state archive that already restores the split tree +
  per-surface `uuid`/`sessionID` (the phase-2b pty-host reattach path), so a restored surface
  comes back still flagged — no new persistence layer. **Restore sets the @Published values
  DIRECTLY in `init(from:)` (legal on `private(set)` from inside the class), NOT via the
  `ghosttyBellDidRing`/`ghosttyAttentionDidChange` notifications** — so a relaunch re-lights
  only the STICKY visuals derived from these states (🔔 title, amber border, dock badge,
  dashboard mark) and deliberately does NOT re-fire the one-shot loud effects (dock bounce,
  system beep, Web Push). Back-compat both ways: `decodeIfPresent ?? false` (pre-fork/`.exec`
  archives read false) + gated `if bell`/`if attentionNeeded` encode (healthy surface's
  archive byte-identical). Focusing a restored surface clears both via `focusDidChange`,
  exactly as at runtime; rides the existing `window-save-state` restoration (off ⇒ nothing
  persists). **⚠️ Correct Codable is NOT enough on its own:** macOS restoration is
  dirty-tracked, so every `bell`/`attentionNeeded` mutation must call
  `invalidateBellRestorableState()` (`window?.invalidateRestorableState()`) or AppKit re-saves
  the STALE blob from the last surface-tree change and the markers vanish on restart anyway —
  this was the original "still not working" bug (the persistence shipped without the
  invalidation; the split tree restored fine but the per-surface flag didn't). Helper is called
  from the ring/attention setters, focus-clear, and the web-monitor clears. GUI-only, no host
  change. Wiring: `macos/Sources/Ghostty/Surface
  View/SurfaceView_AppKit.swift` (`SurfaceView` `CodingKeys` + `init(from:)`/`encode(to:)` +
  `invalidateBellRestorableState()` at each mutation site).
  See `BELL-ATTENTION.md` (→ Surviving a GUI restart / Implementation notes).

- **Web monitor** (fork-only, OFF by default; config `web-monitor-listen` / `web-monitor-token`)
  — a GUI-embedded HTTP server (one `NWListener` on a dedicated serial queue) that, from a phone
  over Tailscale, lists live surfaces, renders one in full color via `xterm.js` fed the host's
  raw PTY byte stream (color + scrollback + live), sends input, and remote-controls scroll; plus
  a bell→Web-Push "I stepped away" notifier. **SCOPE: phone workflows ONLY — do not build new
  features on it; other work may COPY its patterns but must stand alone.** Load-bearing gotchas:
  input is sent as REAL key/wheel events (`ghostty_surface_key` with the NATIVE macOS virtual
  keycode — the `GHOSTTY_KEY_*` enum value is WRONG and silently no-ops), NOT the paste path;
  **Scroll ↑/↓ is "smart" (`smartScroll`, page-side)** — KEY FACT: the host's `raw_output` carries
  only CHILD pty output, so a host-side scroll emits nothing back to the phone; the browser's
  `xterm.js` holds the only replayable scrollback. It reads the LIVE mode off `xterm.js`
  (`buffer.active.type` + `modes.mouseTrackingMode`) and routes 3 ways: normal buffer (shell,
  **Claude Code**) → scroll xterm.js's OWN scrollback LOCALLY (`term.scrollLines`, no host
  round-trip — the previously-broken common case); alt+mouse (htop/vim+mouse) → real wheel so the
  app redraws; alt+no-mouse (less/man/vim) → PageUp/PageDown (a wheel is a dead no-op there — the
  `.client` mirror's alt-screen `active_key` is a documented `src/termio/Client.zig` residual); Web
  Push needs a SECURE CONTEXT (`tailscale serve` in front, external HTTPS port ≠ internal bind
  port or the bind hits `EADDRINUSE`); the raw-tee is a HOST change (host restart loses sessions).
  **See `WEB-MONITOR.md` (→ Implementation notes) for the color/scrollback architecture, HTTP
  API, threading, push/VAPID, wiring + tests.**

- **MCP server** (fork-only, OFF by default; config `mcp-listen` / `mcp-token` — the token is a
  SHELL-EXECUTION credential, so bind localhost + always set it) — a GUI-embedded MCP server
  (HTTP JSON-RPC + a stdio shim `ghostty-mcp`) giving an orchestrating agent **26** registered
  tools (12 agent-control + the queue internals + `get_haiku_usage` + the 4 knowledge tools below) to control
  the fork (splits/tabs, open/run) and watch+respond to sessions (read screen, type input,
  approve prompts) — plus `get_haiku_usage` (Agent Manager budget query, see that bullet). Built entirely on existing libghostty/Swift abstractions — the only Zig
  change is two default-null config keys, so enabling/changing it is a GUI relaunch, never a host
  restart. COPIES the web monitor, never depends on it. Load-bearing gotchas: same NATIVE-keycode
  input rule; `processName`/`command` are HOST-GATED (absent until the host is a minor-3 build);
  `read_surface` is VIEWPORT-ONLY by design (no `mode` param — don't re-add one); `atPrompt` rides
  the coarse `needsConfirmQuit` bit, not OSC 133. Durable registration via a committed `.mcp.json`
  + the shim on PATH at `~/.local/bin/ghostty-mcp` (token read from `~/.config/ghostty-ramon/local`).
  **See `MCP-SERVER.md` (→ Implementation notes) for the tool list, transport, port offset,
  host-gating, wiring + tests.**

- **MCP knowledge tools (fork-only, READ-ONLY config/feature DISCOVERY) — the
  "what can I configure / is feature X on" tools, so an agent can answer a colleague
  without anyone scrolling the command palette.** FOUR additive read-only tools on the
  MCP server (registered tool count **21 → 25**; **update the `toolsListHasAllTools`
  assertion in `MCPServerTests.swift` whenever a tool is added/removed**): (1)
  **`get_effective_config`** — current value + `isDefault` for a curated key set (every
  fork-only key + high-signal upstream keys), `changedOnly` (default true) returns only
  user-set keys; secrets (`mcp-token`/`web-monitor-token`) are REDACTED to `<set>`/``,
  never echoed; PURE Swift over the typed `Ghostty.Config` getters, `isDefault` compared
  against a fresh `Ghostty.Config.defaultConfig()` (a finalized initial-defaults config).
  (2) **`docs_for_feature`** — a curated `FeatureDoc` table (agent-dashboard / agent-manager
  / agent-queue / web-monitor / mcp / project-selector / splits / `all`) whose `enabled`/
  `requires` are computed LIVE from the config with the REAL precondition predicates (the
  pure `MCPKnowledge.status(_:pre:)` MIRRORS `AgentManagerController.sidecarShouldStart` for
  the sidecar features). (3) **`describe_config_key`** — one key's doc text (same as
  `+explain-config`), fork-only flag, current value (type/default live inside the doc text). (4) **`list_config_keys`** — every
  key's name + one-line summary + fork flag, with `filter`/`forkOnly`. (3)+(4) are backed by
  a NEW read-only Zig C API that needs NO `*Config` (reads the generated `help_strings` + the
  `Key` enum): `ghostty_config_describe_key(name,len)` → `ghostty_config_key_doc_s`,
  `ghostty_config_key_count()`, `ghostty_config_key_at(idx)` → `ghostty_config_key_info_s`
  (all returned `[*:0]const u8` are STATIC — do not free). **Fork-only-key detection is the
  doc's leading `(ramon fork` prefix** (`fork_marker` in `CApi.zig`; matches the bare
  `(ramon fork)` AND scoped `(ramon fork / …)` forms — NOT including the closing paren,
  else scoped keys like agent-manager/agent-queue are missed), so any new fork key whose
  doc starts with that prefix is auto-classified. Live config reads hop to main and
  return ONLY value types (the WebMonitor/MCP threading rule); the C-API path works headless.
  Wiring: core — `src/config/CApi.zig` (the 3 exports + `keyDoc` + `KeyDoc`/`KeyInfo` extern
  structs), `include/ghostty.h` (`ghostty_config_key_doc_s`/`_info_s` + the 3 prototypes);
  macOS — `macos/Sources/Features/MCP/MCPKnowledge.swift` (NEW: readers table, `FeatureDoc`/
  `FeatureSpec`/`Preconditions`/`status`, `describeBellFeatures`/`redact`),
  `MCPTools.swift` (4 schemas + dispatch), `Ghostty.Config.swift` (`describeKey`/
  `allConfigKeys`/`defaultConfig`/`firstLine` + `KeyDoc`/`KeyInfo` value types),
  `project.pbxproj` (iOS exclusion of `MCPKnowledge.swift`). Tests:
  `macos/Tests/MCP/MCPServerTests.swift` (knowledge tool registration, `describe_config_key`/
  `list_config_keys` dispatch, pure-helper + `status` predicate + `entries` tests, tool count
  now 25) + the `ghostty_config_describe_key`/`_key_count`/`_key_at` Zig tests in
  `src/config/CApi.zig` (`zig build test -Dtest-filter=CApi`). **GUI relaunch + a lib/
  xcframework rebuild (the 3 C exports are new); no host restart.**

- **Agent Dashboard** (fork-only, macOS, OFF by default; config `agent-dashboard` /
  `agent-dashboard-commands` / `agent-dashboard-pin`, action `toggle_agent_dashboard`) — a sidebar
  `NSPanel` with a live natively-rendered preview of every split running a CLI agent (Claude/Codex)
  across all tabs/windows; click to jump, Hide to declutter, bell auto-unhides; `agent-dashboard-pin`
  floats + activates the panel (so Rectangle can move it). Live previews need `pty-host` (each tile
  mounts a read-only mirror `SurfaceView`). Load-bearing gotchas: agent detection is HOST-GATED on
  the minor-4 `foreground_pid` frame (finds nothing until the host is rebuilt; `proc_listchildpids`
  is unreliable — use `proc_listpids`); the smart bottom-anchor footer-trim must test the Unicode
  whitespace property (Claude pads the prompt with NBSP U+00A0); per-tile working/waiting/idle state
  comes from Claude Code hooks POSTing to the MCP `/agent-state` route, correlated to a surface by
  walking the hook's ppid chain for the controlling tty (the hook's own tty is detached/`??`). **See
  `AGENT-DASHBOARD.md` (→ Implementation notes) for the bottom-anchor subsystem, detection, hook
  plumbing, wiring + tests.**

- **Agent Manager** (fork-only, macOS, OFF by default; config `agent-manager` /
  `agent-manager-node-path`) — a Haiku status summarizer that annotates each dashboard tile with a
  live one-line semantic status. Read-only (never types into a session). A warm TypeScript Agent
  SDK sidecar (`macos/agent-manager/`) is the brain, the MCP server its hands; billing rides Claude
  Code's own auth (NO Anthropic API key). Load-bearing gotchas: agent DETECTION keys off
  `agentKind`, NOT `processName` (under the `claude-pool` wrapper the fg process is `bash`); the
  sidecar SELF-DISABLES unless a feature is on + MCP configured + `node` on PATH; it is SHARED with
  the Agent Queue (per-feature env flags gate the two loops; the summarizer's `GHOSTTY_SUMMARIZER`
  absent=ON for back-compat); cost is controlled by hidden-throttle + fuzzy change-detection +
  quiescent-skip + a config overlay + rate-limit auto-backoff; for colleagues the sidecar is bundled
  dist-only AND the Haiku summarizer + rate-limit bell watchdog now WORK for DMG users (no longer
  dev-only) — the release build inlines ONLY the SDK's JS via esbuild (no 215MB native binary) and
  `model.ts` points the SDK at the colleague's ALREADY-INSTALLED `claude` via
  `pathToClaudeCodeExecutable` (the `GHOSTTY_CLAUDE_PATH` env, set by `AgentManagerController` from a
  ROBUST `claude`/`node` probe — `probeExecutableViaLoginShell` checks well-known absolute locations
  FIRST (`wellKnownExecutablePaths`: `~/.local/bin`, `~/.claude/local`, Homebrew, nix) then a LOGIN
  then an INTERACTIVE login shell `command -v` (`-lc`→`-ilc`), so it finds a `claude`/`node` whose
  PATH entry lives only in `.zshrc` — which a plain `-l` probe silently missed, the same colleague
  bug that broke MCP auto-registration), billed to their own Claude subscription; needs `node` +
  `claude` findable, else the summarizer self-disables per-surface while the queue still runs.
  **Haiku usage/budget tracking (config `agent-manager-usage-tracking`, default ON):** every Haiku
  call is recorded as one JSONL line to `~/Library/Logs/ghostty-ramon-haiku-usage.jsonl` tagged with
  the FEATURE (`summarizer`/`bell-classify`) + account, so you can ask "how much per feature over the
  last N hours" — captured at the single chokepoint `model.ts summarize()` (an `onUsage` callback
  reading the SDK's `usage`+`total_cost_usd`, verified non-zero), tagged at the `index.ts` call site,
  persisted by `usage.ts` (survives GUI restarts — it's a file; 14-day retention trimmed at startup),
  and queried by the **`get_haiku_usage` MCP tool** (`{hours?}`, default 3 → total + per-feature +
  per-account, via the pure `MCPUsage.aggregate`). The Zig bool `agent-manager-usage-tracking`
  (default true) gates it, forwarded to the sidecar EXPLICITLY as `GHOSTTY_HAIKU_USAGE=1`/`0` by
  `AgentManagerController` so the config wins over the sidecar's default-on; set it `false` in
  `~/.config/ghostty-ramon/config` to disable (GUI relaunch; Zig/lib rebuild but NO host restart —
  the host ignores the key). **See `AGENT-MANAGER.md` (→ Implementation notes) for the loop, cost
  controls, account routing, the rate-limit attention watchdog, the system-`claude`/esbuild bundle,
  Haiku usage/budget tracking, wiring + tests.**

- **Agent Queue Supervisor** (fork-only, macOS, OFF by default; config `agent-queue` /
  `agent-queue-templates-dir` / `agent-queue-max-total`, action `start_agent_queue`) — turns the
  dashboard into an active supervisor: from a user-authored JSON template it opens a tab of splits,
  launches one CLI agent per work item, caps concurrency, never doubles up on an item key, tracks
  each to completion via status, force-closes a done+idle split, and re-polls. **`agent-queue-max-total`
  is an OPTIONAL fleet-wide cap across ALL runs, default `0` = UNLIMITED** (was 8) — a queue is
  bounded only by its own `concurrency`/`maxItems`/grid unless you set a positive value. (Its Swift
  getter had a latent bug — read into a `UInt32?` so `ghostty_config_get` could never set the
  Optional tag → always returned the hardcoded 8, silently ignoring the config AND any per-queue
  `concurrency` above 8; fixed to a non-optional read. See AGENT-QUEUE.md → Implementation notes.)
  GENERIC by design —
  Ghostty links NO tracker; the template names shell `list`/`status`/`claim` provider commands (item
  fields reach the provider as argv `{key}` and the agent as `GHOSTTY_ITEM_*` env — NEVER
  string-spliced). The engine is a deterministic loop in the shared TS sidecar (no LLM in the
  control path). HARD DEPS (self-disables otherwise): pty-host + the Claude agent-state hooks (Codex
  can dispatch but not auto-close). No-duplicates rests on a persisted dispatch LATCH (re-dispatch
  needs a real status round-trip) + reconcile + restart survival. Grid is a balanced BSP with
  multi-tab overflow (`largestLeafSplit` MUST use real pixel bounds) that is **grid-CONSTRAINED** —
  the template `grid.cols`/`grid.rows` are threaded as HARD caps (sidecar → MCP → `largestLeafSplit`)
  so a tab never exceeds `cols` columns / `rows` rows (e.g. on an ultrawide a 3×2 grid now stacks a
  2nd row instead of a 4th column); caps ≤0/absent = byte-identical pure-aspect back-compat. The dashboard shows per-queue
  health + a backlog dependency DAG; cap and concurrency are editable live. A per-split **📌 KEEP
  pin** (dashboard tile; template default `keepOnComplete`) **exempts a completed split from
  auto-close** so you can do manual work in it — held in DONE_PENDING (slot kept, like
  `closeOnComplete:false`), never force-closed, persisted across restart; toggled via a
  `set_keep{run,key,keep}` command, state carried on the surface annotation (`queueKeep`). Keep is
  RUN-LEVEL state (`QueueRun.keep` map, mirrors the `dispatched` latch — survives reconcile),
  `effectiveKeep = run.keep[key] ?? template.keepOnComplete`. A **`release{run,key?}`** command
  is the in-place escape from the dispatch latch's "needs a tracker status round-trip" rule: an
  agent that crashed/exited or was killed before claiming leaves its item latched-but-listed
  ("held"), never rescheduled. The health bar surfaces an orange **`N held`** chip (the sidecar
  status report now carries `held`/`heldCount` = listed ∩ latched ∩ ¬active) → **Release** (per
  item or all) clears the latch (+ cooldown) so the queue re-dispatches it on the next `list`
  poll, NO Linear round-trip. Like `set_keep`, release lives in the per-run store (persisted by
  the next reconcile sweep, not an active-runs change). **See `AGENT-QUEUE.md`
  (→ Implementation notes) for the full engine, MCP tools, grid/packing, health/backlog, live edits,
  keep, restart hardening, wiring + tests.**

## Fork-identity / non-functional changes
- **Bundle id** `com.mitchellh.ghostty-ramon` for Release, `.local` for the in-tree ReleaseLocal dev build, `.debug` for Debug — all coexist with the official `com.mitchellh.ghostty`, each with its own state/defaults domain. (`macos/Ghostty.xcodeproj/project.pbxproj`, `DockTilePlugin.swift` reads the host bundle id at runtime so each domain reads its own defaults.)
- **Display name** "Ghostty (ramon)" for Release, "Ghostty (ramon-local)" for ReleaseLocal — so the installed app and the in-tree dev build are visually distinguishable in the dock and ⌘-Tab.
- **Single-instance guard** in `AppDelegate.applicationWillFinishLaunching`: if another process with the same bundle id is already running from a different bundle URL, that one is activated and this process exits. Stops two copies of the same fork identity from racing each other (e.g. dock-attention bouncing one while you click the other).
- **Icon** defaults to `chalkboard` (`macos-icon` default in `src/config/Config.zig`); macOS swaps it per build at runtime so each identity is distinct at a glance — Release stays on `chalkboard`, ReleaseLocal becomes `paper`, Debug becomes `blueprint`. The swap fires only when the resolved icon is the fork default, so an explicit non-chalkboard `macos-icon` still wins. (`macos/Sources/Features/Custom App Icon/AppIcon.swift`)
- **Auto-update via Sparkle, pinned to the fork's OWN GitHub Releases feed** (was hard-disabled; re-enabled for colleague distribution). Sparkle starts normally but `UpdateDelegate.feedURLString` points at `github.com/ramonsnir/ghostty/releases/latest/download/appcast.xml`, never ghostty.org, so the fork is never replaced by an official build. Dev builds still don't auto-check (`Ghostty-Info.plist` ships `SUEnableAutomaticChecks=false`); the CI release build deletes that key. The committed `SUPublicEDKey` is the fork's OWN real public key (generated at enrollment via Sparkle `generate_keys`; public keys aren't secret), matching the `SPARKLE_PRIVATE_KEY` CI secret; CI re-injects `SPARKLE_PUBLIC_KEY` as belt-and-suspenders. (`UpdateController.hasPlaceholderUpdateKey` still guards the all-zero placeholder so a future placeholder build fails closed.) See "Distribution / sharing the fork" below. (`macos/Sources/Features/Update/{UpdateController,UpdateDelegate}.swift`)
- **App Nap opt-out (fork-only, macOS; always on)** — `AppDelegate.applicationDidFinishLaunching` holds a process-lifetime `ProcessInfo.beginActivity(.userInitiatedAllowingIdleSystemSleep)` token (`appNapAssertion`) so macOS never naps/throttles the GUI while backgrounded or occluded. **Load-bearing for the `.client` backend:** the host connection is opened from per-surface IO threads at surface creation and is **single-shot (no retry — see `src/termio/Client.zig` `connectAndAttach`)**, so if the GUI is relaunched into the background with **no active display** (a remote restart while away), App Nap can suspend those threads before they connect to `ghostty-host`, leaving every restored surface permanently blank until a manual restart-while-present. This is exactly the 2026-06 weekend symptom ("restarted Ghostty remotely while away → monitor showed empty surfaces all weekend; restarting while at the Mac fixed it"). The `...AllowingIdleSystemSleep` option opts out of App Nap **without** preventing system/display sleep (it omits the idle-sleep-disable bits), so battery/sleep behavior is unchanged — we only decline to be napped (it also disables sudden/automatic termination, desirable for a terminal). Note: a connect-retry/reconnect in the `.client` backend was considered and **deliberately skipped** — the host is a KeepAlive LaunchAgent (≈always up, so connect rarely fails) and a dropped host can't restore RAM-only sessions anyway, so it was high-risk surgery on the most delicate lifecycle code for an unobserved failure mode. (`macos/Sources/App/macOS/AppDelegate.swift`)
- **Config separation**: the fork additionally loads `~/.config/ghostty-ramon/config` on top of the shared `~/.config/ghostty/config`. Put fork-only keybinds **and fork-only config keys** there so an official Ghostty (which shares `~/.config/ghostty/config`) never errors on unknown actions or keys. Fork-only config keys so far: `project-directory`, `bell-features-focused`, `attention-features`, `agent-manager-bell-filter`, `bell-diagnostics`, `web-monitor-listen`, `web-monitor-token`, `mcp-listen`, `mcp-token`, `agent-dashboard`, `agent-dashboard-commands`, `agent-dashboard-pin`, `agent-manager`, `agent-manager-node-path`, `agent-manager-usage-tracking`, `agent-queue`, `agent-queue-templates-dir`, `agent-queue-max-total`. (`src/config/file_load.zig` `forkXdgPath`, `Config.zig` `loadDefaultFiles`)

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

- **First-launch setup (`ForkSetup`, GUI-only, distribution builds).** Idempotent, safe on
  every launch, and now SPLIT in two by launch ordering: `performHostSetup()` (host-critical)
  + `performDeferred()` (the rest); `perform()` still runs both for callers/tests. SEVEN jobs
  total: (1) seed a sanitized `~/.config/ghostty-ramon/config` if absent (embedded
  `seedTemplate`, `__HOME__` substituted, the whole `ctrl+a` keybind layer commented out, open
  `mcp-listen`/`web-monitor-listen` disabled — see the seed bullet below); (2) **auto-provision
  the untracked machine-local `~/.config/ghostty-ramon/local`** with `mcp-listen` + a CSPRNG
  `mcp-token` (see the local-secrets bullet below); (3) install/version-reload a launchd
  LaunchAgent for a `ghostty-host` BUNDLED at `Contents/MacOS/ghostty-host`; (4) install the
  bundled `ghostty-mcp` shim onto PATH (see the MCP-shim bullet below); (5) install a
  **`ghostty-ramon` CLI launcher** onto PATH (see the next bullet); (6) fire a **one-time
  first-run welcome notification** (idempotent via the persisted `forkSetup.welcomeShown`
  bool; pure predicate `shouldShowWelcome(alreadyShown:)`) that points the colleague at
  `ghostty-ramon +list-keybinds` / `ONBOARDING.md` — concrete discovery, NOT "scroll the
  command palette". The welcome bool is recorded BEFORE `notify()` fires so a failed/denied
  notification can't re-fire it every launch; (7) **auto-register the Ghostty MCP server with
  Claude Code** (`claude mcp add ghostty --scope user -- ~/.local/bin/ghostty-mcp`) so a fresh
  `claude` session can SEE it — see the MCP-registration bullet below. **`performHostSetup()` (jobs 1–3) runs
  SYNCHRONOUSLY and EARLY in `AppDelegate.applicationDidFinishLaunching` — before any window/
  `.client` surface is created — so the bundled host is installed + bootstrapped + RUNNING
  before a surface dials its socket, eliminating the blank-pane race** (steady-state fast path:
  one `launchctl print`; only first-install/version-change spends the bootstrap budget). It
  returns a Bool (true iff a host is bundled = the distribution path); the deferred jobs 4–6
  run off-main only when it returned true. **HONEST CAVEAT: pty-host still only takes EFFECT on
  the SECOND launch on a fresh machine** — the GUI reads `pty-host` in `Ghostty.App.init()`
  (before any launch callback), so the freshly-seeded value isn't seen until the next launch.
  `performHostSetup()` removes the connection RACE on every configured launch, not the one-time
  relaunch (no `Client.zig` connect-retry was added — deliberate). **Two safety gates make it
  impossible to clobber a hand-managed host** (Ramon's own dev setup uses the SAME label
  `com.mitchellh.ghostty-ramon.host`): it only acts when a host is actually bundled
  (local/dev builds skip — they don't bundle it), and it writes an ownership marker
  (`GhosttyAppManaged` = bundle id) into any plist it creates, refusing to touch a
  pre-existing plist that lacks the marker. The version-aware reload (bootout+bootstrap,
  never kill) re-derives launchd's LWCR after a Sparkle update gives the bundled host a
  new cdhash — encoding the LWCR gotcha (below) into the app. Pure planner `plan(...)`,
  `makeSpec`, `configSeedContents`, `readPlistMarker`, `planCLIInstall`, `shouldShowWelcome`,
  `planLocalSecretsInstall`, `localHasMCPToken`, `planMCPRegister` are unit-tested. Wiring:
  `macos/Sources/Features/ForkSetup/ForkSetup.swift` (`import Security` for the CSPRNG;
  `registerMCPWithClaudeIfNeeded` + `loginShellStatus`/`claudeOnPath`/`ghosttyMCPRegistered`),
  `AppDelegate.swift` (the synchronous `performHostSetup()` call + the off-main
  `performDeferred()`), `project.pbxproj` (iOS exclusion). Tests:
  `macos/Tests/ForkSetup/ForkSetupTests.swift` (incl. `cli*` plan gates, `welcome*`,
  `mcpRegister*`, `localSecrets*`/`generateMCPToken`/`localHasMCPToken`, and the seed-content
  `configSeed*` assertions for the new onboarding content).

- **Auto-provisioned MCP secrets (`~/.config/ghostty-ramon/local`, ForkSetup job 2).** On
  first launch the fork writes the untracked machine-local `local` with `mcp-listen =
  127.0.0.1:8765` + a freshly-generated CSPRNG `mcp-token` (`generateMCPToken` = 32
  `SecRandomCopyBytes` bytes → 64 hex chars, well over the 16-byte floor), so the MCP server,
  the `ghostty-mcp` shim, the Claude agent-state hooks, and the dashboard chips / agent queue /
  manager **work OUT OF THE BOX with no hand-written token** (the seeded config already pulls
  `local` in via the optional include). Pure decision `planLocalSecretsInstall(localExists:
  hasToken:)` → `.skipHasToken` / `.create` / `.append`: it NEVER rotates or clobbers an
  existing token (presence of a non-comment `mcp-token`, detected by `localHasMCPToken`, is the
  idempotency key); a missing `local` is created with a header; an existing `local` WITHOUT a
  token is APPENDED to (preserving any other machine-local keys like `web-monitor-listen`).
  Impure `seedLocalSecretsIfNeeded`; the token value is never logged. Wiring/Tests as in the
  ForkSetup bullet above.

- **`ghostty-ramon` CLI launcher on PATH (fork-only, ForkSetup job 4).** A SYMLINK at
  `~/.local/bin/ghostty-ramon` → the app's multitool binary `Contents/MacOS/ghostty`, so a
  colleague can run discovery commands like `ghostty-ramon +list-keybinds` /
  `ghostty-ramon +show-config` (the cheat-sheet entrypoint the seed + welcome point at).
  **Named `ghostty-ramon`, NOT `ghostty`,** so it can't collide with an official ghostty CLI
  already on PATH. A SYMLINK (not a copy) so it always tracks the installed app — no rewrite
  when a Sparkle update relocates the bundle. Idempotent + version-aware with the SAME safety
  gates as the MCP shim, via the pure `planCLIInstall(...)` → `CLIPlan` (`.skipNoBundledBinary`
  / `.skipExternallyManaged` / `.upToDate` / `.install`): acts only when the multitool is
  actually BUNDLED, NEVER clobbers a pre-existing NON-managed file (only a symlink WE created —
  one whose resolved destination is THIS app's multitool, recognized by `symlinkPointsAt`), and
  reinstalls on a deleted symlink or a `CFBundleVersion` change (recorded in
  `forkSetup.cliLauncherVersion`). Because `perform()` early-returns unless a host is bundled, a
  dev/local build never installs it (so it can't overwrite Ramon's own PATH). Wiring:
  `ForkSetup.swift` (`CLIPlan`/`planCLIInstall`/`installCLILauncherIfNeeded` +
  `fileExistsOrSymlink`/`symlinkPointsAt` helpers). Tests: `ForkSetupTests.swift` (`cli*`).

- **Seed-template REFRAME — FEATURE-FIRST, keybindings opt-in (`ForkSetup.seedTemplate`).**
  The auto-seeded `~/.config/ghostty-ramon/config` no longer IMPOSES the personal keybind
  layer (all asserted by `configSeed*` tests): (1) **the WHOLE tmux-style `ctrl+a` keybind
  layer is COMMENTED OUT** at the bottom of the file under an "OPTIONAL: my personal tmux-style
  `ctrl+a` keybindings — ALL COMMENTED OUT" header — nothing is bound for a colleague (so any
  matrix/example claim that the seed ships ACTIVE fork keybinds is no longer true). (2) the
  top-of-file **QUICK START** block now explains the FEATURES and the **Command Palette**
  (cmd+shift+p → type "split"/"tab"/"project"/"agent"), not keybindings, with the discovery
  pointers `ghostty-ramon +list-keybinds` / `+show-config --default --docs` and ONBOARDING.md.
  (3) feature SETTINGS stay ACTIVE — `agent-dashboard = true`, `agent-dashboard-commands`,
  `auto-update = check`, `bell-features`, the `pty-host` socket (parameterized), etc.; only the
  binds are commented. (4) `agent-queue = true` is present but COMMENTED (opt-in; needs node +
  the agent-state hooks + a template). (5) `project-directory = ~/git` is COMMENTED (so an
  unconfigured machine doesn't get an empty project picker). (6) softened
  `bell-features-focused` = VISUAL-ONLY `no-system,no-attention,no-title` (was
  `system,no-attention,no-title`) — no audible beep while the ringing split is focused. (7) the
  MCP section documents that `local` is AUTO-PROVISIONED with a bind + random token on first
  launch (no longer "enable only WITH a hand-written token"). (Keep `example/ghostty-ramon/config`
  in sync if the live config also changes — the seed is a separate sanitized template, not a
  copy of `example/`.)

- **`claude-hooks` + `ONBOARDING.md` bundled into `Contents/Resources` (BOTH release
  paths).** The colleague-onboarding deliverables ship INSIDE the notarized bundle (carried
  by Sparkle, like the host / shim / agent-manager sidecar): the Claude Code agent-state
  hooks (`example/claude-hooks/` → `Contents/Resources/claude-hooks/`) so a DMG user has the
  hook script + settings block locally (the dashboard per-tile state + the queue auto-close
  depend on it — see AGENT-DASHBOARD.md), and `ONBOARDING.md` → `Contents/Resources/` so the
  cheat-sheet the seed/welcome point at travels with the app (no repo clone needed). Both
  release paths copy them alongside the existing agent-manager bundle step: the PRIMARY local
  `dist/macos/release-local.sh` and the manual-only `.github/workflows/fork-release.yml`.
  DMG-user install instructions reference the bundled `…/Contents/Resources/claude-hooks`
  path; repo-clone developers keep using `example/claude-hooks/` (see AGENT-DASHBOARD.md).

- **`ONBOARDING.md` (repo-root colleague onboarding doc).** The single concrete onboarding
  entrypoint a colleague is pointed at by the first-run welcome notification, the seed config
  header, and SHARING.md — deliberately NOT "browse the command palette" (colleagues won't).
  Covers the keybind cheat sheet (`ctrl+a` prefix gestures), discovery commands
  (`ghostty-ramon +list-keybinds` / `+show-config`), and the works-OOTB-vs-needs-setup
  feature matrix. Bundled into `Contents/Resources` (above) so DMG users have it locally.

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
  xattr doesn't propagate to the loose copy. The colleague no longer registers by hand —
  ForkSetup job 7 runs `claude mcp add` for them (see the next bullet; token auto-read from
  `local`); the committed `.mcp.json` (bare `ghostty-mcp`) serves repo-clone developers, not
  DMG users.
  Wiring: `dist/macos/release-local.sh` (step 3a build+bundle + the `sign` line) and
  `.github/workflows/fork-release.yml` (build+bundle+sign steps),
  `macos/Sources/Features/ForkSetup/ForkSetup.swift` (`ShimPlan`/`planShimInstall`/
  `installShimIfNeeded`); tests in `macos/Tests/ForkSetup/ForkSetupTests.swift` (`shim*`).

- **Auto-registered MCP server with Claude Code (fork-only, ForkSetup job 7).** Installing the
  shim onto PATH is NOT enough for the MCP to appear in a colleague's Claude Code — Claude Code
  must be TOLD about it. So on first launch (deferred, AFTER the shim install) the fork runs
  `claude mcp add ghostty --scope user -- ~/.local/bin/ghostty-mcp` for them, making the Ghostty
  MCP visible in EVERY `claude` session (user scope = any cwd). The shim reads the token from
  `local` at runtime, so the registration carries NO secret. Pure decision
  `planMCPRegister(alreadyRecorded:claudeFound:shimExists:alreadyRegistered:)` →
  `.skipAlreadyRecorded` / `.skipNoClaude` / `.skipNoShim` / `.skipAlreadyRegistered` /
  `.register`: it records success (persisted `forkSetup.mcpRegisteredWithClaude`) so it stops
  probing, but leaves a transient miss (`claude` or the shim not present yet, or `claude mcp add`
  non-zero) UNrecorded so a later launch retries; it NEVER clobbers a pre-existing `ghostty`
  server (a hand-managed entry is left strictly alone). **`claude` resolution is ROBUST to the
  GUI's pristine launchd PATH** — `resolveClaude` checks well-known absolute locations FIRST
  (`~/.local/bin/claude` = the official native installer, `~/.claude/local/claude`, Homebrew,
  nix — pure `claudeCandidatePaths`/`firstExecutablePath`), then falls back to a LOGIN shell and
  an INTERACTIVE login shell `command -v` (`-lc` then `-ilc`, the latter sourcing `.zshrc` where
  most installs put the PATH). **This was a real colleague bug**: a plain `-l` `command -v claude`
  silently MISSES an install whose PATH entry lives in `.zshrc` (the common `~/.local/bin/claude`
  case), so job 7 took `.skipNoClaude` and nothing registered — fixed by the absolute-candidate
  check. `registerMCPWithClaudeIfNeeded` then runs `claude mcp add` via an INTERACTIVE login shell
  using the RESOLVED ABSOLUTE path (so claude is found deterministically AND gets node/env to run),
  with a bounded timeout + stdin=/dev/null so a hung/interactive `.zshrc` can't wedge the deferred
  thread (`runLoginShell`/`loginShellStatus`/`shellQuote`). If `claude` is never installed, this is
  a silent no-op (the colleague can still register by hand; ONBOARDING.md documents the command).
  Wiring/Tests as in the ForkSetup bullet above (`planMCPRegister`, `claudeCandidatePaths`,
  `firstExecutablePath`; `mcpRegister*`, `claudeCandidates*`/`firstExecutable*`).

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

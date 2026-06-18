# Agent Dashboard — Layer 3 design spec (macOS panel)

> **Scope:** DESIGN ONLY. This document specifies the macOS Swift panel (Layer 3). No
> source is edited by this spec. Layers 1 (host render-tee) and 2 (read-only render-mirror
> surface mode) are **committed** on `ramon-fork` — see commits `6497b5451` (host render-tee
> `subscribe_render`) and `db96af6d9` (core render-mirror surface mode). Everything below is
> verified against the *actual current code* on `ramon-fork`, not the older plan.
>
> Supersedes the Layer-3 (§4) section of `.claude/plans/agent-dashboard-plan.md` where they
> disagree. Read the plan for the why-this-design narrative; read **this** for what to build.

---

## 0. What already exists (verified against code)

What Layer 3 builds on, confirmed by reading the tree:

- **C-ABI mirror flag — DONE.** `ghostty_surface_config_s` has `uint64_t session_id;` and
  `bool mirror;` (`include/ghostty.h` ~483–493). `mirror=true` + non-zero `session_id` + the
  `.client` backend (pty-host set) ⇒ a read-only render mirror. Zero-init callers get the safe
  default (`mirror=false`, normal attach/spawn).
- **Reading a real surface's session id — DONE.** `ghostty_surface_session_id(surface) -> u64`
  (`include/ghostty.h` ~1169; `src/apprt/embedded.zig` ~1641). WebMonitor already calls it from
  AppKit (`WebMonitorServer.swift` ~1967).
- **Core mirror role — DONE.** `src/termio/Client.zig` `Role = enum { attach, mirror }`. In
  `.mirror` it does `Hello` + `subscribe_render(session_id)`, consumes `grid_frame`/`mode_frame`
  into the same `RenderState` the renderer reads, suppresses all session-mutating outbound
  frames, and on host-forwarded child-exit calls **`markMirrorEnded`** → posts a *synthetic*
  `child_exited` `apprt.surface.Message` (it does **not** self-close; `mirror_ended` is a
  fire-once flag). So a mirror SurfaceView's "session ended" reaches Swift through the **normal
  `childExited` path**, no new signal needed for the *ended* case.
- **`apprt/embedded.zig`** carries `mirror` through `Surface.Options` → `Surface.Config`
  (~428–435, ~480–515). `Surface.zig` constructs the mirror backend respecting the post-move
  mirror/mutex wiring.

What Layer 3 must still wire on the **Swift** side (verified absent today):

- `SurfaceConfiguration.withCValue` (`SurfaceView.swift` ~695–771) forwards `config.session_id`
  but **does NOT set `config.mirror`** and `SurfaceConfiguration` has **no `mirror` property**.
  → Layer 3 adds both.
- `Ghostty.Surface` exposes `foregroundPID` and `ttyName` (`Ghostty.Surface.swift` ~97–107) but
  **no `sessionID` getter**. → Layer 3 adds `var sessionID: UInt64 { ghostty_surface_session_id(surface) }`.
- **No per-frame activity signal reaches Swift — verified.** The `@Published` fields on the
  macOS `SurfaceView` (`SurfaceView_AppKit.swift` ~13–157: title/bell/cursor/pointer/background/
  derivedConfig/inspector) are EACH driven by a specific apprt *action* callback — there is **no**
  per-frame / draw-applied callback. The renderer draws on its own thread via Metal (no Swift
  round-trip per frame); core's per-applied-frame `notify()` (`src/termio/Client.zig` ~1062 for
  the mirror's `grid_frame` arm, ~993 for the ended arm) only `notify()`s the **renderer wakeup**
  eventfd — it does **not** post a surface message to Swift. So an output-driven, Swift-visible
  activity tick is **NOT** free: it would require a NEW core→apprt action plumbed through
  `include/ghostty.h` + `src/apprt/embedded.zig` + the action callback in `Ghostty.App.swift`
  (a `src/` change). This is the single scoping fork in the design — see §4.4, which presents the
  GUI-only default (no tick) and the opt-in tick (with its src/ cost) explicitly.

Integration points confirmed present and reused as-is:

- **Global enumeration:** `for c in TerminalController.all { for view in c.surfaceTree where … }`
  — exactly WebMonitor's pattern (`WebMonitorServer.swift` ~1150, ~1217). `surfaceTree` is the
  `@Published var surfaceTree: SplitTree<Ghostty.SurfaceView>` on `BaseTerminalController` (~44),
  `SplitTree: Sequence` over leaf `SurfaceView`s with stable `.id: UUID` (Identifiable).
- **Bell:** per-surface `@Published private(set) var bell: Bool` (`SurfaceView_AppKit.swift`
  ~106). Aggregated live via `BaseTerminalController.surfaceValuesPublisher(valueKeyPath:\.bell,
  publisherKeyPath:\.$bell)` → `AnyPublisher<[SurfaceView.ID: Bool], Never>` (~1888), which
  `switchToLatest()`es over `$surfaceTree` so it auto-tracks tree changes.
- **Click-to-focus:** post `Notification.ghosttyPresentTerminal` with the **real** target
  `SurfaceView`; `BaseTerminalController.ghosttyDidPresentTerminal` (~897–911) raises the window
  (`makeKeyAndOrderFront`), runs `moveFocus(to:)` immediately + again at `delay: 0.1`, and
  `highlight()`-flashes. The tab is selected implicitly because the controller *is* the
  window/tab that owns the surface.
- **Zoom:** `SplitTree.zoomed: Node?`, `zoomedLeaves() -> [ViewType]` (`SplitTree.swift`
  ~1372). The zoom is cleared **non-destructively** by `tree = SplitTree(root: tree.root,
  zoomed: nil)` — `root` (and thus all ratios) is untouched. **WebMonitor already ships exactly
  the helper we need** as `revealIfZoomedAway(_:_:)` (`WebMonitorServer.swift` ~1167–1173):
  `guard tree.zoomed != nil; if tree.zoomedLeaves().contains(where: {$0.id == view.id}) {
  return }; controller.surfaceTree = .init(root: tree.root, zoomed: nil)`. Layer 3's
  `unzoomIfHidden` is the same logic, lifted to `BaseTerminalController`.
- **Action wiring template:** `toggle_project_selector` is the exact precedent — payload-less
  enum in `src/input/Binding.zig` (~917, ~1574), command-palette entry in `src/input/command.zig`
  (~571), action enum in `src/apprt/action.zig` (~379, ~460), dispatched in `Ghostty.App.swift`
  `action(...)` switch (~633) to a `private static func` handler (~1157) that posts a
  Notification with the target `SurfaceView`.
- **Floating panel template:** `QuickTerminalWindow: NSPanel` (`QuickTerminalWindow.swift`):
  `canBecomeKey=true`, `canBecomeMain=true`, `.setAccessibilitySubrole(.floatingWindow)`,
  `styleMask.insert(.nonactivatingPanel)`, the `initialFrame` zero-size-corruption guard.
- **AppDelegate lifecycle template:** WebMonitor — `private var webMonitor: WebMonitorServer?`
  started in `applicationDidFinishLaunching` (~243) and torn down in `applicationWillTerminate`
  (~459). The dashboard controller is owned the same way.
- **RepeatableString C plumbing:** `project-directory: RepeatableString` (`Config.zig` ~2908)
  with `RepeatableString.cval()`/`list_c` (~6100–6166) returns `ghostty_config_string_list_s`;
  Swift reads it via `ghostty_config_get(config, &v, key, len)` → `UnsafeBufferPointer(start:
  v.items, count: Int(v.len))` (`Ghostty.Config.swift` `projectDirectories` ~806–814). Reuse
  verbatim for `agent-dashboard-commands`.
- **pbxproj iOS exclusion:** macOS-only files are listed in the
  `PBXFileSystemSynchronizedBuildFileExceptionSet` at `project.pbxproj` ~116–284 (e.g.
  `Features/WebMonitor/WebMonitorServer.swift`, `Features/Command Palette/ProjectPalette.swift`).
  New `Features/AgentDashboard/*.swift` go in the same list.

---

## 1. The panel

### 1.1 Window class — `AgentDashboardPanel: NSPanel`

Model on `QuickTerminalWindow` but **floating and persistent** (the quick terminal hides on
resign-key; the dashboard does not). In `awakeFromNib()`/`init`:

```
override var canBecomeKey: Bool  { true }   // tiles must accept clicks
override var canBecomeMain: Bool { false }  // never the "main" window; it's an overlay
styleMask = [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow, .fullSizeContentView]
isFloatingPanel = true
hidesOnDeactivate = false            // STAYS visible when another app is frontmost ("lock to foreground")
level = .floating                    // above terminal windows; below modal alerts
collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]  // visible on every Space + alongside fullscreen terminals
setAccessibilitySubrole(.floatingWindow)
identifier = .init(rawValue: "com.mitchellh.ghostty.agentDashboard")
titlebarAppearsTransparent = true; titleVisibility = .hidden
```

Rationale, opinionated:
- **`.nonactivatingPanel`** so clicking a tile does **not** steal app activation away from the
  agent's own terminal window when we then `ghosttyPresentTerminal` it — the present flow itself
  raises the right window. Clicking the dashboard should feel like a remote control, not a
  context switch *to the dashboard*.
- **`.canJoinAllSpaces`** is the decisive ultrawide ergonomic: the dashboard is a glanceable
  status surface; it should be on whatever Space you're looking at. (Quick terminal deliberately
  does the opposite.)
- **`hidesOnDeactivate=false` + `level=.floating`** = "locked to foreground" without being
  intrusive `.modalPanel`/`.statusBar` levels.
- **`canBecomeMain=false`**: an overlay should never become the app's main window (would confuse
  window-cycling and the "new window/tab inherits from main" logic).

### 1.2 Controller — `AgentDashboardController: NSWindowController` + the model

One app-wide singleton, owned by `AppDelegate` (`private var agentDashboard: AgentDashboardController?`),
**independent of any terminal window** — it must survive when every terminal window closes and
re-populate when one opens. It owns:
- the `AgentDashboardPanel` and a SwiftUI `NSHostingView` of `AgentDashboardView(model:)`;
- the `AgentDashboardModel` (`@MainActor ObservableObject`, the single source of truth);
- the `AgentDetector` (off-main poller, §5).

`toggle()` shows/hides: first show **creates** the panel (frame is restored *automatically* by
`setFrameAutosaveName` at window creation — see §1.4 — so `toggle()` does **NOT** call
`restoreFrame`/`setFrame` itself; an explicit restore would fight the autosave and is omitted on
purpose); subsequent `toggle()` flips visibility via `orderOut(nil)` / `orderFrontRegardless()`
(`orderFrontRegardless` because `.nonactivatingPanel` should not require app activation to
appear). The only frame work `toggle()` does is supply the **first-run default frame** (§1.4)
*before* assigning the autosave name, so a never-seen-before panel opens in the right place; once
autosave has a stored frame, that wins. **Critically, hide/show gates the mirror surfaces (§8)**
so previews cost ~nothing while hidden.

### 1.3 The model: tracking `TerminalController.all` + every `$surfaceTree`

`TerminalController.all` is a plain static array with no change publisher, and each controller's
tree is its own `@Published`. So the model needs a composite observation:

- **Tab/window churn (controllers added/removed):** there is no `TerminalController.all` Combine
  publisher today. Two acceptable options — pick **(b)**:
  - (a) a `Timer`-driven coalesced rescan (cheap; the same ~poll the detector already runs).
  - **(b) [recommended] hook the existing app-level notifications.** New terminal windows/tabs
    post through the standard AppKit `NSWindow.didBecomeKey`/`willClose` and Ghostty already
    fires surface-tree changes. Subscribe to `NSWindow.willCloseNotification` +
    `didBecomeMainNotification` *and* a lightweight rescan on `terminalWindowBellDidChangeNotification`
    (`SplitTree.swift` ~1934, already broadcast app-wide on any bell). On each, call
    `rebuildControllerObservers()`.
- **Split churn within a controller (`$surfaceTree` replaced):** for each live controller, the
  model keeps a `surfaceValuesPublisher(\.bell, \.$bell)` subscription (auto-tracks the tree via
  `switchToLatest`) **and** a direct `controller.$surfaceTree` sink to learn the leaf set. Merge
  all controllers' bell dictionaries into one `[UUID: Bool]`.
- **The model's derived state per tick:**
  `entries: [AgentEntry]` where `AgentEntry` is a value type:
  `{ id: UUID, weak realView, controllerRef, title, pwd, agent: AgentKind?, bell: Bool,
  hidden: Bool, sessionID: UInt64, endedAt: Date? }`. The model never holds a `ghostty_surface_t`
  across threads (see §8); the `weak realView` is only dereferenced on main.

`rebuild()` is the one reconciler: walk `TerminalController.all → surfaceTree` (the WebMonitor
pattern), join with the latest detector results (§5) keyed by `UUID`, the bell dictionary, and
the hide set; produce the sorted `entries` (§2.5). It diffs against the previous entry set so
**mirror SurfaceViews are created/destroyed incrementally** (don't tear down a live mirror just
because an unrelated tab opened).

### 1.4 Position/size persistence — fork bundle-id defaults domain

The fork already runs under its own bundle id (`com.mitchellh.ghostty-ramon` / `.local` /
`.debug`), so `UserDefaults.standard` is automatically the per-identity domain — no manual
suite. Use `NSWindow.setFrameAutosaveName("com.mitchellh.ghostty.agentDashboard")` (free,
correct, multi-monitor-aware) as the **sole** frame-persistence mechanism; that's strictly better
than hand-rolling frame keys. **Ordering that avoids the autosave-vs-restore conflict:** at panel
creation, (1) set the default first-run frame with `setFrame(_:display:)`, THEN (2) call
`setFrameAutosaveName(...)`. AppKit applies a previously-autosaved frame *at the moment the
autosave name is assigned* if one exists, so step 2 overrides step 1 on every run after the first,
and step 1 only takes effect the very first time (when no autosaved frame exists). Do **not** also
call `restoreFrame`/read the frame back manually anywhere — that would double-apply and fight the
autosave (this is the §1.2 caveat). Default first-run frame: top-right quadrant of the widest
screen, ~40% width × full height (tuned for ultrawide — see §2.1). Persist *visibility* (not the
frame) under a single bool default `agentDashboardWasVisible` so "remembered toggle" (§6) can
restore the open/closed state on launch.

---

## 2. Tile anatomy + ultrawide layout

### 2.1 Layout: grid, not list — and why

**Recommendation: a wrapping grid (`LazyVGrid`), column count derived from panel width**, not a
single vertical list.

Justification for the ultrawide target:
- On a 49"/32:9 monitor a vertical list wastes ~80% of horizontal space and forces tiny tiles or
  heavy scrolling. A terminal preview's information density lives in its *width* (long lines, TUI
  layouts); a narrow list column truncates exactly the content you're trying to glance at.
- A grid lets us show **4–6 readable previews at once** across the panel's width and grow rows
  downward only as agent count exceeds a row.
- Column count: `max(1, floor(panelContentWidth / targetTileWidth))` with
  `targetTileWidth ≈ 360pt` (≈ wide enough for ~100 cols at preview scale). `LazyVGrid` with
  `[GridItem(.adaptive(minimum: 320, maximum: 480), spacing: 12)]` gives this for free and
  reflows on panel resize. Vertical scroll only when rows overflow.
- A user with a non-ultrawide secondary use still gets a sensible 1–2 column layout from the
  same adaptive grid — no separate code path.

### 2.2 Tile sizing + the embedded live mirror

Each tile is a fixed aspect-ratio card (recommend **4:3**, terminal-ish and dense) containing,
top to bottom:
1. **Header row** (compact, ~22pt): agent badge (§2.4) · title (truncating middle) · bell dot ·
   hide button (✕, appears on hover, see §3).
2. **Live preview** — the mirror, filling the rest of the card.
3. **Footer** (optional, ~16pt, dim): cwd basename (`pwd`), small "ringing" / "ended" pill.

**Embedding the mirror SurfaceView.** Reuse the existing SwiftUI `Ghostty.Surface` representable
(`SurfaceView.swift` ~595–625, `makeOSView` wraps the view in a `SurfaceScrollView` on macOS).
The tile owns a `Ghostty.SurfaceView` built from a `SurfaceConfiguration` with the **new
`mirror = true`** flag and the source split's session id.

> **⚠️ Two same-named members, two different types — spell the round-trip out.** The session id
> exists in two places with DIFFERENT types and they must not be confused:
> - `Ghostty.Surface.sessionID` — the **`UInt64`** getter Layer 3 adds (`{ ghostty_surface_session_id(surface) }`, §7), read off the *real* surface.
> - `SurfaceConfiguration.sessionID` — an existing **`String?`** (it's `Codable`; `withCValue` parses it back to a `u64` at `SurfaceView.swift` ~733, e.g. `UInt64(self.sessionID ?? "")`).
>
> So populating the mirror config is **`config.sessionID = String(realView.surface.sessionID)`** —
> a `UInt64` → `String` on the way in, `String` → `u64` on the way out inside `withCValue`. The
> tile must NOT assign the `UInt64` directly to the `String?` field (won't compile) nor assume the
> two `sessionID`s are the same type. (The model's `AgentEntry.sessionID` in §1.3 is the `UInt64`
> form, captured once on main; the `String` only ever appears at the config boundary.)

This view renders natively through Ghostty's renderer (full color, viewport-only — exactly right
for a thumbnail).

**Scaling — aspect-fit, bottom-anchored.** The mirror renders at the *host's authoritative grid*
(the real split's cols×rows); the mirror backend never drives resize, so the preview must be
*displayed scaled*, not re-gridded:
- Wrap the mirror in a container; apply `scaleEffect(s, anchor: .bottom)` where
  `s = min(tileContentWidth / mirrorPixelWidth, …)` computed from the mirror's reported
  `ghostty_surface_size` (cols/rows × cell size). **Aspect-fit by width**, then **anchor to the
  bottom** so the most recent rows (the agent's latest output + prompt) are always visible; clip
  the top. This realizes "emphasize the last lines" without re-gridding the session.
- Disable hit-testing on the scaled mirror (`allowsHitTesting(false)`): the tile, not the mirror,
  receives the click (the mirror is read-only and clicking it would do nothing useful; we want
  the whole card to be the jump target). This also avoids the mirror trying to take first
  responder inside a `.nonactivatingPanel`.
- **Do not** call `term.resize`/drive any size message toward the mirror — it's read-only by
  construction (the core suppresses outbound resize), and the SwiftUI `updateOSView` path's
  size-sync is harmless because the mirror ignores it on the wire. Still, prefer feeding the
  representable the *mirror's own* pixel size so SwiftUI's letterboxing is a no-op and our
  `scaleEffect` is the only transform.

### 2.3 Bell frame (needs-input highlight)

Reuse the existing **amber bell look**. The codebase's bell amber is `Color(red: 1.0, green: 0.8,
blue: 0.0)` (the `bell.badge` glyph, `TerminalView.swift` ~169) and the marked-pane inset is
`Color.orange, lineWidth: 3` (`TerminalSplitTreeView.swift` ~136). For semantic consistency the
tile draws, when `entry.bell == true`:
- a **3pt amber rounded border** (`RoundedRectangle.strokeBorder(bellAmber, lineWidth: 3)`)
  matching the in-terminal bell-border feel, **distinct from** the orange marked-pane inset
  (different hue + it's a full perimeter, not an inset), and
- a small amber `bell.badge.fill` glyph + "needs input" label in the footer.

Bell is reactive (from the merged `[UUID: Bool]`); it clears the normal way when the user (or
the dashboard's future inline-reply) services the surface — the tile follows automatically.

### 2.4 Agent badge

A small leading pill showing the detected agent: **`claude`** (use a consistent accent, e.g. the
fork's chalkboard-era amber-free neutral; do not collide with the bell amber) or **`codex`**.
Source is `entry.agent: AgentKind` from the detector (§5). If detection is mid-flight (first poll
not yet returned) show a neutral "•" placeholder rather than flicker the tile in/out.

### 2.5 Sort order — bell-first, then activity

Deterministic, opinionated:
1. **Ringing (bell) tiles first** — they need you. (Exact + reactive in both build variants.)
2. then **most-recently-active** descending — the agent doing something now is more interesting
   than an idle one. **The precision of this key depends on the §4.4 variant:** in the default
   GUI-only variant (b) "active" is the coarse ~2s detector heuristic (still-alive / foregroundPID
   churn); in the opt-in variant (a) it's the per-frame `activityTick`. Either way bell outranks
   it absolutely, so the dashboard's *correctness* never depends on this key.
3. tie-break by **stable UUID** so tiles don't jitter on equal keys.

Within a row the grid lays out in this order, so a newly-ringing agent visibly jumps to the
top-left. Animate reorders with a short `.animation(.easeInOut(duration: 0.18), value: order)` so
the jump reads as motion, not a flash.

### 2.6 Empty / edge / degraded states — never a silent blank

The panel must always say *something*. The view renders one of:
- **No terminal windows at all** → "No terminals open." + hint.
- **Terminals open, zero agents detected** → "No CLI agents running." + the configured command
  set ("Watching for: claude, codex") + a hint that detection polls every ~2s. This is the most
  common non-trivial empty state; make it reassuring, not alarming.
- **pty-host is OFF** (`config.ptyHost == nil`) → mirrors are impossible. Show a one-time banner:
  "Live previews require pty-host. Set `pty-host` in your config to enable mini-previews." and
  **fall back to a metadata-only tile** per agent (badge + title + pwd + bell frame + jump),
  driven purely by the detector + bell publisher. The dashboard is still useful (bell + jump)
  without previews — this is the key graceful-degradation decision.
- **A specific mirror can't start** (subscribe_render fails / host doesn't speak it / session
  gone at construction) → that tile shows a dim "Preview unavailable" placeholder *but keeps* the
  badge/title/bell/jump affordances. Never a blank rectangle.
- **Session ended** — **REMOVED (Layer 3 fix, locked decision).** The "ended" tile state (dim +
  frozen preview + "ended" pill) was DEAD in production: a tile is built only while the detector
  reports the agent live, so when a claude/codex process exits the next ~2s detector poll returns
  nil and the tile is removed *before* any ended state could show. Finished agents now simply
  VANISH on the next reconcile (the detector dropping the id removes the tile). The endedAt field,
  the "ended" pill, and the frozen-on-ended preview branch were removed; no dangling refs remain.
- **All agents hidden** → collapse to the "N hidden" affordance only (§4.3).

---

## 3. Interaction

### 3.1 Click → jump (present + unzoom)

Clicking anywhere on a tile card (not the hide button):
1. Resolve the **real** `SurfaceView` from `entry` on main (it's a weak ref; if nil — closed
   meanwhile — no-op + drop the tile).
2. Find its owning controller via the WebMonitor pattern (`for c in TerminalController.all { if
   c.surfaceTree.contains(view) … }`).
3. **Unzoom-if-hidden** *before* presenting (see §3.2).
4. Post `Notification.ghosttyPresentTerminal` with the **real** `SurfaceView` (NOT the mirror).
   `ghosttyDidPresentTerminal` (~897) raises the window, selects the tab, `moveFocus`es twice
   (immediate + `delay:0.1`), and `highlight()`-flashes. We get the locate-pane flash for free —
   intentional, it helps you find the jumped-to split on a busy ultrawide.

The dashboard panel stays up (it's floating + non-activating), so you can fire several jumps in a
row, or jump → service → glance back.

### 3.2 `unzoomIfHidden(_:)` on `BaseTerminalController`

WebMonitor already proves the transform (`revealIfZoomedAway`, ~1167). Lift it to
`BaseTerminalController` as a reusable method so both features share it (refactor WebMonitor to
call it too, or duplicate — duplicating is fine and lower-risk; recommend a shared method):

```swift
/// If `target` is hidden because this tab is split-zoomed to a DIFFERENT split,
/// clear the zoom so the split re-mounts and can take focus. Ratio-preserving:
/// rebuilds the tree from the SAME `root`, only dropping `zoomed`. No-op when the
/// tab isn't zoomed or `target` is itself (in) the zoomed subtree. MUST be on main.
func unzoomIfHidden(_ target: Ghostty.SurfaceView) {
    let tree = surfaceTree
    guard tree.zoomed != nil else { return }
    guard !tree.zoomedLeaves().contains(where: { $0.id == target.id }) else { return }
    surfaceTree = .init(root: tree.root, zoomed: nil)
}
```

Detection of "hidden under zoom" is exactly: `tree.zoomed != nil && !tree.zoomedLeaves()
.contains(target)`. Clearing is the same `SplitTree(root:zoomed:)` reset the zoom toggle uses —
**ratios are preserved because `root` is untouched** (verified: `ghosttyDidToggleSplitZoom`
~843–845 and the navigation path ~827 both clear zoom this exact way). Because the present
handler already re-`moveFocus`es at `delay:0.1`, focus lands correctly after the tree settles —
no extra delay needed. Call `unzoomIfHidden` from the dashboard click handler *before* posting
`ghosttyPresentTerminal` (so the split is in the hierarchy when focus arrives); optionally also
have `ghosttyDidPresentTerminal` call it defensively (idempotent).

### 3.3 Hover / selection affordances

- **Hover** raises the tile slightly (`shadow` + 1pt border highlight) and reveals the hide ✕ in
  the header. Cursor → pointing hand over the card.
- The card has an accessible label "Jump to {agent} — {title}" for VoiceOver.
- No multi-select; one click = one jump. Keep it dead simple.
- Right-click (or the ✕) menu: "Hide", "Reveal in Terminal" (= jump), and (future) "Send Enter".

---

## 4. Hide / auto-unhide

### 4.1 The hide set

`AgentDashboardModel.hidden: Set<UUID>`, **in-memory only** (recommended — do **not** persist).
Rationale: hiding is a *"not right now"* gesture; persisting it across launches risks a silently
missing agent (a real footgun for a needs-input dashboard). Each launch starts with everyone
visible. (If a user later wants persistence, it's a one-line `UserDefaults` add — call it out as
an open question, §9.)

A hidden tile is removed from the grid. Hiding never touches the real split or the mirror's
liveness decision *per se*, but the model **may pause that tile's mirror** while hidden to save a
renderer (§8) — the auto-unhide triggers below must therefore not depend on the mirror rendering.

### 4.2 Auto-unhide triggers (exact)

A hidden id is removed from `hidden` (unhidden) when **either**:
- **(A) Bell** — `bell[id]` transitions to `true` (from the merged bell publisher). An agent
  asking for input must never stay hidden. This works regardless of mirror state, because the bell
  publisher reads the *real* surface's `$bell`, independent of any mirror. **This is the guaranteed
  trigger in both build variants below.**
- **(B) New output / activity** — the agent produced output since it was hidden. Whether this is
  available depends on the **activity-tick decision in §4.4**, which has two build variants:
  - **GUI-only default (no tick):** there is NO cheap output signal (a hidden tile's mirror is
    paused, and even an *un*paused mirror exposes no Swift-visible per-frame counter without a
    `src/` callback — see §4.4 / §0). So in this variant a hidden tile auto-unhides on **bell
    only**, plus it reappears on the **next panel-open `rebuild()`** if it's still a live agent.
    Output-while-hidden does NOT pop it back. This is the **default contract** because it keeps
    Layer 3 truly GUI-only and is honest about the cost model.
  - **Opt-in tick variant (adds a small `src/` callback):** if the per-frame apprt callback in
    §4.4(a) is built, a hidden tile whose *real* surface emits output (the callback fires on the
    real surface, NOT the paused mirror — see §4.4) unhides immediately on the next frame. This
    gives full output-driven auto-unhide at the cost of a small, additive core change.

The two variants are reconciled with §9.1 (the open question): pick **GUI-only/bell-only** unless
the human explicitly wants output-while-hidden, in which case build the §4.4(a) callback.

No snapshot diffing anywhere — the bell publisher (always) and, in the opt-in variant, the
frame-driven callback *are* the signals.

### 4.3 Collapsed "N hidden" affordance

A persistent, compact footer chip in the panel: "**N hidden**" with a chevron. Clicking it
expands a small popover list (badge · title · "Show") so a user can manually un-hide a specific
agent, or "Show all". When `N == 0` the chip is absent. This guarantees hiding is never a
one-way trapdoor.

### 4.4 The activity signal — scoping decision (the one place Layer 3 forks)

**Hard fact (verified, §0):** there is **no** existing per-frame Swift-visible signal on the
macOS `SurfaceView`, and there is **no** existing draw/frame-applied Swift callback to "bump."
The renderer draws on its own Metal thread; core's per-applied-frame work
(`src/termio/Client.zig` ~1062 mirror `grid_frame` arm, ~993 ended arm) only `notify()`s the
**renderer wakeup eventfd** — it never posts a surface message to Swift. So an output-driven,
Swift-visible activity tick is **not** a "tiny GUI-only" add; it needs a real `src/` plumbing.
The earlier draft's "bump the existing frame-applied callback" was wrong — no such callback
exists. Two honest variants, pick per §9.1:

**Variant (b) — DEFAULT: GUI-only, NO output tick.** Do not add any activity signal. Drive:
- **Sort order (§2.5):** by *bell-first*, then *most-recently-seen-as-an-agent* from the detector
  poll (a coarse "still alive + foregroundPID churn" heuristic at the ~2s cadence), then UUID.
  This is coarser than per-frame "most-recently-active" but needs zero `src/` change and is
  perfectly adequate for a glanceable dashboard (sub-2s reorder precision is invisible at a
  glance; bell — the signal that actually matters — is exact and reactive).
- **Auto-unhide (§4.2):** **bell-only** while hidden, plus reappear on the next panel-open
  `rebuild()` if still a live agent.
- This keeps the §7 manifest **GUI-only plus the config/action keys** (no `src/termio`/`src/host`/
  per-frame callback) — the framing in §7's footnote holds *for this variant*.

**Variant (a) — OPT-IN: real per-frame apprt callback (adds a small, additive `src/` change).**
If the human wants output-driven sort + output-while-hidden auto-unhide (§9.1), add a minimal
core→apprt action:
- **Core:** in `src/termio/Client.zig`, after the mirror's `grid_frame` apply (~1062) — gate it so
  it fires **only for mirror role** and is coalesced (e.g. at most once per ~100ms via a simple
  monotonic-clock check, so a busy agent doesn't flood the mailbox) — push a new lightweight
  surface message / call a new apprt action `surface_activity` (no payload, or a `u64` monotonic
  counter). Reuse the existing `surface_mailbox` the child_exited path already uses, so no new
  channel.
- **apprt + header:** add the action to `src/apprt/action.zig` + `include/ghostty.h`
  (additive, last) and route it in `src/apprt/embedded.zig`'s `performAction` like the other
  per-surface actions.
- **Swift:** add `@Published private(set) var activityTick: UInt64 = 0` on `SurfaceView`
  (`SurfaceView_AppKit.swift`) bumped from the new action case in `Ghostty.App.swift`/the surface
  action handler. **Crucially, fire it from the REAL surface, not (only) the mirror** — if it only
  fired on the mirror it would be dead while the mirror is paused (panel hidden / hidden tile),
  exactly when output-while-hidden auto-unhide needs it. Bumping on the *real* surface's frames
  costs every surface a coalesced `@Published` bump; gate/coalesce so the hot path stays cheap.
  (If you instead bump on the *mirror* only, accept that the tick is dead while paused — which
  collapses variant (a) back toward (b)'s contract; that defeats the point, so bump the real one.)
- **Cost honesty:** firing on every real surface's frames touches the common path. The ~100ms
  coalesce keeps it to ≤10 mailbox pushes/sec/surface; acceptable but NOT free, and it means Layer
  3 **drops the strict "GUI-only" claim** and adds `src/termio/Client.zig`, `src/apprt/action.zig`,
  `src/apprt/embedded.zig`, `include/ghostty.h` to the touched-Zig list (§7 lists these under the
  variant-(a) sub-block).

**Recommendation: ship variant (b).** Bell is the signal that matters and it's exact; output-driven
nicety isn't worth a common-path callback. Revisit (a) only if the human (§9.1) wants
output-while-hidden unhide or sub-2s activity sort. Whichever is chosen, the tick (if built) is
monotonic + coalesced and must never allocate or log per frame.

---

## 5. Agent detection

### 5.1 The libproc walk (`AgentDetector.swift`)

For each real `SurfaceView` with a `foregroundPID` (`Ghostty.Surface.foregroundPID`,
`Ghostty.Surface.swift` ~97), determine whether an agent is running:
- Start at `foregroundPID`; if its `proc_name` basename is in the configured command set
  (default `["claude","codex"]`) → match.
- Else **walk the process subtree**: `proc_listchildren(pid, …)` → for each child `proc_name`
  basename test, recurse (bounded depth, e.g. 4, and a visited cap to defend against cycles/huge
  trees). The shell is usually `foregroundPID`; the agent is a child (`node`/`python`/a wrapper
  exec'ing `claude`), so the subtree walk is the reliable discriminator.
- `proc_pidinfo`/`proc_pidpath` give the exe path if `proc_name` is truncated (it's capped at
  `MAXCOMLEN`); prefer the path basename when available.
- **Fallbacks (weak, last resort):** title-substring match (some agents set OSC 0/2 titles), and
  `ttyName` correlation (`Ghostty.Surface.ttyName` ~105) only if needed to disambiguate. Title
  match is explicitly a *fallback*, never the primary signal (titles are user/agent-spoofable and
  noisy).

The matcher is split into a **pure function** for testability:
```
func matchAgent(rootPID: pid_t, snapshot: ProcSnapshot, commands: Set<String>) -> AgentKind?
```
where `ProcSnapshot` is an injectable `[pid_t: (name: String, children: [pid_t])]`. The libproc
calls live behind a `ProcEnumerator` protocol so tests pass fixtures (§7).

### 5.2 Polling cadence + where it runs

- Poll every **~2s** on a **dedicated background queue** (`DispatchQueue(label:
  "agent-dashboard.detector", qos: .utility)`), never main. libproc is a syscall; cheap but not
  free, and the tree walk must not block UI.
- **`foregroundPID`/`ttyName` are read via `ghostty_surface_*`, which must be on main** (§8). So
  the cadence is: on main, snapshot `[(uuid, foregroundPID, ttyName, title)]` for all current
  leaves (the WebMonitor enumeration, value types only); hop to the detector queue to run the
  libproc walks + matching; hop back to main to publish `[UUID: AgentKind?]` into the model.
- **Cache per surface `UUID`** with a short TTL so a stable agent isn't re-walked every tick if
  its `foregroundPID` is unchanged; invalidate when `foregroundPID` changes or the surface
  disappears.
- **Pause polling while the panel is hidden** (the detector only matters when previews are shown;
  bell/jump still work via the always-live bell publisher). Resume on show.

### 5.3 Configurable command set

`agent-dashboard-commands` (`RepeatableString`, default `claude,codex`) → `Set<String>` of exe
basenames. Read once at controller start + on config reload (no live reload mid-run is fine;
match WebMonitor's "relaunch to change" stance, but config reload re-reading is cheap here).

---

## 6. Config + action

### 6.1 Fork-only config keys (`src/config/Config.zig` + `Ghostty.Config.swift`)

Both default-off / safe so an official Ghostty sharing `~/.config/ghostty/config` never trips —
keep them in `~/.config/ghostty-ramon/config`.

- **`agent-dashboard: bool = false`** — master enable + "open on launch" (recommended: a bool, not
  a remembered toggle, for the *config-driven* default). The runtime *visible* state is the
  remembered `agentDashboardWasVisible` default (§1.4). Semantics: if `agent-dashboard = true`,
  the panel is created at launch and shown if it was visible last time (or shown by default the
  first time); the toggle action then hides/shows it. If `false`, the feature is dormant until
  the toggle action is invoked (which lazily creates the controller). **Recommendation: ship the
  bool config key AND the remembered-visibility default** — config sets the "is this feature on
  at all / open by default" policy; the toggle + remembered bool handle session-to-session feel.
- **`agent-dashboard-commands: RepeatableString = claude,codex`** — exe basenames (§5.3). Reuse
  `project-directory`'s exact `RepeatableString` cval/`list_c` plumbing (`Config.zig` ~6100–6166)
  and the Swift `ghostty_config_string_list_s` read pattern (`Ghostty.Config.swift` ~806–814) →
  `var agentDashboardCommands: [String]`.
- **(Optional, recommend deferring)** `agent-dashboard-rows: u16` — bottom rows per tile. Start
  *without* it (the aspect-fit bottom-anchor already emphasizes the last lines); add only if the
  fixed 4:3 crop proves wrong. List as an open question (§9).

Each key needs a doc comment (fork-only note + "keep in ghostty-ramon/config") and a parse test
in `Config.zig`'s test block (mirror the `project-directory` / `RepeatableString cval` tests at
~6271).

### 6.2 The toggle action — `toggle_agent_dashboard` (payload-less)

Wire exactly like `toggle_project_selector`:
- `src/input/Binding.zig`: add `toggle_agent_dashboard` to the `Action` enum (near ~917) and the
  payload-less arm of the formatter/round-trip switch (near ~1574). Add a parse round-trip test
  (mirror `Binding toggle_project_selector` ~3704).
- `src/input/command.zig`: command-palette entry (mirror ~571):
  `{ .action = .toggle_agent_dashboard, .title = "Toggle Agent Dashboard", .description = "Show
  or hide the floating dashboard of running CLI agents." }`.
- `src/apprt/action.zig`: add `toggle_agent_dashboard` to the action enum (~379) and the
  no-payload set (~460). Regenerate/append `GHOSTTY_ACTION_TOGGLE_AGENT_DASHBOARD` in
  `include/ghostty.h` (additive, last).
- `macos/Sources/Ghostty/Ghostty.App.swift`: a `case GHOSTTY_ACTION_TOGGLE_AGENT_DASHBOARD:` in
  the `action(...)` switch (~633) → `toggleAgentDashboard(app, target:)`. The dashboard is
  app-global (not per-surface), so the handler **posts unconditionally** — on `GHOSTTY_TARGET_APP`
  *or* `GHOSTTY_TARGET_SURFACE` it just posts `Notification.ghosttyToggleAgentDashboard` (no target
  payload needed; the controller is app-wide). The `AppDelegate` (which owns the controller, like
  WebMonitor) observes it and calls `toggle()`.
  > **⚠️ This DIVERGES from the cited `toggleProjectSelector` template.** Use it only for the
  > *wiring shape* (switch case → `private static func` handler → post a Notification), **NOT** its
  > target handling: `toggleProjectSelector` (`Ghostty.App.swift` ~1157) **no-ops on the APP
  > target** (it logs a warning and returns, acting only on a SURFACE because the project palette
  > attaches to a focused surface). The dashboard is app-global, so its handler must instead handle
  > the APP target (the natural target for a payload-less app-wide toggle) — do NOT copy the
  > `guard ... TARGET_SURFACE` early-return. Simplest correct form: ignore the target tag entirely
  > and always post.
- Keep the keybind **fork-side**: e.g. `keybind = ctrl+a>d=toggle_agent_dashboard` in
  `~/.config/ghostty-ramon/config`. Verify `ctrl+a>d` is unbound in the fork config first (per
  the CLAUDE.md clobber warning — `d` is lower-case, no shift, so no `shift+` needed).

---

## 7. File manifest

### New macOS files — `macos/Sources/Features/AgentDashboard/`
- **`AgentDashboardPanel.swift`** — the `NSPanel` subclass (§1.1).
- **`AgentDashboardController.swift`** — `NSWindowController` + ownership + show/hide + frame
  autosave + mirror gating; the `AgentDashboardModel` (`ObservableObject`) and its reconciler.
- **`AgentDashboardView.swift`** — SwiftUI `LazyVGrid` of tiles + empty/degraded states + the
  "N hidden" chip/popover (§2.6, §4.3).
- **`AgentPreviewTile.swift`** — one tile: embedded mirror `Ghostty.Surface` (aspect-fit
  bottom-anchored), header (badge/title/hide), bell frame, footer, ended/unavailable states.
- **`AgentDetector.swift`** — `ProcEnumerator` protocol + libproc impl + the **pure**
  `matchAgent(rootPID:snapshot:commands:)` + the off-main poll loop + per-UUID cache.

### Touched macOS files
- **`macos/Sources/Ghostty/Surface View/SurfaceView.swift`** — add `var mirror: Bool = false` to
  `SurfaceConfiguration`; set `config.mirror = mirror` in `withCValue` (~733, beside the existing
  `config.session_id`).
- **`macos/Sources/Ghostty/Ghostty.Surface.swift`** — add `var sessionID: UInt64 {
  ghostty_surface_session_id(surface) }`.
- **`macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`** — ensure the synthetic
  `child_exited` (markMirrorEnded, already in core) routes to the existing `childExited` handling
  so the tile sees "ended" (no new field needed for this; it's the normal path per §0).
  **Variant (a) ONLY** (§4.4 opt-in): add `@Published private(set) var activityTick: UInt64 = 0`
  bumped from the new `surface_activity` action case. In the **default variant (b) this file needs
  no change at all** beyond confirming the ended path.
- **`macos/Sources/Ghostty/Ghostty.Config.swift`** — `agentDashboard: Bool` and
  `agentDashboardCommands: [String]` getters.
- **`macos/Sources/Ghostty/Ghostty.App.swift`** — `GHOSTTY_ACTION_TOGGLE_AGENT_DASHBOARD` case +
  `toggleAgentDashboard` handler (posts `ghosttyToggleAgentDashboard`).
- **`macos/Sources/App/macOS/AppDelegate.swift`** — own `agentDashboard:
  AgentDashboardController?`; create/restore in `applicationDidFinishLaunching` honoring
  `agent-dashboard` + remembered visibility; observe `ghosttyToggleAgentDashboard`; tear down in
  `applicationWillTerminate`.
- **`macos/Sources/Features/Terminal/BaseTerminalController.swift`** — add `unzoomIfHidden(_:)`
  (§3.2); optionally call it defensively from `ghosttyDidPresentTerminal`.
- **`macos/Ghostty.xcodeproj/project.pbxproj`** — add the 5 new
  `Features/AgentDashboard/*.swift` to the iOS `membershipExceptions` block (~116–284).

### Touched Zig / core files
- **`include/ghostty.h`** — append `GHOSTTY_ACTION_TOGGLE_AGENT_DASHBOARD` (additive, last).
- **`src/input/Binding.zig`** — `toggle_agent_dashboard` enum + arm + parse test.
- **`src/input/command.zig`** — command-palette entry.
- **`src/apprt/action.zig`** — action enum + no-payload set.
- **`src/config/Config.zig`** — `agent-dashboard` (bool) + `agent-dashboard-commands`
  (RepeatableString) + docs + parse tests.

#### Variant-(a)-ONLY additional touched Zig/core files (the opt-in activity tick, §4.4)
*Skip this whole block if shipping the recommended default variant (b).*
- **`src/termio/Client.zig`** — push a coalesced `surface_activity` surface message from the
  mirror/real `grid_frame` apply path (reuse `surface_mailbox`; ≥~100ms coalesce; gated).
- **`src/apprt/action.zig`** — add the `surface_activity` action to the enum + no-payload set.
- **`src/apprt/embedded.zig`** — route `surface_activity` in `performAction`.
- **`include/ghostty.h`** — append `GHOSTTY_ACTION_SURFACE_ACTIVITY` (additive, last).

> **Scope footnote — depends on the §4.4 variant:**
> - **Default variant (b):** No `src/host/*` or `src/termio/*` changes. Layer 3 is **GUI-only
>   plus** the small config/action keys (`agent-dashboard*`, `toggle_agent_dashboard`). Layers 1 &
>   2 already shipped the render-tee + mirror role, so Layer 3 ships with **no host restart** — the
>   deploy caveat that loses live sessions does not apply.
> - **Opt-in variant (a):** adds the four `src/`/header files listed just above (a per-frame apprt
>   callback). It is **NOT** "GUI-only" and touches the common surface frame path, but it is
>   purely additive (new action, zero-init-safe, no protocol/host change), so it **still needs no
>   host restart** (it's a GUI-lib rebuild, not a `ghostty-host` rebuild). Choose this only if
>   §9.1 calls for output-driven behavior.

### 7.x Test plan — what is gated in-agent vs. a manual live check

**A. Unit-testable IN-AGENT (these are the CI/gate tests — pure logic, no live app, no GPU).**

*Zig (`zig build test -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=<name>`):*
- **Config parse** (`-Dtest-filter=Config`): `agent-dashboard` bool round-trips (default `false`);
  `agent-dashboard-commands` `RepeatableString` parses `claude,codex` and defaults correctly —
  mirror the existing `project-directory` / `RepeatableString cval` tests (`Config.zig` ~6271).
- **Binding/action round-trip** (`-Dtest-filter=Binding`): `toggle_agent_dashboard` parses,
  formats, and round-trips as a payload-less action — mirror `Binding toggle_project_selector`
  (~3704). Assert it's in the no-payload set in `action.zig`.
- **Variant (a) only:** `surface_activity` action encode/format round-trip; a unit assertion that
  the coalesce gate suppresses a second push inside the window (if the coalescer is factored into a
  pure helper).

*Swift (`macos/build.nu --action test`, or `-only-testing:GhosttyTests/AgentDashboardTests`;
auto-discovered by the filesystem-synchronized `GhosttyTests` group — new dir
`macos/Tests/AgentDashboard/`):*
- **`AgentDetector` pure match logic** — `matchAgent(rootPID:snapshot:commands:)` over injected
  `ProcSnapshot` fixtures via the `ProcEnumerator` protocol: (1) direct hit (foregroundPID name in
  set); (2) child hit (shell → `node` → `claude`); (3) depth-bounded walk stops at the cap; (4)
  cycle/visited-cap defends against a self-referential tree; (5) basename-vs-path truncation
  (`MAXCOMLEN`) prefers the path basename; (6) no-match returns nil; (7) configurable command set
  (`{"codex"}` matches codex but not claude). **No libproc in the test** — fixtures only.
- **Hide / auto-unhide state machine** — drive `AgentDashboardModel`'s hide set with synthetic
  bell/rebuild events: hide adds the id; bell `false→true` removes it (variant (a): activity tick
  also removes it; variant (b): assert output does NOT remove it and a panel-open rebuild does);
  "Show all" clears; `N hidden` count derivation.
- **`unzoomIfHidden` decision** — over constructed `SplitTree`s (no AppKit window): (1)
  `zoomed == nil` → no-op; (2) target IS in `zoomedLeaves()` → no-op (preserve zoom); (3) target
  hidden under a zoom to a different split → tree rebuilt as `SplitTree(root:zoomed:nil)` with
  identical `root` (assert ratios/structure unchanged, only `zoomed` cleared). This is a pure
  transform — testable like the existing `SplitTreeTests`.
- **Bell-frame derivation** — given a merged `[UUID: Bool]` + entry set, assert which tiles get the
  amber frame and that sort puts bell tiles first (and the variant-(b) coarse secondary key /
  variant-(a) activityTick key behave + tie-break by UUID is stable).
- **Sort order** — deterministic ordering fixture (bell-first, then activity key, then UUID).

**B. Needs the LIVE app — MANUAL check, NOT a gate** (visual/GPU/click behavior; document as a
step, never block CI on it). On a ReleaseLocal build:
- A real `claude`/`codex` split shows a live, full-color, bottom-anchored mini-preview that
  updates as the agent works.
- Ringing the bell draws the amber frame + floats the tile to top-left.
- Clicking a tile jumps to the real split, raises its window, selects its tab, flashes the
  highlight; if that split was hidden under a split-zoom, the zoom clears and focus lands.
- Hide removes the tile; a subsequent bell brings it back; the "N hidden" chip works.
- Panel hidden ⇒ previews pause (Activity Monitor: no per-tile GPU/CPU while hidden).
- Degraded states render text, never a blank: 0 terminals, 0 agents, `pty-host` off
  (metadata-only tiles), a mirror that can't start ("Preview unavailable"), session-ended.
- The 4:3 crop reads well on the actual ultrawide (§9.3).

---

## 8. Threading / correctness

- **AppKit + `ghostty_surface_*` on main only.** `TerminalController.all`, `surfaceTree`,
  `SurfaceView`, `ghostty_surface_session_id`/`_foreground_pid`/`_tty_name`/`_size`, and all
  panel/SwiftUI work happen on main. The model is `@MainActor`.
- **Detection off main.** The libproc walk runs on `agent-dashboard.detector` (`.utility`). It
  receives **value types only** (uuid/pid/tty/title snapshot taken on main) and returns value
  types (`[UUID: AgentKind?]`) published back on main. Never pass a `SurfaceView`/
  `ghostty_surface_t` across the hop (the WebMonitor discipline).
- **Mirror lifecycle ↔ panel show/hide (cost control):** the renderer pauses when off-screen
  (`src/renderer/Thread.zig` gates on `visible`), and the host always emulates regardless. So:
  - **Panel hidden:** order the panel out → its mirror views are off-screen → renderers pause →
    near-zero preview cost. *Do not* destroy the mirror surfaces on hide (re-subscribe churn +
    flicker); just let them pause. Also **pause the detector poll** while hidden.
  - **Panel shown:** mirrors resume drawing the live grid (the host replays a seeded full frame
    on `subscribe_render`, so the first visible frame is current, not stale).
  - **Tile removed (agent gone / hidden-with-pause):** tear down that one mirror SurfaceView on
    main (idempotent), which drops its host `subscribe_render`. Removing a mirror never touches
    the real session (the mirror owns nothing — verified in Layer 2).
- **Bell publisher is independent of mirrors** — it reads real surfaces' `$bell`, so bell-driven
  auto-unhide and the bell frame work even when a tile's mirror is paused/absent (key to the §6
  pty-host-off fallback).
- **No new locks.** Reuse Combine + `@MainActor`. In the opt-in variant (a) the activity tick is a
  plain `@Published` bumped from the apprt action callback, which arrives on main like every other
  surface action (no cross-thread mutation); the coalescing happens in core before the message is
  pushed. In the default variant (b) there is no tick at all.
- **Weak refs only to views** in the model's entries; closed surfaces auto-drop (matches the
  mark/goto-last weak-ref pattern in `Ghostty.App`).

---

## 9. Open UX questions (need a human decision before implementation)

1. **Output-while-hidden auto-unhide (THE scoping decision — gates §4.4).** Should a *hidden* tile
   pop back on **new output** (not just bell)? This is the single fork in the whole design:
   - **Default — variant (b), recommended:** **bell-only while hidden** (+ reappear on next
     panel-open rebuild). Keeps Layer 3 **GUI-only** (no `src/` change), bell is the real "needs
     you" signal, and sort order falls back to the coarse ~2s detector heuristic. This is honest
     and adequate.
   - **Variant (a):** full output-driven auto-unhide + sub-2s activity sort, but it **requires a
     small additive `src/` per-frame apprt callback** on the *real* surface (NOT a "tiny GUI tick"
     — verified: no such Swift callback exists today; see §0/§4.4). It touches the common frame
     path (coalesced) and drops the strict "GUI-only" claim, though it still needs no host restart.

   **Decision needed:** ship (b) unless you specifically want output-while-hidden unhide /
   per-frame activity sort, in which case approve the §4.4(a) `src/` callback. Everything else in
   the spec is variant-agnostic; only §2.5/§4.2/§4.4/§7 branch on this answer.
2. **Persist the hide set across launches?** Recommended **no** (a needs-input dashboard should
   not silently start with someone hidden). Confirm.
3. **Tile shape + "last N rows."** Ship fixed 4:3 bottom-anchored aspect-fit, or add the optional
   `agent-dashboard-rows` knob now? Recommend defer the knob; confirm the 4:3 crop reads well on
   the user's actual ultrawide (a visual/manual check).
4. **Click target semantics on a *fullscreen* agent window.** Presenting raises + focuses the
   target window; if that window is in macOS fullscreen on another Space, the jump moves you to
   that Space. Acceptable (it's the point), but confirm the `.canJoinAllSpaces` dashboard +
   fullscreen interaction feels right vs. surprising.
5. **Should the dashboard show *all* terminals (not just agents) in a muted secondary section?**
   The spec is agent-only. A "show non-agent splits too" toggle could help, but risks clutter on
   ultrawide. Recommend agent-only v1; confirm.
6. **Inline reply (future).** The mirror is read-only by design; a future "send Enter / type"
   from a tile would forward `ghostty_surface_key` to the **real** surface (never the mirror,
   never a resize). Out of scope for Layer 3 — flag whether to leave hooks (e.g. the right-click
   "Send Enter") stubbed now.
7. **Keybind default.** `ctrl+a>d` proposed; confirm it's free in the user's fork config and not
   shadowed by a `repeatable:`/same-trigger clobber (per the CLAUDE.md trigger-identity warning).
8. **What "active" means for sort order** when an agent is streaming continuously (it would
   monopolize the top). Consider a short decay on the activity weight so a steadily-busy agent
   doesn't pin above a just-rang one — bell always outranks activity, but among non-bell tiles,
   confirm "most-recent-frame" vs. a decayed rate is the desired ordering.

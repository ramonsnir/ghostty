# Agent Dashboard — Layer 3 implementation plan (file-by-file)

> **Status:** IMPLEMENTATION plan, derived from `.claude/plans/agent-dashboard-layer3-spec.md`
> (gated/approved) under the **LOCKED HUMAN DECISIONS** below. Layers 1 (host render-tee) and 2
> (core render-mirror surface mode) are COMMITTED on `ramon-fork` (commits `6497b5451`,
> `db96af6d9`). This plan implements Layer 3 only. **Apply Zig/core first** (so the lib builds),
> **then Swift**, **then pbxproj**. The spec is the rationale; read this for what to type.
>
> All file/line pointers below were re-verified against the live `ramon-fork` tree.

## LOCKED HUMAN DECISIONS (override every "variant" branch in the spec)

1. **AUTO-UNHIDE = VARIANT (b), BELL-ONLY, FULLY GUI-ONLY.** No per-frame core/apprt activity
   callback. **No `src/termio/Client.zig`, `src/apprt/action.zig` `surface_activity`,
   `src/apprt/embedded.zig`, or `include/ghostty.h` activity entry, and no `activityTick` field on
   `SurfaceView`.** A hidden tile reappears on BELL (and the user can manually "Show"); the
   panel-open `rebuild()` re-evaluates the live agent set but never silently clears the hide set.
   Sort order = bell-first, then the coarse ~2s detector heuristic (still-alive / `foregroundPID`
   churn), then UUID. (Spec §2.5 variant-b, §4.2 bell-only, §4.4 variant-b, §7 default manifest.)
2. **PERSIST THE HIDE SET across launches** in the fork bundle-id `UserDefaults` domain. A hidden
   tile stays hidden across relaunch until a bell (or manual Show) unhides it. (Spec §4.1 — its
   "in-memory only" is OVERRIDDEN to persisted.)
3. **DEFER INLINE REPLY entirely.** Dashboard is READ-ONLY/view-only. No right-click "Send Enter"
   / key-forwarding stub anywhere. (Spec §9.6 — defer.)
4. **`ctrl+a>d`** for `toggle_agent_dashboard` (confirmed free); **agent-only** (no "show all
   terminals"); tile **fixed 4:3 bottom-anchored** (NO `agent-dashboard-rows` knob — deferred).
   Settled — do not re-litigate.

## NO ACTIVITY-TICK CORE CHANGE — explicit confirmation (variant b)

This plan adds **ZERO** per-frame / output-driven core or apprt plumbing. The spec's §4.4(a) /
§7 "Variant-(a)-ONLY additional touched Zig/core files" block is **NOT** implemented:
- NOT touched: `src/termio/Client.zig` (no coalesced `surface_activity` push).
- NOT added: a `surface_activity` action in `src/apprt/action.zig` / route in
  `src/apprt/embedded.zig` / `GHOSTTY_ACTION_SURFACE_ACTIVITY` in `include/ghostty.h`.
- NOT added: `@Published var activityTick` on `SurfaceView_AppKit.swift`.

The ONLY Zig/core changes in this plan are: the two fork-only **config keys** and the
**payload-less `toggle_agent_dashboard` action**. The "most-recently-active" sort key is the
detector's coarse ~2s liveness/`foregroundPID`-churn heuristic — pure Swift, no core signal.

---

## PHASE 1 — ZIG / CORE (apply first; lib must build before any Swift)

Order within the phase: A (config keys) → B (action wiring). Run the Phase-1 gate at the end.

### A. `src/config/Config.zig` — two fork-only config keys

Reuse `project-directory`'s exact `RepeatableString` cval/`list_c` plumbing (no new C type).
`project-directory: RepeatableString = .{}` is at **line 2908**; `RepeatableString.list_c` /
`cval()` plumbing is at **lines 6100–6166**.

**A1. Add the fields** adjacent to `project-directory` (line 2908) so the fork-only block stays
together. Use the documented fork-only doc-comment style:

```zig
/// (ramon fork) Master enable for the floating Agent Dashboard panel (macOS).
/// When true the panel is created at launch and shown per remembered visibility;
/// when false the feature is dormant until `toggle_agent_dashboard` is invoked.
/// Default false. Fork-only — keep it in `~/.config/ghostty-ramon/config` (an
/// official Ghostty sharing `~/.config/ghostty/config` would error on it).
@"agent-dashboard": bool = false,

/// (ramon fork) Executable basenames the Agent Dashboard treats as CLI agents.
/// Default `claude,codex`. Reuses the `project-directory` RepeatableString
/// plumbing. Fork-only — keep it in `~/.config/ghostty-ramon/config`.
@"agent-dashboard-commands": RepeatableString = .{},
```

> **Default-value note:** `RepeatableString` has no literal-list default. Two options — choose the
> **Swift-side default** (simpler; no allocator work in `default()`): the Zig field defaults to
> empty `.{}`, the parse test asserts an explicit `claude,codex` round-trips, and
> `Ghostty.Config.swift`'s `agentDashboardCommands` getter substitutes `["claude","codex"]` when
> the C list is empty (see C4). This keeps the Zig change to bare field + doc + one parse test.

**A2. Add a Config-level parse/round-trip test** in the `Config.zig` test block. **Do NOT clone a
`project-directory` parse test — none exists.** The only RepeatableString tests are the `cval`
tests at **lines 6271–6336**, which exercise the type in isolation, not a Config field. Use the
established **Config-level harness** at **lines 4031–4048** (`Config.default(alloc)` →
`loadReader(alloc, &reader, path)` → `finalize()` → assert field; `loadReader` is at line **4011**,
`default` at **3946**, `finalize` at **4609**). Model the new test on it:

```zig
test "agent-dashboard config" {
    const alloc = testing.allocator;
    // default
    {
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        try testing.expectEqual(false, cfg.@"agent-dashboard");
        try testing.expectEqual(@as(usize, 0), cfg.@"agent-dashboard-commands".list.items.len);
    }
    // explicit
    {
        const data =
            "agent-dashboard = true\n" ++
            "agent-dashboard-commands = claude\n" ++
            "agent-dashboard-commands = codex\n";
        var reader: std.Io.Reader = .fixed(data);
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        try cfg.loadReader(alloc, &reader, "/home/ghostty/.config/ghostty/config.ghostty");
        try cfg.finalize();
        try testing.expect(cfg._diagnostics.empty());
        try testing.expectEqual(true, cfg.@"agent-dashboard");
        try testing.expectEqual(@as(usize, 2), cfg.@"agent-dashboard-commands".list.items.len);
    }
}
```

> Confirm `RepeatableString`'s public field name (`list`) against the type decl (~line 6080) when
> writing the length assertion; if it differs, assert via `.list_c` / `.cval()` length instead. A
> 1-line adjustment, not a design choice.

### B. `toggle_agent_dashboard` action (payload-less) — wire exactly like `toggle_project_selector`

`toggle_project_selector` is the verified precedent at every site (same lines cited).

**B1. `src/input/Binding.zig`**
- Add `toggle_agent_dashboard,` to the `Action` enum — beside `toggle_project_selector` at **line
  917**.
- Add `toggle_agent_dashboard,` to the payload-less arm of the formatter/round-trip switch — beside
  `toggle_project_selector` at **line 1574**.
- Add a parse round-trip test modeled on `test "Binding toggle_project_selector"` (**lines
  3704–3717**, which does `parseSingle("a=toggle_project_selector")`, asserts the action, then
  formats + asserts `"toggle_project_selector"`):
  ```zig
  test "Binding toggle_agent_dashboard" {
      const binding = try parseSingle("a=toggle_agent_dashboard");
      try testing.expect(binding.action == .toggle_agent_dashboard);
      // mirror the format/round-trip asserts from the project_selector test
  }
  ```

**B2. `src/input/command.zig`**
- Add a command-palette entry modeled on the `.toggle_project_selector` arm at **lines 572–575**:
  ```zig
  .toggle_agent_dashboard => comptime &.{.{
      .action = .toggle_agent_dashboard,
      .title = "Toggle Agent Dashboard",
      .description = "Show or hide the floating dashboard of running CLI agents.",
  }},
  ```

**B3. `src/apprt/action.zig`**
- Add `toggle_agent_dashboard,` to the action enum — beside `toggle_project_selector` at **line
  379**.
- Add `toggle_agent_dashboard,` to the no-payload `Key` enum — beside `toggle_project_selector` at
  **line 460**. The `test "ghostty.h Action.Key"` at **line 463**
  (`checkGhosttyHEnum(Key, "GHOSTTY_ACTION_")`) enforces parity with `include/ghostty.h`, so B4
  MUST land in the same change or this test fails.

**B4. `include/ghostty.h`**
- Append `GHOSTTY_ACTION_TOGGLE_AGENT_DASHBOARD,` to `ghostty_action_tag_e`, **additive,
  immediately after** `GHOSTTY_ACTION_TOGGLE_PROJECT_SELECTOR,` (**line 1002**). The
  `checkGhosttyHEnum` test verifies the name matches the Zig field
  (`toggle_agent_dashboard` → `GHOSTTY_ACTION_TOGGLE_AGENT_DASHBOARD`).

### Phase-1 gate (run before starting Phase 2)
```sh
zig build -Demit-macos-app=false -Demit-xcframework=false                                 # lib + config compile
zig build test -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=Config       # config parse test
zig build test -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=Binding      # binding round-trip
zig build test -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=action       # checkGhosttyHEnum parity
zig build -Demit-macos-app=false -Doptimize=ReleaseFast                                    # rebuild lib for macOS build
```
(`-Dtest-filter` runs are fast → foreground. The two `zig build` lib compiles can approach the
watchdog → DE-RISK background+poll pattern.)

---

## PHASE 2 — macOS SWIFT (after the lib rebuilds clean)

### Order
1. **C2 + C3** (`mirror`/`sessionID` plumbing) — foundational; tiles depend on them.
2. **C4** (`Ghostty.Config.swift` getters).
3. **C5** (`Ghostty.App.swift` handler + action case).
4. **C6** (`BaseTerminalController.unzoomIfHidden`).
5. **C7** (new `Features/AgentDashboard/` group — 5 files).
6. **C8** (`AppDelegate` ownership + observer + the notification name in `GhosttyPackage.swift`).
7. **C9** (`project.pbxproj` iOS exclusion of the 5 new files).
8. **C10** (confirm `SurfaceView_AppKit.swift` needs NO change — variant b).

### C2. `macos/Sources/Ghostty/Surface View/SurfaceView.swift` — `mirror` on `SurfaceConfiguration`
- `SurfaceConfiguration` has `var sessionID: String?` at **line 661**; its `withCValue` parse at
  **line 733** is `config.session_id = sessionID.flatMap { UInt64($0) } ?? 0`.
- Add `var mirror: Bool = false` to `SurfaceConfiguration` (near `sessionID`, line 661).
- In `withCValue`, add **`config.mirror = mirror`** immediately beside `config.session_id` at
  **line 733**. (C-ABI `bool mirror;` exists at `include/ghostty.h` **line 493** from Layer 2.)

### C3. `macos/Sources/Ghostty/Ghostty.Surface.swift` — `UInt64 sessionID` getter
- Add (beside `foregroundPID`/`ttyName`, ~lines 97–107):
  ```swift
  var sessionID: UInt64 { ghostty_surface_session_id(surface) }
  ```
  (`ghostty_surface_session_id(...) -> uint64_t` at `include/ghostty.h` **line 1169**.)

> **The two `sessionID`s are different types — do not confuse them (spec §2.2).**
> `Ghostty.Surface.sessionID` is `UInt64` (off the *real* surface); `SurfaceConfiguration.sessionID`
> is `String?` (parsed back to `u64` in `withCValue`). The tile populates the mirror config as
> **`config.sessionID = String(realView.surface.sessionID)`** and sets **`config.mirror = true`**.

### C4. `macos/Sources/Ghostty/Ghostty.Config.swift` — two getters
- Add `agentDashboard: Bool` using the existing bool-getter pattern in this file.
- Add `agentDashboardCommands: [String]` modeled **verbatim** on `projectDirectories` (**lines
  806–814**: `ghostty_config_get(config, &v, key, len)` →
  `UnsafeBufferPointer(start: v.items, count: Int(v.len))` → map to `String`), key
  `"agent-dashboard-commands"`. **Return `["claude","codex"]` when the parsed list is empty** (the
  Swift-side default from A1):
  ```swift
  var agentDashboardCommands: [String] {
      // read ghostty_config_string_list_s like projectDirectories (806–814) ...
      return parsed.isEmpty ? ["claude", "codex"] : parsed
  }
  ```
  (`ptyHost` getter at **line 278** is available for the pty-host-off degraded state, §2.6.)

### C5. `macos/Sources/Ghostty/Ghostty.App.swift` — action case + handler (POSTS UNCONDITIONALLY)
- In the `action(...)` switch (the project-selector dispatch is at **line 635**), add:
  ```swift
  case GHOSTTY_ACTION_TOGGLE_AGENT_DASHBOARD:
      toggleAgentDashboard(app, target: target)
  ```
- Add `private static func toggleAgentDashboard(...)`. **DIVERGE from `toggleProjectSelector`
  (lines 1158–1177): that handler NO-OPs on `GHOSTTY_TARGET_APP`** — verified at **lines 1162–1164**
  it logs `"toggle project selector does nothing with an app target"` and returns. The dashboard is
  app-global, so the new handler must **post unconditionally**, ignoring the target tag:
  ```swift
  private static func toggleAgentDashboard(
      _ app: ghostty_app_t,
      target: ghostty_target_s) {
      // App-global panel: target is irrelevant, always post.
      NotificationCenter.default.post(name: .ghosttyToggleAgentDashboard, object: nil)
  }
  ```
  (No `guard ... TARGET_SURFACE` early-return; no `surfaceView(from:)`. Do NOT copy the project
  selector's APP-target no-op.)

### C6. `macos/Sources/Features/Terminal/BaseTerminalController.swift` — `unzoomIfHidden(_:)`
- Lift WebMonitor's `revealIfZoomedAway` (**`WebMonitorServer.swift` lines 1167–1173**, the
  verbatim transform) to a reusable method:
  ```swift
  /// If `target` is hidden because this tab is split-zoomed to a DIFFERENT split,
  /// clear the zoom so the split re-mounts and can take focus. Ratio-preserving
  /// (rebuilds from the SAME `root`, only dropping `zoomed`). No-op when not zoomed
  /// or `target` is in the zoomed subtree. MUST be on main.
  func unzoomIfHidden(_ target: Ghostty.SurfaceView) {
      let tree = surfaceTree
      guard tree.zoomed != nil else { return }
      guard !tree.zoomedLeaves().contains(where: { $0.id == target.id }) else { return }
      surfaceTree = .init(root: tree.root, zoomed: nil)
  }
  ```
  (`SplitTree(root:zoomed:)` init + `zoomedLeaves()` exist; the clear is ratio-preserving exactly as
  `ghosttyDidToggleSplitZoom` does it.)
- (Optional, idempotent) call it defensively from `ghosttyDidPresentTerminal` (~line 897).
- **Do NOT refactor WebMonitor to call this** (leave its local copy alone — avoid touching a tested
  file; duplication is acceptable and lower-risk).

### C7. NEW group — `macos/Sources/Features/AgentDashboard/` (5 files)

All `@MainActor` where they touch AppKit. Model holds **value types + weak view refs only**; never
a `ghostty_surface_t`/`SurfaceView` across the detector queue hop (WebMonitor discipline).

**C7a. `AgentDashboardPanel.swift`** — `final class AgentDashboardPanel: NSPanel` (spec §1.1):
- `canBecomeKey = true`, `canBecomeMain = false`.
- `styleMask = [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow, .fullSizeContentView]`.
- `isFloatingPanel = true`, `hidesOnDeactivate = false`, `level = .floating`.
- `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`.
- `setAccessibilitySubrole(.floatingWindow)`, transparent titlebar, hidden title,
  `identifier = "com.mitchellh.ghostty.agentDashboard"`. Mirror `QuickTerminalWindow`'s
  zero-size-frame guard.

**C7b. `AgentDashboardController.swift`** — `NSWindowController` + `AgentDashboardModel` +
ownership/show-hide/frame-autosave/mirror-gating (spec §1.2–1.4):
- Owns the panel, an `NSHostingView` of `AgentDashboardView(model:)`, the
  `AgentDashboardModel` (`@MainActor ObservableObject`), and the `AgentDetector`.
- `toggle()`: first show **creates** the panel; set the first-run default frame with
  `setFrame(_:display:)` **THEN** `setFrameAutosaveName("com.mitchellh.ghostty.agentDashboard")`
  (autosave wins on every later run; default only on first). `orderOut(nil)` /
  `orderFrontRegardless()` to flip. Persist *visibility* in `agentDashboardWasVisible` (fork
  bundle-id `UserDefaults.standard`). Show resumes the detector + un-pauses mirrors; hide pauses
  both (do NOT destroy mirror SurfaceViews on hide — let renderers pause off-screen).
- **`AgentDashboardModel`** (`@MainActor ObservableObject`):
  - `@Published var entries: [AgentEntry]`; `@Published var hidden: Set<UUID>`.
  - `AgentEntry` value type: `{ id: UUID, weak realView: Ghostty.SurfaceView?, title, pwd,
    agent: AgentKind?, bell: Bool, hidden: Bool, sessionID: UInt64, endedAt: Date? }`.
  - **Hide-set persistence (LOCKED #2):** load `hidden` from `UserDefaults` key
    `agentDashboardHiddenIDs` (array of UUID strings) at init; write back on every mutation.
    **Inject the store behind a tiny protocol** (`protocol HideStore { func load() -> Set<UUID>;
    func save(_ ids: Set<UUID>) }`) with a `UserDefaultsHideStore` production impl, so the
    persistence round-trip is unit-testable with an in-memory fake.
  - **Composite observation (spec §1.3, variant b):** subscribe to
    `NSWindow.willCloseNotification` + `didBecomeMainNotification` + the app-wide bell broadcast
    **`Notification.Name.terminalWindowBellDidChangeNotification`**. **This is declared at
    `BaseTerminalController.swift:1913`** (`static let terminalWindowBellDidChangeNotification =
    Notification.Name("com.mitchellh.ghostty.terminalWindowBellDidChange")`) — NOT in
    `SplitTree.swift`. On each → `rebuildControllerObservers()`. Per live controller keep a bell
    subscription via **`surfaceValuesPublisher(valueKeyPath: \.bell, publisherKeyPath: \.$bell)`**
    — the real signature is at `BaseTerminalController.swift:1888–1891` (use BOTH argument labels;
    a positional `surfaceValuesPublisher(\.bell, \.$bell)` will not compile) — plus a
    `controller.$surfaceTree` sink. Merge all controllers' `[UUID: Bool]` bell dicts into one.
  - **Auto-unhide (variant b, bell-only):** when merged `bell[id]` goes `false→true`, remove `id`
    from `hidden` (and persist). Output/rebuild do **NOT** unhide. A panel-open `rebuild()`
    re-evaluates the live-agent set but **never clears `hidden`** — only a bell or the explicit
    "Show"/"Show all" affordance (§4.3) removes an id. Persistence (#2) means a hidden id survives
    relaunch. **Pin this exactly in the C-test-5 state machine.**
  - **`rebuild()`** reconciler: walk `TerminalController.all → surfaceTree` leaves (WebMonitor
    pattern — `for c in TerminalController.all { for view in c.surfaceTree ... }`), join detector
    results + bell dict + hide set, produce sorted `entries` (bell-first → detector-liveness key →
    UUID). Diff against previous so mirror SurfaceViews are created/destroyed incrementally (don't
    tear down a live mirror because an unrelated tab opened).
  - **Mirror gating:** create/destroy each visible tile's mirror SurfaceView on main; tearing down a
    mirror drops its host `subscribe_render` and never touches the real session (Layer 2 verified).

**C7c. `AgentDashboardView.swift`** — SwiftUI (spec §2.1, §2.6, §4.3):
- `LazyVGrid([GridItem(.adaptive(minimum: 320, maximum: 480), spacing: 12)])` of `AgentPreviewTile`
  in sorted order; `.animation(.easeInOut(duration: 0.18), value: order)`.
- **Six non-blank degraded states (spec §2.6):** (1) no terminals; (2) terminals but 0 agents (show
  "Watching for: <commands>"); (3) `pty-host` off (`config.ptyHost == nil`) → banner +
  metadata-only tiles; (4) a specific mirror can't start → "Preview unavailable" tile keeping
  badge/title/bell/jump; (5) session-ended → dimmed frozen tile + "ended" pill; (6) all hidden →
  collapse to "N hidden" only.
- "**N hidden**" footer chip + popover list (badge · title · "Show") + "Show all" (calls the model
  to clear/partly-clear `hidden`, persisting).

**C7d. `AgentPreviewTile.swift`** — one tile (spec §2.2–2.4):
- Header (~22pt): agent badge · middle-truncated title · bell dot · hide ✕ (on hover).
- Live preview: `Ghostty.Surface` representable from a `SurfaceConfiguration` with
  **`mirror = true`** and `sessionID = String(realView.surface.sessionID)`. Wrap +
  `scaleEffect(s, anchor: .bottom)` aspect-fit by width from `ghostty_surface_size`;
  `allowsHitTesting(false)` on the mirror so the **card** receives the click. Do NOT drive any
  resize toward the mirror.
- Footer (~16pt, dim): cwd basename + "needs input"/"ended" pill.
- **Bell frame (spec §2.3):** when `entry.bell`, draw a 3pt amber border
  (`RoundedRectangle.strokeBorder(Color(red:1.0,green:0.8,blue:0.0), lineWidth: 3)`) — distinct
  from the orange marked-pane inset — plus an amber `bell.badge.fill` + "needs input" in the footer.
- Click → resolve real view on main; find owning controller (WebMonitor pattern); call
  `controller.unzoomIfHidden(view)`; then post `Notification.ghosttyPresentTerminal` with the
  **real** `SurfaceView` (`ghosttyPresentTerminal` declared at `GhosttyPackage.swift:410`).
  **READ-ONLY: no Send-Enter / key-forward / right-click reply (LOCKED #3).**
- Accessible label "Jump to {agent} — {title}".

**C7e. `AgentDetector.swift`** — detection (spec §5):
- `protocol ProcEnumerator` returning `ProcSnapshot = [pid_t: (name: String, children: [pid_t])]`;
  a libproc impl (`proc_listchildren` / `proc_name` / `proc_pidpath`).
- **Pure** `func matchAgent(rootPID: pid_t, snapshot: ProcSnapshot, commands: Set<String>) -> AgentKind?`
  — direct hit → child-subtree walk (bounded depth ~4 + visited cap) → basename-vs-path
  (`MAXCOMLEN`) preferring path basename → nil. Title/tty fallbacks last-resort, not primary.
- Poll loop on `DispatchQueue(label: "agent-dashboard.detector", qos: .utility)`: on main snapshot
  `[(uuid, foregroundPID, ttyName, title)]` (value types) → hop to detector queue → walk/match →
  hop back to main publishing `[UUID: AgentKind?]`. Per-UUID cache keyed by `foregroundPID` with a
  short TTL. **Pause while panel hidden** (LOCKED #1: detector + sort key only matter when shown).
- Command set from `config.agentDashboardCommands` (Set<String>), read at start + on config reload.

### C8. `macos/Sources/App/macOS/AppDelegate.swift` + the notification name
- **Declare the notification** alongside `ghosttyPresentTerminal` in
  `macos/Sources/Ghostty/GhosttyPackage.swift` (`ghosttyPresentTerminal` is at **line 410**):
  ```swift
  static let ghosttyToggleAgentDashboard = Notification.Name("com.mitchellh.ghostty.toggleAgentDashboard")
  ```
  > The project-selector notification is actually named **`ghosttyProjectSelectorDidToggle`**
  > (`GhosttyPackage.swift:369`) and is observed by `BaseTerminalController`. The dashboard is
  > app-global, so **AppDelegate** owns the new observer (correct divergence); the *placement*
  > (declare next to `ghosttyPresentTerminal` at line 410) is the right spot.
- In `AppDelegate`, mirror WebMonitor's ownership (`private var webMonitor: WebMonitorServer?` at
  **line 103**; started in `applicationDidFinishLaunching` ~**lines 222/243**; torn down in
  `applicationWillTerminate` at **line 457**):
  - `private var agentDashboard: AgentDashboardController?`.
  - In `applicationDidFinishLaunching`: if `ghostty.config.agentDashboard`, create the controller +
    restore visibility from `agentDashboardWasVisible` (otherwise leave nil → lazily created on
    first toggle).
  - Add an observer for `.ghosttyToggleAgentDashboard` → lazily create the controller if nil, then
    `agentDashboard?.toggle()`.
  - In `applicationWillTerminate`: tear down (persist visibility, stop detector).

### C9. `macos/Ghostty.xcodeproj/project.pbxproj` — iOS exclusion of the 5 new files
- Add to the macOS-app `membershipExceptions` list inside the
  `PBXFileSystemSynchronizedBuildFileExceptionSet` that already holds
  `Features/WebMonitor/WebMonitorServer.swift` (**line 220**) and
  `Features/Command Palette/ProjectPalette.swift` (**line 156**) — the set spanning **lines
  116–284**:
  ```
  "Features/AgentDashboard/AgentDashboardController.swift",
  "Features/AgentDashboard/AgentDashboardPanel.swift",
  "Features/AgentDashboard/AgentDashboardView.swift",
  "Features/AgentDashboard/AgentPreviewTile.swift",
  "Features/AgentDashboard/AgentDetector.swift",
  ```
  (Keep the list's existing lexical grouping; insert near the other `Features/` entries.)

### C10. `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift` — NO CHANGE (variant b)
- Confirm only: the synthetic `child_exited` from the core mirror's `markMirrorEnded` already routes
  through the **existing `childExited` path** (spec §0), so the tile observes "ended" with no new
  field. **Do NOT add `activityTick`** (variant b, LOCKED #1). This file needs no edit.

### Phase-2 gate (macOS — use DE-RISK background+poll; the build always exceeds 150s)
```sh
rm -rf macos/build/ReleaseLocal           # REQUIRED before app/test build (stale-binary trap)
macos/build.nu --action test              # builds GhosttyTests + runs Swift unit tests
```
Run via:
```sh
( macos/build.nu --action test > /tmp/l3-test.log 2>&1 ; echo "EXIT=$?" >> /tmp/l3-done.log ; echo ALLDONE >> /tmp/l3-done.log )
```
then poll until `ALLDONE`. Do NOT build/run the GUI app for visual checks.

---

## IN-AGENT GATE TESTS (the only tests this workflow asserts; spec §7.x.A variant-b)

### Zig (fast, foreground; `-Dtest-filter=<name>`)
1. **`Config`** — `agent-dashboard` bool default `false` + explicit `true` round-trip;
   `agent-dashboard-commands` parses `claude,codex` to 2 entries, defaults empty. (A2; uses the
   `Config.default`/`loadReader`/`finalize` harness at lines 4031–4048 — NOT a non-existent
   `project-directory` parse test.)
2. **`Binding`** — `toggle_agent_dashboard` parse + format + payload-less round-trip (B1, modeled on
   `Binding toggle_project_selector` at 3704–3717).
3. **`action`** — `checkGhosttyHEnum` parity (`GHOSTTY_ACTION_TOGGLE_AGENT_DASHBOARD` ↔ enum field;
   the existing test at `action.zig:463` fails if B4 is missing).

### Swift (`macos/Tests/AgentDashboard/AgentDashboardTests.swift`, auto-discovered by the
filesystem-synchronized `GhosttyTests` group)
4. **`matchAgent` pure logic** via injected `ProcEnumerator` fixtures: (1) direct hit; (2) child hit
   (shell→node→claude); (3) depth cap stops walk; (4) cycle/visited cap; (5) `MAXCOMLEN` truncation
   prefers path basename; (6) no-match → nil; (7) command set `{"codex"}` matches codex not claude.
   **No libproc — fixtures only.**
5. **Hide / auto-unhide state machine INCLUDING PERSISTENCE round-trip** (LOCKED #2): hide adds id +
   writes the store; bell `false→true` removes id; **assert output/rebuild do NOT remove it**;
   "Show all" clears; `N hidden` count derivation; **persistence**: model A hides id → injected
   in-memory store retains it → fresh model B built from the same store starts with id hidden.
6. **`unzoomIfHidden` decision** over constructed `SplitTree`s (no AppKit): (1) `zoomed==nil` no-op;
   (2) target in `zoomedLeaves()` no-op; (3) target hidden under a zoom to a different split →
   `SplitTree(root:zoomed:nil)` with identical `root` (ratios/structure unchanged, only `zoomed`
   cleared). Pure transform like the existing `SplitTreeTests`.
7. **Bell-frame derivation + sort order**: given merged `[UUID:Bool]` + entry set, assert which tiles
   get the amber frame; assert sort is **bell-first**, then the coarse detector-liveness key, then
   **UUID tie-break is stable** (variant-b key; no `activityTick`).

### MANUAL (NOT a gate — the human runs ReleaseLocal; do not attempt)
Live panel visual/layout, real click-to-jump (+ unzoom), real mirror rendering, fullscreen/Space
behavior, previews-pause-while-hidden, the six degraded states rendered live, 4:3 crop legibility.
(Spec §7.x.B.)

---

## HARD INVARIANTS (re-confirm before finishing)
- `.exec` + `.client` (attach AND mirror) paths **byte-for-byte unchanged** — Phase 1 adds only two
  config fields + one payload-less action; no termio/host/embedded edits (variant b).
- Fork-only config keys default off (`agent-dashboard=false`, `agent-dashboard-commands` empty) so
  an official Ghostty sharing `~/.config/ghostty/config` never errors. Keep the keybind +
  `agent-dashboard*` keys in `~/.config/ghostty-ramon/config`.
- The 5 new macOS files are iOS-excluded in `project.pbxproj` (C9).
- Do not regress Layers 1/2 — **no** `src/host/*` or `src/termio/*` changes here; host/client zig
  tests stay green (this plan touches nothing near them).
- Six non-blank degraded states (spec §2.6) all handled in `AgentDashboardView` (C7c).

## APPLY-ORDER CHECKLIST (condensed)
1. Zig: Config fields + test (A) → Binding/command/action/ghostty.h (B) → Phase-1 gate.
2. Rebuild lib `-Doptimize=ReleaseFast`.
3. Swift: C2 mirror config → C3 sessionID getter → C4 config getters → C5 App handler (posts
   unconditionally) → C6 unzoomIfHidden → C7 AgentDashboard group (5 files) → C8 AppDelegate +
   notification name → C9 pbxproj → C10 confirm no SurfaceView_AppKit change.
4. `rm -rf macos/build/ReleaseLocal` → `macos/build.nu --action test` (DE-RISK bg+poll).

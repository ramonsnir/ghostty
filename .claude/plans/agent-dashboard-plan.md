# Agent Dashboard — implementation plan (ramon-fork)

A fork-only macOS feature: a **floating panel** for the ultrawide that shows a **live,
natively-rendered mini-preview of every terminal split that is running a CLI agent
(Claude Code / Codex)** across all tabs and windows, highlights the ones that rang the
**bell** (need input), lets you **click a preview to jump to that split** (un-zooming if
it is hidden under a split-zoom), and lets you **hide** previews you don't care about
right now (auto-un-hidden on the next bell or new output).

> Status: PLAN. Not started. Single working branch `ramon-fork`. The host pieces land on
> `ramon-fork` (host code already lives here — `src/host/`), NOT on `ptyhost/phase-2b`.

---

## 1. Why this design (the decisive facts)

- The fork's **pty-host** splits emulation (host) from rendering (GUI `.client`). The
  **host always emulates** every session — `Session.renderTick` runs on a ~10 Hz poll
  *and* on real output, independent of whether any GUI is drawing that session
  (`src/host/Session.zig`). Only the **GUI renderer pauses when off-screen**
  (`src/renderer/Thread.zig` gates `drawFrame`/`updateFrame` on a `visible` flag).
- Therefore a preview that lives **inside the panel (on-screen)** renders **live**, even
  for an agent whose own tab is backgrounded / in another window / hidden under a zoom —
  precisely the panes we care about. Native `.client` rendering is **full-color, full
  fidelity, viewport-only** (ptyhost.md: "cell fidelity proven equal to in-process
  `.exec`"). Viewport-only is exactly right for a "last few lines" preview.
- The host's render-frame push is **already fan-out-capable**: `SessionEntry.subscribers`
  is a list, and the raw-tee (`raw_subscribers`) already proves the additive
  "second read-only subscriber list" pattern. So we add a **read-only render
  subscription** that receives the session's *existing* frames at the session's *current*
  size and **never drives resize** → it can never reflow your real terminal.
- "Live xterm in a WebView" was rejected: we get higher fidelity, zero new web stack, and
  keep the inline-reply future open by reusing Ghostty's own renderer + `ghostty_surface_key`.

### Invariants we must preserve
- **`.exec` byte-for-byte unchanged.** All new behavior is gated on the new frames /
  surface mode; nothing touches the `.exec` path.
- **Additive, version-negotiated host protocol.** Bump the protocol minor (currently 1,
  from the raw-tee); a peer that doesn't speak `subscribe_render` simply never sends it.
  **A host rebuild kills every live shell it owns** — keep the host change tiny, additive,
  crash-safe (checked `intToEnum`, bounded lengths, degrade-to-close on malformed frames).
- **Read-only mirror never sends Resize/Input that mutates session size.** Input
  forwarding (future) sends keystrokes only; it must never send a resize frame.
- **Threading:** the panel + any host-socket work follow the web-monitor discipline —
  AppKit / `ghostty_surface_*` only on main; socket read loops on their own thread.

---

## 2. Layer 1 — Host render-tee (Zig, additive; twin of the raw-tee)

Goal: a client can `subscribe_render(session_id)` and receive the session's GridFrame +
ModeFrame stream (seeded with a full frame on subscribe), without attaching, without
driving resize, without owning the session.

### Protocol (`src/host/protocol.zig`)
- Bump the negotiated minor (the raw-tee already took it to 1 → take to 2) with a comment
  noting the additive `subscribe_render` frame.
- Add frame tag `subscribe_render` (client→host). Reuse the existing `SessionIdFrame`
  pattern: `pub const SubscribeRender = SessionIdFrame(.subscribe_render);` (mirror
  `SubscribeRaw` at protocol.zig ~1078).
- **Reuse the existing `grid_frame` / `mode_frame` tags for the payload** — they are
  already pointer-free and fan-out-safe. Render subscribers receive the identical bytes
  attached clients receive. (No new render-payload frame type needed.)

### Server (`src/host/Server.zig`)
- `SessionEntry.render_subscribers: std.ArrayList(*Conn) = .empty;` parallel to
  `raw_subscribers` (~line 128). Add `addRenderSubscriber`/`removeRenderSubscriber`
  (mirror `addRawSubscriber`/`removeRawSubscriber`, ~lines 172–190, idempotent, under
  `e.mutex`).
- `Conn.subscribed_render: AutoHashMap(u64, void)` parallel to `subscribed_raw` (~line 202).
- Dispatch arm `.subscribe_render` → `handleSubscribeRender(conn, sid)` mirroring
  `handleSubscribeRaw` (~lines 1074–1094): validate session exists + live, add to
  `render_subscribers`, then **seed by calling `pushFullFrames` targeted at this conn
  only** (reuse the existing full-frame capture at Server.zig ~1500–1573 — refactor it to
  take an optional single-`Conn` target, or add a `pushFullFramesTo(conn, e)` that shares
  the one `render_mutex` critical section).
- Broadcast: in `onRender` (~line 1233), after the existing `e.subscribers` loop, add a
  second loop over `e.render_subscribers` writing the **same** GridFrame + ModeFrame.
  Same `e.mutex`, no new lock.
- Cleanup (mirror raw exactly): `unsubscribeAll` (~488) iterate `conn.subscribed_render`;
  `.detach` arm (~749) remove render-sub; `teardownEntry` (~1616) clear `render_subscribers`
  under `e.mutex` before free.
- **Acceptable-method/decode discipline:** add `subscribe_render` to the validated decode
  set; it is a client→host frame, so `grid_frame`/`mode_frame` stay in the "host→client,
  reject if received" set.

### Tests (`src/host/test.zig`, `-Dtest-filter=host`)
- Frame encode/decode round-trip for `subscribe_render`.
- Integration: spawn a session, `attach` a primary conn at grid A, `subscribe_render` a
  second conn → it receives a seeded full frame at grid A, and subsequent output produces
  GridFrames on **both** conns. Resize from the primary reflows; the render-sub follows.
- Negative: a render-sub that sends a Resize is rejected/ignored without affecting session
  size (assert the session grid is unchanged). Malformed `subscribe_render` → clean
  connection close, session survives.
- Teardown/detach removes the render-sub; no broadcast-after-free.

---

## 3. Layer 2 — Core "render-mirror" surface mode (Zig + apprt + C header)

Goal: a `ghostty_surface_t` that renders a live mirror of an existing `session_id` by
`subscribe_render`ing it, instead of `attach`ing a fresh/own session. Renders through
Ghostty's own renderer (full color, viewport-only). Drives **no** resize and owns **no**
PTY.

### Client backend (`src/termio/Client.zig`, `backend.zig`)
- Add a **mirror mode** to the `.client` backend: a flag (e.g. `role: .attach | .mirror`)
  set at construction. In `.mirror`:
  - Handshake `Hello`, then send `subscribe_render(session_id)` instead of `attach`.
  - Consume GridFrame/ModeFrame into the same `RenderState` mirror the renderer already
    reads (`src/renderer/generic.zig`, unchanged — it just reads the mirror under
    `render_mutex`).
  - **Suppress all resize messages to the host** (the renderer/surface will compute a grid
    from the preview's pixel size, but the mirror backend must drop/never-send the resize
    frame). The mirror simply renders whatever cols/rows the host pushes, letterboxed by
    the view (see §4.2).
  - Input: in the first cut, **read-only** — drop input messages (or never wire a
    responder). (Inline-reply is a later add: forward key events as host Input frames to
    the live session; explicitly never a resize.)
  - child-exit / session-gone on a mirror → render a quiescent "session ended" state and
    signal the surface so the panel can drop the tile (do **not** close anything real).

### Surface + apprt (`src/Surface.zig`, `src/apprt/embedded.zig`, `include/ghostty.h`)
- `Surface.zig`: when the new config flag says "mirror" and a `session_id` is present,
  construct the `.client` backend in mirror mode *before* the backend-union move (respect
  the existing "wire mirror/mutex after the move" discipline — see ptyhost.md "One mutex
  for the mirror").
- C ABI: add to `ghostty_surface_config_s` a `mirror: bool` (or a `surface_role` enum)
  alongside the existing `session_id` field. The macOS side already passes `session_id`
  forward and reads it back via `ghostty_surface_session_id()`.
- No new `.exec` behavior; mirror mode is only reachable under `pty-host`.

### Tests (`-Dtest-filter=client`)
- Mirror backend: given a fake host emitting GridFrames, the mirror's `RenderState`
  rehydrates equal to an attached client's (reuse `client_difftest.zig` harness).
- Mirror never enqueues a resize/attach frame on the wire (assert the outbound frame set).

---

## 4. Layer 3 — macOS panel (Swift, new feature dir `macos/Sources/Features/AgentDashboard/`)

New files in a feature dir (add macOS-only files to the iOS exclusion set in
`project.pbxproj`, like WebMonitor):
- `AgentDashboardController.swift` — the `NSPanel` window controller + model.
- `AgentDashboardPanel.swift` — the `NSPanel` subclass (QuickTerminal template).
- `AgentDashboardView.swift` — SwiftUI grid/list of preview tiles.
- `AgentPreviewTile.swift` — one tile: hosts the mirror SurfaceView, bell frame, hide
  button, title/cwd, "session ended" state.
- `AgentDetector.swift` — pure-ish `libproc` process-tree walk → is-agent + which agent.
- Plus small additions to `Ghostty.App.swift` / `Ghostty.Config.swift` /
  `AppDelegate.swift` (open/close + config) and `BaseTerminalController.swift`
  (un-zoom-before-present).

### 4.1 The panel window
- `class AgentDashboardPanel: NSPanel` modeled on `QuickTerminalWindow`
  (`macos/Sources/Features/QuickTerminal/QuickTerminalWindow.swift`):
  non-activating (`.nonactivatingPanel`), `canBecomeKey = true`, accessibility subrole
  `.floatingWindow`. After show, set `window.level = .floating` so it stays above terminal
  windows ("lock to foreground"). Toggle via a fork-only action + command-palette entry
  ("Toggle Agent Dashboard"). Position/size persisted in UserDefaults (per the fork's
  own bundle-id domain).
- **Lifecycle:** opened/closed from `AppDelegate`; survives independent of any one
  terminal window. The model observes `TerminalController.all` + each controller's
  `$surfaceTree` to keep the surface set current as tabs/splits/windows come and go.

### 4.2 The live preview tile (the heart)
- For each agent split, create a **mirror SurfaceView** bound to that split's
  `session_id` (read via `ghostty_surface_session_id(realSurface)`), constructed with the
  new `mirror: true` config flag. It renders natively through Ghostty's renderer, full
  color, viewport-only.
- **Sizing:** the mirror renders at the host's authoritative grid (the real split's
  cols/rows). The tile shows it **scaled down to fit** (an aspect-fit transform on the
  hosting NSView/layer) so it reads as a faithful thumbnail without driving any resize.
  The "last few lines" emphasis is achieved by anchoring the scaled view to its bottom
  (cursor/most-recent rows visible) and clipping the tile height — show the bottom N rows.
- **Render cost is self-limiting:** the renderer pauses when the panel is hidden
  (off-screen), so closed panel ≈ zero preview cost. With the panel open we have one extra
  renderer per agent tile; for a handful of agents this is fine and bounded by the agent
  filter (§4.4).
- "session ended" / mirror-gone → tile shows a dimmed terminated state and is removed on
  next model refresh.

### 4.3 Bell highlight (needs-input signal)
- Subscribe to per-surface bell via the existing
  `BaseTerminalController.surfaceValuesPublisher(valueKeyPath: \.bell,
  publisherKeyPath: \.$bell)` aggregated across all controllers (the model merges each
  controller's publisher keyed by `SurfaceView.id`).
- A tile whose underlying real surface has `bell == true` draws the amber **bell frame**
  (reuse the look of the existing bell border) and sorts to the top. Bell clears the
  normal way (surface processes it); the tile frame follows reactively.

### 4.4 Agent detection (filter to Claude Code / Codex)
- `AgentDetector`: for each real `SurfaceView`, read `Ghostty.Surface.foregroundPID`
  (C: `ghostty_surface_foreground_pid()`) and walk the process subtree with `libproc`
  (`proc_listchildren`, `proc_name`, `proc_pidinfo`) looking for an executable basename
  matching a configurable set (default `["claude", "codex"]`). `ttyName`
  (`ghostty_surface_tty_name()`) is the fallback discriminator if the pid is the shell.
- Detection is **polled** (e.g. every ~2 s) off the main thread; results cached per
  surface id; the agent name decorates the tile. Title-substring match is a last-resort
  fallback (some agents set OSC 0/2 titles).
- The agent set is a fork-only config key (§5) so "what counts as an agent" is tunable
  without a rebuild.

### 4.5 Click-to-focus + un-zoom
- Clicking a tile posts `.ghosttyPresentTerminal` with the **real** target `SurfaceView`
  (NOT the mirror). The existing handler `BaseTerminalController.ghosttyDidPresentTerminal`
  (~897–911) already raises the window, selects the tab (it's the controller's window),
  `moveFocus`es, and `highlight()`-flashes.
- **New un-zoom step:** before/with focus, if the target controller's
  `surfaceTree.zoomed != nil` and the target is **not** among `surfaceTree.zoomedLeaves()`
  (i.e. hidden under the zoom), reset the zoom first so the split can take focus. Add a
  small helper on `BaseTerminalController` (e.g. `unzoomIfHidden(_ target:)`) invoked from
  the present handler (guarded so it only fires when needed; visible-zoom or unzoomed tabs
  are untouched). Verify which zoom path applies (split-zoom via `SplitTree.zoomed`) and
  reset via the existing equalize/un-zoom transform, then re-`moveFocus` after the tree
  settles (the handler already does a delayed second `moveFocus` for race safety).

### 4.6 Hide + auto-unhide
- A per-surface **hide set** (`Set<SurfaceView.ID>`) in the dashboard model (persisted is
  optional — start in-memory). A tile's "Hide" button adds its id; hidden tiles are
  removed from the grid (optionally collapsed into a small "N hidden" affordance).
- **Auto-unhide triggers** (remove from hide set):
  - bell rings on that surface (from the §4.3 publisher), or
  - **new output** — derive an activity signal from the mirror's frame stream (the host
    pushes a render/grid frame on change). Expose a lightweight "last activity" tick from
    the mirror surface (e.g. increment on each applied GridFrame) and observe it; on
    increment for a hidden id, unhide. (No snapshot diffing — the stream *is* the signal.)
- Hiding only affects the dashboard; it never touches the real split.

---

## 5. Config (fork-only keys, default-off; keep in `~/.config/ghostty-ramon/config`)

In `src/config/Config.zig` (+ doc + parse test), mirrored in `Ghostty.Config.swift`:
- `agent-dashboard = true|false` (default `false`) — master on/off. (Or gate purely on the
  toggle action + remember last state; a config key is cleaner for "always open on launch".)
- `agent-dashboard-commands = claude,codex` (RepeatableString, default `claude,codex`) —
  the executable basenames that mark a split as an agent. Reuses the `RepeatableString`
  cval/C plumbing already added for `project-directory`.
- (Optional) `agent-dashboard-rows = N` — how many bottom rows each tile shows.
- Keybind action `toggle_agent_dashboard` (payload-less) in `src/input/Binding.zig` +
  `src/input/command.zig` (command-palette entry "Toggle Agent Dashboard"), wired through
  `src/apprt/action.zig` to a macOS handler on `Ghostty.App` (like
  `toggle_project_selector`). Keep the keybind fork-side (e.g. `ctrl+a>d`).

---

## 6. File manifest

**Zig core / host**
- `src/host/protocol.zig` — minor bump + `subscribe_render` tag + `SubscribeRender`.
- `src/host/Server.zig` — `render_subscribers`, add/remove, dispatch arm,
  `handleSubscribeRender`, `pushFullFramesTo`, `onRender` second loop, cleanup in
  `unsubscribeAll`/`.detach`/`teardownEntry`.
- `src/host/test.zig` — render-tee frame + integration + negative tests.
- `src/termio/Client.zig`, `src/termio/backend.zig` — mirror role; `subscribe_render`;
  resize/input suppression; session-gone handling.
- `src/termio/client_difftest.zig` — mirror == attach render equality.
- `src/Surface.zig` — construct mirror backend on the new flag + `session_id`.
- `src/apprt/embedded.zig`, `include/ghostty.h` — `mirror`/`surface_role` in
  `ghostty_surface_config_s`.
- `src/config/Config.zig` — `agent-dashboard*` keys (+ docs + parse tests).
- `src/input/Binding.zig`, `src/input/command.zig`, `src/apprt/action.zig` —
  `toggle_agent_dashboard`.

**macOS Swift**
- `macos/Sources/Features/AgentDashboard/{AgentDashboardController,AgentDashboardPanel,
  AgentDashboardView,AgentPreviewTile,AgentDetector}.swift` — new feature.
- `macos/Sources/Ghostty/Ghostty.Config.swift` — `agentDashboard*` getters.
- `macos/Sources/Ghostty/Ghostty.Surface.swift` — already has `foregroundPID`/`ttyName`;
  add a mirror-surface constructor convenience if needed.
- `macos/Sources/Ghostty/Ghostty.App.swift` — `toggle_agent_dashboard` handler; open/close.
- `macos/Sources/App/macOS/AppDelegate.swift` — panel lifecycle; honor `agent-dashboard`.
- `macos/Sources/Features/Terminal/BaseTerminalController.swift` — `unzoomIfHidden(_:)` +
  call it from `ghosttyDidPresentTerminal`.
- `macos/Ghostty.xcodeproj/project.pbxproj` — iOS-exclude the new macOS-only files.

**Tests**
- Zig: `-Dtest-filter=host` (render-tee), `-Dtest-filter=client` (mirror),
  `Config` parse tests, `Binding toggle_agent_dashboard`.
- Swift (`macos/Tests/AgentDashboard/…`, auto-discovered by the synchronized group):
  `AgentDetector` process-match logic (pure, with injected proc-tree fixtures),
  hide/auto-unhide model state machine, un-zoom decision (`unzoomIfHidden` given a
  zoomed tree with the target inside/outside `zoomedLeaves`), bell-frame derivation.

---

## 7. Build / deploy / safety caveats

- **Order:** Zig core+host first (`zig build test …` per filter), then rebuild the lib
  (`zig build -Demit-macos-app=false -Doptimize=ReleaseFast`), then Swift tests
  (`macos/build.nu --action test`), then the app (`--configuration ReleaseLocal`). Iterate
  on **ReleaseLocal** ("Ghostty (ramon-local)") — never quit/launch the installed Release
  that hosts this session.
- **Host deploy caveat (loud):** the render-tee is a **host** change. Rebuilding/restarting
  `ghostty-host` **drops every live session** (RAM-only). So shipping Layer 1 means a host
  restart and losing current shells — schedule it deliberately. The GUI/panel pieces
  (Layers 2–3) are GUI-only and survive via reattach.
- **Protocol compat:** keep it additive + minor-negotiated; an old host (no
  `subscribe_render`) must degrade cleanly (the mirror surface should detect the missing
  capability and show an informative "no live stream" tile rather than hang — mirror the
  web monitor's `→ 501` fallback philosophy).
- **`.exec` untouched; never push to `origin`; back up with bare `git push fork`.**

---

## 8. Decisions already made (from discussion)
- Floating `NSPanel` (not docked sidebar).
- Show **only** agent sessions (Claude Code / Codex), detected via foreground-pid + libproc.
- **Native** live mini-render via Ghostty's own renderer over a read-only host render-tee
  (not WebView/xterm.js, not Metal snapshotting — off-screen splits don't draw, so
  snapshotting can't see them).
- **No vertical slice** — build the complete, usable feature.

## 9. Open questions to resolve during implementation
- Exact split-zoom reset call for `unzoomIfHidden` (which `SplitTree` transform clears
  `zoomed` without disturbing ratios) — confirm against `SplitTree.swift`.
- Whether `agent-dashboard` master switch is a config key, a remembered toggle, or both.
- Tile layout for many agents (grid vs vertical list; per-window grouping like the web
  monitor's phone view).
- Persist the hide-set across launches or reset each launch (lean: reset each launch).

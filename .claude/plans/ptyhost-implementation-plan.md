# Ghostty Persistent Emulation-on-Host PTY-Host — Final Implementation Plan

Status: build-ready. All Phase-0 spikes are resolved (see §9). Architecture is decided
(emulation-on-host / tmux-server model); this plan does not relitigate it.

Scope discipline reminder (from the fork CLAUDE.md): this is a fork-only project. All
host wiring, the new `.client` backend, and `project-directory`-style fork keys must not
break an official Ghostty sharing `~/.config/ghostty/config`. Never quit/launch any app
named "Ghostty"; never touch `/Applications`. The installed Release identity
(`com.mitchellh.ghostty-ramon`) hosts the live session — iterate only on ReleaseLocal /
Debug.

---

## 1. Final architecture (resolved)

Three tiers, replacing today's two (AppKit/SwiftUI ⇄ in-process libghostty):

```
┌─ ghostty-host  (NEW long-lived process, one per fork identity) ───────────────┐
│  Headless libghostty "up to but not including GPU draw".                       │
│  Per session_id:                                                               │
│    terminal.Terminal  +  termio.Termio  +  termio.Exec (.exec backend)         │
│    termio.Thread (libxev loop) + pty.zig master fd + Command.zig child         │
│    renderer.State { mutex, terminal:*Terminal, inspector=null }  (REAL, no GPU)│
│    xev.Async wakeup  →  callback runs RenderState.update + diff + push          │
│    stub renderer.Thread.Mailbox (BlockingQueue) drained for {.resize,.reset_*}  │
│    stub App.Mailbox (BlockingQueue) drained for apprt.surface.Message events    │
│    search Thread (src/terminal/search/Thread.zig — holds *Terminal) moves HERE  │
│  Session registry: session_id → {Termio, child pid, RenderState, subscribers}  │
│  Transport server: AF_UNIX SOCK_STREAM @ per-identity path, framed protocol    │
└────────────────────────────────────────────────────────────────────────────────┘
                          ▲ AF_UNIX framed binary protocol (versioned)
                          ▼
┌─ Ghostty GUI (existing AppKit/SwiftUI + libghostty; churns freely) ────────────┐
│  Surface KEEPS: renderer.Thread + Renderer + Metal + font grids/atlas           │
│                 + a LOCAL RenderState mirror per surface (the draw source)       │
│                 + renderer.image.State mirror (kitty) per surface                │
│                 + key/IME encoding + a small terminal-MODE mirror (~14 fields)   │
│  Surface DROPS: in-process Termio / Terminal / Exec / PageList / child / search  │
│  NEW termio backend `.client` proxies to the host over the socket; never forks. │
└────────────────────────────────────────────────────────────────────────────────┘
```

### 1.1 The boundary, resolved

The renderer↔termio boundary that "must become IPC" is **not** the raw `terminal.Terminal`.
It is `terminal.RenderState` (`src/terminal/render.zig:49`). Confirmed by the
`renderstate-as-wire-protocol` and `updateframe-terminal-coupling` spikes: there are
**exactly 8 `state.terminal` references in `src/renderer/generic.zig`, all inside the one
`updateFrame` critical section**; everything downstream of the mutex already reads the
local `self.terminal_state` (a `RenderState`), never the live `Terminal`. The decision is
**option (B)**: the GUI renderer reads only a host-supplied `RenderState` mirror; there is
no GUI-side `Terminal`.

Disposition of the 8 critical-section accesses (all host-side now):
- `RenderState.update` (the mirror build) → host runs it per render tick, serializes the result.
- `synchronized_output` mode → host scalar in the frame header (or host simply omits frames while synced).
- `scrollbar()` (`src/renderer/generic.zig:1216`) → host ships `{total,offset,len}` u64 triple (reuse `ghostty_action_scrollbar_s`).
- scroll-to-bottom-on-output `getBottomRight` comparison + `scrollViewport(.bottom)` WRITE (`generic.zig:1187-1200`) → host owns `last_bottom_node`/`y`, runs the scroll **host-side before** the mirror build; ships a `scrolled_to_bottom` bit. The config flag `scroll_to_bottom_on_output` currently lives in the **renderer's** `DerivedConfig` (`generic.zig:572`, populated `:646`, read `:1187`) and must be **moved into the host's `Termio.DerivedConfig`** (see §4.6 for the exact relocation).
- `search_viewport_dirty = true` WRITE (`generic.zig:1208`) → host-internal; the search `Thread` (`src/terminal/search/Thread.zig`, which holds `*Terminal`) moves host-side (see the relocation task in §3.3), so this write never crosses the wire. Search **match highlights** then ride the GridFrame: they already live on `RenderState` rows (`src/terminal/render.zig:197-206,651`), so once the search Thread runs host-side the highlights serialize with the dirty rows and the GUI needs no separate search wire.
- Kitty `kittyRequiresUpdate`/`kittyUpdate` (`generic.zig:1231-1243`) → host-side; ships on a **separate heavy image channel** (§4.4).

**Net result from the spikes:** *neither* of the two feared GUI→host WRITES crosses the
wire. Both are host-local steps run in the host's single render tick under the host's
terminal mutex, preserving the exact in-process ordering (scroll → build mirror → set
search-dirty). The GUI→host channel is therefore "input bytes + small typed requests +
resize/focus/clipboard/config", *not* "bytes + ordering-sensitive write-back".

### 1.2 What lives where

- **Emulation (host):** `terminal.Terminal`, `termio.Termio`, `termio.Exec` + `pty.zig` +
  `Command.zig`, `StreamHandler`, `PageList`/scrollback, alt-screen, modes, kitty image
  storage, the search `Thread` (`src/terminal/search/Thread.zig`). Reused verbatim — no `Termio` source change is needed to
  remove GPU (the `termio-without-gpu` spike proved GPU was never inside `Termio` or
  `renderer.State`; it lives in the renderer impl + render thread the host simply never
  creates).
- **Rendering (GUI):** `renderer.Thread`, `Renderer`, Metal, font grids/atlas, the local
  `RenderState` mirror, the `renderer.image.State` mirror. `rebuildCells`/`rebuildRow`/
  `cursorStyle`/font-shaper paths stay **untouched** — they already consume only a
  populated `terminal_state.RenderState`.

---

## 2. The protocol (the frozen contract)

Transport: **AF_UNIX `SOCK_STREAM`, one connection per GUI process**, multiplexed by
`session_id`, **length-prefixed (4-byte BE) binary frames**. Survival, throughput, and
latency proven (`grid-over-ipc-perf` spike: full 200×50 viewport ≈ 80 KiB, full
12-surface tick incl. AF_UNIX hop ≈ 0.05 ms vs the 8 ms `DRAW_INTERVAL` budget — ~150×
headroom; ~22.6 GiB/s with 1 MiB socket buffers). **No shared-memory ring, no tighter
codec for v1.** Raise `SO_SNDBUF`/`SO_RCVBUF` to ~1 MiB so a full frame never short-writes.

**Authoritative schema source:** `src/terminal/c/render.zig` (the existing
`render_state_*` C ABI) is the canonical field set for the grid frame and is **stabilized
as part of the frozen host/protocol surface**. The wire format mirrors it 1:1.

Every frame carries a `protocol_version` (major.minor) negotiated at handshake. Host
accepts newer-*minor* GUIs (additive fields, ignore-unknown); refuses incompatible
*major* cleanly. See §6.

### 2.1 Frame catalog

**Handshake (both directions, once per connection):**
- `Hello { protocol_version, identity_bundle_id }` → `HelloAck { protocol_version, host_pid, host_start_epoch }`.

**GUI → host (per session unless noted):**
- `Attach { session_id? , spawn_opts? }` — attach to existing `session_id`, else spawn
  fresh; host replies `Attached { session_id, cols, rows }` (session_id is host-assigned
  on spawn and surfaced back for archival, §5).
- `Detach { session_id }` — explicit detach (keeps child alive).
- `Close { session_id }` — explicit close (tears the session down).
- `Input { session_id, bytes, linefeed:bool }` — maps to `Termio.queueWrite` semantics.
- `Resize { session_id, grid_size:{cols,rows}, screen_size:{w,h,padding} }` — GUI computes
  font metrics/DPI (GUI-only); host runs `Termio.resize` (`src/termio/Termio.zig:463`).
- `Focus { session_id, focused:bool }` → `Termio.focusGained` (`src/termio/Termio.zig:620`).
- `ScrollViewport { session_id, target }` / `JumpToPrompt { session_id, delta }` — mirror
  `src/termio/Termio.zig:599,609`.
- `ClipboardReply { session_id, data, kind }` — answer to host `ClipboardRead` event.
- `ConfigUpdate { termio_derived_config }` — the termio half of a config reload (§4.6).
- `RequestScrollback { session_id, range }` — lazy scrollback paging (§4.7).
- `Ping {}` / `Pong {}` — liveness.

**Host → GUI (per session):**
- `GridFrame` — the linchpin. Mirrors `RenderState` 1:1:
  - header: `cols, rows, dirty(false|partial|full), nstyles, ndirty_rows, scrolled_to_bottom:bool, synchronized_output:bool, scrollbar:{total,offset,len}(3×u64), cursor_blink_visible:bool`.
  - `colors`: `{bg, fg, cursor, palette[256]}` (reverse-video pre-applied — `render.zig:119-128`).
  - `cursor`: `{active_coord, viewport_coord, cell(u64 page.Cell bitcast), style, visual_style, visible, blinking, password_input}` (`render.zig:130-168`).
  - in-frame **style table**: `u16 style_id → 14-byte Style POD` for the non-default styles referenced this frame.
  - dirty rows only (when `dirty==partial`; whole viewport when `full`; nothing when `false`): each row = `u16 row_index, dirty, selection_range?, highlight_ranges[]` then `cols × 8-byte verbatim page.Cell`, with **grapheme runs appended** only for grapheme cells (`row,col,len + len×u21`). `page.Cell` is `packed struct(u64)` with no pointers (`cval()==@bitCast`); `grapheme` is the only managed member and is arena-duplicated during `RenderState.update` (`render.zig:530`), so the snapshot is self-contained and pointer-free. **The serializer must strip `PageList.Pin` identity** (`render.zig:88,181`) — the GUI compares frames by content/Dirty, never by pin.
- `ModeFrame` (in-band, same monotonic sequence as `GridFrame`) — the input-mode mirror,
  ~14 fields (§4.1): `{alt_esc_prefix, cursor_keys, keypad_keys, backarrow_key_mode,
  ignore_keypad_with_numlock, bracketed_paste, disable_keyboard, mouse_alternate_scroll,
  mouse_event(enum), mouse_format(enum), mouse_shift_capture(tri), modify_other_keys_2,
  kitty_flags(active-screen-resolved), alt_screen_active}`. Applied strictly
  **before/atomically-with** the `GridFrame` it accompanies so DECCKM-then-arrow is correct.
- `LinkFrame` — regex/OSC8 link highlighting computed **host-side**, shipped as `(x,y)`
  coordinate `CellSet` lists (the C type already exists). Not part of the cell grid.
- `ImageFrame` (kitty graphics, heavy, separate channel) — modeled field-for-field on
  `renderer.image.State` (`src/renderer/image.zig:18`): (a) image upserts
  `{Id, width, height, pixel_format, transmit_time, blob}` sent **once per (id,transmit_time)**
  and cached client-side; deletes by `Id`; (b) flat `Placement` tuple array (pure integer
  tuples — image_id, grid x/y/z, dest px size, cell offsets, source rect, no Terminal
  pointers) + `kitty_bg_end` + `kitty_text_end` band indices + `kitty_virtual` flag; (c) an
  `images_dirty` generation counter. Host runs `kittyUpdate` against its own Terminal/
  viewport; GUI applies verbatim into its existing `image.State` and runs `upload()`/`draw()`
  unchanged.
- `SurfaceEvent { session_id, message }` — the `apprt.surface.Message` set verbatim
  (`src/apprt/surface.zig:14-95`): `set_title, report_title, set_mouse_shape,
  clipboard_read, clipboard_write, desktop_notification, password_input, color_change,
  pwd_change, ring_bell, progress_report, renderer_health`. GUI re-injects into its existing
  surface-message handling.
- `ChildExited { session_id, exit_code, runtime }` — buffered while detached, reported on
  reattach (host `childExitedAbnormally`, `src/termio/backend.zig:88`).
- `ScrollbackChunk { session_id, range, rows }` — answer to `RequestScrollback`.

### 2.2 Cadence

- The host render-ticks a session **only when `Termio.processOutput` marked something
  dirty** (the existing `queueRender` wakeup, `src/termio/Termio.zig:654` → the `xev.Async`
  callback). It pushes coalesced dirty diffs — not at 120 fps. Host-tick capped (e.g. 60 Hz)
  for full-screen TUI redraw.
- The GUI's draw timer (`DRAW_INTERVAL = 8`, `src/renderer/Thread.zig:19`) draws from the
  **local mirror**, decoupled from the network. Steady typing = a few dirty rows; a TUI
  redraw = one coalesced `full` frame.
- `ImageFrame` is on its own lazy/backpressured channel; blobs deduped by
  `(image_id, transmit_time)`. While `kitty_virtual` is set, re-ship the **placement-tuple
  block** (diffed; not pixels) on every grid change.
- Scrollback is never streamed wholesale; the mirror holds only the viewport (RenderState is
  viewport-only by construction, `render.zig:57-60`). Scroll = `ScrollViewport` request →
  host repins → `full` `GridFrame`.

---

## 3. Component-by-component work breakdown

### 3.1 New `.client` termio backend (Zig, GUI side)

Files: `src/termio/backend.zig`, new `src/termio/Client.zig`, `src/Surface.zig`.

- Extend `Kind` from `enum { exec }` (`src/termio/backend.zig:14`) to `enum { exec, client }`.
  Add a `client: termio.Client` arm to **every** switch in `Backend` (`:24-114`), `Config`
  (`:17-22`), and `ThreadData` (`:116-129`). Each interface method maps to a protocol send:
  - `initTerminal(t)` (`:33`) — `.client` connects to the host socket and `Attach`es; the
    host returns initial dims and a first `GridFrame`/`ModeFrame`.
  - `threadEnter`/`threadExit` (`:39`/`:50`) — register/unregister the socket fd with the
    GUI's termio `libxev` loop; the read side decodes frames into the mirror `RenderState`
    + mode mirror.
  - `resize` (`:66`) → `Resize` send; `queueWrite` (`:76`) → `Input` send;
    `focusGained` (`:56`) → `Focus` send.
  - `childExitedAbnormally` (`:88`) — driven by the host's `ChildExited` event, not local.
  - `getProcessInfo` (`:108`) — answered from host metadata cached at attach (or a small
    request/response).
- `src/Surface.zig:687` `.backend = .{ .exec = io_exec }` is the single branch point. Select
  `.client` when an attach token / host mode is present (config-selectable; `.exec` remains
  the default fallback so a broken host never bricks the GUI — see the incremental
  validation rule, §7).
- `src/Surface.zig:1329-1330` reads `self.io.backend` as `.exec` for the command string; add
  a `.client` arm returning host-supplied process info.
- `Client.zig` owns: the socket fd, the per-surface mirror `RenderState`, the mode mirror,
  the `renderer.image.State` mirror, frame decode, and the GUI→host send helpers. It
  deserializes a `GridFrame` straight into the mirror `RenderState` and flips its dirty
  flags; the existing render path runs verbatim.

### 3.2 Renderer wiring to read the mirror (Zig, GUI side)

Files: `src/renderer/State.zig`, `src/renderer/generic.zig`, `src/Surface.zig`.

- Today `renderer.State` = `{mutex, terminal:*Terminal, inspector?, preedit?, mouse}`
  (`src/renderer/State.zig:14-31`) and `Surface` sets `renderer_state.terminal = &self.io.terminal`
  (`src/Surface.zig:616`). Under option (B) the GUI has no `Terminal`. Refactor the renderer's
  source of truth from `state.terminal` to a host-supplied `RenderState` that the `.client`
  backend owns and updates under the same `renderer_state.mutex`.
- The 8 `state.terminal` accesses in `updateFrame` (`src/renderer/generic.zig:1177-1262`) are
  all satisfied from the frame: 6 reads become RenderState/header reads; the 2 writes are
  gone (host-side per §1.1). `RenderState.update` (`render.zig:263`) is no longer called
  GUI-side — the mirror is populated by frame decode instead.
- `rebuildCells`/`rebuildRow`/`addGlyph`/`addCursor`/`cursorStyle`/font-shaper: **no change**
  (they already read `self.terminal_state`).

### 3.3 Host process (Zig, new)

Files: `build.zig` (new target), new `src/host/` tree (e.g. `src/host/main.zig`,
`src/host/Server.zig`, `src/host/Session.zig`, `src/host/protocol.zig`).

- New build target sibling to `libghostty-vt` (`build.zig:116-160`) producing `ghostty-host`,
  linking the core but **not** running GPU draw and **not** instantiating `src/apprt/embedded.zig`.
- Per session, issue the `Termio.init` call shape from `src/Surface.zig:683-693`, substituting
  a **host-side render sink** for the three things `Termio` requires
  (`src/termio/Termio.zig:44,48,51`):
  - `renderer_state: *renderer.State` — a **real** `renderer.State{ .mutex=heap std.Thread.Mutex,
    .terminal=&session.terminal, .inspector=null }`.
  - `renderer_wakeup: xev.Async` — `xev.Async.init()`; its wait-callback is the literal
    `queueRender` target (`src/termio/stream_handler.zig:104`) and runs the host's
    snapshot/diff/push-to-clients logic (the renderer-thread replacement, proven GPU-free).
  - `renderer_mailbox: *renderer.Thread.Mailbox` — a stub `BlockingQueue(renderer.Message, 64)`
    the host drains, handling **exactly two** message kinds: `.resize` (`Termio.zig:501`) and
    `.reset_cursor_blink` (`Termio.zig:668`). The complete live emit set —
    `StreamHandler.rendererMessageWriter` is **dead code** (zero call sites), so StreamHandler
    pushes no renderer messages.
- Also supply an `App.Mailbox`-shaped `BlockingQueue` the host drains for the
  `apprt.surface.Message` set → forwarded as `SurfaceEvent` frames.
- Run `termio.Thread`'s `libxev` loop on the host IO thread as today.
- **Hard host invariants:** `renderer_state.inspector` stays `null`; never call any
  `embedded.App`/`embedded.Surface`/`Inspector` method (those link objc/Metal/CGS that must
  stay unexecuted — the full-suite trace showed `IOSurfaceCreate`/CGS-blur at 0 hits and
  Metal device init dead-stripped). At port time, confirm no new `Termio` push beyond
  `{.resize, .reset_cursor_blink}`.
- **Relocate the search `Thread` from GUI to host (real refactor, not a passive move).**
  Today the search thread is **owned by the GUI `Surface`**: the field `state: terminal.search.Thread`
  is declared at `src/Surface.zig:200`, the thread is spawned via `terminal.search.Thread.threadMain`
  at `src/Surface.zig:4982`, and its results land through `searchCallback`
  (`src/Surface.zig:1427`, event type `terminal.search.Thread.Event` at `:1440`). The thread
  holds a `*Terminal`, so it **must** move to wherever the `Terminal` lives — i.e. into the
  host `Session`. Work items: (a) move the `terminal.search.Thread` field + spawn + lifecycle
  (init/deinit, the libxev async wakeup) out of `src/Surface.zig` and into the host `Session`
  struct, parented to the same host `Terminal`/mutex; (b) the host sets `search_viewport_dirty`
  host-internally (never on the wire); (c) the GUI's search **commands** (start/next/prev/clear,
  the inputs that today drive `searchCallback`) become typed GUI→host requests, and the host
  re-emits match state as **highlights on `RenderState` rows** (`src/terminal/render.zig:197-206,651`)
  that ship inside the normal GridFrame — so the GUI's existing highlight-render path is reused
  unchanged and no bespoke search wire frame is needed. This is the one nontrivial ownership
  relocation in the GUI→host split; budget it as Phase-3 work alongside the other cross-boundary
  events (§4) and cover it with the search-in-TUI matrix entry.
- Session registry: `session_id → Session{ Termio, child pid, renderer.State, subscriber
  socket(s) }`. The host's `libxev` loop already multiplexes N termio threads in one process;
  N sessions is the same model minus N renderers.
- Transport server: listen on the per-identity AF_UNIX path (§3.6); accept GUI connections;
  frame-route by `session_id`.

### 3.4 apprt / C-ABI plumbing for attach token (Zig + C + Swift)

Files: `include/ghostty.h`, `src/apprt/action.zig`, `src/apprt/embedded.zig`, `src/Surface.zig`.

- Thread an `attach`/`session_id` field through the same chain `initial_input` uses:
  `ghostty_surface_config_s` (header) → `apprt.Surface.Options` (`src/apprt/embedded.zig:425`)
  → applied in `Surface.init` → branch the backend at `src/Surface.zig:687` (`.client` when a
  live `session_id` is present, else `.exec`). The token is opaque — it skips the
  WorkingDirectory normalize/validate path, which is correct (no validation pitfalls).

### 3.5 Reattach-by-session-id via restorable state (Swift)

Files: `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`,
`macos/Sources/Features/Terminal/TerminalRestorable.swift`,
`macos/Sources/Features/Terminal/TerminalRestorableState+InteralState.swift`,
`macos/Tests/Terminal/TerminalRestorableTests.swift`.

- Carry the host `session_id` as an **optional `sessionID` CodingKey on `SurfaceView`'s
  existing Codable conformance** (`SurfaceView_AppKit.swift:1821` `CodingKeys`, `:1828`
  `init(from:)`, `:1855` `encode(to:)`) — `encodeIfPresent`/`decodeIfPresent`, mirroring the
  `title`/`isUserSetTitle` pattern (`:1840-1841`). Do **not** add it to
  `TerminalRestorableState.InternalState` (per-window, wrong scope) and do **not** touch
  `SplitTree`'s Codable (it delegates to the view).
- **Version migration — exact, and safe by construction.** The concrete class declares both
  literals directly in `TerminalRestorable.swift`:
  - `static var version: Int { 7 }` at **`TerminalRestorable.swift:61`** — bump this to `{ 8 }`.
  - `static var minimumVersion: Int { 5 }` at **`TerminalRestorable.swift:62`** — leave it
    untouched at `5`.

  Note on the protocol-extension default: `TerminalRestorable.swift:17`
  (`static var minimumVersion: Int { version }`) is the *protocol-extension default* — but the
  concrete `TerminalRestorableState` **overrides** it at `:62` with a hard literal `5`, so for
  this type `minimumVersion` is already **decoupled** from `version` and is **not** coupled to
  it. Editing only `:61` (version 7→8) therefore does **not** raise `minimumVersion`. The decode
  guard `current >= Self.minimumVersion` (`TerminalRestorable.swift:38`) stays `current >= 5`,
  so every existing v5/v7 archive still decodes after the bump and `sessionID` reads as nil
  (spawn-fresh) — the migration is non-corrupting in both directions (spike
  `reattach-session-id-restore`). **Do not** touch `:62`, and **do not** rely on the `:17`
  default; if a future refactor ever deletes the `:62` override, the `:17` default would couple
  `minimumVersion` to `version` and silently discard all v5/v7 archives on the first GUI upgrade
  — the exact survival event this project exists to support — so the `:62` literal is
  load-bearing and must remain.
- **Update the migration-acknowledgment test.** `TerminalRestorableTests.swift:9` asserts
  `TerminalRestorableState.version == 7`; change it to `== 8`. The companion assertion at
  `:10` (`minimumVersion == 5`) **stays unchanged** — it is the regression guard that proves the
  bump did not raise `minimumVersion`. Add a v8 base64 fixture (generate via the commented
  archive helper at `:64-101`) AND keep the existing v5/v7 fixtures (`v5Data`/`v7Data`/
  `v7GenericData`, `:201-215`) so the `restoreTerminal57` test continues to prove old archives
  still decode after the bump.
- On decode, `SurfaceView.init` reads `sessionID` and passes it into `SurfaceConfiguration`
  before `withCValue`/`ghostty_surface_new`. A null/unknown/GC'd `session_id` ⇒ spawn fresh
  (the `ghostty_surface_new`-returns-null fallback at `SurfaceView_AppKit.swift:354-356`),
  degrading to today's layout-only restore. The migration is provably non-corrupting in both
  directions (spike `reattach-session-id-restore`).
- **session_id generation**: assigned host-side on spawn, surfaced back to the GUI in
  `Attached { session_id }` so the GUI can store it in the archive.

### 3.6 launchd lifecycle + per-identity socket namespacing (config/scripts)

Files: a new `LaunchAgent` plist per identity (not in tracked source; install under
`~/Library/LaunchAgents/`), referenced by build/install docs; host code reads the socket fd
from launchd.

- Per-identity `LaunchAgent` label `com.mitchellh.ghostty-ramon.host` (and `.local.host`,
  `.debug.host`), with `RunAtLoad` + `KeepAlive`, and the **listening socket passed via the
  `Sockets` key** so there's no cold-start connect race. The host outlives every GUI.
- Socket path keyed by the **runtime bundle id** (same pattern `DockTilePlugin.swift` uses):
  `$(getconf DARWIN_USER_TEMP_DIR)/ghostty-host-<bundleid>.sock` (or
  `~/Library/Application Support/<bundleid>/host.sock`). Release / ReleaseLocal / Debug each
  get their own host + socket, so iterating the GUI never touches the Release host's sessions.
- A `ghostty-host` CLI subcommand to list/kill orphan sessions (§4.8).

### 3.7 Single-instance interaction (Swift, host)

- The existing GUI single-instance guard
  (`AppDelegate.applicationWillFinishLaunching`, per bundle id) is **unaffected** — it guards
  GUI instances. The host gets its own discipline: launchd guarantees one host per label;
  additionally the host fail-binds the socket / `flock`s a lockfile. GUI and host
  single-instance are orthogonal.

---

## 4. Cross-boundary handling

### 4.1 Input (encode GUI-side; mode mirror mandatory)
Key/text/IME encoding stays GUI-side (`src/apprt/embedded.zig:180,901,1828`) — it needs
focus/layout/IME. But encoding reads live terminal modes, so the GUI keeps a small **mode
mirror** fed by `ModeFrame` (§2.1, in-band, stream-ordered). `key_encode.fromTerminal`
(`src/input/key_encode.zig:59`, body `:61-67`) reads seven modes; paste reads `bracketed_paste`
(`src/input/paste.zig:11`); `Surface` reads `disable_keyboard` (`Surface.zig:2694`),
`mouse_alternate_scroll` (`:3566`), `cursor_keys` (`:3573,4276-4277,4903`). Their
`fromTerminal` calls become `fromMirror` reads of the locally cached frame. **No synchronous
GUI→host→GUI round-trip exists in any input-encode path** (spike `input-mode-mirror`) —
input is effectively fire-and-forget bytes *because* the mirror is continuously updated in
stream order. `kitty_flags` are active-screen-resolved and re-emitted on alt-screen switch.
`macos_option_as_alt` stays GUI-local (layout-derived — `Surface.zig:3302`, not host state).
GUI-action bindings (splits, the fork's `swap_split`/`flip_split`/etc.) stay entirely
GUI-side; only pure terminal-input bindings encode and ship `Input` bytes.

### 4.2 Resize
GUI computes `renderer.Size` (font metrics/DPI — GUI only), sends `Resize`; host runs
`Termio.resize` (`Termio.zig:463`) → `TIOCSWINSZ` + `Terminal.resize`, pushes a `full`
`GridFrame`. `RenderState` already tolerates a 1–2 frame size mismatch (`render.zig:50-56`);
IPC widens that window, so validate the tolerance under latency (Phase 3 acceptance).

### 4.3 Focus
GUI → host `Focus` → `Termio.focusGained` (`Termio.zig:620-638`).

### 4.4 Clipboard
Request/response. Host emits `clipboard_read` (`apprt/surface.zig:32`) as a `SurfaceEvent`;
GUI reads `NSPasteboard`, replies with `ClipboardReply`; host feeds via `clipboardContents`.
`clipboard_write` host→GUI writes the pasteboard. Clipboard policy
(`clipboard_write` config, `Termio.zig:167`) stays host-side in `DerivedConfig`.

### 4.5 OSC / title / bell / notifications / pwd / color / progress / mouse-shape
All are `apprt.surface.Message` (`apprt/surface.zig:14-95`) emitted by `StreamHandler` via
`surfaceMessageWriter` (`stream_handler.zig:125`). Forward each as a `SurfaceEvent`; the GUI
re-injects into its existing handling.

### 4.6 Config reload — split the config
Host owns `Termio.DerivedConfig` (palette, cursor, clipboard policy, scrollback, image
limits — `Termio.zig:156-216`). **`scroll_to_bottom_on_output` must be RELOCATED, not assumed
present:** today it lives in the **renderer's** `DerivedConfig`, declared at
`src/renderer/generic.zig:572` and populated at `:646` from `config.@"scroll-to-bottom".output`,
and read at `:1187`. Because the scroll-to-bottom decision and `scrollViewport(.bottom)` write
move host-side (§1.1), this is a **new field to ADD to `Termio.DerivedConfig`** (and `changeConfig`)
and **REMOVE from the renderer's `DerivedConfig`** (`generic.zig:536/572/646`); the renderer no
longer reads it. GUI owns render/font/window config. The existing SIGUSR2 →
`ghostty_app_update_config` fan-out: GUI applies its half, ships the termio half via
`ConfigUpdate`, host runs `Termio.changeConfig` (`Termio.zig:421`). `changeConfig`
deliberately does **not** touch command/working-dir (`Termio.zig:441-443`) — exactly the
"never restart the child" host invariant.

### 4.7 Multiplexing N surfaces + scrollback paging
One socket per GUI process, frames tagged by `session_id`; host keeps `session_id → Termio`.
Scrollback stays host-side in `PageList`, never streamed wholesale; lazy paging via
`RequestScrollback`/`ScrollbackChunk`. Reattach recovers exactly one viewport per surface
(bounded reattach payload).

### 4.8 Reconnection + session GC + crash recovery
- GUI disconnect: host keeps draining ptys (proven OS spike). Sessions GC when (a) child
  exits AND no reattach within a grace window, or (b) explicit `Close`. A detached session
  with a live child lives forever. `ghostty-host` CLI lists/kills orphans.
- GUI crash → host + sessions intact → relaunch reattaches.
- Host crash → all sessions die (accepted; mitigate by keeping the host tiny/frozen).
- Child exit while detached: host buffers (`childExitedAbnormally`, `backend.zig:88`) and
  reports `ChildExited` on reattach.

---

## 5. session_id lifecycle (end to end)

1. GUI surface needs a session: sends `Attach { session_id? }`.
2. If `session_id` present and live → host re-subscribes the socket, pushes a `full`
   `GridFrame` + current `ModeFrame` + any buffered `ChildExited`/`ImageFrame`. If absent or
   GC'd → host spawns a fresh `Termio`/`.exec` session, assigns a new `session_id`.
3. Host replies `Attached { session_id, cols, rows }`.
4. GUI stores `session_id` on its `SurfaceView` (encoded into restorable state via §3.5).
5. On GUI relaunch (post binary swap), restorable state decodes `sessionID` → step 1 with the
   token → reattach recovers exact viewport + lazy scrollback.

---

## 6. Host-frozen / churn-in-GUI discipline

The protocol is the contract. The host is the stable tier; the GUI churns freely.

- **Versioning:** every frame carries `protocol_version` (major.minor). Handshake negotiates;
  host accepts newer-*minor* GUIs (additive fields, ignore-unknown) and refuses incompatible
  *major* cleanly.
- **Frozen surface:** the frozen host/protocol surface is exactly: the AF_UNIX framing, the
  `src/terminal/c/render.zig` field set (grid frame), the `ModeFrame` ~14-field struct, the
  `image.State` shape (`ImageFrame`), the `apprt.surface.Message` set (`SurfaceEvent`), and
  the `Termio.DerivedConfig` split. Treat these as ABI.
- **Host rebuilds are session-nuking releases** — batched and rare. Any change touching host
  emulation, the protocol schema, or `Termio` internals requires a host restart that kills
  sessions. Therefore: keep `ghostty-host` tiny; reuse core verbatim; never add a host-side
  feature that the GUI could own instead.
- **GUI changes never restart the host.** Swapping the GUI binary (the whole point) only
  drops/reopens client sockets; sessions survive. This is the project goal.
- **At every port step, re-confirm** `Termio` emits no renderer message beyond
  `{.resize, .reset_cursor_blink}` and `inspector` stays `null`.

---

## 7. Phased milestones (each independently testable)

**Incremental validation rule:** every phase keeps `.exec` fully working
(config-selectable) as a fallback so a broken host never bricks the GUI.

### Phase 1 — Headless host, no IPC
Build `ghostty-host` linking core + `Termio`/`.exec` + a real host-side `renderer.State`
(inspector=null) + stub mailboxes, driving one session, printing `RenderState` diffs to
stdout.
- Acceptance: host runs a real child shell, produces `RenderState` diffs, links **zero**
  GPU symbols at the running-code level (`IOSurfaceCreate`/CGS-blur 0 hits; Metal device
  init dead-stripped is fine — renderer/Inspector/Metal *type* machinery linking is benign,
  per the `termio-without-gpu` spike gate "no GPU code RUNS / `apprt.embedded` never
  instantiated"). No GUI changes.
- Tests (Zig, per lifecycle step 2): `zig build test -Demit-macos-app=false
  -Demit-xcframework=false -Dtest-filter=host` — add `host session spawn+diff` test;
  `RenderState round-trip (serialize→deserialize→equal)` test.

### Phase 2 — Protocol + single-session reattach
Define the framed protocol; implement `.client` for one surface; host serves it.
- Acceptance: type → child sees it → `GridFrame` back → renders identically to in-process;
  kill GUI, relaunch, reattach same `session_id`, recover viewport. Core proof.
- Tests: Zig `Binding .client backend select`; `protocol frame encode/decode` round-trip;
  Swift `SurfaceView sessionID Codable round-trip` (old→new, new→old) + v8 fixture in
  `TerminalRestorableTests` (per `reattach-session-id-restore`).

### Phase 3 — All cross-boundary events
Title/bell/clipboard/OSC/resize/focus/config-split/scrollback-paging/kitty/**mode mirror**.
- Acceptance: TUI matrix (vim, htop, tmux-inside, less, kitty-graphics demo) renders
  identically; cursor-key-mode + bracketed-paste correctness (exercises the mode mirror);
  resize tolerance holds under injected latency.
- Tests: Zig `ModeFrame ordering (DECCKM then arrow)`, `ImageFrame dedup by (id,transmit_time)`,
  `config split: changeConfig leaves command/cwd untouched`. Swift clipboard request/reply.

### Phase 4 — N surfaces + layout restore
Multiplex; wire `session_id` into restore (version 7→8); reattach a full window tree across a
GUI binary swap.
- Acceptance: a multi-split, multi-window layout reattaches all sessions after a ReleaseLocal
  GUI binary swap + relaunch; GC'd sessions degrade to spawn-fresh.
- Tests: Swift `TerminalRestorableState v8 multi-surface decode`; **a v7-archive-still-decodes-
  after-v8-bump test** (a v7 base64 fixture that must still restore with `sessionID == nil`,
  locking in the `minimumVersion`-stays-5 decoupling and preventing a regression that would nuke
  live-session restore); Zig `host registry N sessions route-by-id`.

### Phase 5 — launchd + per-identity namespacing + GC + hardening
LaunchAgent, socket-by-bundle-id, orphan management, version handshake.
- Acceptance: the end-to-end "binary swap with ~dozen live Claude trees survives" test, run
  **only on ReleaseLocal / Debug** (never the Release host). Version-mismatch handshake
  refuses cleanly.
- Tests: Zig `handshake rejects incompatible major`; `socket path per bundle id`; manual
  end-to-end survival run on ReleaseLocal.

**Build cadence per lifecycle:** after any Zig change, rebuild lib
(`zig build -Demit-macos-app=false -Doptimize=ReleaseFast`) before any app build; Swift tests
via `macos/build.nu --action test`; app build via
`macos/build.nu --configuration ReleaseLocal --action build`. Never run the install block
without explicit user confirmation; never quit the Release host.

---

## 8. Files touched (index)

Zig core:
- `src/termio/backend.zig:14-129` — `Kind`/`Backend`/`Config`/`ThreadData` add `.client`.
- `src/termio/Client.zig` (new) — `.client` backend: socket, mirror RenderState/mode/image, send/recv.
- `src/Surface.zig:616,687,1329` — drop GUI Terminal as renderer source; backend branch; process-info arm.
- `src/renderer/State.zig:14-31`, `src/renderer/generic.zig:1177-1262` — renderer reads host-supplied RenderState mirror.
- `src/host/` (new tree) — `main.zig`, `Server.zig`, `Session.zig`, `protocol.zig`.
- `build.zig:116-160` — new `ghostty-host` target.
- `include/ghostty.h`, `src/apprt/embedded.zig:425`, `src/apprt/action.zig` — attach/session_id field.
- Stabilize as protocol schema: `src/terminal/c/render.zig`, `src/terminal/render.zig:49`, `src/renderer/image.zig:18`, `src/apprt/surface.zig:14-95`, `src/termio/Termio.zig:156-216` (DerivedConfig).
- Relocate GUI→host (real refactor): `src/terminal/search/Thread.zig` — currently owned by the GUI `Surface` (field `src/Surface.zig:200`, spawn `:4982`, callback `:1427/1440`); move field+spawn+lifecycle into the host `Session` (see §3.3).

Swift macOS:
- `macos/.../SurfaceView_AppKit.swift:1821-1861` — `sessionID` CodingKey; `:354-356` spawn-fresh fallback.
- `macos/Sources/Features/Terminal/TerminalRestorable.swift:61` — bump `version` `{ 7 }`→`{ 8 }`; **leave `minimumVersion { 5 }` at `:62` untouched** (it is the load-bearing decoupling literal; do not rely on the `:17` protocol default).
- `macos/Sources/Features/Terminal/TerminalRestorableState+InteralState.swift` — (only if a per-window field were ever needed; `sessionID` goes on `SurfaceView`, not here).
- `macos/Tests/Terminal/TerminalRestorableTests.swift:9` — assert `version == 8`; keep `:10` `minimumVersion == 5`; add a v8 fixture; keep v5/v7 fixtures so old archives still prove-decode.
- New per-identity `LaunchAgent` plists (installed, not tracked).

---

## 9. Residual risks (carried from the spikes, with mitigations)

1. **Byte-identical GPU cells** depend on font shaping + atlas being identical GUI-side
   (`renderstate-as-wire-protocol`). Reasoned from source, not run end-to-end against the
   built renderer; shaping/atlas already run GUI-side from the same three `Cell` fields, so
   identical font config + RenderState ⇒ identical output by construction. *Mitigation:*
   Phase-3 TUI matrix is a visual diff against in-process `.exec`.
2. **Future RenderState pointer fields.** Only `grapheme` is a pointer today and it's
   arena-duplicated (`render.zig:530`). *Mitigation:* the serializer asserts pointer-free
   projection; a CI test fails if a new non-bitcast field appears in the C ABI schema.
3. **Kitty graphics bandwidth/backpressure.** Storage cap 320 MB
   (`graphics_storage.zig:61`). *Mitigation:* dedup blobs by `(image_id, transmit_time)`
   (renderer already keys re-upload on transmit_time, `image.zig:534`); diff placement tuples;
   keep the image channel lazy/out-of-band with its own backpressure.
4. **Virtual-placement frequency.** `kitty_virtual` forces placement re-emit on every grid
   change while any virtual placement exists. *Mitigation:* re-ship tuples (not pixels), diffed.
5. **Perf is component-level, not end-to-end Metal frame latency** (`grid-over-ipc-perf`).
   IPC is ~0.5–1% of the 8 ms budget even at pessimal full-frame-every-tick across 12
   surfaces. *Mitigation:* real-host concurrency (12 independent sockets + xev loop) is the
   one unmodeled factor; total per-tick work is fixed at ~0.05 ms, so headroom absorbs it —
   re-measure in Phase 2/3 on the built app.
6. **Resize size-mismatch window widens under IPC** (`render.zig:50-56` tolerates 1–2
   frames). *Mitigation:* validate under injected latency in Phase 3; host can withhold
   frames during an in-flight resize.
7. **Host crash kills all sessions** (accepted trade-off of emulation-on-host). *Mitigation:*
   keep `ghostty-host` tiny and frozen; reuse core verbatim; batch any host release as a
   rare, announced session-nuking event (§6).
8. **IME/preedit-commit path mode reads** not fully confirmed beyond `bracketed_paste`
   (`input-mode-mirror`; `textCallback→completeClipboardPaste`, `Surface.zig:3313-3318`). It
   routes through the same `paste.encode`, so it appears covered. *Mitigation:* a final
   source glance + a Phase-3 IME paste test.
9. **No new `Termio` renderer-message push** must hold over time (only `.resize`,
   `.reset_cursor_blink` today; `rendererMessageWriter` is dead). *Mitigation:* a Zig test
   that greps/asserts the renderer-mailbox push set at the host boundary.

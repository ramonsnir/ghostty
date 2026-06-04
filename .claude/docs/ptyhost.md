# Notes: PTY-host (emulation-on-host) for the macOS fork — Phase 2b

Handoff notes for a session resuming the PTY-host work cold. Audience: an
engineer who needs to rebuild context and continue. Branch: **`ptyhost/phase-2b`**.

## What this is, and why

A separate long-lived process — **`ghostty-host`** — owns the PTY, the child
shell, and the terminal **emulation**. The macOS GUI becomes a thin **`.client`**
that renders a host-fed *mirror* of the screen over an `AF_UNIX` socket. The goal
is that **a terminal session (live shell + screen state) survives a GUI binary
swap or restart**: quit the GUI, relaunch it, and a tab **reattaches** to its
still-running host session. This has been live-verified working for the basic
attach/reattach path; see the Status section for what is not yet done.

This is built in an **isolated git worktree** at `/Users/ramon/git/ghostty-phase2b`.
The shared checkout (`/Users/ramon/git/ghostty`, branch `ramon-fork`) is used by
other live sessions and must never be disturbed.

The original implementation plan referenced by the commit messages
(`.claude/plans/ptyhost-implementation-plan.md`, with `§1.1`, `§2.2`, `§4.7`,
`§3.6`, `§6` cross-references) is **not present in this worktree** (only
`.claude/plans/2b0-worklist.json` exists), and those `§` references are dangling.
The inline summaries in this doc and in the source comments are now the
authoritative description; do not spend time hunting for the plan file.

## Commit range

All work sits in **`eedccf9b5..5df356e80`** on `ptyhost/phase-2b`. Base
`eedccf9b5` = "bell: add fork-only bell-features-focused". To rebuild context:
`git log eedccf9b5..5df356e80` then `git show <hash>`.

| Hash | What it landed |
|---|---|
| `1b4b2306f` | Phase 1 — headless `ghostty-host` (emulation only, no IPC) |
| `810ea1d4d` | Phase 2a — framed `AF_UNIX` protocol + `Server` + reattach |
| `43cb56e55` | Cell-by-cell differential fidelity test (`.exec` RenderState vs host wire round-trip) |
| `a86e51442` | Bound the host socket-integration frame-scan loops (fail fast) |
| `c3c6a04cf` | Phase 2b-3 — Swift restorable-state `sessionID` (TerminalRestorable version 7 → 8) |
| `5e77baef6` | Slice 1 — `.client` backend variant + stub `Client.zig` |
| `701838669` | Slice 2 — real `.client` decode/rehydrate/send + `Snapshot` `row.raw` + lifecycle |
| `a92baa8e8` | Slice 3a — renderer reads the host-supplied `RenderState` mirror |
| `51dfcb667` | Slice 3b — host-side search → `row.highlights` on `GridFrame` |
| `3873da8da` | Slice 3c — host-computed OSC8 links; regex links stay GUI-side |
| `4beac4c73` | Slice 3d — reconcile mirror/link_cells lock domains (shared renderer-state mutex) |
| `9fd860def` | Slice 4 — make `.client` selectable via fork-only `pty-host` key |
| `d03e143d8` | Slice 4 fix — send `Hello` before `Attach` in `connectAndAttach` |
| `79fd86b5e` | Slice 4 perf — wake the GUI renderer on each visible frame |
| `d1e1a3db5` | Slice 5a — forward `session_id` for reattach |
| `e96a214b9` | Slice 5b — `ghostty_surface_session_id()` getter for reattach |
| `a411113ec` | Slice 5c — wire reattach `session_id` through `SurfaceView` (Swift) |
| `d15f5bdab` | Slice 5d — deliver `child_exited` so `.client` tabs close |
| `50d06e6f7` | Slice 6 — general `SurfaceEvent` channel (title/bell/clipboard/pwd/colors/notifications/…) |
| `5bd1a864f` | Slice 7 — scroll-via-host |
| `5673098ff` | Slice 8 — push `GridFrame` on cursor-only moves (cursor tracking) |
| `5df356e80` | Slice 9 — resize to authoritative wire grid (scrollback survives resize) |

## Architecture & key decisions

### Two termio backends: `.exec` and `.client`

`src/termio/backend.zig` defines two backends:

- **`.exec`** (default) — the in-process `Terminal`. This is **upstream behavior,
  byte-for-byte unchanged** when the PTY-host is not in use.
- **`.client`** (`src/termio/Client.zig`) — proxies to the host over `AF_UNIX`.

**Selection** is the fork-only config key `pty-host = <af_unix socket path>`,
consumed in `src/Surface.zig`: non-null ⇒ `.client`, null ⇒ `.exec`. The branch
happens **before** either backend is constructed.

Selection is **hard — there is no silent `.exec` fallback**. If a `.client`
connect fails, the IO thread paints a **visible error into the surface** (the
error-handling path in `src/termio/Thread.zig`'s `threadMain_`); it never quietly
forks a working local shell. A user who asked for the host and didn't get it sees
that, rather than an indistinguishable local session.

### The boundary: the renderer reads a host-supplied `RenderState` mirror

This is the central decision. The GUI renderer's source of truth under `.client`
is a host-supplied **`terminal.RenderState` mirror, not a raw `Terminal`**. The
mirror is **viewport-only by construction**.

- The renderer (`src/renderer/generic.zig`) reads the mirror; `rebuildCells` /
  font-shaping are unchanged.
- The wire payload is **`Snapshot`** (`src/host/RenderState.zig`): a
  **pointer-free** projection of `RenderState` (including `row.raw`, which the
  renderer reads). It is serialized over framed `AF_UNIX`, then **rehydrated**
  client-side back into a `RenderState` the renderer can consume.

Because the mirror is viewport-only, there is **no local scrollback buffer** on
the client (see Status: scrollback paging is not done).

### Pins can't cross the wire → host computes links & search

A `PageList.Pin` is a host pointer **into the host's `PageList`**; it cannot be
serialized. The client mirror sets it to a **poisoned sentinel**. Consequently
the renderer's pin-dereferencing paths are **gated off under `.client`** and the
host computes the results instead:

- **Search highlights**: the pin-based `updateHighlightsFlattened` path is gated
  off; the **host** computes matches and ships them as `row.highlights` on the
  `GridFrame` (Slice 3b, `src/host/Session.zig`).
- **OSC8 links**: `RenderState.linkCells` (pin-based) is gated off; the **host**
  computes OSC8 links via a `Hover` → `LinkFrame` round-trip (Slice 3c).
- **Regex links stay GUI-side** — `renderCellMap` reads cell *text*, not pins, so
  it works against the mirror without a host round-trip.

### Lock domains: one mutex for the mirror

The renderer reads the mirror under `renderer_state.mutex`; the `Client` read
thread writes it. Slice 3d reconciles these to **one lock**: the `Client` guards
its mirror with the **same `*std.Thread.Mutex`** as the renderer state, passed in
via `Client.Config.render_mutex`.

Pointer-lifetime care: the mutex and mirror pointers must reference the `Client`
at its **final address** — after `Termio.init` moves the backend union — never a
pre-move local. The wiring in `src/Surface.zig` reaches into
`self.io.backend.client` *after* the move for exactly this reason.

### The render-tick push gate (critical gotcha)

`src/host/Session.zig`'s `renderTick` is driven by a periodic poll timer
(~10 Hz) **as well as** real output, and every captured `Snapshot` is currently
`.full`. Pushing unconditionally would broadcast a full `GridFrame` + `ModeFrame`
to every subscriber ~10×/sec on a completely idle session. So the push is
**gated**:

```
if (changed > 0 or force_push or cursor_changed) { ... push GridFrame ... }
```

where `changed` = dirty rows in the diff, `force_push` = the read-and-cleared
`search_dirty` flag, and `cursor_changed` covers cursor-only moves.

**Lesson for future work: any NEW render-affecting state you add must be added to
this gate, or it will not reach the GUI.** Two existing fields illustrate the
rule:

- A pure **search** command mutates highlights but may not change cells; if the
  search is *cleared* the diff can be 0 yet the cleared frame must still ship —
  hence `search_dirty` / `force_push` (Slice 3b).
- A **cursor-only** move changes no cells; hence `cursor_changed` (Slice 8).
  Cursor change is detected by `Snapshot.cursorEql` in
  `src/host/RenderState.zig`.

A freshly (re)attached GUI is unaffected by the gate: attach pushes a full frame
via `Server.pushFullFrames` independently of the tick.

### Resize to the authoritative wire grid (Slice 9 gotcha)

On resize, the host must resize to the **authoritative wire `{cols, rows}`** the
GUI sends — **not** re-derive the grid from the raw wire `screen_w`/`screen_h`.
`Resize.toSize` (`src/host/protocol.zig`) reconstructs
`screen = cols*cell + padding` so that the downstream `size.grid()` =
`(screen - padding) / cell` reproduces exactly `{cols, rows}`, while keeping the
wire cell/padding for the pixel math.

Why: the grid the GUI actually rendered at **is** `{cols, rows}` (the client
computes it via the same `size.grid()` before sending). Re-deriving from a raw,
possibly-inconsistent/transient `screen_w`/`screen_h` (a garbled mid-drag frame,
a buggy peer) yields a degenerate near-1×1 grid that **erases the terminal and
scrollback**. Driving from `{cols, rows}` makes the host authoritative-grid
driven rather than pixel-derived. `.exec`'s own resize path is untouched.

### Protocol, handshake, frozen-ABI discipline

`src/host/protocol.zig` defines **length-prefixed binary frames**. A **`Hello`
handshake is required before any stateful frame** (the Slice 4 fix `d03e143d8`
exists precisely because `Attach` was being sent before `Hello`). `Hello`
negotiates a **protocol version** (`protocol_version_major`/`minor`).

**Frozen-ABI / host-stable discipline:** the host is meant to stay **tiny and
stable** while churn happens in the GUI, because a host rebuild is a
**session-nuking event** (it kills the live shells it owns). Prefer additive,
version-negotiated protocol changes; avoid forcing host rebuilds.

### Reattach

Reattach is keyed on a host-assigned `session_id` (host ids start at **1**, so
**0 is the safe "unattached" sentinel** — `next_session_id = 1` in
`src/host/Server.zig`):

- **Forward** (GUI → host on attach): `ghostty_surface_config_s.session_id` in
  `include/ghostty.h`, plumbed via `src/apprt/embedded.zig`
  (`Options.session_id`).
- **Reverse** (read the current id back): `ghostty_surface_session_id()` in
  `include/ghostty.h` / `src/apprt/embedded.zig`; the Surface-side getter lives
  in `src/Surface.zig` (returns 0 for `.exec` or an unattached `.client`).
- **Swift**: `sessionID` is `Codable` and persisted via macOS restorable state —
  `TerminalRestorable` version was bumped **7 → 8**
  (`macos/Sources/.../SurfaceView.swift` / `SurfaceView_AppKit.swift`). On
  relaunch the GUI replays the persisted `session_id` to reattach.

### SurfaceEvent channel (Slice 6)

The host forwards the `apprt.surface.Message` set over a single host → GUI
**`surface_event`** frame; the `Client` re-injects each into its
`surface_mailbox` so the GUI handles them exactly as it would under `.exec`.
Covered: `set_title`, `ring_bell`, `clipboard_read`/`clipboard_write`,
`pwd_change`, `color_change`, `desktop_notification`, `progress_report`,
`set_mouse_shape`, `password_input`, command-tracking
(`start_command`/`stop_command`), `report_title`.

Two carve-outs:

- **`child_exited` has its OWN dedicated `ChildExited` frame** (Slice 5d), which
  also drives render-stop and detach-buffering. **Do not double-forward it via
  `surface_event`.**
- **Responses** for `clipboard_read` and `report_title` ride the existing
  **Input** channel (the surface's normal termio reply path) — no separate reply
  frame.

## Components & where things live

**Host** (`src/host/`):

| File | Role |
|---|---|
| `main.zig` | Entry point; `--listen=<path>` |
| `Server.zig` | `AF_UNIX` listener + session registry (`session_id → Session`) + subscriber routing |
| `Session.zig` | One session: Termio + Exec + Terminal + `renderTick` (the push gate) |
| `RenderState.zig` | `Snapshot` + serialize/deserialize/rehydrate; `cursorEql` / `eqlRenderState` |
| `protocol.zig` | Frames, `Hello`, `Resize.toSize`, version constants |
| `difftest.zig` | Cell fidelity test |
| `test.zig` | Host socket integration + reattach tests |

Built via the **`ghostty-host`** target in `build.zig` (native-only gated).

**Client** (`src/termio/`): `Client.zig` (the `.client` backend), plus
`backend.zig` (the `.exec`/`.client` union) and `client_difftest.zig`.

**Core wiring**: `src/Surface.zig` (backend selection on `pty-host`; mirror/mutex
wiring after the backend move; `scroll_*` handlers; `session_id` getter),
`src/renderer/generic.zig` (reads the mirror; pin paths gated under `.client`),
`src/config/Config.zig` (the fork-only `pty-host` key).

**C-ABI / apprt**: `include/ghostty.h` (`session_id` field +
`ghostty_surface_session_id`), `src/apprt/embedded.zig` (forward + reverse).

**macOS**: `SurfaceView.swift` / `SurfaceView_AppKit.swift` (`sessionID` Codable,
`TerminalRestorable` v7 → v8).

## Build, run, test, smoke

> **Build / run only in the `/Users/ramon/git/ghostty-phase2b` worktree.** Never
> touch `/Users/ramon/git/ghostty`. **Never quit or launch the installed Release
> fork (`com.mitchellh.ghostty-ramon`)** — it normally hosts the working shell
> session. Use the **ReleaseLocal** identity ("Ghostty (ramon-local)", bundle id
> `com.mitchellh.ghostty-ramon.local`) for dev.

### Tests (fast, no app)

```sh
zig build test -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=<host|client|render|config>
```

- **Cell fidelity** (mirror == in-process `.exec` RenderState, including negative
  perturbations): `src/host/difftest.zig`, `src/termio/client_difftest.zig`.
- **Host socket integration + reattach**: `src/host/test.zig`.

### Build (lib + host)

```sh
zig build -Demit-macos-app=false -Doptimize=ReleaseFast
# rebuilds the ghostty-host binary into zig-out/bin/ghostty-host
```

### Build the macOS app (ReleaseLocal)

```sh
macos/build.nu --configuration ReleaseLocal --action build
# -> macos/build/ReleaseLocal/Ghostty.app
```

### Codesign (gotcha)

`build.nu`'s own codesign step **fails on xattr detritus**. After building, run:

```sh
APP="macos/build/ReleaseLocal/Ghostty.app"
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
```

### Smoke (human, ReleaseLocal)

Run the **Build (lib + host)**, **Build the macOS app**, and **Codesign** blocks
above first, then:

1. Start the host: `./zig-out/bin/ghostty-host --listen=/tmp/ghostty-host.sock`
2. Put `pty-host = /tmp/ghostty-host.sock` in `~/.config/ghostty-ramon/config`
   (fork-only key; keep it out of the shared `~/.config/ghostty/config`).
3. Launch the **ReleaseLocal** "Ghostty (ramon-local)" dev app. A new tab should
   come up as a `.client` rendering the host-fed mirror (typing, output,
   resize, scroll all routed through the host). A connect failure paints a
   visible error into the surface — it must **never** fall back to a local shell.

### Reattach smoke (the headline feature)

This is the value proposition (session survives GUI restart) and is the most
important thing to re-verify when resuming:

1. With the host running and `pty-host` set (as above), launch ReleaseLocal and
   open a tab.
2. In that tab, start a **long-lived, observable** command, e.g.
   `sleep 9999 & echo MARKER-$$` or a `vim`/`top` session, so you can tell the
   *same* process survived.
3. The tab's `session_id` is auto-persisted via restorable state (v8); you can
   also observe it through `ghostty_surface_session_id()`.
4. **Quit ONLY the ReleaseLocal GUI** (`tell application id
   "com.mitchellh.ghostty-ramon.local" to quit`) — never the installed Release.
   Leave `ghostty-host` running.
5. **Relaunch ReleaseLocal.**
6. **Pass:** the tab reattaches to the **still-running** host session — the
   marker process is alive (the `sleep`/`vim`/`top` is exactly the one from
   before), the screen state is intact, and the shell continues. **Fail:** a
   fresh shell (new PID, blank state), or a visible connect error.

## Status: open items & next steps

- **cwd-inherit on new tab + shell command-tracking are BROKEN under `.client`.**
  The host's shell has no shell integration ("shell could not be detected"), so
  no OSC 7 pwd updates and no command marks. **Next up:** make the host inject
  shell integration the way `.exec` does.
- **Scrollback paging is NOT done.** The mirror is viewport-only and scroll is a
  host round-trip (Slice 7), so there is no local scrollback buffer; smooth
  scrolling and select+copy across history are limited. The `scroll_to_row`
  (`.row` index) and `scroll_to_selection` (`.pin`) handlers in `src/Surface.zig`
  are **not no-ops** — they lock the renderer mutex, scroll, and `queueRender` —
  but under `.client` they are **ineffective**: they scroll the host-fed mirror,
  which the host **overwrites on the next `GridFrame`**. Neither target fits
  Slice 7's viewport-only `ScrollViewport` union (`top`/`bottom`/`delta`);
  carrying row/pin scrolls to the host is future work.
- **Resize residual edge.** A transient wire `cols`/`rows` == 0 could still
  `toSize` → grid 0 (`toSize` guards a 0 *cell* but not 0 cols/rows). Minor
  follow-on; the normal resize-erases-content bug was fixed in Slice 9.
- **`cursorEql` omits `cursor_style`.** In `src/host/RenderState.zig`,
  `cursorEql` compares `cursor_visual_style` (the `.block`/`.bar`/`.underline`
  enum) but **omits** the separate `cursor_style` POD (`StylePod`) that the full
  `eqlRenderState` checks. Harmless in practice: `cursor_style` only changes
  alongside a cell/position change that already trips the push gate, and it is
  carried in the snapshot, so the mirror is never wrong. The only un-pushed case
  would be a hypothetical cursor-only fast-path push with a pure style-only delta
  and identical `visual_style`, which does not occur today. Worth tightening if a
  cursor-only push path is ever broadened.
- **Desktop notifications WORK** — they only needed the macOS notification
  permission granted to the dev app (not a code bug).
- **Host lifecycle is manual.** launchd lifecycle, per-identity socket
  namespacing, orphan GC, and a fuller version handshake are NOT done; the host
  is started by hand for now.
- **Re-smoke pending.** Slices 6–9 need a live re-smoke; Swift app-hosted unit
  tests are deferred to the human smoke.
- **Debugging practice.** Bugs in the push gate or the resize grid derivation are
  best confirmed by **reproducing the gate / derivation behavior before fixing**
  (both the cursor-not-moving and resize-erases-content bugs were gate/derivation
  shaped and only obvious once reproduced).

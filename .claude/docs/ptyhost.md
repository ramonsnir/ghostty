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

All work sits in **`eedccf9b5..040cb33ca`** on `ptyhost/phase-2b`. Base
`eedccf9b5` = "bell: add fork-only bell-features-focused". To rebuild context:
`git log eedccf9b5..040cb33ca` then `git show <hash>`.

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
| `30d8d8707` | Slice 10 — `finalize()` the host session config (login shell + shell-integration resolve) |
| `086980e09` | Slice 11 — cwd-inherit: carry `working_directory` through the `.client` spawn |
| `4cc4320f4` | Slice 12 — drop the degenerate reattach Resize so scrollback survives |
| `805cbe7eb` | Phase A — apply the host `ModeFrame` onto the `.client` local terminal (TUI input: arrows/paste/mouse) |
| `07da2b0b9` | Phase B1 — host-authoritative drag-select + copy under `.client` |
| `e4a8e0927` | Reattach-scrollback #1 — force-push the `GridFrame` on explicit scroll/jump (`viewport_dirty`) |
| `040cb33ca` | Reattach-scrollback #2 — saturating `remaining_rows` in `PageList.resizeCols` (host crash on reattach resize-flood) |

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

### Drop the degenerate reattach Resize (Slice 12 fix)

**Bug (tab-dependent, live smoke):** after a GUI quit + relaunch (reattach), the
shell process + state survived on ALL tabs, but the terminal **scrollback was
lost on some tabs** — observed lost on the first/heaviest tab (~200 lines, had
been resized during the session) and preserved on two others. Root cause: on
reattach the GUI can momentarily report a **0 / near-0 grid** for a restored tab
before layout/font-metrics settle (tab-dependent restore timing — active vs
background tabs are sized at different moments). The Slice-9 fix made the host
authoritative-grid driven off the wire `{cols, rows}`, but `Resize.toSize` only
guards `cell==0`, **not `cols==0`/`rows==0`** — so a degenerate frame still
flows through. `size.grid()`'s `@max(1,…)` floor (`src/renderer/size.zig:260-261`)
then resolves `{0,0}` to a **1×1 collapse grid**, and `terminal.resize(1,1)`
against real history doesn't merely discard scrollback — it **panics with
integer overflow in `PageList.resizeCols`**.

**Fix:** `Server.dispatch`'s `.resize` arm DROPS a degenerate frame (logged at
debug) before queueing it to Termio — a terminal is never legitimately tiny, and
the next well-formed Resize carries the real restored size. Dropping the frame
(vs clamping) is cleanest: it never touches the terminal, so no reflow/discard.

The guard gates on the **RESOLVED grid** — the `(cols,rows)` Termio.resize will
actually apply via `Resize.toSize().grid()` — against the GUI's OWN minimum
terminal size, `CoreSurface.min_window_{width,height}_cells` (10x4,
`src/Surface.zig`), which every apprt embedder enforces as the minimum window
size. A resolved grid below that floor is, by the app's own definition, not a
legitimate terminal; it can only be a transient/garbled reattach frame.

**Why resolved, not the raw wire value (MF-1):** an earlier cut gated on
`resize.cols == 0 or resize.rows == 0`, catching only a literal `{0,0}` frame.
But `size.grid()`'s `@max(1,…)` floor (`src/renderer/size.zig:260-261`) maps
`{0,0}` to a 1x1 collapse grid, and a wire `{1,1}` (or `{1,24}`/`{80,1}`, both
dims nonzero) sails straight through the wire-only guard to the SAME
`PageList.resizeCols` underflow panic (`self.rows - cursor.y - 1`) once a column
shrink triggers reflow with real history present. Empirically confirmed: with
the wire-only guard, a wire `{1,1}` reattach transient aborts the IO thread with
`thread … panic: integer overflow` at `src/terminal/PageList.zig:1062`.
Resolving first and gating against the 10x4 floor closes that gap — every
degenerate transient (`{0,0}`, `{1,1}`, `{1,24}`, `{80,1}`) resolves below the
floor and is dropped. Well-formed frames (>= the floor in both dims, e.g.
`80x50`, `100x50`) are unaffected and still apply the authoritative wire grid,
so Slice 9 is not regressed. `.exec` untouched.

**Repro (fail-before/pass-after, real host path):** `src/host/test.zig` →
`"host reattach: degenerate-then-real Resize preserves scrollback (Slice 12)"`.
It stands up `Server.init` + `start`, attaches a client, feeds 120 lines into
the **live** session terminal (so ~96 land in scrollback), then sends the
reattach transient as wire frames through `clientSend(.resize)` →
**`Server.dispatch`** → Termio mailbox → live terminal: FIRST a sequence of
degenerate frames (`{0,0}`, `{1,1}`, `{1,24}`, `{80,1}`), THEN the real `80×50`.
It reads back off the live session and asserts (a) the grid is `80×50` (no
degenerate frame was ever applied) and (b) `"L000"` survived. **Confirmed
fail-before:** with the guard reverted to the wire-only form
(`if (resize.cols == 0 or resize.rows == 0)`) and the lib rebuilt,
`-Dtest-filter="degenerate-then-real"` aborts with
`thread … panic: integer overflow` raised on the IO thread at
`src/terminal/PageList.zig:1062` (`terminal.resize(1,1)` → `PageList.resizeCols`
underflow) — triggered by the wire `{1,1}` case, which the wire-only guard lets
through (MF-1). With the resolved-grid guard restored the test passes. The test
drives the PRODUCTION guard, not a copy — reverting `Server.zig` alone flips it
red. A companion `"… well-formed resize preserves scrollback + applies wire
grid (Slice 9 guard)"` test drives a legit `80×10`→`100×50` shrink-then-grow
through the same real path and asserts both the authoritative grid and `"L000"`
survive, locking in that the guard does not regress well-formed frames.

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

> **RESUME SNAPSHOT (crash-survival; update when state changes).**
> - **HEAD:** `040cb33ca` (code) / `59fb43fed` (docs) on branch `ptyhost/phase-2b`
>   (working dir `~/git/ghostty-phase2b`, a worktree separate from the shared
>   `~/git/ghostty`).
> - **DONE + live-smoke validated:** Phases 1, 2a, 2b-1 (all slices incl.
>   resize/cursor/SurfaceEvent/scroll/cwd-inherit/Slice-12), Phase A (TUI input),
>   Phase B1 (drag-select + copy), and the reattach-scrollback bug (BOTH
>   mechanisms — push-gate `e4a8e0927` + `resizeCols` crash `040cb33ca`). Reattach
>   is responsive AND shows scrollback.
> - **NEXT (per remediation plan):** Phase B2 (word/line/select-all selection) →
>   Phase C (history transport — needed only for history-spanning ops, NOT
>   reattach scrollback) → Phase D (R1 tail: reset, ⌘K clear, cursor-click-to-move,
>   IME anchor, accessibility geometry).
> - **To resume building:** edit Zig in `src/`, macOS in `macos/Sources/`; then
>   `zig build test -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=<name>`
>   → `zig build -Demit-macos-app=false -Doptimize=ReleaseFast` (rebuild lib) →
>   `macos/build.nu --configuration ReleaseLocal --action build` → sign + restart
>   the DEV app (NEVER the installed Release host). See "Build, run, test, smoke".
> - **Smoke harness:** dev host runs as `ghostty-host --listen=/tmp/ghostty-host.sock`
>   (log `/tmp/ghostty-host.log`); GUI launched with `--config-file=/tmp/ptyhost-smoke.conf`
>   (which sets `pty-host` to select the `.client` backend). Both are the
>   ReleaseLocal identity — safe to quit/relaunch; the installed Release fork
>   hosting this session is NOT.

> **Remediation plan:** the audit's 37 gaps are sequenced into a phased program
> (A: consume the ModeFrame mirror → B: host-authoritative selection/copy →
> C: history transport → D: the R1 tail) in
> **`.claude/docs/ptyhost-remediation.md`** — read it to decide what to fund.
> Phase A + B1 are DONE; the reattach-scrollback bug (once filed under C) is
> RESOLVED and was NOT R3.

> **META (read this first): `.client` systematically breaks every GUI feature
> that reads or writes the in-process `io.terminal` / `core_surface`.** The real
> terminal lives host-side; the GUI holds only a viewport `RenderState` mirror.
> So any feature whose GUI code path touches the local terminal — links, search,
> pwd/cwd-inherit, selection, … — is inert or wrong under `.client` until it is
> explicitly re-routed (host-computed, or GUI-against-the-mirror). These have
> been found reactively via smoke; **a systematic audit of all
> `io.terminal`/`core_surface` consumers is needed so the rest are found
> proactively** (see "Selection" + the audit task below). Do not assume an
> untested GUI feature works under `.client`.

- **Selection + copy BROKEN under `.client` (mouse).** Mouse drag sets the
  selection on the GUI's LOCAL `io.terminal` (`Surface.zig` `screens.active.select`),
  but the renderer draws `row.selection` from the host-fed mirror (empty — the
  host has no mouse), so NO highlight shows; and `selectionString`
  (`Surface.zig:2205`) reads the local terminal, which has no cell content under
  `.client`, so copy yields nothing. Two designs: (A) apply the selection as a
  GUI-side highlight on the mirror rows + extract copy text from the mirror cells
  (viewport-scoped); (B) round-trip selection coords to the host (handles
  scrollback). NOT YET BUILT — substantial slice.
- **SECOND reattach scrollback-loss path (distinct from Slice 12): RESOLVED
  (`e4a8e0927` + `040cb33ca`).** It was TWO independent mechanisms, neither R3:
  **(1)** the render-tick push gate (`Session.zig`) suppressed the post-reattach
  scroll's `GridFrame` when the scrolled rows matched a stale `prev_snapshot`
  (`pushFullFrames` doesn't update it) — fixed by a `viewport_dirty` force-push set
  in `scrollViewport`/`jumpToPrompt`, consumed in `renderTick` (toggle-proven via
  the `2nd mechanism repro` host test). **(2)** the GUI's post-reattach resize-flood
  drove a shrink-cols+shrink-rows resize whose OLD cursor `y` exceeded the new row
  count, underflowing `PageList.resizeCols` (`self.rows - c.y - 1`) and CRASHING
  THE WHOLE HOST — every session down (the "all tabs frozen" symptom) — fixed by
  saturating subtraction `self.rows -| c.y -| 1` (reproduce-first Screen test
  panics at `PageList.zig:1062` pre-fix, passes post-fix; full resize/reflow corpus
  green). Both live-smoke validated: reattach is responsive and shows scrollback.
- **TASK — systematic `.client` feature audit (proactive, not reactive).**
  Enumerate every consumer of `io.terminal` / `self.renderer_state.terminal` /
  `core_surface.*` in `src/Surface.zig`, `src/apprt/embedded.zig`, and the macOS
  apprt; classify each as works-under-`.client` / broken / already-re-routed
  (links 3b/3c, pwd Slice 10+pwd-sync, child_exit 5d, scroll 7). Output a
  prioritized gap list so features are fixed before a user hits them.

- **cwd-inherit / shell command-tracking under `.client`: FIXED + live-smoke
  validated** (new tab opens in the source tab's cwd). Was broken because
  `src/host/Session.zig`
  used `Config.default()` (which does NOT call `finalize()`), leaving `command`
  null → `Exec` fell back to a bare `sh` → `shell_integration.setup`'s `.detect`
  couldn't classify it → nothing injected → no OSC 7 pwd / command marks. Fix:
  `Session.create` now calls `config.finalize()` after `Config.default()`, which
  resolves the user's login shell (the passwd/`$SHELL` branch). Verified
  empirically: the host log flipped from `shell could not be detected` to
  `default shell source=env value=/bin/zsh` + `shell integration automatically
  injected shell=.zsh`. The end-to-end cwd-inherit-on-new-tab still needs a GUI
  smoke to confirm OSC 7 actually drives the GUI's new-tab cwd.
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
- **Scrollback lost on reattach, tab-dependent (FIXED, Slice 12).** In a 3-tab
  reattach smoke: shell state (a marker var) survived on ALL tabs, but
  **scrollback was lost on 1 tab (the first/heaviest — had ~200 lines + had been
  resized during the session) and PRESERVED on the other two.** Root cause was
  the Slice-9 residual: a **transient degenerate reattach Resize** (wire
  `cols==0`/`rows==0` for a tab whose layout hadn't settled) resolved
  (toSize→grid, `@max(1,…)` floor) to a 1×1 collapse grid and `terminal.resize`
  underflow-panicked / discarded scrollback. **Fixed** by dropping degenerate
  frames in `Server.dispatch` — see "Drop the degenerate reattach Resize (Slice
  12 fix)" above for the mechanism, the fix, and the fail-before/pass-after repro
  (driven through the real `Server.dispatch` path; confirmed to panic pre-fix).
- **Live re-smoke status:** Slice 8 (cursor tracks arrow keys) and Slice 9
  (resize preserves scrollback/content, in-session) VERIFIED live. Slice 10
  (shell integration injected) verified at the host log. Title is dynamic (zsh
  shell-integration OSC → SurfaceEvent → GUI), confirming Slice 6 forwarding +
  Slice 10 together. Reattach: shell state survives (see the tab-dependent
  scrollback bug above). Swift app-hosted unit tests still deferred to the human
  smoke.
- **Debugging practice.** Bugs in the push gate or the resize grid derivation are
  best confirmed by **reproducing the gate / derivation behavior before fixing**
  (both the cursor-not-moving and resize-erases-content bugs were gate/derivation
  shaped and only obvious once reproduced).


---

# .client Feature Audit — Prioritized Gap Report

This audits GUI-side feature paths under the `.client` backend. The renderer draws the **host-fed mirror** at `renderer_state.mirror`; the local `renderer_state.terminal` aliases `&self.io.terminal` (`src/Surface.zig:616`) and is **never fed VT** — the real terminal lives in ghostty-host. Every BROKEN/UNSURE item below stems from one of **three roots**:

- **(R1) Unfed-local-terminal read** — code reads `self.io.terminal` / `renderer_state.terminal` for content/state that only exists host-side.
- **(R2) ModeFrame mirror decoded-but-unconsumed** — the host ships a ~14-field `ModeFrame`; `Client.mode` is set at `src/termio/Client.zig:739` but read **only** by `client_difftest.zig`. No production encode/query path applies it back to `io.terminal`, so the context's "input modes already re-routed" assumption is **not realized at this commit**. Treat all `io.terminal.modes/flags` reads in key/mouse/paste paths as currently stale.
- **(R3) Viewport-only transport (no history/scrollback on the wire)** — the `GridFrame` carries a `Snapshot` whose `row_data` is `rows`-length: "The viewport rows, top to bottom. Length == rows" (`src/host/RenderState.zig:335`; RenderState is "the viewport grid", :4, "viewport-only", :33). `pushFullFrames` (`src/host/Server.zig:1194-1232`) ships exactly that one viewport snapshot; protocol.zig:105-111 states the host "owns the real scrollback" and a scrolled viewport "arrives on the next grid_frame." **No scrollback/history rows are ever transmitted.** This is a distinct, deeper root than R1: even a GUI that re-points its reads at the mirror cannot recover history — a **new history-bearing frame/protocol does not exist** and must be built before any feature needing off-screen content can work under `.client`.

**Provenance note:** line numbers below are cited against the **dirty `ghostty-phase2b` worktree** (HEAD `5ea47fc3d` + 15 uncommitted lines in `src/Surface.zig`), not a clean HEAD. Spot-verified current positions: `mouseCaptured` at `:3917`, `selectAll()` at `:5757`, paste `.fromTerminal` at `:6163`, `hasSelection` at `:2195`, `selectionString` at `:2202`. A clean-tree checkout will shift Surface.zig cites by up to ~3 lines.

## BROKEN — High (core typing/selection/copy/reset broken in TUIs and at the prompt)

| Feature | File | Why broken | Fix direction |
|---|---|---|---|
| Key encoding application modes (DECCKM cursor_keys, keypad, **Kitty keyboard flags**, alt_esc_prefix, backarrow, modify_other_keys) | `src/Surface.zig:3431-3436` (`encodeKeyOpts` → `key_encode.Options.fromTerminal(&self.io.terminal)`); `src/input/key_encode.zig:59-72` | Main key path reads modes off the unfed local terminal (R2). cursor_keys stuck false (arrows always normal-mode ESC[A), Kitty protocol never engages, keypad/backarrow/modify_other_keys at defaults. Breaks vim/less/tmux/neovim key handling. | Apply decoded `Client.mode` (ModeFrame) onto `io.terminal.modes/flags` on each `.mode_frame` (Client.zig:737-740), or have `encodeKeyOpts` read `Client.mode` under `.client`. Data is already on the wire; only apply/read side missing. **This single wiring also fixes paste, KAM, alt-scroll, and the entire mouse-reporting cluster.** |
| Bracketed paste (ESC[200~/201~ wrapping) | `src/Surface.zig:6160-6163` (`paste.Options.fromTerminal(&self.io.terminal)`); `src/input/paste.zig:9-13` | Reads `modes.get(.bracketed_paste)` off unfed local terminal, stuck false (R2). Multi-line paste into vim/fish/bash-readline is unwrapped → each line executes / auto-indent cascades. | Same ModeFrame apply (host ships `bracketed_paste`, protocol.zig:898). |
| Mouse click/release reporting (SGR/X10 button events) | `src/Surface.zig:3816-3818` (`isMouseReporting`), `4074-4110`, `3821-3883` (`mouseReport`); `src/input/mouse_encode.zig:46-47` | `isMouseReporting()` gates on `io.terminal.flags.mouse_event != .none`, always `.none` under `.client` (R2) → click/release report never emitted. TUIs requesting mouse (vim/htop/tmux/fzf/less -X) get no events; falls through to local selection (itself broken). | Resolved by ModeFrame apply; existing `queueIo(.write_small)` already ships encoded bytes to host. |
| Mouse motion/drag reporting (button-motion 1002, any-motion 1003) | `src/Surface.zig:4784-4807`, `4543/4776`, `3888-3913` | Same root: motion report gated on stale `mouse_event=.none` (R2). Drag-to-select in mouse apps, hover tracking, button-drag all dead. | Resolved by ModeFrame apply. |
| Mouse scroll reporting + alternate-scroll (DECSET 1007) → cursor-key translation | `src/Surface.zig:3694-3764`, `3701/3744`, `3709-3711`, `3718` | Three stale reads (R2): `isMouseReporting` false (no scroll-as-button), alt-scroll branch needs `active_key==.alternate` + `mouse_alternate_scroll` (both stale, never taken), `cursor_keys` stale. Scrolling less/man/vim sends no synthetic arrows. | ModeFrame apply must cover `alt_screen_active`, `mouse_alternate_scroll`, `cursor_keys`, `mouse_event`; ensure accessor consults the mirror's `alt_screen_active` (local `active_key` is stale). |
| Mouse drag selection (left-button drag → highlight) | `src/Surface.zig:4871`, `4191/4196`, `1372` | Drag/press write `select()` to the **local** terminal (R1); renderer draws selection from the host-fed mirror (`generic.zig:2449/2491`, `terminal_state.copyFrom(mirror)` at 1229). Selection set on empty local terminal, never shipped, never in mirror → no highlight. | Make selection host-authoritative: forward gesture coords to host via new SurfaceEvent/queueIo; host runs `select()` on real terminal and ships per-row selection in GridFrame mirror. GUI gesture machinery stays GUI-side but drives a host select. |
| Select-word (double-click) / select-line (triple-click) / output-block selection | `src/Surface.zig:4145-4198`, `4191`, `selectWord 4264`, `selectLine 4496` | `press()` and word/line boundary detection run against the empty local terminal (R1); result committed to local terminal and not drawn. No highlight, no copy. | Send click pin + click-count (select-word/line/output intent) to host; host computes on real screen and ships in mirror. `selection_word_chars` travels with request or lives host-side. |
| Select All (`select_all`, Cmd-A) | `src/Surface.zig:5757` (`selectAll()`), `~5753-5762` | `selectAll()` on the empty local terminal returns null/degenerate (R1); written locally, not drawn. **Also R3**: even host-side, a true "select all" spans scrollback the GUI never receives — the host must own the result. Cmd-A shows nothing; copy yields nothing. | Host-side `select_all`: forward action, host runs `selectAll()` over its real screen+scrollback and ships selection (and, for copy, text) host-side. |
| selectionString / copy selection (Cmd-C, `copy_to_clipboard`, `copy_on_select`) | `src/Surface.zig:2202-2210`, `2493-2528`, `5189-5215`, `2370-2487`, `2388-2390` | All read `io.terminal.screens.active(.selection)`, ScreenFormatter, and colors off the empty local terminal (R1). Every format (plain/vt/html/mixed) and copy_on_select produce empty output. Clipboard **write** works; source text is empty. | Host-compute: forward copy request, host runs `selectionString`/`ScreenFormatter` with real colors/palette over the real screen, returns text via existing `clipboard_write` SurfaceEvent (Slice 6 set). |
| `read_selection` / `has_selection` (C-ABI: accessibility selected-text, copy, services) | `src/apprt/embedded.zig:1633-1653`; `src/Surface.zig:2195-2210` | C-ABI readout reads the empty local terminal selection (R1) → returns false/empty even when host has a selection. | Mirror a selection field + cached string from host; read host-supplied state under `.client`. |
| `read_text` (C-ABI arbitrary text readout, VoiceOver line/word reads) | `src/apprt/embedded.zig:1660-1708`; `src/Surface.zig:2077-2192` | `sel.core()` resolves against local active screen, `dumpTextLocked` reads `selectionString` + viewport pins from local `pages` (R1). No rows/scrollback → empty text + degenerate viewport. **R3**: any region outside the current viewport (history) is *not on the wire at all* — re-pointing reads at the mirror recovers only the visible viewport. | Resolve/dump against host (request → host `selectionString` → reply); the viewport-only mirror cannot answer history reads, so off-screen text **requires a new history-transport frame**, not just a re-point. Viewport math must derive from mirror geometry, not local pages (mirror pins are the `invalid_pin` sentinel — avoid deref). |
| Terminal reset (`.reset` / "Reset Terminal") | `src/Surface.zig:5083-5087` | `renderer_state.terminal.fullReset()` resets the empty local terminal (R1); no frame sent to host. A wedged host shell (stuck modes/scroll-regions/charset/alt-screen) is untouched — Reset does nothing. | New termio message + Client frame (`.reset`) applied to host's real Terminal; host ships fresh GridFrame/ModeFrame. `.exec` keeps local `fullReset()`. Pure GUI-side reset would be wrong (host overwrites next frame). |
| Clear screen / scrollback (⌘K, `clear_screen`) | `src/Surface.zig:5361-5376`; `src/termio/Termio.zig:546-598` | Correctly `queueIo`'s `.clear_screen`, but `Termio.clearScreen` works on the IO thread's local terminal (R1). Worse: gate at :564 (`!cursorIsAtPrompt()`) sees unfed cursor `semantic_content=.output` → "not at prompt" → **early-return at :583**, so the form-feed (:597) that nudges the host shell is never sent. ⌘K neither clears host scrollback nor repaints. | Client frame carrying clear+history intent; host runs `Termio.clearScreen` on its REAL terminal (correct `cursorIsAtPrompt`, real eraseDisplay over real scrollback, real FF), then ships GridFrame. At-prompt decision must use host state. |

## BROKEN — Medium (UI-state/correctness regressions, niche-but-real losses)

| Feature | File | Why broken | Fix direction |
|---|---|---|---|
| `mouseCaptured` / `isMouseReporting` public predicate (apprt event-routing, C-ABI `ghostty_surface_mouse_captured`) | `src/Surface.zig:3816-3818`, `3917-3921`; `src/apprt/embedded.zig:1869` | Returns `io.terminal.flags.mouse_event != .none`, stale `.none` (R2) → GUI always believes app is NOT capturing the mouse; routes gestures to (broken) local selection instead of recognizing app capture. | Resolved by ModeFrame apply (mouse_event reflects host); no signature change. |
| `hasSelection()` (Copy-menu enable / `ghostty_surface_has_selection` validate gating) | `src/Surface.zig:2195-2198`; `src/apprt/embedded.zig:1633-1636` | Reads local `selection != null`, always null (R1) → Copy menu stays disabled even when host has a selection. | Mirror a "has selection" bool from host; read it under `.client`. |
| dumpText / `read_text` viewport-rect + accessibility geometry | `src/Surface.zig:2065-2192` | `getTopLeft/getBottomRight(.viewport)` / `pointFromPin` / `pages.cols` computed on the empty/degenerate local viewport (R1) → bogus / (-1) rects to macOS accessibility. | Host-compute viewport offsets against host pagelist; map to GUI px using GUI's own size struct. |
| Alt-screen scroll → cursor-key translation (cursor_keys/mode portion) | `src/Surface.zig:3709-3718` | `active_key`/`mouse_event`/`mouse_alternate_scroll`/`cursor_keys` all read off unfed local terminal (R2); `active_key` stuck `.primary` so branch never taken — wheel in less/man/vim sends no arrows. | ModeFrame apply (alt_screen_active, mouse_alternate_scroll, cursor_keys, mouse_event). |
| Cursor-click-to-move at prompt (`cursor_click_to_move`, kitty click_events, OSC133 prompt clicks) | `src/Surface.zig:4327-4438`, call at `4067` | Operates entirely on local terminal (R1): `semantic_prompt.click` defaults `.none`, `cursorIsAtPrompt()` always false; click report + `.cl` arrow replay (reads local `cursor_keys`) all dead. Silently no-ops. | Compute click→cursor-move host-side given clicked viewport coord, or ship `semantic_prompt.click` + prompt pin on mirror so GUI computes and writeIo's arrows. Larger than a one-field fix. |
| Confirm-on-quit at a clean prompt (`confirm_close_surface=true`, `needsConfirmQuit` / `ghostty_surface_needs_confirm_quit`) | `src/Surface.zig:1057-1075`; `src/apprt/embedded.zig:1613-1616` | Reads local `cursorIsAtPrompt()`, always false on unfed cursor (R1) → `needsConfirmQuit` always true. Idle-at-prompt surface always shows close-confirmation (the mode meant to skip it). Annoyance, not data loss. | Expose host-side "cursor at prompt" on mirror/ModeFrame; read under `.client`. One bool. |
| IME preedit anchor (`ghostty_surface_ime_point` / `imePoint`) | `src/Surface.zig:2250-2253`; `src/apprt/embedded.zig:1945` | Reads local `screens.active.cursor` (R1); under `.client` cursor lives only in mirror (`Client.zig:911`), local stays at (0,0). CJK/dead-key candidate panel anchors top-left instead of at the cursor. preedit width is correct (GUI-local). | Read cursor position from `renderer_state.mirror.cursor.active/.viewport` when `mirror != null`. |
| Selection autoscroll (left-drag past viewport edge) | `src/Surface.zig:1342-1372`, `4855-4868` | `autoscrollTick` runs on local `t` and `.select()`s locally (R1); trigger is gated on local gesture state driven by an empty terminal. Even if viewport scrolls (Slice 7), the growing selection is never highlighted. Extension of broken selection. | Fold into host-authoritative selection: host owns selection, scrolls and extends near an edge, ships both viewport + selection. GUI forwards "drag at edge" intent. |
| Copy color metadata for VT/HTML format (sub-part of broken copy) | `src/Surface.zig:2388-2390` | Formatter opts read local `colors.background/foreground/palette` and iterate the empty local screen (R1). Distinct mention but rides the broken copy path. | Same as copy fix: source text + colors from host snapshot. |
| `write_screen` / dump-screen-to-file (history/screen/selection dump) | `src/Surface.zig:5960` (`writeScreenFile`), `~6049-6051` | ScreenFormatter over local `screens.active` + local colors (R1) → empty/blank file for all emit formats. **R3 is load-bearing here**: `.history` and full `.screen` dumps need scrollback that is *not on the wire* — the viewport-only mirror cannot supply it. | Compute the dump host-side (host owns screen + scrollback); colors from host terminal same pass. Requires shipping history host→GUI (new frame) or having the host write the file directly — the GUI mirror fundamentally cannot supply history. |

## BROKEN — Low (cosmetic / niche / derived)

| Feature | File | Why broken | Fix direction |
|---|---|---|---|
| Deep-press (force-click) word selection | `src/Surface.zig:4652-4666` | Runs on empty local terminal, result not drawn (R1). | Route deep-press pin to host word-select path. |
| Quick Look / Look Up word under cursor (`ghostty_surface_quicklook_word`) | `src/apprt/embedded.zig:2218-2253` | Pins + `selectWord` on empty local terminal (R1) → returns nothing. | Forward cursor pin to host word-select+read path. |
| `search_selection` (seed needle from selection) | `src/Surface.zig:5100-5108` | `selectionString` reads empty local selection (R1) → needle null, no-op. Derived; search itself is host-computed (Slice 3b). | Once selection is host-owned, source needle from host selection text. |
| copy_url / link-open / hover-preview **regex-link** text extraction | `src/Surface.zig:1769-1772`, `4562`, `5228-5231`; `linkAtPin 4495-4509` | Regex links are *detected* GUI-side on the mirror, but text is extracted via `io.terminal...selectionString(link.selection)` on the empty local terminal (R1) → empty URL/hover/copy. OSC8 links use host-computed `osc8URI` and are fine. | Pull link substring from the same mirror StringMap/renderCellMap used for detection, or have host return matched text; re-point `linkAtPin` at the mirror. |
| Live OS color-scheme DSR (mode 2031) on theme change | `src/termio/Termio.zig:713-721`; `src/Surface.zig:4877-4895` | Gates on local `modes.get(.report_color_scheme)`, stuck false (R1/R2); `report_color_scheme` is NOT in ModeFrame and no theme frame is forwarded. A TUI following system theme via 2031 gets no live update. Explicit CSI ?996n query is unaffected (host-answered). | Forward a theme frame GUI→host (carry `conditional_state.theme`); host updates its terminal and emits the 2031 DSR under its real mode gate (must interleave with host PTY write stream). |
| VT KAM (`disable_keyboard`) gate | `src/Surface.zig:2835-2840` | Reads local `disable_keyboard`, stuck false (R2). Behind `vt_kam_allowed` (default off). | ModeFrame apply (host ships it, protocol.zig:899). |
| modsChanged link-refresh vs mouse-capture gate | `src/Surface.zig:2855-2892` | `mouse_event` stale `.none` (R2) → always takes link-refresh branch, never suppresses when an app grabs the mouse. Wasteful, not destructive. | Auto-fixed by ModeFrame apply. |
| Key-event mouse-shape derivation (`keyToMouseShape`) | `src/Surface.zig:2896-2907` | Reads stale `mouse_event` + default `mouse_shape` (R2/R1) → modifier-over-grab pointer logic never engages; shape defaults `.text`. Cosmetic. | ModeFrame apply for `mouse_event`; route app shape through local terminal or read last `set_mouse_shape` payload. |
| Mouse-shape RESTORE after link-hover clears | `src/Surface.zig:1820-1825`, `2880-2884`, `4700-4706` | Restores shape by reading local `mouse_shape`, stale `.text` (R1); `set_mouse_shape` handler doesn't write it → hovering off a link resets to `.text` instead of the app's shape. Self-corrects on next app update. | Have `set_mouse_shape` handler also write `io.terminal.mouse_shape`, or track last app shape in a Surface field. |

## UNSURE / Notes

The audit found **no items it could not classify** — every cited site resolved to broken, harmless, or ok-rerouted. Two cross-cutting cautions to carry into any fix:

1. **"Input modes already re-routed" is false at this commit (R2).** The ~14-field ModeFrame mirror is decoded into `Client.mode` but has **no production consumer** (only `client_difftest.zig` reads it). Treat all `io.terminal.modes/flags` reads in the key/mouse/paste paths as currently stale.
2. **No history is on the wire (R3).** The `GridFrame`/Snapshot is strictly viewport-sized (`RenderState.zig:298,335`; `pushFullFrames` `Server.zig:1194-1232`); scrollback is reachable only by re-scrolling the host viewport. Every "host owns scrollback" fix direction for `read_text`/`write_screen`/full select-all **requires a new history-bearing frame or a host-writes-it-directly path** — re-pointing GUI reads at the existing mirror recovers only the visible viewport.

## Already working (ok-rerouted / works — not regressions)

OSC 4/10/11 color query responses (host StreamHandler); all rendered colors incl. 256-palette/cursor/reverse-video (mirror); selection/cursor-text uniforms (config + mirror); app-driven mouse shape via `set_mouse_shape` SurfaceEvent; focus reporting (DEC 1004 via `.focused` frame); password-input render masking + secure-keyboard toggle (mirror + SurfaceEvent); cursor visibility/blinking (mirror); pwd readout / working-dir inherit (pwd-sync write into local terminal); surface size readout (host-driven geometry); child-exited query (ChildExited frame); `keyEventIsBinding` (config-only); session id (`Attached` frame). Foreground PID / TTY name return a graceful documented `null` under `.client` (host owns the process) rather than a wrong local read. The local writes in childExited banners, `passwordInput` flag, `dirty.clear`, and `dirty.preedit` are inert-but-harmless (the live behavior rides the mirror / SurfaceEvents / `queueRender`).
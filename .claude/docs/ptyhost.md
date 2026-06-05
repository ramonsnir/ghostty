# PTY-host (emulation-on-host) — current state

A long-lived **`ghostty-host`** process owns the PTY, the child shell, and the
terminal **emulation**. The macOS GUI runs as a thin **`.client`** that renders a
host-fed, viewport-only *mirror* of the screen over an `AF_UNIX` socket. The point
of the split: **a terminal session (live shell + its children + screen state)
survives a GUI binary swap or restart** — quit the GUI, rebuild/reinstall, relaunch,
and each tab reattaches to its still-running host session.

Branch: **`ptyhost/phase-2b`**. Isolated worktree at
`/Users/ramon/git/ghostty-phase2b`; the shared checkout
(`/Users/ramon/git/ghostty`, branch `ramon-fork`) hosts other live sessions and must
never be touched. History: `git log eedccf9b5..HEAD` (base `eedccf9b5` =
"bell: add fork-only bell-features-focused"); use `git show` / `git blame` for the
rationale behind any line.

This doc is the **current-state** description (what works, what doesn't, how it's
built, what the goal status is). Forward backlog + decisions live in
`.claude/docs/ptyhost-remediation.md`.

---

## Goal status: does a session survive a GUI restart?

**Yes — substantially met, and close to a daily driver.** On GUI quit + relaunch,
each tab reattaches by a host-assigned `session_id` (persisted via macOS restorable
state) and recovers the **live** host session: the same shell process and its
children, cwd, terminal modes, scroll region, alt-screen, and scrollback. Reattach
is responsive and shows scrollback. Verified live and by host integration tests.

### "Well" — what is preserved vs. lost on reattach

| Preserved | Lost / not restored |
|---|---|
| Live shell process + children (same PIDs) | Selection (transient host gesture state) |
| cwd, modes, scroll region, charset, alt-screen | — |
| Scrollback (host-owned; reaches GUI on attach + via host-round-trip scroll) | — |
| Title, colors, cursor + cursor style, viewport | — |
| Window/tab/split layout (macOS restorable state) | — |

### "Always" — failure modes and the honest caveats

- **Host crash/kill, or machine reboot → ALL sessions lost.** The host holds every
  session in memory with no persistence; it is the **single point of failure**. This
  is the inherent trade the design makes — it survives *GUI* restarts, not *host*
  restarts. There is no launchd supervision and **no SIGTERM/graceful shutdown**
  (killing the host kills every shell). Host crash-hardening is therefore the
  highest-stakes property; see Durability below (it is in good shape).
- **Unknown `session_id` on reattach → fresh spawn (now logged; no false match).**
  If the persisted id no longer maps to a live host session, the GUI spawns a new
  blank shell (`Server.zig` handleAttach "degrade to spawn-fresh"). Session ids are
  **random 64-bit** (not a counter that resets to 1 each host launch), so a stale id
  from a dead host instance never false-matches a fresh one — an unknown id always
  degrades cleanly instead of binding a tab to the wrong/younger session. The Client
  detects the miss (it asked for one id and got a different one back) and **logs it**
  ("prior session closed or host restarted"); a user-visible indication (vs. a log)
  is the remaining polish. The orphaned host session, if any, keeps running with no
  GUI attached.
- **Restorable-state versioning is tolerant (NOT a cliff).** `TerminalRestorableState`
  is `version = 8` but **`minimumVersion = 5`** (`TerminalRestorable.swift`; only the
  protocol *default* is `minimumVersion { version }`, and the concrete type overrides
  it). The decoder accepts v5–8, and the Codable layer is additive-tolerant — newer
  fields are optionals / `decodeIfPresent` (e.g. `sessionID` at
  `SurfaceView_AppKit.swift`), so an older blob simply leaves them `nil` (those
  surfaces spawn fresh; everything else restores). So older schemas load fine across
  the additive changes made so far. The real sensitivity is only if a future change
  **raises `minimumVersion`** or makes a **non-additive** change (renamed/retyped/
  required field) — keep changes additive+optional and `minimumVersion` low. (This is
  the macOS state-restoration schema version — unrelated to the host *protocol*
  version negotiated in `Hello`.)
- **Connect failure (host down / bad socket) → visible error, never a silent local
  fallback.** The IO thread paints an error into the surface
  (`src/termio/Thread.zig`); it never quietly forks a local shell, so a degraded
  host is never mistaken for a working session.
- Handled cleanly: degenerate/transient reattach resize frames (dropped),
  child-already-exited (tab closes correctly), detach/reattach/close races
  (serialized on `registry_mutex`), multiple windows/tabs (per-tab id).

---

## Current functional state (`.client`)

Everything below is verified against the code at HEAD. Roots for non-working items:
**R1** = GUI reads the unfed local terminal; **R2** = host mode-mirror not consumed;
**R3** = no scrollback/history on the wire (mirror is viewport-only).

### Works

- **Input:** typing; all TUI input modes (DECCKM cursor keys, keypad, Kitty keyboard
  flags, alt-esc, backarrow, modify_other_keys, KAM); bracketed paste; mouse
  click/release/motion/drag reporting (SGR/X10/1002/1003) + button-scroll +
  alternate-scroll. (Host ships a `ModeFrame`; the `.client` terminal applies it.)
- **Rendering:** cells, colors (incl. 256-palette / reverse-video), cursor +
  visibility/blink/style; cell fidelity is proven equal to in-process `.exec`
  (differential tests).
- **Selection + copy:** drag-select, double-click word, triple-click line,
  select-all; ⌘C / copy-on-select. Host-authoritative (host runs `select*` /
  `selectionString` on the real screen). **Select-all copies the full buffer
  including scrollback** (no R3 needed — the host has it).
- **Scroll** (host round-trip), **⌘K clear screen/scrollback**, **terminal reset**
  (force-pushes the post-reset frame so stuck modes recover).
- **confirm-close-surface=true** warns only when a command is actually running
  (host-authoritative `at_prompt` bit). (`=always`, the user's config, confirms
  unconditionally by design.)
- **SurfaceEvents:** title, bell, clipboard read/write (OSC52), pwd, dynamic colors
  (OSC 4/10/11), desktop notifications, progress, mouse-shape, password-input,
  command-tracking.
- **Links:** OSC8 (host-computed) and regex-link *detection*. **Search**
  (host-computed highlights + nav + counts). **Resize** (authoritative wire grid;
  degenerate frames dropped). **child-exit → tab close.**
- **cwd-inherit on new tab:** wired (host `finalize()`s its config so the login
  shell + OSC7 resolve; pwd synced into the local terminal). Believed working; a
  definitive end-to-end GUI re-smoke is the one loose end here.

### Broken / missing — but low-to-near-zero impact for this usage

(Interactive shells + TUIs + CLI agents. No CJK/IME, VoiceOver, or right-click copy.)

| Item | Root | Impact |
|---|---|---|
| Alt-screen wheel→arrow translation (less/man/vim without mouse mode) | R2 | low-moderate (the one felt gap; apps with `mouse=a` work) |
| Cursor-click-to-move at the prompt | R1 | low-moderate (keyboard nav unaffected) |
| Selection autoscroll past the viewport edge | R1/R3 | low (select-all covers whole-buffer copy) |
| Cross-scrollback selection *highlight* (the off-screen visual) | R3 | low (copy across scrollback works) |
| regex-link / copy_url *text extraction*; `search_selection` seed | R1 | low |
| `write_screen` history dump; `read_text`/accessibility over history | R3 | near-zero (no VoiceOver) |
| IME preedit anchor; Quick Look / Look Up word | R1 | near-zero (no IME) |
| Live OS color-scheme DSR (mode 2031); right-click→Copy | R1/R2 | near-zero / de-prioritized |

**Scrollback paging is local-less by design:** the mirror is viewport-only, so scroll
is a host round-trip (no smooth local paging). History-spanning features (the R3
rows above) would need a new history-transport frame — see *Phase C: decided against*
in the remediation doc.

---

## Durability & safety posture

- **`.exec` is byte-for-byte unchanged** (the hard invariant). Every `.client`
  behavior is gated on mirror-presence / the backend union; the differential test
  corpus asserts the mirror equals the in-process `.exec` RenderState cell-for-cell.
- **Host crash-hardening (the highest-stakes property): good.** The two known crash
  vectors are fixed and regression-tested — the `PageList.resizeCols` unsigned
  underflow (saturating subtraction; this was the *all-sessions-down* reattach-flood
  crash) and an `@enumFromInt` UB on an untrusted highlight tag on the render hot
  path (validated at the wire boundary + at the render site). The **entire untrusted
  GUI→host frame surface degrades a malformed frame to a clean connection close, not
  a process abort**: every enum decode goes through checked `intToEnum`, frame length
  is bounded, the dispatch loop catches and logs, and selection coords drop
  out-of-viewport rather than index out of bounds. No other reachable host
  crash/UAF turned up in dispatch/selection/resize/decode.
- **Residual durability risk:** the host runs the full upstream terminal emulator on
  real PTY output and has **no panic isolation** — a latent panic anywhere in
  upstream emulation reachable by adversarial child output would abort the whole
  process (all sessions). None found; the surface is the whole emulator, not just IPC.
- **Data integrity:** the render-tick push gate is complete (rows-changed OR
  force-push for search/selection/viewport/**mode** OR cursor-changed), so no
  render-affecting host state change is silently dropped. Selection text is extracted
  in the same locked critical section as the snapshot, so highlight and copy text
  share one point-in-time read (no torn/stale copy).
- **Known scalability caveat (not a correctness bug):** attach/close do blocking
  socket writes under `registry_mutex`, so they serialize behind one slow GUI peer —
  acceptable for a single local GUI.

---

## Architecture & invariants

### Two backends (`src/termio/backend.zig`)

- **`.exec`** (default) — the in-process `Terminal`; upstream behavior, unchanged.
- **`.client`** (`src/termio/Client.zig`) — proxies to the host over `AF_UNIX`.

Selected by the fork-only config key **`pty-host = <socket path>`** (consumed in
`src/Surface.zig` before either backend is constructed): non-null ⇒ `.client`. No
silent `.exec` fallback (see Goal status).

### The mirror (the central decision)

Under `.client` the renderer's source of truth is a host-supplied
**`terminal.RenderState` mirror, viewport-only by construction** — not a raw
`Terminal`. The wire payload is a **pointer-free `Snapshot`** (`src/host/RenderState.zig`),
serialized over framed `AF_UNIX` and rehydrated client-side into a `RenderState` the
renderer consumes unchanged. There is **no local scrollback buffer** on the client.

A `PageList.Pin` is a host pointer and **cannot cross the wire** (the mirror sets a
poisoned sentinel), so pin-dereferencing GUI paths are gated off and the **host
computes the result**: search highlights ride `row.highlights` on the frame; OSC8
links come via a `Hover`→`LinkFrame` round-trip; regex links work GUI-side because
they read cell *text*, not pins.

### One mutex for the mirror

The renderer reads the mirror under `renderer_state.mutex`; the `Client` read thread
writes it under the **same** mutex (passed via `Client.Config.render_mutex`). The
mutex/mirror pointers must reference the `Client` at its **final address** (after
`Termio.init` moves the backend union) — the wiring reaches into
`self.io.backend.client` *after* the move for exactly this reason.

### The render-tick push gate (the rule to remember)

`src/host/Session.zig` `renderTick` runs on a ~10 Hz poll timer as well as on real
output, and every captured `Snapshot` is `.full`, so the push is gated:

```
if (changed > 0 or force_push or cursor_changed) { push GridFrame + ModeFrame }
```

**Any new render-affecting host state must be added to this gate or it never reaches
the GUI.** This is the single most common bug class here — it caused the cursor,
search-clear, scroll-after-reattach, and mode-only-flip gaps. The current force-push
terms cover search, selection, viewport (scroll/jump), and mode changes; cursor moves
have their own `cursorEql` term. A freshly (re)attached GUI bypasses the gate via
`Server.pushFullFrames`.

### Resize, reattach, protocol

- **Resize** drives off the **authoritative wire `{cols, rows}`** the GUI rendered
  at (reconstructed by `Resize.toSize`), never re-derived from raw pixel
  `screen_w/h`. Degenerate frames (resolved grid below the 10×4 min-window floor) are
  **dropped** in `Server.dispatch` — a transient reattach frame must never reflow the
  real terminal.
- **Reattach** is keyed on `session_id` (random non-zero u64 per session; 0 =
  unattached — see `allocSessionId`). Forward via `ghostty_surface_config_s.session_id`;
  reverse via `ghostty_surface_session_id()`;
  persisted Swift-side as `sessionID` in `TerminalRestorable` (v8).
- **Protocol** (`src/host/protocol.zig`): length-prefixed binary frames; a `Hello`
  handshake is required before any stateful frame. **Frozen-ABI discipline:** keep
  the host tiny and stable and prefer additive, version-negotiated changes — a host
  rebuild kills every live shell it owns.
- **SurfaceEvent channel** (one `surface_event` frame) forwards the
  `apprt.surface.Message` set; the `Client` re-injects each so the GUI handles them
  as under `.exec`. Carve-outs: `child_exited` has its own dedicated frame (do not
  double-forward); `clipboard_read`/`report_title` responses ride the Input channel.

---

## Where the code lives

**Host** (`src/host/`): `main.zig` (`--listen=<path>`), `Server.zig` (listener +
session registry + subscriber routing + dispatch), `Session.zig` (one session:
Termio/Exec/Terminal + `renderTick` push gate + selection/clear/reset/at-prompt
handlers), `RenderState.zig` (`Snapshot` serialize/deserialize/rehydrate, `cursorEql`),
`protocol.zig` (frames, `Hello`, `Resize.toSize`), `difftest.zig` + `test.zig`.

**Client** (`src/termio/`): `Client.zig` (the `.client` backend), `backend.zig`
(the union), `Termio.zig`/`Thread.zig` (message routing), `message.zig`,
`client_difftest.zig`.

**Core wiring:** `src/Surface.zig` (backend selection on `pty-host`; mirror/mutex
wiring after the move; selection/scroll/clear/reset routing; `session_id` getter;
`needsConfirmQuit`), `src/renderer/generic.zig` (reads the mirror; pin paths gated;
highlight-tag validated), `src/config/Config.zig` (`pty-host` key).

**C-ABI / apprt:** `include/ghostty.h` (`session_id` field + getter),
`src/apprt/embedded.zig`. **macOS:** `SurfaceView.swift` / `SurfaceView_AppKit.swift`
(`sessionID` Codable), `TerminalRestorable.swift` (v8).

---

## Build, run, test, smoke

> Build/run **only** in `/Users/ramon/git/ghostty-phase2b`. Never touch
> `/Users/ramon/git/ghostty`. Never quit/launch the **installed Release** fork
> (`com.mitchellh.ghostty-ramon`) — it hosts the working session. Use the
> **ReleaseLocal** identity ("Ghostty (ramon-local)", `…ghostty-ramon.local`) for dev.

**Tests (fast, no app):**
```sh
zig build test -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=<host|client|Screen|Terminal>
```

**Build lib + host:**
```sh
zig build -Demit-macos-app=false -Doptimize=ReleaseFast   # -> zig-out/bin/ghostty-host
```

**Build the macOS app (ReleaseLocal):**
```sh
rm -rf macos/build/ReleaseLocal                 # REQUIRED — see the stale-binary trap below
macos/build.nu --configuration ReleaseLocal --action build
```

**⚠️ Stale-binary trap (cost a long debug session).** `build.nu` compiles into
DerivedData, then xcodebuild codesigns the output bundle. If that bundle carries
xattr/"resource fork detritus" (left by a prior manual `ditto`/`xattr`/`codesign`),
the codesign **fails** (`** BUILD FAILED **`, exit 65) and the freshly-linked binary
is **never copied over** — so the app you launch is **silently stale** (old behavior,
even though `zig build` succeeded). **Always `rm -rf macos/build/ReleaseLocal` first**
so build.nu produces a clean bundle and exits 0. To verify freshness: check the binary
mtime, and launch the binary **directly** (not via `open`) with `GHOSTTY_LOG=stderr`
redirected to a file — core libghostty `log.*` is invisible unless `GHOSTTY_LOG` is
set (it gates both the os_log path under subsystem=<bundle id> and the stderr path).

**Smoke (the headline feature — re-verify when resuming):**
1. Start the host: `./zig-out/bin/ghostty-host --listen=/tmp/ghostty-host.sock`
   (a fresh dev host; not the one hosting this session).
2. `pty-host = /tmp/ghostty-host.sock` in a config the dev app loads
   (`~/.config/ghostty-ramon/config` or a `--config-file`).
3. Launch ReleaseLocal; open a tab; start an observable long-lived process
   (`sleep 9999 & echo MARKER-$$`, or `vim`/`top`).
4. Quit **only** ReleaseLocal (`tell application id "com.mitchellh.ghostty-ramon.local"
   to quit`); leave the host running. Relaunch.
5. **Pass:** the tab reattaches to the still-running session (same marker PID, screen
   intact, scrollback present). **Fail:** a fresh shell, or a visible connect error.

### Dev notes (process)

- Workflow review/plan agents must be pinned `model: 'opus'` — the `Explore` agentType
  silently downgrades the model. Background multi-phase workflows kept dying on the
  180 s no-output watchdog during heavy Opus reads; main-loop build/test + a single
  foreground Opus review agent has been more reliable.
- The original implementation plan (`.claude/plans/ptyhost-implementation-plan.md`,
  the `§` cross-refs in old commit messages) is **not in this worktree**; this doc and
  the source comments are authoritative.

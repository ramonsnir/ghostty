# Suspend / resume idle agent splits — reclaim RAM, keep the split

Status: **PROPOSED — design of record. Part 1 (passive session-id capture) IMPLEMENTED on the
`suspend-resume-design` branch (hooks + GUI/sidecar only, no host change); Parts 2–6 not yet
built.** Grounded in the code at HEAD
(citations are `file:line` / `file:symbol`) and in the four-thread investigation that preceded it;
claims about *current* behavior were verified against source. Scope is deliberately **Claude Code
only** for the MVP — Codex is postponed (see [Postponed: Codex](#postponed-codex)).

---

## Summary / motivation

Long-lived terminal splits running a CLI coding agent (Claude Code) pile up over days/weeks and
hold a lot of RAM. The goal: when such a split has been **idle for more than two business days**,
automatically **kill its child process** (the real RAM cost), keep the **GUI split alive as a
frozen placeholder** so you still remember what was in there, and offer a **Resume** button that
spawns a fresh agent child — `claude-pool --resume <session_id>` in the same working directory —
and grafts the split back onto it, continuing the conversation close-enough from where it was.

### The one fact that shapes the whole feature

Under this fork's pty-host architecture, a session on `ghostty-host` owns only the pty **master
fd**, the child **pid** (an integer), and the `terminal.Terminal` (grid + scrollback, capped by
`scrollback-limit`, default **10 MB** — `src/config/Config.zig:1388`). **The child is a separate
OS process** whose memory is *not* in the host's address space. A `node`+`claude` child is
hundreds of MB; a shell is a few MB.

| Split type | Reclaimable RAM per split | The whale |
|---|---|---|
| text-only | ≤~10 MB scrollback + tiny shell | scrollback (modest) |
| text + Claude | ≤~10 MB scrollback + **hundreds of MB** node process | the agent child |

So **suspend ≙ kill the child** (`Subprocess.killPid`, `src/termio/Exec.zig:1369`). That single act
reclaims essentially all the RAM for an agent split. Everything else — the placeholder, the resume
command, the cwd — is about fidelity, not reclaim. Keeping the ≤10 MB Terminal parked in host RAM
is a rounding error against the child we freed, and it is what lets Resume be a graft rather than a
cold restart.

### Why this is *not* the host-handoff path

Host-handoff (`HOST-HANDOFF.md`) is **process-transparent**: it hands the live child + master fd to
a successor over `SCM_RIGHTS`, so the shell keeps running. Suspend is the opposite by design: it
**kills** the child to reclaim RAM. Resume therefore starts a **fresh** child and continues the
*agent conversation* from the agent's own on-disk transcript (`claude --resume`), not the *process*.
For an **idle** Claude session this is essentially lossless — which is exactly the case we target.
This "close-enough" tradeoff is accepted (user decision).

---

## Lifecycle model

A session gains one new state, `suspended`, between "live" and "destroyed":

```
  LIVE (child running, GUI attached)
    │  idle > 2 business days  ──►  scanner fires suspend_split
    ▼
  SUSPENDED (child killed + master closed; Terminal kept parked in host RAM;
             GUI split still attached, showing a frozen placeholder)
    │  user clicks Resume  ──►  resume_split
    ▼
  LIVE again (fresh child spawned into the SAME session, cwd + claude --resume <id>;
              placeholder clears when the child's first bytes arrive)
```

Two invariants:

- **The GUI split never dies and never detaches.** The placeholder is a GUI-side overlay over the
  frozen last frame; the surface stays subscribed to the same `(host, session_id)` the whole time.
  "Re-attach" on resume is just the overlay clearing — no re-dial, no new surface. (This is the
  primary design; an alternative that detaches is noted under [Alternatives](#alternatives).)
- **A suspended session is never reaped.** The existing reaper (`reapEligible`,
  `dead_session_grace_ms = 3_600_000`, `src/host/Server.zig:978,996`) must treat `suspended` as
  *never eligible*, the same way it already treats a live detached child (`Server.zig:994`).

### MVP durability boundary

The MVP keeps the parked Terminal **in host RAM only** — so a suspended split survives a **GUI
restart** (the host outlives the GUI) but **not a host restart**. This is intentional: it needs
zero serialization, dodges the `session_transfer` same-build guard entirely, and still delivers the
whole RAM win (the child is gone). Disk durability is a documented follow-up (see
[Future: disk durability](#future-disk-durability-layer-2)).

---

## Part 1 — Passive session-id capture (IMPLEMENTED; no host change)

Resume needs Claude's own session id (the `claude --resume <id>` token). **We capture it passively
from the hook — we do NOT run `/status`.** Claude Code already passes `session_id` (and `cwd`,
`transcript_path`) on the hook stdin JSON for every event; the fork's hook script currently reads
only `tool_name` / `prompt` / `message` and drops the rest
(`example/claude-hooks/ghostty-agent-state.sh:118-123`, POST body assembled at `:266`).

Capturing it passively means suspend needs **no session injection, no TUI scraping, and no
before/after snapshot dance** — the id (and cwd) are already known at suspend time. The `/status`
idea is dropped for exactly this reason: it would wake an idle session and pollute the very frame
we want to freeze.

Plumbing (all additive, **hooks + GUI/Swift only, no host/Zig change**):

1. `example/claude-hooks/ghostty-agent-state.sh` — add `json_field session_id` and `json_field cwd`;
   include both in the POST body (`:266` local, `:165` remote).
2. `macos/Sources/Features/MCP/MCPAgentState.swift:32-77` (`MCPAgentState.parse`) — decode
   `sessionId`, `cwd`.
3. `macos/Sources/Features/AgentDashboard/AgentStateBridge.swift:13-29` (`AgentStatePayload`) — add
   the fields.
4. `macos/Sources/Features/AgentDashboard/AgentDashboardController.swift:1117-1128`
   (`HookSnapshotEntry`) — carry `claudeSessionId`, `agentCwd`.
5. Echo on `list_surfaces` (`macos/Sources/Features/MCP/MCPLayout.swift` `SurfaceRow`) for
   observability — **but keep it distinct from the existing `sessionID` field, which is the
   ghostty-host PTY id, not the agent's resume id.** These two "session ids" are unrelated; naming
   must keep them apart (`claudeSessionId` vs `sessionID`).

`transcript_path` is available the same way if we ever want the on-disk transcript; not needed for
the MVP.

---

## Part 2 — Idle scanner (GUI-side, gated, no LLM)

The "automated process" is **not** an agent that drives the TUI. It collapses to a passive periodic
check, because the session id is already known (Part 1). The dashboard already tracks
`agentState` (`working`/`waiting`/`idle`) and `idleSeconds` per surface, so the scanner is a small
timer that:

1. Enumerates agent splits with `agentKind == "claude"` and `agentState == idle`.
2. Computes **elapsed business days** since last activity (skip Sat/Sun; holidays out of scope —
   note it) and compares to the threshold (default 2).
3. For each over-threshold split, invokes the suspend path (Part 3).

Home: a small addition to `AgentDashboardController` (it already polls surface state), gated by a
config key so it is OFF by default. An agent-queue **schedule** could drive it instead, but a plain
timer is simpler and needs no LLM in the loop — preferred.

**Business-day math:** from the last-activity timestamp to now, count weekday boundaries crossed;
fire at ≥ 2. Last-activity = the timestamp of the most recent hook event or output for the surface
(already available to the dashboard). Edge cases to encode in a pure, unit-tested helper: a
Friday-idle session doesn't cross the threshold until Tuesday; DST transitions; the machine being
asleep across a boundary (use wall-clock deltas, not tick counts).

---

## Part 3 — Suspend (host change)

New host protocol frame `Suspend` (distinct from `Detach` and `Close`), triggered by a new
`suspend_split` surface action. Semantics, contrasted with the two existing teardown paths:

| | child process | pty master fd | Terminal state | session entry |
|---|---|---|---|---|
| **Detach** (`Server.zig:1644`) | stays alive | stays open | kept in RAM | parked, reattachable |
| **Close** (`Server.zig:2904`) | SIGHUP'd + reaped | closed | freed | destroyed |
| **Suspend** (new) | **`killPid` (reaped)** | **closed** | **kept parked in RAM** | **alive, marked `suspended`** |

Suspend is a **new composition** of primitives that already exist — none of the three current paths
does it:

1. `Subprocess.killPid` (`Exec.zig:1369`) — SIGHUP + reap the whole process group (handles the
   setsid race + Darwin EPERM).
2. Close the master fd (as the adopted-close branch does, `Exec.zig:324-333`).
3. Keep the `SessionEntry` registered, set a new `suspended` flag on it, and stop pushing
   `foreground_pid` frames for it. This reuses the *dead-child park* scaffolding
   (`sessionOwnerThread`, `Server.zig:2220-2236`) — but marked so the 1-hour reaper skips it.

The cleanest place to add the composite is next to `Session.detachForHandoff` (the existing "stop
the reader without killing" precedent, `detach_requested` in `Exec.zig:63`, detach branch
`:301-313`). Suspend is its mirror: **kill** the reader's child instead of handing it off, but keep
the Session object.

GUI side at suspend:
- Record the manifest (Part 5).
- Flip the split to the placeholder (Part 4).
- Do **not** detach the surface — it stays subscribed so the reaper never sees zero subscribers and
  resume is a local graft.

**Redeploy:** this links into `ghostty-host` → it is a **Host change**. It lands via the
supervisor/worker **handoff** path (`HOST-HANDOFF.md`), not a destructive bootout, and — per the
testing plan below — is exercised in the **non-installed** build first.

---

## Part 4 — The frozen placeholder (GUI-only)

Reuse the existing overlay machinery. `ReconnectStateOverlay` (`SurfaceView.swift:342-383`) already
draws a named, actionable banner **over the dimmed, frozen last frame**, and its `.sessionEnded`
case already renders a **`moon.zzz` sleep icon** (`SurfaceView.swift:399-405`) — literally a
sleeping-pane visual.

Two changes:
- It is gated to remote hosts only (`SurfaceView.swift:220-222` requires a non-`"local"`
  `hostName`). Add a sibling branch (or relax the gate) so a **local** suspended split shows it.
- Add a `@Published var suspended` (+ resume metadata) on `SurfaceView` and a new ZStack branch in
  `SurfaceWrapper.body` (`SurfaceView.swift:188-228`), following the existing placeholder branches
  (`AwaitingRemoteHostView`, `SurfaceErrorView`). The banner card carries a **Resume** button.

**Frozen frame fidelity (decided): viewport only, no scrollback.** The placeholder shows the last
rendered viewport frame the split already holds — enough to remember what was in there. We do
**not** marshal scrollback for the MVP; scrolling back in a suspended split is out of scope (that
would be the optional Layer 2 snapshot, [below](#future-disk-durability-layer-2)).

---

## Part 5 — The manifest (what Resume needs)

A small per-suspended-split record. For the MVP it lives in RAM alongside the GUI split (and in the
restorable-state archive so it survives a GUI restart, mirroring how the fork already persists the
sticky `bell` / `attentionNeeded` flags — `SurfaceView_AppKit.swift:2456-2457,2507-2508`):

```
{
  hostSessionId : u64      // the ghostty-host PTY session id (identity of the parked session)
  hostName      : String   // "local" for MVP
  claudeSessionId : String // the claude --resume <id> token (from Part 1)
  cwd           : String   // working dir to respawn in (from the hook cwd)
  agentKind     : "claude" // MVP; codex later
  title         : String   // for the placeholder label
  lastPrompt    : String?  // shown on the card as a reminder
  suspendedAt   : Date
}
```

Add it as new CodingKeys on the SurfaceView archive (`SurfaceView_AppKit.swift:2441-2458`), emit
only when set, decode with defaults for old archives — verbatim to the bell/attention pattern.

**Pool account note (decided):** `claude-pool` rotates accounts; `--resume` replays a *local*
on-disk transcript that is not account-scoped for reading, so resume works regardless of which pool
account it lands on. Which account *continues* the session doesn't matter — accepted.

---

## Part 6 — Resume (host change)

New `resume_split` surface action + a host frame that spawns a **fresh child into the existing
suspended session**:

1. Host: for the `suspended` SessionEntry, build a fresh subprocess — `Pty.open` + `fork_exec`
   (`Subprocess.start`, `Exec.zig:~1102`) — with the recorded **cwd** and the reconstructed command
   `claude-pool --resume <claudeSessionId>` (agentKind → `claude-pool`; `codex-pool` later). The
   Terminal already parked on the session is reused as the emulation target; only a *new pty +
   child* are attached to it.
2. This is a small new variant of `Session.adopt` (`Session.zig:544`). Today `adopt` requires an
   inherited `master_fd` **and** `child_pid`. The terminal-injection seam is already decoupled from
   the pty (`Termio.init` adopts `opts.adopt_terminal` verbatim, `Termio.zig:262-295`) — so we need
   a **fresh-spawn** variant of adopt: reuse the parked Terminal, but `subprocess.start` a new pty +
   child instead of inheriting one. Clear the `suspended` flag; resume normal `foreground_pid`
   pushes.
3. GUI: the surface is already attached — the placeholder overlay clears when the child's first
   output arrives (poll `clientStateInfo` back to `.healthy`, `SurfaceView_AppKit.swift:202-204`).

**Delivery of the resume command.** Two options:
- (a) Host spawns `claude-pool` directly as the child's argv (exec-level). Cleanest; no shell
  keystroke injection.
- (b) Spawn a fresh shell child, then type the command as `initialInput` — the mechanism
  `spawn_split_command` already uses (`MCPLayout.swift:494-547,630`, `config.initialInput`).

Prefer **(a)** — it matches "start a new shell running claude-pool with --resume" without a
racey type-into-shell step, and it's how a normal split's command is launched. (b) is the fallback
if the pool wrapper must run under an interactive shell for its `.bashrc` account plumbing; that's a
detail to confirm against how `claude-pool` resolves its account on this machine.

**Redeploy:** Host change (links into `ghostty-host`); same handoff-deploy + non-installed-build
testing as Part 3.

---

## Testing plan — use the non-installed build (decided)

Parts 3 and 6 are **Host changes**, so they must be exercised without touching the installed
Release that hosts this Claude Code session:

- **Build + run the `.local` (ReleaseLocal) or `.debug` fork** (`macos/build/ReleaseLocal/…` /
  `.../Debug/…`, bundle ids `com.mitchellh.ghostty-ramon.local` / `.debug`) and drive its **own**
  `ghostty-host` there. These are freely quit/launched (`CLAUDE.md` identity table) and their host
  is separate from the installed Release's host.
- **Do NOT bootout/redeploy the installed Release's host** to test — that would end the live
  session. Only after the feature is proven on the non-installed build do we schedule the installed
  Release's host upgrade via the deliberate handoff path, at a time the user picks.
- Full build/host-restart mechanics: `FORK-DEV.md` (iteration lifecycle) + `PTYHOST.md`
  (bootout+bootstrap, never `kill`) + `HOST-HANDOFF.md` (session-preserving worker handoff).

In-process host tests (`src/host/test.zig`) get: a suspend → parked-with-`suspended` test, a
reaper-skips-`suspended` test, and a resume → fresh-child-into-parked-Terminal test (mirroring the
existing detach/adopt sequence tests). Pure GUI helpers (business-day math, placeholder gating,
manifest encode/decode-with-old-archive) get Swift unit tests.

---

## Implementation surface (Claude-first MVP)

| Layer | Files | Redeploy |
|---|---|---|
| Passive session-id capture | `example/claude-hooks/ghostty-agent-state.sh`; `MCPAgentState.swift`; `AgentStateBridge.swift`; `AgentDashboardController.swift`; `MCPLayout.swift` | hooks + GUI/sidecar |
| `suspend_split` / `resume_split` actions | `src/input/Binding.zig`; `src/input/command.zig`; `src/apprt/action.zig`; `include/ghostty.h`; `src/Surface.zig`; `Ghostty.App.swift`; `GhosttyPackage.swift` | Zig + lib (xcframework) |
| Host suspend/resume | `src/host/protocol.zig` (new frames); `src/host/Server.zig` (handlers, `suspended` state, reaper skip); `src/host/Session.zig` (`suspendChild` + fresh-spawn `adopt` variant); `src/termio/Exec.zig`; `src/termio/Termio.zig` | **Host** (handoff deploy) |
| Idle scanner + business-day math | `AgentDashboardController.swift` (+ pure helper) | GUI/sidecar |
| Placeholder + Resume button | `SurfaceView.swift` (overlay branch), `SurfaceView_AppKit.swift` (`suspended` flag + manifest CodingKeys) | GUI |

New fork-only config keys (proposed; all in `~/.config/ghostty-ramon/config`, OFF by default):
- `suspend-idle` — master switch (default off).
- `suspend-idle-business-days` — threshold (default 2).
- `suspend-scan-interval` — how often the scanner runs (default e.g. 30m).

Per `CLAUDE.md` documentation discipline, when this ships each key/action gets its feature-doc
entry here + the CLAUDE.md Feature map + Fork-only config keys index, in the same change.

---

## Postponed: Codex

Codex is **detected** (same subtree-walk matcher, `agentKind == "codex"`) but has **no hook
mechanism** in this fork — so neither passive session-id capture nor a clean idle signal exists for
it (`AGENT-QUEUE.md:60-62` "Codex hooks: TODO"). Bringing Codex to parity needs a new capture path
(read Codex's rollout file for the latest session in that cwd, or a future Codex hook) and a
`codex-pool --resume`/equivalent invocation. **Out of scope for the MVP** (user decision); revisit
after the Claude path is proven.

---

## Future: disk durability (Layer 2)

To make suspended splits survive a **host restart / reboot** (and free the parked ≤10 MB Terminal
too), add a two-layer disk model:

- **Durable manifest (stable JSON):** the Part 5 record written to disk. Always resumable across
  app updates and host restarts, because it holds only strings/ids.
- **Best-effort screen snapshot (fragile blob):** `session_transfer.serialize`
  (`src/host/session_transfer.zig`) is already a pointer-free, position-independent `[]u8`
  (~16–20 MB for 10k×200, compresses hugely) that `Terminal.deserialize` rehydrates from bytes +
  allocator alone — no child needed. **But** its MAGIC + 10-word struct-layout fingerprint guard
  (`session_transfer.zig:49-81`) has **no versioning**: a blob written before any rebuild that
  shifts those struct sizes fails to deserialize. So the snapshot is same-build-only and must be
  best-effort — on mismatch, resume falls back to the durable manifest (blank frame + the resume
  command still works). This is why durability rests on the manifest, with the snapshot as a bonus.

Not needed for the MVP: the RAM win is the child, which the in-RAM path already reclaims fully.

---

## Alternatives (considered, not chosen)

- **Detach the surface at suspend, re-adopt at resume by `(host, session_id)`.** The queue's
  `adopt_split` already resumes an orphaned session by that pair (`AGENT-QUEUE.md:315-317`). Works,
  but it makes the GUI split briefly ownerless and turns resume into a re-dial + content swap
  (`materializeClientSurface`, `SurfaceView_AppKit.swift:729`). The keep-subscribed design (Part 4)
  is simpler and keeps the placeholder a pure GUI overlay. Re-adopt becomes the natural mechanism if
  we ever *do* detach (e.g. Layer 2, where the session is freed and recreated).
- **Run `/status` via an agentic driver.** Rejected: wakes the idle session, pollutes the frame we
  want to freeze, and needs TUI scraping — all unnecessary once the id is captured passively.

---

## Honest caveats (state these to any implementer)

1. **Not process-transparent.** Killing the child is irreversible; resume is a *fresh* child +
   `claude --resume`, i.e. the agent conversation continues, not the live process. Lossless for an
   idle Claude session; lossy for a shell mid-command (out of scope — we only suspend idle *agent*
   splits).
2. **MVP survives GUI restart, not host restart** (Terminal parked in host RAM). Reboot durability
   is Layer 2.
3. **Two unrelated "session ids".** The ghostty-host PTY `session_id` (`u64`) and Claude's resume
   id (`claude --resume <id>` string) are different things; the code must never conflate them.
4. **Codex not covered** until its capture path is built.

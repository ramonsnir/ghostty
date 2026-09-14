# Suspend / resume idle agent splits — reclaim RAM, keep the split

Status: **IN PROGRESS on the `suspend-resume-design` branch. Part 1 (passive session-id capture) and
the Part 2 policy core (`SuspendPolicy`) are IMPLEMENTED + unit-tested. Parts 3–6 REVISED to need NO
host change — verified in code that suspend reuses the existing `Close` frame (via the existing
`ghostty_surface_close_session_now` export; the `closing` flag already suppresses redial/adopt-fresh)
and resume reuses the existing `Attach` (fresh spawn + `working_directory` + `initial_input` via the
`materializeClientSurface` in-place recreate), so Parts 3–6 are **GUI-only Swift** — no Zig, no
xcframework rebuild, no `ghostty-host` restart (the host-frame design is retained as a rejected
alternative). Parts 3–6 now IMPLEMENTED (GUI-only Swift) and the app builds with all unit tests
green (`SuspendPolicyTests` 8, `SuspendManifestTests` 5, plus the Part-1 `MCPAgentStateTests` /
`AgentDashboardHookStateTests`); the interactive UX (placeholder → Resume → conversation continues)
and the auto-suspend timing are pending hands-on verification in the `.local` build, and nothing is
merged. A manual "Suspend Split" command-palette action (`suspend_split`) is also implemented (the
one piece that needed Zig — a payload-less apprt action) so a split can be parked on demand; the app
builds with it and its Binding + `ghostty.h`↔`Action.Key` tests pass.** Grounded in the code at HEAD
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

So **suspend ≙ tear the session down** — which reaps the child (the hundreds of MB) AND frees the
≤10 MB Terminal. As Part 3 shows, the existing `Close` frame already does exactly that, so suspend
reuses it; everything else — the placeholder, the resume command, the cwd — is GUI-side fidelity,
not reclaim.

### Why this is *not* the host-handoff path

Host-handoff (`HOST-HANDOFF.md`) is **process-transparent**: it hands the live child + master fd to
a successor over `SCM_RIGHTS`, so the shell keeps running. Suspend is the opposite by design: it
**kills** the child to reclaim RAM. Resume therefore starts a **fresh** child and continues the
*agent conversation* from the agent's own on-disk transcript (`claude --resume`), not the *process*.
For an **idle** Claude session this is essentially lossless — which is exactly the case we target.
This "close-enough" tradeoff is accepted (user decision).

---

## Lifecycle model

The lifecycle is entirely GUI-side; the host session is fully torn down while suspended (the GUI
surface/split lives on as a placeholder):

```
  LIVE (host session running, GUI split attached)
    │  idle > 2 business days  ──►  scanner fires suspend_split
    ▼
  SUSPENDED  (GUI marks the surface `suspended` + records the manifest, then sends the
              existing Close frame → host reaps the child, closes the master, frees the
              Terminal (FULL RAM reclaim). The GUI split is NOT destroyed: it holds its
              cached last frame + a "Suspended — Resume" overlay.)
    │  user clicks Resume (or resume_split)  ──►  fresh Attach
    ▼
  LIVE again (SAME SurfaceView re-attaches to a NEW host session: fresh spawn in the
              recorded cwd with initial_input="claude-pool --resume <id>\n"; overlay clears
              on the first grid_frame; the surface adopts the new session_id)
```

Invariants:

- **The GUI split survives; the host session does not.** Suspend is a `Close` (full teardown) plus a
  GUI decision to keep the split as a placeholder. There is nothing parked host-side, so nothing to
  reap and no host-RAM residue.
- **Resume is a fresh session, not a reattach.** Continuity comes from Claude's own on-disk
  transcript via `claude --resume <id>`, not from host state — consistent with "not
  process-transparent" (see caveats).

### Durability

Because suspend frees the host session completely, a suspended split survives BOTH a GUI restart and
a host restart for free — the placeholder + resume manifest live in the SurfaceView restorable-state
archive (Part 5), and there is no host-side state that a restart could lose.

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

**Resume-id durability (three tiers, all implemented).** The `claude --resume <id>` token is sourced,
in order: (1) the live in-memory hook capture (above); (2) PERSISTED across GUI relaunches in the
per-host-session `PersistedAgentState` store (`claudeSessionId`/`cwd`/`lastActivity`, 14-day prune),
rehydrated onto the reattached surface — so a once-captured id survives a relaunch; (3) RECOVERED at
suspend time from Claude's own on-disk transcript (`TranscriptResolver`): find the `claude` process
under the split's foreground pid, read its cwd, and take the newest `~/.claude/projects/<cwd→'-'>/…
.jsonl` (the filename IS the session id). Tier 3 is what makes a NEVER-captured idle split
suspendable with no poking — the encoding (every non-alphanumeric char → `-`) is verified against
real project dirs, and `claude --resume` reads the transcript by id.

---

## Part 2 — Idle scanner (GUI-side, gated, no LLM)

> **Status:** the PURE core is IMPLEMENTED (`SuspendPolicy` — business-day math + idle-selection,
> fully unit-tested, no Zig change). The side-effecting wiring (a timer on
> `AgentDashboardController`, the `suspend-idle*` config keys, and the call into the suspend action)
> lands with Part 3, which it depends on.

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

## Part 3 — Suspend (GUI + GUI-side lib; NO host change)

**Key finding (verified in code): the host needs no change.** The existing `Close` frame already
SIGHUPs+reaps the child AND frees the Terminal (`Server.zig:2904`), and the existing `Attach` frame
already carries a fresh-spawn `working_directory` + `initial_input` (`protocol.zig:554-564`) — so
suspend reuses `Close` and resume (Part 6) reuses `Attach`. No new protocol frame, no minor bump,
and nothing new links into `ghostty-host`. The `.client` state-machine tweaks are GUI-side **lib**
Zig (rebuild the xcframework) but are NOT compiled into the host (the `.client` redial machine is
GUI-lib-only), so there is **no host restart and no session-loss deploy** — the whole feature ships
as a normal GUI/lib relaunch. The original host-frame design is kept as a rejected alternative below.

Two bonuses over the parked-in-host-RAM design this replaces: it reclaims MORE RAM (the ≤10 MB
Terminal is freed too, not just the child), and it matches the "no scrollback in the frozen frame"
decision — the frozen frame is the GUI's cached last viewport (already retained for the
session-ended overlay), not host-held scrollback.

Contrast with the two existing teardown paths — suspend simply reuses `Close`, the difference being
purely GUI-side (the split is kept, not destroyed):

| | child process | pty master fd | Terminal | host session | GUI split |
|---|---|---|---|---|---|
| **Detach** (`Server.zig:1644`) | stays alive | stays open | kept in RAM | parked | destroyed/reparented |
| **Close** (`Server.zig:2904`) | reaped | closed | freed | destroyed | destroyed |
| **Suspend** (Close + keep split) | reaped | closed | freed | destroyed | **kept — frozen placeholder** |

The `suspend_split` action, on the focused (or scanner-selected) split:
1. Record the manifest (Part 5) on the SurfaceView.
2. Mark the surface `suspended` and send the existing `Close` frame to the host session (full RAM
   reclaim). **Do NOT destroy the GUI surface/split.**
3. Hold the last mirror frame (dimmed) and show the "Suspended — Resume" overlay (Part 4).

**The auto-respawn gotcha is already handled — no `.client` change needed.** `closeSession` sets a
`closing` flag before sending `Close` (`Client.zig:1162`), and `classifyDrop` returns `null` when
`closing` (`Client.zig:206-211`) — so the drop provoked by our `Close` leaves the frozen frame in
place and does NOT go `.reconnecting`, redial, or adopt-a-fresh-id. So suspend is literally
`SurfaceView.closeSessionNow()` (the existing `ghostty_surface_close_session_now` export) plus the
GUI keeping the split and overlaying the banner. **Zero Zig.**

**Redeploy:** GUI only (Swift) — no Zig, no xcframework rebuild, no host restart. A normal
ReleaseLocal build + relaunch.

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
would be the optional screen snapshot, [below](#future-higher-fidelity-frozen-frame-optional)).

---

## Part 5 — The manifest (what Resume needs)

A small per-suspended-split record. For the MVP it lives in RAM alongside the GUI split (and in the
restorable-state archive so it survives a GUI restart, mirroring how the fork already persists the
sticky `bell` / `attentionNeeded` flags — `SurfaceView_AppKit.swift:2456-2457,2507-2508`):

```
{
  suspended       : Bool    // sticky flag: this split is suspended (drives the overlay + gate)
  claudeSessionId : String  // the claude --resume <id> token (from Part 1)
  cwd             : String   // working dir to respawn in (from the hook cwd)
  agentKind       : "claude" // MVP; codex later
  title           : String   // for the placeholder label
  lastPrompt      : String?  // shown on the card as a reminder
  suspendedAt     : Date
}
```

No `hostSessionId` is needed as identity: suspend FREES the host session and resume mints a fresh
one, so there is nothing to reattach to by id. `hostName` stays `"local"` for the MVP. Add these as
new CodingKeys on the SurfaceView archive (`SurfaceView_AppKit.swift:2441-2458`), emit only when
set, decode with defaults for old archives — verbatim to the sticky `bell`/`attentionNeeded` pattern.
A suspended split thus survives a GUI restart as a placeholder and resumes after it.

**Pool account note (decided):** `claude-pool` rotates accounts; `--resume` replays a *local*
on-disk transcript that is not account-scoped for reading, so resume works regardless of which pool
account it lands on. Which account *continues* the session doesn't matter — accepted.

---

## Part 6 — Resume (GUI + GUI-side lib; NO host change)

The `resume_split` action (or the overlay's Resume button) re-attaches the SAME SurfaceView to a
FRESH host session that runs the resume command:

1. Reconstruct the command from the manifest: `claude-pool --resume <claudeSessionId>` (agentKind →
   `claude-pool`; `codex-pool` later).
2. Re-attach via the existing content-swap `materializeClientSurface` (`SurfaceView_AppKit.swift:729`):
   a new `Attach` with `session_id=null` (fresh spawn), `working_directory = manifest.cwd`, and
   `initial_input = "<command>\n"`. The fresh interactive shell loads its rc (so a `claude-pool`
   shell function resolves) and runs the resume — exactly the by-hand path.
3. Clear the overlay + `suspended` flag on the first grid_frame of the new session (`clientStateInfo`
   back to `.healthy`, `SurfaceView_AppKit.swift:202-204`); adopt its new `session_id` (the surface's
   identity updates, as any fresh attach does).

**Why `initial_input`, not an exec-level argv:** typing the command into a fresh interactive shell
works whether `claude-pool` is a shell function (loaded from the rc file) or an on-PATH executable —
it reproduces the by-hand invocation exactly, and it is the mechanism `spawn_split_command` already
uses (`MCPLayout.swift:494-547`, `config.initialInput`). An exec-level argv would miss a shell
function. (`GHOSTTY_ITEM_*`-style env is not needed for resume; the session id is the only input.)

**Redeploy:** GUI only (Swift); no Zig, no xcframework rebuild, no host restart.

---

## Testing plan — GUI/lib only, NO host restart

Because there is no host change (Part 3), there is nothing to deploy to `ghostty-host` and no
session-loss restart to schedule. The feature ships as a normal GUI/lib relaunch:

- **Unit tests** (the safe, CI-able bulk): the pure `SuspendPolicy` business-day/selection helper
  (done — `SuspendPolicyTests`), the manifest encode/decode-with-old-archive, and the `.client`
  session-ended `suspended`-gate decision as a pure helper (mirroring `client_difftest.zig`'s
  arming/redial tests).
- **Build + run the `.local` (ReleaseLocal) or `.debug` fork** to exercise suspend→placeholder→resume
  interactively against its own host — never needed for correctness of the host, only to see the UI.
  These identities are freely quit/launched (`CLAUDE.md` identity table).
- Shipping to the installed Release is the normal GUI-only install block (`FORK-DEV.md` step 6) +
  relaunch — non-destructive under pty-host, **no host bootout**.

(The earlier plan's in-process `src/host/test.zig` suspend/resume tests are moot — there is no host
change to test.)

---

## Implementation surface (Claude-first MVP)

| Layer | Files | Redeploy | Status |
|---|---|---|---|
| Passive session-id capture (Part 1) | `example/claude-hooks/ghostty-agent-state.sh`; `MCPAgentState.swift`; `AgentStateBridge.swift`; `AgentDashboardController.swift`; `MCPLayout.swift`; `mcp.ts` | hooks + GUI/sidecar | **DONE** |
| Idle policy core (Part 2) | `SuspendResume/SuspendPolicy.swift` (+ tests) | GUI | **DONE (core)** |
| Suspend mechanism | `SurfaceView.suspend(manifest:)` — reuses the EXISTING `ghostty_surface_close_session_now` via `SurfaceView.closeSessionNow()`; keeps the split | GUI only | **DONE** |
| Resume mechanism | `SurfaceView.resume()` — in-place recreate with a fresh `SurfaceConfiguration` (`sessionID=nil`, `workingDirectory=cwd`, `initialInput="<pool> --resume <id>\n"`) | GUI only | **DONE** |
| Placeholder + Resume button + manifest | `SuspendedOverlay` in `SurfaceView.swift`; `suspended` flag + `SuspendManifest` CodingKeys + restore-defer in `SurfaceView_AppKit.swift`; `SuspendManifest.swift` | GUI only | **DONE** |
| Idle scanner + config | `AgentDashboardController` scan timer → `AgentDashboardModel.suspendOverdueIdleAgents` → `SuspendPolicy`; `SuspendSettings` (UserDefaults, default OFF) | GUI only | **DONE** |

| Manual **Suspend Split** action | `suspend_split` apprt action (`Binding.zig`/`command.zig`/`action.zig`/`ghostty.h`/`Surface.zig`) → `Ghostty.App`/`GhosttyPackage`/`AppDelegate` → `AgentDashboardController.suspendSurface` → `SurfaceView.suspend` | Zig + lib (xcframework) | **DONE** |

The runtime suspend/resume is GUI-only Swift (the one C export it needs,
`ghostty_surface_close_session_now`, already exists). The **manual command-palette "Suspend Split"**
(a user request — park a split on demand without waiting for the idle scanner) is the one piece that
needed Zig: a payload-less apprt action. Resume stays the overlay's Resume button (no `resume_split`
action was added).

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

## Future: higher-fidelity frozen frame (optional)

The GUI-only approach already reclaims ALL the RAM (suspend `Close`s the session, freeing child +
Terminal) and already survives a GUI restart (the manifest + a cached frozen frame persist in the
SurfaceView archive), so the original "Layer 2 disk durability" RAM/host-restart rationale is moot.

The one thing lost is scrollback fidelity in the placeholder — the frozen frame is viewport-only (by
decision). If a future want is "scroll back through a suspended split," that's the only place
`session_transfer.serialize` (`src/host/session_transfer.zig`) would help: capture a screen snapshot
at suspend for a richer placeholder. It's a pointer-free `[]u8` that `Terminal.deserialize` rehydrates
from bytes alone, BUT its MAGIC + 10-word struct-layout fingerprint guard (`session_transfer.zig:49-81`)
has no versioning, so a snapshot is same-build-only and must be best-effort (fall back to the
viewport frame on mismatch). Out of scope; noted for completeness.

---

## Alternatives (considered, not chosen)

- **New host `Suspend`/`Resume` frames + a parked "suspended" session (the original Part 3/6
  design).** Suspend would `killPid` the child but KEEP the `SessionEntry` + its Terminal parked in
  host RAM (marked `suspended`, excluded from the 1-hour reaper); resume would spawn a fresh child
  into that parked session via a fresh-spawn variant of `Session.adopt`, keeping the same
  `(host, session_id)`. **Rejected** once code review showed `Close` already frees everything and
  `Attach` already spawns fresh with cwd + initial_input: the host approach is strictly more work (a
  protocol minor bump, `Server`/`Session`/`Exec` changes, a destructive host redeploy scheduled via
  the supervisor handoff, in-process host tests) for LESS RAM reclaim (it keeps the ≤10 MB Terminal
  resident) and no functional gain — the only thing it preserved was the exact host-side scrollback,
  which the "no scrollback in the frozen frame" decision doesn't want. The GUI-only path (Parts 3/6
  above) supersedes it.
- **Resume by exec-level argv (`claude-pool` as the child's argv) instead of `initial_input`.**
  Rejected: misses a `claude-pool` *shell function*; typing into a fresh interactive shell
  reproduces the by-hand invocation regardless of how `claude-pool` is provided.
- **Run `/status` via an agentic driver to read the session id.** Rejected: wakes the idle session,
  pollutes the frame we want to freeze, and needs TUI scraping — all unnecessary once the id is
  captured passively (Part 1).

---

## Honest caveats (state these to any implementer)

1. **Not process-transparent.** Killing the child is irreversible; resume is a *fresh* child +
   `claude --resume`, i.e. the agent conversation continues, not the live process. Lossless for an
   idle Claude session; lossy for a shell mid-command (out of scope — we only suspend idle *agent*
   splits).
2. **Survives GUI restart AND host restart** — suspend `Close`s the host session entirely, so there
   is no host-side state to lose; the placeholder + resume manifest persist in the SurfaceView
   archive. (A reboot loses only unsaved GUI state, same as any window restoration.)
3. **Two unrelated "session ids".** The ghostty-host PTY `session_id` (`u64`) and Claude's resume
   id (`claude --resume <id>` string) are different things; the code must never conflate them. On
   resume the surface gets a NEW host `session_id` (fresh session); the Claude resume id is what
   carries continuity.
4. **Suspend is a deliberate `Close`.** Any non-Claude output, a half-typed command, or background
   jobs in that split are gone — we restart a fresh shell + `claude --resume`. Fine for an idle
   agent split (the only thing we suspend); never suspend a split doing non-agent work.
5. **Codex not covered** until its capture path is built.

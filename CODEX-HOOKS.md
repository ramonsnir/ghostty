# Codex agent hooks — parity with Claude Code

The fork's Agent Dashboard / Manager / Queue / Suspend features are driven by two
signals: a local **process-subtree detector** (which already classifies a `codex`
process — see `AGENT-DASHBOARD.md`) and per-tile **agent-state hooks** the CLI agent
POSTs to the in-GUI MCP server at `POST /agent-state`. Historically only Claude Code
wired those hooks, so a Codex split was *detected + previewed* but had no live status
chip, no attention/"needs you" push, no queue auto-close, and no idle suspend/resume.

Codex CLI shipped a Claude-Code-shaped hooks system (v0.114, on by default), so this
feature brings Codex to full parity by wiring the **same** `/agent-state` ingest from
Codex's hooks. It is a **GUI + shell** feature — **no host/Zig change** except a
one-line command-palette label (so the redeploy is **Zig+lib** for the palette entry,
GUI-only otherwise; the sidecar needs **no code change** — its auto-close gate is
already agentState-based and CLI-agnostic).

## What you get (once installed)

A local **or** cross-host Codex split behaves exactly like a Claude one:

- a live **status chip** (working / waiting / idle) + last tool / last prompt on its tile;
- an **attention alert + phone Web Push** when Codex asks for approval
  (`PermissionRequest` → `waiting`);
- **Agent Queue auto-close** of a finished Codex split (its `Stop`/`SessionEnd` → `idle`
  satisfies the queue's quiescence gate);
- **idle auto-suspend + Resume** of an idle Codex split (`codex-pool --resume <id>`),
  the same business-day scanner that covers Claude.

## Install

Command palette → **Install Agent Hooks** (or the one-time launch offer when a
queue/manager feature is enabled). It installs BOTH agents' hooks — each installer is
independent + idempotent, so anything already present is left untouched. For Codex it:

1. writes `~/.config/ghostty-ramon/codex-hooks/ghostty-agent-state.sh` (chmod 0755), and
2. idempotently merges six events into `~/.codex/hooks.json` (backing up any prior file,
   preserving every existing entry, refusing to overwrite a malformed file).

Then run Codex's **`/hooks`** command once to **TRUST** the hook — Codex refuses to run a
non-managed hook until you approve it. Restart Codex sessions to pick up the hooks.

### Event → state mapping (`hooks.json`)

| Codex event | agent state | drives |
|---|---|---|
| `SessionStart`, `UserPromptSubmit`, `PreToolUse` (matcher `.*`) | `working` | status chip |
| `PermissionRequest` | `waiting` | attention alert + Web Push |
| `Stop`, `SessionEnd` | `idle` | queue auto-close + idle-since for suspend |

`PermissionRequest` is Codex's "needs you" edge (Claude uses `Notification`); Codex has
no `Notification` event, so a plain finished turn settles in `idle` (no nag), which the
queue's quiescence gate accepts.

## Cross-host Codex

A remote-spawned Codex agent lights up a **cross-host tile** exactly like a remote Claude
one: the GUI injects a per-spawn correlation **nonce** (`GHOSTTY_SURFACE_NONCE`, kind-
agnostic) and the hook POSTs `{nonce, state, kind:"codex", …}` with the per-box capability
token, resolved to the surface by `RemoteAgentIdentity`. Provision the box exactly as for
Claude (see `CLOUD-HOSTS-DESIGN.md` → Deployment); the SAME `codex-hooks/` script + a
`~/.codex/hooks.json` on the box are all that's added. **The box's `~/.codex/hooks.json`
also needs the one-time `/hooks` trust.**

## Implementation notes

Load-bearing facts + file wiring; read before touching the feature.

- **Wire contract is CLI-agnostic.** `POST /agent-state` takes
  `{tty|nonce, state, prompt?, tool?, message?, claudeSessionId?, cwd?, kind?}`. The one
  field added for Codex is **`kind`** (`AgentStatePayload.kind`), parsed + sanitized in
  `MCPAgentState.parse` (`safeKind`: lowercased, ≤32 chars, `[a-z0-9-_]` only, else nil —
  it becomes an `AgentKind` command string + a suspend pool-wrapper choice, so it must be
  a safe basename token). The server handler is UNCHANGED (it forwards the whole payload).
- **`kind` is a FALLBACK-ONLY label.** `AgentDashboardModel.displayAgentKind` returns the
  DETECTED kind when the local subtree walk classified one; only for a hook-only surface
  (the cross-host case the detector can't reach) does it fall back to
  `hookKind[id] ?? "claude"`. So the detector always wins; `kind` only fixes the label
  (and the suspend pool wrapper) for a surface with no local process to classify. Without
  it a remote Codex agent would be mislabeled `claude` and reconstruct `claude-pool` on
  resume. `hookKind` is captured in `applyAgentState` (sticky) and persisted in
  `PersistedAgentState.agentKind` (optional; old records / Claude decode as nil → claude),
  so the label + pool wrapper survive a GUI relaunch.
- **Detection needs no change.** `codex` is already in the default
  `agent-dashboard-commands = claude,codex`, so a local Codex subtree classifies as
  `agentKind:"codex"` with no hooks — the hooks add the *state* layer on top.
- **Queue auto-close needs no sidecar change.** `supervisor.ts`'s `isQuiescent` accepts
  `idle` OR `waiting`, and SPAWNED→RUNNING keys off any `agentState`. Codex posting `idle`
  on `Stop` satisfies the close gate directly; the only thing that was missing was Codex
  posting agent-state at all.
- **Suspend/resume.** `SuspendPolicy.suspendableKinds = ["claude","codex"]` gates the idle
  scanner; `SuspendManifest.poolCommand` maps `agentKind == "codex"` → `codex-pool`, and
  `resumeInputLine` emits `codex-pool --resume <id>` (the id is Codex's hook `session_id`,
  captured into the `claudeSessionId` wire field — historically named, kind-neutral in
  purpose, guarded to a safe charset). `codex resume`/`codex-pool` semantics live in the
  external pool wrapper, exactly like `claude-pool`.
- **The installer** is `CodexHooksInstaller` (a self-contained twin of
  `AgentHooksInstaller`): script dir `codex-hooks/`, settings file `~/.codex/hooks.json`,
  events with `PreToolUse` matcher `".*"` (Codex matchers are REGEXES), marker
  `codex-hooks/ghostty-agent-state.sh` (the path segment disambiguates it from the Claude
  twin sharing the same script filename). The hook script is EMBEDDED verbatim (byte-in-
  sync with `example/codex-hooks/ghostty-agent-state.sh`, generated from it) so the
  installer works in a bundle-less ReleaseLocal build. `AppDelegate.ghosttyInstallAgentHooks`
  now installs BOTH agents and reports a combined result; the launch offer
  (`maybeOfferAgentHooks`, asked-key `agentHooks.offered.v2`) fires when EITHER agent's
  hooks are missing.

### Files

- `example/codex-hooks/ghostty-agent-state.sh` — the POST script (source of truth)
- `example/codex-hooks/hooks.json` — the six-event config merged into `~/.codex/hooks.json`
- `macos/Sources/Features/AgentHooks/CodexHooksInstaller.swift` — installer + embedded script
- `macos/Sources/Features/AgentHooks/AgentHooksInstaller.swift` — the Claude twin (unchanged)
- `macos/Sources/Features/AgentDashboard/AgentStateBridge.swift` — `AgentStatePayload.kind`
- `macos/Sources/Features/MCP/MCPAgentState.swift` — `parse` reads + sanitizes `kind`
- `macos/Sources/Features/AgentDashboard/AgentDashboardController.swift` — `hookKind`,
  `displayAgentKind` fallback, `PersistedAgentState.agentKind`
- `macos/Sources/Features/SuspendResume/SuspendPolicy.swift` — `suspendableKinds`
- `macos/Sources/App/macOS/AppDelegate.swift` — install-both handler + combined offer
- `src/input/command.zig` — the "Install Agent Hooks" palette label

### Tests

- `macos/Tests/AgentHooks/CodexHooksInstallerTests.swift` — merge idempotency, matcher
  `.*`, `~/.codex/hooks.json` path, marker disambiguation, embedded-script byte-identity,
  malformed refusal, end-to-end install.
- `macos/Tests/MCP/MCPAgentStateTests.swift` — `kind` parse + sanitization.
- `macos/Tests/AgentDashboard/AgentDashboardTests.swift` — hook-reported kind labels a
  hook-only Codex tile, detector still wins, no-kind falls back to claude, suspend manifest
  picks `codex-pool`.
- `macos/Tests/SuspendResume/SuspendPolicyTests.swift` — Codex now selected; unknown kind /
  working codex excluded.

## Redeploy

**GUI-only** for everything except the one-line command-palette label in `src/input/command.zig`,
which makes the palette-entry change **Zig+lib** (rebuild the lib + xcframework). No host
restart. The sidecar `dist` needs no rebuild (no sidecar code changed). See `FORK-DEV.md`.

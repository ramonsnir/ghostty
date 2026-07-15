# Cloud-hosted terminals — some splits run on a remote host over SSH

Status: **Phases 1 + 2 + 4 implemented; Phase 3 L1 implemented (L3 deferred).** This remains the
DESIGN doc (rationale + full plan of record); the build-ready spec is `CLOUD-HOSTS-IMPL-PLAN.md`.
Phase 1 landed the multi-host `.client` client + registry + launch + `(host, session_id)`
identity: the `pty-remote-host` / `pty-remote-ssh-options` config keys, a per-surface socket
override (`ghostty_surface_config_s.pty_host_socket` / `host_name` + `Client.Config.host_name`),
the GUI-lib-only `ghostty_probe_host` Hello→HelloAck handshake probe, the `new_split_on_host` /
`new_tab_on_host` actions + host-picker palette, `RemoteHostRegistry` + `RemoteTunnelController`
(SSH unix-socket tunnel supervisor with a handshake-gated readiness signal),
restored-remote-surface `hostName` persistence + deferred dial-on-readiness, and the
`MCPLayout`/`MCPKnowledge` surfacing. **Phase 2 (Reconnect subsystem)** added the opt-in
IO-thread redial state machine in `termio.Client` (per-surface `Config.reconnect`, auto-set for a
remote `.attach` surface; `xev.Async` wakeup → backoff `xev.Timer` → read-thread respawn +
re-`Hello`/`Attach`, per-attempt handshake watchdog; NEVER a bare `sleep`), the five-state
surface-visible connection channel (`ghostty_surface_client_state`), the `RemoteTunnelController`
single-owner never-give-up ssh-master respawn supervisor, and the `pty-remote-connect-timeout`
per-attempt ceiling. **Phase 3 L1** added the `HelloAck` version read + the directional `too_old`
overlay + the `ReconnectStateOverlay` banners. **L3 (`hello_nack`) is DEFERRED** (host protocol
change ⇒ session loss ⇒ needs a scheduled MINOR bump). **Phase 4 (cross-host agent ecosystem) is
now implemented:** cross-host agent self-ID by a GUI-minted correlation NONCE (a box can't name a
laptop tty), a PER-BOX capability token scoped to `/agent-state` INGEST ONLY (the master
`mcp-token` is NEVER shipped to a box — D6), the `(host, session_id)` PAIR keyed everywhere the
GUI/sidecar persist a session (dashboard stores, sidecar reconcile + schedule maps, the
`list_surfaces` `sessionID` STRING composite — OQ8/Q2), a per-queue `host` (provider laptop-side,
agent cloud-side — OQ3), a host-aware project palette over the ControlMaster (`pty-remote-project-directory`
— OQ4), and the Linux `/proc` arm in `proc_info.zig` (the ONE host change — a Linux box's host
rebuild names cloud agents; `foreground_pid` already worked on Linux). **All of Phases 2–3 and the
macOS side of Phase 4 are GUI-lib-only — the redial machine, surface Options, probe, state
accessor, nonce map, capability tokens, and the composite-`sessionID` emit are NOT compiled into
`ghostty-host`, so no macOS host restart / no session loss; only the Linux `/proc` arm links into
`ghostty-host` and takes effect after a Linux-box host rebuild.** It is grounded in the code at HEAD (citations are `file:symbol`
/ `file:line`), and every claim about *current* behavior was verified against the source unless
explicitly marked "unverified".

---

## Summary / motivation

This fork already runs terminal **emulation on a separate host process** (`ghostty-host`).
The macOS GUI is a thin **`.client`** that connects to the host over an `AF_UNIX` socket and
attaches to RAM-only sessions by `session_id`; a session (live shell + children + screen
state) survives a GUI restart because the host outlives it. See `PTYHOST.md`.

Today there is exactly **one** host — a local launchd LaunchAgent — and its socket path is a
single config scalar `pty-host` (`src/config/Config.zig:3045`).

**Goal:** let *some* splits run their shell on a **remote** host (a cloud Linux box) for more
RAM/CPU/GPU and to keep running while the laptop sleeps/hibernates, mixed seamlessly with
local splits **in the same GUI window**. The user has worked in cloud VMs over SSH for years
and wants a cloud split to feel exactly like that: authoritative remote output, plain-SSH
latency, reconnect across sleep — but rendered as a native Ghostty split, with the fork's
agent ecosystem (dashboard / queue / manager) working across hosts.

The enabling insight: because the GUI already talks to the host over a **local Unix socket**,
we do not need a networked host or a new auth protocol. We **forward the remote host's
existing Unix socket to the laptop over SSH** (`ssh -L localsock:remotesock`), so the `.client`
dials a *local* forwarded socket and is essentially unaware it is remote. SSH provides auth,
encryption, and a TCP_NODELAY transport; the host keeps its Unix socket and needs (almost) no
change.

---

## Goals

- Launch a split whose shell runs on a chosen remote host, rendered natively alongside local
  splits in the same window/tab.
- Latency **equal to plain SSH** to that box (no worse). Authoritative remote output, no local
  echo.
- Reattach a cloud split across GUI restart **and** across transport drops (sleep, WiFi roam,
  Tailscale reconnect) by a stable `(host, session_id)` identity.
- The agent ecosystem (Agent Dashboard / Queue / Manager / MCP) works for agents running on a
  cloud box.
- Version-mismatch and connect failures are **loud and diagnosable**, never a silent blank
  pane.

## Non-goals (explicit)

- **Predictive/local echo (mosh-style).** Out of scope. The host is authoritative; latency is
  plain-SSH. Do not build client-side speculative echo.
- **A networked `ghostty-host` listener.** The host keeps its `AF_UNIX` socket only. No TCP
  bind, no TLS in the host.
- **A protocol-level auth handshake.** SSH (optionally Tailscale SSH) is the entire auth +
  encryption story. `Hello.identity_bundle_id` stays empty/advisory.
- **Native multi-pane / server-side layout.** No tmux-style server-owned window tree. Layout
  stays GUI-side; a cloud split is just a split whose backend points at a remote-forwarded
  socket.
- **Migrating a live session between hosts.** A session is pinned to the host it spawned on.

---

## Current architecture (grounded)

### The host and the `.client` backend

- Two termio backends (`src/termio/backend.zig`): `.exec` (in-process `Terminal`, upstream,
  unchanged) and `.client` (`src/termio/Client.zig`, proxies to the host). The backend is
  selected in `src/Surface.zig` (`Surface.init`) at **`Surface.zig:683`** — `const backend:
  termio.Backend = if (config.@"pty-host") |sock| backend: {` (line `:667` is the "SLICE 4
  (backend selection)" comment, not the `if`). Non-null `pty-host` ⇒ `.client` (the arm at
  `:683` uses `try`, so a connect/attach failure propagates), else `.exec` — **no silent
  `.exec` fallback** (`PTYHOST.md` "Connect failure"). **⚠️ The socket comes from the GLOBAL
  scalar `config.@"pty-host"` (`.socket_path = sock` at `:683`/`:707`) — there is NO per-surface
  socket path today; adding one is load-bearing for multi-host (see Wiring / the plan's §D5).

- The socket is `AF_UNIX` `SOCK_STREAM`. `Client.connectUnix` (`src/termio/Client.zig:1793`)
  is exactly:
  ```zig
  const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
  const addr = try std.net.Address.initUnix(path);
  try posix.connect(fd, &addr.any, addr.getOsSockLen());
  ```
  i.e. a **path-addressed Unix socket** — this is the single fact that makes SSH unix→unix
  forwarding viable (a forwarded local socket path is dialed identically).

### The connect is SINGLE-SHOT with NO retry — VERIFIED

This is the load-bearing constraint for the reconnect subsystem. Confirmed:

- `Client.threadEnter` (`Client.zig:591`) calls `self.connectAndAttach(...)` **once**
  (`Client.zig:630`).
- `connectAndAttach` (`Client.zig:653`) calls `connectUnix` once (`Client.zig:661`); on any
  error it unwinds via errdefers and returns the error — there is **no loop, no backoff, no
  re-dial**.
- The read thread `ReadThread.threadMainPosix` polls the socket; the *connect* is still
  single-shot (the read thread never re-dials — a drop hands off to the IO-thread redial
  machine). **⚠️ Corrected behavior at design time (the design originally overstated the
  `.attach` teardown):** on a read **error** the `.attach` role `return`ed but pushed **NO**
  surface message; on a clean **EOF (n==0)** the `.attach` role just `break`ed the inner loop and
  re-polled, and because the outer `poll()` used timeout `-1` and checked only the quit pipe —
  never the socket's `POLLHUP` — a peer-closed socket **busy-looped** (read 0 → break → poll
  returns immediately → read 0 …). All session-gone signalling (synthetic `child_exited` via
  `markMirrorEnded`) was **`is_mirror`-gated**, so a `.attach` transport drop surfaced nothing.
  **✅ Phase 2 FIXED this:** every `.attach` drop path — EOF, read-error, fatal push/decode/
  `handleFrame`, poll-error, and a NEW `POLLHUP`/`POLLERR`-without-`POLLIN` check — now routes
  through `ReadThread.onAttachDrop`, which classifies a surface-visible `Client.State` (the pure
  `classifyDrop`: `cannot_handshake` before any `HelloAck`, else `reconnecting` for a reconnect
  client / leave-state for local single-shot) and `return`s to exit the loop **cleanly** (no
  busy-loop), then wakes the IO-thread redial machine for a reconnect client. A `local`/
  single-shot client (`Config.reconnect == false`) never redials and simply keeps its frozen last
  frame — today's local behavior, minus the busy-loop.
- `CLAUDE.md` ("App Nap opt-out") documents the rationale explicitly: *"the host connection is
  opened from per-surface IO threads at surface creation and is single-shot (no retry — see
  `src/termio/Client.zig` `connectAndAttach`)"*, and that a reconnect was **deliberately
  skipped** because the local host is a KeepAlive LaunchAgent (≈always up) and a dropped local
  host can't restore RAM-only sessions anyway.

For a **remote** host this rationale no longer holds: the forwarded socket vanishes whenever
the SSH tunnel drops (sleep / roam / Tailscale reconnect), while the remote session is still
perfectly alive. So reconnect becomes mandatory (see the reconnect section).

### The mirror + one mutex

Under `.client` the renderer's source of truth is a host-supplied, viewport-only
`terminal.RenderState` mirror rehydrated from decoded `grid_frame`s; there is no local
scrollback. Writer (read thread `handleFrame`) and reader (renderer) share one mutex
(`Client.renderMutex()`, `Client.zig:476`). None of this changes for remote hosts — it is
transport-agnostic.

### Protocol + version negotiation — VERIFIED

- `src/host/protocol.zig`: length-prefixed binary frames (`[u32 BE length][u8 tag][payload]`,
  in-frame scalars LE). `PROTOCOL_VERSION_MAJOR = 1` (`protocol.zig:44`),
  `PROTOCOL_VERSION_MINOR = 4` (`protocol.zig:79`).
- Handshake: a `Hello` (major+minor+advisory `identity_bundle_id`) must precede any stateful
  frame. The host gate is in `Server.dispatch` (`src/host/Server.zig:1120`):
  - Pre-handshake, any frame other than `.hello`/`.ping` ⇒ `conn.closed.store(true)` + return
    (`Server.zig:1132`).
  - On `.hello`, if `hello.protocol_version_major != PROTOCOL_VERSION_MAJOR` ⇒ **log a warning
    and close the connection** (`Server.zig:1142-1148`). **No error frame is sent back** — the
    GUI just sees the socket close.
  - Else `conn.handshaked = true`, `conn.negotiated_minor = hello.protocol_version_minor`
    (`Server.zig:1149-1153`), and replies `HelloAck` (which *does* carry the host's major/minor,
    `protocol.zig:497`).
- **Minor negotiation is per-connection and additive.** New host→GUI frames are gated on
  `conn.negotiated_minor` (e.g. `processInfoAllowed(minor)>=3`, `foregroundPidAllowed(minor)>=4`
  — `Server.zig:2249,2257`). An unknown frame **tag** on the GUI side is FATAL:
  `FrameReader.next` returns `error.InvalidFrameType` (`protocol.zig:350`) and the client read
  loop treats it as fatal, so the host must never send a tag the peer didn't negotiate
  (`protocol.zig:62-70`).

**Critical current failure mode:** a major mismatch (or any pre-handshake reject) is surfaced
to the GUI *only* as a connection close — which the `.client` connect path renders as a
generic connect failure / blank-or-error pane. There is **no version-mismatch signal the GUI
can read** (the GUI does not even inspect `HelloAck`'s version fields today — verified: no
major/minor comparison exists in `Client.handleFrame`). Fleet versioning (below) must fix
this.

### sessionID / reattach — VERIFIED single ID space

- Host session ids are **random non-zero u64** (`Server.allocSessionId`, `Server.zig:1853`); 0
  is the "unattached / spawn-fresh" sentinel (`Client.sessionIdFromConfig`, `Client.zig:414`).
- Forward (GUI→host on attach): `ghostty_surface_config_s.session_id` → `Client.Config.session_id`.
  Reverse (host→GUI): `Attached.session_id` stored into `Client.session_id`
  (`std.atomic.Value(u64)`, `Client.zig:239`), read back via `ghostty_surface_session_id()`.
- Persistence: macOS `SurfaceView.sessionID: String?` (`SurfaceView_AppKit.swift:239`), a
  `Codable` key (`SurfaceView_AppKit.swift:2121`), decoded with `decodeIfPresent`
  (`:2151`), and **encoded preferring the LIVE `ghostty_surface_session_id(s)` over the
  init-time value** (`:2184-2195`), inside `TerminalRestorableState` (v8, `PTYHOST.md`).
- Re-adoption on GUI relaunch feeds the persisted id back through the surface config; an
  unknown id degrades to a fresh spawn (`PTYHOST.md` "Unknown `session_id`").
- The agent-queue "survive a GUI restart" path also re-adopts a running scan **by
  `sessionID`** (recent commit `0397875aa`), and `MCPLayout`/`list_surfaces` carry `sessionID`
  for the queue reconcile.

**The problem for multi-host:** `session_id` is a single u64 namespace with **no host
component anywhere**. Two hosts can independently mint the same random u64 (birthday-bounded
but real), and — more importantly — a persisted `sessionID` has no record of *which host* it
belongs to, so on relaunch the GUI cannot know which host to dial to re-adopt it. Identity
must become `(host, session_id)` (see below).

### The agent ecosystem is LAPTOP-1-LOCAL — VERIFIED

The dashboard/queue/manager correlate an agent-state hook to a surface by **local process-tree
walking**:

- The Claude Code hook `example/claude-hooks/ghostty-agent-state.sh` walks **up its own ppid
  chain** to find the nearest ancestor with a real controlling **tty** (its own tty is `??`),
  then fires a fire-and-forget POST to `http://127.0.0.1:<port>/agent-state` with `{tty,
  state}` (`ghostty-agent-state.sh:95-116`).
- The MCP server `/agent-state` route (`MCPServer.swift:452,507`) resolves the hook's `tty` to
  a live surface UUID on the **main thread** via `MCPAgentState.resolveSurface(forTTY:
  surfaces:)`, matching the tty against the local `SurfaceView.foregroundPID`
  (`MCPServer.swift:519-533`).
- The foreground pid itself arrives from the host as the minor-4 `foreground_pid` frame
  (`protocol.zig:231`), and the GUI walks the **local** process subtree to classify the agent
  (pids are system-global **on one machine**).

Every step assumes a single machine: the hook curls **the same box's** `127.0.0.1`, the tty
and pids are **local**, and the process tree is walked **locally**. For an agent on a cloud box
this is entirely broken: `127.0.0.1` on the cloud box is not the GUI, the cloud tty/pids mean
nothing locally, and there is no local process tree. This is the crux of the cross-host agent
work (below), and the fix is actually *cleaner* than today's heuristic.

### App Nap / connect-race (relevant)

`CLAUDE.md` documents that the GUI holds a process-lifetime
`beginActivity(.userInitiatedAllowingIdleSystemSleep)` (`AppDelegate.appNapAssertion`) so the
single-shot connect isn't napped before it lands. The remote-connect path adds a *new* reason
the connect can be slow/fail (the SSH tunnel isn't up yet), which the single-shot path handles
badly — another reason reconnect is mandatory.

---

## Proposed architecture

### Transport: forward the remote Unix socket over SSH

The remote `ghostty-host` runs on the cloud box exactly as locally, listening on a **local**
Unix socket there (e.g. `~/.ghostty-ramon-host.sock` on the box). We forward it to a
laptop-local path and point a `.client` at the local path:

```
ssh -N \
    -o ControlMaster=auto -o ControlPath=~/.ssh/cm-%r@%h:%p -o ControlPersist=60 \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
    -L ${LOCAL_SOCK}:${REMOTE_SOCK} \
    cloud-1
```

`ssh -L localsock:remotesock` uses OpenSSH's **unix→unix** forwarding (a local Unix listener
whose accepted connections are forwarded to a remote Unix socket). The `.client` then dials
`LOCAL_SOCK` via the *unmodified* `connectUnix` path.

```
   ┌─────────────────────────── laptop (macOS GUI) ────────────────────────────┐
   │                                                                            │
   │   Surface (local split)  ──.client──▶  /Users/me/.ghostty-ramon-host.sock  │
   │                                              │ (AF_UNIX)                    │
   │                                              ▼                              │
   │                                    local ghostty-host (LaunchAgent)         │
   │                                                                            │
   │   Surface (cloud split)  ──.client──▶  /Users/me/.ghostty-remote/cloud-1.sock
   │                                              │ (AF_UNIX, LOCAL forwarded)   │
   └──────────────────────────────────────────────┼────────────────────────────┘
                                                   │  ssh -L (unix→unix), over Tailscale
                                                   ▼
   ┌─────────────────────────── cloud-1 (Linux) ───────────────────────────────┐
   │                     sshd  ──▶  ~/.ghostty-ramon-host.sock (AF_UNIX)         │
   │                                       │                                     │
   │                                       ▼                                     │
   │                              ghostty-host (systemd user service)            │
   └────────────────────────────────────────────────────────────────────────────┘
```

Why this is the right transport:
- **No host change for auth/transport.** SSH provides authentication, encryption, and NAT
  traversal (composed with Tailscale). The host keeps its `AF_UNIX` socket; `Hello`'s
  `identity_bundle_id` stays advisory.
- **No session-loss host redeploy for transport.** Adding remote support is a **GUI-side +
  ops-side** change; the host binary is (nearly) untouched, so existing sessions are not killed
  to gain the feature. (The one possible host touch is fleet-versioning; see Wiring.)
- **`.client` is nearly unaware.** It dials a local path either way. The only `.client`-level
  new behavior is **reconnect** (which we need anyway) and threading a host label into
  identity.

Latency: because the host streams *authoritative* output (no local echo — see the mirror), a
keystroke round-trips laptop→host→shell→frame→laptop **exactly like plain SSH** to that box.
SSH already sets `TCP_NODELAY`; our obligation is only *"don't make the transport worse than
SSH"* — i.e. **no input-path coalescing / batching**. `Client.queueWrite` already sends one
Input frame per call (`Client.zig:884`); keep it that way over the tunnel. Do **not** add a
Nagle-style buffer.

#### Compose with Tailscale for addressing/NAT

The `ssh` target (`cloud-1`) is a tailnet name. Two auth options, both fine:
- **SSH over the tailnet**: normal OpenSSH keys/agent, reachable via the Tailscale IP/MagicDNS
  name. Tailscale handles NAT/roaming; SSH handles auth.
- **Tailscale SSH**: Tailscale ACLs + identity do the auth (no separate SSH key management).

Either way the forwarded socket **never leaves the cloud box's loopback namespace** — only the
SSH stream crosses the network (encrypted).

#### Per-host transport-command override (single-forward mode) — Phase 6 ✅

Some boxes are **not** reachable by a plain `ssh <target>`. A common case is a box reached only
through a **wrapper** — e.g. a Cloud-Workstations-style `gcloud workstations ssh` launcher — that
is exposed as a **shell FUNCTION** and spins up its OWN gateway tunnel *per invocation*. That model
breaks two of the default transport's assumptions: a shell function **cannot be `execve`'d**, and a
per-invocation gateway has no stable connection to multiplex, so the `ControlMaster` + `ssh -O
check` / `ssh -O exit` machinery does not fit at all.

Phase 6 adds an optional per-host **transport-command override** for exactly this case. A new
fork-only key `pty-remote-host-command = <name> = <command template>` (a `RepeatableString`) binds a
custom transport onto the matching `pty-remote-host` name. When a host has an override the tunnel
supervisor switches to **single-forward mode**:

- It runs **ONE long-lived forward process** built from the command, appending the forward +
  keepalive itself:
  ```
  <command> -N -L <localSock>:<remoteSock> \
      -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
      -o ExitOnForwardFailure=yes -o StreamLocalBindMask=0177
  ```
- **No `ControlMaster`, no `-M`, no `ssh -O check`/`-O exit`.** There is nothing to multiplex — the
  single process *is* the transport. The health check and stale-control cleanup that the default
  `ssh` path performs are guarded OFF for a command-mode host.
- The command runs through the user's **LOGIN + INTERACTIVE shell** (`<shell> -ilc '<cmd> …'`) so a
  shell **function** resolves — the same `-lc` → `-ilc` login-shell escalation the fork already uses
  to probe `node`/`claude` on a colleague's PATH (`AgentManagerController.probeExecutableViaLoginShell`).
  Command mode goes straight to `-ilc` because a function is only defined for an interactive shell.
- The **remote socket path still comes from the `pty-remote-host` line**; when an override exists the
  ssh-target field of that line is just a human LABEL (the override command is what actually dials).
  The **local** forwarded socket stays under the existing 0700 short dir (its `sun_path` length is
  checked, as in the default path); `StreamLocalBindMask=0177` is passed best-effort (honored by the
  underlying OpenSSH).

Crucially, **only the spawn changes.** The supervisor's readiness signal is already the
transport-agnostic `ghostty_probe_host` socket handshake on the local forwarded socket (a full
Hello→HelloAck round-trip, not a bare connect), and its respawn is already the transport-agnostic
never-give-up backoff that watches the forward process's exit. Both are reused UNCHANGED — the single
forward process is tracked in the same slot the ControlMaster occupies, so the shared respawn drives
it as-is.

**Teardown is the ONE spot the shared path is NOT enough.** The tracked process is the interactive
shell (`-ilc`), and an interactive shell commonly IGNORES SIGTERM — so the default `Process.terminate()`
(SIGTERM) can be a no-op, leaking the shell, its `ssh -N` forward, and any per-invocation gateway after
the last surface releases the tunnel (there is no ControlMaster to `ssh -O exit`). So command-mode
teardown instead force-kills the whole **process GROUP**: the shell leads its own group because an
INTERACTIVE (`-i`) login shell self-`setpgid`s during job-control init (it self-leads even without a
controlling tty). The post-spawn `setpgid(pid, pid)` in `spawnCommandTunnel` is only a best-effort
belt-and-suspenders that is EXPECTED to FAIL with EACCES — Foundation.Process `posix_spawn`s, so by the
time `run()` returns the child has already exec'd and a parent can no longer change its pgid — so it is
NOT the load-bearing mechanism (guarded by the `commandModeTransportProcessIsItsOwnGroupLeader` test).
Teardown SIGTERMs then (after a short grace) SIGKILLs `kill(-pid, …)` — reaping the ssh child + gateway
too — plus SIGKILLs the shell pid itself. `kill(-pid, …)` is SAFE even if the shell never became a
leader (there is then no group with that id → ESRCH no-op; it can never reach the GUI's own group). The forward process's exit
handler also SIGKILLs the group to reap orphans before a respawn, and command-mode teardown unlinks the
forwarded local socket so a leaked forward can't hold the path across a respawn.

A host **without** an override uses the default `ssh` ControlMaster path **byte-identically**
(back-compat): the registry builder defaults the command list to empty, so `transportCommand == nil`
and every non-override code path is unchanged.

Because a wrapper command usually carries a real target / cluster / region identifier, keep the real
value in the **untracked** `~/.config/ghostty-ramon/local` and use a neutral placeholder
(`my-ssh-wrapper` / `cloud-1`) in tracked config, e.g.:

```
# ~/.config/ghostty-ramon/local (untracked)
pty-remote-host         = cloud-1 = cloud-1 : /run/user/1000/ghostty-host.sock
pty-remote-host-command = cloud-1 = my-ssh-wrapper cloud-1 --
```

No host or protocol change (GUI-lib + config-key only).

### Multi-host client + `(host, session_id)` identity

Introduce a small **host registry** in the GUI: an ordered set of named hosts, each with a
`.client` socket path. The special reserved name **`local`** is the existing `pty-host`
socket; every other entry is a remote whose socket path is the **laptop-local forwarded path**
that the tunnel supervisor (below) creates.

`session_id` must be namespaced by host **everywhere it is stored or keyed for
reattach/persistence**. Concretely, replace the bare `u64` session identity with a pair
`(host_name, session_id)`:

| Place today (single ID space) | Change |
|---|---|
| `Client.Config.session_id: ?u64` (`Client.zig:361`) | add `host_name` (the registry key); the socket path is derived from it |
| `Client.session_id` atomic (`Client.zig:239`) | unchanged type; the *host* is Config-side, so the pair is `(config.host_name, session_id)` |
| `ghostty_surface_config_s.session_id` / `ghostty_surface_session_id()` | keep the u64; add a `host_name` string field alongside it in the C surface config + a getter |
| macOS `SurfaceView.sessionID: String?` Codable (`SurfaceView_AppKit.swift:239,2121,2195`) | add a persisted `hostName: String?` sibling key (additive, `decodeIfPresent` → nil = `local`, back-compat) |
| `MCPLayout` / `list_surfaces` `sessionID` emission | add `hostName` so the queue reconcile keys on the pair |
| agent-queue re-adopt-by-sessionID (`queue/runner.ts`, store) | key on `(hostName, sessionID)` |

**Re-adoption rule:** on GUI relaunch, a surface with persisted `(hostName, sessionID)` where
`hostName != local` must (1) ensure the tunnel for `hostName` is up (supervisor), then (2)
dial that host's local forwarded socket with `session_id = sessionID`. An unknown id still
degrades to a fresh spawn on **that** host (existing `handleAttach` behavior), never on the
wrong host.

Back-compat: a nil/absent `hostName` means `local` (every existing persisted surface). This is
strictly additive, matching the `decodeIfPresent ?? default` discipline the fork already uses
for `sessionID`/`bell`/`attentionNeeded` (`PTYHOST.md`; `SurfaceView_AppKit.swift`).

### Config / host registry (proposed keys — fork-only)

Follow the `RepeatableString` precedent (`project-directory` `Config.zig:2908`;
`agent-queue-templates-dir` `Config.zig:3007`; C bridge `ghostty_config_string_list_s`
`include/ghostty.h:561` backed by `list_c` `Config.zig:6375`). A registry entry needs
name + ssh target + remote socket path (+ optional local socket path), so a plain
`RepeatableString` of structured lines is the least-friction shape:

```
# fork-only; keep in ~/.config/ghostty-ramon/config
# name = ssh-target : remote-socket-path  [ : local-socket-path ]
pty-remote-host = cloud-1 = cloud-1 : ~/.ghostty-ramon-host.sock
pty-remote-host = big-gpu = user@big-gpu.tailnet.ts.net : /run/user/1000/ghostty-host.sock
```

- Parse each line into `{ name, sshTarget, remoteSocket, localSocket? }`; default
  `localSocket` to a derived per-name path under a fork dir (e.g.
  `~/.ghostty-ramon/remote/<name>.sock`).
- `local` is reserved and always maps to the scalar `pty-host` value (unchanged key).
- Reuse the existing `RepeatableString` + `list_c` C plumbing; **no new C API** for the config
  list itself.
- Two more optional scalars: `pty-remote-ssh-options` (extra `ssh` args appended verbatim) and
  `pty-remote-connect-timeout` (seconds; feeds the reconnect backoff cap).
- (Phase 6) An optional repeatable `pty-remote-host-command = <name> = <command template>` binds a
  per-host TRANSPORT-COMMAND override onto the matching `pty-remote-host` entry: the tunnel then
  runs one long-lived forward through that command in a login+interactive shell (no ControlMaster),
  for a box reachable only through a wrapper (e.g. a gateway / launcher shell function). The
  command usually carries a real target/identifier, so keep the real value in the untracked
  `~/.config/ghostty-ramon/local` and use a neutral placeholder in tracked config.

Keeping these in `~/.config/ghostty-ramon/config` is mandatory (an official Ghostty shares
`~/.config/ghostty/config` and would error on the unknown keys — the fork's standing rule).

### Launch-on-host action (propose; do not implement)

Two entry points, both thin wrappers that set the surface's target host before spawning a
`.client`:

- **Keybind action** `new_split_on_host:<name>` / `new_tab_on_host:<name>` (fork-only,
  surface-scoped), mirroring the existing `new_tab:<dir>` shape. It resolves `<name>` in the
  registry, ensures the tunnel is up, and spawns a fresh `.client` surface with
  `host_name=<name>` (session_id null ⇒ fresh spawn on that host). A command-palette entry
  "New Split on Host…" opens a fuzzy host picker (like the project selector).
- **MCP tool** `spawn_split_command` already exists (`macos/Sources/Features/MCP/…`); add an
  optional `host` argument so an orchestrating agent can place a split on a named host. This
  needs the same registry lookup + tunnel-ensure. **No new tool** — extend the existing one's
  schema (mind the `toolsListHasAllTools` count assertion if a *new* tool is ever added).

`cwd` semantics: a fresh cloud split's `working_directory` is **host-relative** — it names a
path on the cloud box, not the laptop. See the locality taxonomy.

---

## The reconnect subsystem (the biggest engineering item)

Two independent layers must both be built; they are complementary, not redundant.

### Layer 1 — SSH tunnel lifecycle (the transport)

A **tunnel supervisor** (GUI-side, one per remote host that has at least one live surface)
owns the `ssh -L` process and keeps the forwarded local socket alive:

- **Multiplexing:** `ControlMaster=auto` + `ControlPath` + `ControlPersist` so N cloud splits
  to one host share **one** TCP/SSH connection (one auth, one NAT hole). The first surface
  brings the master up; later surfaces reuse it.
- **Keepalive:** `ServerAliveInterval=15` + `ServerAliveCountMax=3` so a dead tunnel is
  detected in ~45s (and torn down rather than hanging).
- **Respawn (autossh-style):** the supervisor watches the `ssh` child; on exit it respawns with
  exponential backoff (1, 2, 4, 8, 16, capped ~30–60s, forever while ≥1 surface for that host
  is alive), then **recreates the local forwarded socket**. Reuse the fork's existing backoff
  shape (`AgentPreviewTile` `mirrorReconnectDelay`: a quick burst then a steady cadence forever
  — `CLAUDE.md` "Preview auto-reconnect").
- **Readiness:** the local forwarded socket must exist *and accept a connection* before the
  `.client` dials it. The supervisor exposes a "ready" signal (poll-connect the local socket)
  that the redial loop waits on.
- **Lifecycle bounding:** tear the tunnel down when the last surface for that host closes
  (respecting `ControlPersist` for a brief reuse window).

Implementation note: launch `ssh` as a child `Process` (like `AgentManagerController` launches
the sidecar), inherit the user's SSH agent, and parent-death-guard it (the sidecar orphan-guard
pattern, `CLAUDE.md` "Sidecar orphan guard") so a GUI crash doesn't leak `ssh` children.

### Layer 2 — `.client` redial loop (the session)

This is the change that reverses the *deliberate* single-shot decision (`Client.connectAndAttach`
`Client.zig:653`). It must be **opt-in per host** so the local host stays byte-for-byte
single-shot (the KeepAlive LaunchAgent assumption is still valid locally — do not add retry to
`local`).

- When a remote `.client`'s read thread hits EOF / read error (the forwarded socket died with
  the tunnel), instead of tearing the surface down it enters a **redial state**: wait for the
  Layer-1 "ready" signal (with backoff), then re-run the connect + `Hello` + **`Attach{
  session_id = <known id> }`** to *reattach* the still-alive remote session by its id — not a
  fresh spawn.
- The id to reattach is the one the surface already holds (`Client.session_id` atomic, seeded
  from the persisted/last-known id), so reattach targets the exact `(host, session_id)`.
- On reattach the host does a `pushFullFrames` seed (existing path), so the mirror repaints
  the current screen — exactly the GUI-restart reattach flow, now triggered by a *transport*
  drop instead of a GUI restart.
- **Distinguish reconnecting from dead.** EOF now has two meanings: (a) tunnel dropped, session
  alive → redial; (b) session genuinely gone (host restarted → unknown id → fresh spawn, or
  child exited → `child_exited` frame). The `child_exited` frame is explicit and unambiguous
  (`protocol.zig:110`); treat a bare EOF as (a) and redial, and let the reattach's
  known-vs-returned-id check (already logged today, `PTYHOST.md`) detect a host restart and
  degrade. Surface a clear reconnecting overlay meanwhile (see below).
- **App Nap interaction:** the redial loop must survive backgrounding. The existing App-Nap
  opt-out covers the *initial* connect; the redial loop runs on the same IO thread and inherits
  it, but verify the loop's backoff timer isn't a `sleep` that a suspended thread stalls
  (prefer a poll/eventfd wait so the quit pipe still works).

### Reconnecting UX (never a silent blank pane)

While redialing, draw a **reconnecting overlay** on the split (frozen last frame dimmed + a
"Reconnecting to cloud-1…" banner). **✅ IMPLEMENTED** as a dedicated SwiftUI
`ReconnectStateOverlay` (NOT a reuse of the mirror-ended `markMirrorEnded` path — that stays
mirror-only): it polls the lock-free `ghostty_surface_client_state` accessor and renders the pure
`reconnectBanner(state)` over the dimmed frame. The design's original three states became **five**
(see the design rule under "Fleet versioning"): `reconnecting` (transient), `session_ended`
(reattach returned a different id after host restart), `cannot_handshake` (EOF before ack —
ambiguous), `too_old` (decoded-ack MAJOR mismatch — loud + directional), `unreachable` (tunnel
dial failed).

---

## Cross-host agent ecosystem

The correlation must move from **local process-tree walking** (verified laptop-1-local, above)
to **environment self-identification**, which also works locally and is *more* robust.

### Inject `(host, session_id)` into the spawned shell's environment

When a `.client` spawns a fresh session, the host already accepts spawn-opts on `Attach`
(`working_directory`, `initial_input` — `protocol.zig:554`). Add the split's stable identity as
**environment** in the spawned shell, e.g.:

```
GHOSTTY_SURFACE_HOST=cloud-1
GHOSTTY_SURFACE_SESSION=<session_id>
GHOSTTY_MCP_URL=https://<laptop-tailnet-name>:<mcp-port>/agent-state
GHOSTTY_MCP_TOKEN=<mcp-token>
```

- Delivery mirrors the queue's existing dual-delivery of `GHOSTTY_QUEUE_TEMPLATE_DIR`
  (`env` for `.exec`; a command prefix for `.client` — `CLAUDE.md` agent-queue shared-templates
  bullet). For `.client` this rides the spawned shell (an `env`-prefix on the initial command,
  or a new spawn-opt env map on `Attach` if we want it clean — that would be a host touch;
  the command-prefix path avoids it).
- The `GHOSTTY_MCP_URL` points at the **laptop's tailnet address**, not `127.0.0.1`, so a cloud
  hook can reach the MCP server over the tailnet.

> **✅ As implemented (D6) — the env set above narrowed to ONE GUI-injected value.** The
> shipped self-ID delivers a single non-secret **per-spawn correlation NONCE**, not the
> `(host, session_id)` pair (the session id is minted host-side on `Attach`, AFTER the launch
> line is sent, so it isn't known when the initial input is built). `MCPLayout.newSplitCommand`
> injects `export GHOSTTY_SURFACE_NONCE=<nonce>` via `initial_input` and keeps a
> `nonce → (surfaceID, hostName, sessionID)` map; the hook POSTs `{nonce, state}`. **Neither
> `GHOSTTY_MCP_URL` nor a token is GUI-injected:** `GHOSTTY_MCP_URL` is a per-box, laptop-facing
> value provisioned in the BOX's own environment (its `ghostty-host` systemd unit
> `Environment=GHOSTTY_MCP_URL=…`; see Deployment), and the credential is a **per-box CAPABILITY
> token** the box reads from a 0600 file — NOT the master `mcp-token`, which never leaves the
> laptop (see "MCP over the tailnet" and the security posture).

### Hook self-identifies instead of walking ppid/tty

Update `ghostty-agent-state.sh` (`example/claude-hooks/`) so that **if `GHOSTTY_SURFACE_SESSION`
is set, it POSTs `{host, session, state}` directly** and skips the ppid/tty walk entirely.
The MCP `/agent-state` route (`MCPServer.swift:507`) gains a branch: when the body carries
`{host, session}` it resolves the surface by matching the persisted `(hostName, sessionID)`
pair (a direct map lookup) instead of `resolveSurface(forTTY:)`. This is:

- **Correct across hosts** (the cloud tty/pids are irrelevant; the token is the identity).
- **More robust locally** (no fragile ancestor-tty heuristic, no `claude-pool`-wrapper pid
  guessing).
- **Additive** (keep the tty path as a fallback for un-instrumented shells).

### MCP over the tailnet

- The MCP server currently binds loopback (`mcp-listen = 127.0.0.1:8765`, the token is a
  shell-execution credential). To be reachable from a cloud box, front it with `tailscale
  serve` (HTTPS on the tailnet, same pattern the web monitor already documents — `CLAUDE.md`
  web-monitor bullet, `WEB-MONITOR.md`) rather than binding `0.0.0.0`. The token travels to the
  cloud shell via `GHOSTTY_MCP_TOKEN`.
- ACL note: the tailnet ACL must permit the cloud box → laptop MCP port. Because the token is a
  shell-exec credential, the tailnet is the trust boundary; do not expose the port off-tailnet.

### claude / node / billing on the cloud box (flag)

An agent running on the cloud box runs **there**, so:

- `claude` and `node` must be installed **on the cloud box** and on the shell's PATH (the
  fork's robust `probeExecutableViaLoginShell` logic — `CLAUDE.md` Agent Manager bullet — is a
  *GUI-side* macOS probe; it does not help the remote box). Document this as a per-box setup
  step.
- Billing rides **whatever Claude auth exists on the cloud box** (its own `~/.claude` / config
  dir), which may be a *different* account than the laptop's. Call this out: the Agent
  Manager's warm-base account routing (`CLAUDE.md`) is laptop-local; a cloud agent's cost is on
  the cloud box's account and is **not** visible to the laptop's `get_haiku_usage`.
- The Agent Manager **summarizer/bell-classify** (Haiku calls made by the laptop sidecar) is a
  separate concern from the cloud agent's own Claude usage; the sidecar still runs on the
  laptop and classifies host-fed frames, so it works for a cloud split's *rendered output*
  without needing claude on the box. Only agents *launched on* the box (queue dispatch) need
  claude there.

---

## Per-action locality taxonomy

A cloud split's shell sees the **cloud filesystem**; a local split sees the laptop's. Every
"open something and do something" action has an implicit host. `cwd`/env resolve **relative to
the target surface's host**.

| Action / feature | Locality | Notes |
|---|---|---|
| `new_split` / `new_tab` (bare, inherit cwd) | **either** | Inherit cwd **from the source surface's host** — a cloud split's new tab inherits the cloud cwd; a local split's inherits the laptop cwd. The inheriting surface and source must share a host, or the cwd is meaningless. |
| `new_tab:<dir>` | **host of the new tab** | `<dir>` is a path on the **target** host. If the target is `local`, laptop path; if cloud, cloud path (no `~` expansion locally for cloud). |
| `new_tab_command:<cmd>` | **host of the new tab** | The command runs on the target host's shell (delivered as `initial_input`). |
| `new_split_on_host:<name>` / `new_tab_on_host:<name>` (proposed) | **cloud-only** target `<name>` | Fresh spawn on that host; cwd host-relative to `<name>`. |
| `toggle_project_selector` / `project-directory` | **needs a host answer** | See below — projects are per-host directory listings. |
| Agent Queue template `{templateDir}` + provider `list/status/claim` scripts | **runs where the queue runs** | The provider scripts and `{templateDir}` are resolved on the **laptop** today (GUI-side / sidecar). If a queue dispatches agents onto a cloud host, the *agent split* is cloud-side but the *provider scripts* are laptop-side — a split-brain the queue must make explicit (a per-queue `host` field). Flag as an open question. |
| Agent split env (`GHOSTTY_QUEUE_TEMPLATE_DIR`, item env) | **host of the agent split** | Must be delivered into the cloud shell (dual-delivery, above). A `{templateDir}` that names a laptop path is wrong for a cloud agent — either ship the scripts to the box or keep provider scripts laptop-side and only the agent remote. |
| `mark/pull/swap/flip/toggle/goto` split ops, `move_split_to_new_tab`, zoom | **host-agnostic** | Pure GUI layout transforms on `SplitTree`; they move *surfaces* (each keeping its own host) around the tree. A cloud split and a local split can be siblings. |
| `goto_last_surface`, dashboard/queue/manager tiles | **host-agnostic** | Operate on surfaces regardless of host, once correlation is `(host, session)`. |
| Clipboard (OSC52), title, bell, notifications, pwd (OSC7) | **host of the surface** | Already host-fed via `surface_event` frames; work unchanged over the tunnel. Bell/attention persist per surface. |
| `report_bug`, config discovery MCP tools | **laptop-only** | GUI/config features; no host relevance. |

### `project-directory` needs a "which host" answer

`project-directory` (fork-only, `Config.zig:2908`) lists **laptop** subdirectories today. For a
cloud host the project list must come from the **cloud** filesystem. Options (pick in
implementation):

1. **Per-host project bases**: extend the registry / add `pty-remote-project-directory =
   <name> = <base>` and have the project selector, when a cloud host is chosen, list the cloud
   box's subdirs (a small `ssh cloud-1 ls` over the multiplexed control connection, cached).
2. **Host-scoped picker**: the project palette first asks *which host*, then lists that host's
   projects; picking one opens a split **on that host** in that dir.

Recommend (2) layered on (1): the palette is host-aware, and each host contributes its own
bases. The MCP `list`/`describe` config discovery tools remain laptop-only.

---

## Fleet versioning + loud version-mismatch error

Today the GUI does **not** inspect versions and a mismatch is only a socket close (verified
above). With a *fleet* of independently-deployed hosts (some cloud boxes will lag the laptop's
host build), this becomes the dominant failure mode and **must be loud**.

- **The version requirement is the GUI's COMPILED constants** — NOT a new shipped-on-the-wire
  version window. The `Hello`/`HelloAck` already carry `major` + `minor`; the GUI compares the
  host's advertised `HelloAck` major/minor against its own compiled
  `protocol.PROTOCOL_VERSION_MAJOR`/`MINOR` (no additional Hello fields were added). The host
  already refuses a wrong major (`Server.zig:1142`, closes without an ack). **The MAJOR is the
  only incompatibility axis; a MINOR gap degrades gracefully** — the host gates every new
  host→GUI frame on the per-connection `negotiated_minor` and simply WITHHOLDS a frame the peer's
  minor doesn't support, so a too-old-by-minor host is never an error (never `too_old`).
- **✅ IMPLEMENTED (L1): the GUI reads + validates `HelloAck`.** The `hello_ack` arm in
  `Client.handleFrame` (previously swallowed by the `else`) decodes the ack, records the host's
  advertised major/minor into lock-free atomics (for the directional message), marks the
  handshake `ack_seen`, and — for a non-mirror role — sets the surface state to **`too_old`**
  ONLY on a MAJOR mismatch. The `ReconnectStateOverlay` renders that as a loud, actionable,
  DIRECTIONAL banner over the frozen frame:
  > `ghostty-host on cloud-1 is too old — host protocol 1.2, but this GUI needs major 3 (it
  > speaks 3.4). Redeploy ghostty-host on cloud-1 (see CLOUD-HOSTS-DESIGN.md → Deployment).`
  Because the host CLOSES before the ack on a real major mismatch, the *normal* major-mismatch
  path is actually EOF-before-ack ⇒ the ambiguous, retryable **`cannot_handshake`** state (its
  copy claims NO specific version — distinguishing it from the confident `too_old`, which only
  fires if a skewed/forged peer sends an ack despite a differing major). A failed tunnel dial is
  the distinct **`unreachable`**.
- **The host side surfacing a reason on refuse (`hello_nack`) is DEFERRED (L3).** Today it
  closes silently (`Server.zig:1146`). A tiny additive `hello_nack{reason}` frame would make the
  refuse explicit, but it is a **host protocol change**, and rebuilding `ghostty-host` ends every
  live RAM-only session — so it must ride a *scheduled* MINOR bump, not this phase. The shipped
  behavior is the no-host-change inference above (EOF-before-ack ⇒ `cannot_handshake`;
  decoded-ack major mismatch ⇒ `too_old`; connect failure ⇒ `unreachable`).
- **Reuse the existing non-destructive reload discipline** (`CLAUDE.md` "First-launch-setup" →
  reload identity): a MAJOR bump is a breaking fleet event; treat the fleet like the colleague
  fleet — bump `host_reload_epoch` / minor first so peers record identity, and never leave a
  major-N GUI silently talking to a major-(N−1) host. The blank-pane-on-major-mismatch is
  exactly what the loud error prevents.

**Design rule for this doc's whole feature:** any connect/handshake/version failure resolves to
a *named, actionable* surface state — never an unexplained blank pane. The implementation
(`termio.Client.State` ⇄ C `ghostty_client_state_e` ⇄ Swift `ClientState`) splits the original
"three states" into **five**: **reconnecting** (transient, drop in flight), **session_ended**
(host restarted → reattach returned a different id), **cannot_handshake** (connected but EOF
before any `HelloAck` — ambiguous: starting up / down / incompatible), **too_old** (decoded a
`HelloAck` with a mismatched MAJOR — confident + directional), **unreachable** (the tunnel dial
failed). `ok` is the sixth, normal, no-overlay value (and the value a `.exec`/local surface
always reports).

---

## Deployment (cloud box)

The cloud box has no GUI and no `ForkSetup` first-launch flow — it is a **manual deploy**, like
Ramon's hand-managed dev host (`CLAUDE.md` PTY-host LaunchAgent section), but under **systemd**
instead of launchd.

### The host is headless core Zig and builds on Linux

- `ghostty-host` is the headless core (`src/host/main.zig` `--listen=<path>`, `src/host/*.zig`);
  it links the core `src/` emulator, not the macOS app. Ghostty targets Linux, so the host
  cross-compiles/builds on Linux with the same `zig build -Demit-macos-app=false
  -Doptimize=ReleaseFast` invocation, producing `zig-out/bin/ghostty-host`.
- **The one portability caveat (narrowed by verification):** ONLY the `process_info` frame
  (name + command) is macOS-only — it resolves via `src/os/proc_info.zig` `resolve()` (`:118`,
  comptime-null off-Darwin) using `libproc` `proc_name` + `sysctl(KERN_PROCARGS2)` +
  `proc_listchildpids`. The **`foreground_pid` frame ALREADY works on Linux** (its pid comes
  from `tcgetpgrp`, which has a working Linux branch at `pty.zig:274-282`). So a Linux host
  emits correct `foreground_pid` out of the box; only the human-facing name/command was blank
  until `proc_info.zig` gained a `.linux` arm. **✅ Phase 4 IMPLEMENTED** — `resolve()` now returns
  first through `resolveLinux` on a `.linux` target (the Darwin sysctl/libproc body is comptime-dead
  there): it reads `/proc/<pid>/comm` (name) + `/proc/<pid>/cmdline` (command, NUL-separated argv)
  and does a `/proc`-PPID launcher descent (`/proc/<pid>/task/<pid>/children`, falling back to a
  `/proc/*/stat` PPID scan) via the generic `descendToProgramImpl` + the pure `pickDescendChild`, so
  classification finds the agent UNDER the `bash`/`claude-pool` wrapper, not the wrapper. The pure
  parsers/pickers (`parseProcCmdline` / `pickDescendChild` / `descendToProgramImpl` /
  `parsePpidFromStat`) are target-agnostic + unit-tested. This fills the already-negotiated minor-3
  `process_info` frame — **NO protocol change** — but it links into `ghostty-host`, so it is the
  **ONE Phase-4 host code change** (a Linux box's host must be rebuilt to name cloud agents); a
  dumb-terminal cloud split (Phases 0–2) needs none, and the macOS host is untouched. **Audited clean
  (no other macOS-only host-hot-path
  syscall):** PTY (`pty.zig` openpty/termios/TIOCSCTTY + `.linux` branches), spawn
  (`Command.zig:372-410,189` `.linux` dup3 + `fork`), event loop (`xev.Dynamic` →
  io_uring/epoll, `global.zig:17,123`), and SIGPIPE (globally ignored for all POSIX at
  `global.zig:215`, reached via `main_host.zig:27`, so a dropped forwarded socket won't kill the
  host). `build.zig:97-99` confirms `ghostty-host` builds natively on Linux.
- The socket-forwarding transport itself needs **no host change** — the host already listens on
  a Unix socket regardless of platform.

### systemd user unit (sketch — analogous to the documented macOS LaunchAgent)

```ini
# ~/.config/systemd/user/ghostty-host.service   (on cloud-1)
[Unit]
Description=ghostty-host (emulation-on-host backend)
After=default.target

[Service]
ExecStart=%h/.local/bin/ghostty-host --listen=%h/.ghostty-ramon-host.sock
# TERM/terminfo so the child shell gets xterm-ghostty (mirror of the LaunchAgent's
# GHOSTTY_RESOURCES_DIR env — point at the installed core resources on the box).
Environment=GHOSTTY_RESOURCES_DIR=%h/.local/share/ghostty
# (cloud-hosts, D6) The MCP ingest URL the agent-state hook POSTs to. It is a
# per-box, laptop-facing value and is NOT GUI-injected — set it HERE so the
# spawned shells (and thus a cloud agent's hook) inherit it. Point it at the
# laptop's tailnet /agent-state URL (fronted by `tailscale serve` for HTTPS).
# Omit for a dumb-terminal box that runs no cross-host agents.
Environment=GHOSTTY_MCP_URL=https://laptop.example.ts.net/agent-state
Restart=always
RestartSec=2
# The socket stays on loopback/AF_UNIX; only sshd reaches it via the -L forward.

[Install]
WantedBy=default.target
```

Enable with `systemctl --user enable --now ghostty-host` (and `loginctl enable-linger $USER`
so it runs while logged out — the "keep running while the laptop hibernates" property). Unlike
the macOS ad-hoc dev host, there is **no LWCR/cdhash trap** on Linux (systemd does not pin a
code-signing requirement), so a redeploy is a plain `systemctl --user restart ghostty-host` —
but that still **kills all RAM-only sessions on that box** (the inherent host trade), so
schedule it deliberately, exactly as documented for the macOS host.

### Per-box setup checklist (one-time)

1. Build/copy `ghostty-host` → `~/.local/bin/ghostty-host` on the box; place core resources for
   `GHOSTTY_RESOURCES_DIR`.
2. Write + enable the systemd user unit above; `enable-linger`.
3. Ensure the box is on the tailnet (Tailscale) and SSH-reachable from the laptop.
4. (For agents on the box) install `claude` + `node` on the box's PATH; log into the Claude
   account to bill; drop the self-identifying hook (`ghostty-agent-state.sh` variant) into the
   box's Claude Code settings. Set `GHOSTTY_MCP_URL` in the box's environment (the systemd
   unit above) to the laptop's tailnet `/agent-state` URL, and provision a per-box CAPABILITY
   token into a 0600 file the hook reads (default `~/.config/ghostty-ramon/mcp-capability-token`).
5. On the laptop: add a `pty-remote-host = <name> = <ssh-target> : <remote-socket>` line to
   `~/.config/ghostty-ramon/config`. For agents on the box, also add that box's capability
   token as `pty-remote-capability-token = <token>` (in `~/.config/ghostty-ramon/local`) so the
   MCP server ACCEPTS its `/agent-state` POSTs, and either front the MCP port with
   `tailscale serve` or add the laptop's FQDN via `pty-remote-mcp-allowed-host`.

---

## Security posture

- **Auth + encryption = SSH** (keys via the SSH agent) or **Tailscale SSH** (tailnet identity +
  ACLs). No credentials in the host protocol; `Hello.identity_bundle_id` stays advisory.
- **The host socket never leaves the box.** It is `AF_UNIX` on the box's loopback namespace;
  only `sshd` connects to it via the `-L` forward. There is no network listener to attack.
- **The forwarded local socket** lives under the laptop user's home (mode 0700 dir); local Unix
  socket perms apply.
- **MCP over tailnet**: the MCP token is a shell-exec credential, so the tailnet (with ACLs
  restricting which peers may reach the laptop's MCP port) is the trust boundary. Front with
  `tailscale serve` (HTTPS); never bind `0.0.0.0`. The token travels to the cloud shell as env
  over the (already-trusted) tunnel.
- **Blast radius**: a compromised cloud box can drive its own sessions and (with the token)
  call the laptop's MCP — scope MCP surface control accordingly; the token gates it and the
  ACL gates reachability.

---

## Wiring touchpoints (for the implementer)

Honest split of GUI-only vs host (session-loss) changes. **The SSH-forwarding transport choice
was made specifically to keep host changes near-zero — verified: transport needs no host
change** (the host already listens on a Unix socket). The only *potential* host touches are
(a) fleet-versioning niceties and (b) a Linux `/proc` port for agent detection — both
optional/phased.

### GUI-only (no host restart, no session loss)

- `src/config/Config.zig` — add `pty-remote-host` (RepeatableString, reuse `list_c` /
  `ghostty_config_string_list_s`), `pty-remote-ssh-options`, `pty-remote-project-directory`,
  `pty-remote-connect-timeout`. + parse tests. (Zig/lib rebuild, **not** a host rebuild — the
  host ignores these keys.)
- `src/termio/Client.zig` — add `Config.host_name`; **the redial loop** (reverse the single-shot
  `connectAndAttach`, opt-in per non-`local` host); reconnecting state + reuse `markMirrorEnded`
  dimming; read + validate `HelloAck` version → loud error state.
- `src/Surface.zig` — backend selection threads `host_name` (socket path resolved from the
  registry) alongside `pty-host`; session-id getter/setter gains the host component.
- `include/ghostty.h` + `src/apprt/embedded.zig` — add `host_name` to the surface config + a
  reverse getter (lib/xcframework rebuild; **no host compile** — these C exports aren't in
  `ghostty-host`).
- macOS: a **tunnel supervisor** (new file, e.g. `Features/RemoteHost/RemoteTunnelController.swift`)
  owning `ssh -L` `Process`es with ControlMaster/keepalive/backoff + parent-death guard;
  `SurfaceView.hostName` Codable sibling to `sessionID` (`SurfaceView_AppKit.swift`);
  restore/re-adopt keys on `(hostName, sessionID)`; `new_split_on_host` action + palette host
  picker; `spawn_split_command` host arg (`Features/MCP/…`); `/agent-state` route self-ID branch
  + `MCPAgentState` map lookup by `(hostName, sessionID)` (`MCPServer.swift`,
  `MCPLayout.swift`); reconnecting/ended/too-old overlays (`TerminalView.swift`).
- `example/claude-hooks/ghostty-agent-state.sh` — self-ID branch (`GHOSTTY_SURFACE_SESSION`) that
  POSTs `{host,session,state}` to `GHOSTTY_MCP_URL`, tty-walk kept as fallback.
- Agent-queue sidecar (`macos/agent-manager/`) — reconcile keyed on `(hostName, sessionID)`;
  per-queue `host` field for cloud dispatch; agent-split env delivery to cloud shells.

### Host changes (rebuild + systemd/LaunchAgent reload = SESSION LOSS — schedule deliberately)

- **None required for the core transport / multi-host / reconnect feature.** (This is the whole
  point of the SSH-forwarding choice.)
- *Optional, phased:* a `hello_nack{reason}` frame (additive, minor-gated) for an explicit
  version-refuse reason — only if we prefer that over the no-host-change EOF inference.
- *For full agent detection on a Linux cloud box:* port the `process_info` / `foreground_pid`
  resolution from macOS `libproc`/`sysctl` to Linux `/proc`. Needed only for cloud agents, not
  dumb cloud terminals.

---

## Testing plan (follow existing patterns)

- **Zig — protocol/version negotiation** (`src/host/test.zig`, `src/host/protocol.zig` tests,
  `src/termio/client_difftest.zig`): a Hello major-mismatch produces the loud path (assert the
  GUI-side classification of "got EOF with no HelloAck" → too-old vs "no socket" → unreachable);
  minor negotiation gates any new frame. Reuse the existing `TestListener` +
  connect/attach/resize lifecycle harness (`client_difftest.zig` T1/T2/T3).
- **Zig — reconnect** (new, `client_difftest.zig`): drive `connectAndAttach` against a
  `TestListener` that drops the connection after N frames; assert the redial loop reattaches
  with `Attach{session_id=<same>}` (not a fresh spawn), backs off, and never re-dials `local`
  (opt-in gate). A deterministic drop-then-accept repro like the SegmentedPool grow repro
  pattern (`src/datastruct/segmented_pool.zig` tests).
- **Zig — config** (`src/config/Config.zig` tests): `pty-remote-host: RepeatableString parse`
  (name/target/socket split; `local` reserved), mirroring the `agent-queue-templates-dir`
  parse test (`Config.zig:11761`).
- **Swift — host-registry + identity** (`macos/Tests/…`): registry line parsing (pure);
  `(hostName, sessionID)` Codable round-trip with `decodeIfPresent → local` back-compat
  (mirror the existing `sessionID`/`bell` Codable tests); re-adoption keys on the pair; the
  `/agent-state` self-ID map lookup vs the tty fallback (`MCPAgentStateTests`); the tunnel
  supervisor's backoff schedule (pure, like `AgentMirrorReconnectTests`
  `backoffQuickBurstThenSteadyMinute`).
- **Swift — version-mismatch UX**: assert a too-old host yields the actionable message string,
  a missing tunnel yields the unreachable message, and neither yields a blank pane.
- **Live smoke** (documented, like `PTYHOST.md`'s): stand up a `ghostty-host` on a Linux box +
  `ssh -L`, launch a cloud split, run `sleep 9999 & echo MARKER-$$`, sleep the laptop / drop
  WiFi, wake, and assert the split **reattaches** (same MARKER pid) after the tunnel
  re-establishes.

---

## Phased implementation plan (dumb-terminal first)

Build a rendering + reconnecting remote split **before** any agent-ecosystem work.

- **Phase 0 — Linux host bring-up (ops).** Build `ghostty-host` for Linux, systemd unit,
  Tailscale + SSH reachability. Manual `ssh -L` by hand; point a temporary `pty-host` at the
  forwarded socket and confirm a *single* remote split renders + takes input (no registry, no
  reconnect yet). This validates the transport with zero code.
- **Phase 1 — Multi-host client + registry + launch action.** `pty-remote-host` config,
  `host_name` through Client/Surface/C-ABI, `(host, session_id)` identity + persistence,
  `new_split_on_host` + palette. Tunnel supervisor **basic** (bring-up on first surface, no
  auto-respawn yet). Deliverable: mix local + cloud splits in one window; cloud split survives
  a **GUI restart** (reattach by `(host, session_id)`).
- **Phase 2 — Reconnect subsystem. ✅ IMPLEMENTED.** Layer-1 ssh-master respawn/readiness
  (`RemoteTunnelController` single-owner supervisor: surface refcount + never-give-up
  `respawnDelay` backoff + `ssh -O check`/`ssh -O exit` health/clean) + Layer-2 IO-thread redial
  state machine (`termio.Client`: opt-in `Config.reconnect`, `xev.Async` wakeup → backoff
  `xev.Timer` → read-thread respawn + re-`Hello`/`Attach`, per-attempt handshake watchdog) +
  the reconnect overlay (`ReconnectStateOverlay` over the frozen, dimmed last frame). Local
  stays byte-for-byte single-shot (`reconnect=false`). Deliverable: cloud split survives
  **sleep / WiFi roam / Tailscale reconnect** without a manual restart.
- **Phase 3 — Loud fleet versioning. L1 ✅ IMPLEMENTED; L3 DEFERRED.** The GUI now reads +
  validates `HelloAck` (the `hello_ack` arm in `Client.handleFrame` records the host's advertised
  major/minor and sets the **directional `too_old`** state on a MAJOR mismatch); the named error
  states (`too_old` / `cannot_handshake` / `unreachable` / `session_ended`) render as actionable
  banners (L1, `reconnectBanner`). **L3 (a `hello_nack{reason}` frame) is DEFERRED** — it is a
  host protocol change, and rebuilding the host ends every live RAM-only session, so it must ride
  a *scheduled* MINOR bump (not shipped in this phase). Until then a version refuse is inferred
  (host closes before `HelloAck` ⇒ the ambiguous `cannot_handshake`; a decoded-ack major mismatch
  ⇒ the confident `too_old`). Deliverable: an old cloud host shows an actionable message, never a
  blank pane.
- **Phase 4 — Cross-host agent ecosystem. ✅ IMPLEMENTED.** Nonce self-ID injection
  (`export GHOSTTY_SURFACE_NONCE` via `initial_input`) + the hook's `{nonce, state}` self-ID branch
  + the `/agent-state` nonce resolver (`RemoteAgentIdentity`); the PER-BOX capability token scoped
  to `/agent-state` only (never `/mcp` spawn) + MCP-over-tailnet host allow-list; `(host, session)`
  correlation across the dashboard stores / sidecar reconcile + schedule maps / the `list_surfaces`
  `sessionID` STRING composite (`"<host>:<id>"`); the Linux `/proc` arm for
  `foreground_pid`/`process_info` (the one host change); per-queue `host` (provider laptop-side,
  agent cloud-side) + `pty-remote-project-directory`; and the claude/node/billing docs. NO new MCP
  tool (count stays 26 — `spawn_split_command` gained an optional `host` arg). Deliverable: an agent
  on a cloud box shows in the dashboard/queue with correct state.
- **Phase 6 — Per-host transport-command override (single-forward transport). ✅ IMPLEMENTED.**
  A new fork-only `pty-remote-host-command = <name> = <command template>` key lets a box that is
  reachable ONLY through a wrapper (e.g. a gateway / launcher exposed as a shell
  FUNCTION that spins its own gateway per invocation) use a CUSTOM transport instead of the default
  `ssh` ControlMaster. When a `pty-remote-host` name has a matching command override, the tunnel
  supervisor runs **ONE long-lived forward process** built from the command through the user's
  **LOGIN + INTERACTIVE shell** (`<shell> -ilc '<command> -N -L <local>:<remote> -o
  ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -o
  StreamLocalBindMask=0177'`) so a shell function resolves — **NO ControlMaster, NO `ssh -O
  check`/`-O exit`, NO `-M`**. Readiness is the SAME `ghostty_probe_host` socket handshake and
  respawn is the SAME never-give-up process-exit watch (both already transport-agnostic), so ONLY
  the spawn changes. The remote socket path still comes from the `pty-remote-host` line (its
  ssh-target field becomes just a label when an override exists); the local socket stays under the
  0700 short dir (sun_path length-checked). A host WITHOUT an override uses the default `ssh`
  ControlMaster path BYTE-IDENTICALLY. GUI-lib + config-key only — NO host / protocol / wire
  change. Wiring: `src/config/Config.zig` (`pty-remote-host-command: RepeatableString` + parse
  test — added Phase 6); macOS `Ghostty.Config.swift` (`ptyRemoteHostCommandLines`),
  `RemoteHostRegistry.swift` (`RemoteHostEntry.transportCommand` + `parseCommand`/`parseCommands`
  + the two-arg `parse(lines:commandLines:)` builder), `RemoteTunnelController.swift` (pure
  `singleForwardArgv` + `loginShell` + `spawnCommandTunnel` (best-effort `setpgid` no-op + the
  interactive-shell self-led process group it actually relies on) +
  the `ensureTunnel` command branch + `forceKillCommandProcess` (process-GROUP teardown for the
  SIGTERM-ignoring interactive shell + forwarded-socket unlink) + the
  `cleanStaleControl`/`checkMasterHealth` command-mode guards), `SurfaceView_AppKit.swift`
  (`remoteHostRegistry()` passes the command lines — the one resolver that feeds `retainTunnel`),
  `MCPKnowledge.swift` (reader + cloud-hosts `configKeys`). Tests: Zig `pty-remote-host-command
  parse`; Swift `RemoteHostRegistryTests` (command parse/pairing) + `RemoteTunnelControllerTests`
  (`singleForwardArgv*` / command-mode-no-ControlMaster / `commandModeTransportProcessIsItsOwnGroupLeader`,
  the process-group-teardown leadership invariant). Deliverable: a wrapper-only box works.

Ship Phases 0–2 as the "cloud terminals" MVP; Phases 3–4 harden and extend to agents; Phase 6 adds
custom transports for wrapper-only boxes.

---

## Open questions

1. **Registry line format** — a `RepeatableString` of `name = target : socket` is proposed;
   is a structured config sub-object worth the extra C plumbing instead? (Recommend: no, reuse
   `list_c`.)
2. **`hello_nack` vs EOF inference** — add the additive frame for an explicit refuse reason, or
   infer "too old" from *connected-but-immediate-EOF-no-HelloAck*? The inference needs no host
   change; the frame is cleaner. (Recommend: inference now, frame during the next scheduled host
   bump.)
3. **Queue split-brain** — when a laptop queue dispatches agents onto a cloud host, provider
   `list/status/claim` scripts + `{templateDir}` are laptop-side but the agent split is
   cloud-side. Do we (a) ship provider scripts to the box, (b) keep provider laptop-side and only
   remote the agent, or (c) run the whole queue on the box? Needs a per-queue `host` design.
   **✅ RESOLVED + IMPLEMENTED (Phase 4, option b): per-queue `host`.** The template gains
   `host` (default `"local"`) + host-relative `agentWorkdir`/`remoteTemplateDir`. The PROVIDER
   commands ALWAYS run laptop-side; only the AGENT split is placed on `host` (via
   `spawn_split_command`'s optional `host` arg — no provider scripts shipped, whole queue not
   moved). `{templateDir}` DIVERGES: provider/param sites keep the laptop dir, `agent.command` gets
   `remoteTemplateDir` (dual-delivered as `GHOSTTY_QUEUE_TEMPLATE_DIR`). See AGENT-QUEUE.md →
   "Running a queue's agents on a remote host".
4. **`project-directory` per-host listing** — cache an `ssh cloud-1 ls` over the control
   connection, or require an explicit `pty-remote-project-directory` per box? (Recommend: both —
   explicit bases, listed via the multiplexed connection, cached.)
   **✅ RESOLVED + IMPLEMENTED (Phase 4, both): explicit bases + cached `ssh find`.** The fork
   config key `pty-remote-project-directory` (a `RepeatableString` of `<host> = <base>` lines,
   grammar parsed macOS-side by `ProjectPaletteView.parseRemoteProjectBases`) names the explicit
   bases; `RemoteTunnelController.ensureProjects`/`listProjects` list each base's immediate
   subdirs over the supervisor's ControlMaster (`ssh … find -L <base> -mindepth 1 -maxdepth 1
   -type d -print0`, `ls -1p` fallback) and CACHE it (stale-while-revalidate, ~1s TTL). The palette
   reads the cache synchronously (never blocks) and opens a tab that runs on the host.
5. **Linux host portability audit** — beyond `libproc`/`sysctl` for process info, is any other
   macOS-only syscall on the host's hot path? (Must audit before shipping a Linux host; the
   emulator core is portable, but verify PTY/`xev` specifics.)
   **✅ RESOLVED: audited clean.** `foreground_pid` already works on Linux (`tcgetpgrp`); only
   `process_info` (name/command) was macOS-only, now covered by the `proc_info.zig` `/proc` arm
   (Phase 4). PTY / spawn (`Command.zig` `.linux` dup3+fork) / `xev.Dynamic` (io_uring/epoll) /
   SIGPIPE (globally ignored) are all portable — no other macOS-only host-hot-path syscall. See
   "The host is headless core Zig and builds on Linux".
6. **Billing visibility** — a cloud agent bills the box's Claude account, invisible to the
   laptop's `get_haiku_usage`. Do we want a cross-host usage aggregation, or is per-box
   accounting acceptable? (Recommend: acceptable for v1; document it.)
   **✅ RESOLVED (per-box, docs-only): acceptable for v1.** `get_haiku_usage` tracks ONLY the
   laptop sidecar's own Haiku calls (summarizer / bell-classify / issue-key-infer); a cloud
   work-agent bills the box's own Claude account, invisibly — NOT a regression (it never tracked
   work-agent spend). No cross-host aggregation in v1; documented in AGENT-MANAGER.md → billing
   scope.
7. **App-Nap + redial** — ✅ SETTLED: poll on the read thread's quit self-pipe. The backoff is
   an `xev.Timer` on the IO loop (NEVER a bare `sleep`), so a clean quit stops the loop and
   cancels the timer; the read thread `poll()`s its quit self-pipe (Darwin has no eventfd), so a
   backgrounded IO thread still redials and still honors the quit signal.
8. **Sudden multi-host id collision** — two hosts *can* mint the same random u64. `(host,
   session_id)` disambiguates for reattach, but any place that ever keys on the bare u64 across
   hosts (audit `MCPLayout`, the sidecar store) must be found and switched to the pair.
   **✅ RESOLVED + IMPLEMENTED (Phase 4, Q2/Q3/D3): all bare-u64 keying switched to the pair.**
   The audit found and converted every site: `MCPLayout.surfacesJSONData` now emits `sessionID` as
   the STRING composite `"<host>:<id>"` (the matched emit↔parse pair — the sidecar `parseSessionKey`
   splits on the LAST `:`, a bare-number legacy value ⇒ host `"local"`); the sidecar keys
   `reconcile` (`liveBySession`/`claimedSessions`) and `scheduleSweep` (`bySession` re-adopt) on
   `sessionKey(host, id)` and persists `Assignment.hostName` / `ScheduleState.hostName`; the
   dashboard's `AgentStateStore` + `manualOrder` + the mirror-preview `.id` + the mirror dial use
   the composite `AgentSessionKey` (a pre-migration bare key reads back as `local:`). The web
   monitor's raw stream is the one exception — a remote surface is "stream unavailable" (falls back
   to the `/screen` poll), remote raw streaming being out of v1 scope.

---

## Verification log (corrections applied)

An independent citation-verification + adversarial-review pass ran against HEAD. This design
doc is a **design doc**; the build-ready spec (with all resolutions/mitigations folded in) is
**`CLOUD-HOSTS-IMPL-PLAN.md`**. Corrections applied to THIS doc so it no longer carries wrong
facts:

- **Backend selection line:** the `if (config.@"pty-host") |sock|` was at `Surface.zig:683`, not
  `~:667` (`:667` is the "SLICE 4 (backend selection)" comment). Behavior (`.client` via `try`,
  no `.exec` fallback) was correct. Also flagged: the socket was the GLOBAL scalar — no
  per-surface socket existed at design time (plan §D5). **Phase 1 done:** `Surface.init` now
  resolves the backend socket via `termio.Client.resolveSocketPath(per_surface_sock, config.@"pty-host")`
  (per-surface override wins), reading `rt_surface.pty_host_socket` / `rt_surface.host_name`
  (via `@hasField`) and threading `host_name` into `Client.Config`.
- **`.attach` EOF behavior:** the doc claimed a `.attach` EOF "tears down the read thread and the
  surface shows an error." Corrected: at design time, on EOF the `.attach` role `break`ed and
  re-polled (busy-looped, no `POLLHUP` check); on read error it returned but pushed NO surface
  message; all session-gone signalling was `is_mirror`-gated. **✅ Phase 2 ADDED the `.attach`
  teardown + signalling from scratch** (task G): every drop (EOF / read-error / fatal decode /
  poll-error / `POLLHUP`) now routes through `ReadThread.onAttachDrop`, exits the loop cleanly
  (no busy-loop), classifies a surface-visible `Client.State`, and wakes the IO-thread redial.
- **`markMirrorEnded` line:** declared at `Client.zig:1085` (self-locking wrapper → `:1052`
  `markMirrorEndedLocked`), not `:1066` (that's inside the doc-comment).
- **Linux portability:** `foreground_pid` ALREADY works on Linux (`pty.zig:274-282` `tcgetpgrp`);
  only `process_info` (name/command, `src/os/proc_info.zig` `resolve()`) is macOS-only. PTY /
  spawn / xev-Dynamic / SIGPIPE audited clean; the doc's `process_info`↔`foreground_pid` coupling
  was corrected.
- **Stale in-tree comment (fixed in Phase 1):** `include/ghostty.h` `session_id` used to say host
  session ids "start at 1"; `allocSessionId` (`Server.zig:1853`) actually mints RANDOM non-zero
  u64. Phase 1 corrected the header comment (random non-zero, `0` = "no session") while adding the
  adjacent `pty_host_socket` / `host_name` fields.

Open-question dispositions (full rationale + `planImpact` in the plan): OQ1 → RepeatableString
`pty-remote-host`, Swift-side grammar, no new C API. OQ2 → GUI reads/validates HelloAck now
(no host change), against its COMPILED `PROTOCOL_VERSION_MAJOR`/`MINOR` (no new Hello fields). A
MINOR gap DEGRADES (host withholds frames on `negotiated_minor`, never an error). The host's real
major-mismatch close path is EOF-before-ack ⇒ the AMBIGUOUS retryable `cannot_handshake` state; a
DECODED-ack MAJOR mismatch ⇒ the confident, directional `too_old` (L1 shipped). `hello_nack` (L3)
deferred to a scheduled MINOR bump (host rebuild = session loss). OQ3 → per-queue `host`
(provider laptop-side, agent cloud-side). **Phase 5 REFINES OQ3: the per-queue `host` is now a
weighted host POOL** (`hosts[]`) the supervisor spreads a queue's agents across by weighted-least-
loaded placement (`argmin(active / (maxConcurrent × weight))`), with a FLEET-WIDE per-host
`maxConcurrent` cap, a `hostCapacity` block reason when the pool is full, and down-host cooldown
degrade — sidecar + GUI-lib only, NO host/protocol change (placement rides the already-persisted
`Assignment.hostName` + the existing `spawn_split_command` `host` arg). Scalar `host` stays a valid
single-entry pool. See CLOUD-QUEUE-BALANCING.md + AGENT-QUEUE.md → "Multi-host load balancing". OQ4 → BOTH `pty-remote-project-directory` bases + cached
`ssh find` over the ControlMaster. OQ5 → Phases 0–2 ship with ZERO host changes; only
`proc_info.zig` needs a Linux arm (Phase 4). OQ6 → per-box billing, docs-only (`get_haiku_usage`
never tracked work-agent spend). OQ7 → `poll()` on the read thread's quit self-pipe (Darwin has no
eventfd); the redial backoff is an `xev.Timer` on the IO loop (never a bare `sleep`), cancelled
when a clean quit stops the loop. Settled + IMPLEMENTED. OQ8 → namespace by host LAPTOP-SIDE only (no protocol change); exhaustive site
list (incl. the dashboard `AgentStateStore`/`manualOrder` stores, `AgentPreviewTile` `.id`/dial,
and WebMonitor `routeStream` the original note missed) is in the plan (§D3, tasks Q3–Q4).

Adversarial-review blockers folded into the plan (§Cross-cutting decisions): tunnel-readiness
must be a full Hello→HelloAck round-trip (not a bare connect, which false-positives with
`ssh -L`); the redial must be an IO-thread state machine (the write path is IO-thread-owned);
three-way host resolution (unresolvable ≠ local fallback); do NOT ship the master `mcp-token` to
boxes (per-box capability-scoped token via a 0600 file) and correlate agents via a GUI-minted
nonce (session_id is unknown at spawn time).

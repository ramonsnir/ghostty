# Cloud-hosted terminals — BUILD-READY IMPLEMENTATION PLAN

Status: **SPEC — ready to hand to a fresh implementing session.** This is the build
spec; the design rationale lives in `CLOUD-HOSTS-DESIGN.md` (read it once for motivation,
then work from this file). Every task names exact files with **verified** citations at
HEAD; where the design doc carried a stale/wrong citation it is corrected here (and in the
design doc's Verification log).

> **Companion doc discipline (BLOCKING, per `CLAUDE.md`):** every task's code change lands
> in the SAME commit as its doc delta. The doc-delta list per phase is not optional.

---

## 0. How to read this plan

- **Phases 0–4** each have: (1) ordered task list (file + citation + concrete change),
  (2) config keys, (3) C-ABI / protocol touches (GUI-only rebuild vs host-rebuild =
  session loss), (4) test plan, (5) doc deltas, (6) local-vs-cloud-box validation boundary.
- **§Cross-cutting decisions** below resolves the hard design tensions the reviewers found
  (reconnect thread ownership, version classification, the security model, identity
  namespacing, the per-surface-socket gap). Read it before ANY phase task — several phase
  tasks are only correct in light of these decisions.
- **§Sequencing** partitions edits by owning file so multiple agents can run in parallel
  without edit races.

### Grounding corrections folded in (do not propagate the design doc's originals)

1. **Backend selection** is at `src/Surface.zig:683` — `const backend: termio.Backend =
   if (config.@"pty-host") |sock| backend: {` — **not** `:667` (that line is the "SLICE 4
   (backend selection)" comment). The `.client` arm at `:683` uses `try`, so a connect/attach
   failure propagates — **no silent `.exec` fallback**. It sets `.socket_path = sock` at
   `:683`/`:707`, reading the **global** scalar `config.@"pty-host"` for every `.client`
   surface. **There is NO per-surface socket path today** (see §Cross-cutting decision D5).
2. **`markMirrorEnded`** is declared at `Client.zig:1085` (self-locking wrapper), delegating
   to `markMirrorEndedLocked` at `:1052` — **not** `:1066` (that line is inside the doc-comment).
3. **`.attach` EOF does NOT tear down today.** `ReadThread.threadMainPosix` (`Client.zig:1813`):
   on a read **error** the `.attach` role `return`s/tears down (`:1856-1868`) but pushes **no
   surface message**; on a clean **EOF (n==0)** the `.attach` role just `break`s the inner loop
   and re-polls (`:1870-1877`). The outer `poll()` uses timeout `-1` and checks **only** the
   quit pipe `pollfds[1]` (`:1925`), never the socket's `POLLHUP` → a peer-closed socket
   busy-loops (read 0 → break → poll returns immediately on POLLIN → read 0 …). All
   session-gone signalling (synthetic `child_exited` via `markMirrorEnded`) is **`is_mirror`-gated**
   (`:1849,1860,1866,1874,1886,1895,1908,1921`). So "the surface shows an error" on a `.attach`
   drop is **not implemented** — Phase 2 must add it.
4. **`ghostty.h:497-499`** comment ("Host session ids start at 1, so 0 is a safe sentinel")
   is **stale**: `allocSessionId` (`Server.zig:1853`) mints **random non-zero u64** and dedups
   only within its OWN `self.sessions`. Fix the comment while touching the header.

---

## Cross-cutting decisions (resolve these tensions once)

### D1 — Version-refuse classification (the reviewers' #1 landmine)

A **MINOR** protocol gap is **never** a hard failure: the host gates new frames on
`negotiated_minor` (`Server.zig:2249,2257`) and simply withholds them, so a too-old-by-minor
host degrades gracefully. Only a **MAJOR** mismatch is a hard failure (`Server.zig:1142-1148`,
closes the connection **before** the `HelloAck` write at `:1154`, sends no frame).

**The GUI cannot infer "too old" from a bare EOF.** Under `ssh -L`, OpenSSH's local listener
`accept()`s immediately, then opens the remote channel; if the ControlMaster/remote socket
isn't ready yet, ssh accepts then closes with zero bytes — the **exact** connect-then-EOF-no-ack
signature of a major mismatch AND of a host that is simply down. So classify strictly:

| Observation | State | Message |
|---|---|---|
| `connect()` (dial local socket) fails | **host unreachable / tunnel down** | "Tunnel to `<host>` is down — retrying…" |
| connected, sent Hello, **got EOF before any HelloAck** | **cannot handshake (AMBIGUOUS)** — retryable | "Can't complete the handshake with `<host>` — it may be starting up, down, or running an incompatible `ghostty-host`. Retrying…" |
| decoded a **HelloAck** whose **major** ≠ GUI major, or a minor the GUI hard-requires is absent | **host too old / incompatible** — loud, actionable, do NOT retry silently | "`<host>`: ghostty-host is incompatible (host protocol `X.Y`, this GUI is `A.B`). Redeploy ghostty-host on `<host>` (see CLOUD-HOSTS-DESIGN.md → Deployment)." |

Consequences that shape the phases:
- **The GUI MUST read + validate `HelloAck` before it trusts a connection** (it does not
  today — no `.hello_ack` arm; the `else` arm at `handleFrame` (`Client.zig:1409`, `else => log.debug("client ignoring frame tag={}", .{tag})`; switch span ~`:1125-:1410`) swallows it,
  and Hello at `:730` is fired then Attach/subscribe at `:744+` **without awaiting the ack**).
  This "ack-seen" gate is a **Phase-2 prerequisite** (readiness classification depends on it),
  not a Phase-3 nicety.
- The confident "too old, redeploy" message only fires on a **decoded** HelloAck (same-major,
  minor-incompatible) or the optional `hello_nack` (Phase-4-later, host change, same-major only).
- The ambiguous "cannot handshake" banner is what makes a major mismatch **loud but never a
  silent blank pane**, without a host change, and without misdirecting the user to "redeploy"
  when the box is merely down.
- **Version window = compile-time constants** `PROTOCOL_VERSION_MAJOR/MINOR` (`protocol.zig:44,79`).
  **Do NOT add a config key**, and do NOT add a min-version field to `Hello` (pre-negotiation
  first frame; an old host's `Hello.decode` at `:478-489` ignores trailing bytes → invisible to
  exactly the old hosts you want to catch; appending after `identity_bundle_id` also breaks the
  `readBytes` trailing-field bound — if `Hello` ever must grow, convert `identity_bundle_id` to
  `readBytesField` first). All version signalling is **host→GUI** (HelloAck fields, or later
  `hello_nack`).

### D2 — Reconnect thread ownership + the wait primitive

The write path (`write_stream` = an `xev.Stream` on `td.loop`, `write_queue`, the two
`SegmentedPool`s, `socket_fd`) is owned by the **IO/xev-loop thread** (`Client.zig:1938-1966`)
and read by **unlocked atomic readers** (`queueWrite` at `:884`, `focusGained`). EOF is detected
on the **read thread** (`:1870`). Tearing down + reinstalling `write_stream`/`socket_fd` from the
read thread would be a cross-thread lifecycle UAF.

**Decision:** the reconnect is an **IO-thread state machine**, not a read-thread loop.
1. Read thread detects a `.attach` drop (EOF via new POLLHUP handling, read-error, or
   decode-fatal) → sets `Client.reconnecting` (atomic) so `queueWrite` **holds/drops** frames,
   then wakes the IO thread (xev async / mailbox) and exits the read loop cleanly (STOP — see D1
   grounding correction 3; today it busy-loops).
2. IO thread callback: deinit the old `write_stream` + close the old fd; **wait** the backoff;
   `connectUnix` a **new** fd; send `Hello`; **await `HelloAck`** (D1); send `Attach{session_id =
   <live id>}`; reinstall `write_stream`; clear `reconnecting`; respawn the read thread on the
   new fd.
3. **The backoff wait MUST NOT be `std.time.sleep`.** Use `posix.poll()` on the read thread's
   **quit self-pipe** fd (`internal_os.pipe()` at `Client.zig:666`; the quit fd is `pollfds[1]`
   at `:1836-1839`, woken by `threadExit`'s byte-write at `:809-817`, already checked at `:1925`)
   with the backoff as the poll timeout — return immediately if the quit fd is readable
   (clean shutdown, no `join()` hang), reconnect only on the timeout branch. This is the
   finite-timeout `poll()` the mirror role already uses (`MIRROR_POLL_TIMEOUT_MS`, `:1850,1914`).
   ("eventfd" from the design's OQ7 does not apply — Darwin has no eventfd; it's a self-pipe.)
   If the backoff wait runs on the IO thread instead, use an `xev` timer on `td.loop` (woken by
   loop stop on quit) — either is correct; **bare sleep is not**. Optionally add a second poll fd
   (a supervisor "tunnel-ready" self-pipe) so a redial wakes early on readiness.
4. **Opt-in via a positive bool** `Client.Config.reconnect` (default `false`), set `true` ONLY
   for a resolved **remote** host. Do NOT gate on a `host_name != "local"` string compare (a
   nil/"" default mishandled as remote would attach the redial loop to the local KeepAlive host
   and could storm it during a host bootout). `local` / nil host ⇒ `reconnect=false` ⇒
   byte-identical single-shot path.
5. **Black-holed tunnel:** a dead tunnel keeps the local socket open with no EOF for
   ~ServerAliveInterval×Count. So drive the reconnecting state from **three** signals, not just
   read-EOF: (a) a **write error** on the xev stream — `writeCallback` (`Client.zig:1782-1785`)
   must **notify the surface / trip `reconnecting`**, not just log; (b) the supervisor's
   ServerAlive-derived liveness (shorten `ServerAliveInterval` to ~5s); (c) read-EOF.

### D3 — Identity namespacing = laptop-side only; NO host protocol change

`allocSessionId` dedups within one host's registry, so the **wire u64 stays correct between the
GUI and a single host** — session_id remains a bare u64 in `Attach`/`Input`/frames. The
collision/mis-adopt problem is purely **where the GUI + sidecar AGGREGATE multiple hosts into one
keyspace**. Carry a sibling `hostName` (registry key; **absent/nil ⇒ `"local"`** for
back-compat) at every site that **persists** a session id or **dials a socket**; pair-key those.
Sites that key on the globally-unique macOS surface UUID (`view.id`) are collision-free and
unchanged. See Phase-1 task I1 and Phase-4 task Q3 for the exhaustive site list.

**Also switch the sidecar-facing sessionID to a string** (`"${hostName}:${sessionID}"` composite
where keyed): host ids are full 64-bit random and JSON `number` is lossy above 2^53 (the Codable
side already persists `String(id)`, `SurfaceView_AppKit.swift:2195`). String composite keys are
lossless and give the pair one clean key. **⚠️ This is a MATCHED emit↔parse pair, sequenced into
Phase 4 (task Q2), NOT Phase 1.** The `list_surfaces` emit (`MCPLayout.surfacesJSONData:246`) and
the sidecar readers (`mcp.ts:69` `SurfaceRow.sessionID`; `store.ts:444` parse + `store.ts`
finalize/reconcile keys; the `sessionKey` helper) MUST land in the SAME commit — the shipping
agent-queue reconcile parses `sessionID` as a **number** today (`typeof r.sessionID === "number"`),
so an emit-only flip coerces every row to `0` and silently breaks reconcile (see Phase-1 F1). Phase 1
adds ONLY the additive `hostName` field to the row and keeps `sessionID` as `NSNumber`.

### D4 — Reattach safety (never a silent wrong-host / duplicate / fresh-shell)

Three named terminal states, never an unexplained pane (design rule §564-566). Enforce:
- **Three-way host resolution** (not two-way): absent/nil `hostName` ⇒ `local`; present +
  resolvable in the registry ⇒ that host's forwarded socket; present + **UNRESOLVABLE** (renamed/
  removed registry line, config didn't load) ⇒ the **"host not in registry / unreachable"** error
  state — **NEVER** a local-socket fallback and **NEVER** a spawn. The existing unknown-id→
  fresh-spawn degrade (`handleAttach`, `Server.zig:1682`) is safe ONLY after dialing the resolved
  host.
- **Reattach id gate:** redial-as-reattach only when `Client.session_id != 0` (set on `Attached`,
  `:748`; default 0, `:239`). If the id is still 0 (initial spawn's `Attached` never arrived), do
  NOT blindly re-Attach with `session_id=null` — that spawns a **second** session and orphans the
  first (`handleAttach` spawn path, `Server.zig:1682`). Treat a 0-id drop as a fresh not-yet-started
  surface (safe re-spawn only if no `initial_input` side effects were expected). Document the
  orphan-until-host-restart consequence; a client spawn-nonce is a Phase-4-later host-side option.
- **Reattach-miss = loud "session ended," not a log.** Convert `att.session_id != requested`
  (today a bare `log.warn` at `Client.zig:1245-1256`) into the **visible "session ended (host
  restarted on `<host>`)"** state, distinct from "reconnecting." This is the only reliable
  session-ended signal besides the explicit `child_exited` frame (`protocol.zig:110`). Do NOT
  store the returned fresh id and continue.

### D5 — The per-surface socket path gap (load-bearing for Phase 1)

`Surface.init` reads the **global** `config.@"pty-host"` as THE socket for every `.client`
surface (`Surface.zig:683/707`). `ghostty_surface_config_s` / `embedded.zig` Options carry
`session_id`/`mirror`/`working_directory`/`initial_input` but **no socket path or host name**. So
"a cloud split dials a different forwarded socket" needs:
- (a) **`ghostty_surface_config_s`** + `embedded.zig` Options gain **two additive, defaulted-null
  fields**: `pty_host_socket` (the GUI-resolved local forwarded socket path; null ⇒ fall back to
  the global scalar) and `host_name` (the identity label; null ⇒ `"local"`).
- (b) **`Surface.init`** prefers the per-surface socket over the global scalar:
  `const sock = options.pty_host_socket orelse config.@"pty-host"`, and threads `host_name` into
  `Client.Config`.
- (c) The **name → socket resolution is GUI-side** (the Zig core cannot read the Swift registry).
  The tunnel supervisor resolves `host_name` → forwarded socket path and passes the RESOLVED path
  as `pty_host_socket`. `host_name` is only additionally needed for identity/persistence.
- (d) **No reverse `host_name` C getter is required** (unlike `ghostty_surface_session_id()`,
  which reads a host-assigned runtime atomic — `embedded.zig:1678`). `host_name` is caller-supplied
  and never mutated by the host, so the GUI persists the name it passed. (A getter is cheap and
  symmetric if desired, but not on the critical path — skip it for v1.)

### D6 — Cross-host agent security model (reshapes Phase 4)

The design's "inject the master `mcp-token` + `GHOSTTY_SURFACE_SESSION=<session_id>` via the
initial-command prefix" is **broken on two counts** and is replaced:
- **Do NOT ship the master `mcp-token` to any box.** It is the fork's one shell-execution
  credential (`MCPServer.swift:15,43`) — a compromised box could drive `spawn_split_command` on
  the laptop and, with the new `host` arg, on the whole fleet. Instead mint a **per-box,
  capability-scoped token** (authorizes `/agent-state` ingest ONLY — add a token→allowed-methods
  map in `decideRoute`), provisioned once per box into a **0600 file** the hook reads (like the
  laptop's `~/.config/ghostty-ramon/local`), **never** via the command prefix (which leaks to
  `ps`/shell history — the exact leak `ghostty-agent-state.sh` avoids with `curl -K -`). Rotate
  per box.
- **`session_id` is unknown at spawn** (minted host-side on `Attach`, not known to the GUI until
  the `Attached` reply — the command prefix is sent *before* it exists). So correlate on a
  **GUI-minted per-spawn nonce**: the GUI mints a random correlation id, injects it via
  `initial_input` (a **non-secret correlation id** — the SSH same-user boundary already trusts
  co-processes on the box), and keeps a `nonce → surface` map that records `(hostName, sessionID)`
  once the `Attached` reply lands. The hook POSTs `{nonce, state}` (+ its per-box token); the
  route resolves `nonce → surface`. **`MCPAgentState.parse` must be extended** to accept a
  nonce-carrying body with no `tty` (today `parse` hard-requires a non-blank `tty`,
  `MCPAgentState.swift:33-35`). Keep the tty-walk path as a local fallback.
- Socket perms: create forwarded socket + ControlPath under a **0700 dir** AND set
  OpenSSH `StreamLocalBindMask=0177` (socket 0600); verify perms post-creation and refuse to dial
  a group/other-accessible socket. Document that any same-user local process can pivot via these
  sockets (the laptop account is the trust boundary).
- MCP over tailnet: `hostHeaderAllowed` (`MCPServer.swift:434-436,586-591`) will **403** a
  tailnet-origin request (its Host is the MagicDNS name, not `127.0.0.1`). Either configure
  `tailscale serve` to rewrite Host to the loopback value (preferred — keeps the rebinding guard
  tight) or add the exact tailnet FQDN to the allowed-Host set (never a wildcard).

### D7 — SSH tunnel supervisor: single owner, not per-surface

The supervisor is the **single owner** of `ssh` spawn + backoff **per host**; surfaces are pure
consumers of one readiness `Publisher` (they await it; they never spawn ssh or poll-connect the
tunnel themselves). Use a dedicated master owned by the supervisor (forwarders use
`ControlMaster=no`) so it can health-check with `ssh -O check` and clean a stale socket with
`ssh -O exit` / unlink ControlPath before respawn. Reasons:
- N cloud splits share one master ⇒ shared fate; a per-surface backoff would thundering-herd the
  tunnel on a drop. One owner, one backoff, one readiness signal fans out.
- **The orphan-guard precedent does NOT transplant.** That guard is Node code inside the sidecar
  (`index.ts:152-184`); an unmodified `ssh` child can't run it, and a GUI SIGKILL is exactly when
  `Process.terminationHandler` does not fire. Use a **short `ControlPersist`** so an orphaned
  master times itself out, and/or wrap `ssh` in a tiny ppid-watching launcher. Only
  `AgentManagerController`'s **launch + `terminationHandler`-restart scaffolding** transfers
  (`:191,:498`) — **not** its backoff policy, which **gives up** after `restartMaxAttempts=8`
  (`:112,:231-234`) and clamps at `restartDelayMax=30s` (`:592`). Layer-1 wants never-give-up; copy
  the **`AgentPreviewTile` `mirrorReconnectDelay`** shape instead (quick burst → steady cadence
  forever, `CLAUDE.md` "Preview auto-reconnect").
- **GUI env ≠ shell env.** `childEnvironment` seeds from `ProcessInfo.processInfo.environment`
  (`AgentManagerController.swift:260`), which for a launchd/Finder-launched GUI lacks shell-exported
  vars. `SSH_AUTH_SOCK` is usually launchd-injected (OK for the default agent), but a shell-set
  agent (1Password/custom) or shell `ssh` config needs the same login-shell env probe
  (`resolveNodePath`/`runLoginShell -lc/-ilc`) the sidecar controller already uses. Reuse it.
- **`sun_path` is ~104 bytes** and `connectUnix`→`initUnix` (`Client.zig:1793,1801`) errors on
  overflow; so does `ssh -L`'s local socket. Derive the forwarded socket under a SHORT dir
  (`$TMPDIR/gr-<shorthash>.sock`), length-check it, and map overflow to a specific actionable error
  (not the generic "unreachable"). Probe OpenSSH ≥ 6.7 (unix→unix forwarding) once and surface a
  clear "ssh too old for unix forwarding" message.

---

## Config keys (all fork-only; keep in `~/.config/ghostty-ramon/config`)

All reuse the existing `RepeatableString` + `list_c` + `ghostty_config_string_list_s` bridge
(`Config.zig:6365,6375,6388`; `include/ghostty.h:557-561`; generic `ghostty_config_get` dispatch
`CApi.zig:102` / `c_get.zig:16`) — **NO new C API for config** — or a plain scalar. Each fork key's
doc comment MUST begin with the `(ramon fork` marker so the MCP knowledge tools auto-classify it.

**⚠️ MCPKnowledge coverage = TWO DISTINCT guards, TWO separate edits (verified at HEAD — do NOT
conflate them):** every fork-only key must be registered in BOTH structures in
`MCPKnowledge.swift`, each guarded by its own test:
1. **The `readers` table** (`MCPKnowledge.swift:52`, the `get_effective_config` `ValueReader` list;
   `RepeatableString` keys like `project-directory`/`agent-queue-templates-dir` appear there with an
   explicit reader) — guarded by **`readersIncludeAllForkOnlyKeys`** (`MCPServerTests.swift:1657`).
2. **Some `FeatureDoc.configKeys`** (`MCPKnowledge.swift:130`, the `docs_for_feature` table) —
   guarded by the DISTINCT **`featureDocsCoverAllForkOnlyKeys`** (`MCPServerTests.swift:1622`).

Adding a key to ONLY one of the two fails the OTHER test — a hard build break. So all four new keys
(`pty-remote-host`/`-ssh-options`/`-connect-timeout`/`-project-directory`) need a `readers`
`ValueReader` entry (RepeatableString keys via `.joined(separator:)` mirroring the
`agent-queue-templates-dir` reader at `:52`; `pty-remote-connect-timeout` via its u32 getter) AND a
`FeatureDoc.configKeys` entry. The concrete `readers` edits are owner task **MCP-K1** below (Phase 1);
the `FeatureDoc.configKeys` edits are in the per-phase doc deltas.

| Key | Type | Phase | Parse-test name (`Config.zig`, mirror `:11761`) |
|---|---|---|---|
| `pty-remote-host` | `RepeatableString` | 1 | `pty-remote-host: RepeatableString parse` |
| `pty-remote-ssh-options` | `?[]const u8` | 1 | `pty-remote-ssh-options parse` |
| `pty-remote-connect-timeout` | `u32` (seconds; feeds backoff cap only, NOT a protocol field) | 2 | `pty-remote-connect-timeout parse` |
| `pty-remote-project-directory` | `RepeatableString` (lines `<name> = <base>`) | 4 (key may land in 1) | `pty-remote-project-directory: RepeatableString parse` |

`pty-remote-host` line grammar (**parsed entirely Swift-side** — `RepeatableString.parseCLI`
stores the value verbatim and does **not** trim; the CLI/file parser splits only on the FIRST `=`,
`args.zig:128`, and empty value = list-clear, `Config.zig:6399-6403`):

```
# name = ssh-target : remote-socket-path  [ : local-socket-path ]
pty-remote-host = cloud-1 = user@cloud-1.example.ts.net : ~/.ghostty-ramon-host.sock
```

Swift parser rule (the SOLE home of the grammar): split `name` on the **first `=`**, split the
remainder on **spaced ` : `** (not a bare `:`, so `user@host`, IPv6 `::1`, and `=`-free socket
paths are unambiguous), and **trim each field**. `local` is a reserved name mapping to the scalar
`pty-host` (never a remote entry).

---

## C-ABI / protocol change ledger

**GUI-lib-only (lib/xcframework rebuild; NO `ghostty-host` compile; NO session loss)** — these C
exports/structs are compiled into the GUI lib, not the host:
- `ghostty_surface_config_s` + `embedded.zig` Options: `pty_host_socket` + `host_name` (D5, Phase 1)
  + `pty_host_connect_timeout_s` (REG-T2, Phase 2).
- `Surface.init` per-surface socket preference (D5, Phase 1) + connect-timeout thread (REG-T2, Phase 2).
- `ghostty_probe_host` + `ghostty_host_probe_s` (B5, Phase 1): a headless Hello→HelloAck probe
  reusing `protocol.zig` encode/decode, compiled into the GUI lib only (NOT `ghostty-host`). Feeds
  the C3 readiness gate + Phase-2 version classification.
- `Client.zig`: `Config.host_name`, `Config.reconnect` (Phase 1), `Config.connect_timeout_s` (REG-T2,
  Phase 2), the redial state machine, HelloAck read/validate, EOF/error/decode `.attach` teardown +
  named states. Phases 1–3.
- `include/ghostty.h`: the two Phase-1 surface-config fields + `ghostty_probe_host`/
  `ghostty_host_probe_s` (B5) + the Phase-2 `pty_host_connect_timeout_s` field; fix the stale
  `session_id` comment. Phase 1.

**Host-rebuild = LaunchAgent/systemd reload = SESSION LOSS (schedule deliberately):**
- **NONE for the core transport / multi-host / reconnect / versioning feature.** (This is the whole
  point of SSH-forwarding + host→GUI version signalling via the already-existing HelloAck fields.)
- *Phase-4-later, optional:* a `hello_nack{reason}` frame (additive, appended at the END of
  `FrameType`, minor bump 4→5, same-major refuse only) for a host-authored refuse reason.
- *Phase-4, for cloud AGENT detection only:* a Linux `/proc` arm in `src/os/proc_info.zig` (NOT a
  protocol change — it fills the already-negotiated minor-3 `process_info` frame). `foreground_pid`
  (minor-4) already works on Linux (see Phase 4).

**Protocol invariants to assert (a `protocol.zig` test):** `FrameType` tag values (`:95`) are
**append-only within a major**; if `hello_nack`/ack-before-close is ever adopted, the host must
send ONLY the fixed-layout `HelloAck` before closing on a major mismatch so a skewed GUI can safely
decode that one version-independent frame.

---

# PHASE 0 — Linux host bring-up (OPS; zero code)

**Goal:** validate the SSH-forwarding transport with a single remote split, no registry, no
reconnect. This is done by hand and produces no committed code — but it gates everything.

### Tasks
1. **Build `ghostty-host` for Linux.** On the box (or cross): `zig build -Demit-macos-app=false
   -Doptimize=ReleaseFast` → `zig-out/bin/ghostty-host`. Grounded buildable on Linux by
   `build.zig:97-99` (host target excluded only for wasm / cross-Darwin). Copy to
   `~/.local/bin/ghostty-host` on the box; place core resources for `GHOSTTY_RESOURCES_DIR`.
2. **systemd user unit** `~/.config/systemd/user/ghostty-host.service` (sketch in
   CLOUD-HOSTS-DESIGN.md §Deployment); `systemctl --user enable --now ghostty-host`;
   `loginctl enable-linger $USER`.
3. **Tailscale + SSH reachability** from the laptop; confirm `ssh <box>` works.
4. **Manual tunnel:** `ssh -N -L /tmp/gr-cloud1.sock:~/.ghostty-ramon-host.sock <box>` (OpenSSH
   ≥ 6.7 for unix→unix). Temporarily point a laptop `pty-host = /tmp/gr-cloud1.sock`, launch ONE
   split, confirm it renders + takes input.

### Config / C-ABI / protocol
None.

### Test plan (acceptance, not code)
- **Live soak on the Linux xev backend.** `xev = @import("xev").Dynamic` runtime-detects to
  io_uring/epoll on Linux (`global.zig:17,123`); the spurious-`child_exited` handling and the
  `SegmentedPool` grow fix were debugged on **kqueue** only. Completion-queue semantics differ —
  run a multi-hour session (heavy paste, output bursts, resize, reattach) and confirm no input
  freeze / no `invalid state in submission queue` bursts before building anything on top.
- SIGPIPE is already globally ignored on the host for all POSIX (`global.zig:215` via
  `main_host.zig:27`), so a dropped forwarded socket won't kill the host — verify (drop the tunnel
  mid-write, host stays up).

### Doc deltas
- CLOUD-HOSTS-DESIGN.md §Deployment: confirm the unit + checklist match reality.
- (No CLAUDE.md bullet yet — no code.)

### Local vs cloud boundary
**Needs a real Linux box.** Everything here is ops. Nothing testable purely locally.

---

# PHASE 1 — Multi-host client + registry + launch action

**Goal:** mix local + cloud splits in one window; a cloud split **survives a GUI restart**
(reattach by `(host, session_id)`), given the tunnel is up. Per D-decisions, Phase 1 includes a
**minimal supervisor with a readiness gate** (bring-up on demand + poll-connect-to-HelloAck ready
signal) and a **deferred first dial** for restored non-local surfaces — WITHOUT the auto-respawn/
mid-session redial (that is Phase 2). This resolves the reviewer blocker that "survives GUI
restart" is impossible under an eager single-shot dial when the tunnel isn't up at restore time.

### Ordered tasks

**A. Config (owner file: `src/config/Config.zig`)**
- **A1** Add `pty-remote-host: RepeatableString = .{}`, `pty-remote-ssh-options: ?[]const u8 =
  null` with doc comments beginning `(ramon fork / cloud-hosts) …`. Reuse `list_c`/`cval` — NO
  header/CApi change for `pty-remote-host`. Add parse tests `pty-remote-host: RepeatableString
  parse` and `pty-remote-ssh-options parse` (clone the `agent-queue-templates-dir` test at `:11761`).

**B. C-ABI surface config (owner files: `include/ghostty.h`, `src/apprt/embedded.zig`,
`src/Surface.zig`, `src/termio/Client.zig` Config)**
- **B1** `include/ghostty.h`: add `const char* pty_host_socket;` and `const char* host_name;` to
  `ghostty_surface_config_s`; fix the stale `session_id` comment at `:497-499` (random non-zero,
  not "start at 1").
- **B2** `src/apprt/embedded.zig`: add the two nullable fields to the surface Options struct that
  maps `ghostty_surface_config_s` (defaulted null), thread them into the core `Surface` options.
- **B3** `src/Surface.zig:683`: change the `.client` backend selection to prefer the per-surface
  socket — `const sock = options.pty_host_socket orelse config.@"pty-host"` — and pass
  `host_name` into `Client.Config`. Keep the `try` (no `.exec` fallback). (D5.)
- **B4** `src/termio/Client.zig`: add `Config.host_name: ?[]const u8` (identity, threaded to the
  `(host_name, session_id)` pair) and `Config.reconnect: bool = false` (Phase 2 uses it; declare
  now so the ABI is stable). No behavior change yet.
- **B5** **Handshake-probe C export (THE production mechanism for the C3 readiness gate — resolves
  the reviewers' #1 blocker "ready fires only after a full Hello→HelloAck round-trip, not a bare
  connect").** There is NO Swift frame codec today (the handshake lives entirely in the Zig
  `Client`), and the Client's own dial is deferred + single-shot (E2 `materializeClientSurface`)
  and runs only AFTER readiness fires — so readiness must be established **out-of-band, before any
  `Client` exists**. Add a GUI-lib-only C export that does exactly one Hello→HelloAck round-trip
  and reports the result:
  - `include/ghostty.h`: `typedef struct { bool reachable; bool handshaked; uint16_t major;
    uint16_t minor; } ghostty_host_probe_s;` + prototype `ghostty_host_probe_s
    ghostty_probe_host(const char* socket_path, uint32_t timeout_ms);`.
  - `src/apprt/embedded.zig`: implement `ghostty_probe_host` by **REUSING `protocol.zig`'s `Hello`
    encode + `HelloAck` decode** (the same byte layout the `Client` uses — `Hello.encode`,
    `HelloAck.decode` at `protocol.zig:478-524`), NOT a hand-rolled framer, so there is zero risk
    of Swift/Zig wire drift (the drift this plan treats as a chokepoint elsewhere). It
    `connectUnix`es the given path (reusing `Client`'s `connectUnix`/`initUnix` at `:1793,:1801`),
    writes a `[u32 BE len][u8 tag][Hello payload]` frame, reads one framed reply with the timeout,
    and returns `{reachable=connect ok, handshaked=decoded a HelloAck, major, minor}`. Works
    **headless** (no host rebuild — `ghostty_probe_host` is compiled into the GUI lib, never into
    `ghostty-host`; the code it reuses already exists there for the mirror/attach path).
  - This ALSO hands Phase 1 the host version fields **for free** — the probe's `major`/`minor` feed
    the Phase-2 `too_old`/`cannot_handshake` classification (D1), so a lagging host can already be
    flagged at readiness time reusing the D1 table (full mid-session classification stays Phase 2).

**C. macOS registry + tunnel supervisor (owner files: new `Features/RemoteHost/`,
`Ghostty.Config.swift`)**
- **C1** `Ghostty.Config.swift`: add `ptyRemoteHostLines: [String]` getter — a byte-for-byte copy
  of `agentQueueTemplatesDirs` (`~:1004`) / `projectDirectories` (`:820`) over
  `ghostty_config_string_list_s`. (Confirmed: this is a third near-identical ~8-line copy, not a
  reuse — that's fine.)
- **C2** New `Features/RemoteHost/RemoteHostRegistry.swift`: pure `parse(line:) -> RemoteHostEntry?`
  implementing the grammar in §Config keys (first `=`, spaced ` : `, trim; `local` reserved). The
  SOLE home of the line grammar. Build `[name: RemoteHostEntry]`.
- **C3** New `Features/RemoteHost/RemoteTunnelController.swift`: the **single-owner** supervisor
  (D7). Phase-1 scope: `ensureTunnel(host:) async` that spawns the dedicated `ssh` master +
  forwarder `Process` (ControlMaster owned centrally, forwarders `ControlMaster=no`; keepalive
  `ServerAliveInterval=5`; `StreamLocalBindMask=0177`; socket under a 0700 short dir per D7), and a
  **readiness `Publisher`** whose "ready" fires only after a **full Hello→HelloAck round-trip** over
  the forwarded socket (NOT a bare connect — D1 blocker). **The round-trip is performed by calling
  the `ghostty_probe_host` C export (task B5) off-main** on the resolved forwarded socket path;
  readiness fires ONLY on `handshaked == true` (a bare `reachable == true` connect is NOT ready —
  that is the exact `ssh -L` accept-then-EOF false-positive D1 warns about). The controller does NOT
  implement any Swift-side frame codec (there is none, and B5 avoids the Swift/Zig wire drift). Poll
  the probe on the supervisor's backoff cadence until it handshakes. The probe also returns the host
  `major`/`minor`, which the controller stashes so a `too_old` host can be surfaced at readiness time
  per D1 (full classification is Phase 2). Login-shell env probe for `ssh`/agent (D7). Parent-death:
  short `ControlPersist` (Phase 2 hardens). No auto-respawn yet.

**D. Launch action + palette (owner files: `src/input/Binding.zig`, `src/input/command.zig`,
`src/Surface.zig`, `src/apprt/action.zig` + `include/ghostty.h`, macOS handlers + new palette)**
- **D1** `src/input/Binding.zig`: add fork-only surface-scoped actions
  `new_split_on_host:<name>` / `new_tab_on_host:<name>` (mirror `new_tab:<dir>` parse shape; add
  `Binding new_split_on_host` round-trip test).
- **D2** `src/input/command.zig`: command-palette entry "New Split on Host…" (opens a host picker;
  no default keybind — needs an argument).
- **D3** `src/apprt/action.zig` (+ `include/ghostty.h`): if a new apprt action/Key enum entry is
  needed, append it **LAST** (union order must match the `Key` enum — the `hide_dashboard_split`
  lesson). Prefer reusing the existing `.new_tab`/`.new_split` action with the resolved socket +
  host_name threaded on the SurfaceConfiguration (fewer enum touches).
- **D4** macOS: the action handler resolves `<name>` in the registry (C2), `await`s
  `ensureTunnel`'s readiness (C3), then spawns a bare `.client` `SurfaceConfiguration` carrying
  `ptyHostSocket=<resolved>` + `hostName=<name>` (session_id null ⇒ fresh spawn on that host).
  New `Features/Command Palette/RemoteHostPalette.swift` (fuzzy host picker, like `ProjectPalette`;
  add to the iOS exclusion set in `project.pbxproj`).

**E. Identity persistence (owner file: `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`)**
- **E1** Add `hostName: String?` as a Codable sibling to `sessionID` (`:239` field, `:2121`
  CodingKeys, `:2151` decode, `:2184-2195` encode). **Encode only for non-local** (nil ⇒ local ⇒
  omit — keeps existing local/.exec archives byte-identical, matching the `encodeIfPresent`/gated
  discipline); decode `decodeIfPresent ?? nil` (= local). (D3, identity-persistence MINOR.)
- **E2** Restore/re-adopt: **defer the first dial** for a restored **non-local** surface to the
  supervisor readiness signal (C3) — do NOT dial eagerly at surface creation (the tunnel isn't up at
  restore time; the single-shot `.client` dial would blank — the App-Nap/single-shot-connect hazard
  `CLAUDE.md` warns about). **Concrete construction path (all citations verified at HEAD):**
  - The eager dial is `ghostty_surface_new(app, &surface_cfg_c)` at
    **`SurfaceView_AppKit.swift:453-454`**, inside the designated init `init(_ app:baseConfig:uuid:)`
    (`:280`); it synchronously builds the `.client` backend, which single-shot dials. The restore
    convenience init `init(from:)` (`:2131`) builds a `SurfaceConfiguration` (`config` at `:2141`,
    `config.sessionID` at `:2151`) and funnels into that designated init — so the dial fires from
    restore too.
  - The socket is resolved from that config in `SurfaceConfiguration.withCValue`
    (**`SurfaceView.swift:711`**) where `config.session_id` is populated at **`:749`**; this is the
    site that will also populate `config.pty_host_socket` / `config.host_name` /
    `config.pty_host_connect_timeout_s` (the D5/REG-T2 Options fields) next to the `session_id` write.
  - **Prerequisite (PERSIST-owned):** add `ptyHostSocket: String?` + `hostName: String?` to
    `SurfaceConfiguration` (`SurfaceView.swift:668`, beside `sessionID`) and their `withCValue`
    population at `:749`. (B2/B3 add the matching C-ABI/core side; this is the Swift struct side.)
  - **Deferral primitive (choose "gate the dial", NOT a background thread):** in the designated init
    (`:446-460`), when `baseConfig.hostName` resolves **non-local**, SKIP the `ghostty_surface_new`
    call and leave `self.surface == nil` (already a legal, render-empty state; the `self.error` arm at
    `:456-458` is the existing not-yet-live path). Store the pending `(hostName, resolvedSocketPending)`
    and SUBSCRIBE (on main) to the supervisor's readiness `Publisher` (C3). When it fires "ready"
    with the resolved forwarded socket, a NEW `materializeClientSurface()` main-thread method sets
    the resolved `pty_host_socket` on the config and calls `ghostty_surface_new` exactly once, then
    assigns `self.surfaceModel` (mirror the `:453-460` body). This gates the Client dial on readiness
    WITHOUT holding the whole `SurfaceView`/AppKit view construction. A local (`hostName` nil/`local`)
    surface takes the unchanged eager path at `:453-454` (byte-identical).
  - **Three-way host resolution** (D4): an **unresolvable** non-local `hostName` ⇒ set `self.error`
    to the "host not in registry / unreachable" state, **never** a local-socket dial and never a spawn.
  - **Interim "awaiting tunnel" placeholder — owner: OVERLAY (`TerminalView.swift`)** using the K1
    named-state scaffolding built in Phase 2; until K1 lands, PERSIST ships a minimal inline
    placeholder view driven by the `self.surface == nil && pendingRemoteHost != nil` condition so the
    pane is never an unexplained blank (design rule §564-566).

**F. list_surfaces carrier (owner file: `macos/Sources/Features/MCP/MCPLayout.swift`)**
- **F1** Add `hostName: String` to `SurfaceRow` (`:109`), populate at `:184/:201`, and **emit it**
  in `surfacesJSONData` (`:246`) next to `sessionID` — this field is **genuinely additive** (nothing
  reads `hostName` off the row until Phase 4 Q2/Q3), so it is safe to land alone here.
  **⚠️ Do NOT flip `sessionID`'s wire type in Phase 1.** Keep the existing `NSNumber(value:)`
  emit at `:246`. The `sessionID` number→string(`"${host}:${id}"`) switch (D3) is a **matched
  emit↔parse pair** that MUST land in the SAME phase/commit as the sidecar readers — the
  currently-shipping agent-queue reconcile consumes `sessionID` as a **number** today (`mcp.ts:69`
  `sessionID?: number`; `store.ts:444` `typeof r.sessionID === "number" ? r.sessionID : 0`), so
  flipping the emit alone makes every row arrive as `typeof "string"` → coerced to `0` → no
  reconcile match → the queue's restart re-adoption and same-sweep adopt fold-in silently break
  (the exact "matched pair must both land" chokepoint this plan cites for `coerceQueueCommands`).
  The switch is therefore **Phase-4 task Q2** (emit here + the sidecar `mcp.ts`/`store.ts` parse in
  one commit). If the >2^53 JSON-`number` lossiness must be fixed sooner, pull the WHOLE Q2
  sidecar-parse update forward into Phase 1 — never ship the emit alone.

**MCP-K. MCPKnowledge coverage — the TWO-guard registration (owner file:
`macos/Sources/Features/MCP/MCPKnowledge.swift`; see §Config keys → "TWO DISTINCT guards")**
- **MCP-K1** For EACH fork-only key as it lands (`pty-remote-host` + `pty-remote-ssh-options` +
  `pty-remote-project-directory` here in Phase 1; `pty-remote-connect-timeout` in Phase 2), make TWO
  separate edits, else the two coverage tests fail:
  - **(a) `readers` table** (`:52`): add a `ValueReader` entry. The three `RepeatableString` keys read
    via `.joined(separator:)` over the `Ghostty.Config` list getter (byte-copy the
    `agent-queue-templates-dir` reader at `:52` — it already `.joined`s a `[String]`);
    `pty-remote-connect-timeout` reads via its `ptyRemoteConnectTimeout` u32 getter (Phase-2 task
    REG-T1). Satisfies **`readersIncludeAllForkOnlyKeys`** (`MCPServerTests.swift:1657`).
  - **(b) `FeatureDoc.configKeys`** (`:130`): add the key to a `configKeys` list — a NEW
    `"cloud-hosts"` `FeatureDoc` (preferred; groups all four + carries the enabled/requires predicate)
    or fold into an infra feature. Satisfies **`featureDocsCoverAllForkOnlyKeys`**
    (`MCPServerTests.swift:1622`).
  Update the `MCPServerTests` pure-helper/entries assertions if the new `FeatureDoc` changes counts.

### Config keys
`pty-remote-host`, `pty-remote-ssh-options` (A1). `pty-remote-project-directory` may land here too
(scalar-cheap, consumed in Phase 4).

### C-ABI / protocol
- GUI-lib-only: B1–B5 (incl. the `ghostty_probe_host` handshake export), F1-adjacent surface reads.
  Lib/xcframework rebuild; **no host rebuild**.
- Protocol: none (B5 REUSES the existing `Hello`/`HelloAck` layout — no new frame/tag).

### Test plan
- **Zig** `Config.zig`: A1 parse tests. Backend selection — a Zig test that `Surface.init` with a
  non-null `options.pty_host_socket` uses it over `config.@"pty-host"` (extend the surface-init test
  set; if none exists, a focused unit test on the `orelse` resolution).
- **Zig** `ghostty_probe_host` (B5): a test listener that accepts, reads a `Hello` frame, writes a
  `HelloAck` → `ghostty_probe_host` returns `{reachable, handshaked, major, minor}` with the
  advertised version; a listener that accepts then closes with zero bytes →
  `{reachable=true, handshaked=false}`; no listener → `{reachable=false}`. (Pattern:
  `client_difftest.zig`'s `TestListener`.)
- **Swift** `macos/Tests/RemoteHost/RemoteHostRegistryTests.swift`: `parse(line:)` cases — spaced
  ` : `, `user@host`, IPv6, `=`-free socket, trimming, `local` reserved, malformed → nil.
- **Swift** `SurfaceView` Codable: `hostNameRoundTripsForRemote`, `absentHostNameDecodesLocal`,
  `localSurfaceArchiveByteIdentical` (mirror the existing `sessionID`/`bell` Codable tests).
- **Swift** re-adoption: a restored non-local surface enters "awaiting tunnel" and dials only after
  a ready signal; an unresolvable `hostName` → error state (D4). Pure test on the resolution helper.
- **Swift** `RemoteTunnelControllerTests`: readiness fires only after `ghostty_probe_host` reports
  `handshaked==true` — stand up a fake local socket acceptor that speaks the real `Hello`→`HelloAck`
  frames (so the actual B5 export decodes it), and assert a bare-`reachable` accept-then-EOF acceptor
  does NOT fire ready (D1's `ssh -L` false-positive). Assert the stashed host `major`/`minor` match
  what the acceptor advertised (feeds Phase-2 classification).

### Doc deltas (same commit)
- `CLOUD-HOSTS-DESIGN.md`: status → "Phase 1 implemented"; fix the citations per §0.
- `CLAUDE.md`: new summary bullet "Cloud-hosted terminals (Phase 1: multi-host client + registry +
  launch)" + a wiring list (Config.zig keys, Client.Config.host_name/reconnect, Surface.zig
  per-surface socket, ghostty.h/embedded.zig fields incl. `ghostty_probe_host`/`ghostty_host_probe_s`,
  RemoteHostRegistry/RemoteTunnelController, RemoteHostPalette, SurfaceView hostName, MCPLayout
  hostName emit — note `sessionID` stays `NSNumber` until Phase 4 Q2). Add the new keys to the
  fork-only config list.
- `PTYHOST.md`: note the per-surface socket override + `(host, session_id)` identity.
- `example/ghostty-ramon/config`: a **commented** `pty-remote-host = cloud-1 = user@example.ts.net
  : ~/.ghostty-ramon-host.sock` example (neutral placeholder — NO real names, per the rule).
- `MCPKnowledge.swift`: register the Phase-1 keys per task **MCP-K1** — BOTH the `readers` table
  (`ValueReader` via `.joined(separator:)`, satisfies `readersIncludeAllForkOnlyKeys`) AND a
  `FeatureDoc.configKeys` entry (a new "cloud-hosts" feature or an infra feature, satisfies
  `featureDocsCoverAllForkOnlyKeys`). BOTH edits are required or one of the two tests fails.

### Local vs cloud boundary
- **Local:** everything except an actual remote render — config parse, registry parse, Codable,
  backend selection, palette, supervisor readiness (with a fake local socket acceptor). The
  supervisor can bring up a tunnel to a **second local host** (a second `ghostty-host` on a
  different socket) to exercise multi-host without a cloud box.
- **Needs a box:** end-to-end "cloud split survives GUI restart" — validated by launching a cloud
  split, restarting the GUI, confirming reattach (same shell/pid).

---

# PHASE 2 — Reconnect subsystem

**Goal:** a cloud split survives sleep / WiFi roam / Tailscale reconnect with no manual restart, and
**never shows a silent blank pane** — three named states (reconnecting / session ended /
cannot-handshake-or-unreachable). Per D1, the **HelloAck read** and the **`.attach` clean-teardown**
land here (they are reconnect prerequisites), and a **minimal loud "cannot handshake" banner** lands
here (pulled forward from Phase 3 so Phase-0/1 multi-box use is never a silent blank pane).

### Ordered tasks (owner file: `src/termio/Client.zig`, plus macOS overlay + supervisor)

**G. `.attach` clean teardown + named states (Client.zig — PREREQUISITE)**
- **G1** Add explicit `POLLHUP`/EOF handling to the `.attach` path so a peer-closed socket **stops
  the read loop cleanly** instead of busy-looping (grounding correction 3): in `threadMainPosix`
  make the outer `poll()` also watch the socket fd's `POLLHUP`/`POLLERR`, and on `n==0` for the
  `.attach` role transition to a named state + exit the loop (do NOT re-poll forever). Cover the
  read-error (`:1856-1868`) and `reader.next`/`handleFrame` decode-fatal (`:1889-1910`) `.attach`
  paths too — today they `return` silently with no surface signal.
- **G2** Add a surface-visible **state channel** for `.attach`: `reconnecting`,
  `session_ended`, `cannot_handshake` (ambiguous/retryable), `too_old` (confident), `unreachable`.
  Reuse the mirror-ended/dimming surfacing pattern (`markMirrorEnded` at `:1085` /
  `markMirrorEndedLocked` at `:1052`) rather than inventing a new channel; surface to Swift via a
  small accessor (extend an existing status accessor or add one in `embedded.zig` + `ghostty.h`).

**H. HelloAck read + version classify (Client.zig — PREREQUISITE, D1)**
- **H1** Add a `.hello_ack` arm to `handleFrame` (today swallowed by the `else` at `:1409`, `else => log.debug("client ignoring frame tag={}", .{tag})`; switch span ~`:1125-:1410`)
  decoding `protocol.HelloAck` (`:497-524`), storing host major/minor + an **`ack_seen`** bool
  (under `renderMutex`).
- **H2** Compare host major/minor to compiled `PROTOCOL_VERSION_MAJOR/MINOR`; on incompatibility set
  the **`too_old`** state with a directional message (host's real version vs GUI's). On a
  connect-then-EOF **before** `ack_seen`, set **`cannot_handshake`** (ambiguous, keep redialing). A
  `connectUnix` failure sets **`unreachable`**. (D1 table.)

**I. IO-thread redial state machine (Client.zig, D2/D4)**
- **I1** Implement the reconnect per D2: read thread detects drop (G1) → sets `reconnecting` atomic
  (queueWrite holds/drops) → wakes IO thread → IO thread deinits stream+fd, **poll-waits the backoff
  on the quit self-pipe** (never `sleep`, D2.3), `connectUnix` new fd, `Hello`, **await HelloAck**
  (H1), `Attach{session_id=<live id>}` (D4 gate: only if `session_id != 0`; else treat as fresh),
  reinstall `write_stream`, clear `reconnecting`, respawn read thread. Backoff shape = quick burst →
  steady cadence forever, its per-attempt ceiling = **`Config.connect_timeout_s`** (the Client.Config
  field added by REG-T1 below; a compiled default when 0). Gated on `Config.reconnect`
  (D2.4) — `local` never redials.
- **I2** Reattach-miss → `session_ended` (D4): convert the `att.session_id != requested` log
  (`:1244-1256`) into the visible state; do NOT store the returned fresh id.
- **I3** Write-error trip (D2.5): `writeCallback` (`:1782-1785`) sets `reconnecting` on error
  instead of only logging, so a black-holed tunnel surfaces in seconds.

**J. Layer-1 supervisor: respawn/keepalive (RemoteTunnelController.swift, D7)**
- **J1** Auto-respawn the `ssh` master on exit with the `AgentPreviewTile` backoff shape
  (never-give-up, per-attempt ceiling = `ptyRemoteConnectTimeout` per REG-T3), `ssh -O check` health
  probe, `ssh -O exit` + unlink stale ControlPath before respawn, recreate the forwarded socket. Fan
  the readiness/liveness signal to all surfaces for that host (single owner). Tear down when the last
  surface for the host closes (respecting `ControlPersist`). Optional: a "tunnel-ready" self-pipe the
  redial's poll wakes on (D2.3).

**K. Reconnecting overlay (owner file: `macos/Sources/Features/Terminal/TerminalView.swift`)**
- **K1** Draw the three named states over the frozen dimmed last frame: "Reconnecting to `<host>`…",
  "Session ended (host restarted on `<host>`)", and the loud "cannot handshake / too old /
  unreachable" banner (D1). Never leave an unexplained blank pane (design rule §564-566).

**REG-T. `pty-remote-connect-timeout` getter + threading into both backoff caps (owner files:
`src/config/Config.zig`, `Ghostty.Config.swift`, `include/ghostty.h`, `src/apprt/embedded.zig`,
`src/Surface.zig`, `src/termio/Client.zig`, `RemoteTunnelController.swift`)**
- **REG-T1** (CFG) Add the `pty-remote-connect-timeout: u32` config key + doc comment beginning
  `(ramon fork / cloud-hosts) …` + parse test `pty-remote-connect-timeout parse` (mirror the
  `agent-queue-hero-max` u32 field). (REGISTRY) `Ghostty.Config.swift`: add a **non-optional** u32
  `ptyRemoteConnectTimeout` getter — byte-copy the `agentQueueHeroMax` getter (a plain
  `ghostty_config_get` scalar read; do NOT read into a `UInt32?`, the latent-Optional-tag bug called
  out for `agent-queue-max-total`). (MCP) Register it in `MCPKnowledge.readers` (via this getter) AND
  a `FeatureDoc.configKeys` per task MCP-K1.
- **REG-T2** (CABI) Thread the value to the Zig redial as a THIRD defaulted-null surface-config field
  alongside D5's two: `include/ghostty.h` `ghostty_surface_config_s` gains `uint32_t
  pty_host_connect_timeout_s;` (0 = use compiled default), `embedded.zig` Options gains the field,
  `Surface.zig:683` threads it into `Client.Config.connect_timeout_s: u32 = 0`. The supervisor
  (RemoteTunnelController, macOS) sets it on the bare `SurfaceConfiguration` from
  `ptyRemoteConnectTimeout` when it dials a remote host. `Client.zig` I1 uses `Config.connect_timeout_s`
  as the redial backoff ceiling (compiled default when 0). This is an additive C-ABI touch (GUI-lib
  rebuild; NO host rebuild — `Client.zig`/the surface Options are not compiled into `ghostty-host`).
- **REG-T3** (REGISTRY) `RemoteTunnelController.J1` caps its OWN `ssh`-respawn backoff at
  `ptyRemoteConnectTimeout` too (read the Swift getter directly — the supervisor is macOS-side, no
  Zig threading needed for its own loop), so the tunnel-owner and the per-surface redial share one
  user-facing ceiling.

### Config keys
`pty-remote-connect-timeout` (u32; backoff cap only — NOT a protocol field). Owner task **REG-T1**:
the Zig key + parse test `pty-remote-connect-timeout parse`, the non-optional `ptyRemoteConnectTimeout`
Swift getter, and the MCPKnowledge readers + FeatureDoc coverage (MCP-K1). Threaded to the Zig redial
via REG-T2 and to the supervisor via REG-T3.

### C-ABI / protocol
- GUI-lib-only: all of G–K + the state accessor in `embedded.zig`/`ghostty.h` + **REG-T2's third
  surface-config field** `pty_host_connect_timeout_s` (`ghostty_surface_config_s`/`embedded.zig`
  Options/`Surface.zig`→`Client.Config.connect_timeout_s`). Lib/xcframework rebuild; **no host
  rebuild** (Client.zig + the surface Options are not linked into `ghostty-host`).
- Protocol: none.

### Test plan (pattern: `src/termio/client_difftest.zig` T1/T2/T3 + SegmentedPool deterministic repro)
- **Zig** `client_difftest.zig`: a `TestListener` that (a) drops the connection after N frames →
  assert redial reattaches with `Attach{session_id=<same>}` (not fresh), backs off, honors the quit
  pipe mid-backoff (no `join()` hang), and **never re-dials `local`** (assert against
  `Config.reconnect=false`). (b) A **drop-then-accept with an outstanding queued write** → assert no
  double-close/UAF of `write_stream`/pools (the D2 hazard). (c) EOF-before-ack vs EOF-after-ack map
  to distinct states; a HelloAck with mismatched major → `too_old`; `connectUnix` fail →
  `unreachable`. (d) `att.session_id != requested` → `session_ended`; `session_id==0` drop does NOT
  spawn a duplicate (D4).
- **Swift** version-UX: `tooOldYieldsActionableMessage`, `missingTunnelYieldsUnreachable`,
  `ambiguousEOFYieldsCannotHandshakeNotTooOld`, and **none yields a blank pane**.
- **Swift** `RemoteTunnelControllerTests`: backoff schedule pure test (mirror
  `AgentMirrorReconnectTests.backoffQuickBurstThenSteadyMinute` /
  `backoffSettlesAtSteadyIntervalForever` / `backoffNeverNegativeOrZero`).
- **Live smoke** (documented, like PTYHOST.md): `sleep 9999 & echo MARKER-$$`, sleep the laptop /
  drop WiFi, wake, assert the split reattaches (same MARKER pid).

### Doc deltas
- `CLOUD-HOSTS-DESIGN.md`: Phase-2 status; correct §"The connect is SINGLE-SHOT" bullet 3 to the
  real `.attach` EOF behavior; reword OQ7 to "poll on the read thread's quit self-pipe (settled)."
- `CLAUDE.md`: extend the cloud-hosts bullet (reconnect subsystem, opt-in `reconnect` bool, IO-thread
  state machine, three named states, write-error trip); note it's GUI-only (no host restart).
- `PTYHOST.md`: the reconnect/redial section (reverses the deliberate single-shot decision **for
  remote hosts only**; local stays single-shot).

### Local vs cloud boundary
- **Local:** the entire Zig redial state machine (deterministic `TestListener` drop/accept), the
  supervisor backoff (pure), overlays. Exercise a real drop against a **second local host** by
  `kill`-ing its `ssh` forwarder.
- **Needs a box:** the sleep/roam live smoke.

---

# PHASE 3 — Loud fleet versioning (refinement)

**Goal:** an old cloud host shows an **actionable, directional** message. Most of the machinery
(HelloAck read, `ack_seen`, the four version states) already landed in Phase 2 (D1 made it a
reconnect prerequisite). Phase 3 is the **message-granularity refinement** + optional host frame.

### Ordered tasks
- **L1** (GUI-only) Sharpen the `too_old` message with the exact host vs GUI versions and the
  redeploy pointer; ensure a minor-only gap is **never** rendered as an error (it degrades — D1).
  Distinguish `too_old` (confident, from a decoded HelloAck) from `cannot_handshake` (ambiguous EOF)
  in the overlay copy.
- **L2** (protocol test) Add the `protocol.zig` test asserting `FrameType` tag-order stability within
  a major (append-only invariant).
- **L3** (OPTIONAL, Phase-4-later — do NOT ship on its own) `hello_nack{reason}`: append at the END
  of `FrameType`, `HelloNack{reason:[]const u8}` encode/decode, bump `PROTOCOL_VERSION_MINOR` 4→5;
  `Server.zig` emits it BEFORE close **only** for a same-major refuse **and** only when the refused
  Hello's minor ≥ 5 (else keep the silent close → EOF inference); `Client.zig` `.hello_nack` arm
  surfaces the authored reason. **This is a host rebuild = session loss** — ride an already-scheduled
  MINOR bump only. Per `CLAUDE.md`, a MINOR bump is safe for the non-destructive fleet transition;
  **do NOT bump MAJOR** while any colleague lacks a recorded reload identity.

### Config keys
None (version window = compiled constants, D1).

### C-ABI / protocol
- L1–L2: GUI-lib-only / test-only.
- L3 (optional): host rebuild + MINOR bump = session loss.

### Test plan
- **Zig** `src/host/test.zig` / `client_difftest.zig`: feed a HelloAck with mismatched major → GUI
  classifies `too_old`; assert EOF-before-ack vs EOF-after-ack distinct (already in Phase 2, extend
  with the directional-message assertion). `protocol.zig` enum-order-prefix test (L2). If L3:
  same-major-minor-<5 refuse still EOFs; minor-≥5 refuse decodes `hello_nack`.
- **Swift** the directional-message string test (host older vs GUI older).

### Doc deltas
- `CLOUD-HOSTS-DESIGN.md` §"Fleet versioning": scope "min required major/minor" to **compiled
  constants** (not config); state a MINOR gap degrades (never fatal). Resolve OQ2.
- `CLAUDE.md` + `PTYHOST.md`: the version-classification table; if L3, the new frame + minor bump.

### Local vs cloud boundary
- **Local:** all classification tests (fake HelloAck). Two local hosts at different compiled
  versions is awkward locally; the `TestListener` covers it deterministically.
- **Needs a box:** confirming a genuinely-lagging cloud host shows the message end-to-end.

---

# PHASE 4 — Cross-host agent ecosystem

**Goal:** an agent on a cloud box shows in the dashboard/queue with correct state. This is the
largest and most security-sensitive phase; D6 replaces the design's self-ID transport, and D3
completes the identity namespacing across the sidecar + dashboard stores.

### Ordered tasks

**M. Secure self-ID transport (D6)**
- **M1** (macOS) GUI mints a **per-spawn correlation nonce**; keep a `nonce → surface` map that
  records `(hostName, sessionID)` once the `Attached` reply lands. Deliver the nonce via
  `initial_input` (non-secret correlation id). Files: the spawn path (`MCPLayout.newSplitCommand`
  `:479-482`, launch handler), a new `Features/RemoteHost/RemoteAgentIdentity.swift` for the map.
- **M2** (ops + hook) Per-box **capability-scoped token** provisioned once into a **0600 file** on
  the box; `example/claude-hooks/ghostty-agent-state.sh` gains a branch: if
  `GHOSTTY_SURFACE_NONCE` is set, POST `{nonce, state}` to `GHOSTTY_MCP_URL` reading the token from
  the 0600 file via `curl -K -` (never argv). Tty-walk kept as the local fallback.
- **M3** (macOS `MCPServer.swift` + `MCPAgentState.swift`) `/agent-state` route (`:452,:507`) gains
  a nonce branch resolving `nonce → surface`; **extend `MCPAgentState.parse`** (`:33-35`) to accept
  a nonce body with no `tty`. Add a **token → allowed-methods** map in `decideRoute`
  (`:434-436,:586-591` neighborhood) so a per-box token authorizes `/agent-state` ONLY, never `/mcp`
  spawn/input. Configure `tailscale serve` Host rewrite (or add the tailnet FQDN to the allowed-Host
  set) so the rebinding guard doesn't 403 tailnet origins. Rate-limit + log identity assertions.

**N. Linux `/proc` port for agent detection (host change, but NO protocol change)**
- **N1** `src/os/proc_info.zig`: add a `.linux` arm to `resolve()` (`:118`, comptime-null off-Darwin
  today) reading `/proc/<pid>/comm` (name) + `/proc/<pid>/cmdline` (NUL-separated argv — add a pure
  NUL-split parser unit-tested like the existing `parseProcArgs2`). Port
  `descendToProgram`/`singleChildForDescent` to walk `/proc/<pid>/task/<pid>/children` (fallback: scan
  `/proc/*/stat` PPID) so classification finds the real agent under the `bash`/`claude-pool` wrapper,
  not the wrapper. Keep the pure `isLauncher`. **`foreground_pid` already works on Linux** via
  `pty.zig:274-282` `tcgetpgrp` — no change needed there; only `process_info` (name/command,
  minor-3) needs this. This fills an **already-negotiated** frame — no protocol touch. **Host rebuild
  = session loss on the box** — schedule deliberately; not needed for dumb cloud terminals.

**O. Queue split-brain: per-queue `host` (adopt option (b) — provider laptop-side, agent
cloud-side)** — sidecar + macOS, NO wire-protocol change:
- **O1** `queue/types.ts`: `QueueTemplate.host` (default `"local"`), `agentWorkdir` /
  `remoteTemplateDir` (host-relative, absolute, NOT laptop-expanded).
- **O2** `queue/templates.ts`: `validateTemplate` **must whitelist** `host` / `agentWorkdir` /
  `remoteTemplateDir` (else silently dropped — the `coerceQueueCommands` lesson); make
  `substituteTemplateDir` (`:54-70`) route the **remote** dir into `agent.command` only, keeping the
  **laptop** dir in the four provider/param sites.
- **O3** `queue/wiring.ts`: do NOT `expandHome` the agent workdir against the laptop home (`:232`);
  provider `cwd` stays laptop-side (`realExec` `:105`).
- **O4** `queue/runner.ts`: agent `base.cwd` (`:1802`) + `GHOSTTY_QUEUE_TEMPLATE_DIR`/
  `templateDirAssign` (`:1789-1795,:1803`) use the **host-relative** dir when `host != local`;
  provider `queueProviderEnv`/`cwd` (`:1041/:1325`) stay laptop; add `host` to `spawnArgs`.
- **O5** `mcp.ts`: `spawn_split_command` wire carries `host`; read `hostName` back off
  `list_surfaces` (`SurfaceRow.hostName`, `:69`).
- **O6** macOS `MCPTools.swift`: `spawn_split_command` schema gains optional `host` (**tool count
  stays 26** — mind `toolsListHasAllTools`); `MCPLayout.newSplitCommand(host:)` (`:479-482`) resolves
  the registry socket, ensures the tunnel, sets `pty_host_socket`+`host_name` on the bare
  `SurfaceConfiguration`.

**P. `pty-remote-project-directory` + host-aware project palette (config + macOS + supervisor)**
- **P1** Config key `pty-remote-project-directory: RepeatableString` (may have landed in Phase 1);
  `Ghostty.Config.swift` `remoteProjectDirectories` getter + pure `name = base` line parser.
- **P2** `RemoteTunnelController.listProjects(host:) async -> [String]` running
  `ssh -o ControlPath=<master> <target> find -L <base> -mindepth 1 -maxdepth 1 -type d -print0`
  (POSIX-portable; `ls -1` fallback), parse NUL-delimited; per-host cache dict
  `host -> (paths, fetchedAt)` invalidated on tunnel drop/reconnect (stale-while-revalidate, ~1s TTL
  like `/api/surfaces`). Reuses the ControlMaster socket the supervisor owns
  (`ssh.zig:439,477-491` precedent). Runs off-main via the same child-`Process` pattern.
- **P3** `Features/Command Palette/ProjectPalette.swift`: host-aware. Keep synchronous
  `discoverProjectPaths` (`:71/:115`) for `local`; for a remote read the supervisor cache
  **synchronously** (the getter must not block — show a "listing…/stale" informational row when
  cold, like the project selector's never-silent-no-op). On select, post `ghosttyNewTab` carrying
  `workingDirectory` **AND** the target `hostName` (so it spawns on that host). The remote lister
  cannot reuse Swift `isProjectDirectory` (`:143-153`); encode its symlink-follow via `find -L
  -type d`.

**Q. Complete identity namespacing across sidecar + dashboard stores (D3) — the exhaustive list**
- **Q1** Sidecar `queue/types.ts`: `Assignment.hostName` + `ScheduleState.hostName`; a pure
  `sessionKey(host, id) = ` `` `${host} ${id}` `` .
- **Q2** **The `sessionID` number→string wire switch (D3) — a MATCHED emit↔parse pair, both edits
  in THIS commit:**
  - **(emit, macOS)** `MCPLayout.surfacesJSONData` (`:246`): change the `sessionID` emit from
    `NSNumber(value:)` to the string composite `"${hostName}:${sessionID}"` (Phase 1 deliberately
    left this as `NSNumber` — flipping it alone breaks reconcile; see F1).
  - **(parse, sidecar)** `mcp.ts:69` `SurfaceRow.sessionID: number` → `string`; `store.ts:444`
    parse the composite (split on the last `:` into `(hostName, u64)`) instead of
    `typeof r.sessionID === "number"`.
  These two MUST NOT be split across commits — an emit-only flip coerces every row to `0` and
  silently breaks the queue reconcile (restart re-adoption + same-sweep adopt fold-in).
  Then re-key reconcile Maps/Sets (`liveBySession` `:706`, `claimedSessions`
  `:725`, `adoptedSessions` `:840`, `LiveSurface.sessionID` `:592`, match `:729`) via `sessionKey`;
  serialize/parse `Assignment.sessionID` (`:444`) + `ScheduleState.activeSessionID` (`:196-200`) with
  a sibling `hostName`; **`parseStore` defaults a MISSING `hostName` to `local`** (back-compat, mirror
  the Codable `decodeIfPresent ?? local`). Round-trip test for a pre-migration (no-hostName) record.
- **Q3** `queue/runner.ts`: `projectLiveSurfaces` (`:1227-1233`) reads `hostName` off the row;
  `finalizeRecord` (`:1877`) records the dispatch host (from dispatch context, not the spawn reply);
  `scheduleSweep` `bySession` (`:1990-1992`) + `activeSessionID` compares (`:2053/:2066`) key on the
  pair. (`gridOccupancy` `:2253` keys on slot ints — safe, unchanged.)
- **Q4** macOS dashboard stores the design MISSED (all persist across restart or dial a socket):
  - `AgentDashboardController.swift`: re-key `AgentStateStore` `[UInt64:…]` (`:100-135,:412`,
    `rehydrateAndPersist` `:911-927`) and `manualOrder` `[UInt64]` (`:334,:448,:598-600,:1139`) to
    `"${host}:${u64}"` String keys, decoding a legacy bare-number key as host `local`; add
    `LiveSurface.hostName` + `HookSnapshotEntry.hostName`.
  - `AgentPreviewTile.swift`: composite SwiftUI `.id` (`:721`) → `"${host}:${sessionID}-${gen}"`; put
    `host` into the mirror dial `cfg` (`:951`, add the resolved socket) so two same-u64 sessions on
    different hosts don't collapse / dial the wrong host.
  - `WebMonitorServer.swift` (out-of-scope for v1 phone use, but FLAG + guard): `routeStream`
    (`:1070-1076`) + `WebMonitorHostClient` (`:251,:309`) hardcode `config.ptyHost`; under multi-host
    this dials the wrong socket. Either scope multi-host out of the web monitor or derive socketPath
    from the surface's host. Document the limitation.

**R. Billing docs (no code — D6/OQ6)**
- **R1** Documentation only: `get_haiku_usage` tracks ONLY the laptop sidecar's own Haiku calls
  (`summarizer`/`bell-classify`/`issue-key-infer`, `index.ts:540-549`, `usage.ts:39-52`,
  `MCPUsage.swift:17-20`, `MCPTools.swift:51`) — a work-agent's token spend (local OR cloud) was
  **never** in scope, so a cloud agent billing the box's own account is **not** a regression. Per-box
  `claude`/account inspection on the box is the accounting mechanism. No `byHost` bucket, no usage
  frame, no config key, tool count stays 26.

### Config keys
`pty-remote-project-directory` (if not already in Phase 1).

### C-ABI / protocol
- **Host rebuild = session loss (box only):** N1 (`proc_info.zig` Linux arm — fills an already-
  negotiated `process_info` frame; NO protocol/tag change). Schedule the box restart deliberately.
- **Optional host frame:** L3 `hello_nack` if deferred from Phase 3.
- Everything else (M, O, P, Q, R) is GUI-lib + sidecar `dist` + hook/docs — **no host restart**.

### Test plan
- **sidecar** `queue/*.test.ts`: `host` field validate/whitelist (`templates.test.ts`);
  `substituteTemplateDir` routes remote dir into agent only, laptop dir into providers
  (`templates.test.ts`); reconcile/schedule pair-keying with a **two-host-same-u64** case (no false
  match, correct re-adopt on the right host) + pre-migration no-hostName → local (`store.test.ts`,
  `runner.test.ts`); `spawn_split_command` carries `host`, reads `hostName` back (`mcp.test.ts`).
- **Swift** `MCPAgentStateTests`: nonce body with no tty parses + resolves; tty fallback still works;
  a per-box token is rejected for `/mcp` spawn (capability scoping); Host-rewrite/allowed-Host.
  `ProjectPaletteTests`: `name = base` parser + cache stale-while-revalidate schedule (style of
  `AgentMirrorReconnectTests`). Dashboard store pair-keying round-trip (legacy bare key → local).
- **Zig** `proc_info.zig`: Linux `/proc/<pid>/cmdline` NUL-split parser (mirror `parseProcArgs2`);
  `descendToProgram` over a `/proc` PPID fixture (comptime-gated to `.linux`).

### Doc deltas
- `AGENT-QUEUE.md` (per-queue `host`, provider-laptop/agent-cloud split, `{templateDir}` divergence),
  `AGENT-DASHBOARD.md` (cross-host correlation via nonce; store pair-keying),
  `AGENT-MANAGER.md` (get_haiku_usage scope clarification — R1), `MCP-SERVER.md` (nonce route,
  per-box capability token, `spawn_split_command` `host` arg, tool count stays 26),
  `CLOUD-HOSTS-DESIGN.md` (resolve OQ3/OQ4/OQ6/OQ8; correct the `foreground_pid`/`process_info`
  coupling and the SIGPIPE/pty/Command/xev "audited clean" note per §Linux findings),
  `example/claude-hooks/ghostty-agent-state.sh` (nonce branch + 0600-file token read),
  `CLAUDE.md` (extend the cloud-hosts bullet + fork-key list).
- **No real-world names** anywhere (boxes are `cloud-1`, `user@example.ts.net`, etc.).

### Local vs cloud boundary
- **Local:** all sidecar tests, the nonce map + route + parse (Swift), the project-palette parser +
  cache, the identity pair-keying — exercisable with a **second local host** and a synthetic hook POST.
- **Needs a box:** the Linux `/proc` classification (N1 is Linux-only code — test with the `.linux`
  fixtures locally, but end-to-end agent detection needs the box); the per-box token file + tailnet
  hook POST; billing.

---

## Sequencing + edit-race partitioning (parallelizable by owning file)

Assign one agent per **owner group**; they touch disjoint files so they can run concurrently within
a phase. Cross-group dependencies are listed.

| Group | Owner files | Phases | Depends on |
|---|---|---|---|
| **CFG** | `src/config/Config.zig` (+ its parse tests) | 1,2,4 | — |
| **CABI** | `include/ghostty.h`, `src/apprt/embedded.zig` (incl. `ghostty_probe_host` B5, reusing `protocol.zig` encode/decode), `src/Surface.zig` (backend selection) | 1,2 | CFG (key names only, loose) |
| **CLIENT** | `src/termio/Client.zig` (Config fields, redial state machine, HelloAck, states) | 1,2,3 | CABI (Config.host_name/reconnect/socket) |
| **REGISTRY** | new `Features/RemoteHost/*` (Registry, TunnelController, AgentIdentity), `Ghostty.Config.swift` getters | 1,2,4 | CFG; CABI (the `ghostty_probe_host` export for the C3 readiness gate) |
| **LAUNCH** | `src/input/Binding.zig`, `src/input/command.zig`, `src/apprt/action.zig`, new `RemoteHostPalette.swift`, `ProjectPalette.swift` | 1,4 | REGISTRY (registry lookup), CABI (surface config) |
| **PERSIST** | `SurfaceView_AppKit.swift` (hostName Codable + deferred/gated dial + `materializeClientSurface()`), `SurfaceView.swift` (`SurfaceConfiguration.ptyHostSocket`/`hostName` + `withCValue` population) | 1 | CABI, REGISTRY (readiness Publisher) |
| **MCP** | `MCPLayout.swift`, `MCPServer.swift`, `MCPAgentState.swift`, `MCPTools.swift`, `MCPKnowledge.swift` (MCP-K1 readers + FeatureDoc coverage) | 1,2,4 | PERSIST (hostName), REGISTRY (nonce map + `ptyRemoteConnectTimeout` getter) |
| **OVERLAY** | `TerminalView.swift` (reconnecting/ended/too-old overlays) | 2 | CLIENT (state channel) |
| **DASH** | `AgentDashboardController.swift`, `AgentPreviewTile.swift` (store pair-keying) | 4 | PERSIST, MCP |
| **SIDECAR** | `macos/agent-manager/src/{queue/*,mcp,index}.ts` | 4 | MCP (list_surfaces hostName), CFG (none) |
| **HOST** | `src/os/proc_info.zig` (Linux arm) | 4 | — (isolated; but host rebuild = session loss) |
| **HOOK/DOCS** | `example/claude-hooks/*`, all `*.md`, `example/ghostty-ramon/config` | all | the code it documents (same commit) |

**Ordering rules across groups:**
1. Phase 1: CFG + CABI first (they define the ABI CLIENT/REGISTRY/PERSIST/MCP consume), then the rest
   in parallel. CLIENT Phase-1 work is just the two `Config` fields (no behavior). **CABI's B5
   `ghostty_probe_host` export is a hard prereq for REGISTRY's C3 readiness gate** (C3 calls it to
   decide "ready"), so land B5 before C3 wires the readiness `Publisher`.
2. Phase 2: CLIENT is the critical path (G→H→I→J→K); OVERLAY depends on CLIENT's state channel;
   REGISTRY's J1 supervisor respawn is parallel to CLIENT. Do NOT start I (redial) before G (clean
   teardown) + H (HelloAck) land — they are prerequisites (D1/D2). REG-T (connect-timeout) spans
   CFG+REGISTRY+CABI+CLIENT: REG-T1 (key+getter+MCP-K1 coverage) and REG-T2 (the third ABI field →
   `Client.Config.connect_timeout_s`) should land before I1 wires the backoff cap, but I1 tolerates
   a compiled default (0) so it is a soft, not hard, prereq.
3. Phase 4: MCP's `list_surfaces hostName` (the additive field landed in Phase 1 F1) unblocks
   SIDECAR Q; the `sessionID` number→string flip is NOT in Phase 1 — it is Q2's matched emit↔parse
   pair (MCP `surfacesJSONData` emit + sidecar `mcp.ts`/`store.ts` parse) that MUST land in one
   commit or reconcile silently coerces every row to `0`. M (nonce) spans REGISTRY+MCP+HOOK; O/P/Q
   are largely independent (queue vs project vs identity). HOST N1 is fully isolated but is the only
   session-loss item — land + deploy it on its own scheduled window.

**Session-loss gate:** the ONLY host-rebuild items are Phase-4 N1 (`proc_info.zig`) and the optional
L3 `hello_nack`. Everything else is GUI-lib + sidecar `dist` + hook/docs — deployable while sessions
run. Never bump the protocol MAJOR in a colleague-facing release while any colleague lacks a recorded
reload identity (`CLAUDE.md` fleet-transition rule); a MINOR bump (L3) is safe.

---

## Docs-discipline checklist (BLOCKING — every commit)

- [ ] Feature doc updated (`CLOUD-HOSTS-DESIGN.md` status + the relevant `AGENT-*`/`PTYHOST.md`/
      `MCP-SERVER.md`).
- [ ] `CLAUDE.md` summary bullet + wiring list + fork-only config-key list.
- [ ] `example/ghostty-ramon/config` + `example/claude-hooks/*` updated **with neutral placeholders
      only** (no real host/user/company names).
- [ ] New fork config key: doc comment begins `(ramon fork` + added to a `FeatureDoc.configKeys`
      (`MCPKnowledge.swift`) so the coverage guards pass.
- [ ] Tests named per the existing patterns (`Config.zig` parse tests, `client_difftest.zig`,
      `AgentMirrorReconnectTests`, `MCPAgentStateTests`, sidecar `*.test.ts`).
- [ ] Lib/xcframework rebuilt WITH the xcframework (never `-Demit-xcframework=false` for the app
      build); `rm -rf macos/build/ReleaseLocal` after any protocol/lib change.

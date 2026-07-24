import Combine
import Darwin
import Foundation
import GhosttyKit
import os

/// (ramon fork / cloud-hosts) The SINGLE-OWNER SSH tunnel supervisor (design decision
/// D7). There is one shared instance for the whole app; surfaces are pure CONSUMERS of a
/// per-host readiness `Publisher` — they never spawn `ssh` or poll-connect a tunnel
/// themselves.
///
/// Phase-1 scope (this file):
///   - `ensureTunnel(host:)` brings up a tunnel ON DEMAND: a dedicated `ssh` ControlMaster
///     plus a forwarder process (`ControlMaster=no`) that `-L`-forwards a LOCAL unix socket
///     to the remote `ghostty-host` socket. Keepalive `ServerAliveInterval=5`; socket
///     perms locked with `StreamLocalBindMask=0177` under a 0700 short dir (sun_path is
///     ~104 bytes — length-checked). A short `ControlPersist` bounds an orphaned master on
///     GUI death (Phase 2 hardens this with a real ppid watchdog + auto-respawn).
///   - A readiness `Publisher` (`readinessPublisher(for:)`) that fires "ready" ONLY after a
///     full Hello→HelloAck round-trip over the forwarded socket — performed by the
///     `ghostty_probe_host` C export (task B5) OFF-MAIN. A bare `reachable` connect is NOT
///     ready (that is the `ssh -L` accept-then-EOF false-positive D1 warns about); readiness
///     fires only on `handshaked == true`. The probe's host `major`/`minor` are stashed on
///     the readiness value so a lagging host can be surfaced at readiness time (D1; full
///     mid-session classification is Phase 2).
///
/// Phase 2 (task J1) is now WIRED: surfaces `retainTunnel`/`releaseTunnel` (the
/// refcount), so a master exit while a surface still wants the host schedules a
/// never-give-up `respawn`, and the last surface's release tears the tunnel down.
/// (`ensureTunnel` remains the one-shot bring-up used by the first retain + each
/// respawn; a bare `ensureTunnel` with no retain stays one-shot — Phase-1 behavior.)
final class RemoteTunnelController {
    /// The single owner (D7). All state below is shared through this instance.
    static let shared = RemoteTunnelController()

    /// A tunnel that has completed a full Hello→HelloAck handshake and is ready to carry a
    /// `.client` surface. `socketPath` is the RESOLVED local forwarded socket a surface
    /// should dial (fed into `ghostty_surface_config_s.pty_host_socket`). `major`/`minor`
    /// are the host's advertised protocol version (meaningful because handshaked).
    struct Readiness: Equatable, Sendable {
        let hostName: String
        let socketPath: String
        let major: UInt16
        let minor: UInt16
    }

    /// The pure outcome of one `ghostty_probe_host` call (mirrors `ghostty_host_probe_s`).
    struct ProbeResult: Equatable, Sendable {
        var reachable: Bool = false
        var handshaked: Bool = false
        var major: UInt16 = 0
        var minor: UInt16 = 0
    }

    enum TunnelError: Error, Equatable {
        /// The resolved forwarded-socket path exceeds the platform `sun_path` limit
        /// (~104 bytes). Actionable: shorten `$TMPDIR` or pin a shorter local-socket path.
        case socketPathTooLong(String)
        /// No `ssh` executable resolved (neither well-known locations nor a login shell).
        case sshNotFound
    }

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "remote-tunnel")

    /// sizeof(sockaddr_un.sun_path) is 104 on Darwin; reserve one byte for the NUL.
    static let maxSunPathBytes = 103

    /// Probe/backoff timing. The quick burst then a steady cadence FOREVER mirrors the
    /// `AgentPreviewTile` reconnect shape (never give up while a surface wants the host).
    static let defaultProbeTimeoutMs: UInt32 = 3000
    private static let backoffSchedule: [TimeInterval] = [0.5, 1, 2, 4, 8]
    private static let steadyBackoff: TimeInterval = 15

    /// (Phase 2, J1) ssh-master RESPAWN backoff — a quick exponential burst
    /// (1,2,4,8,16,30) then a STEADY once-a-minute cadence FOREVER (never give up while a
    /// surface still wants the host). This is a BYTE-FOR-BYTE copy of
    /// `AgentPreviewTile.mirrorReconnectDelay` (task J1) — NOT the `AgentManagerController`
    /// give-up backoff (which stands down after `restartMaxAttempts`).
    static let respawnQuickAttempts = 6
    static let respawnSteadyDelay: TimeInterval = 60
    /// A master that ran at least this long before exiting resets its respawn budget, so a
    /// LATER transient drop gets a full quick-burst again (mirrors `mirrorStableSeconds`).
    static let respawnHealthyRunInterval: TimeInterval = 15
    /// (REG-T3) Compiled-in per-attempt connection ceiling (seconds) when
    /// `pty-remote-connect-timeout` is unset (0). Mirrors the core client's
    /// `DEFAULT_CONNECT_TIMEOUT_S`.
    static let defaultConnectTimeoutSeconds: UInt32 = 10
    /// (Phase 6) Grace between the SIGTERM and the SIGKILL escalation when force-killing a
    /// COMMAND-mode transport — its interactive shell (`-ilc`) may ignore SIGTERM.
    static let commandKillGraceSeconds: TimeInterval = 2

    /// Map a `pty-remote-connect-timeout` seconds value to the per-attempt probe/handshake
    /// ceiling in ms (REG-T3). `0` ⇒ the compiled default. PURE + unit-testable.
    static func connectTimeoutMs(_ seconds: UInt32) -> UInt32 {
        let s = seconds == 0 ? defaultConnectTimeoutSeconds : seconds
        return s &* 1000
    }

    /// The ssh-master respawn delay (seconds) for a 0-based `attempt`: a quick exponential
    /// burst 1,2,4,8,16,30 then a STEADY `respawnSteadyDelay` (60s) forever. PURE + static
    /// for unit testing (mirrors `AgentPreviewTile.mirrorReconnectDelay`).
    static func respawnDelay(forAttempt attempt: Int) -> TimeInterval {
        let a = max(attempt, 0)
        if a >= respawnQuickAttempts { return respawnSteadyDelay }
        return min(Double(1 << a), 30.0)
    }

    // MARK: - State (guarded by stateQueue)

    private let stateQueue = DispatchQueue(label: "com.mitchellh.ghostty-ramon.remote-tunnel.state")
    /// Per-host readiness, replayed to late subscribers (a restored surface may subscribe
    /// AFTER the tunnel already handshaked). `nil` until the first successful handshake.
    private var subjects: [String: CurrentValueSubject<Readiness?, Never>] = [:]
    /// Monotonic per-host token; a bump cancels the in-flight probe loop for that host.
    private var probeGeneration: [String: Int] = [:]
    private var masterProcesses: [String: Process] = [:]
    private var forwarderProcesses: [String: Process] = [:]

    // --- Supervision (J1): surface refcount + never-give-up respawn ---
    /// How many live surfaces still want each host. The tunnel is torn down (respecting
    /// ControlPersist) when this reaches 0 (single owner — D7). Retain on surface create,
    /// release on surface close.
    private var wanted: [String: Int] = [:]
    /// The last-used bring-up params, remembered so a respawn can reconstruct the tunnel
    /// without the caller re-supplying them.
    private var hostEntries: [String: RemoteHostEntry] = [:]
    private var hostSSHOptions: [String: String?] = [:]
    private var hostConnectTimeout: [String: UInt32] = [:]
    /// Per-host respawn attempt counter (drives `respawnDelay`); reset by a healthy run.
    private var respawnAttempts: [String: Int] = [:]
    /// Monotonic per-host token; a bump (teardown, or a newer exit) cancels a pending
    /// scheduled respawn so it can't double-spawn.
    private var respawnGeneration: [String: Int] = [:]

    /// The probe blocks up to `timeout_ms`, so it MUST run off the main thread.
    private let probeQueue = DispatchQueue(
        label: "com.mitchellh.ghostty-ramon.remote-tunnel.probe",
        attributes: .concurrent)
    /// Serial queue for respawn scheduling/execution (backoff `asyncAfter` + the actual
    /// re-spawn). SEPARATE from `stateQueue` so respawn work can take `stateQueue.sync`
    /// critical sections (via `ensureTunnel`) without serial-queue reentrancy.
    private let supervisionQueue = DispatchQueue(
        label: "com.mitchellh.ghostty-ramon.remote-tunnel.supervision")

    private init() {}

    // MARK: - Readiness publisher (the consumer contract)

    private func subject(for host: String) -> CurrentValueSubject<Readiness?, Never> {
        stateQueue.sync {
            if let s = subjects[host] { return s }
            let s = CurrentValueSubject<Readiness?, Never>(nil)
            subjects[host] = s
            return s
        }
    }

    /// Subscribe to a host's readiness. Fires (on the main run loop) exactly when the
    /// tunnel has handshaked, carrying the resolved forwarded socket + host version. A
    /// late subscriber whose tunnel is ALREADY ready receives the current value
    /// immediately (CurrentValueSubject replay). Never completes / never errors.
    func readinessPublisher(for hostName: String) -> AnyPublisher<Readiness, Never> {
        subject(for: hostName)
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .eraseToAnyPublisher()
    }

    /// Synchronous snapshot of a host's current readiness (nil until first handshake).
    func currentReadiness(for hostName: String) -> Readiness? {
        subject(for: hostName).value
    }

    // MARK: - Probe (the B5 handshake round-trip)

    /// One Hello→HelloAck round-trip against `socketPath` via the `ghostty_probe_host` C
    /// export (task B5) — reuses the live `.client` wire codec, so it can never drift from
    /// what the real backend speaks. PURE (no controller state); safe to call off-main.
    static func probe(socketPath: String, timeoutMs: UInt32) -> ProbeResult {
        let r = socketPath.withCString { ghostty_probe_host($0, timeoutMs) }
        return ProbeResult(
            reachable: r.reachable,
            handshaked: r.handshaked,
            major: r.major,
            minor: r.minor)
    }

    /// Poll the probe against an ALREADY-RESOLVED forwarded socket until it handshakes,
    /// then publish readiness. This is the testable seam: a test can drive it directly
    /// against a fake local acceptor WITHOUT spawning `ssh`. Cancels any in-flight probe
    /// loop for the same host first (generation bump).
    func startProbing(
        hostName: String,
        socketPath: String,
        probeTimeoutMs: UInt32 = defaultProbeTimeoutMs
    ) {
        let gen: Int = stateQueue.sync {
            let g = (probeGeneration[hostName] ?? 0) + 1
            probeGeneration[hostName] = g
            return g
        }
        probeQueue.async { [weak self] in
            self?.probeLoop(
                hostName: hostName,
                socketPath: socketPath,
                timeoutMs: probeTimeoutMs,
                generation: gen)
        }
    }

    /// Cancel the in-flight probe loop for a host (generation bump). Idempotent.
    func stopProbing(hostName: String) {
        stateQueue.sync { probeGeneration[hostName] = (probeGeneration[hostName] ?? 0) + 1 }
    }

    private func isCurrent(_ hostName: String, _ generation: Int) -> Bool {
        stateQueue.sync { probeGeneration[hostName] == generation }
    }

    private func probeLoop(
        hostName: String,
        socketPath: String,
        timeoutMs: UInt32,
        generation: Int
    ) {
        var attempt = 0
        while isCurrent(hostName, generation) {
            let result = Self.probe(socketPath: socketPath, timeoutMs: timeoutMs)
            if result.handshaked {
                // Re-check generation so a teardown that raced the probe wins.
                if isCurrent(hostName, generation) {
                    subject(for: hostName).send(Readiness(
                        hostName: hostName,
                        socketPath: socketPath,
                        major: result.major,
                        minor: result.minor))
                    logger.info("remote host \(hostName, privacy: .public) handshaked (host protocol \(result.major).\(result.minor))")
                }
                return
            }
            // Not ready (unreachable or reachable-but-no-ack). Back off and retry — a
            // bare reachable connect is NOT ready (the ssh -L accept-then-EOF case).
            let delay = Self.backoff(forAttempt: attempt)
            attempt += 1
            Thread.sleep(forTimeInterval: delay)
        }
    }

    /// Backoff: a quick burst, then a steady cadence forever (never give up while a
    /// surface still wants the host). PURE + unit-testable.
    static func backoff(forAttempt attempt: Int) -> TimeInterval {
        guard attempt >= 0 else { return backoffSchedule.first ?? steadyBackoff }
        if attempt < backoffSchedule.count { return backoffSchedule[attempt] }
        return steadyBackoff
    }

    // MARK: - Tunnel bring-up (ssh master + forwarder)

    /// Bring the tunnel for `host` up ON DEMAND and start probing for readiness.
    /// Idempotent: a second call while the master is alive re-arms probing only if the
    /// host hasn't handshaked yet. `sshOptions` is the verbatim `pty-remote-ssh-options`
    /// string (split on whitespace); pass nil when unset. Best-effort — a spawn/resolution
    /// failure is logged and leaves readiness un-fired (the consumer keeps showing its
    /// awaiting-tunnel placeholder).
    func ensureTunnel(
        host: RemoteHostEntry,
        sshOptions: String? = nil,
        probeTimeoutMs: UInt32 = defaultProbeTimeoutMs
    ) {
        // Remember the bring-up params so an auto-respawn (J1) can reconstruct the tunnel
        // without the caller re-supplying them.
        stateQueue.sync {
            hostEntries[host.name] = host
            hostSSHOptions[host.name] = sshOptions
        }

        let socketPath: String
        do {
            socketPath = try resolveForwardedSocketPath(for: host)
        } catch {
            logger.error("remote host \(host.name, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }

        let alreadyRunning = stateQueue.sync { masterProcesses[host.name]?.isRunning ?? false }
        if alreadyRunning {
            if currentReadiness(for: host.name) == nil {
                startProbing(hostName: host.name, socketPath: socketPath, probeTimeoutMs: probeTimeoutMs)
            }
            return
        }

        // (Phase 6) COMMAND MODE: a per-host transport-command override runs ONE long-lived
        // forward process through the user's login+interactive shell (no ControlMaster, no
        // `ssh -O check`/`-O exit`). Readiness (the `ghostty_probe_host` socket handshake)
        // and respawn (the never-give-up process-exit watch) are UNCHANGED — only the spawn
        // differs. A host WITHOUT an override falls through to the default `ssh`
        // ControlMaster path below, byte-identically.
        if let command = host.transportCommand {
            do {
                try spawnCommandTunnel(host: host, command: command, localSocket: socketPath)
            } catch {
                logger.error("failed to bring up command tunnel for \(host.name, privacy: .public): \(String(describing: error), privacy: .public)")
                return
            }
            startProbing(hostName: host.name, socketPath: socketPath, probeTimeoutMs: probeTimeoutMs)
            return
        }

        guard let ssh = Self.resolveSSH() else {
            logger.error("ssh not found for remote host \(host.name, privacy: .public)")
            return
        }

        do {
            try spawnTunnel(host: host, ssh: ssh, localSocket: socketPath, sshOptions: sshOptions)
        } catch {
            logger.error("failed to bring up tunnel for \(host.name, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }

        startProbing(hostName: host.name, socketPath: socketPath, probeTimeoutMs: probeTimeoutMs)
    }

    // MARK: - Surface refcount + last-surface teardown (J1, D7)

    /// A surface for `host` was created. Increment the want-count (single owner — D7) and,
    /// on the first surface, bring the tunnel up (which arms auto-respawn). Idempotent for
    /// N surfaces: only the first spawns; the rest just bump the refcount. `connectTimeout`
    /// is the `pty-remote-connect-timeout` seconds value (0 ⇒ compiled default), used as
    /// the per-attempt handshake ceiling (REG-T3) for both the initial probe and respawns.
    func retainTunnel(
        host: RemoteHostEntry,
        sshOptions: String? = nil,
        connectTimeout: UInt32 = 0
    ) {
        if noteRetain(host: host, connectTimeout: connectTimeout) {
            ensureTunnel(
                host: host,
                sshOptions: sshOptions,
                probeTimeoutMs: Self.connectTimeoutMs(connectTimeout))
        }
    }

    /// The refcount bump behind `retainTunnel` — the SINGLE source of truth, extracted
    /// so it can be exercised WITHOUT spawning `ssh` (that is `ensureTunnel`'s job,
    /// gated on the `first` return below). Bumps the surface want-count and REMEMBERS the
    /// entry + connect timeout so a later master-exit respawn (and the respawn gate,
    /// `wouldRespawnOnMasterExit`) can reconstruct the bring-up. Returns whether this is
    /// the FIRST surface wanting the host (the one that triggers bring-up).
    @discardableResult
    func noteRetain(host: RemoteHostEntry, connectTimeout: UInt32) -> Bool {
        stateQueue.sync {
            let n = (wanted[host.name] ?? 0) + 1
            wanted[host.name] = n
            hostEntries[host.name] = host
            hostConnectTimeout[host.name] = connectTimeout
            return n == 1
        }
    }

    /// The refcount drop behind `releaseTunnel` — extracted (like `noteRetain`) so the
    /// zero-crossing (the last-surface teardown trigger) is testable without side
    /// effects. Returns whether the count hit 0.
    @discardableResult
    func noteRelease(hostName: String) -> Bool {
        stateQueue.sync {
            let n = max((wanted[hostName] ?? 0) - 1, 0)
            wanted[hostName] = n
            return n == 0
        }
    }

    /// Current surface want-count for `host` (0 if none). Test observability for the
    /// refcount that gates bring-up + last-surface teardown (D7).
    func wantedCount(for hostName: String) -> Int {
        stateQueue.sync { wanted[hostName] ?? 0 }
    }

    /// Whether a master-exit for `host` WOULD schedule a never-give-up respawn: the host
    /// is still wanted by ≥1 surface AND its bring-up params are remembered. Mirrors the
    /// gate inside `handleMasterExit` (extracted so it is test-observable without a real
    /// ssh master). This is the exact predicate the J1 respawn depends on, and it is armed
    /// only because a surface retained the tunnel (`wanted > 0`).
    func wouldRespawnOnMasterExit(hostName: String) -> Bool {
        stateQueue.sync { (wanted[hostName] ?? 0) > 0 && hostEntries[hostName] != nil }
    }

    /// A surface for `hostName` closed. Decrement the want-count; when it reaches 0, tear
    /// the tunnel down (the last-surface-closes trigger — D7). ControlPersist bounds the
    /// master's linger even if a terminate races.
    func releaseTunnel(hostName: String) {
        if noteRelease(hostName: hostName) { teardown(hostName: hostName) }
    }

    /// Tear down a host's tunnel: cancel probing + any pending respawn, ask the master to
    /// exit its forwards, and terminate both processes. Zeroes the want-count so the
    /// terminationHandler's respawn gate declines (the intended-stop case).
    func teardown(hostName: String) {
        stopProbing(hostName: hostName)
        let (master, forwarder, entry) = stateQueue.sync {
            () -> (Process?, Process?, RemoteHostEntry?) in
            wanted[hostName] = 0
            // Bump the respawn generation so any scheduled respawn is superseded/cancelled.
            respawnGeneration[hostName] = (respawnGeneration[hostName] ?? 0) + 1
            respawnAttempts[hostName] = 0
            // The tunnel is going away — a cached project listing is now stale.
            projectCache[hostName] = nil
            projectFetchInFlight.remove(hostName)
            return (masterProcesses.removeValue(forKey: hostName),
                    forwarderProcesses.removeValue(forKey: hostName),
                    hostEntries[hostName])
        }
        if let entry, entry.transportCommand != nil {
            // (Phase 6) COMMAND MODE: the transport runs under an INTERACTIVE shell
            // (`-ilc`, required so a shell function resolves), which commonly IGNORES
            // SIGTERM — so `master?.terminate()` (SIGTERM) can be a no-op, leaking the
            // shell + its `ssh -N` forward + any per-invocation gateway. Force the whole
            // process GROUP down instead, and (there being no ControlMaster to
            // `ssh -O exit`) unlink the forwarded local socket so a leaked forward can't
            // hold the path across a later respawn.
            if let master { forceKillCommandProcess(master) }
            if let path = try? resolveForwardedSocketPath(for: entry) {
                try? FileManager.default.removeItem(atPath: path)
            }
        } else {
            forwarder?.terminate()
            master?.terminate()
        }
    }

    /// (Phase 6) Force a COMMAND-mode transport process — and its whole process group — down.
    /// An interactive shell commonly ignores SIGTERM, so `Process.terminate()` alone can leak
    /// the shell's `ssh -N` forward + gateway. We SIGTERM then (after a grace) SIGKILL the
    /// process GROUP led by the shell via `kill(-pid, …)`, reaping the ssh child + gateway,
    /// and also SIGKILL the shell pid itself (SIGKILL can't be ignored). `kill(-pid, …)` is
    /// SAFE even if the shell never became a group leader: there is then simply no group with
    /// that id (ESRCH, a harmless no-op) — it can NEVER reach the GUI's own process group,
    /// which has a different id. Group leadership is provided by the INTERACTIVE (`-i`) login
    /// shell self-leading its group (the post-spawn `setpgid` in `spawnCommandTunnel` is a
    /// best-effort no-op — EACCES post-exec), an assumption guarded by
    /// `commandModeTransportProcessIsItsOwnGroupLeader`.
    private func forceKillCommandProcess(_ proc: Process) {
        let pid = proc.processIdentifier
        guard pid > 0 else { proc.terminate(); return }
        kill(-pid, SIGTERM)
        proc.terminate()
        supervisionQueue.asyncAfter(deadline: .now() + Self.commandKillGraceSeconds) {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
        }
    }

    // MARK: - Auto-respawn + health (J1)

    /// ssh-master exited (runs on the supervision queue). Clear the dead handles; if a
    /// surface still wants this host, schedule a never-give-up respawn with the
    /// `respawnDelay` backoff (a healthy run first resets the budget). A generation token
    /// makes the scheduled respawn cancellable by a teardown or a newer exit.
    private func handleMasterExit(hostName: String, status: Int32, startedAt: Date) {
        let ranFor = Date().timeIntervalSince(startedAt)
        struct Decision { var respawn: Bool; var entry: RemoteHostEntry?; var opts: String?
                          var timeout: UInt32; var delay: TimeInterval; var gen: Int }
        let d: Decision = stateQueue.sync {
            // Drop the dead master + its now-orphaned forwarder.
            masterProcesses[hostName] = nil
            let fwd = forwarderProcesses.removeValue(forKey: hostName)
            fwd?.terminate()
            // The connection dropped — invalidate the cached project listing so a
            // respawn re-fetches against the fresh tunnel (stale-while-revalidate).
            projectCache[hostName] = nil
            projectFetchInFlight.remove(hostName)

            guard (wanted[hostName] ?? 0) > 0, let entry = hostEntries[hostName] else {
                return Decision(respawn: false, entry: nil, opts: nil, timeout: 0, delay: 0, gen: 0)
            }
            if ranFor >= Self.respawnHealthyRunInterval { respawnAttempts[hostName] = 0 }
            let attempt = respawnAttempts[hostName] ?? 0
            respawnAttempts[hostName] = attempt + 1
            let gen = (respawnGeneration[hostName] ?? 0) + 1
            respawnGeneration[hostName] = gen
            return Decision(
                respawn: true,
                entry: entry,
                opts: hostSSHOptions[hostName] ?? nil,
                timeout: hostConnectTimeout[hostName] ?? 0,
                delay: Self.respawnDelay(forAttempt: attempt),
                gen: gen)
        }
        guard d.respawn, let entry = d.entry else { return }
        logger.notice("remote host \(hostName, privacy: .public) master exited (status \(status, privacy: .public)) — respawning in \(d.delay, privacy: .public)s")
        supervisionQueue.asyncAfter(deadline: .now() + d.delay) { [weak self] in
            guard let self else { return }
            let current = self.stateQueue.sync {
                self.respawnGeneration[hostName] == d.gen && (self.wanted[hostName] ?? 0) > 0
            }
            guard current else { return }
            self.respawn(entry: entry, sshOptions: d.opts, connectTimeout: d.timeout)
        }
    }

    /// Clean the stale multiplex + forwarded sockets, then bring the tunnel back up. Runs
    /// on the supervision queue; `ensureTunnel` re-resolves ssh, recreates the forwarded
    /// socket, respawns master+forwarder, and restarts probing (re-fires readiness).
    private func respawn(entry: RemoteHostEntry, sshOptions: String?, connectTimeout: UInt32) {
        cleanStaleControl(host: entry)
        ensureTunnel(
            host: entry,
            sshOptions: sshOptions,
            probeTimeoutMs: Self.connectTimeoutMs(connectTimeout))
    }

    /// Best-effort `ssh -O exit` on the (possibly still-persisting) master + unlink of the
    /// stale ControlPath, so a respawn binds a fresh multiplex socket instead of colliding
    /// with a half-dead one.
    private func cleanStaleControl(host: RemoteHostEntry) {
        // (Phase 6) A command-mode host has NO ControlMaster — its single long-lived forward
        // process IS the tunnel, so there is no multiplex socket to `ssh -O exit` or unlink.
        // Skip entirely (the respawn just re-spawns the forward process).
        guard host.transportCommand == nil else { return }
        guard let ssh = Self.resolveSSH(), let cp = try? controlPath(for: host) else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ssh)
        proc.arguments = ["-O", "exit", "-o", "ControlPath=\(cp)", host.sshTarget]
        proc.environment = Self.tunnelEnvironment()
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            // No live master to ask — fall through to the unlink.
        }
        try? FileManager.default.removeItem(atPath: cp)
    }

    /// `ssh -O check`: is the master's multiplex socket alive and accepting? Exit 0 ⇒ yes.
    /// A synchronous liveness probe (blocks briefly); call off the main thread.
    func checkMasterHealth(host: RemoteHostEntry) -> Bool {
        // (Phase 6) A command-mode host has no ControlMaster to `ssh -O check`; its liveness
        // is the socket handshake-probe (`ghostty_probe_host`) instead, so this ControlMaster
        // health check is not applicable and short-circuits to false WITHOUT spawning `ssh`.
        guard host.transportCommand == nil else { return false }
        guard let ssh = Self.resolveSSH(), let cp = try? controlPath(for: host) else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ssh)
        proc.arguments = ["-O", "check", "-o", "ControlPath=\(cp)", host.sshTarget]
        proc.environment = Self.tunnelEnvironment()
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return false
        }
        return proc.terminationStatus == 0
    }

    // MARK: - Remote project listing (P2, cloud-hosts)

    /// One cached remote project listing for a host.
    struct CachedProjects: Equatable, Sendable {
        let paths: [String]
        let fetchedAt: Date
    }

    /// Freshness of a cache entry for the stale-while-revalidate scheme.
    enum CacheFreshness: Equatable, Sendable { case miss, fresh, stale }

    /// TTL for the project-list cache. A hit within the TTL is served without a
    /// re-fetch; an older hit is STILL served (stale-while-revalidate) while a
    /// background refresh runs — the same short-TTL shape as the web monitor's
    /// ~1s `/api/surfaces` cache.
    static let projectCacheTTL: TimeInterval = 1.0

    /// (PURE, unit-tested) The stale-while-revalidate decision: classify a cache
    /// entry (nil ⇒ `.miss`) against `now`. `<= ttl` is `.fresh` (boundary is
    /// fresh); older is `.stale` (still served, triggers a revalidate). Mirrors
    /// the pure-schedule style of `respawnDelay` / `AgentPreviewTile` backoff.
    static func cacheFreshness(
        entry: CachedProjects?,
        now: Date,
        ttl: TimeInterval = projectCacheTTL
    ) -> CacheFreshness {
        guard let entry else { return .miss }
        return now.timeIntervalSince(entry.fetchedAt) <= ttl ? .fresh : .stale
    }

    /// (PURE, unit-tested) Split NUL-delimited `find -print0` output into paths,
    /// dropping empty elements (a trailing NUL yields none). Also used for the
    /// `ls` fallback (which this file re-joins with NULs).
    static func parseNulPaths(_ data: Data) -> [String] {
        data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.filter { !$0.isEmpty }
    }

    /// Fired (host name) whenever a host's project cache is refreshed, so a live
    /// palette can recompute its rows. Subscribers should `.receive(on:)` main.
    let projectsDidUpdate = PassthroughSubject<String, Never>()

    /// Per-host project cache + in-flight coalescing set (guarded by `stateQueue`).
    private var projectCache: [String: CachedProjects] = [:]
    private var projectFetchInFlight: Set<String> = []

    /// Synchronous cache read for the palette — NEVER blocks and NEVER spawns
    /// `ssh`. Returns the cached paths + their freshness, or nil on a cold miss.
    /// A stale hit is still returned (stale-while-revalidate); the caller shows it
    /// and separately calls `ensureProjects` to revalidate. `now` is injectable
    /// for tests.
    func cachedProjects(hostName: String, now: Date = Date()) -> (paths: [String], freshness: CacheFreshness)? {
        stateQueue.sync {
            let f = Self.cacheFreshness(entry: projectCache[hostName], now: now)
            guard f != .miss, let entry = projectCache[hostName] else { return nil }
            return (entry.paths, f)
        }
    }

    /// Kick a background project fetch for `host` if the cache is cold or stale
    /// (stale-while-revalidate). Non-blocking; coalesces concurrent fetches per
    /// host (a second call while one is in flight is a no-op). `bases` are the
    /// remote BASE dirs to scan (host-relative — `~`/vars are expanded ON THE BOX
    /// by the login shell, NOT laptop-side).
    func ensureProjects(host: RemoteHostEntry, bases: [String]) {
        let shouldFetch: Bool = stateQueue.sync {
            if projectFetchInFlight.contains(host.name) { return false }
            if Self.cacheFreshness(entry: projectCache[host.name], now: Date()) == .fresh { return false }
            projectFetchInFlight.insert(host.name)
            return true
        }
        guard shouldFetch else { return }
        probeQueue.async { [weak self] in
            guard let self else { return }
            let paths = self.runFindProjects(host: host, bases: bases)
            self.stateQueue.sync {
                self.projectCache[host.name] = CachedProjects(paths: paths, fetchedAt: Date())
                self.projectFetchInFlight.remove(host.name)
            }
            self.projectsDidUpdate.send(host.name)
        }
    }

    /// (P2) List the immediate subdirectories of each `base` on `host`, over the
    /// supervisor-owned ControlMaster socket, and refresh the cache. Async — the
    /// blocking `ssh` runs on the probe queue. This is the awaitable seam; the
    /// palette uses the fire-and-forget `ensureProjects` instead.
    func listProjects(host: RemoteHostEntry, bases: [String]) async -> [String] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            probeQueue.async { [weak self] in
                guard let self else { cont.resume(returning: []); return }
                let paths = self.runFindProjects(host: host, bases: bases)
                self.stateQueue.sync {
                    self.projectCache[host.name] = CachedProjects(paths: paths, fetchedAt: Date())
                    self.projectFetchInFlight.remove(host.name)
                }
                self.projectsDidUpdate.send(host.name)
                cont.resume(returning: paths)
            }
        }
    }

    /// Drop a host's cached project listing (called on tunnel drop/reconnect so a
    /// stale box's dirs are never shown against a fresh connection). Idempotent.
    func invalidateProjects(hostName: String) {
        stateQueue.sync {
            projectCache[hostName] = nil
            projectFetchInFlight.remove(hostName)
        }
    }

    /// Blocking worker: run the remote `find` (with an `ls` fallback) for each
    /// base over the existing ControlMaster, combine + dedupe + sort by displayed
    /// name. MUST run off-main (spawns `ssh`). Empty on any failure (no master, no
    /// ssh) — best-effort like the rest of the supervisor.
    private func runFindProjects(host: RemoteHostEntry, bases: [String]) -> [String] {
        guard let ssh = Self.resolveSSH(), let cp = try? controlPath(for: host) else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for base in bases where !base.isEmpty {
            let raw = Self.runRemoteList(ssh: ssh, controlPath: cp, target: host.sshTarget, base: base)
            for p in Self.parseNulPaths(raw) where seen.insert(p).inserted { out.append(p) }
        }
        return out.sorted {
            ($0 as NSString).lastPathComponent
                .localizedCaseInsensitiveCompare(($1 as NSString).lastPathComponent) == .orderedAscending
        }
    }

    /// Run the remote directory listing over the supervisor's ControlMaster
    /// (`ControlMaster=no` reuses it, never spawns a competing master). PRIMARY:
    /// `find -L <base> -mindepth 1 -maxdepth 1 -type d -print0` — POSIX-portable,
    /// follows symlinks, dirs only, NUL-delimited (the symlink-follow the local
    /// Swift `isProjectDirectory` gives us, encoded remotely). FALLBACK on a
    /// find failure: `ls -1p <base>`, keeping only `/`-suffixed (directory)
    /// entries, re-joined as NUL-delimited absolute paths (best-effort; no
    /// symlink follow). Returns NUL-joined bytes for `parseNulPaths`.
    private static func runRemoteList(ssh: String, controlPath: String, target: String, base: String) -> Data {
        let common = [
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlMaster=no",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
        ]
        if let d = runSSHCapture(ssh: ssh, args: common + [
            target,
            "find", "-L", base, "-mindepth", "1", "-maxdepth", "1", "-type", "d", "-print0",
        ]), !d.isEmpty {
            return d
        }
        guard let ls = runSSHCapture(ssh: ssh, args: common + [target, "ls", "-1p", base]) else {
            return Data()
        }
        let text = String(decoding: ls, as: UTF8.self)
        var joined = Data()
        let prefix = base.hasSuffix("/") ? base : base + "/"
        for line in text.split(separator: "\n") where line.hasSuffix("/") {
            let name = line.dropLast()
            guard !name.isEmpty else { continue }
            joined.append(Data((prefix + name).utf8))
            joined.append(0)
        }
        return joined
    }

    /// Spawn `ssh` with `args`, capture stdout, and return it only on a clean
    /// exit (nil otherwise). stdout is drained BEFORE `waitUntilExit` so a large
    /// listing can't deadlock on a full pipe buffer.
    private static func runSSHCapture(ssh: String, args: [String]) -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ssh)
        proc.arguments = args
        proc.environment = tunnelEnvironment()
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return proc.terminationStatus == 0 ? data : nil
    }

    /// Resolve the LOCAL forwarded-socket path for a host: the user's explicit pin (tilde
    /// expanded) if present, else a derived path under a 0700 short dir. Always
    /// length-checked against the `sun_path` limit (D7).
    func resolveForwardedSocketPath(for host: RemoteHostEntry) throws -> String {
        if let explicit = host.localSocketPath {
            let expanded = (explicit as NSString).expandingTildeInPath
            try Self.checkSunPath(expanded)
            return expanded
        }
        let dir = try tunnelDir()
        let path = dir.appendingPathComponent("\(Self.shortHash(host.name)).sock").path
        try Self.checkSunPath(path)
        return path
    }

    static func checkSunPath(_ path: String) throws {
        if path.utf8.count > maxSunPathBytes { throw TunnelError.socketPathTooLong(path) }
    }

    /// A short 0700 dir under the per-user temp dir for forwarded sockets + control paths.
    private func tunnelDir() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("grt", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return dir
    }

    /// A stable 8-hex-char digest of the host name, for short socket/control-path
    /// filenames (keeps sun_path short — D7). FNV-1a; not security-sensitive.
    static func shortHash(_ s: String) -> String {
        var h: UInt64 = 1469598103934665603  // FNV-1a offset basis
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(format: "%08x", UInt32(truncatingIfNeeded: h))
    }

    /// The ssh ControlPath (multiplex socket) for a host — a short filename under the 0700
    /// tunnel dir so it stays well under `sun_path`. Used by spawn, `ssh -O check`
    /// (health), and `ssh -O exit` (stale-cleanup before respawn).
    func controlPath(for host: RemoteHostEntry) throws -> String {
        try tunnelDir().appendingPathComponent("\(Self.shortHash(host.name)).cp").path
    }

    private func spawnTunnel(
        host: RemoteHostEntry,
        ssh: String,
        localSocket: String,
        sshOptions: String?
    ) throws {
        let controlPath = try self.controlPath(for: host)
        // Best-effort cleanup of a stale forwarded socket (the host unlinks-and-rebinds;
        // ssh -L refuses to bind onto an existing path).
        try? FileManager.default.removeItem(atPath: localSocket)

        let extra = Self.splitSSHOptions(sshOptions)
        let env = Self.tunnelEnvironment()

        // Central ControlMaster owned by the supervisor (so it can `ssh -O check` /
        // `ssh -O exit` in Phase 2). Short ControlPersist bounds an orphaned master on GUI
        // death until the Phase-2 ppid watchdog lands.
        let master = Process()
        master.executableURL = URL(fileURLWithPath: ssh)
        master.arguments = [
            "-M", "-N",
            "-o", "ControlMaster=yes",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=10s",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=3",
            "-o", "ExitOnForwardFailure=yes",
        ] + extra + [host.sshTarget]
        master.environment = env
        master.standardInput = FileHandle.nullDevice

        // (J1) Auto-respawn on master exit — crash, network drop, or a ControlPersist
        // timeout. Fires on an arbitrary thread; hop to the supervision queue. Respawn is
        // gated inside `handleMasterExit` on the host still being `wanted` (>0), so a bare
        // `ensureTunnel` (no `retainTunnel`) stays one-shot (Phase-1 behavior).
        let startedAt = Date()
        master.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.supervisionQueue.async {
                self.handleMasterExit(
                    hostName: host.name, status: proc.terminationStatus, startedAt: startedAt)
            }
        }

        // Forwarder reuses the master (ControlMaster=no) and owns the -L unix→unix forward.
        // StreamLocalBindMask=0177 ⇒ the forwarded socket is 0600.
        let forwarder = Process()
        forwarder.executableURL = URL(fileURLWithPath: ssh)
        forwarder.arguments = [
            "-N",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=3",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "StreamLocalBindMask=0177",
            "-L", "\(localSocket):\(host.remoteSocketPath)",
        ] + extra + [host.sshTarget]
        forwarder.environment = env
        forwarder.standardInput = FileHandle.nullDevice

        try master.run()
        do {
            try forwarder.run()
        } catch {
            master.terminate()
            throw error
        }

        stateQueue.sync {
            masterProcesses[host.name] = master
            forwarderProcesses[host.name] = forwarder
        }
    }

    // MARK: - Command-mode transport (Phase 6): a single long-lived forward process

    /// (Phase 6) Bring up a COMMAND-mode tunnel: ONE long-lived process that runs the
    /// per-host `command` through the user's LOGIN + INTERACTIVE shell (so a shell FUNCTION
    /// — e.g. a wrapper / gateway launcher exposed as a function — resolves) with the forward + keepalive
    /// APPENDED (see `singleForwardArgv`). NO ControlMaster and NO separate forwarder — this
    /// single process IS the transport. It is tracked in `masterProcesses` (the "master"
    /// slot) so the SHARED `handleMasterExit` respawn + `teardown` machinery drives it
    /// UNCHANGED; `forwarderProcesses` stays empty for the host (a nil forwarder terminate is
    /// a no-op). Readiness is armed by the caller (`startProbing`) exactly as in ssh mode.
    private func spawnCommandTunnel(
        host: RemoteHostEntry,
        command: String,
        localSocket: String
    ) throws {
        // Best-effort cleanup of a stale forwarded socket (an `ssh -L` refuses to bind onto
        // an existing path; the remote host unlinks-and-rebinds its own end).
        try? FileManager.default.removeItem(atPath: localSocket)

        let argv = Self.singleForwardArgv(
            shell: Self.loginShell(),
            command: command,
            localSocket: localSocket,
            remoteSocket: host.remoteSocketPath)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: argv[0])
        proc.arguments = Array(argv.dropFirst())
        proc.environment = Self.tunnelEnvironment()
        proc.standardInput = FileHandle.nullDevice

        // (J1, reused) Auto-respawn on process exit — the transport command's gateway drop,
        // a network blip, or a clean kill. Gated inside `handleMasterExit` on the host still
        // being `wanted` (>0), same as the ssh-master path.
        let startedAt = Date()
        proc.terminationHandler = { [weak self] p in
            guard let self else { return }
            let exitedPid = p.processIdentifier
            self.supervisionQueue.async {
                // (Phase 6) Reap any orphaned forward/gateway left in the exited shell's
                // process group before respawn/teardown (SIGKILL the group; a non-leader
                // pid is a harmless ESRCH no-op, never the GUI's group).
                if exitedPid > 0 { kill(-exitedPid, SIGKILL) }
                self.handleMasterExit(
                    hostName: host.name, status: p.terminationStatus, startedAt: startedAt)
            }
        }

        try proc.run()

        // (Phase 6) Command-mode teardown reaps the whole process GROUP via `kill(-pid, …)`,
        // which requires the tracked shell to be its OWN process-group leader (pgid == pid).
        // ⚠️ This `setpgid` is a best-effort belt-and-suspenders that is EXPECTED to FAIL with
        // EACCES: Foundation.Process spawns via `posix_spawn`, so by the time `run()` returns
        // the child has ALREADY exec'd, and a parent cannot change an exec'd child's pgid — so
        // it is effectively a no-op here, NOT the load-bearing mechanism. The ACTUAL group
        // leadership is provided by the INTERACTIVE (`-i`) login shell self-`setpgid`ing during
        // job-control init (it self-leads its group even without a controlling tty). That
        // assumption is guarded by `commandModeTransportProcessIsItsOwnGroupLeader`; if it ever
        // regresses (e.g. dropping `-i`, or a shell that doesn't self-lead when interactive-
        // without-tty), the group-kill degrades to a harmless ESRCH no-op and teardown falls
        // back to SIGKILLing the shell pid + unlinking the socket (see `forceKillCommandProcess`).
        let pid = proc.processIdentifier
        if pid > 0 { setpgid(pid, pid) }

        stateQueue.sync {
            masterProcesses[host.name] = proc
            // No ControlMaster forwarder in command mode.
            forwarderProcesses[host.name] = nil
        }
    }

    /// (Phase 6, PURE + unit-tested) Build the COMMAND-mode transport invocation argv WITHOUT
    /// spawning. The custom `command` may be a shell FUNCTION, which only resolves in the
    /// user's INTERACTIVE LOGIN shell — so the whole thing runs as
    /// `<shell> -ilc '<command> <forward+keepalive>'`. The forward + keepalive are APPENDED
    /// to the command (never string-spliced INTO it): `-N -L <local>:<remote>` plus the SSH
    /// keepalive / fail-fast / bind-mask `-o`s. `StreamLocalBindMask=0177` is best-effort
    /// (honored by the underlying OpenSSH). Deliberately emits NO ControlMaster / `-M` /
    /// `-O check` / `-O exit` — those belong ONLY to the default `ssh` transport.
    /// Returns the full argv (argv[0] is the shell); the spawner uses argv[0] as the
    /// executable and the remainder as arguments.
    static func singleForwardArgv(
        shell: String,
        command: String,
        localSocket: String,
        remoteSocket: String
    ) -> [String] {
        let forward = "\(command) -N -L \(localSocket):\(remoteSocket)"
            + " -o ServerAliveInterval=15"
            + " -o ServerAliveCountMax=3"
            + " -o ExitOnForwardFailure=yes"
            + " -o StreamLocalBindMask=0177"
        return [shell, "-ilc", forward]
    }

    /// The user's login shell (from `$SHELL`, falling back to zsh) — the shell a COMMAND-mode
    /// transport runs under so a shell FUNCTION resolves. Mirrors the shell resolution in
    /// `probeViaLoginShell` / `AgentManagerController.probeExecutableViaLoginShell`.
    static func loginShell() -> String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    static func splitSSHOptions(_ options: String?) -> [String] {
        guard let options, !options.isEmpty else { return [] }
        return options.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    /// The env the `ssh` children run under. Seeds from the process env (which for a
    /// launchd/Finder-launched GUI lacks shell-exported vars) and, when the GUI env is
    /// missing `SSH_AUTH_SOCK` (a shell-set agent, e.g. 1Password), fills it from a login
    /// shell — the same env-gap the sidecar controller works around (D7).
    static func tunnelEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if env["SSH_AUTH_SOCK"] == nil, let sock = probeViaLoginShell("printf %s \"$SSH_AUTH_SOCK\"") {
            env["SSH_AUTH_SOCK"] = sock
        }
        return env
    }

    /// Resolve the `ssh` executable robustly to the GUI's pristine launchd PATH: well-known
    /// absolute locations first, then a login / interactive-login shell `command -v`
    /// (the `-lc`/`-ilc` pattern the sidecar controller uses).
    static func resolveSSH() -> String? {
        let fm = FileManager.default
        for p in ["/usr/bin/ssh", "/opt/homebrew/bin/ssh", "/usr/local/bin/ssh"]
        where fm.isExecutableFile(atPath: p) {
            return p
        }
        if let resolved = probeViaLoginShell("command -v ssh 2>/dev/null"),
           fm.isExecutableFile(atPath: resolved) {
            return resolved
        }
        return nil
    }

    /// Run `command` in a LOGIN then INTERACTIVE-login shell and return its trimmed single-
    /// line stdout (isolated by a printf marker; stdin=/dev/null so a prompt EOFs instead
    /// of hanging). Best-effort; nil on any failure. Mirrors
    /// `AgentManagerController.probeExecutableViaLoginShell`.
    private static func probeViaLoginShell(_ command: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let marker = "__GHOSTTY_RTUN__"
        for interactive in [false, true] {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: shell)
            proc.arguments = [
                interactive ? "-ilc" : "-lc",
                "printf '\(marker)%s\\n' \"$(\(command))\"",
            ]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            proc.standardInput = FileHandle.nullDevice
            do {
                try proc.run()
                proc.waitUntilExit()
            } catch {
                continue
            }
            guard proc.terminationStatus == 0 else { continue }
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            for line in out.split(separator: "\n") where line.hasPrefix(marker) {
                let value = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { return String(value) }
            }
        }
        return nil
    }
}

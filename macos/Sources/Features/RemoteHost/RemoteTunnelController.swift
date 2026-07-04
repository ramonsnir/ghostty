import Combine
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
/// Phase-1 does NOT auto-respawn the master or redial mid-session (Phase 2, task J1).
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

    // MARK: - State (guarded by stateQueue)

    private let stateQueue = DispatchQueue(label: "com.mitchellh.ghostty-ramon.remote-tunnel.state")
    /// Per-host readiness, replayed to late subscribers (a restored surface may subscribe
    /// AFTER the tunnel already handshaked). `nil` until the first successful handshake.
    private var subjects: [String: CurrentValueSubject<Readiness?, Never>] = [:]
    /// Monotonic per-host token; a bump cancels the in-flight probe loop for that host.
    private var probeGeneration: [String: Int] = [:]
    private var masterProcesses: [String: Process] = [:]
    private var forwarderProcesses: [String: Process] = [:]

    /// The probe blocks up to `timeout_ms`, so it MUST run off the main thread.
    private let probeQueue = DispatchQueue(
        label: "com.mitchellh.ghostty-ramon.remote-tunnel.probe",
        attributes: .concurrent)

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

    /// Tear down a host's tunnel: cancel probing, ask the master to exit its forwards,
    /// and terminate both processes. Best-effort (Phase 1; the last-surface-closes trigger
    /// is a Phase-2 concern).
    func teardown(hostName: String) {
        stopProbing(hostName: hostName)
        let (master, forwarder) = stateQueue.sync {
            (masterProcesses.removeValue(forKey: hostName),
             forwarderProcesses.removeValue(forKey: hostName))
        }
        forwarder?.terminate()
        master?.terminate()
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

    private func spawnTunnel(
        host: RemoteHostEntry,
        ssh: String,
        localSocket: String,
        sshOptions: String?
    ) throws {
        let controlPath = try tunnelDir()
            .appendingPathComponent("\(Self.shortHash(host.name)).cp").path
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

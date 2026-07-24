import Darwin
import Foundation
import Testing
@testable import Ghostty

/// (ramon fork / cloud-hosts) Tests for the tunnel supervisor's READINESS gate — the
/// core invariant that "ready" fires ONLY after a full Hello→HelloAck round-trip
/// (`handshaked == true`), never on a bare `reachable` accept-then-EOF (the `ssh -L`
/// false-positive of D1). Uses `FakeHostSocket`, a real local unix-socket acceptor that
/// speaks the actual `HelloAck` wire frame so the REAL B5 export (`ghostty_probe_host`,
/// via `RemoteTunnelController.probe`) decodes it — no Swift-side codec, no wire drift.
struct RemoteTunnelControllerTests {

    // MARK: - Probe (direct B5 export exercise)

    @Test func probeDecodesHelloAckVersion() throws {
        let acceptor = try FakeHostSocket(mode: .handshake(major: 5, minor: 2))
        defer { acceptor.stop() }
        let r = RemoteTunnelController.probe(socketPath: acceptor.path, timeoutMs: 1500)
        #expect(r.reachable)
        #expect(r.handshaked)
        #expect(r.major == 5)
        #expect(r.minor == 2)
    }

    @Test func probeReachableButNotHandshakedOnAcceptThenClose() throws {
        // The exact ssh -L accept-then-EOF false-positive: connect succeeds, no ack.
        let acceptor = try FakeHostSocket(mode: .acceptThenClose)
        defer { acceptor.stop() }
        let r = RemoteTunnelController.probe(socketPath: acceptor.path, timeoutMs: 600)
        #expect(r.reachable)
        #expect(!r.handshaked)
    }

    @Test func probeUnreachableWhenNoListener() {
        let path = NSTemporaryDirectory() + "grt-none-\(UUID().uuidString.prefix(8)).sock"
        let r = RemoteTunnelController.probe(socketPath: path, timeoutMs: 300)
        #expect(!r.reachable)
        #expect(!r.handshaked)
    }

    // MARK: - Readiness publisher

    @Test func readinessFiresOnlyOnHandshakeAndStashesVersion() async throws {
        let acceptor = try FakeHostSocket(mode: .handshake(major: 3, minor: 7))
        defer { acceptor.stop() }
        let controller = RemoteTunnelController.shared
        let host = "test-handshake-\(UUID().uuidString.prefix(6))"
        controller.startProbing(hostName: host, socketPath: acceptor.path, probeTimeoutMs: 1000)
        defer { controller.stopProbing(hostName: host) }

        let readiness = try await Self.waitForReadiness(controller, host, timeout: 4.0)
        #expect(readiness.hostName == host)
        #expect(readiness.socketPath == acceptor.path)
        #expect(readiness.major == 3)   // stashed host version feeds Phase-2 classify (D1)
        #expect(readiness.minor == 7)
    }

    @Test func acceptThenEofNeverFiresReady() async throws {
        let acceptor = try FakeHostSocket(mode: .acceptThenClose)
        defer { acceptor.stop() }
        let controller = RemoteTunnelController.shared
        let host = "test-eof-\(UUID().uuidString.prefix(6))"
        controller.startProbing(hostName: host, socketPath: acceptor.path, probeTimeoutMs: 400)
        defer { controller.stopProbing(hostName: host) }

        // Observe a bounded window; a bare reachable-but-no-ack must NOT become ready.
        try await Task.sleep(nanoseconds: 1_600_000_000)
        #expect(controller.currentReadiness(for: host) == nil)
    }

    // MARK: - Pure helpers

    @Test func backoffIsQuickBurstThenSteadyForever() {
        #expect(RemoteTunnelController.backoff(forAttempt: 0) == 0.5)
        #expect(RemoteTunnelController.backoff(forAttempt: 4) == 8)
        // Past the burst it clamps to the steady cadence (never gives up).
        #expect(RemoteTunnelController.backoff(forAttempt: 5) == 15)
        #expect(RemoteTunnelController.backoff(forAttempt: 99) == 15)
        // Defensive: a negative attempt never goes negative/zero.
        #expect(RemoteTunnelController.backoff(forAttempt: -1) > 0)
    }

    // MARK: - Respawn backoff (J1) — mirrors AgentMirrorReconnectTests

    @Test func backoffQuickBurstThenSteadyMinute() {
        // Quick exponential burst 1,2,4,8,16,30 then the steady 60s cadence.
        #expect(RemoteTunnelController.respawnDelay(forAttempt: 0) == 1)
        #expect(RemoteTunnelController.respawnDelay(forAttempt: 1) == 2)
        #expect(RemoteTunnelController.respawnDelay(forAttempt: 2) == 4)
        #expect(RemoteTunnelController.respawnDelay(forAttempt: 3) == 8)
        #expect(RemoteTunnelController.respawnDelay(forAttempt: 4) == 16)
        #expect(RemoteTunnelController.respawnDelay(forAttempt: 5) == 30)
        #expect(RemoteTunnelController.respawnDelay(forAttempt: 6) == 60)
    }

    @Test func backoffSettlesAtSteadyIntervalForever() {
        // Never gives up: every attempt past the quick burst clamps to the steady cadence.
        #expect(RemoteTunnelController.respawnDelay(forAttempt: 6) == 60)
        #expect(RemoteTunnelController.respawnDelay(forAttempt: 50) == 60)
        #expect(RemoteTunnelController.respawnDelay(forAttempt: 10_000) == 60)
    }

    @Test func backoffNeverNegativeOrZero() {
        for a in -3...12 {
            #expect(RemoteTunnelController.respawnDelay(forAttempt: a) > 0)
        }
    }

    // MARK: - Connect-timeout ceiling (REG-T3)

    @Test func connectTimeoutMsMapsZeroToCompiledDefault() {
        // 0 ⇒ the compiled-in default seconds; a positive value passes through (×1000).
        #expect(RemoteTunnelController.connectTimeoutMs(0)
                == RemoteTunnelController.defaultConnectTimeoutSeconds * 1000)
        #expect(RemoteTunnelController.connectTimeoutMs(15) == 15_000)
        #expect(RemoteTunnelController.connectTimeoutMs(1) == 1_000)
    }

    // MARK: - Teardown cancels a live probe loop (J1, D7 last-surface-closes)

    @Test func teardownCancelsInFlightProbeLoop() async throws {
        // A never-handshaking acceptor keeps the probe loop retrying forever; teardown()
        // (what the last releaseTunnel calls) bumps the probe generation so the loop's
        // isCurrent gate fails and it exits — no readiness ever fires, before or after.
        let acceptor = try FakeHostSocket(mode: .acceptThenClose)
        defer { acceptor.stop() }
        let controller = RemoteTunnelController.shared
        let host = "test-teardown-\(UUID().uuidString.prefix(6))"

        controller.startProbing(hostName: host, socketPath: acceptor.path, probeTimeoutMs: 300)
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(controller.currentReadiness(for: host) == nil)  // reachable-but-no-ack ≠ ready

        controller.teardown(hostName: host)
        // Still nil after teardown, and no leaked loop can flip it later.
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(controller.currentReadiness(for: host) == nil)
    }

    // MARK: - Surface refcount + respawn gate wiring (J1, D7)

    /// A surface create/close PAIR must increment then zero the want-count (`wanted`),
    /// and the never-give-up respawn gate must be armed EXACTLY while a surface still
    /// wants the host. This proves the J1 machinery is WIRED: the refcount `retainTunnel`
    /// bumps (which `SurfaceView.subscribeRemoteReadiness` now calls, and
    /// `SurfaceView.deinit` releases) is the SAME count `handleMasterExit` gates the
    /// respawn on — so a hard tunnel drop while a surface is alive schedules a respawn
    /// instead of looping on `.unreachable` forever. Uses the non-spawning `noteRetain`/
    /// `noteRelease` seams (the single source of truth behind retain/release) so the test
    /// never launches ssh.
    @Test func retainReleasePairTracksWantCountAndArmsRespawn() {
        let controller = RemoteTunnelController.shared
        let name = "test-refcount-\(UUID().uuidString.prefix(6))"
        let entry = RemoteHostEntry(
            name: name,
            sshTarget: "user@\(name).invalid",
            remoteSocketPath: "/tmp/ghostty-host.sock",
            localSocketPath: nil)

        // Before any surface: nobody wants it, so a master exit would NOT respawn.
        #expect(controller.wantedCount(for: name) == 0)
        #expect(!controller.wouldRespawnOnMasterExit(hostName: name))

        // Surface #1 created: count → 1, and it is the FIRST (bring-up) surface. The
        // respawn gate is now ARMED purely because a surface wants the host — this is the
        // exact `wanted[host] > 0` condition the dead-code review flagged as never true.
        #expect(controller.noteRetain(host: entry, connectTimeout: 0))
        #expect(controller.wantedCount(for: name) == 1)
        #expect(controller.wouldRespawnOnMasterExit(hostName: name))

        // Surface #2 for the same host: NOT first; count → 2.
        #expect(!controller.noteRetain(host: entry, connectTimeout: 0))
        #expect(controller.wantedCount(for: name) == 2)

        // Close one surface: count → 1, NOT the last (no teardown), respawn still armed.
        #expect(!controller.noteRelease(hostName: name))
        #expect(controller.wantedCount(for: name) == 1)
        #expect(controller.wouldRespawnOnMasterExit(hostName: name))

        // Close the LAST surface: count → 0 (the last-surface teardown trigger) and the
        // respawn gate CLOSES — a master exit no longer respawns (the intended-stop case).
        #expect(controller.noteRelease(hostName: name))
        #expect(controller.wantedCount(for: name) == 0)
        #expect(!controller.wouldRespawnOnMasterExit(hostName: name))

        controller.teardown(hostName: name)  // clean shared singleton state
    }

    @Test func shortHashIsStableEightHex() {
        let a = RemoteTunnelController.shortHash("cloud-1")
        let b = RemoteTunnelController.shortHash("cloud-1")
        let c = RemoteTunnelController.shortHash("cloud-2")
        #expect(a == b)
        #expect(a != c)
        #expect(a.count == 8)
    }

    @Test func checkSunPathRejectsOverlongPath() {
        let ok = "/tmp/short.sock"
        #expect(throws: Never.self) { try RemoteTunnelController.checkSunPath(ok) }
        let tooLong = "/tmp/" + String(repeating: "x", count: 200) + ".sock"
        #expect(throws: RemoteTunnelController.TunnelError.self) {
            try RemoteTunnelController.checkSunPath(tooLong)
        }
    }

    @Test func splitsSSHOptionsOnWhitespace() {
        #expect(RemoteTunnelController.splitSSHOptions(nil).isEmpty)
        #expect(RemoteTunnelController.splitSSHOptions("").isEmpty)
        #expect(RemoteTunnelController.splitSSHOptions("-J jump.example.ts.net -i ~/.ssh/id")
                == ["-J", "jump.example.ts.net", "-i", "~/.ssh/id"])
    }

    // MARK: - (Phase 6) Command-mode single-forward transport

    /// The PURE argv builder wraps the command in the user's LOGIN + INTERACTIVE shell
    /// (`-ilc`, so a shell FUNCTION resolves), APPENDS the `-N -L <local>:<remote>` forward +
    /// keepalive + bind-mask, and substitutes the socket placeholders — WITHOUT spawning.
    @Test func singleForwardArgvWrapsCommandInInteractiveLoginShellWithForward() {
        let argv = RemoteTunnelController.singleForwardArgv(
            shell: "/bin/zsh",
            command: "gcp_ssh cloud-1 --",
            localSocket: "/tmp/grt/abc.sock",
            remoteSocket: "~/.ghostty-ramon-host.sock")

        // argv[0] is the shell, argv[1] is the interactive-login flag, argv[2] the script.
        #expect(argv.count == 3)
        #expect(argv[0] == "/bin/zsh")
        #expect(argv[1] == "-ilc")

        let script = argv[2]
        // The custom command leads, verbatim.
        #expect(script.hasPrefix("gcp_ssh cloud-1 -- "))
        // The forward is APPENDED with both socket placeholders substituted.
        #expect(script.contains("-N -L /tmp/grt/abc.sock:~/.ghostty-ramon-host.sock"))
        // Keepalive + fail-fast + best-effort bind-mask are all present.
        #expect(script.contains("-o ServerAliveInterval=15"))
        #expect(script.contains("-o ServerAliveCountMax=3"))
        #expect(script.contains("-o ExitOnForwardFailure=yes"))
        #expect(script.contains("-o StreamLocalBindMask=0177"))
    }

    /// A command-mode transport must NOT emit ANY ControlMaster / `-O check` / `-O exit` /
    /// `-M` flags — those belong ONLY to the default `ssh` path. Readiness is the SAME
    /// socket-probe (`ghostty_probe_host`) used by every host, so no ssh-multiplex liveness
    /// concept applies (the ControlMaster health check short-circuits to false WITHOUT
    /// spawning `ssh`).
    @Test func commandModeEmitsNoControlMasterOrControlFlags() {
        let argv = RemoteTunnelController.singleForwardArgv(
            shell: "/bin/zsh",
            command: "gcp_ssh cloud-1 --",
            localSocket: "/tmp/grt/abc.sock",
            remoteSocket: "/run/gr.sock")
        let script = argv[2]
        #expect(!script.contains("ControlMaster"))
        #expect(!script.contains("ControlPath"))
        #expect(!script.contains("ControlPersist"))
        #expect(!script.contains("-O check"))
        #expect(!script.contains("-O exit"))
        // `-M` (master) must not appear as its own token.
        #expect(!script.split(separator: " ").contains("-M"))

        // The `ssh -O check` health path is guarded OFF for a command-mode host: it returns
        // false immediately, WITHOUT spawning ssh (proving the ControlMaster path is skipped).
        let entry = RemoteHostEntry(
            name: "cmd-\(UUID().uuidString.prefix(6))",
            sshTarget: "label-only",
            remoteSocketPath: "/run/gr.sock",
            localSocketPath: nil,
            transportCommand: "gcp_ssh cloud-1 --")
        #expect(RemoteTunnelController.shared.checkMasterHealth(host: entry) == false)
    }

    /// Command-mode teardown reaps the whole process GROUP with `kill(-pid, …)`, which ONLY
    /// works if the spawned transport shell is its OWN process-group leader (pgid == pid). The
    /// post-`run()` `setpgid(pid,pid)` in `spawnCommandTunnel` is a best-effort no-op
    /// (Foundation.Process `posix_spawn`s, so the child has already exec'd → EACCES); the ACTUAL
    /// leadership comes from the INTERACTIVE (`-i`) login shell self-leading its group during
    /// job-control init (even without a controlling tty). This guards that load-bearing
    /// assumption end-to-end: it spawns the SAME interactive-login shell with the SAME detached
    /// stdin `spawnCommandTunnel` uses and asserts the shell leads its own group. If it ever
    /// regresses (e.g. dropping `-i`, or a shell that no longer self-leads), the group-kill
    /// silently degrades to an ESRCH no-op and every teardown would leak the `ssh -N` forward +
    /// gateway — this test fails first.
    @Test func commandModeTransportProcessIsItsOwnGroupLeader() throws {
        let shell = RemoteTunnelController.loginShell()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        // Same interactive-login invocation (`-ilc`) + detached stdin as `spawnCommandTunnel`.
        proc.arguments = ["-ilc", "sleep 5"]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        let pid = proc.processIdentifier
        defer {
            // Reap via the exact group-kill teardown relies on, then the pid, then wait.
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
            proc.waitUntilExit()
        }
        // The shell self-`setpgid`s during job-control init; poll briefly for it to settle.
        var pgid = getpgid(pid)
        for _ in 0..<100 where pgid != pid {
            usleep(20_000) // 20ms, up to ~2s total
            pgid = getpgid(pid)
        }
        #expect(
            pgid == pid,
            "command-mode transport shell must lead its own process group so kill(-pid) reaps the ssh forward + gateway; got pgid=\(pgid) pid=\(pid)")
    }

    @Test func loginShellPrefersSHELLEnvOrFallsBackToZsh() {
        let shell = RemoteTunnelController.loginShell()
        // Either the env's SHELL or the zsh fallback — never empty.
        #expect(!shell.isEmpty)
        if let env = ProcessInfo.processInfo.environment["SHELL"] {
            #expect(shell == env)
        } else {
            #expect(shell == "/bin/zsh")
        }
    }

    // MARK: - waitForReadiness

    /// Poll the controller's synchronous readiness snapshot until it's set or the timeout
    /// elapses. Avoids depending on the RunLoop.main delivery in the publisher path — the
    /// probe loop sets the subject value synchronously off-main.
    static func waitForReadiness(
        _ controller: RemoteTunnelController,
        _ host: String,
        timeout: TimeInterval
    ) async throws -> RemoteTunnelController.Readiness {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let r = controller.currentReadiness(for: host) { return r }
            try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        }
        throw ReadinessTimeout()
    }

    struct ReadinessTimeout: Error {}
}

// MARK: - FakeHostSocket

/// A minimal local unix-domain acceptor that speaks the REAL `ghostty-host` wire framing
/// so `ghostty_probe_host` decodes it. `.handshake` writes one framed `HelloAck`;
/// `.acceptThenClose` accepts then closes with zero bytes (the ssh -L false-positive).
final class FakeHostSocket {
    enum Mode {
        case handshake(major: UInt16, minor: UInt16)
        case acceptThenClose
    }

    let path: String
    private let mode: Mode
    private var listenFD: Int32 = -1
    private var thread: Thread?
    private var stopped = false

    init(mode: Mode) throws {
        self.mode = mode
        // Short path under the per-user temp dir (well under sun_path's ~104 bytes).
        self.path = NSTemporaryDirectory() + "grt-t-\(UUID().uuidString.prefix(8)).sock"
        try bindAndListen()
        startAccepting()
    }

    private func bindAndListen() throws {
        unlink(path)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw SocketError.create }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw SocketError.pathTooLong }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: capacity) { cptr in
                for (i, b) in bytes.enumerated() { cptr[i] = CChar(bitPattern: b) }
                cptr[bytes.count] = 0
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, size) }
        }
        guard rc == 0 else { throw SocketError.bind }
        guard listen(listenFD, 4) == 0 else { throw SocketError.listen }
    }

    private func startAccepting() {
        let t = Thread { [weak self] in
            guard let self else { return }
            while !self.stopped {
                let client = accept(self.listenFD, nil, nil)
                if client < 0 { break }  // listen fd closed by stop()
                switch self.mode {
                case let .handshake(major, minor):
                    let frame = FakeHostSocket.helloAckFrame(major: major, minor: minor)
                    frame.withUnsafeBytes { raw in
                        _ = write(client, raw.baseAddress, raw.count)
                    }
                    // Give the write time to flush before we close.
                    Thread.sleep(forTimeInterval: 0.2)
                    close(client)
                case .acceptThenClose:
                    close(client)  // zero-byte EOF
                }
            }
        }
        t.stackSize = 1 << 20
        t.start()
        thread = t
    }

    func stop() {
        stopped = true
        if listenFD >= 0 {
            close(listenFD)  // unblocks accept()
            listenFD = -1
        }
        unlink(path)
    }

    /// Build a framed `HelloAck`: [u32 BE length][tag=1 (hello_ack)][payload]. In-frame
    /// scalars are LITTLE-endian (protocol.zig `writeInt`): major u16, minor u16,
    /// host_pid i32, host_start_epoch i64 = 16 payload bytes, length = 17.
    static func helloAckFrame(major: UInt16, minor: UInt16) -> [UInt8] {
        var payload: [UInt8] = []
        payload += withUnsafeBytes(of: major.littleEndian) { Array($0) }        // 2
        payload += withUnsafeBytes(of: minor.littleEndian) { Array($0) }        // 2
        payload += withUnsafeBytes(of: Int32(4242).littleEndian) { Array($0) }  // host_pid
        payload += withUnsafeBytes(of: Int64(1).littleEndian) { Array($0) }     // start epoch

        let len = UInt32(1 + payload.count)  // tag byte + payload
        var frame: [UInt8] = []
        frame += withUnsafeBytes(of: len.bigEndian) { Array($0) }  // BE length prefix
        frame.append(1)  // FrameType.hello_ack == 1
        frame += payload
        return frame
    }

    enum SocketError: Error { case create, bind, listen, pathTooLong }
}

// MARK: - Liveness watch + orphan reap (cloud-hardening)

@Suite("RemoteTunnel hardening")
struct RemoteTunnelHardeningTests {
    // The transport process exiting is caught for free; a BLACK-HOLED tunnel is not, and a
    // wrapper (e.g. a Cloud-Workstations launcher) can inject `-o ServerAliveInterval=0`
    // AHEAD of our `=15` — OpenSSH takes the FIRST value, so our keepalive is disabled and
    // the dead tunnel never exits. Hence the periodic handshake probe. Threshold > 1 so one
    // transient blip can't churn the tunnel.
    @Test func livenessTripsOnlyAtTheThreshold() {
        #expect(RemoteTunnelController.livenessFailureThreshold > 1)
        for failures in 0..<RemoteTunnelController.livenessFailureThreshold {
            #expect(RemoteTunnelController.shouldTripLiveness(consecutiveFailures: failures) == false)
        }
        #expect(RemoteTunnelController.shouldTripLiveness(
            consecutiveFailures: RemoteTunnelController.livenessFailureThreshold) == true)
        // Past the threshold stays tripped (no wrap-around / off-by-one).
        #expect(RemoteTunnelController.shouldTripLiveness(
            consecutiveFailures: RemoteTunnelController.livenessFailureThreshold + 5) == true)
    }

    @Test func livenessProbeIntervalIsSaneAndPositive() {
        #expect(RemoteTunnelController.livenessProbeInterval > 0)
        // Must be well under the steady respawn cadence so a dead tunnel is DETECTED
        // long before we'd otherwise notice, but not so tight that it spams the box.
        #expect(RemoteTunnelController.livenessProbeInterval <= RemoteTunnelController.respawnSteadyDelay)
    }

    // The reap key is a per-host, app-private socket path, but the SAFETY property is that
    // it can never target this process or its parent — killing our own group would take the
    // GUI down with it.
    @Test func parsePgrepPidsExcludesSelfAndParentAndJunk() {
        let out = "4242\n\(getpid())\n\(getppid())\n7\nnot-a-pid\n\n  9  \n1\n0\n-3\n"
        let pids = RemoteTunnelController.parsePgrepPids(out, excluding: [getpid(), getppid()])
        #expect(pids == [4242, 7, 9])
        #expect(!pids.contains(getpid()))
        #expect(!pids.contains(getppid()))
        // pid 1 (launchd) and non-positive values are never reaped.
        #expect(!pids.contains(1))
        #expect(!pids.contains(0))
    }

    @Test func parsePgrepPidsEmptyOutputYieldsNothing() {
        #expect(RemoteTunnelController.parsePgrepPids("", excluding: []).isEmpty)
        #expect(RemoteTunnelController.parsePgrepPids("\n\n  \n", excluding: []).isEmpty)
    }
}

// (ramon fork) MCP server: a GUI-embedded HTTP server that speaks JSON-RPC 2.0
// over `POST /mcp`, letting an orchestrating agent (e.g. Claude Code via the
// `ghostty-mcp` stdio shim) read live terminal surfaces and control splits/tabs
// from inside the running macOS app. Fork-only, OFF by default.
//
// This module COPIES the proven threading + security scaffolding from the web
// monitor (serial-queue + main-hop discipline, RequestParser, the Host-header /
// token / backoff defenses, the native-keycode `keySpecs` table) but does NOT
// import or extend it. The web monitor remains untouched.
//
// SECURITY MODEL (no TLS — localhost/tailnet only): the only authentication is
// the optional `mcp-token`. If SET it is required on every `POST /mcp` via the
// `X-Ghostty-Token` header (constant-time compare + per-peer backoff). If EMPTY
// the server runs OPEN (logs a warning) and access control is the bound
// localhost/tailnet alone. That token is LOAD-BEARING: a holder can spawn tabs
// and run shell commands, so treat it as a shell-execution credential and bind
// localhost or a tailnet only. Defense in depth: (a) the bound address; (b) a
// Host-header allowlist (DNS-rebinding guard, NOT an auth boundary); (c) a
// per-peer failed-token backoff (token mode only).
//
// Zero new SPM dependencies: Foundation + Network.framework + AppKit only.

import Foundation
import Network
import AppKit
import UserNotifications
import GhosttyKit
import os

final class MCPServer {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "mcp")

    // INVARIANT (correctness-critical): this is a DEDICATED, private, SERIAL
    // background queue. It is NEVER DispatchQueue.main. The listener, every
    // connection, and every receive/send callback run on this queue, which makes
    // the `DispatchQueue.main.sync { ... }` hops used by the tool handlers
    // deadlock-safe — we are never already on main when we sync onto main.
    let queue = DispatchQueue(label: "com.mitchellh.ghostty-ramon.mcp")

    private let listenSpec: String
    let token: String

    /// The parsed host:port. The host is used ONLY for the Host-header
    /// allowlist (DNS-rebinding defense), never as an IP allowlist.
    private let parsed: (host: String, port: UInt16)?

    private var listener: NWListener?
    private var connectionRefs: [ObjectIdentifier: NWConnection] = [:]

    /// Per-connection idle/read watchdog timers. Mutated only on `queue`.
    private var connectionTimers: [ObjectIdentifier: DispatchSourceTimer] = [:]
    private static let connectionIdleTimeout: TimeInterval = 10

    /// Per-connection ABSOLUTE deadline timers, armed exactly ONCE in `handle()`.
    /// Mutated only on `queue`.
    private var connectionDeadlineTimers: [ObjectIdentifier: DispatchSourceTimer] = [:]
    private static let connectionAbsoluteDeadline: TimeInterval = 15

    /// Hard cap on concurrently-tracked connections. Mutated only on `queue`.
    private static let maxConcurrentConnections = 32

    /// The event bus backing `wait_for_event` / `watch_for_pattern`. Created once,
    /// owned by the server, mutated only on `queue` (its waiter registry) and main
    /// (its event source). See `MCPEventBus`.
    let bus: MCPEventBus

    /// Per-peer failed-token counter (keyed by remote IP string). Cheap brute
    /// force speed bump; resets on a successful auth. Mutated only on `queue`.
    /// Decays past the window and is capped so a spray of distinct IPs cannot
    /// grow it unbounded.
    private var failedAuth: [String: (count: Int, last: Date)] = [:]
    static let failedAuthThreshold = 5
    private static let failedAuthWindow: TimeInterval = 60
    private static let failedAuthMaxEntries = 4096

    /// Current (non-decayed) failure count for a peer. Mutated only on `queue`.
    private func failedAuthCount(_ peer: String) -> Int {
        guard let e = failedAuth[peer] else { return 0 }
        if Date().timeIntervalSince(e.last) > Self.failedAuthWindow {
            failedAuth[peer] = nil
            return 0
        }
        return e.count
    }

    /// Record a failed auth for a peer (bumps the count, refreshes the clock).
    private func recordAuthFailure(_ peer: String) {
        if failedAuth.count >= Self.failedAuthMaxEntries {
            let cutoff = Date().addingTimeInterval(-Self.failedAuthWindow)
            failedAuth = failedAuth.filter { $0.value.last > cutoff }
            while failedAuth.count >= Self.failedAuthMaxEntries,
                  let oldest = failedAuth.min(by: { $0.value.last < $1.value.last })?.key {
                failedAuth[oldest] = nil
            }
        }
        let prev = failedAuthCount(peer)
        failedAuth[peer] = (count: prev + 1, last: Date())
    }

    private func clearAuthFailures(_ peer: String) {
        failedAuth[peer] = nil
    }

    /// Whether the listener entered .failed (surfaced once to the user).
    private(set) var didFailToBind = false

    /// (ramon fork / Agent Queue, §8a) The GUI→sidecar command FIFO. Local control
    /// intents (palette / dashboard buttons / keybind) are posted as
    /// `.ghosttyQueueCommand`; the observer hops the enqueue onto THIS serial queue
    /// and appends here, and `take_queue_commands` drains+clears it (also on `queue`).
    /// So every access is on `queue` — race-free WITHOUT a lock. In-memory only: an
    /// undrained command lost on a GUI crash just means re-trigger (the STARTED-run
    /// STATE is persisted sidecar-side, so a running queue survives regardless).
    /// Mutated ONLY on `queue`.
    var queueCommandFIFO: [QueueCommand] = []

    /// Observer token for `.ghosttyQueueCommand`. Set in `start()`, removed in
    /// `stop()`. Touched only on main (NotificationCenter add/remove).
    var queueCommandObserver: NSObjectProtocol?

    init(listen: String, token: String) {
        self.listenSpec = listen
        self.token = token
        // All three fork identities (Release, ReleaseLocal, Debug) share
        // ~/.config/ghostty-ramon/config, so they read the SAME mcp-listen port
        // and would fight over it when run side-by-side. Shift the dev builds'
        // port up by a per-identity offset so they coexist; Release (the
        // canonical bundle id) keeps the configured port unchanged.
        self.parsed = Self.applyPortOffset(
            Self.parseListen(listen),
            offset: Self.portOffset(forBundleID: Bundle.main.bundleIdentifier))
        self.bus = MCPEventBus()
    }

    // MARK: - Lifecycle

    func start() {
        // Token auth is OPTIONAL. Empty -> run OPEN (access control is the bound
        // localhost/tailnet alone); warn so it is a deliberate choice. A non-empty
        // but short token is allowed but warned.
        if token.isEmpty {
            logger.warning("mcp: starting WITHOUT a token — OPEN on the bound port; access control is the bound address alone")
        } else if !Self.tokenAcceptable(token) {
            logger.warning("mcp: mcp-token is under \(Self.minTokenLength, privacy: .public) chars — consider a longer random token")
        }

        guard let parsed else {
            logger.error("mcp: invalid listen address: \(self.listenSpec, privacy: .public)")
            Self.notify(
                title: "MCP server not started",
                body: "Invalid mcp-listen address: \(self.listenSpec)")
            return
        }
        guard let nwPort = NWEndpoint.Port(rawValue: parsed.port) else {
            logger.error("mcp: invalid listen port: \(self.listenSpec, privacy: .public)")
            return
        }

        // NWListener binds the PORT on all interfaces; the TOKEN (plus the bound
        // address + Host-header allowlist) is the security boundary, not the bind
        // host. Documented in CLAUDE.md.
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        do {
            let l = try NWListener(using: params, on: nwPort)
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            l.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.logger.info("mcp: ready on port \(parsed.port, privacy: .public)")
                case .failed(let err):
                    self.logger.error("mcp: listener failed: \(String(describing: err), privacy: .public)")
                    if !self.didFailToBind {
                        self.didFailToBind = true
                        Self.notify(
                            title: "MCP server failed to bind",
                            body: "Port \(parsed.port): \(String(describing: err)). Is it in use?")
                    }
                case .cancelled:
                    self.logger.info("mcp: listener cancelled")
                default:
                    break
                }
            }
            self.listener = l
            // Start the event bus source (bell observer + the exited/prompt poll)
            // on main, before accepting connections, so a waiter that registers
            // immediately has a live source feeding it.
            bus.start(server: self)
            // (Agent Queue, §8a) Observe local control-command posts and enqueue
            // them onto the FIFO (race-free, on `queue`).
            startQueueCommandObserver()
            l.start(queue: queue)
        } catch {
            logger.error("mcp: failed to create listener: \(String(describing: error), privacy: .public)")
            Self.notify(title: "MCP server failed to start", body: String(describing: error))
        }
    }

    func stop() {
        // Async teardown (never queue.sync from main): handlers running on `queue`
        // themselves hop to main via DispatchQueue.main.sync, so a sync teardown
        // from main would be a lock-order inversion.
        bus.stop()
        stopQueueCommandObserver()
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            for (_, timer) in self.connectionTimers { timer.cancel() }
            self.connectionTimers.removeAll()
            for (_, timer) in self.connectionDeadlineTimers { timer.cancel() }
            self.connectionDeadlineTimers.removeAll()
            for (_, conn) in self.connectionRefs { conn.cancel() }
            self.connectionRefs.removeAll()
        }
    }

    /// Post a one-time user-visible notification (best-effort; also logged).
    private static func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(
            identifier: "mcp-" + UUID().uuidString,
            content: content,
            trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    // MARK: - listen parsing (pure, testable)

    /// Parse a `host:port` listen spec into its parts. Splits on the LAST ':'
    /// so bracketed IPv6 (`[::1]:8765`) and hostnames are tolerated; strips the
    /// surrounding brackets from a bracketed IPv6 host. Returns nil on a missing
    /// host, a missing/non-numeric/out-of-range port.
    static func parseListen(_ spec: String) -> (host: String, port: UInt16)? {
        guard let colonIdx = spec.lastIndex(of: ":") else { return nil }
        var host = String(spec[spec.startIndex..<colonIdx])
        let portPart = String(spec[spec.index(after: colonIdx)...])
        if host.hasPrefix("[") && host.hasSuffix("]") && host.count >= 2 {
            host = String(host.dropFirst().dropLast())
        }
        guard !host.isEmpty else { return nil }
        guard let port = UInt16(portPart) else { return nil }
        return (host, port)
    }

    /// Per-build-identity listen-port offset, keyed off the bundle id suffix —
    /// the same identity scheme as the icon / display-name swaps. The three
    /// fork identities share one config file (hence one configured port), so
    /// without this they would all bind the same port and only the first to
    /// launch would get it. Release (canonical `…ghostty-ramon`) ⇒ 0 (keeps the
    /// configured port); ReleaseLocal (`.local`) ⇒ +1; Debug (`.debug`) ⇒ +2.
    static func portOffset(forBundleID bundleID: String?) -> UInt16 {
        guard let bundleID else { return 0 }
        if bundleID.hasSuffix(".debug") { return 2 }
        if bundleID.hasSuffix(".local") { return 1 }
        return 0
    }

    /// Apply `offset` to a parsed listen spec's port. Pure + testable. Returns
    /// the spec unchanged when there's nothing to parse, the offset is 0, or the
    /// shift would overflow a UInt16 port (in which case the original — which
    /// also can't usefully bind near the ceiling — is kept rather than wrapped).
    static func applyPortOffset(
        _ parsed: (host: String, port: UInt16)?,
        offset: UInt16
    ) -> (host: String, port: UInt16)? {
        guard let parsed, offset > 0 else { return parsed }
        let shifted = Int(parsed.port) + Int(offset)
        guard shifted <= Int(UInt16.max) else { return parsed }
        return (parsed.host, UInt16(shifted))
    }

    // MARK: - Connection handling (background queue)

    private func handle(_ conn: NWConnection) {
        if connectionRefs.count >= Self.maxConcurrentConnections {
            logger.notice("mcp: connection cap (\(Self.maxConcurrentConnections, privacy: .public)) reached, rejecting connection")
            conn.cancel()
            return
        }

        let key = ObjectIdentifier(conn)
        connectionRefs[key] = conn
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.connectionRefs[key] = nil
                self?.cancelConnectionTimer(key)
                // A peer that disconnects while a wait_for_event is parked must
                // have its waiter torn down (single-shot guard makes a later
                // timer/event a no-op).
                self?.bus.connectionDropped(key)
            default:
                break
            }
        }
        armConnectionTimer(key, conn: conn)
        armConnectionDeadline(key, conn: conn)
        conn.start(queue: queue)
        receiveRequest(conn, accumulated: Data())
    }

    /// Arm (or rearm) the one-shot idle watchdog for a connection. Runs on `queue`.
    private func armConnectionTimer(_ key: ObjectIdentifier, conn: NWConnection) {
        connectionTimers[key]?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.connectionIdleTimeout)
        timer.setEventHandler { [weak self] in
            self?.logger.debug("mcp: connection idle timeout, cancelling")
            self?.cancelConnectionTimer(key)
            conn.cancel()
        }
        connectionTimers[key] = timer
        timer.resume()
    }

    /// Arm the one-shot ABSOLUTE deadline for a connection. Runs on `queue`.
    private func armConnectionDeadline(_ key: ObjectIdentifier, conn: NWConnection) {
        connectionDeadlineTimers[key]?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.connectionAbsoluteDeadline)
        timer.setEventHandler { [weak self] in
            self?.logger.debug("mcp: connection absolute deadline, cancelling")
            self?.cancelConnectionTimer(key)
            conn.cancel()
        }
        connectionDeadlineTimers[key] = timer
        timer.resume()
    }

    /// Cancel and drop BOTH the idle watchdog and the absolute-deadline timer
    /// for a connection. Runs on `queue`. Used both for normal completion and,
    /// when a wait_for_event parks the connection, to EXEMPT it from the idle
    /// watchdog (the per-waiter deadline bounds it instead).
    func cancelConnectionTimer(_ key: ObjectIdentifier) {
        connectionTimers[key]?.cancel()
        connectionTimers[key] = nil
        connectionDeadlineTimers[key]?.cancel()
        connectionDeadlineTimers[key] = nil
    }

    /// Sentinel peer key used when no concrete remote IP could be resolved. Many
    /// peers can collapse onto this single key, so it must NEVER drive throttling.
    static let unresolvedPeerKey = "?"

    /// Best-effort remote IP string for the per-peer backoff key.
    private static func remoteIP(of conn: NWConnection) -> String {
        func hostString(_ endpoint: NWEndpoint?) -> String? {
            guard let endpoint else { return nil }
            if case let .hostPort(host, _) = endpoint {
                switch host {
                case .ipv4(let a): return "\(a)"
                case .ipv6(let a): return "\(a)"
                case .name(let n, _): return n
                @unknown default: return nil
                }
            }
            return nil
        }
        return hostString(conn.currentPath?.remoteEndpoint) ?? hostString(conn.endpoint) ?? unresolvedPeerKey
    }

    static let maxRequestBytes = 256 * 1024

    private func receiveRequest(_ conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.logger.debug("mcp: receive error: \(String(describing: error), privacy: .public)")
                conn.cancel()
                return
            }

            var buffer = accumulated
            if let data { buffer.append(data) }

            let key = ObjectIdentifier(conn)
            switch RequestParser.parse(buffer, maxRequestBytes: Self.maxRequestBytes) {
            case .needMore:
                if isComplete {
                    conn.cancel()
                } else {
                    self.armConnectionTimer(key, conn: conn)
                    self.receiveRequest(conn, accumulated: buffer)
                }
            case .tooLarge:
                self.cancelConnectionTimer(key)
                self.send(.status(413, "Payload Too Large"), on: conn)
            case .lengthRequired:
                self.cancelConnectionTimer(key)
                self.send(.status(411, "Length Required"), on: conn)
            case .badRequest:
                self.cancelConnectionTimer(key)
                self.send(.status(400, "Bad Request"), on: conn)
            case .complete(let req):
                self.cancelConnectionTimer(key)
                self.routeRequest(req, on: conn)
            }
        }
    }

    // MARK: - Routing

    /// The PURE routing decision. No AppKit, no socket, no mutation; unit-tested.
    enum RouteDecision: Equatable {
        case forbiddenHost      // 403 — Host-header / DNS-rebinding guard
        case throttled          // 429 — per-peer backoff (token mode only)
        case unauthorized       // 401 — token mismatch; bumps failure count
        case mcp                // POST /mcp — the JSON-RPC route
        case agentState         // POST /agent-state — Claude Code hook ingest
        case methodNotAllowed   // 405 — /mcp or /agent-state with a non-POST method
        case notFound           // 404 — any other path
    }

    /// Decide the route. PURE: no AppKit, no socket, no mutation.
    static func decideRoute(
        method: String,
        path: String,
        headers: [String: String],
        configuredHost: String,
        configuredPort: UInt16,
        token: String,
        peerFailureCount: Int
    ) -> RouteDecision {
        // DNS-rebinding defense: reject a present, non-empty Host that is neither
        // the configured host:port nor a loopback host on the configured port. A
        // missing/empty Host is allowed.
        if let host = headers["host"], !host.isEmpty,
           !hostHeaderAllowed(host, configuredHost: configuredHost, configuredPort: configuredPort) {
            return .forbiddenHost
        }

        // Token auth is OPTIONAL. When mcp-token is EMPTY the server is OPEN.
        // When set it gates every request via the X-Ghostty-Token header ONLY (no
        // bootstrap `?token=` path — every MCP request can send a header), with
        // the per-peer brute-force backoff.
        if !token.isEmpty {
            if peerFailureCount >= failedAuthThreshold { return .throttled }
            let headerToken = headers["x-ghostty-token"] ?? ""
            guard tokensMatch(headerToken, token) else { return .unauthorized }
        }

        if path == "/mcp" {
            return method == "POST" ? .mcp : .methodNotAllowed
        }
        if path == "/agent-state" {
            return method == "POST" ? .agentState : .methodNotAllowed
        }
        return .notFound
    }

    /// Thin shell: compute the pure `RouteDecision`, then perform the matching
    /// side effects (failure-count mutation, the `/mcp` JSON-RPC handoff, `send`).
    /// This is the ONLY place that touches the socket / backoff.
    private func routeRequest(_ req: RequestParser.Request, on conn: NWConnection) {
        let peer = Self.remoteIP(of: conn)
        // Only throttle a CONCRETE peer IP (the unresolved key is a shared bucket
        // and must never 429 an unrelated peer).
        let throttleCount = (peer == Self.unresolvedPeerKey) ? 0 : failedAuthCount(peer)

        let decision = Self.decideRoute(
            method: req.method,
            path: req.path,
            headers: req.headers,
            configuredHost: parsed?.host ?? "",
            configuredPort: parsed?.port ?? 0,
            token: token,
            peerFailureCount: throttleCount)

        switch decision {
        case .forbiddenHost:
            logger.debug("mcp: rejecting Host header \(req.headers["host"] ?? "", privacy: .public)")
            send(.status(403, "Forbidden"), on: conn)

        case .throttled:
            logger.debug("mcp: throttling peer \(peer, privacy: .public) after repeated auth failures")
            send(.status(429, "Too Many Requests"), on: conn)

        case .unauthorized:
            recordAuthFailure(peer)
            send(.status(401, "Unauthorized"), on: conn)

        case .methodNotAllowed:
            clearAuthFailures(peer)
            send(.status(405, "Method Not Allowed"), on: conn)

        case .notFound:
            clearAuthFailures(peer)
            send(.status(404, "Not Found"), on: conn)

        case .mcp:
            clearAuthFailures(peer)
            handleRPC(req.body, on: conn)

        case .agentState:
            clearAuthFailures(peer)
            handleAgentState(req.body, on: conn)
        }
    }

    // MARK: - Agent-state hook ingest (POST /agent-state)

    /// Handle a Claude Code hook POST. NOT pure (touches the socket via `send` and
    /// hops to main for the surface walk), so it stays out of `MCPAgentState.swift`.
    /// Parses the body, resolves the hook's tty -> a live surface UUID on MAIN
    /// (reading `SurfaceView.foregroundPID`, the same host-pushed minor-4 pid the
    /// Agent Dashboard consumes), and posts `.ghosttyAgentStateDidChange` so the
    /// dashboard model can update the per-tile agent state.
    private func handleAgentState(_ body: Data, on conn: NWConnection) {
        guard let payload = MCPAgentState.parse(body) else {
            send(.status(400, "Bad Request"), on: conn); return
        }
        // Resolve tty -> UUID on MAIN (reads SurfaceView.foregroundPID, main-only),
        // returning ONLY value types across the hop (the WebMonitor/MCP rule). The
        // (uuid, pid) snapshot shape matches the Agent Dashboard's detectorSnapshot.
        let surfaces: [(uuid: UUID, pid: pid_t)] = DispatchQueue.main.sync {
            var out: [(uuid: UUID, pid: pid_t)] = []
            for c in TerminalController.all {
                for view in c.surfaceTree {
                    if let pid = view.surfaceModel?.foregroundPID, pid > 0 {
                        out.append((view.id, pid_t(pid)))
                    }
                }
            }
            return out
        }
        guard let uuid = MCPAgentState.resolveSurface(forTTY: payload.tty, surfaces: surfaces) else {
            // 200, not 404: the hook is fire-and-forget and a momentary no-match
            // (surface just closed, pid not yet pushed) is not an error.
            send(.empty(200, "OK"), on: conn); return
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .ghosttyAgentStateDidChange, object: nil,
                userInfo: [AgentStateUserInfoKey.surfaceID: uuid,
                           AgentStateUserInfoKey.payload: payload])
        }
        send(.empty(202, "Accepted"), on: conn)
    }

    // MARK: - Token strength (startup gate)

    /// Minimum acceptable token length. PURE + testable; consulted only by `start()`.
    static let minTokenLength = 16

    static func tokenAcceptable(_ t: String) -> Bool {
        t.count >= minTokenLength
    }

    // MARK: - Token comparison (constant-time, length-checked)

    func tokensMatch(_ a: String, _ b: String) -> Bool {
        Self.tokensMatch(a, b)
    }

    static func tokensMatch(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }

    // MARK: - DNS-rebinding Host-header guard (pure, testable)

    /// Accept a Host header only when it names the configured host (or a loopback
    /// host) on the configured port. PURE + testable.
    static func hostHeaderAllowed(_ host: String, configuredHost: String, configuredPort: UInt16) -> Bool {
        var h = host
        var portStr: String? = nil
        if host.hasPrefix("[") {
            if let close = host.firstIndex(of: "]") {
                h = String(host[host.index(after: host.startIndex)..<close])
                let rest = host[host.index(after: close)...]
                if rest.hasPrefix(":") { portStr = String(rest.dropFirst()) }
            }
        } else if let colon = host.lastIndex(of: ":") {
            h = String(host[host.startIndex..<colon])
            portStr = String(host[host.index(after: colon)...])
        }
        let port = portStr.flatMap { UInt16($0) } ?? 80
        guard port == configuredPort else { return false }
        let lower = h.lowercased()
        let loopback = (lower == "localhost" || lower == "127.0.0.1" || lower == "::1")
        return lower == configuredHost.lowercased() || loopback
    }

    // MARK: - HTTP request parsing (pure, testable — no NWConnection)

    /// A connection-free HTTP/1.1 request parser. Copied from the web monitor.
    enum RequestParser {
        struct Request {
            let method: String
            let path: String
            let query: [String: String]
            let headers: [String: String]
            let body: Data
        }

        enum Result {
            case needMore
            case tooLarge
            case lengthRequired   // -> 411 (chunked / TE we do not handle)
            case badRequest       // -> 400
            case complete(Request)
        }

        static func parse(_ buffer: Data, maxRequestBytes: Int) -> Result {
            if buffer.count > maxRequestBytes { return .tooLarge }

            let crlfcrlf = Data([0x0d, 0x0a, 0x0d, 0x0a])
            guard let headerEnd = buffer.range(of: crlfcrlf) else {
                if buffer.count >= maxRequestBytes { return .tooLarge }
                return .needMore
            }

            let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
            guard let headerText = String(data: headerData, encoding: .utf8) else {
                return .badRequest
            }

            let lines = headerText.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else { return .badRequest }

            let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2 else { return .badRequest }
            let method = String(parts[0])
            let target = String(parts[1])
            guard !method.isEmpty, !target.isEmpty else { return .badRequest }

            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let idx = line.firstIndex(of: ":") else { continue }
                let name = line[line.startIndex..<idx].trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
                if name == "content-length", let existing = headers[name], existing != value {
                    return .badRequest
                }
                headers[name] = value
            }

            if let te = headers["transfer-encoding"], !te.isEmpty {
                return .lengthRequired
            }

            let contentLength: Int
            if let clStr = headers["content-length"], !clStr.isEmpty {
                guard let cl = Int(clStr), cl >= 0, cl <= maxRequestBytes else {
                    return .badRequest
                }
                contentLength = cl
            } else {
                contentLength = 0
            }

            let bodyStart = headerEnd.upperBound
            let bodyHave = buffer.distance(from: bodyStart, to: buffer.endIndex)
            if bodyHave < contentLength { return .needMore }

            let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
            let body = buffer.subdata(in: bodyStart..<bodyEnd)

            let path: String
            var query: [String: String] = [:]
            if let qIdx = target.firstIndex(of: "?") {
                path = String(target[target.startIndex..<qIdx])
                let qs = String(target[target.index(after: qIdx)...])
                for pair in qs.split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                    let v = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
                    query[k] = v
                }
            } else {
                path = target
            }

            return .complete(Request(
                method: method, path: path, query: query, headers: headers, body: body))
        }
    }

    // MARK: - HTTP response

    enum HTTPResponse {
        case html(String)
        case text(String)
        case json(Data)
        case asset(Data, String)
        case status(Int, String)
        /// Status line only, body = Data() (Content-Length: 0). Used for JSON-RPC
        /// notifications, which MUST produce NO response payload — so the stdio
        /// shim never sees a stray non-JSON line on stdout.
        case empty(Int, String)

        var statusCode: Int {
            switch self {
            case .html, .text, .json, .asset: return 200
            case .status(let c, _): return c
            case .empty(let c, _): return c
            }
        }
        var reason: String {
            switch self {
            case .html, .text, .json, .asset: return "OK"
            case .status(_, let r): return r
            case .empty(_, let r): return r
            }
        }
        var contentType: String {
            switch self {
            case .html: return "text/html; charset=utf-8"
            case .text: return "text/plain; charset=utf-8"
            case .json: return "application/json"
            case .asset(_, let ct): return ct
            case .status: return "text/plain; charset=utf-8"
            case .empty: return "text/plain; charset=utf-8"
            }
        }
        var body: Data {
            switch self {
            case .html(let s): return Data(s.utf8)
            case .text(let s): return Data(s.utf8)
            case .json(let d): return d
            case .asset(let d, _): return d
            case .status(let c, let r): return Data("\(c) \(r)".utf8)
            case .empty: return Data()
            }
        }
    }

    /// Write a one-shot Content-Length response and cancel the connection on
    /// completion. `internal` (not private) so the event bus can resolve a parked
    /// wait_for_event connection from `MCPEventBus`.
    func send(_ response: HTTPResponse, on conn: NWConnection) {
        cancelConnectionTimer(ObjectIdentifier(conn))
        let body = response.body
        var head = "HTTP/1.1 \(response.statusCode) \(response.reason)\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}

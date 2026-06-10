// (ramon fork) Web monitor: a GUI-embedded HTTP server that serves both an
// embedded mobile HTML page AND a small JSON API on ONE port, from inside the
// running macOS app. Lets you list live terminal surfaces, watch a chosen
// surface update, and send input (notably approving CLI-agent prompts) from a
// phone over Tailscale. Fork-only, OFF by default, token-gated.
//
// SECURITY MODEL (no TLS — WireGuard/the tailnet already encrypts transport):
// the only authentication is the shared `web-monitor-token`. Every request must
// present it. The query form (`?token=...`) is accepted ONLY on the BOOTSTRAP
// routes — `GET /` (the page) AND the vendored static assets `GET /xterm.js` /
// `GET /xterm.css` — because a browser reaches those from a plain link or a
// `<script>`/`<link>` tag, neither of which can set the X-Ghostty-Token header.
// Every OTHER (non-bootstrap) route REQUIRES the header and ignores any query
// token. The assets are public, non-secret static files, so accepting the query
// token on them leaks nothing beyond what the page URL already carries. That
// token is
// LOAD-BEARING: a holder can read live terminal output AND inject input into a
// live shell (e.g. approve a CLI-agent prompt), so it must be treated as a
// shell-execution credential. Defense in depth here is: (a) the tailnet ACL —
// only devices on your tailnet can reach the bound port; (b) a Host-header
// allowlist to blunt DNS-rebinding (a browser tricked into pointing at this
// port via an attacker hostname will send a Host we reject) — this is a
// DNS-rebinding guard ONLY, NOT an authentication boundary: a request with no
// Host header is still subject to the token gate (the token, not the Host
// check, is what authenticates); (c) a per-peer failed-token backoff so brute
// force is not free — it counts CONSECUTIVE wrong-token failures and is
// cleared on a token-valid request. If the token leaks, ROTATE
// it (and relaunch). Live updates are POLL-based; server-push (SSE/WebSocket)
// is a possible future option, intentionally out of scope for v1.
//
// Zero new SPM dependencies: Foundation + Network.framework + AppKit only.

import Foundation
import Network
import AppKit
import UserNotifications
import GhosttyKit
import os

final class WebMonitorServer {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "web-monitor")

    // INVARIANT (correctness-critical): this is a DEDICATED, private, SERIAL
    // background queue. It is NEVER DispatchQueue.main. The listener
    // (listener.start(queue:)), every connection (conn.start(queue:)), and
    // every receive/send callback run on this queue. Because of that, the
    // `DispatchQueue.main.sync { ... }` hops used by the API handlers (to touch
    // AppKit / SurfaceView / ghostty_surface_*) can NEVER deadlock — we are
    // never already on main when we sync onto main.
    private let queue = DispatchQueue(label: "com.mitchellh.ghostty-ramon.webmonitor")

    private let listenSpec: String
    private let token: String

    /// The parsed host:port. The host is used ONLY for the Host-header
    /// allowlist (DNS-rebinding defense), never as an IP allowlist.
    private let parsed: (host: String, port: UInt16)?

    private var listener: NWListener?
    private var connectionRefs: [ObjectIdentifier: NWConnection] = [:]
    /// Per-connection idle/read watchdog timers (slowloris defense; also bounds
    /// `connectionRefs` growth). Mutated only on `queue`.
    private var connectionTimers: [ObjectIdentifier: DispatchSourceTimer] = [:]
    private static let connectionIdleTimeout: TimeInterval = 10

    /// Per-connection ABSOLUTE deadline timers. Unlike the idle watchdog these
    /// are armed exactly ONCE in `handle()` and never rearmed, so a slowloris /
    /// trickle peer that keeps making just-enough progress to reset the idle
    /// timer still gets hard-killed at this ceiling. Mutated only on `queue`.
    private var connectionDeadlineTimers: [ObjectIdentifier: DispatchSourceTimer] = [:]
    private static let connectionAbsoluteDeadline: TimeInterval = 15

    /// Hard cap on concurrently-tracked connections. Beyond this, new
    /// connections are rejected in `handle()` so a flood cannot grow
    /// `connectionRefs` (and its timers) without bound. Mutated only on `queue`.
    private static let maxConcurrentConnections = 32

    /// Live raw-output stream backends, one per `/stream` connection. The host
    /// client pipes a session's raw PTY bytes back onto the NWConnection. Keyed
    /// by connection identity so the connection's `.cancelled/.failed` state
    /// handler can tear the client down (and the client's `onClose` cancels the
    /// connection). Mutated only on `queue`. This is a LONG-LIVED connection, so
    /// it is exempted from the idle/absolute watchdogs (see `routeStream`).
    private var streamClients: [ObjectIdentifier: WebMonitorHostClient] = [:]

    /// Connections currently in STREAMING mode (a `/stream` response: HTTP head
    /// already written, raw byte chunks flowing). A streaming connection is
    /// long-lived and is EXEMPT from the idle/absolute watchdogs (cancelled in
    /// `routeStream`); it is also NOT routed through the one-shot `send()`
    /// (which writes a Content-Length body and cancels on completion). Tracked
    /// so teardown is idempotent and the set can be cleaned up alongside
    /// `streamClients`. Mutated only on `queue`.
    private var streamingConns: Set<ObjectIdentifier> = []

    /// Per-peer failed-token counter (keyed by remote IP string). Cheap brute
    /// force speed bump; resets on a successful auth. Mutated only on `queue`.
    /// Each entry carries the count plus the last-failure time so the lockout
    /// DECAYS (a peer that pauses past the window starts fresh) rather than
    /// being a permanent per-IP lockout until process restart. The dict is also
    /// capped so a spray of distinct source IPs cannot grow it unbounded.
    private var failedAuth: [String: (count: Int, last: Date)] = [:]
    static let failedAuthThreshold = 5
    private static let failedAuthWindow: TimeInterval = 60   // reset after 60s idle
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
        // Opportunistically drop stale entries if we are at the cap so a spray
        // of distinct IPs cannot grow the dict without bound.
        if failedAuth.count >= Self.failedAuthMaxEntries {
            let cutoff = Date().addingTimeInterval(-Self.failedAuthWindow)
            failedAuth = failedAuth.filter { $0.value.last > cutoff }
            // If a spray of fresh distinct IPs within the window pruned nothing,
            // the dict can still be at/over the cap. Drop the oldest entry
            // (smallest `.last`) so the size stays strictly bounded.
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

    init(listen: String, token: String) {
        self.listenSpec = listen
        self.token = token
        self.parsed = Self.parseListen(listen)
    }

    // MARK: - Lifecycle

    func start() {
        // Token-strength gate at startup: never accidentally open with a weak
        // (empty/short) token. The token is a shell-execution credential, so a
        // guessable one is as dangerous as none — require a real, long random
        // token before binding the port.
        guard Self.tokenAcceptable(token) else {
            logger.warning("web-monitor: refusing to start — web-monitor-token is empty or too weak (need >= \(Self.minTokenLength, privacy: .public) chars)")
            Self.notify(
                title: "Web monitor not started",
                body: "web-monitor-token is empty or too short; use a long (\(Self.minTokenLength)+ char) random token.")
            return
        }

        guard let parsed else {
            logger.error("web-monitor: invalid listen address: \(self.listenSpec, privacy: .public)")
            Self.notify(
                title: "Web monitor not started",
                body: "Invalid web-monitor-listen address: \(self.listenSpec)")
            return
        }
        guard let nwPort = NWEndpoint.Port(rawValue: parsed.port) else {
            logger.error("web-monitor: invalid listen port: \(self.listenSpec, privacy: .public)")
            return
        }

        // NWListener cannot cleanly bind a single arbitrary non-localhost IP
        // without extra machinery, so we bind the PORT on all interfaces. The
        // TOKEN (plus the tailnet ACL + Host-header allowlist) is the security
        // boundary; the bind address is NOT an allowlist. Documented in CLAUDE.md.
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        do {
            let l = try NWListener(using: params, on: nwPort)
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            l.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.logger.info("web-monitor: ready on port \(parsed.port, privacy: .public)")
                case .failed(let err):
                    self.logger.error("web-monitor: listener failed: \(String(describing: err), privacy: .public)")
                    if !self.didFailToBind {
                        self.didFailToBind = true
                        Self.notify(
                            title: "Web monitor failed to bind",
                            body: "Port \(parsed.port): \(String(describing: err)). Is it in use?")
                    }
                case .cancelled:
                    self.logger.info("web-monitor: listener cancelled")
                default:
                    break
                }
            }
            self.listener = l
            l.start(queue: queue)
        } catch {
            logger.error("web-monitor: failed to create listener: \(String(describing: error), privacy: .public)")
            Self.notify(
                title: "Web monitor failed to start",
                body: String(describing: error))
        }
    }

    func stop() {
        // Teardown is invoked from applicationWillTerminate on the MAIN thread,
        // but `connectionRefs` is otherwise mutated only on the dedicated serial
        // `queue` (handle / stateUpdateHandler). Hop onto that queue so ALL
        // access to the connection bookkeeping stays serialized — but do it
        // ASYNC, never sync: handlers running on `queue` themselves hop to main
        // via DispatchQueue.main.sync, so a `queue.sync` from main here would be
        // a lock-order inversion that can hang termination. NWListener /
        // NWConnection .cancel() are thread-safe, so async teardown is fine.
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            for (_, timer) in self.connectionTimers { timer.cancel() }
            self.connectionTimers.removeAll()
            for (_, timer) in self.connectionDeadlineTimers { timer.cancel() }
            self.connectionDeadlineTimers.removeAll()
            for (_, client) in self.streamClients { client.stop() }
            self.streamClients.removeAll()
            self.streamingConns.removeAll()
            for (_, conn) in self.connectionRefs { conn.cancel() }
            self.connectionRefs.removeAll()
        }
    }

    /// Post a one-time user-visible notification. Best-effort; the message is
    /// also always in the log (Console.app subsystem = bundle id, category =
    /// "web-monitor"). Uses the modern UserNotifications framework like the rest
    /// of the app (AppDelegate already configures + authorizes it).
    private static func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(
            identifier: "web-monitor-" + UUID().uuidString,
            content: content,
            trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    // MARK: - listen parsing (pure, testable)

    /// Parse a `host:port` listen spec into its parts. Splits on the LAST ':'
    /// so bracketed IPv6 (`[::1]:8787`) and hostnames are tolerated; strips the
    /// surrounding brackets from a bracketed IPv6 host. Returns nil on a missing
    /// host, a missing/non-numeric/out-of-range port.
    static func parseListen(_ spec: String) -> (host: String, port: UInt16)? {
        guard let colonIdx = spec.lastIndex(of: ":") else { return nil }
        var host = String(spec[spec.startIndex..<colonIdx])
        let portPart = String(spec[spec.index(after: colonIdx)...])
        // Strip [..] around an IPv6 literal.
        if host.hasPrefix("[") && host.hasSuffix("]") && host.count >= 2 {
            host = String(host.dropFirst().dropLast())
        }
        guard !host.isEmpty else { return nil }
        guard let port = UInt16(portPart) else { return nil }
        return (host, port)
    }

    // MARK: - Connection handling (background queue)

    private func handle(_ conn: NWConnection) {
        // Concurrent-connection cap: this runs on the serial `queue` (the
        // listener was started with `queue`), so reading `connectionRefs.count`
        // here is race-free. Reject (cancel) the new connection if we are at the
        // ceiling so a flood cannot grow the bookkeeping (and its timers)
        // without bound.
        if connectionRefs.count >= Self.maxConcurrentConnections {
            logger.notice("web-monitor: connection cap (\(Self.maxConcurrentConnections, privacy: .public)) reached, rejecting connection")
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
                // Tear down any /stream backend bound to this connection so a
                // disconnected peer stops the host-client read loop (and frees
                // its socket). Runs on `queue` (NWConnection state callbacks use
                // the start(queue:) queue), so this dict access is race-free.
                if let client = self?.streamClients.removeValue(forKey: key) {
                    client.stop()
                }
                self?.streamingConns.remove(key)
            default:
                break
            }
        }
        // Slowloris / idle-socket defense: one-shot watchdog that cancels the
        // connection if a full request does not arrive in time. Cancelled when
        // the request completes (in `routeRequest`'s `send`, via the state
        // handler above) or rearmed on each receive below.
        armConnectionTimer(key, conn: conn)
        // Absolute deadline: armed ONCE here and never rearmed, so it is the
        // hard ceiling on total connection lifetime regardless of how much
        // incremental progress a trickle peer makes (which keeps resetting the
        // idle watchdog above).
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
            self?.logger.debug("web-monitor: connection idle timeout, cancelling")
            self?.cancelConnectionTimer(key)
            conn.cancel()
        }
        connectionTimers[key] = timer
        timer.resume()
    }

    /// Arm the one-shot ABSOLUTE deadline for a connection. Runs on `queue`.
    /// Never rearmed — this is the hard ceiling on total connection lifetime.
    private func armConnectionDeadline(_ key: ObjectIdentifier, conn: NWConnection) {
        connectionDeadlineTimers[key]?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.connectionAbsoluteDeadline)
        timer.setEventHandler { [weak self] in
            self?.logger.debug("web-monitor: connection absolute deadline, cancelling")
            self?.cancelConnectionTimer(key)
            conn.cancel()
        }
        connectionDeadlineTimers[key] = timer
        timer.resume()
    }

    /// Cancel and drop BOTH the idle watchdog and the absolute-deadline timer
    /// for a connection. Runs on `queue`.
    private func cancelConnectionTimer(_ key: ObjectIdentifier) {
        connectionTimers[key]?.cancel()
        connectionTimers[key] = nil
        connectionDeadlineTimers[key]?.cancel()
        connectionDeadlineTimers[key] = nil
    }

    /// Sentinel peer key used when no concrete remote IP could be resolved.
    /// Many distinct peers can collapse onto this single key, so it must NEVER
    /// drive throttling (see `routeRequest`) — only a concrete IP may.
    static let unresolvedPeerKey = "?"

    /// Best-effort remote IP string for the per-peer backoff key. Returns
    /// `unresolvedPeerKey` when no concrete IP/host could be read off the
    /// connection (the caller must treat that key as non-throttleable).
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
                self.logger.debug("web-monitor: receive error: \(String(describing: error), privacy: .public)")
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
                    // Rearm the idle watchdog: progress was made, but the request
                    // is still incomplete — keep the slowloris ceiling per read.
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
                // Full request received; disarm the read watchdog before we do
                // the (possibly main-thread) routing + response.
                self.cancelConnectionTimer(key)
                self.routeRequest(req, on: conn)
            }
        }
    }

    // MARK: - Routing

    /// The PURE routing decision: given the request shape (method, path, query,
    /// headers) plus the configured host/port/token and the peer's current
    /// failure count, decide WHAT to do — without touching AppKit or the socket.
    /// `routeRequest` (below) is a thin shell that maps a `RouteDecision` onto
    /// the side-effecting work (main-thread AppKit hops, `send`, failure-count
    /// mutation). Keeping the decision pure makes the security-load-bearing
    /// router (Host allowlist, token gate, per-peer backoff, method/path table)
    /// unit-testable end to end.
    enum RouteDecision: Equatable {
        case forbiddenHost                       // 403 (DNS-rebinding defense)
        case throttled                           // 429 (per-peer backoff tripped)
        case unauthorized                        // 401 (token mismatch); bumps failure count
        case page                                // 200 GET / (embedded HTML)
        case surfacesList                        // GET /api/surfaces
        case methodNotAllowed                    // 405
        case notFound                            // 404
        case screen(uuid: UUID, scrollback: Bool) // GET /api/surface/{uuid}/screen
        case stream(uuid: UUID)                  // GET /api/surface/{uuid}/stream (raw byte stream)
        case input(uuid: UUID)                   // POST /api/surface/{uuid}/input
        case asset(name: String, ext: String, contentType: String) // GET /xterm.js|/xterm.css
    }

    /// The static asset routes (vendored xterm.js / xterm.css), served from the
    /// app bundle. Keyed by request path -> (resource name, extension, MIME).
    /// These are bootstrap routes (see `isBootstrapPath`): like `GET /`, they
    /// accept the token via `?token=` because a `<script src>` / `<link href>`
    /// tag cannot set the X-Ghostty-Token header.
    static let assetRoutes: [String: (name: String, ext: String, contentType: String)] = [
        "/xterm.js": ("xterm", "js", "application/javascript; charset=utf-8"),
        "/xterm.css": ("xterm", "css", "text/css; charset=utf-8"),
    ]

    /// Paths that accept the token via the `?token=` query string (not just the
    /// X-Ghostty-Token header). This is the SET of routes a browser can reach
    /// from a plain link or an HTML tag that cannot send a custom header: the
    /// `GET /` bootstrap page AND the `<script>`/`<link>` asset routes it pulls
    /// in. SECURITY: every OTHER (non-bootstrap) route still REQUIRES the header
    /// and ignores any query token (see the token gate in `decideRoute`). The
    /// assets are public, non-secret static files, so accepting the query token
    /// on them leaks nothing beyond what the page URL already carries.
    static func isBootstrapPath(_ path: String) -> Bool {
        path == "/" || assetRoutes[path] != nil
    }

    /// Decide the route. PURE: no AppKit, no socket, no mutation.
    static func decideRoute(
        method: String,
        path: String,
        query: [String: String],
        headers: [String: String],
        configuredHost: String,
        configuredPort: UInt16,
        token: String,
        peerFailureCount: Int
    ) -> RouteDecision {
        // DNS-rebinding defense: reject Host values that are not the configured
        // host:port or a loopback host on the configured port. A bare missing
        // (or empty) Host (HTTP/1.0-style) is allowed; browsers always send one.
        if let host = headers["host"], !host.isEmpty,
           !hostHeaderAllowed(host, configuredHost: configuredHost, configuredPort: configuredPort) {
            return .forbiddenHost
        }

        // Per-peer failed-token backoff (cheap brute-force speed bump).
        if peerFailureCount >= failedAuthThreshold { return .throttled }

        // Token check — gates EVERY request (including GET / and the asset
        // routes). The query token (`?token=`) is accepted ONLY for the
        // BOOTSTRAP paths (GET / and the <script>/<link> asset routes, which
        // cannot send a custom header) so the page + its assets load from a
        // plain link; every /api/* route requires the token via the
        // X-Ghostty-Token header and IGNORES any query token.
        let headerToken = headers["x-ghostty-token"] ?? ""
        let presented = isBootstrapPath(path) ? (query["token"] ?? headerToken) : headerToken
        guard tokensMatch(presented, token) else { return .unauthorized }

        // Route on (method, path).
        if path == "/" {
            return method == "GET" ? .page : .methodNotAllowed
        }
        if let asset = assetRoutes[path] {
            return method == "GET"
                ? .asset(name: asset.name, ext: asset.ext, contentType: asset.contentType)
                : .methodNotAllowed
        }
        if path == "/api/surfaces" {
            return method == "GET" ? .surfacesList : .methodNotAllowed
        }

        // /api/surface/{uuid}/{action}
        let comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if comps.count == 4, comps[0] == "api", comps[1] == "surface" {
            guard let uuid = UUID(uuidString: comps[2]) else { return .notFound }
            switch comps[3] {
            case "screen":
                guard method == "GET" else { return .methodNotAllowed }
                return .screen(uuid: uuid, scrollback: (query["mode"] ?? "viewport") == "scrollback")
            case "stream":
                // Long-lived raw-byte stream (xterm.js source). Header-token only,
                // like every other /api/* route (it is NOT a bootstrap path).
                guard method == "GET" else { return .methodNotAllowed }
                return .stream(uuid: uuid)
            case "input":
                guard method == "POST" else { return .methodNotAllowed }
                return .input(uuid: uuid)
            default:
                return .notFound
            }
        }

        return .notFound
    }

    /// Thin shell: compute the pure `RouteDecision`, then perform the matching
    /// side effects (failure-count mutation, main-thread AppKit hops, `send`).
    private func routeRequest(_ req: RequestParser.Request, on conn: NWConnection) {
        let peer = Self.remoteIP(of: conn)

        // Only throttle when a CONCRETE peer IP was resolved. The best-effort
        // key falls back to `unresolvedPeerKey` (a single shared bucket), so
        // unrelated peers can collide on it; feeding its count into the throttle
        // could 429 a legitimate, never-failed peer (an availability foot-gun
        // for the approval use case). For the unresolved key we pass a 0 count
        // so decideRoute never reaches `.throttled`. A peer that has CLEARED its
        // auth within the window is also non-throttleable here for free: a
        // success calls `clearAuthFailures`, dropping its entry, so
        // `failedAuthCount` is already 0 for it. The decideRoute contract (count
        // >= threshold ⇒ throttled) is unchanged; we only gate WHICH count flows
        // in. Recording of failures (below) still uses the real key.
        let throttleCount = (peer == Self.unresolvedPeerKey) ? 0 : failedAuthCount(peer)

        let decision = Self.decideRoute(
            method: req.method,
            path: req.path,
            query: req.query,
            headers: req.headers,
            configuredHost: parsed?.host ?? "",
            configuredPort: parsed?.port ?? 0,
            token: token,
            peerFailureCount: throttleCount)

        switch decision {
        case .forbiddenHost:
            logger.debug("web-monitor: rejecting Host header \(req.headers["host"] ?? "", privacy: .public)")
            send(.status(403, "Forbidden"), on: conn)

        case .throttled:
            logger.debug("web-monitor: throttling peer \(peer, privacy: .public) after repeated auth failures")
            send(.status(429, "Too Many Requests"), on: conn)

        case .unauthorized:
            recordAuthFailure(peer)
            send(.status(401, "Unauthorized"), on: conn)

        case .page:
            clearAuthFailures(peer)
            send(.html(Self.htmlPage), on: conn)

        case .surfacesList:
            clearAuthFailures(peer)
            let json: Data = DispatchQueue.main.sync { self.surfacesJSON() }
            send(.json(json), on: conn)

        case .methodNotAllowed:
            clearAuthFailures(peer)
            send(.status(405, "Method Not Allowed"), on: conn)

        case .notFound:
            clearAuthFailures(peer)
            send(.status(404, "Not Found"), on: conn)

        case .screen(let uuid, let scrollback):
            clearAuthFailures(peer)
            let result: HTTPResponse = DispatchQueue.main.sync {
                guard let view = self.surface(forUUID: uuid) else { return .status(404, "Not Found") }
                // Reuse the cached readers (~500ms TTL; they free their own
                // text inside the cache closure). Value out only.
                let text = scrollback
                    ? view.cachedScreenContents.get()
                    : view.cachedVisibleContents.get()
                return .text(text)
            }
            send(result, on: conn)

        case .stream(let uuid):
            clearAuthFailures(peer)
            routeStream(uuid: uuid, on: conn)

        case .input(let uuid):
            clearAuthFailures(peer)
            let contentType = req.headers["content-type"] ?? ""
            // Decode the request into an ordered list of KEY EVENT specs. We
            // send REAL key events (ghostty_surface_key), NOT pasted text
            // (ghostty_surface_text) — pasting routes through the clipboard
            // path, so "\n" lands as a literal newline (never submits) and
            // control bytes / arrows are not real keypresses; newline-bearing
            // pastes also trip Mac paste-protection (a dialog invisible to the
            // phone). A pure mapping turns the request into specs; the
            // main-thread sender below replays them as presses on the surface.
            guard let specs = Self.keySpecs(body: req.body, contentType: contentType) else {
                send(.status(400, "Bad Request"), on: conn)
                return
            }
            // Empty decoded input is a no-op; report it as a 400 so the
            // client knows nothing landed (S2).
            guard !specs.isEmpty else {
                send(.status(400, "Bad Request"), on: conn)
                return
            }
            let result: HTTPResponse = DispatchQueue.main.sync {
                guard let view = self.surface(forUUID: uuid),
                      let surface = view.surface else { return .status(404, "Not Found") }
                // Build a ghostty_input_key_s per spec and replay it as a real
                // key event. Mirror the macOS keyDown path: send a PRESS then a
                // RELEASE for each spec. Only value types crossed the main-thread
                // hop; the surface pointer is fetched and used entirely on main.
                for spec in specs {
                    spec.send(to: surface)
                }
                return .json(Data(#"{"ok":true,"sent":\#(specs.count)}"#.utf8))
            }
            send(result, on: conn)

        case .asset(let name, let ext, let contentType):
            clearAuthFailures(peer)
            // Vendored static file (xterm.js / xterm.css) read from the app
            // bundle. Pure file IO — no AppKit / surface access — so it stays
            // on the connection `queue` (no main-thread hop). A missing
            // resource (e.g. a build that did not bundle the vendor files) is a
            // 404 rather than a crash.
            send(Self.assetResponse(name: name, ext: ext, contentType: contentType), on: conn)
        }
    }

    // MARK: - Streaming /stream route (raw PTY byte stream for xterm.js)

    /// The HTTP response head for a streaming `/stream` response: a 200 with an
    /// unbounded `application/octet-stream` body (NO Content-Length — the body
    /// runs until the connection closes) and `Connection: close`. PURE +
    /// `internal` so the exact wire bytes are unit-testable. Followed by raw
    /// byte chunks written directly onto the connection as they arrive from the
    /// host client (see `routeStream`).
    static func streamResponseHead() -> Data {
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: application/octet-stream\r\n"
        // Defense in depth against an intermediary that might buffer/transform:
        // no caching, no MIME sniffing. (Over a tailnet there is normally no
        // proxy, but these are cheap and correct.)
        head += "Cache-Control: no-store, no-transform\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"
        return Data(head.utf8)
    }

    /// Resolve a surface UUID to its host session id + the configured pty-host
    /// socket path, then open a `WebMonitorHostClient` and pipe its raw PTY
    /// bytes onto `conn` as a streaming response. Falls back to 501 (so the
    /// page can degrade to the `/screen` poll) when no pty-host is configured,
    /// or 404 when the surface is gone / has no live session id.
    ///
    /// THREADING: the AppKit / `ghostty_surface_*` access (surface lookup,
    /// `ghostty_surface_session_id`, the config getter) happens inside a single
    /// `DispatchQueue.main.sync` that returns ONLY value types (a session id +
    /// the socket-path String) — never a surface pointer / SurfaceView across
    /// the hop. Everything after (the host client, the NWConnection writes) runs
    /// on the connection `queue`. The host client's `onBytes`/`onClose` fire on
    /// ITS own background queue; they only call thread-safe `NWConnection`
    /// methods, so no further hop is needed.
    private func routeStream(uuid: UUID, on conn: NWConnection) {
        let key = ObjectIdentifier(conn)

        // Resolve session id + socket path on main (value types only).
        struct Resolved { let sessionID: UInt64; let socketPath: String? }
        let resolved: Resolved? = DispatchQueue.main.sync {
            guard let view = self.surface(forUUID: uuid),
                  let surface = view.surface else { return nil }
            let sid = ghostty_surface_session_id(surface)
            let path = (NSApp.delegate as? AppDelegate)?.ghostty.config.ptyHost
            return Resolved(sessionID: sid, socketPath: path)
        }

        guard let resolved else {
            send(.status(404, "Not Found"), on: conn)
            return
        }
        // No pty-host configured -> the raw stream is unavailable. 501 so the
        // page falls back to the /screen viewport poll instead of hanging.
        guard let socketPath = resolved.socketPath, !socketPath.isEmpty else {
            send(.status(501, "Not Implemented"), on: conn)
            return
        }

        // Enter streaming mode: this connection is long-lived, so exempt it from
        // BOTH watchdogs (they would otherwise cancel it mid-stream), and mark it
        // so teardown stays idempotent. We deliberately do NOT route this through
        // `send()` (that path writes a Content-Length body + cancels on
        // completion); instead we write the head, then raw chunks, ourselves.
        cancelConnectionTimer(key)
        streamingConns.insert(key)

        // Write the streaming HTTP head. On failure the connection is already
        // gone; the state handler will clean up.
        conn.send(content: Self.streamResponseHead(), completion: .contentProcessed { _ in })

        // Open the host client and pipe raw bytes onto the connection. onBytes /
        // onClose fire on the client's own background queue; NWConnection.send /
        // .cancel are thread-safe, so we call them directly. We hop to `queue`
        // for the dict cleanup in onClose to keep `streamClients`/`streamingConns`
        // single-threaded.
        let client = WebMonitorHostClient(
            socketPath: socketPath,
            sessionID: resolved.sessionID,
            onBytes: { [weak conn] data in
                conn?.send(content: data, completion: .contentProcessed { err in
                    // A write error means the peer (phone) hung up; tear the
                    // connection down so the host client's read loop stops.
                    if err != nil { conn?.cancel() }
                })
            },
            onClose: { [weak self, weak conn] in
                // The source (host client) closed: end the HTTP response by
                // closing the connection. Drop our bookkeeping on `queue`.
                conn?.cancel()
                self?.queue.async {
                    self?.streamClients[key] = nil
                    self?.streamingConns.remove(key)
                }
            })
        streamClients[key] = client
        client.start()
    }

    /// Load a vendored static asset from the app bundle and wrap it in an
    /// `HTTPResponse`. Returns 404 if the resource is absent or unreadable.
    /// PURE w.r.t. the connection (no socket, no AppKit); `internal` so the
    /// missing-resource fallback can be unit-tested without a real bundle file.
    static func assetResponse(name: String, ext: String, contentType: String) -> HTTPResponse {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let data = try? Data(contentsOf: url) else {
            return .status(404, "Not Found")
        }
        return .asset(data, contentType)
    }

    /// DNS-rebinding defense: accept a Host header only when it names the
    /// configured host (or a loopback host) on the configured port. The default
    /// HTTP port (no `:port`) is treated as 80, so it is rejected unless we are
    /// actually bound to 80. PURE + `internal` so it is unit-testable on its own
    /// (it carries the bracketed-IPv6 split / default-port / loopback logic that
    /// is the named DNS-rebinding pillar in the SECURITY MODEL above).
    static func hostHeaderAllowed(_ host: String, configuredHost: String, configuredPort: UInt16) -> Bool {
        // Split host:port off the Host header (last ':' so IPv6 literals work).
        var h = host
        var portStr: String? = nil
        if host.hasPrefix("[") {
            // [ipv6]:port
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

    // MARK: - Key event specs (real keypresses, not paste)

    /// A single key event to replay on a surface. PURE/value-type so the
    /// request->events mapping is unit-testable without AppKit or a surface.
    /// Mirrors the field set the macOS keyDown path fills into a
    /// `ghostty_input_key_s`: a keycode (`ghostty_input_key_e`, 0 when unset for
    /// text-bearing events), modifiers, optional `text` (the UTF-8 the key
    /// produces — set for printable characters so the event encodes text exactly
    /// like a typed key), and the `unshiftedCodepoint` (the base-layout scalar).
    struct KeySpec: Equatable {
        var keycode: ghostty_input_key_e
        var mods: ghostty_input_mods_e
        var text: String?
        var unshiftedCodepoint: UInt32

        init(
            keycode: ghostty_input_key_e = ghostty_input_key_e(0),
            mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE,
            text: String? = nil,
            unshiftedCodepoint: UInt32 = 0
        ) {
            self.keycode = keycode
            self.mods = mods
            self.text = text
            self.unshiftedCodepoint = unshiftedCodepoint
        }

        /// Build a `ghostty_input_key_s` for this spec at the given action and
        /// hand it to `ghostty_surface_key`. MUST be called on the main thread
        /// (it touches the surface pointer). Text is only attached for a PRESS
        /// (a RELEASE carries no text), matching the keyDown path which only
        /// encodes UTF-8 when there is text and no single control char.
        func send(to surface: ghostty_surface_t) {
            // Press, then matching release — the same two-event shape AppKit's
            // keyDown/keyUp produces for a typed key.
            sendOne(action: GHOSTTY_ACTION_PRESS, to: surface)
            sendOne(action: GHOSTTY_ACTION_RELEASE, to: surface)
        }

        private func sendOne(action: ghostty_input_action_e, to surface: ghostty_surface_t) {
            var key_ev = ghostty_input_key_s()
            key_ev.action = action
            key_ev.keycode = UInt32(keycode.rawValue)
            key_ev.mods = mods
            key_ev.consumed_mods = GHOSTTY_MODS_NONE
            key_ev.unshifted_codepoint = unshiftedCodepoint
            key_ev.composing = false
            // Encode text only on PRESS, and only when it is not a single
            // control character (control chars are encoded by Ghostty itself,
            // matching SurfaceView.keyAction).
            if action == GHOSTTY_ACTION_PRESS,
               let text, text.count > 0,
               let codepoint = text.utf8.first, codepoint >= 0x20 {
                text.withCString { ptr in
                    key_ev.text = ptr
                    _ = ghostty_surface_key(surface, key_ev)
                }
            } else {
                key_ev.text = nil
                _ = ghostty_surface_key(surface, key_ev)
            }
        }
    }

    /// Decode a POST /input request into an ordered list of key-event specs.
    /// Keys ONLY off Content-Type (S11 — never sniffs a leading `{`): when it is
    /// `application/json` the body is parsed as `{"key":...}` and mapped via
    /// `keySpecs(forKey:)`; for any other (or missing) Content-Type the body is
    /// treated as raw UTF-8 text and mapped via `keySpecs(forText:)`. Returns nil
    /// on declared-JSON with a missing/unknown key, or on a body that is not
    /// valid UTF-8 text. An empty raw body decodes to an empty (non-nil) list;
    /// the route's `!specs.isEmpty` guard turns that into a 400.
    static func keySpecs(body: Data, contentType: String) -> [KeySpec]? {
        if contentType.lowercased().contains("application/json") {
            guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let key = obj["key"] as? String else { return nil }
            return keySpecs(forKey: key)
        }
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        return keySpecs(forText: text)
    }

    /// PURE: map a named key command to a single key-event spec. Unknown -> nil.
    /// Named keys carry a `ghostty_input_key_e` keycode (so Ghostty synthesizes
    /// the real keypress/escape sequence); `y`/`n` are just printable text.
    static func keySpecs(forKey key: String) -> [KeySpec]? {
        switch key {
        case "enter": return [KeySpec(keycode: GHOSTTY_KEY_ENTER)]
        case "esc": return [KeySpec(keycode: GHOSTTY_KEY_ESCAPE)]
        case "tab": return [KeySpec(keycode: GHOSTTY_KEY_TAB)]
        case "ctrl-c": return [KeySpec(keycode: GHOSTTY_KEY_C, mods: GHOSTTY_MODS_CTRL)]
        case "up": return [KeySpec(keycode: GHOSTTY_KEY_ARROW_UP)]
        case "down": return [KeySpec(keycode: GHOSTTY_KEY_ARROW_DOWN)]
        case "left": return [KeySpec(keycode: GHOSTTY_KEY_ARROW_LEFT)]
        case "right": return [KeySpec(keycode: GHOSTTY_KEY_ARROW_RIGHT)]
        case "y": return keySpecs(forText: "y")
        case "n": return keySpecs(forText: "n")
        default: return nil
        }
    }

    /// PURE: map literal text to one key-event spec per Character. Printable
    /// characters become a text-bearing spec (`text` = that character,
    /// `unshiftedCodepoint` = its first Unicode scalar, keycode unset) — a
    /// text-bearing event encodes its text exactly as the keyDown path does for
    /// typed characters. A newline (`\n` or `\r`) becomes a REAL Enter key event
    /// (`GHOSTTY_KEY_ENTER`), NOT a text-bearing control char: a text spec for a
    /// control codepoint (< 0x20) would carry no text and submit nothing, so the
    /// trailing "\n" the page appends on Send must map to Enter to actually
    /// submit (this is the core of the paste->key-event fix).
    static func keySpecs(forText text: String) -> [KeySpec] {
        text.map { ch in
            if ch == "\n" || ch == "\r" {
                return KeySpec(keycode: GHOSTTY_KEY_ENTER)
            }
            let scalar = ch.unicodeScalars.first?.value ?? 0
            return KeySpec(text: String(ch), unshiftedCodepoint: scalar)
        }
    }

    // MARK: - Main-thread helpers (AppKit / surface access)

    /// Replicates AppDelegate.findSurface(forUUID:). MUST be called on main.
    private func surface(forUUID uuid: UUID) -> Ghostty.SurfaceView? {
        for c in TerminalController.all {
            for view in c.surfaceTree where view.id == uuid {
                return view
            }
        }
        return nil
    }

    /// MUST be called on main. Iterates AppKit surfaces (thin) and defers the
    /// pure dict/JSON shaping to `surfacesJSONData` so the shaping is testable.
    private func surfacesJSON() -> Data {
        var rows: [(id: String, title: String, pwd: String)] = []
        for c in TerminalController.all {
            for view in c.surfaceTree {
                rows.append((view.id.uuidString, view.title, view.pwd ?? ""))
            }
        }
        return Self.surfacesJSONData(rows)
    }

    /// Pure JSON shaping for the surfaces list (testable; no AppKit).
    static func surfacesJSONData(_ rows: [(id: String, title: String, pwd: String)]) -> Data {
        let arr: [[String: String]] = rows.map { ["id": $0.id, "title": $0.title, "pwd": $0.pwd] }
        return (try? JSONSerialization.data(withJSONObject: arr)) ?? Data("[]".utf8)
    }

    // MARK: - Token strength (startup gate)

    /// Minimum acceptable token length. The token is the sole shell-execution
    /// credential, so anything short is brute-forceable; require a real random
    /// secret. PURE + testable; consulted only by `start()`.
    static let minTokenLength = 16

    /// Whether a configured token is strong enough to bind the port. Rejects an
    /// empty or too-short token (the only auth on a shell-execution credential).
    /// Length is counted in Unicode characters, which for the random ASCII
    /// tokens we expect equals the byte count.
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

    // MARK: - HTTP request parsing (pure, testable — no NWConnection)

    /// A connection-free HTTP/1.1 request parser. `parse` is fed the bytes
    /// accumulated so far and returns whether more is needed, the request is too
    /// large, malformed, or a complete parsed request. Keeping this pure makes
    /// the security-critical Content-Length / chunked / header logic unit-testable.
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
            // Hard ceiling: a buffer over the cap is rejected, never grown.
            if buffer.count > maxRequestBytes { return .tooLarge }

            let crlfcrlf = Data([0x0d, 0x0a, 0x0d, 0x0a])
            guard let headerEnd = buffer.range(of: crlfcrlf) else {
                // No header terminator yet. If we are already at the cap there is
                // no room for one — reject rather than spin.
                if buffer.count >= maxRequestBytes { return .tooLarge }
                return .needMore
            }

            let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
            guard let headerText = String(data: headerData, encoding: .utf8) else {
                return .badRequest
            }

            let lines = headerText.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else { return .badRequest }

            // First line: METHOD SP target SP HTTP/1.1
            let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2 else { return .badRequest }
            let method = String(parts[0])
            let target = String(parts[1])
            guard !method.isEmpty, !target.isEmpty else { return .badRequest }

            // Headers. Split on the FIRST ':' so header VALUES may contain
            // colons (e.g. a Host with a port, an absolute URL). Duplicate
            // header names are last-wins, EXCEPT a duplicate Content-Length with
            // a conflicting value is a bad request (request-smuggling guard).
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

            // We do NOT support chunked / any Transfer-Encoding (S1). Reject
            // rather than silently parsing an empty body.
            if let te = headers["transfer-encoding"], !te.isEmpty {
                return .lengthRequired
            }

            // Content-Length: validate BEFORE any slicing (B1). A negative or
            // oversized length, or a non-numeric value, is a bad request. No
            // body header means zero.
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

            // Split path and query.
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
        /// Raw bytes with an explicit Content-Type (vendored static assets).
        case asset(Data, String)
        case status(Int, String)

        var statusCode: Int {
            switch self {
            case .html, .text, .json, .asset: return 200
            case .status(let c, _): return c
            }
        }
        var reason: String {
            switch self {
            case .html, .text, .json, .asset: return "OK"
            case .status(_, let r): return r
            }
        }
        var contentType: String {
            switch self {
            case .html: return "text/html; charset=utf-8"
            case .text: return "text/plain; charset=utf-8"
            case .json: return "application/json"
            case .asset(_, let ct): return ct
            case .status: return "text/plain; charset=utf-8"
            }
        }
        var body: Data {
            switch self {
            case .html(let s): return Data(s.utf8)
            case .text(let s): return Data(s.utf8)
            case .json(let d): return d
            case .asset(let d, _): return d
            case .status(let c, let r): return Data("\(c) \(r)".utf8)
            }
        }
    }

    private func send(_ response: HTTPResponse, on conn: NWConnection) {
        // Disarm the idle + absolute-deadline timers as a property of send()
        // itself: once we're writing the response the connection will be
        // cancelled on completion, so the watchdogs must not still fire.
        // Idempotent (cancelConnectionTimer tolerates missing keys), so this
        // is safe even though current callers already pre-cancel — it keeps
        // future callers correct without relying on each one to remember.
        cancelConnectionTimer(ObjectIdentifier(conn))
        let body = response.body
        var head = "HTTP/1.1 \(response.statusCode) \(response.reason)\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        // Connection: close — a fresh TCP + token check per poll. Deliberate for
        // v1 simplicity; keep-alive / server-push are a possible future option.
        head += "Connection: close\r\n"
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - Embedded mobile HTML page

    // Not `private` so the embedded page can be asserted on in unit tests.
    static let htmlPage = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Ghostty Web Monitor</title>
    <style>
      :root { color-scheme: dark; }
      body { margin: 0; background: #11131a; color: #d6dae3; font-family: ui-monospace, Menlo, monospace; font-size: 14px; }
      header { padding: 10px 12px; background: #1b1e27; position: sticky; top: 0; z-index: 2; display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
      header b { color: #f0a35e; }
      button, input, select { font-family: inherit; font-size: 14px; }
      button { background: #2a2e3b; color: #d6dae3; border: 1px solid #3a3f4f; border-radius: 6px; padding: 8px 10px; }
      button:active { background: #3a3f4f; }
      /* Brief local tap acknowledgement (~150ms), independent of the network
         round-trip, so a quick-key tap visibly registers even on high latency. */
      button.tapped { background: #4a8fe7; color: #fff; border-color: #4a8fe7; }
      button.danger.tapped { background: #c25555; color: #fff; border-color: #c25555; }
      button:disabled { opacity: 0.45; cursor: not-allowed; pointer-events: none; }
      #list { padding: 8px; }
      .row { padding: 12px; margin: 6px 0; background: #1b1e27; border: 1px solid #2a2e3b; border-radius: 8px; }
      .row .t { color: #d6dae3; font-weight: bold; }
      .row .p { color: #b6bccb; font-size: 12px; margin-top: 4px; word-break: break-all; }
      .empty { padding: 12px; color: #b6bccb; }
      #viewer { display: none; padding: 8px; }
      #screenwrap { position: relative; }
      #screen { white-space: pre; background: #0c0e13; padding: 10px; border-radius: 8px; min-height: 50vh; overflow-x: auto; overflow-y: auto; max-height: 70vh; }
      #screen.wrap { white-space: pre-wrap; word-break: break-word; }
      /* xterm.js live terminal. Shown only when the raw stream is active; the
         <pre id="screen"> poll viewer is the fallback when xterm is missing or
         the /stream route is unavailable (501 / error). */
      #xterm { display: none; background: #0c0e13; padding: 6px; border-radius: 8px; min-height: 50vh; max-height: 70vh; overflow: hidden; }
      #jumpbottom { display: none; position: absolute; right: 14px; bottom: 12px; z-index: 1;
        width: 34px; height: 34px; padding: 0; line-height: 1; border-radius: 17px; opacity: 0.85;
        background: #2a2e3b; border: 1px solid #3a3f4f; color: #f0a35e; font-size: 18px; cursor: pointer; }
      #jumpbottom:active { background: #3a3f4f; }
      .bar { display: flex; gap: 6px; padding: 8px; flex-wrap: wrap; align-items: center; }
      .bar input[type=text] { flex: 1; min-width: 120px; background: #0c0e13; color: #d6dae3; border: 1px solid #2a2e3b; border-radius: 6px; padding: 8px; }
      .bar label { color: #b6bccb; font-size: 12px; }
      .notice { padding: 12px; color: #e08a8a; }
      #tokenrecovery { display: none; padding: 0 12px 12px; }
      #tokenrecovery input[type=text] { width: 100%; box-sizing: border-box; background: #0c0e13; color: #d6dae3; border: 1px solid #2a2e3b; border-radius: 6px; padding: 8px; margin-bottom: 6px; }
      #banner { display: none; padding: 8px 12px; background: #5a2a2a; color: #ffd9d9; text-align: center; }
      #banner.ok { background: #2a4a2a; color: #d9ffd9; }
      /* Ctrl-C is destructive next to benign keys (y/n/Esc): a danger color and a
         left gap separate it so it is not a one-tap fat-finger neighbor. */
      button.danger { margin-left: 12px; background: #5a2a2a; color: #ffd9d9; border-color: #7a3a3a; }
      button.danger:active { background: #7a3a3a; }
    </style>
    </head>
    <body>
    <header>
      <b>Ghostty</b> Web Monitor
      <button id="back" style="display:none">&larr; Sessions</button>
      <span id="cur"></span>
    </header>
    <div id="banner" role="status" aria-live="polite"></div>
    <div id="notice" class="notice" style="display:none" role="alert" aria-live="assertive"></div>
    <div id="tokenrecovery">
      <input id="tokeninput" type="text" placeholder="Paste token"
             autocapitalize="off" autocorrect="off" autocomplete="off"
             spellcheck="false" inputmode="text" enterkeyhint="go"
             aria-label="Token">
      <button id="tokenconnect">Connect</button>
    </div>
    <div id="list"></div>
    <div id="viewer">
      <div class="bar">
        <!-- The View (viewport/scrollback) mode toggle + Refresh only drive the
             <pre id="screen"> poll viewer; xterm.js streams live with its own
             scrollback, so #modetoggle is hidden while the live stream is active. -->
        <span id="modetoggle">
          <label for="mode">View</label>
          <select id="mode" aria-label="Screen view mode">
            <option value="viewport">Viewport</option>
            <option value="scrollback">Scrollback</option>
          </select>
          <button id="refresh">Refresh</button>
        </span>
        <label><input id="wrap" type="checkbox"> Wrap</label>
        <label for="fontsize">Size</label>
        <select id="fontsize" aria-label="Font size">
          <option value="11">11</option>
          <option value="13">13</option>
          <option value="14" selected>14</option>
          <option value="16">16</option>
          <option value="18">18</option>
        </select>
      </div>
      <div id="screenwrap">
        <div id="xterm"></div>
        <pre id="screen"></pre>
        <button id="jumpbottom" title="Jump to live bottom" aria-label="Jump to live bottom">&#x2193;</button>
      </div>
      <div class="bar">
        <input id="inp" type="text" placeholder="type and Send (Enter sends)"
               autocapitalize="off" autocorrect="off" autocomplete="off"
               spellcheck="false" inputmode="text" enterkeyhint="send"
               aria-label="Input to send to the terminal">
        <button id="send">Send</button>
        <button id="sendraw" title="Send without trailing newline">Raw</button>
      </div>
      <div class="bar">
        <button data-key="enter">Enter</button>
        <button data-key="y">y</button>
        <button data-key="n">n</button>
        <button data-key="esc">Esc</button>
        <button data-key="tab">Tab</button>
        <button data-key="ctrl-c" class="danger">Ctrl-C</button>
      </div>
      <div class="bar">
        <button data-raw="1">1</button>
        <button data-raw="2">2</button>
        <button data-raw="3">3</button>
        <button data-raw="4">4</button>
      </div>
      <div class="bar">
        <button data-key="up" aria-label="Up">&uarr;</button>
        <button data-key="down" aria-label="Down">&darr;</button>
        <button data-key="left" aria-label="Left">&larr;</button>
        <button data-key="right" aria-label="Right">&rarr;</button>
      </div>
    </div>
    <script>
    (function () {
      // The token arrives in the initial URL (?token=...). We stash it in
      // sessionStorage and thereafter send it ONLY in the X-Ghostty-Token
      // header, so it stops appearing in request URLs / referers. NOTE: it
      // still appears in the INITIAL page URL + browser history; if that
      // leaks, rotate web-monitor-token.
      var token = new URLSearchParams(location.search).get("token");
      if (token) {
        try { sessionStorage.setItem("ghostty_token", token); } catch (e) {}
        // Scrub it from the visible URL / history.
        try { history.replaceState(null, "", location.pathname); } catch (e) {}
      } else {
        try { token = sessionStorage.getItem("ghostty_token"); } catch (e) {}
      }

      var notice = document.getElementById("notice");
      var tokenRecovery = document.getElementById("tokenrecovery");
      var tokenInput = document.getElementById("tokeninput");
      var tokenConnect = document.getElementById("tokenconnect");
      var banner = document.getElementById("banner");
      var listEl = document.getElementById("list");
      var viewer = document.getElementById("viewer");
      var screenEl = document.getElementById("screen");
      var jumpBtn = document.getElementById("jumpbottom");
      var backBtn = document.getElementById("back");
      var curEl = document.getElementById("cur");
      var modeEl = document.getElementById("mode");
      var modeToggleEl = document.getElementById("modetoggle");
      var wrapEl = document.getElementById("wrap");
      var fontEl = document.getElementById("fontsize");
      var inp = document.getElementById("inp");
      var xtermEl = document.getElementById("xterm");
      var current = null, timer = null, listTimer = null;
      // Active live-stream handle (xterm.js raw byte stream). Held in a module
      // var so showSurface/Back/teardown can dispose it before starting another.
      var stream = null;

      // Show the no-token / 401 notice together with an in-page token-recovery
      // form. The URL was scrubbed via replaceState, so a phone user who lost
      // the ?token=... link has no other way to re-enter it. Connecting stores
      // the entered token in sessionStorage and (re)starts the fetches.
      function showTokenRecovery(msg) {
        notice.style.display = "block";
        notice.textContent = msg;  // textContent: untrusted-safe, no innerHTML
        // Don't disturb the input (clear/refocus) if the form is already shown:
        // a background poll/list 401 must not wipe a token the user is typing.
        if (tokenRecovery.style.display === "block") return;
        tokenRecovery.style.display = "block";
        tokenInput.value = "";
        tokenInput.focus();
      }
      tokenConnect.onclick = function () {
        var t = tokenInput.value.trim();
        if (!t) { tokenInput.focus(); return; }
        token = t;
        try { sessionStorage.setItem("ghostty_token", token); } catch (e) {}
        notice.style.display = "none";
        tokenRecovery.style.display = "none";
        tokenInput.value = "";
        start();  // re-run the fetches with the freshly entered token
      };
      tokenInput.addEventListener("keydown", function (e) {
        if (e.key === "Enter") { e.preventDefault(); tokenConnect.onclick(); }
      });

      if (!token) {
        showTokenRecovery("No token. Open this page with ?token=YOUR_TOKEN once, or paste it below.");
        return; // Do not fire any fetch — every request would 401 (M7).
      }

      function headers(extra) {
        var h = { "X-Ghostty-Token": token };
        if (extra) for (var k in extra) h[k] = extra[k];
        return h;
      }
      function url(path, params) {
        if (!params) return path;
        var p = new URLSearchParams();
        for (var k in params) p.set(k, params[k]);
        return path + "?" + p.toString();
      }
      // Load the vendored xterm.js + xterm.css served by the app (assetRoutes,
      // query-token allowed). These are TAGS, not fetches, so the token rides
      // in the query string like the GET / bootstrap. If they fail to load,
      // window.Terminal stays undefined and openStream() degrades to the
      // <pre id="screen"> poll fallback. Build the URLs with url() so the token
      // is appended exactly like every other request.
      (function () {
        var css = document.createElement("link");
        css.rel = "stylesheet";
        css.href = url("/xterm.css", { token: token });
        document.head.appendChild(css);
        var js = document.createElement("script");
        js.src = url("/xterm.js", { token: token });
        document.head.appendChild(js);
      })();
      // bannerIsError tracks whether the visible banner is a sticky error
      // (send failure / session closed). Sticky errors persist until the next
      // explicit user action; the poll()/loadList() success paths must NOT wipe
      // them. Call setBanner(msg, ok, true) to mark a banner sticky.
      var bannerIsError = false;
      function setBanner(msg, ok, sticky) {
        if (!msg) { banner.style.display = "none"; bannerIsError = false; return; }
        banner.textContent = msg;
        banner.className = ok ? "ok" : "";
        banner.style.display = "block";
        bannerIsError = !!sticky;
      }
      // Clear the banner only if it is not a sticky error. Used on the
      // poll()/loadList() success paths so a send-failure / session-closed
      // banner survives the next successful poll.
      function clearBannerIfNotError() { if (!bannerIsError) setBanner(null); }

      // True until the list has rendered real content at least once; only then
      // do we suppress the "Loading…" placeholder so background refreshes
      // (~3s) re-render rows in place without flashing/losing scroll.
      var listLoaded = false;
      function loadList() {
        // Show the placeholder only on the FIRST/empty load. On a background
        // refresh the rows are diffed/replaced in place (see below) so the
        // list does not flash or jump to the top.
        if (!listLoaded) listEl.innerHTML = "<div class='empty'>Loading\\u2026</div>";
        fetch(url("/api/surfaces"), { headers: headers() }).then(function (r) {
          if (r.status === 401) throw new Error("401");
          if (!r.ok) throw new Error("HTTP " + r.status);
          return r.json();
        }).then(function (rows) {
          clearBannerIfNotError();
          listLoaded = true;
          if (!rows.length) {
            listEl.innerHTML = "<div class='empty'>No active sessions.</div>";
            return;
          }
          // Build the new rows off-screen, then swap them in atomically so the
          // visible list never blanks to a placeholder between refreshes.
          var frag = document.createDocumentFragment();
          rows.forEach(function (row) {
            var d = document.createElement("div");
            d.className = "row";
            var t = document.createElement("div"); t.className = "t"; t.textContent = row.title || "(untitled)";
            var p = document.createElement("div"); p.className = "p"; p.textContent = row.pwd || "";
            d.appendChild(t); d.appendChild(p);
            d.onclick = function () { showSurface(row.id, row.title); };
            frag.appendChild(d);
          });
          listEl.replaceChildren(frag);
        }).catch(function (e) {
          if (String(e.message) === "401") {
            showTokenRecovery("Unauthorized. The token is wrong or was rotated. Reopen with ?token=..., or paste a token below.");
            listEl.innerHTML = "";
            listLoaded = false;  // wiped: let a recovery re-show the placeholder
          } else {
            setBanner("Connection lost \\u2014 retrying\\u2026", false);
          }
        });
      }

      // The session this viewer was watching is gone (server returned 404).
      // Shared by the poll() 404 path and reportSend()'s 404 handling so a
      // send that 404s tears down identically instead of leaving a stale
      // viewer + sticky banner until the next poll fires.
      function sessionClosedTeardown() {
        setBanner("Session closed.", false, true);
        if (timer) { clearInterval(timer); timer = null; }
        current = null;
        // Offer return to the list.
        loadList();
        showList();
      }

      function poll(userInitiated) {
        if (!current) return;
        fetch(url("/api/surface/" + current + "/screen", { mode: modeEl.value }), { headers: headers() })
          .then(function (r) {
            if (r.status === 404) throw new Error("404");
            if (r.status === 401) throw new Error("401");
            if (!r.ok) throw new Error("HTTP " + r.status);
            return r.text();
          })
          .then(function (txt) {
            clearBannerIfNotError();
            // Preserve scroll: only auto-stick to bottom if already near it.
            // On a user-initiated change (mode/wrap/font), the old pixel
            // scrollTop is meaningless against the new content, so jump to the
            // live bottom instead of restoring it.
            var wasNearBottom = isNearBottom();
            var prevTop = screenEl.scrollTop;
            screenEl.textContent = txt;  // textContent: no HTML/JS injection
            if (userInitiated || wasNearBottom) screenEl.scrollTop = screenEl.scrollHeight;
            else screenEl.scrollTop = prevTop;
            updateJumpBtn();
          })
          .catch(function (e) {
            var m = String(e.message);
            if (m === "404") {
              sessionClosedTeardown();
            } else if (m === "401") {
              // Token was rotated mid-session: stop polling (otherwise we'd
              // 401-spam every 700ms) and surface the same persistent, actionable
              // notice as loadList's 401 path.
              if (timer) { clearInterval(timer); timer = null; }
              current = null;
              setBanner(null);
              showTokenRecovery("Unauthorized. The token is wrong or was rotated. Reopen with ?token=..., or paste a token below.");
              showList();
            } else {
              setBanner("Connection lost \\u2014 reconnecting\\u2026", false);
            }
          });
      }

      // True when the screen is scrolled to (or very near) its live bottom.
      // The same threshold drives auto-follow re-stick and the jump button's
      // visibility, so the button appears exactly when auto-follow has stopped.
      function isNearBottom() {
        return (screenEl.scrollHeight - screenEl.scrollTop - screenEl.clientHeight) < 24;
      }
      // Show the jump-to-bottom button only while the user has scrolled up
      // (auto-follow paused). Hidden when already at the live bottom so it stays
      // unobtrusive, especially on mobile.
      function updateJumpBtn() {
        jumpBtn.style.display = isNearBottom() ? "none" : "block";
      }
      jumpBtn.onclick = function () {
        screenEl.scrollTop = screenEl.scrollHeight;  // jump to live bottom, re-arm auto-follow
        updateJumpBtn();
      };
      screenEl.addEventListener("scroll", updateJumpBtn);

      // Dispose any active live stream: cancel the body reader and tear down the
      // xterm.js instance, then hide the xterm container. Idempotent.
      function disposeStream() {
        if (!stream) return;
        var s = stream; stream = null;
        try { s.dispose(); } catch (e) {}
        xtermEl.style.display = "none";
        xtermEl.replaceChildren();  // drop the old terminal's DOM
      }

      // Switch this viewer to the plain-text poll fallback (the <pre id="screen">
      // viewer). Used when xterm.js is unavailable or the /stream route fails.
      // Shows the poll viewer, starts the 700ms poll, and surfaces a banner.
      function fallbackToPoll(msg) {
        disposeStream();
        screenEl.style.display = "block";
        modeToggleEl.style.display = "";  // poll viewer active: the mode toggle applies again
        if (msg) setBanner(msg, false);
        if (!current) return;
        poll();
        if (timer) clearInterval(timer);
        timer = setInterval(poll, 700);  // >= ~600ms (cache TTL ~500ms)
      }

      // Open the live raw-byte stream for `uuid` into an xterm.js terminal. Only
      // attempts the stream if window.Terminal loaded; otherwise returns null so
      // the caller uses the poll fallback. Pipes response.body bytes into
      // term.write(). On fetch reject / non-ok / 501 / stream end, surfaces the
      // connection-lost / "Session closed." banner and falls back to the poll
      // viewer. Returns a handle with dispose() (cancel reader + term.dispose()).
      function openStream(uuid) {
        if (!window.Terminal) return null;
        var term = new Terminal({
          convertEol: false,
          scrollback: 10000,
          fontSize: parseInt(fontEl.value, 10) || 14
        });
        term.open(xtermEl);
        xtermEl.style.display = "block";
        screenEl.style.display = "none";  // hide the poll fallback while streaming
        modeToggleEl.style.display = "none";  // viewport/scrollback toggle is moot under xterm

        var reader = null;
        var disposed = false;
        function teardown() {
          if (disposed) return;
          disposed = true;
          if (reader) { try { reader.cancel(); } catch (e) {} }
          try { term.dispose(); } catch (e) {}
        }

        fetch(url("/api/surface/" + uuid + "/stream"), { headers: headers({}) })
          .then(function (r) {
            // 404 -> session gone; 501 -> no pty-host (stream unavailable); any
            // other non-ok -> connection problem. All degrade to the poll viewer.
            if (r.status === 404) { if (stream === handle) { sessionClosedTeardown(); } return; }
            if (!r.ok || !r.body) {
              if (stream === handle) fallbackToPoll("Live stream unavailable \\u2014 using snapshot.");
              return;
            }
            reader = r.body.getReader();
            function pump() {
              return reader.read().then(function (res) {
                if (disposed) return;
                if (res.done) {
                  // Source closed: the session ended or the host dropped. Fall
                  // back to a poll so a still-live session keeps updating.
                  if (stream === handle) fallbackToPoll("Live stream ended \\u2014 using snapshot.");
                  return;
                }
                term.write(res.value);  // res.value is a Uint8Array; xterm accepts it
                return pump();
              });
            }
            return pump();
          })
          .catch(function () {
            if (disposed) return;
            if (stream === handle) fallbackToPoll("Connection lost \\u2014 using snapshot.");
          });

        var handle = { dispose: teardown };
        return handle;
      }

      function showList() {
        disposeStream();
        viewer.style.display = "none";
        listEl.style.display = "block";
        backBtn.style.display = "none";
        curEl.textContent = "";
        jumpBtn.style.display = "none";  // not viewing a screen: hide the jump affordance
      }

      function showSurface(id, title) {
        current = id;
        listEl.style.display = "none";
        viewer.style.display = "block";
        backBtn.style.display = "inline-block";
        curEl.textContent = title || "";
        setBanner(null);
        // Prefer the live xterm.js raw stream (color + scrollback + live). If
        // xterm.js isn't loaded, openStream returns null and we use the plain
        // poll viewer. openStream itself falls back to the poll on stream failure.
        disposeStream();
        stream = openStream(id);
        if (stream) {
          // Streaming: no poll timer (the stream is the live source). Keep the
          // poll fallback hidden until/unless the stream degrades.
          if (timer) { clearInterval(timer); timer = null; }
        } else {
          screenEl.style.display = "block";
          modeToggleEl.style.display = "";  // poll viewer: the viewport/scrollback toggle applies
          poll();
          if (timer) clearInterval(timer);
          timer = setInterval(poll, 700);  // >= ~600ms (cache TTL ~500ms)
        }
        inp.focus();
      }

      backBtn.onclick = function () {
        current = null;
        if (timer) { clearInterval(timer); timer = null; }
        showList();
        loadList();
      };

      // View preferences persist across page loads (localStorage; best-effort).
      function prefGet(k, dflt) { try { var v = localStorage.getItem(k); return v === null ? dflt : v; } catch (e) { return dflt; } }
      function prefSet(k, v) { try { localStorage.setItem(k, v); } catch (e) {} }
      function applyWrap() { screenEl.classList.toggle("wrap", wrapEl.checked); }
      function applyFont() { screenEl.style.fontSize = fontEl.value + "px"; }
      // Restore saved prefs.
      modeEl.value = prefGet("ghostty_mode", modeEl.value);
      wrapEl.checked = prefGet("ghostty_wrap", "0") === "1";
      fontEl.value = prefGet("ghostty_font", fontEl.value);
      applyWrap(); applyFont();

      document.getElementById("refresh").onclick = poll;
      modeEl.onchange = function () { prefSet("ghostty_mode", modeEl.value); poll(true); };
      wrapEl.onchange = function () { applyWrap(); prefSet("ghostty_wrap", wrapEl.checked ? "1" : "0"); screenEl.scrollTop = screenEl.scrollHeight; updateJumpBtn(); };
      fontEl.onchange = function () { applyFont(); prefSet("ghostty_font", fontEl.value); screenEl.scrollTop = screenEl.scrollHeight; updateJumpBtn(); };

      // A quick-key / Send tapped after the viewed session was torn down (e.g. a
      // 404 cleared `current`) would otherwise be a silent dead tap. Surface a
      // brief, non-sticky "No active session." banner instead so the tap isn't lost.
      function noActiveSession() { setBanner("No active session.", false); setTimeout(clearBannerIfNotError, 1500); }
      function sendKey(key) {
        if (!current) { noActiveSession(); return; }
        fetch(url("/api/surface/" + current + "/input"), {
          method: "POST",
          headers: headers({ "Content-Type": "application/json" }),
          body: JSON.stringify({ key: key })
        }).then(reportSend).catch(function () { setBanner("Send failed \\u2014 not delivered.", false, true); });
      }
      function sendText(text) {
        if (!text) return;
        if (!current) { noActiveSession(); return; }
        fetch(url("/api/surface/" + current + "/input"), {
          method: "POST",
          headers: headers({ "Content-Type": "text/plain" }),  // explicit: server keys off Content-Type (S11)
          body: text
        }).then(reportSend).catch(function () { setBanner("Send failed \\u2014 not delivered.", false, true); });
      }
      function reportSend(r) {
        // ~1500ms (was 600ms): a throttled/backgrounded mobile tab can easily miss
        // a 600ms flash. A later successful poll/list still clears it earlier via
        // clearBannerIfNotError (it is not sticky), so this only sets the ceiling.
        if (r && r.ok) { setBanner("Sent.", true); setTimeout(function () { clearBannerIfNotError(); }, 1500); }
        // A 404 means the session is gone: tear down exactly like the poll()
        // 404 path (clear timer, current=null, sticky "Session closed." banner,
        // back to the list) instead of leaving a stale viewer + sticky banner.
        else if (r && r.status === 404) { sessionClosedTeardown(); }
        else { setBanner("Send failed (HTTP " + (r ? r.status : "?") + ").", false, true); }
      }

      function doSend(withNewline) {
        var v = inp.value;
        if (!v) return;
        // Type the text (text/plain -> server turns it into typed key events),
        // then for Send (withNewline) ALSO fire a separate Enter key event
        // (sendKey -> {key:"enter"}). NO trailing newline is ever appended; the
        // newline/submit is a real Enter key, not a pasted character.
        sendText(v);
        if (withNewline) sendKey("enter");
        inp.value = "";
        inp.focus();
        syncSendEnabled();
      }
      var sendBtn = document.getElementById("send");
      var rawBtn = document.getElementById("sendraw");
      sendBtn.onclick = function () { doSend(true); };
      rawBtn.onclick = function () { doSend(false); };
      inp.addEventListener("keydown", function (e) {
        if (e.key === "Enter") { e.preventDefault(); doSend(true); }
      });
      function syncSendEnabled() {
        var empty = !inp.value;
        sendBtn.disabled = empty;
        rawBtn.disabled = empty;
      }
      inp.addEventListener("input", syncSendEnabled);
      syncSendEnabled();

      // Brief local visual ack on tap, independent of the network round-trip,
      // so the user sees the press registered even under latency. Re-arms the
      // timer on rapid repeat taps so the flash always lasts ~150ms from the
      // last tap; does not change what bytes are sent.
      function flashTap(b) {
        b.classList.add("tapped");
        if (b._tapTimer) clearTimeout(b._tapTimer);
        b._tapTimer = setTimeout(function () { b.classList.remove("tapped"); }, 150);
      }

      Array.prototype.forEach.call(document.querySelectorAll("[data-key]"), function (b) {
        b.onclick = function () { flashTap(b); sendKey(b.getAttribute("data-key")); };
      });

      // Raw-digit quick-keys (1/2/3/4): send the bare digit with NO newline via
      // the text/plain raw path, so Claude Code permission menus answer in one tap.
      Array.prototype.forEach.call(document.querySelectorAll("[data-raw]"), function (b) {
        b.onclick = function () { flashTap(b); sendText(b.getAttribute("data-raw")); };
      });

      // Pause the 700ms poll while hidden (wasteful, and mobile throttles it
      // anyway); re-poll / re-list immediately when the page returns to the
      // foreground, re-arming the interval if a surface is being viewed.
      document.addEventListener("visibilitychange", function () {
        if (document.visibilityState === "visible") {
          if (current) {
            // While the live xterm stream is active there is no poll timer to
            // re-arm (the stream is the source); leave it to keep streaming.
            if (stream) return;
            poll();
            if (timer) clearInterval(timer);
            timer = setInterval(poll, 700);
          } else {
            loadList();
          }
        } else if (timer) {
          clearInterval(timer);
          timer = null;
        }
      });

      // Start (or restart, after token recovery) the fetches: refresh the list
      // now and keep the (cheap) session list fresh while browsing it. The list
      // timer is armed only once; re-running start() after recovery just kicks
      // a fresh loadList().
      function start() {
        if (!listTimer) {
          listTimer = setInterval(function () { if (!current) loadList(); }, 3000);
        }
        loadList();
      }

      start();
    })();
    </script>
    </body>
    </html>
    """
}

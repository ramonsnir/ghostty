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
    // every receive/send callback run on this queue, which serializes ALL access
    // to the server's mutable dicts (connectionRefs/Timers, streamClients,
    // streamingConns, failedAuth, cachedSurfaces). The API handlers that need
    // AppKit / SurfaceView / ghostty_surface_* hop to main via `respondFromMain`
    // (the simple ones) or the routeStream resolve hop — both now ASYNC, not
    // `main.sync`, so the serial queue is FREED during the (slow, under SwiftUI
    // load) main hop instead of head-of-line-blocking every other connection
    // behind it. The response is `send`-ed back ON this queue, so dict access
    // stays serialized; only value types (HTTPResponse) cross the hop. (The hop
    // is still deadlock-free either way — we are never already on main.)
    private let queue = DispatchQueue(label: "com.mitchellh.ghostty-ramon.webmonitor")

    private let listenSpec: String
    private let token: String

    /// The parsed host:port. The host is used ONLY for the Host-header
    /// allowlist (DNS-rebinding defense), never as an IP allowlist.
    private let parsed: (host: String, port: UInt16)?

    /// Web Push subsystem: owns the VAPID keypair + subscription store + enable
    /// flag, observes bells, and fans each bell out as an encrypted push. The
    /// `/api/push/*` routes + the served service worker drive it. Lifecycle is
    /// tied to the server (`start()`/`stop()` below).
    let push = WebPushManager()

    /// (ramon fork / Bell Attention v2) The `monitor` effect's routing per tier, set by
    /// AppDelegate at start from bell-features.monitor / attention-features.monitor.
    /// Drives the per-row `attnIndicator` in the surfaces JSON. Default true (both tiers)
    /// ⇒ the page flag reproduces today's bell indicator + surfaces promotions. Read on
    /// the main hop in `surfacesJSON`; written once before `start()`.
    var monitorBell = true
    var monitorAttn = true

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

    /// Memoized `/api/surfaces` JSON + the time it was built. Accessed ONLY on
    /// `queue`. The page polls every ~3s and many phones can poll at once; without
    /// this each poll would hop to main and rebuild the list (iterating every
    /// TerminalController + surface) — a main-thread cost that scales with clients.
    /// A short TTL collapses STEADY-STATE bursts to ~1 build/sec (see thundering-
    /// herd note in `.surfacesList`). Deliberate tradeoff: the list can lag a
    /// surface create/close/rename by up to the TTL — fine for a phone list view,
    /// and the per-surface routes (/screen,/input,/scroll,/stream) re-resolve the
    /// surface LIVE each call, so a stale id from the cached list 404s on next
    /// action rather than acting on a wrong/closed surface. No token leak: the
    /// payload is the same {id,title,pwd} for every authenticated caller, and the
    /// token gate in decideRoute rejects (.unauthorized) BEFORE .surfacesList is
    /// reached, so the cache is only ever served to already-authenticated callers.
    private var cachedSurfaces: (data: Data, at: Date)?
    /// `internal` (not `private`) so `surfacesCacheFresh`'s default-`ttl` argument
    /// — evaluated at the call site — resolves for the unit tests that omit `ttl`.
    static let surfacesCacheTTL: TimeInterval = 1.0

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
        // All three fork identities (Release, ReleaseLocal, Debug) share
        // ~/.config/ghostty-ramon/config, so they read the SAME
        // web-monitor-listen port and would fight over it when run side-by-side.
        // Shift the dev builds' (loopback) bind port up by a per-identity offset
        // so they coexist; Release (the canonical bundle id) keeps the configured
        // port unchanged. `tailscale serve` then maps each identity's external
        // HTTPS port to its own loopback bind port. Mirrors MCPServer.
        self.parsed = Self.applyPortOffset(
            Self.parseListen(listen),
            offset: Self.portOffset(forBundleID: Bundle.main.bundleIdentifier))
    }

    /// Per-identity loopback-port offset so the three fork builds coexist.
    /// Release `+0`, ReleaseLocal `+1`, Debug `+2`. Pure + testable.
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

    // MARK: - Lifecycle

    func start() {
        // Start the Web Push subsystem (bell observer). Independent of the HTTP
        // listener binding — it just no-ops until a device subscribes and the
        // toggle is armed.
        push.start()

        // Token-strength gate at startup: never accidentally open with a weak
        // (empty/short) token. The token is a shell-execution credential, so a
        // guessable one is as dangerous as none — require a real, long random
        // token before binding the port.
        // Token auth is OPTIONAL. Empty -> run OPEN (access control is the
        // tailnet / Tailscale ACL alone); warn so it is a deliberate choice, not
        // a silent surprise. A non-empty but short token is allowed but warned.
        if token.isEmpty {
            logger.warning("web-monitor: starting WITHOUT a token — OPEN on the bound port; access control is your Tailscale ACL alone")
        } else if !Self.tokenAcceptable(token) {
            logger.warning("web-monitor: web-monitor-token is under \(Self.minTokenLength, privacy: .public) chars — consider a longer random token")
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
        // Tear down the Web Push observer (hops to main itself).
        push.stop()

        // Teardown is invoked from applicationWillTerminate on the MAIN thread,
        // but `connectionRefs` is otherwise mutated only on the dedicated serial
        // `queue` (handle / stateUpdateHandler). Hop onto that queue so ALL
        // access to the connection bookkeeping stays serialized — but do it
        // ASYNC, never sync: a `queue.sync` from main could still invert against
        // a handler's main hop and hang termination (the handlers' main hops are
        // now async, but a queue.sync-from-main lock-order rule is kept as the
        // safe invariant). NWListener /
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
                // Full request received; disarm the watchdogs before we do the
                // (possibly main-thread) routing + response. This is LOAD-BEARING
                // for the de-blocked handlers: `cancelConnectionTimer` cancels
                // BOTH the idle watchdog AND the absolute-deadline timer, and the
                // converted handlers hop to main *asynchronously* (respondFromMain
                // / the .surfacesList + routeStream resolve hops) — which frees the
                // serial `queue`. If the absolute-deadline timer were still armed
                // here, the now-free queue could let it fire mid-hop and cancel the
                // connection out from under an in-flight response. Both timers are
                // already dead by this point, so that race cannot occur; keep this
                // cancel BEFORE routeRequest. (send() also re-cancels idempotently.)
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
        case frame(uuid: UUID)                   // GET /api/surface/{uuid}/frame (host authoritative ANSI frame)
        case input(uuid: UUID)                   // POST /api/surface/{uuid}/input
        case scroll(uuid: UUID)                  // POST /api/surface/{uuid}/scroll (mouse wheel)
        case clearBell(uuid: UUID)               // POST /api/surface/{uuid}/bell (acknowledge bell)
        case clearAttention(uuid: UUID)          // POST /api/surface/{uuid}/attention (acknowledge promotion)
        case setHidden(uuid: UUID)               // POST /api/surface/{uuid}/hidden {hidden:bool} (dashboard hide set)
        case asset(name: String, ext: String, contentType: String) // GET /xterm.js|/xterm.css
        case serviceWorker                       // GET /sw.js (bootstrap; Web Push SW)
        case pushConfig                          // GET /api/push/config (VAPID pubkey + enabled)
        case pushSubscribe                       // POST /api/push/subscribe
        case pushUnsubscribe                     // POST /api/push/unsubscribe
        case pushEnabled                         // POST /api/push/enabled (arm/mute the toggle)
    }

    /// The static asset routes (vendored xterm.js / xterm.css), served from the
    /// app bundle. Keyed by request path -> (resource name, extension, MIME).
    /// These are bootstrap routes (see `isBootstrapPath`): like `GET /`, they
    /// accept the token via `?token=` because a `<script src>` / `<link href>`
    /// tag cannot set the X-Ghostty-Token header.
    static let assetRoutes: [String: (name: String, ext: String, contentType: String)] = [
        "/xterm.js": ("xterm", "js", "application/javascript; charset=utf-8"),
        "/xterm.css": ("xterm", "css", "text/css; charset=utf-8"),
        // JetBrains Mono Nerd Font (Regular + Bold), vendored as woff2 so the page
        // renders in the SAME font as Ghostty itself (the GUI defaults to this Nerd
        // Font build). The phone has no such system font, so we MUST ship it; the
        // @font-face that references these is injected client-side (see the page's
        // asset-loader IIFE) so the token rides the query string like xterm.css.
        "/jetbrains-mono-regular.woff2": ("JetBrainsMonoNerdFont-Regular", "woff2", "font/woff2"),
        "/jetbrains-mono-bold.woff2": ("JetBrainsMonoNerdFont-Bold", "woff2", "font/woff2"),
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
        // `/sw.js` is bootstrap too: the browser fetches the service worker via
        // navigator.serviceWorker.register("/sw.js?token=…"), which (like a
        // <script>/<link> tag) cannot set the X-Ghostty-Token header.
        path == "/" || path == "/sw.js" || assetRoutes[path] != nil
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

        // Token auth is OPTIONAL. When web-monitor-token is EMPTY the server is
        // OPEN — access control is the tailnet / Tailscale ACL alone (the bound
        // port + Host-header allowlist still apply). When a token IS configured
        // it gates every route, with the per-peer brute-force backoff. The query
        // token (`?token=`) is accepted ONLY for the BOOTSTRAP paths (GET / and
        // the <script>/<link> asset routes, which cannot send a custom header);
        // every /api/* route requires the X-Ghostty-Token header.
        if !token.isEmpty {
            if peerFailureCount >= failedAuthThreshold { return .throttled }
            let headerToken = headers["x-ghostty-token"] ?? ""
            let presented = isBootstrapPath(path) ? (query["token"] ?? headerToken) : headerToken
            guard tokensMatch(presented, token) else { return .unauthorized }
        }

        // Route on (method, path).
        if path == "/" {
            return method == "GET" ? .page : .methodNotAllowed
        }
        if let asset = assetRoutes[path] {
            return method == "GET"
                ? .asset(name: asset.name, ext: asset.ext, contentType: asset.contentType)
                : .methodNotAllowed
        }
        if path == "/sw.js" {
            return method == "GET" ? .serviceWorker : .methodNotAllowed
        }
        if path == "/api/surfaces" {
            return method == "GET" ? .surfacesList : .methodNotAllowed
        }

        // /api/push/{action} — Web Push registration + the arm/mute toggle.
        if path == "/api/push/config" {
            return method == "GET" ? .pushConfig : .methodNotAllowed
        }
        if path == "/api/push/subscribe" {
            return method == "POST" ? .pushSubscribe : .methodNotAllowed
        }
        if path == "/api/push/unsubscribe" {
            return method == "POST" ? .pushUnsubscribe : .methodNotAllowed
        }
        if path == "/api/push/enabled" {
            return method == "POST" ? .pushEnabled : .methodNotAllowed
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
            case "frame":
                // One-shot HOST-authoritative ANSI frame (for scrolling a
                // full-screen app without xterm.js re-emulation drift).
                guard method == "GET" else { return .methodNotAllowed }
                return .frame(uuid: uuid)
            case "input":
                guard method == "POST" else { return .methodNotAllowed }
                return .input(uuid: uuid)
            case "scroll":
                guard method == "POST" else { return .methodNotAllowed }
                return .scroll(uuid: uuid)
            case "bell":
                guard method == "POST" else { return .methodNotAllowed }
                return .clearBell(uuid: uuid)
            case "attention":
                guard method == "POST" else { return .methodNotAllowed }
                return .clearAttention(uuid: uuid)
            case "hidden":
                guard method == "POST" else { return .methodNotAllowed }
                return .setHidden(uuid: uuid)
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
            if let cached = Self.cachedSurfacesData(cachedSurfaces, now: Date()) {
                // Fresh — serve from cache with NO main-thread hop at all.
                send(.json(cached), on: conn)
            } else {
                // Stale/empty — build on main, then on `queue` store + send. NOTE: a
                // burst of misses arriving BEFORE the first build stores the cache will
                // each independently hop to main (the cache only collapses misses AFTER
                // the first store lands), so the ~1 build/sec bound holds in steady
                // state, not against a cold-cache thundering herd. Still a large win for
                // the dominant 3s-poll case, and bounded by the 32-conn cap.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let json = self.surfacesJSON()
                    self.queue.async {
                        self.cachedSurfaces = (data: json, at: Date())
                        self.send(.json(json), on: conn)
                    }
                }
            }

        case .methodNotAllowed:
            clearAuthFailures(peer)
            send(.status(405, "Method Not Allowed"), on: conn)

        case .notFound:
            clearAuthFailures(peer)
            send(.status(404, "Not Found"), on: conn)

        case .screen(let uuid, let scrollback):
            clearAuthFailures(peer)
            respondFromMain(on: conn) {
                guard let view = self.surface(forUUID: uuid) else { return .status(404, "Not Found") }
                // Reuse the cached readers (~500ms TTL; they free their own
                // text inside the cache closure). Value out only.
                let text = scrollback
                    ? view.cachedScreenContents.get()
                    : view.cachedVisibleContents.get()
                return .text(text)
            }

        case .frame(let uuid):
            clearAuthFailures(peer)
            // The HOST's authoritative render of the current viewport, serialized
            // to a self-contained ANSI frame (SGR + text, CUP-addressed, exact
            // RGB). The page writes this into xterm.js while scrolling a
            // full-screen app so the phone shows the exact frame the desktop shows
            // instead of re-emulating the raw stream (which drifts on scroll).
            // 501 when the surface has no pty-host mirror (read_ansi false).
            respondFromMain(on: conn) {
                guard let view = self.surface(forUUID: uuid),
                      let surface = view.surface else { return .status(404, "Not Found") }
                var text = ghostty_text_s()
                guard ghostty_surface_read_ansi(surface, &text) else {
                    return .status(501, "Not Implemented")
                }
                defer { ghostty_surface_free_text(surface, &text) }
                let data = Data(bytes: text.text, count: Int(text.text_len))
                return .asset(data, "text/plain; charset=utf-8")
            }

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
            respondFromMain(on: conn) {
                guard let (controller, view) = self.controllerAndView(forUUID: uuid),
                      let surface = view.surface else { return .status(404, "Not Found") }
                // If the target is hidden under a zoom, reveal it first so it gets
                // sized — otherwise the keypress lands on a stale/unsized surface.
                self.revealIfZoomedAway(controller, view)
                // Build a ghostty_input_key_s per spec and replay it as a real
                // key event. Mirror the macOS keyDown path: send a PRESS then a
                // RELEASE for each spec. Only value types crossed the main-thread
                // hop; the surface pointer is fetched and used entirely on main.
                for spec in specs {
                    spec.send(to: surface)
                }
                return .json(Data(#"{"ok":true,"sent":\#(specs.count)}"#.utf8))
            }

        case .scroll(let uuid):
            clearAuthFailures(peer)
            guard let dy = Self.scrollDeltaY(body: req.body) else {
                send(.status(400, "Bad Request"), on: conn)
                return
            }
            // Whether to (re)seed the cursor position before this wheel. The page
            // sends `seed:true` ONLY on the first scroll after opening a surface (see
            // the load-bearing note below); subsequent scrolls omit it.
            let seed = Self.scrollSeed(body: req.body)
            respondFromMain(on: conn) {
                guard let (controller, view) = self.controllerAndView(forUUID: uuid),
                      let surface = view.surface else { return .status(404, "Not Found") }
                // A zoomed-away split keeps a stale/zero size and ignores scroll;
                // reveal it so the wheel lands on a properly-sized surface.
                self.revealIfZoomedAway(controller, view)
                // Seed a cursor position at the CENTER of the surface — but ONLY on the
                // first scroll of a viewing (seed==true). A mouse-reporting TUI (Claude
                // Code, htop, vim+mouse) encodes the wheel as an SGR mouse event AT THE
                // CURSOR POSITION (`getCursorPos()`) and scrolls only if it lands in its
                // scrollable region. The web monitor never moves a mouse, so the position
                // defaulted to (0,0) — the top (Claude's header) — and the app ignored
                // the wheel (the original dead-no-op). But `ghostty_surface_mouse_pos`
                // also emits a MOUSE-MOVE report (Claude has any-event tracking, ?1003),
                // and Claude RESETS its scroll on that move — so seeding before EVERY
                // wheel made consecutive scrolls non-cumulative (they'd never go past ~1
                // screen). The desktop does ONE move then MANY wheels, which accumulate to
                // the full history. So we seed ONCE (the position then persists on the
                // surface) and send bare wheels after — matching the desktop. Logical
                // points ×content_scale internally; size is physical px → /backingScale.
                if seed {
                    let size = ghostty_surface_size(surface)
                    let scale = view.window?.backingScaleFactor ?? 2.0
                    if size.width_px > 0, size.height_px > 0, scale > 0 {
                        ghostty_surface_mouse_pos(
                            surface,
                            Double(size.width_px) / scale / 2.0,
                            Double(size.height_px) / scale / 2.0,
                            GHOSTTY_MODS_NONE)
                    }
                }
                // Discrete (non-precision) wheel scroll: scroll_mods = 0, y = ticks.
                // The host routes it per the app's mode (mouse-mode SGR wheel at the
                // seeded position, alternate-scroll arrows for less/man, or scrollback)
                // exactly like a real wheel — so a TUI scrolls and the redraw streams back.
                ghostty_surface_mouse_scroll(surface, 0, dy, 0)
                return .json(Data(#"{"ok":true}"#.utf8))
            }

        case .clearBell(let uuid):
            clearAuthFailures(peer)
            // Acknowledge a bell from the phone WITHOUT focusing the surface
            // locally — drop the 🔔/border/badge so it can ring again later.
            respondFromMain(on: conn) {
                guard let view = self.surface(forUUID: uuid) else { return .status(404, "Not Found") }
                view.resetBell()
                return .json(Data(#"{"ok":true}"#.utf8))
            }

        case .clearAttention(let uuid):
            clearAuthFailures(peer)
            // (ramon fork / Bell Attention v2) Acknowledge a PROMOTION from the phone
            // WITHOUT focusing the surface — drop the attention-tier border/title/badge
            // independently of the raw bell (P5). The sidecar re-arms on its next clean
            // classify, so a still-live condition can promote again.
            respondFromMain(on: conn) {
                guard let view = self.surface(forUUID: uuid) else { return .status(404, "Not Found") }
                view.resetAttention()
                return .json(Data(#"{"ok":true}"#.utf8))
            }

        case .setHidden(let uuid):
            clearAuthFailures(peer)
            // Hide/reveal this split from the phone by toggling the Agent Dashboard's
            // persisted hide set (the SAME one the tile eye-slash + `hide_dashboard_split`
            // use), so a phone hide is a desktop hide and the "Hide hidden" list filter
            // drops it. `hidden` is by UUID and independent of whether the surface is
            // live, so this succeeds even for a not-currently-resolvable surface — the
            // only failure is the dashboard being unavailable (503).
            guard let want = Self.hiddenFlag(body: req.body) else {
                send(.status(400, "Bad Request"), on: conn)
                return
            }
            respondFromMain(on: conn) {
                // The controller is @MainActor; this closure already runs on main
                // (respondFromMain), so assumeIsolated is the same discipline as
                // `surfacesJSON()`'s dashboard read.
                let ok = MainActor.assumeIsolated {
                    (NSApp.delegate as? AppDelegate)?.setWebMonitorHidden(surfaceID: uuid, hidden: want) ?? false
                }
                guard ok else { return .status(503, "Service Unavailable") }
                return .json(Data(#"{"ok":true,"hidden":\#(want)}"#.utf8))
            }

        case .asset(let name, let ext, let contentType):
            clearAuthFailures(peer)
            // Vendored static file (xterm.js / xterm.css) read from the app
            // bundle. Pure file IO — no AppKit / surface access — so it stays
            // on the connection `queue` (no main-thread hop). A missing
            // resource (e.g. a build that did not bundle the vendor files) is a
            // 404 rather than a crash.
            send(Self.assetResponse(name: name, ext: ext, contentType: contentType), on: conn)

        case .serviceWorker:
            clearAuthFailures(peer)
            // The Web Push service worker. Pure static JS (no AppKit / surface
            // access), served like an asset on the connection queue.
            send(.asset(Data(Self.serviceWorkerJS.utf8), "text/javascript; charset=utf-8"), on: conn)

        case .pushConfig:
            clearAuthFailures(peer)
            // The page needs the VAPID public key (applicationServerKey) + the
            // current armed/muted state + whether THIS server already has any
            // subscription. push.* are self-serialized — no main hop.
            let json: [String: Any] = [
                "vapidPublicKey": push.vapidPublicKeyBase64,
                "enabled": push.isEnabled(),
                "subscriptions": push.subscriptionCount(),
            ]
            send(.json((try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)), on: conn)

        case .pushSubscribe:
            clearAuthFailures(peer)
            guard let sub = Self.pushSubscription(fromBody: req.body) else {
                send(.status(400, "Bad Request"), on: conn)
                return
            }
            push.addSubscription(sub)
            send(.json(Data(#"{"ok":true}"#.utf8)), on: conn)

        case .pushUnsubscribe:
            clearAuthFailures(peer)
            guard let endpoint = Self.pushEndpoint(fromBody: req.body) else {
                send(.status(400, "Bad Request"), on: conn)
                return
            }
            push.removeSubscription(endpoint: endpoint)
            send(.json(Data(#"{"ok":true}"#.utf8)), on: conn)

        case .pushEnabled:
            clearAuthFailures(peer)
            guard let on = Self.pushEnabledFlag(fromBody: req.body) else {
                send(.status(400, "Bad Request"), on: conn)
                return
            }
            push.setEnabled(on)
            send(.json(Data("{\"ok\":true,\"enabled\":\(on)}".utf8)), on: conn)
        }
    }

    // MARK: - Push request-body parsing (pure, testable)

    /// Parse a browser `PushSubscription` JSON (`{endpoint, keys:{p256dh,auth}}`,
    /// the shape of `PushSubscription.toJSON()`) into our value type. Returns nil
    /// if any required field is missing/empty. PURE.
    static func pushSubscription(fromBody body: Data) -> WebPushSubscription? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let endpoint = obj["endpoint"] as? String, !endpoint.isEmpty,
              let keys = obj["keys"] as? [String: Any],
              let p256dh = keys["p256dh"] as? String, !p256dh.isEmpty,
              let auth = keys["auth"] as? String, !auth.isEmpty else { return nil }
        return WebPushSubscription(endpoint: endpoint, p256dh: p256dh, auth: auth)
    }

    /// Parse `{endpoint:"…"}` (unsubscribe). PURE.
    static func pushEndpoint(fromBody body: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let endpoint = obj["endpoint"] as? String, !endpoint.isEmpty else { return nil }
        return endpoint
    }

    /// Parse `{enabled:true|false}` (the arm/mute toggle). PURE.
    static func pushEnabledFlag(fromBody body: Data) -> Bool? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let enabled = obj["enabled"] as? Bool else { return nil }
        return enabled
    }

    // MARK: - Streaming /stream route (raw PTY byte stream for xterm.js)

    /// The HTTP response head for a streaming `/stream` response: a 200 with an
    /// unbounded `application/octet-stream` body (NO Content-Length — the body
    /// runs until the connection closes) and `Connection: close`. PURE +
    /// `internal` so the exact wire bytes are unit-testable. Followed by raw
    /// byte chunks written directly onto the connection as they arrive from the
    /// host client (see `routeStream`).
    static func streamResponseHead(cols: UInt16, rows: UInt16) -> Data {
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: application/octet-stream\r\n"
        // The host terminal's grid size. The browser xterm.js MUST match it or
        // cursor-addressed output (TUIs like Claude Code) renders garbled. Read
        // by the page (same-origin, so the custom headers are readable).
        head += "X-Ghostty-Cols: \(cols)\r\n"
        head += "X-Ghostty-Rows: \(rows)\r\n"
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
    /// `ghostty_surface_session_id`, the config getter) happens inside a
    /// `DispatchQueue.main.async` that returns ONLY value types (a session id +
    /// the socket-path String) — never a surface pointer / SurfaceView across
    /// the hop. The hop is ASYNC (not `main.sync`) so the serial `queue` is not
    /// head-of-line-blocked during resolve; the streaming SETUP after it (which
    /// touches `queue`-only dicts) runs back on the connection `queue` via a
    /// `queue.async` continuation. That continuation's branching (liveness guard
    /// ⇒ abort; nil resolve ⇒ 404; missing pty-host ⇒ 501; otherwise proceed) is
    /// computed by the PURE, unit-tested `streamSetupDecision`; the liveness guard
    /// (`connectionRefs[key] != nil`) ensures a peer that disconnected mid-hop
    /// never leaks a host client. The host client's `onBytes`/`onClose` fire on
    /// ITS own background queue; they only call thread-safe `NWConnection`
    /// methods, so no further hop is needed.
    private func routeStream(uuid: UUID, on conn: NWConnection) {
        let key = ObjectIdentifier(conn)

        // De-blocked resolve hop (head-of-line fix): like the simple handlers
        // (see `respondFromMain`) we hop to main ASYNC so the serial `queue` is
        // not blocked for the whole resolve — but unlike them the streaming setup
        // AFTER resolve touches `queue`-only state (the timer/conn dicts,
        // `streamingConns`, `streamClients`) and so MUST run back on `queue`. So
        // the continuation hops back via `queue.async`. (Old code did the resolve
        // under `main.sync`, blocking `queue` throughout.)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Resolve session id + socket path on main (value types only).
            let resolved: StreamResolution? = {
                guard let view = self.surface(forUUID: uuid),
                      let surface = view.surface else { return nil }
                let sid = ghostty_surface_session_id(surface)
                let path = (NSApp.delegate as? AppDelegate)?.ghostty.config.ptyHost
                let size = ghostty_surface_size(surface)  // host grid, so xterm can match
                return StreamResolution(sessionID: sid, socketPath: path, cols: size.columns, rows: size.rows)
            }()

            self.queue.async {
                // The liveness guard, 404, 501 and proceed branching is computed by
                // the PURE `streamSetupDecision` (unit-tested), so only the side
                // effects live here. `connectionAlive` is `connectionRefs[key] !=
                // nil` — the authoritative on-`queue` liveness bit.
                //
                // Liveness guard (unique to routeStream): the peer may have
                // disconnected (or stop() may have torn down) DURING the main
                // resolve hop, in which case the .cancelled/.failed state handler
                // already ran on `queue` and dropped connectionRefs[key] /
                // streamClients / streamingConns. Without aborting we would
                // re-insert a streaming entry and start a host client for a dead
                // conn — a leaked host subscription that connects + subscribes
                // pointlessly. Under the old `main.sync` this window did not exist
                // because the queue was blocked throughout the hop. This is unique
                // to routeStream because ONLY routeStream creates a leakable
                // resource after the hop; the simple respondFromMain handlers
                // deliberately omit it (they create no such resource — see
                // respondFromMain's doc comment).
                switch Self.streamSetupDecision(
                    connectionAlive: self.connectionRefs[key] != nil, resolved: resolved) {
                case .abort:
                    return
                case .notFound:
                    self.send(.status(404, "Not Found"), on: conn)
                case .notImplemented:
                    // No pty-host configured -> the raw stream is unavailable. 501 so
                    // the page falls back to the /screen viewport poll, not a hang.
                    self.send(.status(501, "Not Implemented"), on: conn)
                case let .proceed(socketPath, sessionID, cols, rows):
                    self.startStream(on: conn, key: key, socketPath: socketPath,
                                     sessionID: sessionID, cols: cols, rows: rows)
                }
            }
        }
    }

    /// The side-effecting tail of `routeStream` once `streamSetupDecision`
    /// returns `.proceed`. Runs on `queue` (touches `streamingConns` /
    /// `streamClients` / the timer dicts). Split out so routeStream's body is the
    /// pure-decision switch above.
    private func startStream(on conn: NWConnection, key: ObjectIdentifier,
                             socketPath: String, sessionID: UInt64,
                             cols: UInt16, rows: UInt16) {
        // Enter streaming mode: this connection is long-lived, so exempt it from
        // BOTH watchdogs (they would otherwise cancel it mid-stream), and mark it
        // so teardown stays idempotent. We deliberately do NOT route this through
        // `send()` (that path writes a Content-Length body + cancels on
        // completion); instead we write the head, then raw chunks, ourselves.
        cancelConnectionTimer(key)
        streamingConns.insert(key)

        // Write the streaming HTTP head. On failure the connection is already
        // gone; the state handler will clean up.
        conn.send(content: Self.streamResponseHead(cols: cols, rows: rows),
                  completion: .contentProcessed { _ in })

        // Open the host client and pipe raw bytes onto the connection. onBytes /
        // onClose fire on the client's own background queue; NWConnection.send /
        // .cancel are thread-safe, so we call them directly. We hop to `queue`
        // for the dict cleanup in onClose to keep `streamClients`/`streamingConns`
        // single-threaded.
        let client = WebMonitorHostClient(
            socketPath: socketPath,
            sessionID: sessionID,
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
        let lower = h.lowercased()
        // Tailscale serve terminates TLS and forwards the ORIGINAL tailnet Host
        // — `<machine>.<tailnet>.ts.net:<external port>` — NOT a rewritten
        // loopback Host, and its external port deliberately differs from our
        // internal bind port. Reaching that endpoint already requires tailnet
        // membership (the Tailscale ACL is the access boundary, matching the
        // open-on-tailnet posture), and a DNS-rebinding attacker cannot make a
        // browser emit a `*.ts.net` Host against our loopback bind. So accept any
        // MagicDNS host on any port; the strict port + host check below still
        // guards the direct loopback / configured-host paths.
        if lower.hasSuffix(".ts.net") { return true }
        let port = portStr.flatMap { UInt16($0) } ?? 80
        guard port == configuredPort else { return false }
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
        /// NATIVE macOS virtual keycode. ghostty_input_key_s.keycode is matched
        /// against input.keycodes `entry.native` to resolve the physical key
        /// (embedded.zig KeyEvent.keyEvent), so this must be the platform keycode
        /// (NSEvent.keyCode space: Return=36, Esc=53, …), NOT a GHOSTTY_KEY_* enum
        /// value. 0 = none (text-bearing event; the char rides `text`).
        var keycode: UInt32
        var mods: ghostty_input_mods_e
        var text: String?
        var unshiftedCodepoint: UInt32

        init(
            keycode: UInt32 = 0,
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
            key_ev.keycode = keycode
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

    /// PURE: decode a scroll request body {"dy": <number>} into a wheel-tick
    /// delta (positive = scroll back / up). Clamped to a sane range; nil on bad
    /// input or a zero delta.
    static func scrollDeltaY(body: Data) -> Double? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let dy = (obj["dy"] as? NSNumber)?.doubleValue, dy != 0 else { return nil }
        return max(-30, min(30, dy))
    }

    /// PURE: whether a scroll request body asks to (re)seed the cursor position
    /// (`{"seed": true}`). The page sends this only on the FIRST scroll after opening
    /// a surface, so a mouse-reporting TUI's scroll accumulates instead of resetting
    /// on a move before every wheel (see the `.scroll` handler). Missing/false ⇒ no
    /// seed. Lenient like `hiddenFlag` (bool, 0/1, "true"/"false").
    static func scrollSeed(body: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let raw = obj["seed"] else { return false }
        if let b = raw as? Bool { return b }
        if let n = raw as? NSNumber { return n.boolValue }
        if let s = raw as? String { return s.lowercased() == "true" || s == "1" }
        return false
    }

    /// PURE: decode a hide request body `{"hidden": <bool>}` into the desired hide
    /// state. Accepts a JSON bool, or `0`/`1` / `"true"`/`"false"` for lenient
    /// clients; nil on missing/unparseable input.
    static func hiddenFlag(body: Data) -> Bool? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let raw = obj["hidden"] else { return nil }
        if let b = raw as? Bool { return b }
        if let n = raw as? NSNumber { return n.boolValue }
        if let s = raw as? String {
            switch s.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    /// NATIVE macOS virtual keycode (NSEvent.keyCode space — see KeySpec.keycode)
    /// for each lowercase letter, used by the general `ctrl-<letter>` rule in
    /// `keySpecs(forKey:)`. Read from `src/input/keycodes.zig` (the same table the
    /// core matches via `entry.native == keycode`); a GHOSTTY_KEY_* enum value here
    /// would silently no-op. `ctrl-c`=8 and `ctrl-u`=32 match the explicit cases.
    static let ctrlLetterKeycodes: [Character: UInt32] = [
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34,
        "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12,
        "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
    ]

    /// PURE: map a named key command to a single key-event spec. Unknown -> nil.
    /// Named keys carry a `ghostty_input_key_e` keycode (so Ghostty synthesizes
    /// the real keypress/escape sequence); `y`/`n` are just printable text.
    static func keySpecs(forKey key: String) -> [KeySpec]? {
        switch key {
        // NATIVE macOS virtual keycodes (NSEvent.keyCode space) — see KeySpec.keycode.
        case "enter": return [KeySpec(keycode: 36)]
        case "esc": return [KeySpec(keycode: 53)]
        case "tab": return [KeySpec(keycode: 48)]
        case "backspace": return [KeySpec(keycode: 51)]
        case "ctrl-c": return [KeySpec(keycode: 8, mods: GHOSTTY_MODS_CTRL,
                                       unshiftedCodepoint: UInt32(UnicodeScalar("c").value))]
        case "ctrl-u": return [KeySpec(keycode: 32, mods: GHOSTTY_MODS_CTRL,
                                       unshiftedCodepoint: UInt32(UnicodeScalar("u").value))]
        case "up": return [KeySpec(keycode: 126)]
        case "down": return [KeySpec(keycode: 125)]
        case "left": return [KeySpec(keycode: 123)]
        case "right": return [KeySpec(keycode: 124)]
        // Page/Home/End — used by smartScroll for alt-screen TUIs (less/man/vim)
        // that own the screen and have no scrollback to wheel through. Native
        // macOS virtual keycodes: PageUp=116, PageDown=121, Home=115, End=119.
        case "pageup": return [KeySpec(keycode: 116)]
        case "pagedown": return [KeySpec(keycode: 121)]
        case "home": return [KeySpec(keycode: 115)]
        case "end": return [KeySpec(keycode: 119)]
        case "y": return keySpecs(forText: "y")
        case "n": return keySpecs(forText: "n")
        // Space is a plain printable 0x20 — same byte a Space keypress sends, and
        // useful in Claude Code (toggle/confirm). Ride the text path like y/n.
        case "space": return keySpecs(forText: " ")
        default:
            // General ctrl-<letter> rule (ctrl-a, ctrl-d, ctrl-z, …) beyond the
            // explicit ctrl-c/ctrl-u above — the desktop client needs the full set
            // of terminal control keys. A Ctrl-modified letter key event carrying
            // the letter's NATIVE macOS virtual keycode + its unshifted scalar.
            // Only a single a-z letter maps; any other `ctrl-…` combo returns nil
            // (a 400 at the route, unchanged).
            if key.hasPrefix("ctrl-") {
                let rest = key.dropFirst(5)
                if rest.count == 1, let ch = rest.first,
                   let keycode = ctrlLetterKeycodes[ch], let ascii = ch.asciiValue {
                    return [KeySpec(keycode: keycode, mods: GHOSTTY_MODS_CTRL,
                                    unshiftedCodepoint: UInt32(ascii))]
                }
            }
            return nil
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
        // Coalesce consecutive printable characters into ONE multi-char text
        // event. Sending each character as its own press+release floods the
        // core's fixed 64-slot IO mailbox (src/termio/mailbox.zig): a ~60-char
        // message is 120 messages, so the MIDDLE silently overflows and is
        // dropped (you see only the head + tail). A printable run rides a single
        // event's `text`, which the core writes verbatim to the PTY (the legacy
        // encoder's `writeAll(utf8)` — NOT the clipboard/paste path), so a long
        // message is 1-2 messages instead of 120. Newlines stay REAL Return
        // keypresses (so each submits) and therefore break a run.
        var specs: [KeySpec] = []
        var run = ""
        func flushRun() {
            guard !run.isEmpty else { return }
            // Keep the single-char shape (unshiftedCodepoint set) byte-identical
            // to before so quick keys like y/n are unchanged; a multi-char run
            // can't carry one scalar, so leave it 0 (the char rides `text`).
            let scalars = Array(run.unicodeScalars)
            let usc: UInt32 = scalars.count == 1 ? scalars[0].value : 0
            specs.append(KeySpec(text: run, unshiftedCodepoint: usc))
            run = ""
        }
        for ch in text {
            if ch == "\n" || ch == "\r" {
                flushRun()
                specs.append(KeySpec(keycode: 36))  // native macOS Return
            } else {
                run.append(ch)
            }
        }
        flushRun()
        return specs
    }

    // MARK: - Main-thread helpers (AppKit / surface access)

    /// Replicates AppDelegate.findSurface(forUUID:). MUST be called on main.
    private func surface(forUUID uuid: UUID) -> Ghostty.SurfaceView? {
        return controllerAndView(forUUID: uuid)?.view
    }

    /// Find the tab controller + surface view that own a UUID. MUST be called on
    /// main. We need the controller (not just the view) so input/scroll handlers
    /// can reveal a surface that's hidden under a zoom (see `revealIfZoomedAway`).
    private func controllerAndView(forUUID uuid: UUID)
        -> (controller: TerminalController, view: Ghostty.SurfaceView)? {
        for c in TerminalController.all {
            for view in c.surfaceTree where view.id == uuid {
                return (c, view)
            }
        }
        return nil
    }

    /// If `view` is hidden because its tab is zoomed to a DIFFERENT split,
    /// un-zoom the tab so the surface re-mounts and starts receiving size
    /// updates again. A zoomed-away SurfaceView is removed from the view
    /// hierarchy, so SwiftUI stops calling `updateOSView` → the surface keeps a
    /// stale/zero cell size and scroll/key events routed by UUID silently no-op.
    /// Revealing it (the same `SplitTree(root:zoomed:)` reset the zoom toggle
    /// uses) is also the intuitive result of driving a split from the phone.
    /// No-op when the tab isn't zoomed or the target is the zoomed split itself.
    /// MUST be called on main.
    private func revealIfZoomedAway(_ controller: TerminalController, _ view: Ghostty.SurfaceView) {
        let tree = controller.surfaceTree
        guard tree.zoomed != nil else { return }
        // Inside the zoomed subtree already? Then it's visible + sized — leave it.
        if tree.zoomedLeaves().contains(where: { $0.id == view.id }) { return }
        controller.surfaceTree = .init(root: tree.root, zoomed: nil)
    }

    /// One surface, enriched with its place in the window/tab/split layout so
    /// the phone list can show how panes are organized on the Mac. PURE value
    /// type — populated on main, shaped to JSON by `surfacesJSONData` (testable).
    struct SurfaceRow {
        let id: String
        let title: String
        let pwd: String
        /// Window-group index in encounter order (each AppKit tab group = one
        /// "window"; standalone windows each get their own index).
        let window: Int
        /// Tab index WITHIN the window group (visual tab order from the tab group).
        let tab: Int
        /// The tab/window title (usually mirrors the active pane).
        let tabTitle: String
        /// This pane's position among its tab's splits (DFS leaf order) and the
        /// tab's total split count, so the UI can badge "split 2/3".
        let splitIndex: Int
        let splitCount: Int
        /// True when this surface has an active (unacknowledged) bell, so the
        /// phone can flag it and offer to clear it (POST .../bell).
        let bell: Bool
        /// (ramon fork / Bell Attention v2) True when this surface has the sticky
        /// promoted "attention needed" state (set by the Agent Manager via set_attention).
        /// Surfaced DISTINCTLY from `bell` (P5) so the phone shows both and can clear the
        /// attention independently (POST .../attention).
        let attentionNeeded: Bool
        /// (ramon fork) True iff the Agent Dashboard's detector matched this surface
        /// as a CLI agent. Only meaningful when the dashboard is running (see the
        /// top-level `agentDashboard` flag); false otherwise. Drives the page's
        /// "agents only" filter.
        let isAgent: Bool
        /// (ramon fork) True iff the user has hidden this surface in the Agent
        /// Dashboard. Only meaningful when the dashboard is running. Drives the
        /// page's "hide hidden" filter.
        let hidden: Bool
        /// (ramon fork / Hero Agents) True iff this surface is a HERO (`queueHero`). Only
        /// meaningful when the dashboard is running. Drives the page's purple-star mark +
        /// the "Focus on heroes" filter. Defaulted so existing `SurfaceRow(...)` call sites
        /// (tests) that predate heroes still compile.
        var hero: Bool = false
    }

    /// MUST be called on main. Iterates AppKit surfaces (thin) and defers the
    /// pure dict/JSON shaping to `surfacesJSONData` so the shaping is testable.
    /// Each `TerminalController` is one tab; its `surfaceTree` is that tab's
    /// split layout — so we group by the window's tab group and number the tabs.
    private func surfacesJSON() -> Data {
        var rows: [SurfaceRow] = []
        // (ramon fork) Pull the Agent Dashboard's agent/hidden sets so the page can
        // offer "agents only" / "hide hidden" filters mirroring the dashboard. The
        // controller's existence == "the dashboard is running"; when it's nil the
        // page disables the filters. Value types only. `webMonitorFilterState()` is
        // @MainActor (the controller is); `surfacesJSON()` is always invoked on the
        // main hop (see the `.surfacesList` handler), so `assumeIsolated` is sound —
        // matching MCPLayout.surfaceRows' on-main contract.
        let filter: (agents: Set<UUID>, hidden: Set<UUID>, hero: Set<UUID>)? =
            MainActor.assumeIsolated {
                (NSApp.delegate as? AppDelegate)?.agentDashboard?.webMonitorFilterState()
            }
        let dashboardRunning = filter != nil
        // Assign a stable window-group index per tab group (or standalone window)
        // in the order we first encounter it.
        var groupIndex: [ObjectIdentifier: Int] = [:]
        func windowIndex(_ c: TerminalController) -> Int {
            let key: ObjectIdentifier
            if let tg = c.window?.tabGroup { key = ObjectIdentifier(tg) }
            else if let w = c.window { key = ObjectIdentifier(w) }
            else { return 0 }
            if let i = groupIndex[key] { return i }
            let i = groupIndex.count
            groupIndex[key] = i
            return i
        }
        for c in TerminalController.all {
            let win = windowIndex(c)
            let tabIdx: Int
            if let tg = c.window?.tabGroup, let w = c.window,
               let idx = tg.windows.firstIndex(of: w) {
                tabIdx = idx
            } else {
                tabIdx = 0
            }
            let tabTitle = c.window?.title ?? ""
            let leaves = Array(c.surfaceTree)
            for (splitIdx, view) in leaves.enumerated() {
                rows.append(SurfaceRow(
                    id: view.id.uuidString, title: view.title, pwd: view.pwd ?? "",
                    window: win, tab: tabIdx, tabTitle: tabTitle,
                    splitIndex: splitIdx, splitCount: leaves.count, bell: view.bell,
                    attentionNeeded: view.attentionNeeded,
                    isAgent: filter?.agents.contains(view.id) ?? false,
                    hidden: filter?.hidden.contains(view.id) ?? false,
                    hero: filter?.hero.contains(view.id) ?? false))
            }
        }
        return Self.surfacesJSONData(
            rows, agentDashboard: dashboardRunning,
            monitorBell: monitorBell, monitorAttn: monitorAttn)
    }

    /// Pure JSON shaping for the surfaces list (testable; no AppKit). Returns an
    /// OBJECT `{agentDashboard: Bool, surfaces: [...]}` — `agentDashboard` tells the
    /// page whether the Agent Dashboard is running (and thus whether the agent/hidden
    /// filters are usable); `surfaces` is the per-row array. Each row's `isAgent` /
    /// `hidden` are only meaningful when `agentDashboard` is true.
    ///
    /// (ramon fork / Bell Attention v2) Each row also carries the raw `bell` +
    /// `attentionNeeded` (truthful — principle F) and a `attnIndicator` boolean: the
    /// monitor-tier-routed "show an alert flag" = (bell && monitorBell) ||
    /// (attentionNeeded && monitorAttn), where monitorBell/monitorAttn are the `monitor`
    /// flag of bell-features / attention-features. Default config (both true) ⇒
    /// `bell || attentionNeeded` (reproduces today + surfaces promotions). The page
    /// renders the flag off `attnIndicator` so the `monitor` effect is config-routable.
    static func surfacesJSONData(
        _ rows: [SurfaceRow], agentDashboard: Bool,
        monitorBell: Bool = true, monitorAttn: Bool = true
    ) -> Data {
        let arr: [[String: Any]] = rows.map {
            [
                "id": $0.id, "title": $0.title, "pwd": $0.pwd,
                "window": $0.window, "tab": $0.tab, "tabTitle": $0.tabTitle,
                "splitIndex": $0.splitIndex, "splitCount": $0.splitCount,
                "bell": $0.bell, "attentionNeeded": $0.attentionNeeded,
                "attnIndicator": ($0.bell && monitorBell) || ($0.attentionNeeded && monitorAttn),
                "isAgent": $0.isAgent, "hidden": $0.hidden, "hero": $0.hero,
            ]
        }
        let obj: [String: Any] = ["agentDashboard": agentDashboard, "surfaces": arr]
        return (try? JSONSerialization.data(withJSONObject: obj))
            ?? Data("{\"agentDashboard\":false,\"surfaces\":[]}".utf8)
    }

    /// Whether a cached-at timestamp is still fresh at `now` for the given TTL.
    /// PURE + `internal` so the cache-freshness boundary is unit-testable without
    /// AppKit or wall-clock racing. (`at == nil` ⇒ never fresh; strict `<`.)
    static func surfacesCacheFresh(at: Date?, now: Date, ttl: TimeInterval = surfacesCacheTTL) -> Bool {
        guard let at else { return false }
        return now.timeIntervalSince(at) < ttl
    }

    /// Pure read-side of the `.surfacesList` cache: returns the cached bytes when the
    /// entry exists AND is still fresh at `now` (a cache HIT, no main hop needed), or
    /// `nil` when the cache is empty or stale (a MISS ⇒ the handler must rebuild on
    /// main). `internal` so the hit/miss decision is unit-testable without AppKit; the
    /// handler calls this on `queue` and never touches `cachedSurfaces` off `queue`.
    static func cachedSurfacesData(_ cache: (data: Data, at: Date)?, now: Date, ttl: TimeInterval = surfacesCacheTTL) -> Data? {
        guard let cache, surfacesCacheFresh(at: cache.at, now: now, ttl: ttl) else { return nil }
        return cache.data
    }

    // MARK: - /stream post-hop decision (pure)

    /// The value-type result of resolving a surface for `/stream` on the main
    /// thread: the host session id + socket path + host grid. Only value types,
    /// so it crosses the main hop safely (never a surface / SurfaceView). Lifted
    /// from a local struct to type scope so `streamSetupDecision` (and its unit
    /// tests) can name it.
    struct StreamResolution: Equatable {
        let sessionID: UInt64
        let socketPath: String?
        let cols: UInt16
        let rows: UInt16
    }

    /// What the post-hop continuation must do once it is back on `queue` after
    /// the async resolve. Pure + `Equatable` so the genuinely-new branching
    /// (liveness guard ⇒ abort; nil resolve ⇒ 404; missing pty-host ⇒ 501;
    /// otherwise proceed to open the host client) is unit-testable WITHOUT
    /// AppKit / a real NWConnection.
    enum StreamSetupDecision: Equatable {
        /// The peer disconnected (or `stop()` tore down) DURING the main resolve
        /// hop — `connectionRefs[key]` is gone. Do nothing: opening a host client
        /// now would leak a pointless subscription for a dead conn.
        case abort
        /// Surface gone / has no live surface ⇒ 404.
        case notFound
        /// No pty-host configured ⇒ 501 so the page falls back to the /screen poll.
        case notImplemented
        /// Live conn + a usable session ⇒ open the host client with these params.
        case proceed(socketPath: String, sessionID: UInt64, cols: UInt16, rows: UInt16)
    }

    /// PURE decision for routeStream's post-hop continuation. `connectionAlive`
    /// is `connectionRefs[key] != nil` (the authoritative on-`queue` liveness
    /// bit); `resolved` is the value-type resolve result from the main hop. This
    /// mirrors EXACTLY the guard chain the on-`queue` continuation runs, so the
    /// liveness/404/501/proceed branching is testable in isolation. The handler
    /// still PERFORMS the side effects (insert streamingConns, start the client)
    /// — this only computes WHICH branch to take.
    static func streamSetupDecision(connectionAlive: Bool, resolved: StreamResolution?) -> StreamSetupDecision {
        guard connectionAlive else { return .abort }
        guard let resolved else { return .notFound }
        guard let socketPath = resolved.socketPath, !socketPath.isEmpty else { return .notImplemented }
        return .proceed(socketPath: socketPath, sessionID: resolved.sessionID,
                        cols: resolved.cols, rows: resolved.rows)
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

    /// Compute a value-type `HTTPResponse` on the MAIN thread (AppKit / surface
    /// access), then hop BACK to the connection `queue` to `send` it. This is the
    /// async analog of the old `let r = DispatchQueue.main.sync { … }; send(r, …)`
    /// pattern: it does NOT block the serial `queue` during the (potentially
    /// multi-second, under SwiftUI load) main hop, so other connections — notably
    /// static assets that need nothing from main — are serviced immediately
    /// instead of queueing head-to-tail behind it (the head-of-line-blocking fix).
    ///
    /// CONTRACT for `work` (load-bearing — a future handler added via this helper
    /// MUST honor it): `work` runs on MAIN and may touch ONLY AppKit / global
    /// state (`TerminalController.all`, `SurfaceView`, `ghostty_surface_*`). It
    /// must NEVER read or mutate server `queue`-only state (`cachedSurfaces`,
    /// `streamClients`, `streamingConns`, the timer dicts, `failedAuth`) — that
    /// state is single-threaded on `queue` and `work` is on main. (The cache-build
    /// path in `.surfacesList` obeys this: it touches `self.cachedSurfaces` only
    /// AFTER the post-hop `guard let self` re-entry on `queue`, never inside the
    /// main block.) Only a value type (`HTTPResponse`) crosses the hop — never a
    /// surface / SurfaceView. `send` still runs on `queue`, so all timer/conn dict
    /// access inside it stays serialized.
    ///
    /// LIFECYCLE — the single genuinely new property vs. the old synchronous chain:
    /// because `send` now runs from a `queue.async` continuation scheduled AFTER
    /// the main hop, the connection's `stateUpdateHandler(.cancelled)` or `stop()`'s
    /// teardown can run on `queue` BETWEEN the dispatch and this continuation. That
    /// is SAFE here: these simple handlers create NO leakable resource (no
    /// `WebMonitorHostClient`, no `streamingConns` insert), so a `send` to an
    /// already-cancelled NWConnection just fails harmlessly and
    /// `cancelConnectionTimer` inside `send` no-ops on the already-emptied dicts.
    /// (routeStream is the EXCEPTION — it DOES create a leakable resource and so
    /// needs an explicit liveness guard; see routeStream's `guard connectionRefs`.
    /// Do NOT add that guard here, and do NOT remove it there.)
    ///
    /// `work` retains `self` for the duration of the main hop (it references e.g.
    /// `self.surface(forUUID:)`), exactly as the old `main.sync` closures did. The
    /// `[weak self]` below only governs the post-hop `queue` re-entry: if the
    /// server was torn down during the hop we drop the `send`.
    private func respondFromMain(on conn: NWConnection, _ work: @escaping () -> HTTPResponse) {
        DispatchQueue.main.async { [weak self] in
            let response = work()
            guard let self else { return }
            self.queue.async { self.send(response, on: conn) }
        }
    }

    // MARK: - Web Push service worker

    // The service worker that receives background push messages and shows the
    // notification — runs even with the tab closed / phone locked (the whole
    // point). It needs NO token: it never calls our API, it only renders the
    // push payload the OS hands it. On tap it focuses an existing monitor tab
    // (which still holds its sessionStorage token) or opens the page. Served at
    // `/sw.js` (a bootstrap route, so the register() fetch may carry `?token=`).
    static let serviceWorkerJS = """
    self.addEventListener('push', function (event) {
      var data = {};
      try { data = event.data ? event.data.json() : {}; } catch (e) {}
      var title = data.title || 'Ghostty';
      var opts = {
        body: data.body || '',
        tag: data.surface || 'ghostty-bell',
        renotify: true,
        data: { surface: data.surface || '' }
      };
      event.waitUntil(self.registration.showNotification(title, opts));
    });
    self.addEventListener('notificationclick', function (event) {
      event.notification.close();
      event.waitUntil(
        clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function (cls) {
          for (var i = 0; i < cls.length; i++) {
            if ('focus' in cls[i]) { return cls[i].focus(); }
          }
          if (clients.openWindow) { return clients.openWindow('/'); }
        })
      );
    });
    """

    // MARK: - Embedded HTML page
    //
    // The SINGLE responsive, capability-adaptive web client, served at GET "/" to
    // BOTH phone and desktop. Layout is responsive off ONE state machine (a
    // `data-view` attribute on #app): a PERSISTENT surface-picker sidebar beside
    // the viewer on a wide screen (>=860px, selecting a surface swaps the viewer
    // without hiding the list), collapsing to a full-width drawer with a back/menu
    // control on a narrow one (<860px, the phone behavior). Capabilities are
    // FEATURE-DETECTED, never guessed from the viewport: browser copy/paste is
    // gated on a secure context + navigator.clipboard (Send-field fallback), and
    // the global keydown driver that maps browser keystrokes to real key events
    // attaches UNIVERSALLY (inert without a physical keyboard, bails inside typing
    // fields / focused controls). Renders a surface in full color via the vendored
    // xterm.js fed the host's raw PTY byte stream; the frame-mode scroll,
    // reconnect-on-refocus resync, and the bell->Web-Push notifier are universal.
    // Keyboard fidelity for non-text keys assumes a Mac client with a standard
    // layout (native macOS keycodes; printable text still works off-Mac). See
    // WEB-MONITOR.md + DESKTOP-MONITOR-DESIGN.md. Not `private` so the page can be
    // asserted on in unit tests.
    static let htmlPage = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, interactive-widget=resizes-content">
    <title>Ghostty Web Monitor</title>
    <style>
      /* Theme-aware CHROME only: the terminal colors come from the host's ANSI
         stream (xterm.js), so the terminal itself is never theme-toggled — only
         the surrounding sidebar/header/banners. Dark is the default; a light
         media block overrides the chrome variables. */
      :root {
        --bg: #11131a; --panel: #1b1e27; --panel2: #161922; --border: #2a2e3b;
        --fg: #d6dae3; --muted: #8b93a7; --accent: #f0a35e; --termbg: #0c0e13;
        --inputbg: #0c0e13;
        --rowbg: #1b1e27; --active: #2b3550; --activeborder: #4a8fe7;
        color-scheme: dark;
      }
      @media (prefers-color-scheme: light) {
        :root {
          --bg: #f4f6f9; --panel: #ffffff; --panel2: #eef1f6; --border: #d3d8e2;
          --fg: #1b2029; --muted: #66707f; --accent: #b46418; --termbg: #0c0e13;
          --inputbg: #ffffff;
          --rowbg: #ffffff; --active: #dbe6fb; --activeborder: #3b7fe0;
          color-scheme: light;
        }
      }
      * { box-sizing: border-box; }
      html, body { height: 100%; }
      /* Whole page is a flex column: always-visible banner/notice chrome at the
         top, then the flex-fill #app. The banners live OUTSIDE #app (not inside
         #main) so a status message / token-recovery notice stays visible in EVERY
         layout state — including the narrow list-view drawer, where #main is
         display:none. */
      body { margin: 0; background: var(--bg); color: var(--fg);
             font-family: "JetBrains Mono", ui-monospace, Menlo, monospace; font-size: 14px;
             display: flex; flex-direction: column; }
      button, input, select { font-family: inherit; font-size: 14px; }
      button { background: var(--panel); color: var(--fg); border: 1px solid var(--border);
               border-radius: 6px; padding: 7px 10px; cursor: pointer; }
      button:hover { border-color: var(--accent); }
      button:active { background: var(--border); }
      button:disabled { opacity: 0.45; cursor: not-allowed; pointer-events: none; }
      button.danger { margin-left: 12px; background: #5a2a2a; color: #ffd9d9; border-color: #7a3a3a; }
      button.danger:active { background: #7a3a3a; }
      /* Local tap-ack flash (~150ms, added/removed by flashTap): a quick-key tap
         registers visibly independent of the network round-trip, so it's felt even on
         a high-latency mobile connection (button:active only covers finger-down, not
         the post-release ack / repeat pulses). Fixed colors read on both themes. */
      button.tapped { background: #4a8fe7; color: #fff; border-color: #4a8fe7; }
      button.danger.tapped { background: #c25555; color: #fff; border-color: #c25555; }
      /* Whole-window flex: fixed sidebar + flex-fill viewer. Responsive off the
         #app `data-view` state (see the narrow media query at the end): wide keeps
         both panes; narrow shows only one. min-width:0 lets it collapse cleanly on
         a phone (the narrow breakpoint drives the drawer). */
      #app { display: flex; flex: 1 1 auto; min-width: 0; min-height: 0; overflow-x: hidden; }
      /* ---- Sidebar (persistent surface picker) ---------------------------- */
      #sidebar { flex: 0 0 268px; width: 268px; min-width: 268px; display: flex;
                 flex-direction: column; background: var(--panel2);
                 border-right: 1px solid var(--border); overflow: hidden; }
      #sidehdr { display: flex; gap: 8px; align-items: center; padding: 11px 12px;
                 background: var(--panel); border-bottom: 1px solid var(--border); }
      #sidehdr b { color: var(--accent); flex: 1 1 auto; min-width: 0; overflow: hidden;
                   text-overflow: ellipsis; white-space: nowrap; }
      #notify { flex: 0 0 auto; padding: 6px 9px; }
      #notify.armed { background: #4a3a1a; border-color: var(--accent); color: #f0c060; }
      /* Same three agent filters as the phone (localStorage-persisted): heroes
         focus, agents-only, hide-hidden. Greyed when the dashboard isn't running. */
      #filterbar { display: flex; gap: 12px; align-items: center; flex-wrap: wrap;
                   padding: 9px 12px; border-bottom: 1px solid var(--border); }
      #filterbar label { display: inline-flex; gap: 6px; align-items: center; color: var(--muted);
                         font-size: 13px; user-select: none; -webkit-user-select: none; }
      #filterbar input[type=checkbox] { width: 15px; height: 15px; accent-color: var(--accent); }
      #filterbar.disabled { opacity: 0.5; }
      #filterbar label.herofocus { color: #b18cff; font-weight: 600; }
      #filterbar input#f-heroes { accent-color: #b18cff; }
      .herostar { color: #b18cff; margin-right: 3px; }
      #filternote { color: var(--muted); font-size: 11px; flex: 1 1 100%; }
      #tokenrecovery { display: none; padding: 10px 12px; border-bottom: 1px solid var(--border); }
      #tokenrecovery input[type=text] { width: 100%; background: var(--inputbg); color: var(--fg);
        border: 1px solid var(--border); border-radius: 6px; padding: 8px; margin-bottom: 6px; }
      #list { flex: 1 1 auto; overflow-y: auto; padding: 8px; }
      .grouphdr { padding: 10px 4px 5px; margin-top: 8px; border-bottom: 1px solid var(--border); }
      .grouphdr:first-child { margin-top: 0; }
      .grouphdr .loc { color: var(--muted); font-size: 10px; font-weight: bold; letter-spacing: .04em;
                       text-transform: uppercase; }
      .grouphdr .ttl { color: var(--fg); font-size: 12px; margin-top: 2px; word-break: break-word; }
      .row { position: relative; padding: 9px 10px; margin: 5px 0; background: var(--rowbg);
             border: 1px solid var(--border); border-left: 3px solid var(--border); border-radius: 7px;
             cursor: pointer; }
      .row:hover { border-color: var(--accent); }
      /* The row of the surface shown in the viewer is highlighted so the picker
         always tells you what you're driving. */
      .row.active { background: var(--active); border-color: var(--activeborder);
                    border-left-color: var(--activeborder); }
      .row.ishidden { opacity: 0.55; }
      .row .t { color: var(--fg); font-weight: bold; padding-right: 46px; font-size: 13px;
                word-break: break-word; }
      .row .hidebtn { position: absolute; top: 8px; right: 8px; padding: 2px 8px; border-radius: 6px;
                      background: var(--panel); border: 1px solid var(--border); color: var(--muted);
                      font-size: 11px; }
      .row .badge { display: inline-block; margin-left: 6px; padding: 1px 6px; border-radius: 10px;
                    background: var(--panel); color: var(--muted); font-size: 10px; font-weight: normal;
                    vertical-align: middle; }
      .row .bellflag { margin-left: 6px; font-size: 12px; vertical-align: middle; }
      .row .p { color: var(--muted); font-size: 11px; margin-top: 3px; word-break: break-all; }
      .empty { padding: 12px; color: var(--muted); }
      /* ---- Main viewer ---------------------------------------------------- */
      #main { flex: 1 1 auto; min-width: 0; display: flex; flex-direction: column; }
      /* flex-wrap so the header's fixed children (menu + mac-layout note + Copy +
         Clear) wrap onto a second line rather than overflowing the page body
         sideways on a narrow viewport (the note is also hidden on narrow below). */
      #viewhdr { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; padding: 9px 12px;
                 background: var(--panel); border-bottom: 1px solid var(--border); }
      /* Back/menu control — hidden on wide (the sidebar is always present), shown
         only inside the narrow media query where it reopens the sidebar drawer. */
      #menubtn { display: none; flex: 0 0 auto; }
      #cur { flex: 1 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis;
             white-space: nowrap; color: var(--fg); font-weight: bold; }
      #copybtn { flex: 0 0 auto; }
      #clearbell, #clearattn { flex: 0 0 auto; background: #4a3a1a; border-color: #6a5320; color: #f0c060; }
      #clearbell:active, #clearattn:active { background: #6a5320; }
      #banner { display: none; padding: 7px 12px; background: #5a2a2a; color: #ffd9d9; text-align: center; }
      #banner.ok { background: #2a4a2a; color: #d9ffd9; }
      #notice { display: none; padding: 9px 12px; background: #4a3a1a; color: #f0c060; }
      #screenwrap { position: relative; flex: 1 1 auto; min-height: 0; padding: 8px; }
      /* xterm.js live terminal — the primary view. The <pre id="screen"> poll
         viewer is the fallback when xterm.js is missing or /stream is unavailable. */
      #xterm { display: none; height: 100%; background: var(--termbg); padding: 8px;
               border-radius: 8px; overflow: auto; }
      #screen { display: none; white-space: pre; background: var(--termbg); color: var(--fg);
                padding: 10px; border-radius: 8px; height: 100%; margin: 0;
                overflow-x: auto; overflow-y: auto; }
      #placeholder { display: flex; height: 100%; align-items: center; justify-content: center;
                     color: var(--muted); text-align: center; padding: 20px; }
      #jumpbottom { display: none; position: absolute; right: 22px; bottom: 18px; z-index: 1;
        width: 34px; height: 34px; padding: 0; line-height: 1; border-radius: 17px; opacity: 0.85;
        background: var(--panel); border: 1px solid var(--border); color: var(--accent); font-size: 18px; }
      #livebtn { display: none; position: absolute; right: 22px; bottom: 18px; z-index: 2;
        padding: 7px 13px; border-radius: 17px; opacity: 0.92;
        background: var(--panel); border: 1px solid var(--border); color: var(--accent); font-size: 13px; }
      .bar { display: flex; gap: 6px; padding: 8px 12px; flex-wrap: wrap; align-items: center;
             border-top: 1px solid var(--border); }
      .bar input[type=text] { flex: 1; min-width: 160px; background: var(--inputbg); color: var(--fg);
             border: 1px solid var(--border); border-radius: 6px; padding: 8px; }
      .bar label { color: var(--muted); font-size: 12px; }
      /* ---- Narrow (phone) breakpoint -------------------------------------- */
      /* Below 860px the two panes become mutually exclusive, driven by #app's
         `data-view` state: data-view="list" shows the full-width sidebar (the
         picker) and hides the viewer; data-view="surface" hides the sidebar and
         gives the viewer the whole screen (today's phone behavior). The #menubtn
         back control reopens the picker. `dvh` sizes #app to the DYNAMIC viewport
         so the flex-fill terminal tracks the soft keyboard instead of being shoved
         off-screen (vh is the fallback for engines without dvh). */
      @media (max-width: 859px) {
        body { height: 100vh; height: 100dvh; }
        #sidebar { flex-basis: 100%; width: 100%; min-width: 0; border-right: none; }
        #main { display: none; }
        #app[data-view="surface"] #sidebar { display: none; }
        #app[data-view="surface"] #main { display: flex; }
        #menubtn { display: inline-block; }
      }
    </style>
    </head>
    <body>
    <!-- Always-visible chrome (top-level, OUTSIDE #app) — a status banner and a
         role=alert notice (token recovery). Kept out of #main so they stay visible
         in every layout state, including the narrow list-view drawer where #main is
         hidden. -->
    <div id="banner" role="status" aria-live="polite"></div>
    <div id="notice" class="notice" role="alert" aria-live="assertive"></div>
    <div id="app" data-view="list">
      <aside id="sidebar">
        <div id="sidehdr">
          <b>Ghostty Web Monitor</b>
          <!-- Push-on-bell toggle (reuses the phone's push routes verbatim). -->
          <button id="notify" aria-label="Notify on bell"
                  title="Push a notification to this device when any split rings a bell">&#128276;</button>
        </div>
        <!-- Same three filters as the phone list (localStorage-persisted). -->
        <div id="filterbar">
          <label class="herofocus"><input type="checkbox" id="f-heroes"> &#9733; Focus on heroes</label>
          <label><input type="checkbox" id="f-agents"> Agents only</label>
          <label><input type="checkbox" id="f-visible"> Hide hidden</label>
          <span id="filternote"></span>
        </div>
        <div id="tokenrecovery">
          <input id="tokeninput" type="text" placeholder="Paste token"
                 autocapitalize="off" autocorrect="off" autocomplete="off"
                 spellcheck="false" inputmode="text" enterkeyhint="go" aria-label="Token">
          <button id="tokenconnect">Connect</button>
        </div>
        <div id="list"></div>
      </aside>
      <main id="main">
        <header id="viewhdr">
          <!-- Narrow-layout back/menu: reopens the sidebar drawer. CSS-hidden on
               wide (the sidebar is always present there). -->
          <button id="menubtn" title="Back to the session list">&larr; Sessions</button>
          <span id="cur"></span>
          <button id="copybtn" title="Copy the terminal selection (or use &#8984;C)">Copy</button>
          <button id="clearbell" style="display:none"
                  title="Acknowledge/clear the bell for this split (it can ring again later)">&#128276; Clear</button>
          <button id="clearattn" style="display:none"
                  title="Acknowledge/clear the &quot;needs you&quot; state for this split">&#128276; Clear</button>
        </header>
        <div id="screenwrap">
          <div id="xterm"></div>
          <pre id="screen"></pre>
          <div id="placeholder">Select a split from the sidebar to drive it here.</div>
          <button id="jumpbottom" title="Jump to live bottom" aria-label="Jump to live bottom">&#x2193;</button>
          <button id="livebtn" style="display:none" title="Return to live view">&#x25cf; Live</button>
        </div>
        <!-- Poll-fallback controls (only drive the <pre id="screen"> poll viewer;
             hidden while the live xterm stream is active). -->
        <div class="bar" id="modebar" style="display:none">
          <label for="mode">View</label>
          <select id="mode" aria-label="Screen view mode">
            <option value="viewport">Viewport</option>
            <option value="scrollback">Scrollback</option>
          </select>
          <button id="refresh">Refresh</button>
        </div>
        <!-- On-screen quick-key row: a fallback for keystrokes the browser/OS eats
             (⌘-combos, some function keys) so no action is stranded (like the phone). -->
        <div class="bar">
          <button data-key="enter">Enter</button>
          <button data-key="space">Space</button>
          <button data-key="y">y</button>
          <button data-key="n">n</button>
          <button data-key="esc">Esc</button>
          <button data-key="tab">Tab</button>
          <button data-key="backspace" title="Backspace / delete char">&#9003;</button>
          <button data-key="ctrl-u" title="Clear line (Ctrl-U)">Clear</button>
          <button data-key="ctrl-c" class="danger">Ctrl-C</button>
          <button data-key="up" aria-label="Up">&uarr;</button>
          <button data-key="down" aria-label="Down">&darr;</button>
          <button data-key="left" aria-label="Left">&larr;</button>
          <button data-key="right" aria-label="Right">&rarr;</button>
          <button id="scrollup" title="Scroll up (real wheel to the app; paints the host frame)">&#8679; Scroll</button>
          <button id="scrolldown" title="Scroll down (real wheel to the app; paints the host frame)">&#8681; Scroll</button>
        </div>
        <div class="bar">
          <input id="inp" type="text" placeholder="type a reply, then Send (or just type on the terminal directly)"
                 autocapitalize="off" autocorrect="off" autocomplete="off"
                 spellcheck="false" inputmode="text" enterkeyhint="send"
                 aria-label="Input to send to the terminal">
          <button id="send" title="Type into the terminal (does NOT submit — press Enter to send)">Send</button>
        </div>
      </main>
    </div>
    <script>
    (function () {
      // Token bootstrap — identical to the phone page: the ?token= arrives in the
      // initial URL, is stashed in sessionStorage, and thereafter rides only the
      // X-Ghostty-Token header on /api/* (scrubbed from the visible URL/history).
      var token = new URLSearchParams(location.search).get("token");
      if (token) {
        try { sessionStorage.setItem("ghostty_token", token); } catch (e) {}
        try { history.replaceState(null, "", location.pathname); } catch (e) {}
      } else {
        try { token = sessionStorage.getItem("ghostty_token"); } catch (e) {}
      }

      var notice = document.getElementById("notice");
      var tokenRecovery = document.getElementById("tokenrecovery");
      var tokenInput = document.getElementById("tokeninput");
      var tokenConnect = document.getElementById("tokenconnect");
      var banner = document.getElementById("banner");
      var app = document.getElementById("app");
      var menuBtn = document.getElementById("menubtn");
      var listEl = document.getElementById("list");
      var filterBar = document.getElementById("filterbar");
      var fHeroes = document.getElementById("f-heroes");
      var fAgents = document.getElementById("f-agents");
      var fVisible = document.getElementById("f-visible");
      var filterNote = document.getElementById("filternote");
      var screenEl = document.getElementById("screen");
      var xtermEl = document.getElementById("xterm");
      var placeholderEl = document.getElementById("placeholder");
      var jumpBtn = document.getElementById("jumpbottom");
      var liveBtn = document.getElementById("livebtn");
      var curEl = document.getElementById("cur");
      var copyBtn = document.getElementById("copybtn");
      var clearBellBtn = document.getElementById("clearbell");
      var clearAttnBtn = document.getElementById("clearattn");
      var modeEl = document.getElementById("mode");
      var modeToggleEl = document.getElementById("modebar");
      var inp = document.getElementById("inp");
      var current = null, timer = null, listTimer = null;
      // Active live-stream handle (xterm.js raw byte stream). Single-surface
      // invariant: at most one live stream — showSurface disposes the old first.
      var stream = null;
      // Frame-mode state (scrolling a full-screen app; see smartScroll).
      var frameMode = false, framePending = false;
      // The surface for which we've already seeded the scroll cursor (see sendScroll).
      var scrollSeededFor = null;

      function showTokenRecovery(msg) {
        notice.style.display = "block";
        notice.textContent = msg;
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
        start();
      };
      tokenInput.addEventListener("keydown", function (e) {
        if (e.key === "Enter") { e.preventDefault(); tokenConnect.onclick(); }
      });

      function headers(extra) {
        var h = {};
        if (token) h["X-Ghostty-Token"] = token;
        if (extra) for (var k in extra) h[k] = extra[k];
        return h;
      }
      function url(path, params) {
        if (!params) return path;
        var p = new URLSearchParams(), any = false;
        for (var k in params) { if (params[k] != null && params[k] !== "") { p.set(k, params[k]); any = true; } }
        return any ? (path + "?" + p.toString()) : path;
      }
      // Load the SAME vendored xterm.js + xterm.css + JetBrains Mono the phone page
      // uses (served by assetRoutes; token rides the query string on these tags).
      (function () {
        var css = document.createElement("link");
        css.rel = "stylesheet";
        css.href = url("/xterm.css", { token: token });
        document.head.appendChild(css);
        var js = document.createElement("script");
        js.src = url("/xterm.js", { token: token });
        document.head.appendChild(js);
        var ff = document.createElement("style");
        ff.textContent =
          '@font-face{font-family:"JetBrains Mono";font-weight:400;font-style:normal;font-display:swap;' +
            'src:url("' + url("/jetbrains-mono-regular.woff2", { token: token }) + '") format("woff2");}' +
          '@font-face{font-family:"JetBrains Mono";font-weight:700;font-style:normal;font-display:swap;' +
            'src:url("' + url("/jetbrains-mono-bold.woff2", { token: token }) + '") format("woff2");}';
        document.head.appendChild(ff);
        if (document.fonts && document.fonts.load) {
          try { document.fonts.load('15px "JetBrains Mono"'); document.fonts.load('bold 15px "JetBrains Mono"'); } catch (e) {}
        }
      })();

      var bannerIsError = false;
      function setBanner(msg, ok, sticky) {
        if (!msg) { banner.style.display = "none"; bannerIsError = false; return; }
        banner.textContent = msg;
        banner.className = ok ? "ok" : "";
        banner.style.display = "block";
        bannerIsError = !!sticky;
      }
      function clearBannerIfNotError() { if (!bannerIsError) setBanner(null); }

      var listLoaded = false;
      // Same availability logic as the phone: filters need the dashboard running;
      // "Focus on heroes" is a full override that greys out the other two.
      function applyFilterAvailability(dashboard) {
        var heroFocus = dashboard && fHeroes.checked;
        fHeroes.disabled = !dashboard;
        fAgents.disabled = !dashboard || heroFocus;
        fVisible.disabled = !dashboard || heroFocus || !fAgents.checked;
        if (dashboard) {
          filterBar.classList.remove("disabled");
          filterNote.textContent = heroFocus
            ? "Focusing on heroes \\u2014 showing all hero splits, ignoring hides."
            : "";
        } else {
          filterBar.classList.add("disabled");
          filterNote.textContent = "Agent Dashboard not running \\u2014 filters unavailable.";
        }
      }

      // Mark the row of the currently-viewed surface active (so the persistent
      // sidebar always shows what the viewer is driving). Called immediately on
      // select and again after each list refresh.
      function highlightActive() {
        Array.prototype.forEach.call(listEl.querySelectorAll(".row"), function (el) {
          el.classList.toggle("active", el.getAttribute("data-id") === current);
        });
      }

      // Reused nearly verbatim from the phone loadList(): fetch /api/surfaces,
      // apply the three filters, group by window+tab, render rows. The desktop
      // difference is the row carries data-id + an active highlight and the list
      // is NEVER hidden (it lives in the persistent sidebar).
      function loadList() {
        if (!listLoaded) listEl.innerHTML = "<div class='empty'>Loading\\u2026</div>";
        fetch(url("/api/surfaces"), { headers: headers() }).then(function (r) {
          if (r.status === 401) throw new Error("401");
          if (!r.ok) throw new Error("HTTP " + r.status);
          return r.json();
        }).then(function (data) {
          clearBannerIfNotError();
          listLoaded = true;
          var allRows = (data && data.surfaces) || [];
          var dashboard = !!(data && data.agentDashboard);
          applyFilterAvailability(dashboard);
          var heroFocus = dashboard && fHeroes.checked;
          var agentsOnly = !heroFocus && dashboard && fAgents.checked;
          var hideHidden = agentsOnly && fVisible.checked;
          var rows = allRows.filter(function (row) {
            if (heroFocus) return !!row.hero;
            if (agentsOnly && !row.isAgent) return false;
            if (hideHidden && row.hidden) return false;
            return true;
          });
          if (!allRows.length) { listEl.innerHTML = "<div class='empty'>No active sessions.</div>"; return; }
          if (!rows.length) { listEl.innerHTML = "<div class='empty'>No sessions match the filters.</div>"; return; }
          var groups = [], byKey = {};
          rows.forEach(function (row) {
            var wi = row.window || 0, ti = row.tab || 0;
            var key = wi + ":" + ti;
            var g = byKey[key];
            if (!g) { g = byKey[key] = { window: wi, tab: ti, tabTitle: row.tabTitle || "", rows: [] }; groups.push(g); }
            g.rows.push(row);
          });
          groups.sort(function (a, b) { return (a.window - b.window) || (a.tab - b.tab); });
          var winSet = {}; groups.forEach(function (g) { winSet[g.window] = 1; });
          var multiWin = Object.keys(winSet).length > 1;
          var frag = document.createDocumentFragment();
          groups.forEach(function (g) {
            var h = document.createElement("div"); h.className = "grouphdr";
            var loc = document.createElement("div"); loc.className = "loc";
            loc.textContent = (multiWin ? ("Window " + (g.window + 1) + " \\u00b7 ") : "") + "Tab " + (g.tab + 1);
            h.appendChild(loc);
            if (g.tabTitle) {
              var ttl = document.createElement("div"); ttl.className = "ttl";
              ttl.textContent = g.tabTitle;
              h.appendChild(ttl);
            }
            frag.appendChild(h);
            g.rows.forEach(function (row) {
              var d = document.createElement("div");
              d.className = "row";
              d.setAttribute("data-id", row.id);
              if (row.id === current) d.classList.add("active");
              var t = document.createElement("div"); t.className = "t";
              if (row.hero) {
                var hs = document.createElement("span"); hs.className = "herostar";
                hs.textContent = "\\u2605"; hs.title = "Hero";
                t.appendChild(hs);
              }
              t.appendChild(document.createTextNode(row.title || "(untitled)"));
              if (row.attnIndicator) {
                var bf = document.createElement("span"); bf.className = "bellflag";
                bf.textContent = "\\uD83D\\uDD14";
                t.appendChild(bf);
              }
              if ((row.splitCount || 1) > 1) {
                var b = document.createElement("span"); b.className = "badge";
                b.textContent = "split " + ((row.splitIndex || 0) + 1) + "/" + row.splitCount;
                t.appendChild(b);
              }
              var p = document.createElement("div"); p.className = "p"; p.textContent = row.pwd || "";
              d.appendChild(t); d.appendChild(p);
              if (dashboard) {
                if (row.hidden) d.classList.add("ishidden");
                var hb = document.createElement("button"); hb.className = "hidebtn";
                hb.textContent = row.hidden ? "Show" : "Hide";
                hb.title = row.hidden
                  ? "Reveal this split (in the dashboard + monitor)"
                  : "Hide this split from the dashboard + monitor";
                hb.onclick = function (ev) { ev.stopPropagation(); setHidden(row.id, !row.hidden); };
                d.appendChild(hb);
              }
              d.onclick = function () { showSurface(row.id, row.title, row.bell); };
              frag.appendChild(d);
            });
          });
          listEl.replaceChildren(frag);
        }).catch(function (e) {
          if (String(e.message) === "401") {
            showTokenRecovery("Unauthorized. The token is wrong or was rotated. Reopen with ?token=..., or paste a token below.");
            listEl.innerHTML = "";
            listLoaded = false;
          } else {
            setBanner("Connection lost \\u2014 retrying\\u2026", false);
          }
        });
      }

      // The viewed session is gone (404): drop the viewer back to the placeholder
      // but keep the sidebar. Shared by the poll()/stream/send 404 paths.
      function sessionClosedTeardown() {
        setBanner("Session closed.", false, true);
        showPlaceholder();
        loadList();
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
            var wasNearBottom = isNearBottom();
            var prevTop = screenEl.scrollTop;
            screenEl.textContent = txt;
            if (userInitiated || wasNearBottom) screenEl.scrollTop = screenEl.scrollHeight;
            else screenEl.scrollTop = prevTop;
            updateJumpBtn();
          })
          .catch(function (e) {
            var m = String(e.message);
            if (m === "404") {
              sessionClosedTeardown();
            } else if (m === "401") {
              if (timer) { clearInterval(timer); timer = null; }
              current = null;
              setBanner(null);
              showTokenRecovery("Unauthorized. The token is wrong or was rotated. Reopen with ?token=..., or paste a token below.");
              showPlaceholder();
            } else {
              setBanner("Connection lost \\u2014 reconnecting\\u2026", false);
            }
          });
      }

      function isNearBottom() {
        return (screenEl.scrollHeight - screenEl.scrollTop - screenEl.clientHeight) < 24;
      }
      function updateJumpBtn() {
        jumpBtn.style.display = (screenEl.style.display !== "none" && !isNearBottom()) ? "block" : "none";
      }
      jumpBtn.onclick = function () {
        screenEl.scrollTop = screenEl.scrollHeight;
        updateJumpBtn();
      };
      screenEl.addEventListener("scroll", updateJumpBtn);

      function disposeStream() {
        if (!stream) return;
        var s = stream; stream = null;
        try { s.dispose(); } catch (e) {}
        xtermEl.style.display = "none";
        xtermEl.replaceChildren();
      }

      function fallbackToPoll(msg) {
        disposeStream();
        frameMode = false; framePending = false; liveBtn.style.display = "none";
        placeholderEl.style.display = "none";
        screenEl.style.display = "block";
        modeToggleEl.style.display = "flex";
        if (msg) setBanner(msg, false);
        if (!current) return;
        poll();
        if (timer) clearInterval(timer);
        timer = setInterval(poll, 700);
      }

      // Open the live raw-byte stream for `uuid` into an xterm.js terminal — the
      // same path as the phone page, but with a desktop-scale font size. Sizes the
      // terminal to the HOST grid from the X-Ghostty-Cols/-Rows headers (never
      // resizes the PTY). Degrades to the poll fallback on any failure.
      function openStream(uuid) {
        if (!window.Terminal) return null;
        var term = new Terminal({
          convertEol: false,
          scrollback: 10000,
          fontSize: 15,
          fontFamily: '"JetBrains Mono", ui-monospace, Menlo, monospace'
        });
        term.open(xtermEl);
        placeholderEl.style.display = "none";
        xtermEl.style.display = "block";
        screenEl.style.display = "none";
        modeToggleEl.style.display = "none";

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
            if (r.status === 404) { if (stream === handle) { sessionClosedTeardown(); } return; }
            if (!r.ok || !r.body) {
              if (stream === handle) fallbackToPoll("Live stream unavailable \\u2014 using snapshot.");
              return;
            }
            reader = r.body.getReader();
            var hc = parseInt(r.headers.get("X-Ghostty-Cols"), 10);
            var hr = parseInt(r.headers.get("X-Ghostty-Rows"), 10);
            if (hc > 0 && hr > 0) { try { term.resize(hc, hr); } catch (e) {} }
            function pump() {
              return reader.read().then(function (res) {
                if (disposed) return;
                if (res.done) {
                  if (stream === handle) fallbackToPoll("Live stream ended \\u2014 using snapshot.");
                  return;
                }
                if (!frameMode) term.write(res.value);
                return pump();
              });
            }
            return pump();
          })
          .catch(function () {
            if (disposed) return;
            if (stream === handle) fallbackToPoll("Connection lost \\u2014 using snapshot.");
          });

        var handle = { dispose: teardown, term: term };
        return handle;
      }

      // No surface selected: keep the sidebar, show the placeholder in the viewer.
      // On narrow layouts data-view="list" collapses the viewer and reveals the
      // full-width sidebar drawer (the phone "back" behavior); on wide it is inert.
      function showPlaceholder() {
        disposeStream();
        frameMode = false; framePending = false; liveBtn.style.display = "none";
        current = null;
        app.dataset.view = "list";
        if (timer) { clearInterval(timer); timer = null; }
        xtermEl.style.display = "none";
        screenEl.style.display = "none";
        modeToggleEl.style.display = "none";
        placeholderEl.style.display = "flex";
        curEl.textContent = "";
        jumpBtn.style.display = "none";
        setClearBellVisible(false);
        setClearAttnVisible(false);
        highlightActive();
      }

      function setClearBellVisible(on) { clearBellBtn.style.display = on ? "inline-block" : "none"; }
      function setClearAttnVisible(on) { clearAttnBtn.style.display = on ? "inline-block" : "none"; }

      // Refresh the Clear-bell/Clear-attention buttons against the live state for
      // the viewed split (a bell may ring / a promotion may land mid-view).
      function refreshBellButton() {
        if (!current) return;
        var want = current;
        fetch(url("/api/surfaces"), { headers: headers() })
          .then(function (r) { return r && r.ok ? r.json() : null; })
          .then(function (data) {
            if (!data || current !== want) return;
            var rows = data.surfaces || [];
            var hit = null;
            for (var i = 0; i < rows.length; i++) { if (rows[i].id === want) { hit = rows[i]; break; } }
            if (hit) { setClearBellVisible(!!hit.bell); setClearAttnVisible(!!hit.attentionNeeded); }
          })
          .catch(function () {});
      }

      // Pick a surface: swap the viewer's content in place (sidebar stays). Single
      // live stream — dispose the old, open the new. Reuses the phone's
      // disposeStream()+openStream() sequence.
      //
      // NOTE: unlike the old phone-only page this deliberately does NOT inp.focus()
      // at the end. On the unified client an always-focused Send field would make
      // the global keydown driver bail (isTypingField), disabling desktop keyboard
      // driving — so we leave focus on the body/terminal. The phone trade-off is the
      // soft keyboard no longer auto-pops on open (tap the Send field to raise it).
      function showSurface(id, title, bell) {
        current = id;
        // On narrow layouts this collapses the sidebar drawer and gives the viewer
        // the whole screen; on wide it is inert (both panes always show).
        app.dataset.view = "surface";
        frameMode = false; framePending = false; liveBtn.style.display = "none";
        scrollSeededFor = null;
        setClearBellVisible(!!bell);
        setClearAttnVisible(false);
        refreshBellButton();
        placeholderEl.style.display = "none";
        curEl.textContent = title || "";
        setBanner(null);
        disposeStream();
        stream = openStream(id);
        if (stream) {
          if (timer) { clearInterval(timer); timer = null; }
        } else {
          screenEl.style.display = "block";
          modeToggleEl.style.display = "flex";
          poll();
          if (timer) clearInterval(timer);
          timer = setInterval(poll, 700);
        }
        highlightActive();
      }

      // Narrow-layout back/menu control: reopen the sidebar drawer, mirroring the
      // phone "← Sessions" back. If we were in frame mode (scrollback), snap the
      // app back to the live bottom first (same as exiting frame mode), then drop
      // to the placeholder (which disposes the stream + sets data-view="list") and
      // refresh the list. CSS-hidden on wide, so this only runs on narrow.
      menuBtn.onclick = function () {
        if (frameMode) { sendScroll(-30); sendScroll(-30); }
        showPlaceholder();
        loadList();
      };

      copyBtn.onclick = function () {
        if (!(stream && stream.term)) { noActiveSession(); return; }
        var sel = "";
        try { sel = stream.term.getSelection(); } catch (e) {}
        if (!sel) { setBanner("No selection to copy.", false); setTimeout(clearBannerIfNotError, 1200); return; }
        if (window.isSecureContext && navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(sel)
            .then(function () { setBanner("Copied.", true); setTimeout(clearBannerIfNotError, 1200); })
            .catch(function () { setBanner("Copy failed \\u2014 try \\u2318C.", false, true); });
        } else {
          setBanner("Copy needs HTTPS \\u2014 use \\u2318C, or put `tailscale serve` in front.", false, true);
        }
      };

      clearBellBtn.onclick = function () {
        if (!current) { noActiveSession(); return; }
        fetch(url("/api/surface/" + current + "/bell"), { method: "POST", headers: headers() })
          .then(function (r) {
            if (r && r.ok) { setClearBellVisible(false); setBanner("Bell cleared.", true); setTimeout(clearBannerIfNotError, 1200); }
            else if (r && r.status === 404) { sessionClosedTeardown(); }
            else { setBanner("Clear bell failed (HTTP " + (r ? r.status : "?") + ").", false, true); }
          })
          .catch(function () { setBanner("Clear bell failed \\u2014 not delivered.", false, true); });
      };
      clearAttnBtn.onclick = function () {
        if (!current) { noActiveSession(); return; }
        fetch(url("/api/surface/" + current + "/attention"), { method: "POST", headers: headers() })
          .then(function (r) {
            if (r && r.ok) { setClearAttnVisible(false); setBanner("Attention cleared.", true); setTimeout(clearBannerIfNotError, 1200); }
            else if (r && r.status === 404) { sessionClosedTeardown(); }
            else { setBanner("Clear attention failed (HTTP " + (r ? r.status : "?") + ").", false, true); }
          })
          .catch(function () { setBanner("Clear attention failed \\u2014 not delivered.", false, true); });
      };

      function prefGet(k, dflt) { try { var v = localStorage.getItem(k); return v === null ? dflt : v; } catch (e) { return dflt; } }
      function prefSet(k, v) { try { localStorage.setItem(k, v); } catch (e) {} }
      modeEl.value = prefGet("ghostty_mode", modeEl.value);

      fHeroes.checked = prefGet("ghostty_filter_heroes", "0") === "1";
      fAgents.checked = prefGet("ghostty_filter_agents", "1") === "1";
      fVisible.checked = prefGet("ghostty_filter_visible", "1") === "1";
      fHeroes.onchange = function () { prefSet("ghostty_filter_heroes", fHeroes.checked ? "1" : "0"); applyFilterAvailability(!fHeroes.disabled); loadList(); };
      fAgents.onchange = function () { prefSet("ghostty_filter_agents", fAgents.checked ? "1" : "0"); loadList(); };
      fVisible.onchange = function () { prefSet("ghostty_filter_visible", fVisible.checked ? "1" : "0"); loadList(); };

      document.getElementById("refresh").onclick = poll;
      modeEl.onchange = function () { prefSet("ghostty_mode", modeEl.value); poll(true); };

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
          headers: headers({ "Content-Type": "text/plain" }),
          body: text
        }).then(reportSend).catch(function () { setBanner("Send failed \\u2014 not delivered.", false, true); });
      }
      function reportSend(r) {
        if (r && r.ok) { setBanner("Sent.", true); setTimeout(function () { clearBannerIfNotError(); }, 1500); }
        else if (r && r.status === 404) { sessionClosedTeardown(); }
        else { setBanner("Send failed (HTTP " + (r ? r.status : "?") + ").", false, true); }
      }

      function doSend() {
        var v = inp.value;
        if (!v) return;
        sendText(v);
        inp.value = "";
        inp.focus();
        syncSendEnabled();
      }
      var sendBtn = document.getElementById("send");
      sendBtn.onclick = doSend;
      inp.addEventListener("keydown", function (e) {
        if (e.key === "Enter") { e.preventDefault(); doSend(); }
      });
      function syncSendEnabled() { sendBtn.disabled = !inp.value; }
      inp.addEventListener("input", syncSendEnabled);
      syncSendEnabled();

      // ---- Global keyboard handling (the core desktop-mode work) --------------
      // A CAPTURE-phase document keydown handler maps browser keystrokes to real
      // key events on the surface (POST /input), then preventDefault()s so the
      // browser doesn't also act. Capture runs BEFORE xterm.js's own hidden
      // textarea handler, so we own the keystroke (xterm is display-only here).
      //
      // Text batching: consecutive printables are coalesced into one text/plain
      // POST within a short window (kinder to the core's 64-slot IO mailbox — see
      // keySpecs(forText:)); a named/ctrl key flushes the buffer first so ordering
      // is preserved (typed "ab" then Enter submits "ab" then Enter).
      var typeBuf = "", typeTimer = null;
      function flushType() {
        if (typeTimer) { clearTimeout(typeTimer); typeTimer = null; }
        var t = typeBuf; typeBuf = "";
        if (t) sendText(t);
      }
      function queueType(ch) {
        typeBuf += ch;
        if (!typeTimer) typeTimer = setTimeout(flushType, 12);
      }
      // Only OUR own text fields swallow keys; the xterm helper textarea does NOT
      // (it's display-only, so keystrokes there must still reach the surface).
      function isTypingField(t) { return t === inp || t === tokenInput; }
      // Named / arrow keys the server's keySpecs(forKey:) knows, derived from
      // KeyboardEvent.key (positional intent). PageUp/PageDown are handled
      // separately (frame-mode scroll), not here.
      function keyNameFor(e) {
        switch (e.key) {
          case "Enter": return "enter";
          case "Escape": return "esc";
          case "Tab": return "tab";
          case "Backspace": return "backspace";
          case "ArrowUp": return "up";
          case "ArrowDown": return "down";
          case "ArrowLeft": return "left";
          case "ArrowRight": return "right";
          case "Home": return "home";
          case "End": return "end";
        }
        return null;
      }
      document.addEventListener("keydown", function (e) {
        if (!current) return;
        if (isTypingField(e.target)) return;   // let our Send/token fields type normally
        // Never steal keys from a focused UI control (sidebar filter checkboxes,
        // the mode <select>, buttons, any input) — those must keep native keyboard
        // behavior (Space toggles, Enter activates, arrows move). The ONE exception
        // is xterm.js's own hidden helper textarea (focused when the terminal has
        // focus): that IS the terminal, so let it fall through to the handler.
        // Body-level focus (nothing focused) also falls through, so typing after a
        // click on the terminal still reaches the surface.
        var tgt = e.target;
        if (tgt && tgt !== document.body &&
            !(tgt.classList && tgt.classList.contains("xterm-helper-textarea"))) {
          var tag = tgt.tagName;
          if (tag === "INPUT" || tag === "SELECT" || tag === "TEXTAREA" ||
              tag === "BUTTON" || tag === "OPTION" || tag === "A") return;
        }

        // ⌘ (Meta): repurposed for clipboard/selection, NOT forwarded to the shell.
        // ⌘A selects all IN THE TERMINAL; ⌘C/⌘X/⌘V fall through so the native
        // copy/cut/paste DOM events fire (handled below), and ⌘R still reloads.
        if (e.metaKey) {
          var mk = (e.key || "").toLowerCase();
          if (mk === "a") {
            if (stream && stream.term) { try { stream.term.selectAll(); } catch (err) {} e.preventDefault(); }
          }
          return;
        }

        // PageUp/PageDown: frame-mode scroll (same host-wheel path as the on-screen
        // Scroll buttons) so a scroll-region TUI doesn't garble under re-emulation.
        if (e.key === "PageUp") { e.preventDefault(); e.stopPropagation(); smartScroll(1); return; }
        if (e.key === "PageDown") { e.preventDefault(); e.stopPropagation(); smartScroll(-1); return; }

        // Ctrl-<letter> -> a real Ctrl key event (ctrl-a … ctrl-z). Derive the
        // letter from KeyboardEvent.code (KeyD -> d), the physical position that
        // matches the native keycode the server maps (see keySpecs(forKey:)).
        if (e.ctrlKey && !e.altKey && !e.metaKey) {
          var code = e.code || "";
          if (/^Key[A-Z]$/.test(code)) {
            flushType();
            e.preventDefault(); e.stopPropagation();
            sendKey("ctrl-" + code.slice(3).toLowerCase());
            return;
          }
        }

        // Named / arrow keys.
        var name = keyNameFor(e);
        if (name) {
          flushType();
          e.preventDefault(); e.stopPropagation();
          sendKey(name);
          return;
        }

        // Printable text (no Ctrl/Meta/Alt): e.key is already the shifted char.
        if (!e.ctrlKey && !e.metaKey && !e.altKey && e.key && e.key.length === 1) {
          e.preventDefault(); e.stopPropagation();
          queueType(e.key);
          return;
        }
      }, true);   // CAPTURE

      // ---- Copy / paste -------------------------------------------------------
      // Copy/cut: put the xterm.js SELECTION on the clipboard (synchronous via the
      // event's clipboardData, no permission prompt). Cut never deletes — the
      // mirror is read-only, so it behaves like copy.
      function writeSelectionToEvent(e) {
        if (!(stream && stream.term && stream.term.hasSelection())) return false;
        var sel = "";
        try { sel = stream.term.getSelection(); } catch (err) {}
        if (!sel) return false;
        try { e.clipboardData.setData("text/plain", sel); e.preventDefault(); return true; } catch (err) { return false; }
      }
      document.addEventListener("copy", function (e) { writeSelectionToEvent(e); });
      document.addEventListener("cut", function (e) { writeSelectionToEvent(e); });
      // Paste: read the clipboard text from the paste event and send it via the
      // text/plain input path (server maps it through keySpecs(forText:); newlines
      // become real Enter key events). The Send field is the manual fallback.
      document.addEventListener("paste", function (e) {
        if (!current) return;
        if (isTypingField(e.target)) return;   // let the Send field paste into itself
        var t = "";
        try { t = (e.clipboardData || window.clipboardData).getData("text"); } catch (err) {}
        if (t) { e.preventDefault(); sendText(t); }
      });

      function flashTap(b) {
        b.classList.add("tapped");
        if (b._tapTimer) clearTimeout(b._tapTimer);
        b._tapTimer = setTimeout(function () { b.classList.remove("tapped"); }, 150);
      }

      // Press-and-hold auto-repeat (pointer events cover mouse + touch) for the
      // navigation quick-keys where a repeated tap is tedious.
      function addRepeat(el, fire) {
        el.style.touchAction = "none";
        var delayT = null, repT = null, active = false;
        function once() { flashTap(el); fire(); }
        function start(e) {
          if (active) return;
          active = true;
          if (e && e.preventDefault) e.preventDefault();
          once();
          delayT = setTimeout(function () { repT = setInterval(once, 90); }, 350);
        }
        function stop() {
          active = false;
          if (delayT) { clearTimeout(delayT); delayT = null; }
          if (repT) { clearInterval(repT); repT = null; }
        }
        el.addEventListener("pointerdown", start);
        el.addEventListener("pointerup", stop);
        el.addEventListener("pointercancel", stop);
        el.addEventListener("pointerleave", stop);
        el.addEventListener("click", function (e) { e.preventDefault(); });
      }

      // On-screen quick-key row: arrows + backspace auto-repeat on hold; the rest
      // (enter/space/y/n/esc/tab/ctrl-u/ctrl-c) are single-fire.
      var repeatKeys = { up: 1, down: 1, left: 1, right: 1, backspace: 1 };
      Array.prototype.forEach.call(document.querySelectorAll("[data-key]"), function (b) {
        var k = b.getAttribute("data-key");
        if (repeatKeys[k]) { addRepeat(b, function () { sendKey(k); }); }
        else { b.onclick = function () { flashTap(b); sendKey(k); }; }
      });

      function sendScroll(dy, seed) {
        if (!current) { noActiveSession(); return; }
        fetch(url("/api/surface/" + current + "/scroll"), {
          method: "POST",
          headers: headers({ "Content-Type": "application/json" }),
          body: JSON.stringify(seed ? { dy: dy, seed: true } : { dy: dy })
        }).catch(function () {});
      }

      function setHidden(id, hidden) {
        fetch(url("/api/surface/" + id + "/hidden"), {
          method: "POST",
          headers: headers({ "Content-Type": "application/json" }),
          body: JSON.stringify({ hidden: !!hidden })
        }).then(function (r) {
          if (r && r.ok) { loadList(); }
          else if (r && r.status === 503) { setBanner("Agent Dashboard isn't running.", false, true); }
          else { setBanner("Hide failed (HTTP " + (r ? r.status : "?") + ").", false, true); }
        }).catch(function () { setBanner("Hide failed \\u2014 not delivered.", false, true); });
      }

      // FRAME MODE (scrolling a full-screen app) — carried over unchanged from the
      // phone page: drive the host wheel (/scroll) then PAINT the host's
      // authoritative frame (/frame) so xterm.js never drifts. "● Live" / a
      // surface swap exits by snapping to bottom + reconnecting the stream.
      function paintFrame() {
        if (!frameMode || !current || framePending) return;
        framePending = true;
        var want = current;
        fetch(url("/api/surface/" + want + "/frame"), { headers: headers() })
          .then(function (r) {
            if (r && r.status === 404) { if (stream) sessionClosedTeardown(); return null; }
            return r && r.ok ? r.text() : null;
          })
          .then(function (ansi) {
            framePending = false;
            if (ansi != null && frameMode && current === want && stream && stream.term) {
              try { stream.term.write(ansi); } catch (e) {}
            }
          })
          .catch(function () { framePending = false; });
      }
      function enterFrameMode() {
        if (frameMode) return;
        frameMode = true;
        liveBtn.style.display = "block";
        setBanner("Scrollback \\u2014 click \\u25cf Live to resume", true);
      }
      function exitFrameMode() {
        if (!frameMode) return;
        frameMode = false;
        framePending = false;
        liveBtn.style.display = "none";
        clearBannerIfNotError();
        var want = current;
        sendScroll(-30); sendScroll(-30);
        setTimeout(function () {
          if (current === want) { showSurface(want, curEl.textContent, false); }
        }, 250);
      }
      liveBtn.onclick = exitFrameMode;

      function smartScroll(dir) {
        var seed = scrollSeededFor !== current; scrollSeededFor = current;
        if (!(stream && stream.term)) { sendScroll(dir * 3, seed); return; }
        enterFrameMode();
        sendScroll(dir * 3, seed);
        setTimeout(paintFrame, 120);
      }
      addRepeat(document.getElementById("scrollup"), function () { smartScroll(1); });
      addRepeat(document.getElementById("scrolldown"), function () { smartScroll(-1); });

      // ---- Reconnect-on-refocus ----------------------------------------------
      // A backgrounded desktop tab can silently stall the stream. On return to the
      // foreground WHILE viewing a surface, do a clean resync — dispose + re-open
      // the stream (idempotent; replays the host ring and rebuilds xterm.js state).
      // With no surface selected, just refresh the sidebar.
      document.addEventListener("visibilitychange", function () {
        if (document.visibilityState === "visible") {
          if (current) { showSurface(current, curEl.textContent, false); }
          else { loadList(); }
        } else if (timer) { clearInterval(timer); timer = null; }
      });

      // ---- Web Push (notify-on-bell) — reused verbatim from the phone page -----
      var notifyBtn = document.getElementById("notify");
      var pushVapidKey = null, pushEnabled = false;
      function pushSupported() {
        return ("serviceWorker" in navigator) && ("PushManager" in window) && window.isSecureContext;
      }
      function vapidKeyBytes(b64) {
        var pad = "=".repeat((4 - b64.length % 4) % 4);
        var s = (b64 + pad).replace(/-/g, "+").replace(/_/g, "/");
        var raw = atob(s), arr = new Uint8Array(raw.length);
        for (var i = 0; i < raw.length; i++) arr[i] = raw.charCodeAt(i);
        return arr;
      }
      function refreshNotifyButton() {
        notifyBtn.textContent = "\\uD83D\\uDD14";
        if (!pushSupported()) {
          notifyBtn.disabled = true;
          notifyBtn.classList.remove("armed");
          notifyBtn.title = window.isSecureContext
            ? "Push notifications are not supported by this browser"
            : "Needs HTTPS \\u2014 put `tailscale serve` in front of the monitor";
          return;
        }
        notifyBtn.disabled = false;
        notifyBtn.classList.toggle("armed", pushEnabled);
        notifyBtn.title = pushEnabled
          ? "Notifications ARMED \\u2014 click to mute"
          : "Click to get a push on this device when any split rings a bell";
      }
      function loadPushConfig() {
        if (!pushSupported()) { refreshNotifyButton(); return; }
        fetch(url("/api/push/config"), { headers: headers() }).then(function (r) {
          if (!r.ok) throw new Error("HTTP " + r.status);
          return r.json();
        }).then(function (cfg) {
          pushVapidKey = cfg.vapidPublicKey;
          pushEnabled = !!cfg.enabled;
          refreshNotifyButton();
        }).catch(function () {});
      }
      function setServerPushEnabled(on) {
        return fetch(url("/api/push/enabled"), {
          method: "POST",
          headers: headers({ "Content-Type": "application/json" }),
          body: JSON.stringify({ enabled: on })
        }).then(function () { pushEnabled = on; refreshNotifyButton(); });
      }
      notifyBtn.onclick = function () {
        flashTap(notifyBtn);
        if (!pushSupported()) return;
        if (pushEnabled) { setServerPushEnabled(false).catch(function () {}); return; }
        Notification.requestPermission().then(function (perm) {
          if (perm !== "granted") { setBanner("Notification permission denied", false, true); return; }
          return navigator.serviceWorker.register(url("/sw.js", { token: token })).then(function (reg) {
            return reg.pushManager.getSubscription().then(function (existing) {
              return existing || reg.pushManager.subscribe({
                userVisibleOnly: true,
                applicationServerKey: vapidKeyBytes(pushVapidKey)
              });
            });
          }).then(function (sub) {
            return fetch(url("/api/push/subscribe"), {
              method: "POST",
              headers: headers({ "Content-Type": "application/json" }),
              body: JSON.stringify(sub)
            });
          }).then(function () {
            return setServerPushEnabled(true);
          }).then(function () {
            setBanner("Notifications armed for this device", true);
          });
        }).catch(function (e) {
          setBanner("Could not enable notifications: " + (e && e.message ? e.message : e), false, true);
        });
      };
      refreshNotifyButton();

      // Keep the persistent sidebar fresh while browsing AND while viewing (so new
      // bells/rows appear and the active highlight stays correct); refresh the
      // viewed split's Clear buttons too.
      function start() {
        if (!listTimer) {
          listTimer = setInterval(function () {
            // On a narrow layout while viewing a surface the sidebar is collapsed
            // (data-view="surface"), so its DOM is off-screen — skip the wasted list
            // refetch/rebuild and only keep the viewed split's Clear buttons live.
            // On wide the sidebar is always visible, so it always refreshes.
            var sidebarHidden = current && app.dataset.view === "surface" &&
              window.matchMedia("(max-width: 859px)").matches;
            if (!sidebarHidden) loadList();
            if (current) refreshBellButton();
          }, 3000);
        }
        loadList();
        loadPushConfig();
      }

      start();
    })();
    </script>
    </body>
    </html>
    """

}

// (ramon fork) MCP event bus: the bell / process-exited / shell-prompt event
// source and the `wait_for_event` / `watch_for_pattern` waiter registry that
// backs those long-held `tools/call`s.
//
// CORRECTNESS-CRITICAL THREADING. Two sides:
//   * EVENT SOURCE (main): a NotificationCenter observer for the bell + a 250ms
//     main-queue poll for exited/prompt transitions. Each emitted Event is
//     appended to a coalescing ring (on main) and then hopped to the server's
//     serial queue to fan out to waiters.
//   * WAITER REGISTRY (server serial queue ONLY): the `waiters` array, the
//     `waitingConns` set, each Waiter's `resolved` flag and `deadline` timer.
//     Every mutation happens on `server.queue` so it is race-free WITHOUT a lock.
//
// A waiter is SINGLE-SHOT: `resolve` guards on `resolved`, cancels the deadline
// timer, removes the waiter from both registries, and writes the JSON-RPC
// response (which self-cancels the connection). A timer that fires after resolve,
// a second matching event, or a connection drop are all no-ops thanks to the
// guard.

import Foundation
import Network
import AppKit
import GhosttyKit
import os

final class MCPEventBus {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "mcp")

    // MARK: - Public value specs (built by MCPTools, used on the serial queue)

    /// A `wait_for_event` request: which surface ids / event types to match
    /// (empty set = match anything) and how long to wait.
    struct WaitSpec {
        let ids: Set<String>
        let types: Set<String>
        let timeoutMs: Double
    }

    /// PURE filter predicate for `wait_for_event` (unit-tested). An event matches
    /// when its id is in `ids` (empty = any) AND its type is in `types` (empty =
    /// any). `ids` / `eventId` are compared CASE-INSENSITIVELY (uppercased): a
    /// client may pass a lowercase UUID even though Foundation's `uuidString`
    /// (and our list_surfaces ids) are uppercase. `types` is exact (the values
    /// are a closed lowercase enum, validated up front in dispatch).
    static func eventMatches(ids: Set<String>, types: Set<String>,
                             eventId: String, eventType: String) -> Bool {
        let wantedIDs = Set(ids.map { $0.uppercased() })
        let idOK = wantedIDs.isEmpty || wantedIDs.contains(eventId.uppercased())
        let typeOK = types.isEmpty || types.contains(eventType)
        return idOK && typeOK
    }

    /// A `watch_for_pattern` request.
    struct PatternSpec {
        let uuid: UUID
        let regex: String
        let timeoutMs: Double
    }

    // MARK: - Timeout bounds

    /// Floor / ceiling for a `wait_for_event` / `watch_for_pattern` `timeoutMs`.
    ///
    /// CEILING is the load-bearing safety bound: a parked connection is exempt
    /// from the idle watchdog (the per-waiter deadline bounds it instead), so an
    /// unbounded `timeoutMs` would park a connection indefinitely; 32 such calls
    /// hit `maxConcurrentConnections` and starve the server. It MUST also stay
    /// strictly BELOW the stdio shim's `URLRequest.timeoutInterval` so the shim
    /// never fires a transport timeout (and emit a spurious -32000 'unreachable')
    /// while the server still holds the waiter parked. The shim uses 180s; this
    /// ceiling is 120s, leaving generous headroom for the response write.
    static let timeoutFloorMs: Double = 1_000
    static let timeoutCeilingMs: Double = 120_000

    /// Clamp a requested `timeoutMs` (or a default) into `[floor, ceiling]`.
    /// NaN / non-finite collapses to the default. PURE; unit-tested.
    static func clampTimeoutMs(_ requested: Double, default def: Double = 30_000) -> Double {
        let v = requested.isFinite ? requested : def
        return min(max(v, timeoutFloorMs), timeoutCeilingMs)
    }

    // MARK: - Events

    // TODO(agent-manager Phase 1): add an `agentState` event kind, fired on a hook
    // agent-state transition (carrying state / prompt? / tool? / message?), so
    // `wait_for_event` can block on "agent changed state". DELIBERATELY DEFERRED
    // from Phase 0 (it was a SECONDARY contract item — the annotation round-trip
    // does not depend on it). The hook signal already reaches the GUI via the MCP
    // `/agent-state` route + `.ghosttyAgentStateDidChange`; wiring it into this
    // waiter registry is the only missing piece.
    // (ramon fork / Agent Queue latency) `queueCommand` is a surface-LESS wake signal: it
    // fires when a GUI queue command (adopt/promote/pause/stop/…) lands on the FIFO, so the
    // sidecar's queue-reactive long-poll wakes an immediate supervisor sweep instead of
    // waiting out the in-flight sweep + the 5s poll gap. Its wire value is `queue_command`
    // (snake_case, matching the tool's type whitelist).
    enum EventType: String { case bell, exited, prompt, queueCommand = "queue_command" }

    struct Event {
        let id: UUID
        let type: EventType
        let ts: Date
    }

    /// Sentinel surface id for surface-less `queueCommand` events. Queue-command waiters
    /// register with an EMPTY `ids` filter (match any), so this id is never compared; it
    /// only fills `Event.id`. A fixed all-zero UUID keeps the event self-documenting.
    static let queueCommandSentinelID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    // MARK: - Event source state (main only)

    /// last-seen processExited per surface, to emit on a false->true transition.
    private var lastExited: [UUID: Bool] = [:]
    /// last-seen needsConfirmQuit per surface (the coarse `prompt` proxy).
    private var lastPrompt: [UUID: Bool] = [:]
    private var pollTimer: Timer?
    private var bellObserver: NSObjectProtocol?

    // MARK: - Coalescing ring + waiter registry (server serial queue)

    /// A bounded ring of recent events so a waiter that registers microseconds
    /// after an event still catches it. Mutated on main (append) and read on the
    /// serial queue (register) — guarded by `ringLock` since it straddles queues.
    private var ring: [Event] = []
    private static let ringCapacity = 64
    private static let coalesceWindow: TimeInterval = 0.5

    /// Upper bound (chars) on the text fed to a `watch_for_pattern` regex per
    /// poll. Tail-biased (the freshest output is most likely to match). Caps the
    /// worst-case cost of a catastrophic-backtracking token-supplied pattern; the
    /// match runs on the serial queue, so this protects that queue's throughput.
    private static let patternScanCap = 16_384
    private let ringLock = NSLock()

    /// A parked waiter. Reference type so its timer + closures share one instance.
    /// All mutable fields are touched ONLY on the server serial queue.
    final class Waiter {
        let id = UUID()
        let conn: NWConnection
        let rpcId: Any
        let filter: (Event) -> Bool
        var deadline: DispatchSourceTimer?
        var resolved = false
        /// nil for wait_for_event; set for watch_for_pattern (shapes the result).
        let patternUUID: UUID?

        init(conn: NWConnection, rpcId: Any, filter: @escaping (Event) -> Bool, patternUUID: UUID?) {
            self.conn = conn
            self.rpcId = rpcId
            self.filter = filter
            self.patternUUID = patternUUID
        }
    }

    /// Mutated ONLY on the server serial queue.
    private var waiters: [Waiter] = []
    /// Parked conn keys, so the server's idle watchdog can exempt them. Mutated
    /// ONLY on the server serial queue.
    private var waitingConns: Set<ObjectIdentifier> = []

    /// Weak so the bus never keeps the server alive; set in register/start.
    private weak var server: MCPServer?

    // MARK: - Lifecycle (main)

    /// Start the event source on main: the bell observer + the exited/prompt poll.
    /// `server` is stashed (weakly) so `record` can fan events out to already-
    /// registered waiters even between registrations.
    func start(server: MCPServer) {
        self.server = server
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.bellObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name.ghosttyBellDidRing,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let self else { return }
                guard let view = note.object as? Ghostty.SurfaceView else { return }
                // (ramon fork / Bell Attention v2) A bell on a surface the user is
                // actively looking at never needs promotion — we don't summon you to a
                // split you're already focused on. Don't surface it as a `.bell` event,
                // so the Agent Manager sidecar doesn't even spend a Haiku classify on it
                // (the bell-reactive promotion loop is the only consumer of `.bell`).
                // The GUI still fires the tier-1 `bell-features-focused` effects
                // independently via `ghosttyBellDidRing` in SurfaceView/AppDelegate.
                // Focus is read live on main at RING time — the freshest truth, unlike
                // the polled `surface.focused` the sidecar would otherwise see. Unfocused
                // bells still flow through and get classified/promoted as before.
                if view.bellIsFocused { return }
                self.record(Event(id: view.id, type: .bell, ts: Date()))
            }

            // 250ms poll for processExited / needsConfirmQuit transitions.
            let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.pollTransitions()
            }
            self.pollTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    /// Stop the event source on main. Parked waiters are torn down by the server's
    /// own connection teardown in `stop()`.
    func stop() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pollTimer?.invalidate()
            self.pollTimer = nil
            if let obs = self.bellObserver {
                NotificationCenter.default.removeObserver(obs)
                self.bellObserver = nil
            }
        }
    }

    /// Walk live surfaces and emit exited/prompt events on a false->true
    /// transition. Runs on main (the poll timer's thread).
    private func pollTransitions() {
        var seen: Set<UUID> = []
        for c in TerminalController.all {
            for view in c.surfaceTree {
                let uuid = view.id
                seen.insert(uuid)

                let exited = view.processExited
                if exited, lastExited[uuid] != true {
                    record(Event(id: uuid, type: .exited, ts: Date()))
                }
                lastExited[uuid] = exited

                let prompt = view.needsConfirmQuit
                if prompt, lastPrompt[uuid] != true {
                    record(Event(id: uuid, type: .prompt, ts: Date()))
                }
                lastPrompt[uuid] = prompt
            }
        }
        // Drop bookkeeping for surfaces that are gone.
        lastExited = lastExited.filter { seen.contains($0.key) }
        lastPrompt = lastPrompt.filter { seen.contains($0.key) }
    }

    // MARK: - record (main -> serial queue)

    /// Append an event to the coalescing ring (any thread; lock-guarded) and fan
    /// it out to parked waiters on the server serial queue.
    private func record(_ event: Event) {
        ringLock.lock()
        ring.append(event)
        if ring.count > Self.ringCapacity { ring.removeFirst(ring.count - Self.ringCapacity) }
        ringLock.unlock()

        guard let server else { return }
        server.queue.async { [weak self] in self?.deliver(event) }
    }

    /// (ramon fork / Agent Queue latency) Emit a surface-less `queueCommand` wake event.
    /// Called from `MCPServer.enqueueQueueCommand` AFTER the command is appended to the FIFO,
    /// so a woken queue-reactive waiter always drains a non-empty buffer. Safe from any
    /// thread (`record` locks the ring + hops to the serial queue). A no-op for effect when
    /// no waiter is parked — the coalescing ring (0.5s) and the 5s timer sweep are the
    /// fallbacks, so a command is never lost.
    func recordQueueCommand() {
        record(Event(id: Self.queueCommandSentinelID, type: .queueCommand, ts: Date()))
    }

    /// Fan an event out to matching waiters. Runs on the server serial queue.
    private func deliver(_ event: Event) {
        // Take an EXPLICIT snapshot: `resolve` mutates `self.waiters` via
        // removeAll, and iterating the live property while resolving would be
        // unsafe if `waiters` ever became a reference-typed collection. The
        // value-semantics copy keeps this correct and robust against refactors.
        let snapshot = waiters
        for w in snapshot where w.filter(event) {
            resolve(w, with: event)
        }
    }

    // MARK: - register (server serial queue)

    /// Register a `wait_for_event` waiter. Called from `handleRPC`, already on the
    /// server serial queue. Coalesce-checks the ring first; otherwise parks.
    func register(spec: WaitSpec, conn: NWConnection, rpcId: Any, server: MCPServer) {
        self.server = server

        // The filter delegates to the PURE, unit-tested `eventMatches` (which
        // normalizes ids case-insensitively so a lowercase client UUID still
        // matches Foundation's uppercase `uuidString`). Snapshot the spec sets so
        // the closure captures values, not the spec reference.
        let ids = spec.ids
        let types = spec.types
        let filter: (Event) -> Bool = { ev in
            Self.eventMatches(ids: ids, types: types,
                              eventId: ev.id.uuidString, eventType: ev.type.rawValue)
        }

        let waiter = Waiter(conn: conn, rpcId: rpcId, filter: filter, patternUUID: nil)

        // Coalesce: a recent matching event (within the window) resolves now.
        if let recent = recentMatch(filter) {
            resolve(waiter, with: recent)
            return
        }

        waiters.append(waiter)
        waitingConns.insert(ObjectIdentifier(conn))
        armDeadline(waiter, timeoutMs: spec.timeoutMs)
    }

    /// Register a `watch_for_pattern` waiter. Its "deadline" timer IS the polling
    /// timer (cancelled inside `resolve`); a separate hard deadline resolves with
    /// matched:false. Called on the server serial queue.
    func registerPattern(spec: PatternSpec, conn: NWConnection, rpcId: Any, server: MCPServer) {
        self.server = server

        // This waiter never matches the event-bus filter (the pattern poll drives
        // it directly), so its filter is a constant false.
        let waiter = Waiter(conn: conn, rpcId: rpcId, filter: { _ in false }, patternUUID: spec.uuid)
        waiters.append(waiter)
        waitingConns.insert(ObjectIdentifier(conn))

        // The regex was already validated in MCPTools.dispatch; rebuild it here.
        let regex = try? NSRegularExpression(pattern: spec.regex)

        // Polling timer (300ms) on the serial queue; hops to main to read text.
        //
        // ReDoS / main-thread-stall mitigation: the regex is token-supplied
        // (shell-exec credential gated, so the threat is limited) but a
        // catastrophic-backtracking pattern run on a large scrollback string
        // could stall the AppKit main thread. Two mitigations: (a) we read only
        // the VIEWPORT (scrollback:false), and (b) we cap the scanned text to
        // `Self.patternScanCap` chars (tail-biased: a pattern is matching the
        // freshest output) BEFORE the match. The match itself runs on the
        // serial queue — the main hop only reads the cached text — so a runaway
        // match stalls only the MCP serial queue (and the per-waiter hard
        // deadline still fires on that same queue to bound the whole watch),
        // never the AppKit main thread.
        let scanCap = Self.patternScanCap
        let poll = DispatchSource.makeTimerSource(queue: server.queue)
        poll.schedule(deadline: .now() + 0.3, repeating: 0.3)
        poll.setEventHandler { [weak self, weak server] in
            guard let self, let server else { return }
            guard !waiter.resolved else { return }
            let fullText: String? = DispatchQueue.main.sync {
                MCPLayout.readText(uuid: spec.uuid)?.text
            }
            guard var text = fullText, let regex else { return }
            if text.count > scanCap {
                text = String(text.suffix(scanCap))
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if regex.firstMatch(in: text, options: [], range: range) != nil {
                self.resolveMatched(waiter, matched: true, server: server)
            }
        }
        waiter.deadline = poll
        poll.resume()

        // Hard deadline: a SEPARATE one-shot that resolves matched:false. We piggy
        // back it on the same serial queue; on fire it resolves the waiter (which
        // cancels the poll timer via `deadline`). Because `deadline` already holds
        // the poll timer, we keep the hard deadline in a local capture.
        let hard = DispatchSource.makeTimerSource(queue: server.queue)
        hard.schedule(deadline: .now() + spec.timeoutMs / 1000.0)
        hard.setEventHandler { [weak self, weak server] in
            guard let self, let server else { return }
            self.resolveMatched(waiter, matched: false, server: server)
            hard.cancel()
        }
        hard.resume()
        // Keep the hard timer alive until the waiter resolves. The poll timer is
        // `waiter.deadline`; stash the hard timer too so it is not deallocated.
        hardDeadlines[waiter.id] = hard
    }

    /// Hard-deadline timers for pattern waiters (server serial queue only).
    private var hardDeadlines: [UUID: DispatchSourceTimer] = [:]

    /// Scan the ring for a matching event newer than the coalesce window. Locks
    /// the ring (it is appended on main). Runs on the server serial queue.
    private func recentMatch(_ filter: (Event) -> Bool) -> Event? {
        ringLock.lock()
        defer { ringLock.unlock() }
        let cutoff = Date().addingTimeInterval(-Self.coalesceWindow)
        // Newest first.
        for ev in ring.reversed() where ev.ts >= cutoff && filter(ev) {
            return ev
        }
        return nil
    }

    // MARK: - deadline (server serial queue)

    private func armDeadline(_ waiter: Waiter, timeoutMs: Double) {
        guard let server else { return }
        let timer = DispatchSource.makeTimerSource(queue: server.queue)
        timer.schedule(deadline: .now() + timeoutMs / 1000.0)
        timer.setEventHandler { [weak self, weak waiter] in
            guard let self, let waiter else { return }
            self.resolve(waiter, with: nil)
        }
        waiter.deadline = timer
        timer.resume()
    }

    // MARK: - resolve (single-shot, server serial queue)

    /// Resolve a `wait_for_event` waiter with an event (or nil = timeout). Runs on
    /// the server serial queue (callers must already be on it: deliver/register/
    /// the deadline handler all are). SINGLE-SHOT.
    private func resolve(_ waiter: Waiter, with event: Event?) {
        guard !waiter.resolved else { return }
        waiter.resolved = true
        waiter.deadline?.cancel()
        waiter.deadline = nil
        hardDeadlines[waiter.id]?.cancel()
        hardDeadlines[waiter.id] = nil
        waiters.removeAll { $0.id == waiter.id }
        waitingConns.remove(ObjectIdentifier(waiter.conn))

        let result: [String: Any]
        if let event {
            result = ["event": [
                "id": event.id.uuidString,
                "type": event.type.rawValue,
                "ts": Self.iso8601.string(from: event.ts),
            ]]
        } else {
            result = ["event": NSNull()]
        }
        sendResult(waiter, result: result)
    }

    /// Resolve a `watch_for_pattern` waiter with matched true/false. SINGLE-SHOT,
    /// server serial queue.
    private func resolveMatched(_ waiter: Waiter, matched: Bool, server: MCPServer) {
        guard !waiter.resolved else { return }
        waiter.resolved = true
        waiter.deadline?.cancel()       // the poll timer
        waiter.deadline = nil
        hardDeadlines[waiter.id]?.cancel()
        hardDeadlines[waiter.id] = nil
        waiters.removeAll { $0.id == waiter.id }
        waitingConns.remove(ObjectIdentifier(waiter.conn))

        var result: [String: Any] = ["matched": matched]
        if let uuid = waiter.patternUUID { result["id"] = uuid.uuidString }
        sendResult(waiter, result: result)
    }

    private func sendResult(_ waiter: Waiter, result: [String: Any]) {
        guard let server else { waiter.conn.cancel(); return }
        let envelope = MCPServer.resultEnvelope(
            id: waiter.rpcId,
            result: MCPServer.toolContent(result, isError: false))
        server.send(.json(envelope), on: waiter.conn)
    }

    // MARK: - connection drop (server serial queue)

    /// A parked connection dropped; resolve its waiter (as a timeout) so the
    /// registries are cleaned up. Runs on the server serial queue (called from the
    /// connection state handler, which runs on that queue).
    func connectionDropped(_ key: ObjectIdentifier) {
        guard waitingConns.contains(key) else { return }
        let snapshot = waiters  // resolve mutates `waiters`; iterate a copy.
        for w in snapshot where ObjectIdentifier(w.conn) == key {
            // resolve writes to a dead conn harmlessly (send no-ops / cancels); the
            // important effect is the single-shot teardown of timers + registries.
            if w.patternUUID != nil {
                if let server { resolveMatched(w, matched: false, server: server) }
            } else {
                resolve(w, with: nil)
            }
        }
        waitingConns.remove(key)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

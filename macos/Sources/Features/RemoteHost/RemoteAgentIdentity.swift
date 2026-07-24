import Foundation
import Security

/// (ramon fork / cloud-hosts, Phase 4 · M1/D6) The GUI-side nonce → surface
/// correlation map for cross-host agent self-identification.
///
/// WHY a nonce (D6): a cloud agent's `session_id` is UNKNOWN at spawn time — it is
/// minted host-side on `Attach`, only observable in the GUI once the `Attached`
/// reply lands, i.e. AFTER the launch command (and its `initial_input`) was already
/// sent. And the fork's master `mcp-token` MUST NEVER be shipped to a box (it is the
/// one shell-execution credential — a compromised box could drive `spawn_split_command`
/// on the whole fleet). So instead the GUI mints a **non-secret per-spawn correlation
/// nonce**, injects it into the spawned shell via `initial_input`
/// (`export GHOSTTY_SURFACE_NONCE=…`), and remembers `nonce → (surfaceID, hostName,
/// sessionID)`. The box's agent-state hook POSTs `{nonce, state}` (authenticated with a
/// per-box CAPABILITY token, NOT the master token — see `MCPServer.decideRoute`); the
/// `/agent-state` route resolves the nonce back to the local surface UUID (D6).
///
/// The nonce is a CORRELATION id, not a credential: the SSH same-user boundary already
/// trusts co-processes on the box, and knowing a nonce only lets a caller assert a
/// STATE for a surface it is already co-resident with — never spawn/input. Capability
/// scoping (route-level) is the actual authorization; the nonce just names the surface.
///
/// Thread-safe (an `NSLock`-guarded dict): registration happens on main from the spawn
/// path; resolution happens off-main on the MCP serial queue in the `/agent-state`
/// route. Bounded (FIFO-evicted at `maxEntries`) + TTL-pruned so a never-connecting box
/// can't grow it without bound.
final class RemoteAgentIdentity {
    /// The single app-wide map (the spawn path + the route both reach it).
    static let shared = RemoteAgentIdentity()

    /// One correlation record. `sessionID` is 0 until the host's `Attached` reply lands
    /// (a deferred remote surface spawns with `surface == nil`), then backfilled by
    /// `recordAttached` / a lazy re-read at resolve time — the route needs only the
    /// stable `surfaceID`, so a 0 `sessionID` never blocks correlation.
    struct Identity: Equatable, Sendable {
        let surfaceID: UUID
        let hostName: String
        var sessionID: UInt64
        let createdAt: Date
    }

    /// Cap the map so a box that keeps POSTing nonces that never resolve (or a long
    /// GUI uptime) can't grow it unbounded. FIFO eviction of the oldest.
    static let maxEntries = 512
    /// Drop records older than this (a spawn whose surface never connected / was closed).
    /// Generous — a live correlation is refreshed implicitly by every resolve.
    static let maxAge: TimeInterval = 24 * 3600

    private let lock = NSLock()
    /// nonce → identity.
    private var map: [String: Identity] = [:]
    /// Insertion order of nonces, for FIFO eviction (oldest first).
    private var order: [String] = []

    private init() {}

    // MARK: - Nonce minting (PURE)

    /// Mint a fresh non-secret correlation nonce: 16 CSPRNG bytes → 32 lowercase hex
    /// chars. Hex keeps it shell-safe (no quoting needed in the `export` prefix) and
    /// URL/JSON-safe. Falls back to a UUID-derived hex if `SecRandomCopyBytes` ever
    /// fails (still unique enough for correlation — it is not a credential).
    static func mintNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let rc = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if rc != errSecSuccess {
            let fallback = (UUID().uuidString + UUID().uuidString)
                .replacingOccurrences(of: "-", with: "").lowercased()
            return String(fallback.prefix(32))
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Registration (spawn path, main)

    /// Record a freshly-spawned remote surface's nonce → identity. Called from
    /// `MCPLayout.newSplitCommand` right after the surface is created. `sessionID` is
    /// usually 0 for a deferred remote surface (backfilled later by `recordAttached`).
    func register(nonce: String, surfaceID: UUID, hostName: String, sessionID: UInt64 = 0) {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        pruneLocked(now: now)
        if map[nonce] == nil { order.append(nonce) }
        map[nonce] = Identity(
            surfaceID: surfaceID, hostName: hostName, sessionID: sessionID, createdAt: now)
        evictLocked()
    }

    /// Backfill the host-assigned `sessionID` once the `Attached` reply lands (best
    /// effort — the correlation works off `surfaceID` regardless). No-op for an unknown
    /// nonce or a surface mismatch.
    func recordAttached(nonce: String, sessionID: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard var id = map[nonce] else { return }
        id.sessionID = sessionID
        map[nonce] = id
    }

    // MARK: - Resolution (route, off-main)

    /// Resolve a nonce to its full identity, or nil if unknown / expired. PURE lookup
    /// (no AppKit) — safe to call from the MCP serial queue.
    func resolve(nonce: String) -> Identity? {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked(now: Date())
        return map[nonce]
    }

    /// Convenience: resolve a nonce to just the surface UUID (what the `/agent-state`
    /// route needs to post `.ghosttyAgentStateDidChange`).
    func resolveSurfaceID(nonce: String) -> UUID? {
        resolve(nonce: nonce)?.surfaceID
    }

    /// Drop a nonce (e.g. its surface closed). Idempotent.
    func remove(nonce: String) {
        lock.lock()
        defer { lock.unlock() }
        if map.removeValue(forKey: nonce) != nil {
            order.removeAll { $0 == nonce }
        }
    }

    /// Test/diagnostic: current entry count.
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return map.count
    }

    // MARK: - Eviction (lock held)

    private func pruneLocked(now: Date) {
        guard !order.isEmpty else { return }
        let cutoff = now.addingTimeInterval(-Self.maxAge)
        var kept: [String] = []
        kept.reserveCapacity(order.count)
        for n in order {
            if let id = map[n], id.createdAt >= cutoff {
                kept.append(n)
            } else {
                map[n] = nil
            }
        }
        order = kept
    }

    private func evictLocked() {
        while order.count > Self.maxEntries {
            let oldest = order.removeFirst()
            map[oldest] = nil
        }
    }
}

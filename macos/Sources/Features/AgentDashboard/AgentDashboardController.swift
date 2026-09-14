import AppKit
import Combine
import SwiftUI
import GhosttyKit

/// (ramon fork / Agent Dashboard, Layer 3) One value-type row in the dashboard.
/// PURE value type: the only reference it holds is a WEAK `realView`, deref'd
/// only on main. The model never carries a `ghostty_surface_t` across threads.
struct AgentEntry: Identifiable {
    let id: UUID
    weak var realView: Ghostty.SurfaceView?
    let title: String
    let pwd: String
    let agent: AgentKind?
    let bell: Bool
    /// (ramon fork / Bell Attention) The sticky "attention needed" state the Agent
    /// Manager promoted this surface into via set_attention. Floats the tile to the
    /// top + drives a tile marker; cleared on focus (like `bell`).
    let attention: Bool
    let hidden: Bool
    let sessionID: UInt64
    /// (ramon fork / cloud-hosts, D3) The host this session lives on (`"local"` by
    /// default). Paired with `sessionID` in `sessionKey` for the manual-order rank +
    /// the mirror dial, so two same-`u64` sessions on different hosts never collapse.
    var hostName: String = "local"
    /// The composite `"<host>:<u64>"` key — the stable manual-order identity.
    var sessionKey: String { AgentSessionKey.make(host: hostName, id: sessionID) }
    /// (ramon fork / Agent hooks) The hook-reported agent lifecycle state, or
    /// nil for a hookless tile (one that has never POSTed a hook event).
    let agentState: AgentState?
    /// Last PreToolUse tool name (sticky until the next PreToolUse).
    let lastTool: String?
    /// Last UserPromptSubmit prompt text (truncated by the parser).
    let lastPrompt: String?
    /// True once this surface has EVER reported a hook event — hook state is
    /// authoritative thereafter and MUTES the `idleSeconds` heuristic.
    let hookBacked: Bool
    /// (ramon fork / Agent Manager) The latest LLM annotation (summary) for this
    /// surface, or nil if the summarizer has not annotated it. In-memory ONLY
    /// (NO persistence).
    let annotation: AgentAnnotation?
    /// (ramon fork / Agent hooks) Number of background shells Claude Code reports
    /// still running for this surface (read from its footer; 0 when none / not a
    /// `.waiting` tile). A `.waiting` tile with `> 0` is waiting on its OWN work,
    /// not the user, so it is DEMOTED out of the attention sort + push and shows a
    /// neutral chip. Recomputed each rebuild for waiting tiles; in-memory ONLY.
    let backgroundShells: Int
}

/// (ramon fork / cloud-hosts, Phase 4 · D3/Q4) The COMPOSITE session key namespacing a
/// host session across multiple hosts aggregated into one keyspace: `"<host>:<u64>"`,
/// host defaulting to `"local"`. Used everywhere the dashboard PERSISTS a session id
/// (the agent-state store, the manual order) so two sessions that happen to share a
/// `u64` on DIFFERENT hosts (the host allocSessionId dedups only within one host) never
/// collide / re-associate onto the wrong host across a GUI restart.
enum AgentSessionKey {
    /// Build the composite key. `host` empty ⇒ `"local"`.
    static func make(host: String, id: UInt64) -> String {
        "\(host.isEmpty ? "local" : host):\(id)"
    }

    /// Normalize a persisted key for back-compat: a PRE-migration bare-number key
    /// (e.g. "12345", written before the host namespacing landed) is read as host
    /// `"local"` — mirrors the Codable `decodeIfPresent ?? "local"`. A key already
    /// carrying a `":"` (a composite) is returned unchanged.
    static func normalizeLegacy(_ key: String) -> String {
        key.contains(":") ? key : "local:\(key)"
    }
}

/// Persistence boundary for the hide set, injected so the round-trip is
/// unit-testable with an in-memory fake (LOCKED decision #2: persist across
/// launches in the fork bundle-id UserDefaults domain).
protocol HideStore {
    func load() -> Set<UUID>
    func save(_ ids: Set<UUID>)
}

/// Production hide store backed by the fork bundle-id `UserDefaults.standard`
/// domain (each fork identity already has its own domain). Stores UUID strings.
struct UserDefaultsHideStore: HideStore {
    static let key = "agentDashboardHiddenIDs"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> Set<UUID> {
        let strings = defaults.stringArray(forKey: Self.key) ?? []
        return Set(strings.compactMap { UUID(uuidString: $0) })
    }

    func save(_ ids: Set<UUID>) {
        defaults.set(ids.map { $0.uuidString }, forKey: Self.key)
    }
}

/// In-memory `HideStore` for tests (and as a default in non-persistent contexts).
final class InMemoryHideStore: HideStore {
    private var ids: Set<UUID>
    init(_ ids: Set<UUID> = []) { self.ids = ids }
    func load() -> Set<UUID> { ids }
    func save(_ ids: Set<UUID>) { self.ids = ids }
}

/// (ramon fork / Agent hooks) One persisted agent-state record. Keyed by the
/// HOST session id (see `AgentStateStore`), so a tile's working/waiting/idle
/// status survives a GUI RESTART: the hooks only POST on transitions, so without
/// persistence a relaunched GUI shows a blank chip until the agent next does
/// something (it stays alive on the host across a GUI relaunch, but is usually
/// idle/waiting between events). `updated` is `timeIntervalSince1970`, used only
/// to age-prune dead records.
struct PersistedAgentState: Codable, Equatable {
    var state: String          // AgentState rawValue
    var tool: String?
    var prompt: String?
    var message: String?
    var updated: Double
    // (ramon fork / suspend-resume) Persisted so an IDLE agent's resume token, working
    // dir, and real idle-since time survive a GUI relaunch — idle sessions are long-lived
    // and usually predate a restart, so without this Suspend Split can't resume them until
    // they next fire a hook. Optional ⇒ old records (and non-Claude rows) decode as nil.
    var claudeSessionId: String?   // the `claude --resume <id>` token
    var cwd: String?               // the agent's working directory
    var lastActivity: Double?      // real last-activity (timeIntervalSince1970), distinct
                                   // from `updated` (which is touched to defeat age-pruning)
}

/// Persistence boundary for per-session agent state, injected for testability
/// (mirrors `HideStore`). Keyed by the COMPOSITE session key `"<host>:<u64>"`
/// (`AgentSessionKey`) — the STABLE reattach key across a GUI restart, namespaced by
/// host (D3) so two sessions sharing a `u64` on different hosts never collide. UNLIKE
/// the surface UUID, which is freshly minted each launch (so a UUID-keyed store could
/// never re-associate).
protocol AgentStateStore {
    func load() -> [String: PersistedAgentState]
    func save(_ map: [String: PersistedAgentState])
}

/// Production store backed by the fork bundle-id `UserDefaults` domain. Encodes
/// `[String: PersistedAgentState]` (composite session key → record) as JSON `Data`.
/// On load, a PRE-migration bare-number key is normalized to the `local:` namespace
/// (`AgentSessionKey.normalizeLegacy`) for back-compat.
struct UserDefaultsAgentStateStore: AgentStateStore {
    static let key = "agentDashboardAgentStates"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> [String: PersistedAgentState] {
        guard let data = defaults.data(forKey: Self.key),
              let raw = try? JSONDecoder().decode([String: PersistedAgentState].self, from: data)
        else { return [:] }
        var out: [String: PersistedAgentState] = [:]
        for (k, v) in raw { out[AgentSessionKey.normalizeLegacy(k)] = v }
        return out
    }

    func save(_ map: [String: PersistedAgentState]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// In-memory `AgentStateStore` for tests.
final class InMemoryAgentStateStore: AgentStateStore {
    private var map: [String: PersistedAgentState]
    init(_ map: [String: PersistedAgentState] = [:]) { self.map = map }
    func load() -> [String: PersistedAgentState] { map }
    func save(_ map: [String: PersistedAgentState]) { self.map = map }
}

/// (ramon fork / Agent Dashboard) Persistence boundary for the user's manual
/// tile order, injected for testability (mirrors `HideStore`/`AgentStateStore`).
/// An ORDERED list of stable COMPOSITE session keys `"<host>:<u64>"`
/// (`AgentSessionKey`) — NOT surface UUIDs, which are freshly minted each GUI launch
/// (so a UUID-keyed order could never survive a relaunch — the same lesson
/// `AgentStateStore` encodes), and host-namespaced so cross-host sessions don't collide.
protocol OrderStore {
    func load() -> [String]
    func save(_ order: [String])
}

/// Production order store backed by the fork bundle-id `UserDefaults` domain.
/// Composite session keys are stored as a string array; a PRE-migration bare-number
/// entry is normalized to the `local:` namespace on load (back-compat).
struct UserDefaultsOrderStore: OrderStore {
    static let key = "agentDashboardManualOrder"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> [String] {
        (defaults.stringArray(forKey: Self.key) ?? []).map(AgentSessionKey.normalizeLegacy)
    }

    func save(_ order: [String]) {
        defaults.set(order, forKey: Self.key)
    }
}

/// In-memory `OrderStore` for tests.
final class InMemoryOrderStore: OrderStore {
    private var order: [String]
    init(_ order: [String] = []) { self.order = order }
    func load() -> [String] { order }
    func save(_ order: [String]) { self.order = order }
}

/// (ramon fork / Agent Queue, §11) Persistence boundary for the dashboard's
/// origin FILTER — the set of origins (queue names, or `(other)`) the user has
/// EXCLUDED from the view. A VIEW filter only: an excluded origin's agents are
/// hidden from the tile list but still ring/auto-unhide (attention is never
/// muted). Injected for testability, mirroring `OrderStore`. Keyed by origin
/// STRING (stable across relaunch — the queue name, unlike the surface UUID).
protocol OriginFilterStore {
    func load() -> Set<String>
    func save(_ excluded: Set<String>)
}

/// Production origin-filter store backed by the fork bundle-id `UserDefaults`
/// domain. Stores the excluded origins as a string array.
struct UserDefaultsOriginFilterStore: OriginFilterStore {
    static let key = "agentDashboardExcludedOrigins"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func save(_ excluded: Set<String>) {
        defaults.set(Array(excluded), forKey: Self.key)
    }
}

/// In-memory `OriginFilterStore` for tests.
final class InMemoryOriginFilterStore: OriginFilterStore {
    private var excluded: Set<String>
    init(_ excluded: Set<String> = []) { self.excluded = excluded }
    func load() -> Set<String> { excluded }
    func save(_ excluded: Set<String>) { self.excluded = excluded }
}

/// (ramon fork / Agent Dashboard) Persistence boundary for the set of origin
/// sections (queue names, or `(other)`) the user has COLLAPSED. A pure VIEW
/// preference — a collapsed section hides its tiles but never touches the model's
/// attention/auto-unhide paths (a ringing/waiting agent in a collapsed section
/// still rings + auto-unhides; the header surfaces its bell count). Injected for
/// testability, mirroring `OriginFilterStore`. Keyed by origin STRING (the queue
/// name is stable across relaunch, unlike a surface UUID).
protocol CollapsedSectionStore {
    func load() -> Set<String>
    func save(_ collapsed: Set<String>)
}

/// Production collapsed-section store backed by the fork bundle-id `UserDefaults`
/// domain. Stores the collapsed origins as a string array.
struct UserDefaultsCollapsedSectionStore: CollapsedSectionStore {
    static let key = "agentDashboardCollapsedSections"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func save(_ collapsed: Set<String>) {
        defaults.set(Array(collapsed), forKey: Self.key)
    }
}

/// In-memory `CollapsedSectionStore` for tests.
final class InMemoryCollapsedSectionStore: CollapsedSectionStore {
    private var collapsed: Set<String>
    init(_ collapsed: Set<String> = []) { self.collapsed = collapsed }
    func load() -> Set<String> { collapsed }
    func save(_ collapsed: Set<String>) { self.collapsed = collapsed }
}

/// (ramon fork / Agent Dashboard, Layer 3) The single source of truth for the
/// dashboard. `@MainActor`: every member touches AppKit / `SurfaceView` /
/// `ghostty_surface_*` (which must be main-only). Detection runs off-main and
/// publishes value types back here on main.
@MainActor
final class AgentDashboardModel: ObservableObject {
    /// Sorted, ready-to-render entries (bell-first, then detector-liveness, then
    /// UUID). Excludes hidden ids.
    @Published private(set) var entries: [AgentEntry] = []

    /// Ids hidden by the user. Persisted via `store`. Auto-unhidden on bell
    /// (variant b, LOCKED #1) or the explicit Show/Show-all affordance.
    @Published private(set) var hidden: Set<UUID>

    /// (ramon fork / Agent Dashboard) The app-wide currently-focused surface, or nil.
    /// Drives a LIGHT "you're looking at this" tile treatment (a subtle accent border
    /// + a header dot). VIEW-only — it never affects the sort or the hide set, and a
    /// focused surface that isn't a detected agent simply matches no tile. Updated
    /// from `.ghosttyFocusedSurfaceDidChange` via `setFocusedSurface`.
    @Published private(set) var focusedSurfaceID: UUID?

    /// (ramon fork / Agent Dashboard) The surface currently PINNED (spotlighted) to
    /// the very top of the dashboard by `spotlight_dashboard_split`, or nil. It sorts
    /// absolute-first (above attention/queues — "top is top") and is lifted OUT of its
    /// origin section into a dedicated top row (`spotlightedEntry`). Cleared after
    /// `agent-dashboard-spotlight-seconds` (see `spotlight`) or when another split is spotlighted.
    @Published private(set) var spotlightedSurfaceID: UUID?

    /// Monotonic token that invalidates a superseded spotlight-expiry timer: each
    /// `spotlight` bumps it, so a still-pending expiry from an earlier spotlight is a no-op.
    private var spotlightGeneration = 0

    /// Latest merged bell state across all live controllers. Drives bell-first
    /// sort and bell-only auto-unhide.
    private(set) var bells: [UUID: Bool] = [:]

    /// (ramon fork / Bell Attention) Latest merged "attention needed" state across all
    /// live controllers (set by the Agent Manager via set_attention). Drives the
    /// attention-first sort + auto-unhide + tile marker, gated by the `dashboard` flag
    /// in attention-features (`attnDashboard`).
    private(set) var attention: [UUID: Bool] = [:]

    /// (ramon fork / Bell Attention v2) Whether the `dashboard` effect is routed to each
    /// tier — `bellDashboard` = bell-features.dashboard (a RAW bell unhides + floats the
    /// tile), `attnDashboard` = attention-features.dashboard (a PROMOTED attention does).
    /// The controller passes the real config flags (both default on, so filter-off +
    /// default config ⇒ raw bells drive the dashboard, as upstream).
    private let bellDashboard: Bool
    private let attnDashboard: Bool

    /// Latest detector results, keyed by surface UUID.
    private(set) var agents: [UUID: AgentKind] = [:]

    /// Coarse most-recently-seen-as-agent timestamps (the ~2s detector liveness
    /// heuristic), used as the secondary sort key (variant b — no per-frame
    /// activity tick).
    private(set) var lastSeen: [UUID: Date] = [:]

    // MARK: - Hook state (ramon fork / Agent hooks)

    /// The latest hook-reported lifecycle state per surface. `@Published` so a
    /// tile re-renders when the agent moves working→waiting→idle. Drives the
    /// state chip + the waiting-first sort.
    @Published private(set) var agentStates: [UUID: AgentState] = [:]

    /// Last PreToolUse tool name per surface (sticky until the next PreToolUse).
    private(set) var lastTool: [UUID: String] = [:]

    /// Last UserPromptSubmit prompt text per surface.
    private(set) var lastPrompt: [UUID: String] = [:]

    /// Last Notification message per surface (the "needs input" reason).
    private(set) var lastMessage: [UUID: String] = [:]

    /// (ramon fork / suspend-resume) Claude Code's OWN session id per surface — the
    /// `claude --resume <id>` token, captured passively from the hook (sticky: a nil
    /// field leaves the prior value). DISTINCT from the ghostty-host PTY session id.
    /// Feeds the suspend manifest so Resume can restart the agent conversation.
    private(set) var claudeSessionId: [UUID: String] = [:]

    /// (ramon fork / suspend-resume) The agent's working directory per surface (hook
    /// `cwd`), so Resume can respawn a fresh child in the same dir.
    private(set) var agentCwd: [UUID: String] = [:]

    /// (ramon fork / suspend-resume) Wall-clock timestamp of the last hook event per
    /// surface — "idle since" for the auto-suspend business-day threshold.
    private(set) var lastActivityAt: [UUID: Date] = [:]

    /// Surfaces that have EVER reported a hook event. Hook-authoritative
    /// thereafter (mutes the `idleSeconds` heuristic for these ids).
    private(set) var hookBacked: Set<UUID> = []

    /// (ramon fork / hook-state lease) Consecutive detector ticks that WALKED a
    /// surface holding hook state and found no agent process in its subtree. Reset
    /// by a detector hit or a fresh hook post; at `hookOnlyMissLimit` the surface
    /// joins `staleHookState`. Only LOCAL surfaces are counted (see `applyAgents`).
    private var hookMisses: [UUID: Int] = [:]

    /// (ramon fork / hook-state lease) Surfaces whose hook state is no longer
    /// EVIDENCE of a live agent — the Claude Code process that posted it is gone.
    /// `@Published` because it gates `isAgentSurface`, i.e. whether a tile exists.
    ///
    /// The recorded state itself is deliberately NOT deleted: it stays readable via
    /// `hookSnapshot`/`list_surfaces` (the Agent Queue's close gate reads the last
    /// `agentState` of a finished agent), it is just no longer proof that THIS
    /// surface is running an agent.
    @Published private(set) var staleHookState: Set<UUID> = []

    // MARK: - Manual order (ramon fork / Agent Dashboard)

    /// The user's manual tile order: an ORDERED list of stable COMPOSITE session keys
    /// `"<host>:<u64>"` (`AgentSessionKey`). Drives the manual-rank sort key, which sits
    /// ABOVE the UUID tie-break (placed tiles sort by this list; unplaced tiles — new
    /// agents — float to the top by recency). `@Published` so the "Reset order"
    /// affordance shows/hides reactively. Empty ⇒ no manual order. Persisted via
    /// `orderStore`. Each drag REWRITES this from the displayed order, so it
    /// never grows past the number of visible tiles.
    @Published private(set) var manualOrder: [String] = []

    // MARK: - Annotations (ramon fork / Agent Manager)

    /// The latest LLM annotation per surface, written by the Agent Manager sidecar
    /// through `set_surface_annotation`. `@Published` so a tile re-renders when the
    /// summary changes. In-memory ONLY in Phase 0 — NO persistence (unlike the
    /// hook state above), and pruned on `rebuild(live:)` for vanished surfaces.
    @Published private(set) var annotations: [UUID: AgentAnnotation] = [:]

    /// (ramon fork / Agent Queue, §11 health) The latest run-level health per queue NAME,
    /// pushed by the supervisor via `report_queue_status`. `@Published` so the section
    /// headers re-render. Drives the queue bar's "N waiting · next: …" + the
    /// SHOW-EVEN-WITH-NO-TILES behavior: a present queue here gets a section/header even
    /// when it has zero (or all-hidden) tiles. A `present:false` report removes the entry.
    /// In-memory only (the sidecar re-reports every sweep).
    @Published private(set) var queueStatuses: [String: QueueStatus] = [:]

    /// (ramon fork / Agent Queue, backlog graph) The latest whole-board snapshot per queue
    /// NAME, pushed by the supervisor via `report_queue_graph` (only when the template
    /// declares the optional `provider.graph`). `@Published` so the "N backlog" header
    /// button + the dependency-graph canvas re-render. A `present:false` report removes the
    /// entry (clears the button + canvas). In-memory only (re-pushed each list-cadence sweep).
    @Published private(set) var queueGraphs: [String: QueueGraph] = [:]

    // MARK: - Origin filter (ramon fork / Agent Queue, §11)

    /// Origins (queue names, or `(other)`) the user has EXCLUDED from the view.
    /// `@Published` so the filter bar + tile list re-render on toggle. A VIEW
    /// filter only — `entries` excludes these origins' tiles, but attention paths
    /// (`applyBells` / `applyAgentState` auto-unhide) operate on the full state, so
    /// an excluded-but-ringing/waiting agent STILL rings/pushes/auto-unhides.
    /// Persisted via `originFilterStore`, keyed by origin string (stable across
    /// relaunch, unlike a surface UUID).
    @Published private(set) var excludedOrigins: Set<String> = []

    // MARK: - Collapsed sections (ramon fork / Agent Dashboard)

    /// Origin sections (queue names, or `(other)`) the user has COLLAPSED.
    /// `@Published` so the section headers + tile list re-render on toggle. A
    /// pure VIEW preference — a collapsed section's tiles are not rendered, but
    /// the header still shows its unhidden/total/bell summary, and the model's
    /// attention paths are untouched (a collapsed section's ringing/waiting agent
    /// still rings + auto-unhides). Persisted via `collapsedSectionStore`, keyed
    /// by origin string (stable across relaunch, unlike a surface UUID).
    @Published private(set) var collapsedOrigins: Set<String> = []

    private let store: HideStore
    private let orderStore: OrderStore
    private let originFilterStore: OriginFilterStore
    private let collapsedSectionStore: CollapsedSectionStore

    /// (ramon fork / Agent hooks) How many background shells a `.waiting` surface
    /// has running, used to DEMOTE it (see `AgentEntry.backgroundShells`). Injected
    /// so the demotion logic is unit-testable without a real surface; the default
    /// reads the surface's viewport (Claude Code's footer) on main. Returns 0 when
    /// the surface/view is gone or no indicator is present.
    lazy var backgroundShellReader: (UUID) -> Int = { [weak self] id in
        self?.readBackgroundShellsFromViewport(id) ?? 0
    }

    /// Default `backgroundShellReader`: read the live surface's viewport mirror
    /// (row-accurate under pty-host, same source as the footer-skip) and scan its
    /// footer for the shell-count indicator. Main-only (the model is `@MainActor`);
    /// the read is the 500ms-cached `cachedVisibleContents`, so it is cheap.
    private func readBackgroundShellsFromViewport(_ id: UUID) -> Int {
        guard let view = live.first(where: { $0.id == id })?.view else { return 0 }
        let text = view.cachedVisibleContents.get()
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return AgentMirrorPreview.backgroundShellCount(rows: lines)
    }

    // MARK: - Agent-state persistence (ramon fork / Agent hooks)

    /// Last-known agent state per HOST session id, persisted across GUI restarts
    /// via `agentStore`. Loaded (pruned) at init, rehydrated onto fresh surface
    /// UUIDs in `rebuild(live:)`, and written through on every state change.
    private var restored: [String: PersistedAgentState]
    private let agentStore: AgentStateStore

    /// Drop persisted records older than this on load (a dead session lingering
    /// in UserDefaults). Generous: a live agent's record is refreshed by every
    /// hook event and the periodic touch below, so only genuinely-gone sessions
    /// age out.
    static let persistMaxAge: TimeInterval = 14 * 24 * 3600
    /// Hard cap on persisted records (keep the newest), a backstop against
    /// unbounded growth independent of age.
    static let persistMaxCount = 256
    /// A live session's record is re-saved (timestamp touched) at most this often
    /// during `rebuild`, so a long-idle-but-ALIVE agent isn't age-pruned without
    /// churning UserDefaults on every rebuild.
    static let persistTouchInterval: TimeInterval = 3600

    /// (ramon fork / hook-state lease) How many CONSECUTIVE detector ticks may walk a
    /// hook-only LOCAL surface and find no agent process before its hook state stops
    /// counting as evidence of an agent. At the detector's 2s cadence this is ~30s —
    /// long enough to ride out the hook-lands-before-the-first-walk race (one tick)
    /// plus any transient, short enough that a stale tile is never permanent.
    static let hookOnlyMissLimit = 15

    init(
        store: HideStore,
        agentStateStore: AgentStateStore = InMemoryAgentStateStore(),
        orderStore: OrderStore = InMemoryOrderStore(),
        originFilterStore: OriginFilterStore = InMemoryOriginFilterStore(),
        collapsedSectionStore: CollapsedSectionStore = InMemoryCollapsedSectionStore(),
        // Default true to match the config defaults (dashboard routed to both tiers =
        // upstream "bell drives the dashboard" behavior); the controller passes the real
        // config flags.
        bellDashboard: Bool = true,
        attnDashboard: Bool = true
    ) {
        self.bellDashboard = bellDashboard
        self.attnDashboard = attnDashboard
        self.store = store
        self.agentStore = agentStateStore
        self.orderStore = orderStore
        self.originFilterStore = originFilterStore
        self.collapsedSectionStore = collapsedSectionStore
        self.hidden = store.load()
        self.manualOrder = orderStore.load()
        self.excludedOrigins = originFilterStore.load()
        self.collapsedOrigins = collapsedSectionStore.load()
        let loaded = agentStateStore.load()
        let pruned = AgentDashboardModel.prune(
            loaded, now: Date(),
            maxAge: AgentDashboardModel.persistMaxAge,
            maxCount: AgentDashboardModel.persistMaxCount)
        self.restored = pruned
        if pruned.count != loaded.count { agentStateStore.save(pruned) }
    }

    // MARK: - Hide set

    /// Hide a surface (user gesture). Persists immediately.
    func hide(_ id: UUID) {
        guard !hidden.contains(id) else { return }
        hidden.insert(id)
        store.save(hidden)
        rebuildEntriesFromCurrentState()
    }

    /// Force-close a surface from its tile (user gesture, escape hatch). Tears the split
    /// down via the confirm-FREE path (`MCPLayout.forceClose`, the same one the queue's
    /// auto-close uses) — so it works even on a live agent without popping the
    /// confirm-close-surface modal. The caller is responsible for confirming first (the
    /// tile shows a confirmation dialog). For a QUEUE tile this unblocks the run: once the
    /// surface vanishes, the supervisor's next reconcile prunes the assignment and frees
    /// the slot. The tile disappears on the next detector poll when the surface is gone.
    /// No-op on an unresolved id. MUST be on main — the model is.
    func closeSurface(_ id: UUID) {
        _ = MCPLayout.forceClose(uuid: id)
    }

    /// (ramon fork / Agent Dashboard) Dismiss the bell AND the promoted attention for a
    /// surface from its tile's 🔔 icon, WITHOUT focusing the surface — the exact same
    /// acknowledge the web monitor's phone clear does (`SurfaceView.resetBell` +
    /// `resetAttention`). Because every bell/attention visual (amber frame, 🔔 title
    /// prefix, dock badge, dashboard mark, "needs you"/"needs input" pill) derives from
    /// the surface's single `bell`/`attentionNeeded` flags, clearing them drops the
    /// signal SYSTEM-WIDE, everywhere it's shown. It only clears GUI state, so the raw
    /// bell can ring again and the sidecar re-arms on its next clean classify — a
    /// still-live condition promotes again later. No-op on an unresolved / already-freed
    /// surface (its bell wouldn't be showing then anyway). MUST be on main — the model is.
    func dismissBell(_ id: UUID) {
        guard let view = entries.first(where: { $0.id == id })?.realView else { return }
        view.resetBell()
        view.resetAttention()
    }

    /// Manually reveal a single hidden surface. Persists.
    func show(_ id: UUID) {
        guard hidden.contains(id) else { return }
        hidden.remove(id)
        store.save(hidden)
        rebuildEntriesFromCurrentState()
    }

    /// Reveal everyone. Persists.
    func showAll() {
        guard !hidden.isEmpty else { return }
        hidden.removeAll()
        store.save(hidden)
        rebuildEntriesFromCurrentState()
    }

    // MARK: - Focus highlight + spotlight (ramon fork / Agent Dashboard)

    /// Record the app-wide focused surface (from `.ghosttyFocusedSurfaceDidChange`).
    /// VIEW-only + cheap: it does NOT re-sort or rebuild entries (focus is not a sort
    /// key) — the `@Published` change alone re-renders the tiles, which read
    /// `focusedSurfaceID` to light the focused one. `nil` clears the highlight.
    func setFocusedSurface(_ id: UUID?) {
        guard focusedSurfaceID != id else { return }
        focusedSurfaceID = id
    }

    /// Spotlight `id` at the very top of the dashboard for `duration` seconds
    /// (`duration <= 0` ⇒ until another split is spotlighted): unhide it, mark it spotlighted
    /// (absolute-top sort + lifted into the dedicated `spotlightedEntry` top row), and arm a
    /// one-shot expiry. Re-spotlighting ANY split supersedes the previous spotlight — the earlier
    /// timer is invalidated via `spotlightGeneration`, so its fire is a no-op. Persists the
    /// unhide (shared hide set) and re-sorts. Idempotent-ish: re-spotlighting the same id
    /// simply resets the timer.
    func spotlight(_ id: UUID, duration: TimeInterval) {
        // Unhide without a redundant extra rebuild (we rebuild once, below).
        if hidden.contains(id) {
            hidden.remove(id)
            store.save(hidden)
        }
        spotlightedSurfaceID = id
        spotlightGeneration += 1
        let generation = spotlightGeneration
        rebuildEntriesFromCurrentState()
        guard duration > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self,
                  self.spotlightGeneration == generation,   // not superseded by a later spotlight
                  self.spotlightedSurfaceID == id
            else { return }
            self.spotlightedSurfaceID = nil
            self.rebuildEntriesFromCurrentState()
        }
    }

    /// Clear the spotlight now (the toggle-off / click-to-dismiss path). Bumps
    /// `spotlightGeneration` so any pending expiry timer is invalidated. No-op when
    /// nothing is spotlighted.
    func clearSpotlight() {
        guard spotlightedSurfaceID != nil else { return }
        spotlightedSurfaceID = nil
        spotlightGeneration += 1   // invalidate any pending expiry
        rebuildEntriesFromCurrentState()
    }

    /// Toggle the spotlight for `id`: if `id` is already the spotlighted split, clear it
    /// (so the same keybind dismisses it early instead of waiting out the timer);
    /// otherwise spotlight it. Drives the `spotlight_dashboard_split` keybind.
    func toggleSpotlight(_ id: UUID, duration: TimeInterval) {
        if spotlightedSurfaceID == id {
            clearSpotlight()
        } else {
            spotlight(id, duration: duration)
        }
    }

    /// The spotlighted tile, lifted out of its origin section for the dashboard's dedicated
    /// top row. Nil when nothing is spotlighted or the spotlighted surface isn't a live agent
    /// tile (closed / not detected). `sections` excludes this entry so it never renders
    /// twice.
    var spotlightedEntry: AgentEntry? {
        guard let spotlightedSurfaceID else { return nil }
        return entries.first { $0.id == spotlightedSurfaceID }
    }

    /// Count of hidden surfaces among the provided live id set (for the
    /// "N hidden" chip). PURE over the provided id set — callers pass the agent
    /// subset (`liveAgentIDs`) so a hidden NON-agent split never inflates the
    /// chip.
    func hiddenCount(among liveIDs: Set<UUID>) -> Int {
        hidden.intersection(liveIDs).count
    }

    // MARK: - Manual order (ramon fork / Agent Dashboard)

    /// Apply a user drag-reorder. `sessionIDs` is the new full order of the
    /// CURRENTLY DISPLAYED tiles (WYSIWYG), captured by the view's `.onMove`.
    /// Sessionless tiles (id 0 — e.g. no `pty-host`, or pre-attach) can't be
    /// ordered stably across a relaunch, so they're dropped from the saved
    /// order (they fall back to recency/UUID). Persists and re-sorts.
    func setManualOrder(_ sessionKeys: [String]) {
        // A sessionless tile has key "<host>:0" — it can't be ordered stably across a
        // relaunch, so drop it (it falls back to recency/UUID). Any host's ":0" suffix.
        manualOrder = sessionKeys.filter { !$0.hasSuffix(":0") }
        orderStore.save(manualOrder)
        rebuildEntriesFromCurrentState()
    }

    /// True when the user has a custom order (drives the "Reset order" footer
    /// affordance).
    var hasManualOrder: Bool { !manualOrder.isEmpty }

    /// Clear the manual order → back to attention-first / recency / UUID.
    /// Persists. No-op (and no churn) when already empty.
    func resetOrder() {
        guard !manualOrder.isEmpty else { return }
        manualOrder = []
        orderStore.save(manualOrder)
        rebuildEntriesFromCurrentState()
    }

    // MARK: - Reactive inputs

    /// Apply a fresh merged bell dictionary. A RINGING surface is never left
    /// hidden (LOCKED #1 / spec §4.2(A): "An agent asking for input must never
    /// stay hidden"). We unhide on the CURRENT ringing set — i.e. any
    /// `hidden ∩ ringing` is cleared, not only `false→true` transitions — so the
    /// hide-WHILE-ringing race (user hides a still-ringing tile, the next bell
    /// republish sees `was == true` and would otherwise skip it) cannot strand a
    /// ringing agent. Output / rebuild never auto-unhide (variant b).
    func applyBells(_ next: [UUID: Bool]) {
        var changed = false
        // (ramon fork / Bell Attention v2) A RAW bell auto-unhides only when the
        // `dashboard` effect is routed to the bell tier (bell-features.dashboard). With
        // the filter off the default routes it there ⇒ upstream behavior; with the
        // filter on a user drops it and the promoted attention (applyAttention) unhides.
        if bellDashboard {
            for (id, ringing) in next where ringing {
                if hidden.contains(id) {
                    hidden.remove(id)
                    changed = true
                }
            }
        }
        bells = next
        if changed { store.save(hidden) }
        rebuildEntriesFromCurrentState()
    }

    /// (ramon fork / Bell Attention v2) Apply a fresh merged "attention needed" map. A
    /// PROMOTED surface auto-unhides when the `dashboard` effect is routed to the
    /// attention tier (attention-features.dashboard; the default). Drives the
    /// attention-first sort + the tile marker via `rebuildEntriesFromCurrentState`.
    func applyAttention(_ next: [UUID: Bool]) {
        var changed = false
        if attnDashboard {
            for (id, on) in next where on {
                if hidden.contains(id) {
                    hidden.remove(id)
                    changed = true
                }
            }
        }
        attention = next
        if changed { store.save(hidden) }
        rebuildEntriesFromCurrentState()
    }

    /// Apply fresh detector results (off-main → main). Updates the liveness
    /// timestamps used as the secondary sort key.
    ///
    /// `walked` is the set of surface ids the detector actually WALKED this tick (the
    /// ids in its snapshot — a surface with no foreground pid is absent). It drives the
    /// hook-state LEASE below: only a walked surface can be judged, so "the detector
    /// never looked" is never mistaken for "no agent is there". Defaulted to nil so a
    /// caller with no walk evidence (tests, any non-detector path) leaves the lease
    /// bookkeeping untouched.
    func applyAgents(_ next: [UUID: AgentKind], walked: Set<UUID>? = nil) {
        let now = Date()
        for id in next.keys { lastSeen[id] = now }
        agents = next
        if let walked { updateHookLease(detected: next, walked: walked) }
        rebuildEntriesFromCurrentState()
    }

    /// (ramon fork / hook-state lease) Age the hook-only agent evidence against this
    /// detector tick.
    ///
    /// WHY: a hook post proves a Claude Code process ran in this surface — it does NOT
    /// prove one is running NOW, and the state was previously kept for the surface's
    /// whole life. So any shell that ever shelled out to `claude` (e.g. an account
    /// script running a headless `claude -p` credential probe) became a permanent
    /// dashboard tile. The state is a LEASE: renewed by evidence, expired without it.
    ///
    /// Renewed by EITHER a detector hit (`agents[id] != nil`) or a fresh hook post
    /// (`applyAgentState`). Expired after `hookOnlyMissLimit` consecutive clean walks.
    ///
    /// Scoped to LOCAL surfaces on purpose: the detector walks the LOCAL process table
    /// from the row's foreground pid, which for a REMOTE surface is a pid on the box —
    /// meaningless here. A cross-host agent is exactly the case hook state exists to
    /// cover, so a remote surface is never leased and keeps today's behavior.
    private func updateHookLease(detected: [UUID: AgentKind], walked: Set<UUID>) {
        var nowStale = staleHookState
        for id in walked where agentStates[id] != nil {
            if detected[id] != nil {
                // The process is right there — full renewal.
                hookMisses[id] = nil
                nowStale.remove(id)
                continue
            }
            // Already expired: nothing left to age (and don't churn the counter).
            guard !nowStale.contains(id), isLocalSurface(id) else { continue }
            let misses = (hookMisses[id] ?? 0) + 1
            hookMisses[id] = misses
            if misses >= Self.hookOnlyMissLimit { nowStale.insert(id) }
        }
        if nowStale != staleHookState { staleHookState = nowStale }
    }

    /// True iff `id` is a live surface on the LOCAL host. An id not (yet) in `live` is
    /// treated as non-local — the conservative answer, since the lease only ever
    /// EXPIRES evidence.
    private func isLocalSurface(_ id: UUID) -> Bool {
        live.first(where: { $0.id == id })?.hostName == "local"
    }

    /// (ramon fork / Agent hooks) Apply one hook event (called on main from the
    /// controller's `.ghosttyAgentStateDidChange` observer). Returns true iff
    /// this transition ENTERS `.waiting` (working/idle/nil → waiting), so the
    /// controller can post `.ghosttyAgentNeedsAttention` exactly on that edge.
    ///
    /// App-side coalescing (LOCKED, the PreToolUse second debounce): if the
    /// resolved state AND tool/prompt/message are all unchanged, we RETURN
    /// without mutating the `@Published` state so the chatty PreToolUse stream
    /// doesn't thrash the rebuild.
    ///
    /// (ramon fork / Agent hooks) BACKGROUND-WORK DEMOTION: a transition into
    /// `.waiting` only counts as an attention edge (and only auto-unhides) when the
    /// agent has NO background shell still running — otherwise it is waiting on its
    /// OWN work, not the user, so it must not nag. `backgroundShells` is read from
    /// the surface's footer (injectable for tests; nil → read the live viewport).
    @discardableResult
    func applyAgentState(
        _ id: UUID, _ payload: AgentStatePayload, backgroundShells bgOverride: Int? = nil
    ) -> Bool {
        hookBacked.insert(id)

        // (hook-state lease) A fresh post is fresh evidence: a Claude Code process was
        // alive in this surface just now. Renew before the coalesce early-return below,
        // so a repeat of an unchanged state still counts as a heartbeat.
        hookMisses[id] = nil
        if staleHookState.contains(id) { staleHookState.remove(id) }

        // (suspend-resume) Capture the resume token + cwd BEFORE the coalesce early-return
        // below, so an unchanged-state republish still records them. Sticky: a nil field
        // leaves the prior value (mirrors lastTool/lastPrompt). Plain dicts (not @Published)
        // so this never forces a tile rebuild.
        if let sid = payload.claudeSessionId { claudeSessionId[id] = sid }
        if let dir = payload.cwd { agentCwd[id] = dir }
        // (suspend-resume) Stamp "last agent activity" on every hook event. For an idle
        // agent this is when it went idle (its last Stop/SessionEnd), which the idle
        // scanner reads as "idle since" for the business-day threshold.
        lastActivityAt[id] = Date()

        let prev = agentStates[id]

        // Coalesce: unchanged state + unchanged (present) fields → no rebuild.
        // A nil field in the payload leaves the previous value, so an unchanged
        // state with all-nil incoming fields is a pure republish to swallow.
        let toolUnchanged = payload.tool == nil || payload.tool == lastTool[id]
        let promptUnchanged = payload.prompt == nil || payload.prompt == lastPrompt[id]
        let messageUnchanged = payload.message == nil || payload.message == lastMessage[id]
        if payload.state == prev, toolUnchanged, promptUnchanged, messageUnchanged {
            return false
        }

        agentStates[id] = payload.state
        // A nil field LEAVES the previous value (`tool` is only present on
        // PreToolUse, `prompt` on UserPromptSubmit, `message` on Notification).
        if let tool = payload.tool { lastTool[id] = tool }
        if let prompt = payload.prompt { lastPrompt[id] = prompt }
        if let message = payload.message { lastMessage[id] = message }

        // Background-work demotion gate: only a TRUE waiting (no background shell
        // churning) is an attention edge / auto-unhide. Read once here for the
        // unhide check + the return; rebuildEntriesFromCurrentState reads the same
        // (cached) source for the chip/sort.
        let backgroundShells = payload.state == .waiting
            ? (bgOverride ?? backgroundShellReader(id))
            : 0
        let genuinelyWaiting = payload.state == .waiting && backgroundShells == 0

        // Auto-unhide on .waiting: a waiting agent — one asking the user for
        // input — must never stay hidden. NOTE this is weaker than applyBells'
        // re-unhide-on-every-ringing-republish: it lands only on the (non-
        // coalesced) enters-waiting edge, because a Notification fires ONCE (not
        // continuously like a bell). So after the coalesce early-return above, an
        // identical `.waiting` republish does NOT re-unhide — a user CAN hide a
        // still-waiting tile, by design (single-shot hook + LOCKED coalesce rule).
        // A background-busy waiting tile is NOT auto-unhidden (it isn't nagging).
        if genuinelyWaiting, hidden.contains(id) {
            hidden.remove(id)
            store.save(hidden)
        }

        // Persist the new state keyed by the stable host session id so it
        // survives a GUI restart (ramon fork / hooks). No-op if this surface's
        // session id isn't known yet (`live` not yet populated for it) — the
        // next `rebuild(live:)` reconciles it.
        writeThrough(id: id)

        // We rebuild unconditionally here even if the detector has not yet matched
        // this id as an agent (`agents[id] == nil` → it's filtered out, so this is a
        // no-visible-change invalidation until the ~2s poll confirms it). That wasted
        // rebuild is deliberate and the safer choice: the hook state is retained, and
        // skipping the rebuild risks dropping the one that must fire the instant the
        // detector adds the id. Claude Code is the foreground process, so the gap is
        // a couple seconds at most.
        rebuildEntriesFromCurrentState()

        // The "enters .waiting" edge is `prev != .waiting` — but a background-busy
        // waiting tile is demoted (no push/attention), so it never reports the edge.
        return prev != .waiting && genuinelyWaiting
    }

    /// (ramon fork / Agent Manager) MERGE an annotation update for `id` into the
    /// stored annotation and rebuild the entries so the tile re-renders. Called on
    /// main from the controller's `.ghosttyAgentAnnotationDidChange` observer. NO
    /// persistence + NO coalesce: the sidecar already rate-limits its own writes.
    ///
    /// The incoming `annotation` carries ONLY the fields the writer provided (a
    /// partial update — see `AgentAnnotationPayload.fromArguments`), so we OVERLAY its
    /// non-nil fields onto the prior stored value via `merging(_:)`. This lets the
    /// Haiku summarizer (summary) and the Agent Queue supervisor (queue tags) update
    /// the same surface independently without clobbering each other's field.
    func applyAnnotation(_ id: UUID, _ annotation: AgentAnnotation) {
        annotations[id] = annotations[id]?.merging(annotation) ?? annotation
        rebuildEntriesFromCurrentState()
    }

    /// (ramon fork / Agent Queue, §11 health) Store/clear a run's health snapshot.
    /// `present` ⇒ store (the header shows it + the queue gets a section even with no
    /// tiles); `!present` ⇒ remove (the run was torn down). `@Published`, so the
    /// dashboard re-renders; no entries rebuild needed (sections reads `queueStatuses`).
    func applyQueueStatus(_ status: QueueStatus) {
        if status.present {
            queueStatuses[status.queueName] = status
        } else {
            queueStatuses.removeValue(forKey: status.queueName)
        }
    }

    /// (ramon fork / Agent Queue, backlog graph) Store/clear a run's whole-board snapshot.
    /// `present` ⇒ store (drives the "N backlog" button + canvas); `!present` ⇒ remove (the
    /// run was torn down). `@Published`, so the header button + any open canvas re-render.
    func applyQueueGraph(_ graph: QueueGraph) {
        if graph.present {
            queueGraphs[graph.queueName] = graph
        } else {
            queueGraphs.removeValue(forKey: graph.queueName)
        }
    }

    /// (§11 health) Resolve a queue item (run name + work-item key) to its live surface
    /// UUID by scanning the stored annotations — the supervisor stamps each running
    /// split's surface with `queueName`/`queueKey`, so this finds the split to "go to"
    /// from a running-dropdown row. Returns nil if no live surface carries that tag
    /// (e.g. the agent just finished / its annotation was dropped).
    func surfaceID(forQueue queueName: String, key: String) -> UUID? {
        for (id, ann) in annotations where ann.queueName == queueName && ann.queueKey == key {
            return id
        }
        return nil
    }

    /// (Schedules) Resolve a running SCHEDULE (run name + schedule id) to its live surface
    /// UUID — the scheduled split's surface carries `queueName` + `scheduleId`, so this finds
    /// the split to "go to" from the Schedules-lane focus (▶) button. Returns nil if no live
    /// surface carries that tag (e.g. the scan just closed).
    func surfaceID(forSchedule queueName: String, scheduleID: String) -> UUID? {
        for (id, ann) in annotations where ann.queueName == queueName && ann.scheduleId == scheduleID {
            return id
        }
        return nil
    }

    // MARK: - Reconciliation

    /// Snapshot of one live surface taken on main (value types + weak view).
    struct LiveSurface {
        let id: UUID
        weak var view: Ghostty.SurfaceView?
        let title: String
        let pwd: String
        let sessionID: UInt64
        /// (ramon fork / cloud-hosts, D3) The host this session lives on — the
        /// `pty-remote-host` registry name, or `"local"` (from `SurfaceView.hostName`,
        /// nil ⇒ `"local"`). Paired with `sessionID` it forms the composite persistence
        /// key so a cross-host session never re-associates onto the wrong host.
        var hostName: String = "local"
        /// The composite `"<host>:<u64>"` persistence/rehydration key.
        var sessionKey: String { AgentSessionKey.make(host: hostName, id: sessionID) }
    }

    /// The current live surface snapshot, captured by `rebuild()` on main and
    /// retained so reactive (bell/agent) updates can re-sort without re-walking.
    private var live: [LiveSurface] = []

    /// Reconcile against the live terminal set. Walk happens in the caller (on
    /// main) and is handed in as value types; this stays pure-ish over its
    /// inputs. A panel-open rebuild re-evaluates the live agent set but NEVER
    /// clears the hide set (LOCKED #1).
    func rebuild(live: [LiveSurface]) {
        self.live = live
        // Drop stale per-id state for surfaces that vanished.
        let liveIDs = Set(live.map(\.id))
        bells = bells.filter { liveIDs.contains($0.key) }
        attention = attention.filter { liveIDs.contains($0.key) }
        agents = agents.filter { liveIDs.contains($0.key) }
        lastSeen = lastSeen.filter { liveIDs.contains($0.key) }
        // Prune hook state for vanished surfaces exactly like the other per-id
        // state (a closed surface's hook state is dropped — ramon fork / hooks).
        agentStates = agentStates.filter { liveIDs.contains($0.key) }
        lastTool = lastTool.filter { liveIDs.contains($0.key) }
        lastPrompt = lastPrompt.filter { liveIDs.contains($0.key) }
        lastMessage = lastMessage.filter { liveIDs.contains($0.key) }
        hookBacked = hookBacked.intersection(liveIDs)
        // (hook-state lease) Same pruning rule as the rest of the per-id state.
        hookMisses = hookMisses.filter { liveIDs.contains($0.key) }
        if !staleHookState.isSubset(of: liveIDs) {
            staleHookState = staleHookState.intersection(liveIDs)
        }
        // (ramon fork / Agent Manager) Drop annotations for vanished surfaces too
        // (in-memory only, so nothing is persisted — just don't leak).
        annotations = annotations.filter { liveIDs.contains($0.key) }
        // (ramon fork / hooks) Restore persisted state onto the (freshly-minted)
        // surface UUIDs by their stable host session id, and keep live records
        // fresh. This is what makes statuses survive a GUI restart.
        rehydrateAndPersist(live: live)
        rebuildEntriesFromCurrentState()
    }

    // MARK: - Agent-state persistence helpers (ramon fork / hooks)

    /// Pure: drop records older than `maxAge`, then cap to the `maxCount` newest.
    static func prune(
        _ map: [String: PersistedAgentState], now: Date,
        maxAge: TimeInterval, maxCount: Int
    ) -> [String: PersistedAgentState] {
        let nowS = now.timeIntervalSince1970
        var kept = map.filter { nowS - $0.value.updated <= maxAge }
        if kept.count > maxCount {
            let newest = kept.sorted { $0.value.updated > $1.value.updated }.prefix(maxCount)
            kept = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        return kept
    }

    /// The COMPOSITE session key for a live surface UUID, or nil if unknown (not yet
    /// in the `live` snapshot) or sessionless (host session id 0 — no stable key).
    private func sessionKey(for id: UUID) -> String? {
        guard let s = live.first(where: { $0.id == id }), s.sessionID != 0 else { return nil }
        return s.sessionKey
    }

    /// True iff `a` and `b` carry the same state/tool/prompt/message (IGNORING
    /// `updated`) — so a steady stream of identical states doesn't churn the store.
    private func sameContent(_ a: PersistedAgentState?, _ b: PersistedAgentState) -> Bool {
        guard let a else { return false }
        return a.state == b.state && a.tool == b.tool && a.prompt == b.prompt && a.message == b.message
            && a.claudeSessionId == b.claudeSessionId && a.cwd == b.cwd
    }

    /// Persist the current state for `id`'s host session, if its session id is
    /// known and non-zero. Saves only when the persisted CONTENT changes.
    private func writeThrough(id: UUID) {
        guard let key = sessionKey(for: id), let state = agentStates[id] else { return }
        let rec = PersistedAgentState(
            state: state.rawValue, tool: lastTool[id], prompt: lastPrompt[id],
            message: lastMessage[id], updated: Date().timeIntervalSince1970,
            claudeSessionId: claudeSessionId[id], cwd: agentCwd[id],
            lastActivity: lastActivityAt[id]?.timeIntervalSince1970)
        if !sameContent(restored[key], rec) {
            restored[key] = rec
            agentStore.save(restored)
        }
    }

    /// For each live surface keyed by its stable host session id: HYDRATE the
    /// per-UUID hook state from the persisted record when we have no live state
    /// for it yet (the GUI-restart restore — silent: no push, no waiting-edge
    /// re-fire; the next live hook takes over), and otherwise keep the persisted
    /// record current with live state (plus an occasional timestamp touch so a
    /// long-idle-but-alive agent isn't age-pruned).
    private func rehydrateAndPersist(live: [LiveSurface]) {
        var dirty = false
        let nowS = Date().timeIntervalSince1970
        for s in live where s.sessionID != 0 {
            let key = s.sessionKey
            if agentStates[s.id] == nil {
                guard let rec = restored[key],
                      let state = AgentState(rawValue: rec.state) else { continue }
                agentStates[s.id] = state
                if let t = rec.tool { lastTool[s.id] = t }
                if let p = rec.prompt { lastPrompt[s.id] = p }
                if let m = rec.message { lastMessage[s.id] = m }
                // (suspend-resume) Rehydrate the resume token / cwd / idle-since so an idle
                // agent is suspendable right after a GUI relaunch, without waiting for its
                // next hook event.
                if let sid = rec.claudeSessionId { claudeSessionId[s.id] = sid }
                if let c = rec.cwd { agentCwd[s.id] = c }
                if let la = rec.lastActivity { lastActivityAt[s.id] = Date(timeIntervalSince1970: la) }
                hookBacked.insert(s.id)
            } else if let state = agentStates[s.id] {
                let rec = PersistedAgentState(
                    state: state.rawValue, tool: lastTool[s.id], prompt: lastPrompt[s.id],
                    message: lastMessage[s.id], updated: nowS,
                    claudeSessionId: claudeSessionId[s.id], cwd: agentCwd[s.id],
                    lastActivity: lastActivityAt[s.id]?.timeIntervalSince1970)
                let cur = restored[key]
                let stale = cur.map { nowS - $0.updated > Self.persistTouchInterval } ?? true
                if !sameContent(cur, rec) || stale {
                    restored[key] = rec
                    dirty = true
                }
            }
        }
        if dirty { agentStore.save(restored) }
    }

    /// The set of currently-live surface ids — ALL terminal splits, agent or
    /// not. Used ONLY to distinguish "no terminals open" (state 1) from
    /// "terminals open, zero agents" (state 2) in the degraded-state logic; it
    /// is deliberately NOT the agent subset. The agent subset is `liveAgentIDs`.
    var liveIDs: Set<UUID> { Set(live.map(\.id)) }

    /// The set of currently-live surface ids that the detector matched as CLI
    /// agents. This is the agent-only universe the dashboard actually operates
    /// over (LOCKED "agent-only" decision): entries, the hidden chip count, and
    /// the Show popover are all derived from this, never from `liveIDs`.
    var liveAgentIDs: Set<UUID> { Set(live.map(\.id).filter { isAgentSurface($0) }) }

    /// (ramon fork / cloud-hosts) Is this surface an AGENT for dashboard purposes?
    ///
    /// TWO INDEPENDENT signals, either sufficient:
    ///  1. the local process DETECTOR matched a CLI agent (`agents[id] != nil`), and
    ///  2. Claude Code's own agent-state HOOK has reported for this surface
    ///     (`agentStates[id] != nil`).
    ///
    /// Signal 2 exists because signal 1 is unreliable for a CROSS-HOST agent. Detection
    /// rests on the host-side `/proc` descent (`proc_info.descendToProgram`), which
    /// deliberately GIVES UP when a launcher has more than one non-launcher child — and
    /// an account-pool wrapper has exactly that: `claude` PLUS a transient `sleep`. So
    /// `agents[id]` can stay nil forever while the agent is plainly running (adopted,
    /// queue-tracked, and POSTing state). Only Claude Code runs that hook, so a report
    /// IS proof of an agent; treating it as such is both more robust and more honest than
    /// pattern-matching a process tree through an arbitrary wrapper.
    ///
    /// (ramon fork / hook-state lease) Signal 2 is EVIDENCE, not a permanent fact: a hook
    /// post proves a Claude Code process ran here, not that one is running now. So it is
    /// discounted once `updateHookLease` has watched the detector walk this LOCAL surface
    /// `hookOnlyMissLimit` times running and find no agent — otherwise any shell that ever
    /// shelled out to `claude` (a headless `claude -p` probe) stayed a tile for the
    /// surface's whole life. Signal 1 is unaffected, and a remote surface is never leased.
    func isAgentSurface(_ id: UUID) -> Bool {
        if agents[id] != nil { return true }
        return agentStates[id] != nil && !staleHookState.contains(id)
    }

    /// The agent kind to display for `id`: the DETECTED kind when the process walk found
    /// one, else a hook-implied `claude` (only Claude Code POSTs agent state). Keeps the
    /// tile's badge + the hover controls that gate on a non-nil kind working for a
    /// cross-host agent the detector could not classify. Nil once the hook evidence has
    /// gone stale (same lease as `isAgentSurface`), so `hookSnapshot` → `list_surfaces`
    /// stops calling a plain shell an agent too.
    func displayAgentKind(_ id: UUID) -> AgentKind? {
        if let a = agents[id] { return a }
        guard agentStates[id] != nil, !staleHookState.contains(id) else { return nil }
        return AgentKind("claude")
    }

    /// (ramon fork / Hero Agents) The set of currently-live surface ids annotated as HEROES
    /// (`queueHero`). Drives the web monitor's purple-star mark + "Focus on heroes" filter,
    /// mirroring `liveAgentIDs`/`hidden`. A hero that isn't currently live is dropped.
    var heroIDs: Set<UUID> { Set(live.map(\.id).filter { annotations[$0]?.queueHero == true }) }

    /// (ramon fork / Agent Manager) Per-surface hook/annotation snapshot for the
    /// MCP `list_surfaces` enrichment. Value types only, so the MCP layer can read
    /// it on the existing main hop and never touch the @MainActor model off-main.
    struct HookSnapshotEntry {
        let agentState: String?   // AgentState rawValue, or nil
        let lastPrompt: String?
        let lastTool: String?
        let notes: String?        // annotation summary (the LLM status round-trip)
        /// (ramon fork / Agent Manager) The DETECTED agent kind's command basename
        /// (e.g. "claude"/"codex") from the dashboard's authoritative subtree-walk
        /// detector, or nil. This is the signal the summarizer keys off to decide a
        /// surface is an agent — the foreground `processName` is NOT reliable (under
        /// the claude-pool wrapper the foreground is `bash`; the real `claude` is a
        /// child the detector finds via its process-subtree walk).
        let agentKind: String?
        /// (ramon fork / Agent Manager) Whether the user has HIDDEN this surface's
        /// tile in the dashboard. Surfaced so the summarizer can skip hidden tiles
        /// (no point spending a Haiku call on a tile you've decluttered away). The
        /// hidden set is dashboard view-state, persisted per bundle id.
        let hidden: Bool
        /// (ramon fork / Agent Queue, adopt) The queue tags from this surface's
        /// annotation, echoed into the MCP `list_surfaces` row so the supervisor's
        /// reconcile orphan-adoption can fold an ADOPTED split into `run.active`.
        /// WITHOUT these, an adopted split is annotated + grouped in the dashboard but
        /// never read back by the sidecar (reconcile keys off `queueName`/`queueKey`
        /// from `list_surfaces`), so it stays UNCOUNTED in the health bar AND UNTRACKED
        /// (no status-poll / auto-close). nil when the surface carries no queue tag.
        let queueKey: String?
        let queueName: String?
        let queueUrl: String?
        /// (ramon fork / Hero Agents) The split's HERO verdict from its annotation's
        /// `queueHero`, echoed into the MCP `list_surfaces` row (`SurfaceRow.hero`) so the
        /// supervisor's reconcile reads hero-ness back — the reconcile-visibility chokepoint,
        /// mirroring `queueKey`/`queueName`. nil when the surface carries no annotation / is
        /// not a hero (the row emits `hero:false` then).
        let queueHero: Bool?
        /// (ramon fork / Agent Queue Schedules) The SCHEDULE id from the annotation's
        /// `scheduleId`, echoed into the `list_surfaces` row (`SurfaceRow.scheduleId`) so the
        /// supervisor tracks + re-adopts the scheduled run — the reconcile-visibility chokepoint,
        /// mirroring `queueKey`. nil for a normal split.
        let scheduleId: String?
        /// (ramon fork / cloud-hosts, D3) The host this surface's session lives on
        /// (`"local"` by default). Snapshotted alongside the queue tags so the MCP layer
        /// can pair it with the session id if needed; `MCPLayout.surfaceRows` reads the
        /// authoritative `SurfaceView.hostName` directly, so this is carried for
        /// completeness / a consistent value-type snapshot. Defaulted so existing
        /// constructors are unaffected.
        var hostName: String = "local"
        /// (ramon fork / suspend-resume) Claude Code's OWN session id (the
        /// `claude --resume <id>` token), captured passively from the hook. Echoed into
        /// the MCP `list_surfaces` row (`SurfaceRow.claudeSessionId`) for observability and
        /// to feed the future suspend manifest. DISTINCT from the host PTY session id.
        /// Defaulted so existing constructors are unaffected.
        var claudeSessionId: String? = nil
        /// (ramon fork / suspend-resume) The agent's working dir (hook `cwd`), for respawn
        /// on Resume. Echoed into the `list_surfaces` row (`SurfaceRow.agentCwd`). Defaulted.
        var agentCwd: String? = nil
    }

    /// (ramon fork / suspend-resume) Suspend every idle Claude split that is overdue past
    /// `thresholdBusinessDays`: build the PURE `SuspendPolicy` candidates from the model,
    /// and for each selected id call `SurfaceView.suspend(manifest:)`. A split with no
    /// captured resume id / cwd (can't be resumed) or no last-activity stamp (never idle)
    /// is skipped. Returns the count suspended (for logging/tests). MUST run on main.
    @discardableResult
    func suspendOverdueIdleAgents(now: Date = Date(), thresholdBusinessDays: Int) -> Int {
        var candidates: [SuspendPolicy.Candidate] = []
        var viewByID: [UUID: Ghostty.SurfaceView] = [:]
        for s in live {
            guard let view = s.view, !view.suspended else { continue }
            viewByID[s.id] = view
            candidates.append(.init(
                id: s.id,
                agentKind: displayAgentKind(s.id)?.command,
                isIdle: agentStates[s.id] == .idle,
                // No activity stamp ⇒ distantFuture ⇒ 0 business days elapsed ⇒ never picked.
                lastActivity: lastActivityAt[s.id] ?? Date.distantFuture))
        }
        let picked = SuspendPolicy.surfacesToSuspend(
            candidates, now: now, thresholdBusinessDays: thresholdBusinessDays)
        var count = 0
        for id in picked {
            guard let view = viewByID[id],
                  let manifest = suspendManifest(
                    for: id, title: view.title,
                    foregroundPid: view.foregroundPid.map { pid_t($0) }, now: now) else { continue }
            view.suspend(manifest: manifest)
            count += 1
        }
        return count
    }

    /// (ramon fork / suspend-resume) Build the Resume manifest for a surface, or nil if it
    /// lacks a captured Claude session id / cwd (i.e. can't be resumed). Shared by the idle
    /// scanner and the manual `suspend_split` action.
    func suspendManifest(for id: UUID, title: String, foregroundPid: pid_t? = nil,
                         now: Date = Date()) -> SuspendManifest? {
        var sid = claudeSessionId[id]
        var cwd = agentCwd[id]
        // (transcript recovery) When the resume id/cwd weren't captured (e.g. an idle split
        // that hasn't fired a hook since the GUI launched), recover them from Claude's on-disk
        // transcript for the running claude under this split — what makes an idle split
        // suspendable without first poking it.
        if (sid?.isEmpty ?? true) || (cwd?.isEmpty ?? true), let fg = foregroundPid,
           let rec = TranscriptResolver.recover(foregroundPid: fg) {
            if sid?.isEmpty ?? true { sid = rec.sessionId }
            if cwd?.isEmpty ?? true { cwd = rec.cwd }
        }
        guard let sid, !sid.isEmpty, let cwd, !cwd.isEmpty else { return nil }
        return SuspendManifest(
            claudeSessionId: sid,
            cwd: cwd,
            agentKind: displayAgentKind(id)?.command ?? "claude",
            title: title,
            lastPrompt: lastPrompt[id],
            suspendedAt: now)
    }

    /// (ramon fork / suspend-resume) Manually suspend one split (the `suspend_split`
    /// action). No-op (returns false) if it is already suspended or has no captured resume
    /// id — a plain shell / a Claude split whose hook never reported can't be resumed.
    @discardableResult
    func suspendSurfaceManually(_ view: Ghostty.SurfaceView) -> Bool {
        guard !view.suspended,
              let manifest = suspendManifest(
                for: view.id, title: view.title,
                foregroundPid: view.foregroundPid.map { pid_t($0) }) else { return false }
        view.suspend(manifest: manifest)
        return true
    }

    /// Snapshot the hook + annotation state for every surface that has any of it.
    /// Surfaces with no state at all are omitted, so an absent map entry means
    /// "nothing known" (the MCP shaper then omits those fields — honest absence).
    func hookSnapshot() -> [UUID: HookSnapshotEntry] {
        var out: [UUID: HookSnapshotEntry] = [:]
        // Host per live surface (D3), so the snapshot carries the host identity.
        var hostByID: [UUID: String] = [:]
        for s in live { hostByID[s.id] = s.hostName }
        let ids = Set(agentStates.keys)
            .union(lastPrompt.keys).union(lastTool.keys)
            .union(claudeSessionId.keys).union(agentCwd.keys)
            .union(annotations.keys).union(agents.keys)
            .union(hidden)
        for id in ids {
            out[id] = HookSnapshotEntry(
                agentState: agentStates[id]?.rawValue,
                lastPrompt: lastPrompt[id],
                lastTool: lastTool[id],
                notes: annotations[id]?.summary,
                // (cloud-hardening) Use the DISPLAY kind, not the raw detector map: the
                // sidecar's agent detection keys off `agentKind`, so a cross-host agent the
                // /proc descent could not classify would otherwise get NO Haiku status
                // annotation even though its tile now exists. Hook-implied `claude` fills in.
                agentKind: displayAgentKind(id)?.command,
                hidden: hidden.contains(id),
                queueKey: annotations[id]?.queueKey,
                queueName: annotations[id]?.queueName,
                queueUrl: annotations[id]?.queueUrl,
                queueHero: annotations[id]?.queueHero,
                scheduleId: annotations[id]?.scheduleId,
                hostName: hostByID[id] ?? "local",
                claudeSessionId: claudeSessionId[id],
                agentCwd: agentCwd[id])
        }
        return out
    }

    /// Metadata for one hidden-but-live agent, so the "N hidden" popover can show
    /// `badge · title · Show` (spec §4.3) instead of a raw UUID prefix. Retained
    /// from the `live` snapshot + latest detector results even though the
    /// corresponding entry is filtered out of `entries` while hidden.
    struct HiddenAgent: Identifiable {
        let id: UUID
        let title: String
        let agent: AgentKind?
    }

    /// Hidden agents that are still live, sorted by title for a stable popover.
    /// Restricted to detected agents (LOCKED "agent-only"): a hidden non-agent
    /// split is never offered in the Show popover.
    var hiddenAgents: [HiddenAgent] {
        live
            .filter { hidden.contains($0.id) && isAgentSurface($0.id) }
            .map { HiddenAgent(id: $0.id, title: $0.title, agent: displayAgentKind($0.id)) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func rebuildEntriesFromCurrentState() {
        // "agent-only": a tile exists ONLY for a live split that is an AGENT — either the
        // detector matched a CLI agent OR Claude's own hook has reported state for it
        // (`isAgentSurface`, which is what makes a CROSS-HOST agent visible: the /proc
        // descent gives up on a pool wrapper's `claude`+`sleep` pair). A plain shell / vim
        // / any non-agent split is still never rendered, so spec §2.6 state-2
        // ("No CLI agents running.") remains reachable whenever a terminal is open but no
        // agent is detected.
        let built: [AgentEntry] = live
            .filter { isAgentSurface($0.id) }
            .map { s in
                AgentEntry(
                    id: s.id,
                    realView: s.view,
                    title: s.title,
                    pwd: s.pwd,
                    agent: displayAgentKind(s.id),
                    bell: bells[s.id] ?? false,
                    attention: attention[s.id] ?? false,
                    hidden: hidden.contains(s.id),
                    sessionID: s.sessionID,
                    hostName: s.hostName,
                    agentState: agentStates[s.id],
                    lastTool: lastTool[s.id],
                    lastPrompt: lastPrompt[s.id],
                    hookBacked: hookBacked.contains(s.id),
                    annotation: annotations[s.id],
                    // Only waiting tiles can be demoted, so only they pay the
                    // (cached) viewport read; everything else is 0.
                    backgroundShells: agentStates[s.id] == .waiting
                        ? backgroundShellReader(s.id)
                        : 0
                )
            }
        // composite session key → its index in the user's manual order (keep-first on
        // the (impossible-in-practice) duplicate, to stay total).
        let manualRank = Dictionary(
            manualOrder.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first })
        entries = AgentDashboardModel.sorted(
            built.filter { !$0.hidden }, lastSeen: lastSeen, manualRank: manualRank,
            spotlightedID: spotlightedSurfaceID,
            bellDashboard: bellDashboard, attnDashboard: attnDashboard)
    }

    // MARK: - Sort (pure, testable)

    /// Whether a tile is demanding attention: a bell rang OR the hook reports
    /// the agent is `.waiting` for the user (ramon fork / Agent hooks). Both
    /// inputs are independent — either floats the tile to the top.
    ///
    /// (ramon fork / Agent hooks) A `.waiting` tile with a live background shell
    /// is DEMOTED — it is waiting on its own work, not the user, so it does NOT
    /// float to the top. A bell still floats it (a bell is a real event).
    private static func needsAttention(
        _ e: AgentEntry, bellDashboard: Bool = false, attnDashboard: Bool = false
    ) -> Bool {
        // (ramon fork / Bell Attention v2) A tile floats when the `dashboard` effect is
        // routed to whichever tier is active for it: a raw bell floats iff
        // bell-features.dashboard; a promoted attention floats iff attention-features.
        // dashboard. (A waiting hook state still floats independently.)
        (e.bell && bellDashboard)
            || (e.attention && attnDashboard)
            || (e.agentState == .waiting && e.backgroundShells == 0)
    }

    /// Whether the agent is idle — done with its turn and free for new work.
    /// (ramon fork / Agent hooks) Idle tiles sort ABOVE busy (working / unknown)
    /// ones among equal-rank peers, so a finished agent is easy to spot and hand
    /// the next task to. Below attention + manual order so neither is disturbed.
    private static func isIdle(_ e: AgentEntry) -> Bool {
        e.agentState == .idle
    }

    /// Deterministic order, highest precedence first:
    ///   1. attention-first (bell OR waiting) — demands always float to the top;
    ///   2. user manual order (`manualRank`, keyed by host session id) — an
    ///      UNPLACED tile (no rank) sorts ABOVE a placed one, so a newly-appeared
    ///      agent floats to the top until the user places it; placed tiles sort
    ///      by ascending rank;
    ///   3. idle-above-busy — among equal-rank peers, an idle agent (free for new
    ///      work) sorts above a working/unknown one. With no manual ranks set
    ///      (the common case, all tiles unplaced + tied) this floats every idle
    ///      tile above every busy one;
    ///   4. most-recently-seen-as-agent (descending) — orders the remaining ties
    ///      among themselves;
    ///   5. stable UUID tie-break.
    /// A session id of 0 (no host session) is treated as never-placed: it can't
    /// be ranked stably, so it falls through to idle/recency/UUID.
    static func sorted(
        _ entries: [AgentEntry],
        lastSeen: [UUID: Date] = [:],
        manualRank: [String: Int] = [:],
        // (ramon fork) The spotlighted surface, if any — sorts absolute-first.
        spotlightedID: UUID? = nil,
        // Default true to match the config defaults (dashboard routed to both tiers);
        // the model passes its real flags.
        bellDashboard: Bool = true,
        attnDashboard: Bool = true
    ) -> [AgentEntry] {
        func rank(_ e: AgentEntry) -> Int? {
            // A sessionless tile (host session id 0) can't be ranked stably.
            e.sessionID == 0 ? nil : manualRank[e.sessionKey]
        }
        return entries.sorted { a, b in
            // (ramon fork) Spotlight is the ABSOLUTE top — above attention, manual
            // order, idle/recency, everything ("top is top"). At most one tile matches.
            if let spotlightedID {
                let ap = a.id == spotlightedID, bp = b.id == spotlightedID
                if ap != bp { return ap && !bp }
            }
            let aa = needsAttention(a, bellDashboard: bellDashboard, attnDashboard: attnDashboard)
            let ba = needsAttention(b, bellDashboard: bellDashboard, attnDashboard: attnDashboard)
            if aa != ba { return aa && !ba }
            let ra = rank(a), rb = rank(b)
            // Unplaced (nil) sorts before placed (non-nil): new agents at top.
            if (ra == nil) != (rb == nil) { return ra == nil }
            if let ra, let rb, ra != rb { return ra < rb }
            // Idle (free for new work) floats above busy tiles among equal-rank peers.
            let ai = isIdle(a), bi = isIdle(b)
            if ai != bi { return ai && !bi }
            let sa = lastSeen[a.id] ?? .distantPast
            let sb = lastSeen[b.id] ?? .distantPast
            if sa != sb { return sa > sb }
            return a.id.uuidString < b.id.uuidString
        }
    }

    // MARK: - Origin grouping + filter (ramon fork / Agent Queue, §11)

    /// The label used for non-queue agents (legacy / today's behavior). A queue
    /// tile's origin is its `queueName` annotation; everything else is here.
    static let otherOrigin = "(other)"

    /// PURE: the origin of one tile — its queue name (from the annotation, §8.5),
    /// or `(other)` for a non-queue agent. A blank queue name is treated as
    /// `(other)` (a defensive guard against an empty annotation string).
    static func origin(of entry: AgentEntry) -> String {
        if let q = entry.annotation?.queueName, !q.isEmpty { return q }
        return otherOrigin
    }

    /// PURE: the set of origins present in a tile list. Used to drive the filter
    /// bar (one toggle per known origin). Unit-tested.
    static func knownOrigins(in entries: [AgentEntry]) -> Set<String> {
        Set(entries.map { origin(of: $0) })
    }

    /// PURE: drop tiles whose origin is in `excluded`. The VIEW filter (§11) — it
    /// never touches the model's attention paths, so an excluded agent still
    /// rings/auto-unhides. Unit-tested.
    static func applyOriginFilter(
        _ entries: [AgentEntry], excluded: Set<String>
    ) -> [AgentEntry] {
        guard !excluded.isEmpty else { return entries }
        return entries.filter { !excluded.contains(origin(of: $0)) }
    }

    /// One rendered origin section: a header label + its tiles (already sorted).
    /// `id` is the origin string (stable). The `(other)` section sorts LAST; queue
    /// origins sort case-insensitively before it.
    struct OriginSection: Identifiable, Equatable {
        let id: String          // == origin
        let entries: [AgentEntry]
        /// Count of this origin's HIDDEN agents (NOT in `entries`, which is the
        /// unhidden set). Set by `groupByOrigin` from the per-origin hidden tally,
        /// so the collapsed-section header can show "unhidden / total".
        let hiddenCount: Int
        /// Unhidden tile count (the agents rendered when expanded).
        var count: Int { entries.count }
        /// Total agents in this origin = unhidden + hidden.
        var totalCount: Int { entries.count + hiddenCount }
        /// Number of unhidden tiles currently ringing the bell. Bells auto-unhide,
        /// so every ringing agent is in `entries` — this is exact.
        var bellCount: Int { entries.lazy.filter(\.bell).count }
        /// True for the catch-all `(other)` section (no queue controls on it).
        var isOther: Bool { id == AgentDashboardModel.otherOrigin }

        init(id: String, entries: [AgentEntry], hiddenCount: Int = 0) {
            self.id = id
            self.entries = entries
            self.hiddenCount = hiddenCount
        }

        static func == (lhs: OriginSection, rhs: OriginSection) -> Bool {
            lhs.id == rhs.id
                && lhs.hiddenCount == rhs.hiddenCount
                && lhs.entries.map(\.id) == rhs.entries.map(\.id)
                && lhs.entries.map(\.bell) == rhs.entries.map(\.bell)
        }
    }

    /// PURE: group an already-sorted, already-filtered tile list into ordered
    /// origin sections — queue origins first (case-insensitive by name), the
    /// `(other)` catch-all LAST. Within a section the input order is preserved
    /// (the caller passes the global `sorted(...)` order, so attention-first /
    /// manual / recency carries into each section). Unit-tested.
    static func groupByOrigin(
        _ entries: [AgentEntry],
        presentQueues: Set<String> = [],
        hiddenCountByOrigin: [String: Int] = [:]
    ) -> [OriginSection] {
        var order: [String] = []           // first-seen origin order (for tie-stable grouping)
        var buckets: [String: [AgentEntry]] = [:]
        for e in entries {
            let o = origin(of: e)
            if buckets[o] == nil { order.append(o) }
            buckets[o, default: []].append(e)
        }
        // (§11 health) Ensure every PRESENT queue gets a section even with NO entries —
        // so its bar (controls + status) stays visible before any split spawns AND when
        // every tile is hidden/filtered. `(other)` is never a queue, so it's excluded.
        for q in presentQueues where q != otherOrigin && buckets[q] == nil {
            buckets[q] = []
            order.append(q)
        }
        // An origin whose ONLY agents are hidden still needs a section so its
        // collapsed/expanded header (with the "0 of N" summary) is reachable.
        for (o, n) in hiddenCountByOrigin where n > 0 && buckets[o] == nil {
            buckets[o] = []
            order.append(o)
        }
        // Queue origins sorted case-insensitively, `(other)` always last.
        let origins = order.sorted { a, b in
            if a == otherOrigin { return false }
            if b == otherOrigin { return true }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        return origins.map {
            OriginSection(id: $0, entries: buckets[$0] ?? [], hiddenCount: hiddenCountByOrigin[$0] ?? 0)
        }
    }

    // MARK: - Origin filter (instance API)

    /// All origins currently present among the (unfiltered) displayed tiles —
    /// drives the filter bar's toggle list. Derived from `entries` (which is the
    /// sorted, non-hidden, but NOT origin-filtered set — see the note below) so the
    /// bar always offers a toggle for every visible origin, including excluded ones
    /// (so the user can re-include them).
    var knownOrigins: Set<String> { AgentDashboardModel.knownOrigins(in: entries) }

    /// Whether the view should render the origin filter bar. Pure + unit-tested.
    /// Shown when there's more than one origin to choose between (a single-origin
    /// fleet needs no filter) OR whenever an exclusion is active — the latter is the
    /// load-bearing case: soloing a queue that later ends can leave `(other)` excluded
    /// as the SOLE remaining origin, which would silently filter out every tile with
    /// no way to reach "Show all". Keeping the bar visible whenever anything is
    /// excluded guarantees the escape hatch is always reachable.
    static func shouldShowFilterBar(
        knownOrigins: Set<String>, excludedOrigins: Set<String>
    ) -> Bool {
        knownOrigins.count > 1 || !excludedOrigins.isEmpty
    }

    /// Instance accessor for `shouldShowFilterBar` over the current state.
    var showsFilterBar: Bool {
        AgentDashboardModel.shouldShowFilterBar(
            knownOrigins: knownOrigins, excludedOrigins: excludedOrigins)
    }

    /// The displayed, origin-filtered tiles grouped into ordered sections. The
    /// `entries` list is the global-sorted, non-hidden set (NOT origin-filtered);
    /// the origin filter is applied HERE so the model's attention logic and the
    /// filter-bar toggle list both see the full origin set.
    var sections: [OriginSection] {
        // (ramon fork) The spotlighted tile is rendered in a dedicated top row
        // (`spotlightedEntry`) ABOVE all origin sections, so drop it here to avoid a
        // double render. `entries` is already sorted (spotlight-first) + non-hidden.
        let unspotlighted = spotlightedSurfaceID == nil
            ? entries
            : entries.filter { $0.id != spotlightedSurfaceID }
        let filtered = AgentDashboardModel.applyOriginFilter(unspotlighted, excluded: excludedOrigins)
        // (§11 health) Present queues (minus any the user filtered out) get a section even
        // with no tiles — so the bar stays put while a queue is starting / all hidden.
        let present = Set(queueStatuses.keys).subtracting(excludedOrigins)
        // Per-origin hidden tally (filtered the same way) feeds each section's
        // "unhidden / total" summary + keeps a fully-hidden origin's header reachable.
        let hiddenByOrigin = hiddenCountByOrigin().filter { !excludedOrigins.contains($0.key) }
        return AgentDashboardModel.groupByOrigin(
            filtered, presentQueues: present, hiddenCountByOrigin: hiddenByOrigin)
    }

    /// Count of HIDDEN live agents per origin (queue name or `(other)`). A hidden
    /// agent is excluded from `entries`, so its origin is read from its annotation
    /// directly (the same rule as `origin(of:)`, kept for hidden surfaces too —
    /// annotations are pruned only on vanish). Feeds the collapsed-section summary.
    private func hiddenCountByOrigin() -> [String: Int] {
        var out: [String: Int] = [:]
        for s in live where hidden.contains(s.id) && isAgentSurface(s.id) {
            let o: String
            if let q = annotations[s.id]?.queueName, !q.isEmpty { o = q }
            else { o = AgentDashboardModel.otherOrigin }
            out[o, default: 0] += 1
        }
        return out
    }

    // MARK: - Collapsed sections (ramon fork / Agent Dashboard)

    /// Whether the given origin's section is collapsed in the view.
    func isCollapsed(_ origin: String) -> Bool {
        collapsedOrigins.contains(origin)
    }

    /// Toggle a section's collapsed state (a header gesture). Persists. Does NOT
    /// touch the hide set or attention paths — a collapsed section's ringing/waiting
    /// agent still rings + auto-unhides (the header surfaces its bell count).
    func toggleCollapsed(_ origin: String) {
        if collapsedOrigins.contains(origin) {
            collapsedOrigins.remove(origin)
        } else {
            collapsedOrigins.insert(origin)
        }
        collapsedSectionStore.save(collapsedOrigins)
    }

    /// Toggle an origin's inclusion in the view. Excluded ⇄ included. Persists.
    /// Does NOT touch the hide set or attention paths — a re-included origin's
    /// tiles reappear immediately; an excluded origin's agents keep ringing.
    func toggleOrigin(_ origin: String) {
        if excludedOrigins.contains(origin) {
            excludedOrigins.remove(origin)
        } else {
            excludedOrigins.insert(origin)
        }
        originFilterStore.save(excludedOrigins)
    }

    /// SOLO an origin: show ONLY this origin (exclude all others). Clicking the
    /// already-soloed origin clears the filter (show all) — a toggle. This is the
    /// filter bar's badge tap behavior ("show only that", not "hide that"). PURE
    /// helper `soloExclusion` computes the new exclusion set for testability.
    func soloOrigin(_ origin: String) {
        let target = AgentDashboardModel.soloExclusion(origin, known: knownOrigins, current: excludedOrigins)
        excludedOrigins = target
        originFilterStore.save(excludedOrigins)
    }

    /// (pure, testable) The exclusion set for a solo tap: every known origin EXCEPT
    /// `origin` — UNLESS that's already the current exclusion (origin is the sole shown
    /// one), in which case clear (show all). Mirrors the "tap to isolate, tap again to
    /// reset" toggle.
    static func soloExclusion(
        _ origin: String, known: Set<String>, current: Set<String>
    ) -> Set<String> {
        let others = known.subtracting([origin])
        return current == others ? [] : others
    }

    /// Re-include every origin (clear the filter). Persists. No-op when empty.
    func showAllOrigins() {
        guard !excludedOrigins.isEmpty else { return }
        excludedOrigins.removeAll()
        originFilterStore.save(excludedOrigins)
    }

    // MARK: - Queue run control (ramon fork / Agent Queue, §8a/§11)

    /// Post a `pause`/`resume`/`stop`/`abort` control intent for a queue RUN
    /// (origin = run name) onto the MCP server's FIFO via `.ghosttyQueueCommand` —
    /// the SAME enqueue path the palette + the keybind action use. The sidecar
    /// supervisor drains + applies it on its next sweep (§8a). No-op for the
    /// `(other)` catch-all (it is not a queue run). The model never holds run
    /// state — this is a one-way control intent (single owner = the sidecar).
    func sendRunCommand(_ action: QueueCommand.Action, run: String) {
        guard run != AgentDashboardModel.otherOrigin, !run.isEmpty else { return }
        // OPTIMISTIC: reflect the phase change instantly (the sidecar's next push, ~one sweep
        // later, reconciles). Without this the header lags a full sweep + its Linear round-trips.
        if let existing = queueStatuses[run] {
            switch action {
            case .pause:  queueStatuses[run] = existing.withPhase("paused")
            case .resume: queueStatuses[run] = existing.withPhase("running")
            case .stop:   queueStatuses[run] = existing.withPhase("draining")
            case .abort:  queueStatuses.removeValue(forKey: run)  // section clears immediately
            default: break
            }
        }
        NotificationCenter.default.post(
            name: .ghosttyQueueCommand,
            object: nil,
            userInfo: [
                QueueCommandUserInfoKey.command:
                    QueueCommand(action: action, run: run),
            ])
    }

    /// (live maxItems edit) Post a `set_max_items` intent for a queue RUN — re-set its
    /// lifetime dispatch cap WITHOUT restarting it. `value` is the raw user string
    /// ("10", "unlimited"/"0"/…); the sidecar parses it (blank/garbage = ignored, so a
    /// fat-finger never silently removes the cap). Same FIFO path as `sendRunCommand`.
    func setQueueMaxItems(run: String, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard run != AgentDashboardModel.otherOrigin, !run.isEmpty, !trimmed.isEmpty else { return }
        // OPTIMISTIC: show a VALID cap instantly (the sidecar's next push reconciles, and
        // corrects if it parsed differently). A blank/garbage value (`.none`) is left as-is —
        // the sidecar ignores it, so we must not fake a change the engine won't make.
        if let existing = queueStatuses[run],
           case let .some(parsed) = QueueStatus.parseCapOptimistic(trimmed) {
            queueStatuses[run] = existing.withMaxItems(parsed)
        }
        NotificationCenter.default.post(
            name: .ghosttyQueueCommand,
            object: nil,
            userInfo: [
                QueueCommandUserInfoKey.command:
                    QueueCommand(action: .setMaxItems, run: run, maxItems: trimmed),
            ])
    }

    /// (live concurrency edit) Post a `set_concurrency` intent for a queue RUN — re-set its
    /// max SIMULTANEOUS agents WITHOUT restarting it. `value` is the raw user string ("9");
    /// the sidecar parses it (blank/garbage/non-positive = ignored). Raising it past the
    /// template `cols*rows` also lifts the pane cap sidecar-side (§12). Same FIFO path as
    /// `sendRunCommand`.
    func setQueueConcurrency(run: String, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard run != AgentDashboardModel.otherOrigin, !run.isEmpty, !trimmed.isEmpty else { return }
        // OPTIMISTIC: show a VALID value instantly (the sidecar's next push reconciles). A
        // blank/garbage/non-positive value parses to nil and is left as-is — the sidecar
        // ignores it too, so we must not fake a change the engine won't make.
        if let existing = queueStatuses[run],
           let parsed = QueueStatus.parseConcurrencyOptimistic(trimmed) {
            queueStatuses[run] = existing.withConcurrency(parsed)
        }
        NotificationCenter.default.post(
            name: .ghosttyQueueCommand,
            object: nil,
            userInfo: [
                QueueCommandUserInfoKey.command:
                    QueueCommand(action: .setConcurrency, run: run, concurrency: trimmed),
            ])
    }

    // MARK: - (Schedules) recurring scan-agent lane controls

    /// (Schedules) Post a single-schedule control intent (pause / resume / run-now) for a queue
    /// RUN onto the MCP FIFO — the sidecar's `coerceQueueCommands` recognizes the snake_case
    /// action and `applyCommand` mutates the run's per-schedule state on its next (reactively
    /// woken) sweep, which re-pushes the status so the lane reflects it. No optimistic update:
    /// the round-trip is ~one wake (the reactive loop), and the schedule state lives only in the
    /// sidecar. No-op for the `(other)` catch-all / empty ids.
    func sendScheduleCommand(_ action: QueueCommand.Action, run: String, scheduleID: String) {
        guard run != AgentDashboardModel.otherOrigin, !run.isEmpty, !scheduleID.isEmpty else { return }
        NotificationCenter.default.post(
            name: .ghosttyQueueCommand,
            object: nil,
            userInfo: [
                QueueCommandUserInfoKey.command:
                    QueueCommand(action: action, run: run, scheduleId: scheduleID),
            ])
    }

    func pauseSchedule(run: String, scheduleID: String) {
        sendScheduleCommand(.pauseSchedule, run: run, scheduleID: scheduleID)
    }
    func resumeSchedule(run: String, scheduleID: String) {
        sendScheduleCommand(.resumeSchedule, run: run, scheduleID: scheduleID)
    }
    func runScheduleNow(run: String, scheduleID: String) {
        sendScheduleCommand(.runScheduleNow, run: run, scheduleID: scheduleID)
    }

    /// (Schedules) Pause EVERY schedule of a run (the vacation switch) — one `pause_all_schedules`
    /// command (`run` only). Same FIFO path.
    func pauseAllSchedules(run: String) {
        guard run != AgentDashboardModel.otherOrigin, !run.isEmpty else { return }
        NotificationCenter.default.post(
            name: .ghosttyQueueCommand,
            object: nil,
            userInfo: [
                QueueCommandUserInfoKey.command:
                    QueueCommand(action: .pauseAllSchedules, run: run),
            ])
    }

    /// (keep) Toggle one queue split's KEEP state (the dashboard 📌 pin) — exempt it from the
    /// supervisor's auto-close so the user can do manual work after the task is done (or
    /// un-keep it). `id` is the surface, `run` its queue (origin) name, `key` its work-item
    /// key. OPTIMISTICALLY flips the stored annotation's `queueKeep` so the pin updates
    /// instantly; the sidecar's `set_keep` is the authoritative path (it sets the per-split
    /// override, persists it, and re-stamps the annotation, reconciling this). No-op for the
    /// `(other)` catch-all or a missing key. Same FIFO path as the other run controls.
    func setQueueKeep(id: UUID, run: String, key: String, keep: Bool) {
        guard run != AgentDashboardModel.otherOrigin, !run.isEmpty, !key.isEmpty else { return }
        // OPTIMISTIC: merge the new keep verdict onto the stored annotation so the tile flips
        // immediately (the sidecar's next restamp confirms / corrects it).
        let prior = annotations[id] ?? AgentAnnotation()
        annotations[id] = prior.merging(AgentAnnotation(queueKeep: keep))
        rebuildEntriesFromCurrentState()
        NotificationCenter.default.post(
            name: .ghosttyQueueCommand,
            object: nil,
            userInfo: [
                QueueCommandUserInfoKey.command:
                    QueueCommand(action: .setKeep, run: run, key: key, keep: keep),
            ])
    }

    /// (release) Release one HELD item (`key`) — or EVERY held item in `run` (`key` nil) — from
    /// the §7.1 dispatch latch, so the supervisor re-dispatches it on its next `list` poll
    /// WITHOUT a tracker status round-trip. A held item was dispatched once but is suppressed by
    /// the latch (its agent crashed/exited, or was killed before claiming, and the item is still
    /// in the backlog). OPTIMISTICALLY drops the released key(s) from the run's `held` set so the
    /// "N held" chip updates instantly; the sidecar's next push reconciles. No-op for the
    /// `(other)` catch-all. Same FIFO path as the other run controls.
    func releaseQueueItem(run: String, key: String?) {
        guard run != AgentDashboardModel.otherOrigin, !run.isEmpty else { return }
        // OPTIMISTIC: remove the released key (or all held) from the stored status.
        if let existing = queueStatuses[run] {
            if let key, !key.isEmpty {
                queueStatuses[run] = existing.withHeld(existing.held.filter { $0.key != key })
            } else {
                queueStatuses[run] = existing.withHeld([])
            }
        }
        NotificationCenter.default.post(
            name: .ghosttyQueueCommand,
            object: nil,
            userInfo: [
                QueueCommandUserInfoKey.command:
                    QueueCommand(action: .release, run: run, key: key),
            ])
    }

    // MARK: - Adopt a free split into a queue (ramon fork / Agent Queue, adopt)

    /// (adopt) Pull an existing human-created CLI-agent split (`id`) into the running
    /// queue `run`, tracking it as work-item `key`. Posts an `adopt` command onto the
    /// SAME FIFO the other run controls use (no MCP tool of its own). The sidecar
    /// LATCHES the key (blocking a second dispatch), MOVES the split into the run's grid
    /// tab, stamps queueKey/queueName(/queueUrl), and lets reconcile fold it in as a
    /// RUNNING assignment. NO optimistic annotation flip — the sidecar's reconcile is the
    /// single authority on `run.active` (mirrors `setQueueKeep` minus the optimistic
    /// merge). No-op for `(other)` / a blank run or key.
    func adoptSplit(id: UUID, run: String, key: String, url: String?) {
        guard run != AgentDashboardModel.otherOrigin, !run.isEmpty, !key.isEmpty else { return }
        NotificationCenter.default.post(
            name: .ghosttyQueueCommand,
            object: nil,
            userInfo: [
                QueueCommandUserInfoKey.command:
                    QueueCommand(action: .adopt, run: run, key: key,
                                 surfaceUUID: id.uuidString, url: url),
            ])
    }

    // MARK: - Promote / demote a split to/from HERO (ramon fork / Hero Agents)

    /// (promote) Flip a RUNNING regular split (`id`) into a HERO in queue `run` (tracking
    /// work-item `key`, optional). Ejects the split into its OWN new tab (single terminal,
    /// out of the BSP grid) via the SAME `move_split_to_new_tab` machinery the keybind
    /// uses — done GUI-side IMMEDIATELY so the hero visibly pops out of the grid — then posts
    /// a `promote` command onto the SAME FIFO the other run controls use. OPTIMISTICALLY flips
    /// the stored annotation's `queueHero` so the tile's hero visual + across-tabs tab marker
    /// update instantly; the sidecar is authoritative (it sets the run-level `hero` bit for
    /// the two-pool accounting, re-ejects — a no-op on the now-solitary tab — and re-stamps
    /// the annotation, reconciling this). Promotion NEVER blocks: it may push over the
    /// fleet-wide `agent-queue-hero-max`; no NEW heroes dispatch until live heroes drain back
    /// under. No-op for the `(other)` catch-all / a blank run. MUST be on main — the model is.
    func promoteToHero(id: UUID, run: String, key: String) {
        guard run != AgentDashboardModel.otherOrigin, !run.isEmpty else { return }
        // EJECT into its own tab immediately (GUI-side, responsive). A no-op on a
        // single-surface tab (move_split_to_new_tab guards on `surfaceTree.isSplit`), so a
        // later sidecar re-eject on the now-solitary tab is harmless.
        _ = MCPLayout.performAction(uuid: id, action: "move_split_to_new_tab")
        // OPTIMISTIC: merge the hero verdict onto the stored annotation so the tile flips
        // (the sidecar's next restamp confirms / corrects it).
        let prior = annotations[id] ?? AgentAnnotation()
        annotations[id] = prior.merging(AgentAnnotation(queueHero: true))
        rebuildEntriesFromCurrentState()
        NotificationCenter.default.post(
            name: .ghosttyQueueCommand,
            object: nil,
            userInfo: [
                QueueCommandUserInfoKey.command:
                    QueueCommand(action: .promote, run: run,
                                 key: key.isEmpty ? nil : key,
                                 surfaceUUID: id.uuidString),
            ])
    }

    /// (demote) Flip a HERO split (`id`) back into a regular tracked item in queue `run`
    /// (work-item `key`, optional): the sidecar clears its run-level `hero` bit so it
    /// re-enters the regular pool for future accounting and drops the hero marker. Demotion
    /// does NOT re-pack the split back into a grid tab (it stays in its own tab, like any kept
    /// split — HERO-AGENTS.md non-goal), so there is NO move here. OPTIMISTICALLY flips the
    /// stored annotation's `queueHero` false so the tile's hero visual + tab marker clear
    /// instantly; the sidecar's next restamp reconciles. No-op for the `(other)` catch-all /
    /// a blank run. MUST be on main — the model is.
    func demoteFromHero(id: UUID, run: String, key: String) {
        guard run != AgentDashboardModel.otherOrigin, !run.isEmpty else { return }
        let prior = annotations[id] ?? AgentAnnotation()
        annotations[id] = prior.merging(AgentAnnotation(queueHero: false))
        rebuildEntriesFromCurrentState()
        NotificationCenter.default.post(
            name: .ghosttyQueueCommand,
            object: nil,
            userInfo: [
                QueueCommandUserInfoKey.command:
                    QueueCommand(action: .demote, run: run,
                                 key: key.isEmpty ? nil : key,
                                 surfaceUUID: id.uuidString),
            ])
    }

    /// (adopt) Request an on-demand Haiku inference of the work-item key for split `id`,
    /// to prefill the adopt modal. First CLEARS any stale `queueKeySuggested` for that
    /// surface DIRECTLY (the `clearingSuggestion()` bypass — NOT via `merging`, which
    /// never nils, so a prior suggestion would otherwise linger), then posts an
    /// `infer_key` command onto the FIFO. The result returns asynchronously as a
    /// `queueKeySuggested` annotation via the normal annotation path; the modal observes
    /// it. No-op when `run` is empty (the GUI only requests infer with a chosen run — the
    /// multi-run "" case is handled by re-firing on the picker's onChange).
    func requestInferKey(id: UUID, run: String) {
        guard !run.isEmpty else { return }
        // DIRECT clear (NOT via applyAnnotation/merging — see clearingSuggestion()).
        if let prior = annotations[id] {
            annotations[id] = prior.clearingSuggestion()
            rebuildEntriesFromCurrentState()
        }
        NotificationCenter.default.post(
            name: .ghosttyQueueCommand,
            object: nil,
            userInfo: [
                QueueCommandUserInfoKey.command:
                    QueueCommand(action: .inferKey, run: run, surfaceUUID: id.uuidString),
            ])
    }

    /// (adopt) The names of the queue runs currently present (the adopt-modal picker's
    /// options, LOCKED #4). Empty ⇒ the Adopt button is disabled; a single name ⇒ the
    /// modal auto-selects it and hides the picker. Sorted for a stable picker order.
    func runNamesForAdopt() -> [String] {
        queueStatuses.filter { $0.value.present }.keys.sorted()
    }

    /// (adopt) Look up a work-item node in a run's LOCAL backlog graph (LOCKED #1: the
    /// instant, round-trip-free title-preview source). Returns nil when the run has no
    /// graph or the key isn't on its board ("not on this queue's board" — still
    /// adoptable). Backs the modal's live title preview + the optional queueUrl.
    func graphNodeForAdopt(run: String, key: String) -> QueueGraph.Node? {
        queueGraphs[run]?.nodes.first { $0.key == key }
    }

    /// (adopt) The GUI-visible set of work-item keys currently RUNNING in `run` — the
    /// modal's duplicate-key guard source. A soft proxy for the sidecar's authoritative
    /// `run.active.has(key)` check (the `adopt` reducer rejects a true duplicate); the
    /// GUI guard just blocks Confirm + offers a jump before the command is even sent.
    func activeKeysForRun(_ run: String) -> Set<String> {
        Set((queueStatuses[run]?.running ?? []).map(\.key))
    }

    /// (adopt) Jump to the split currently running work-item `key` in `run` — the
    /// "Jump to the running one" affordance the adopt modal offers when the user enters a
    /// DUPLICATE key (one already active in the target run). Resolves the surface via the
    /// stored annotations (`surfaceID(forQueue:key:)`) and presents it on the SAME path a
    /// tile tap / the running-dropdown's go-to uses (raise window, select tab, unzoom,
    /// highlight). Deferred to the next runloop so the present runs after the panel's
    /// key-window change settles (see `AgentPreviewTile.jump`). No-op when no live surface
    /// carries that tag.
    func jumpToKey(run: String, key: String) {
        guard let id = surfaceID(forQueue: run, key: key) else { return }
        DispatchQueue.main.async {
            for controller in TerminalController.all {
                for v in controller.surfaceTree where v.id == id {
                    controller.unzoomIfHidden(v)
                    NotificationCenter.default.post(
                        name: Ghostty.Notification.ghosttyPresentTerminal,
                        object: v)
                    return
                }
            }
        }
    }
}

/// (ramon fork / Agent Dashboard, Layer 3) Owns the panel, the SwiftUI host
/// view, the model, and the detector. App-wide singleton owned by AppDelegate,
/// independent of any terminal window.
@MainActor
final class AgentDashboardController: NSWindowController {
    private let model: AgentDashboardModel
    private let ghostty: Ghostty.App

    /// Combine subscriptions: per-controller bell publishers + tree sinks + the
    /// app-wide churn notifications.
    private var cancellables = Set<AnyCancellable>()
    private var controllerCancellables: [ObjectIdentifier: Set<AnyCancellable>] = [:]

    private let detector: AgentDetector

    /// (ramon fork / suspend-resume) Low-frequency timer that auto-suspends idle Claude
    /// splits past the business-day threshold. Runs regardless of whether the dashboard
    /// is shown (it's about RAM, not the panel), gated on `SuspendSettings.enabled`
    /// (OFF by default). nil until `startSuspendScan()`.
    private var suspendScanTimer: Timer?

    /// Suspend-scan cadence (seconds). Coarse: the threshold is in business DAYS, so a
    /// few minutes of latency to notice an idle split is immaterial.
    private static let suspendScanInterval: TimeInterval = 300

    /// (ramon fork / Agent Dashboard, tab mode) How the dashboard is presented.
    /// `.panel` = the original floating `AgentDashboardPanel`; `.tab` = docked as a
    /// native leftmost tab in a terminal window's group (`AgentDashboardTabWindow`);
    /// `.off` = hidden. The `toggle_agent_dashboard` action CYCLES panel → tab →
    /// off → panel, and the choice is remembered across launches (`presentationKey`).
    enum Presentation: String { case panel, tab, off }

    /// The current presentation. Starts `.off` (nothing shown) so a lazily-created
    /// controller's first `cycle()` opens the panel; `restoreAtLaunch` sets the
    /// remembered value at startup (persisted as `presentationKey`, migrated from
    /// the legacy `wasVisibleKey` bool on the first launch after upgrade).
    private(set) var presentation: Presentation = .off

    /// The docked-tab window when `presentation == .tab` and a terminal window is
    /// available to host it; nil in panel/off mode or while dormant (no terminal
    /// window to dock into yet — a later `didBecomeMain` docks it).
    private var tabWindow: AgentDashboardTabWindow?

    /// Whether the dashboard is currently visible in EITHER shell. Derived from
    /// `presentation` so all the existing `isShown`-gated observers keep working.
    var isShown: Bool { presentation != .off }

    static let wasVisibleKey = "agentDashboardWasVisible"
    static let presentationKey = "agentDashboardPresentation"
    static let autosaveName = "com.mitchellh.ghostty.agentDashboard"

    init(ghostty: Ghostty.App) {
        self.ghostty = ghostty
        self.model = AgentDashboardModel(
            store: UserDefaultsHideStore(),
            agentStateStore: UserDefaultsAgentStateStore(),
            orderStore: UserDefaultsOrderStore(),
            originFilterStore: UserDefaultsOriginFilterStore(),
            collapsedSectionStore: UserDefaultsCollapsedSectionStore(),
            bellDashboard: ghostty.config.bellFeatures.contains(.dashboard),
            attnDashboard: ghostty.config.attentionFeatures.contains(.dashboard))
        self.detector = AgentDetector(commands: Set(ghostty.config.agentDashboardCommands))

        let panel = AgentDashboardPanel(pinned: ghostty.config.agentDashboardPin)
        super.init(window: panel)

        let host = makeHostingView()

        // First-run default frame, THEN autosave name (autosave wins on every
        // later run; the default only takes effect the very first time).
        // Guard against older-macOS SwiftUI corrupting the frame when the
        // contentView is first hosted: pin `initialFrame` across the
        // contentView assignment (QuickTerminalWindow's zero-size hack), so the
        // override returns the real frame rather than a zeroed one.
        panel.setFrame(Self.defaultFrame(), display: false)
        panel.initialFrame = panel.frame
        panel.contentView = host
        panel.initialFrame = nil
        panel.setFrameAutosaveName(Self.autosaveName)
        panel.delegate = self

        detector.onResults = { [weak self] results, walked in
            self?.model.applyAgents(results, walked: walked)
        }

        subscribeChurn()
        subscribeWindowLifecycle()
        subscribeAgentState()
        subscribeAnnotation()
        subscribeQueueStatus()
        subscribeQueueGraph()
        subscribeFocus()
        rebuildControllerObservers()
        startSuspendScan()
    }

    /// (ramon fork / suspend-resume) Start the periodic idle auto-suspend scan. The timer
    /// always runs (cheap: a no-op when `SuspendSettings.enabled` is false), so toggling
    /// the setting takes effect on the next tick without restarting. `[weak self]` so it
    /// never keeps the controller alive.
    private func startSuspendScan() {
        suspendScanTimer?.invalidate()
        suspendScanTimer = Timer.scheduledTimer(
            withTimeInterval: Self.suspendScanInterval, repeats: true
        ) { [weak self] _ in
            // The timer fires on the main run loop; hop the isolation assertion so the
            // @MainActor model call is legal under strict concurrency.
            MainActor.assumeIsolated { self?.runSuspendScan() }
        }
    }

    /// One idle auto-suspend pass. No-op unless enabled. MainActor: the timer fires on the
    /// main run loop, and it mutates SurfaceViews.
    private func runSuspendScan() {
        guard SuspendSettings.enabled else { return }
        model.suspendOverdueIdleAgents(thresholdBusinessDays: SuspendSettings.businessDays)
    }

    /// (ramon fork / suspend-resume) Manually suspend a split (the `suspend_split` action,
    /// routed here from the AppDelegate notification observer). Always available regardless
    /// of `SuspendSettings.enabled` — a manual suspend is an explicit user gesture.
    func suspendSurface(_ view: Ghostty.SurfaceView) {
        if !model.suspendSurfaceManually(view) {
            // Never a silent no-op: tell the user why nothing happened.
            view.showSuspendNotice(view.suspended
                ? "Already suspended."
                : "Can't suspend: no resumable Claude session captured in this split yet.")
        }
    }

    /// Build a fresh `NSHostingView` mounting the shared `AgentDashboardView`. Used
    /// for the panel's content and, in tab mode, the docked tab's content — only
    /// ONE is mounted at a time (the inactive shell's content is released), so there
    /// is a single set of mirror `SurfaceView`s regardless of presentation.
    private func makeHostingView(maxContentWidth: CGFloat? = nil) -> NSHostingView<AnyView> {
        let dashboard = AgentDashboardView(
            model: model,
            ghostty: ghostty,
            ptyHostEnabled: ghostty.config.ptyHost != nil,
            commands: ghostty.config.agentDashboardCommands
        )
        let root: AnyView
        if let cap = maxContentWidth {
            // Docked-tab mode: the tab spans the FULL (wide) terminal-window width,
            // which would blow up the mirror-preview scale (huge text). Cap the
            // dashboard column to the panel's chosen width, leading-aligned, so tiles
            // size exactly like the floating panel; fill the rest with window bg.
            root = AnyView(
                ZStack(alignment: .topLeading) {
                    Color(nsColor: .windowBackgroundColor)
                    dashboard.frame(maxWidth: cap, maxHeight: .infinity, alignment: .topLeading)
                }
            )
        } else {
            root = AnyView(dashboard)
        }
        let host = NSHostingView(rootView: root)
        host.autoresizingMask = [.width, .height]
        return host
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    // MARK: - Show / hide / presentation

    /// (ramon fork / Agent Dashboard, tab mode) The single action bound to
    /// `toggle_agent_dashboard`: CYCLE the presentation panel → tab → off → panel.
    /// This is how you move the dashboard between the floating panel (best on an
    /// external monitor) and a docked leftmost tab (best on a small laptop screen
    /// that wants the terminal full-screen), and how you hide it. The chosen state
    /// is remembered across launches.
    func cycle() {
        apply(Self.nextPresentation(presentation))
    }

    /// Pure cycle transition for `toggle_agent_dashboard`: panel → tab → off →
    /// panel. Extracted so the state machine is unit-testable without NSWindow.
    nonisolated static func nextPresentation(_ current: Presentation) -> Presentation {
        switch current {
        case .panel: return .tab
        case .tab:   return .off
        case .off:   return .panel
        }
    }

    /// Pure launch-presentation resolution: use the persisted `presentationKey`
    /// value if it parses; otherwise MIGRATE from the legacy `wasVisibleKey` bool
    /// (nil = first-ever run ⇒ panel shown). Extracted for unit tests.
    nonisolated static func resolveLaunchPresentation(
        persisted: String?,
        legacyWasVisible: Bool?
    ) -> Presentation {
        if let persisted, let parsed = Presentation(rawValue: persisted) {
            return parsed
        }
        return (legacyWasVisible ?? true) ? .panel : .off
    }

    /// Kept for source compatibility with the AppDelegate handler name; the action
    /// now CYCLES rather than plain show/hide (see `cycle()`).
    func toggle() { cycle() }

    /// (ramon fork / Agent Dashboard, tab mode) Apply a presentation, driving the
    /// shell transitions and persisting the choice. Exactly one shell is mounted at
    /// a time: entering `.tab` releases the panel's content and docks the tab;
    /// entering `.panel` undocks the tab and remounts the panel; `.off` tears both
    /// down. Idempotent enough to call repeatedly.
    func apply(_ p: Presentation) {
        presentation = p
        UserDefaults.standard.set(p.rawValue, forKey: Self.presentationKey)
        // Keep the legacy bool coherent for any older read path + migration.
        UserDefaults.standard.set(p != .off, forKey: Self.wasVisibleKey)

        switch p {
        case .panel:
            undockTab()
            showPanel()
        case .tab:
            hidePanel()
            releasePanelContent()
            dockTabIntoFocusedWindow(select: true)
        case .off:
            undockTab()
            hidePanel()
            releasePanelContent()
        }
        updateDetector()
    }

    /// Hide the given surface from the dashboard (driven by the
    /// `hide_dashboard_split` keybind, routed here by the AppDelegate). Hide-only
    /// — idempotent on an already-hidden split (reveal from the panel's Show
    /// button). This only mutates the persisted hide set — it does NOT show/hide
    /// the panel itself.
    func hide(surfaceID id: UUID) {
        model.hide(id)
    }

    /// (ramon fork / Web monitor) Hide or reveal a surface in the SAME persisted,
    /// UUID-keyed hide set as the tile eye-slash button / `hide_dashboard_split`
    /// keybind — driven from the phone. `hidden:true` hides, `false` reveals. So a
    /// phone hide IS a desktop hide (unified), and the web monitor's "Hide hidden"
    /// list filter then drops it. Auto-unhide-on-bell still applies. MUST be on
    /// main — the model is.
    func setHidden(surfaceID id: UUID, hidden: Bool) {
        if hidden { model.hide(id) } else { model.show(id) }
    }

    /// (ramon fork / Agent Dashboard) TOGGLE the spotlight for the given surface
    /// (driven by the `spotlight_dashboard_split` keybind). Pressing it on the
    /// already-spotlighted split clears it (dismiss early instead of waiting out the
    /// timer); otherwise it unhides the split and floats its tile to the top for
    /// `agent-dashboard-spotlight-seconds` (0 = until another split is spotlighted).
    /// Only the SPOTLIGHT-ON branch OPENS the panel (the whole point is to SEE the
    /// agent) — a toggle-off leaves panel visibility alone. Reads the pre-toggle state
    /// to decide, then shows first so the surface is already in `live` when it re-sorts.
    func spotlight(surfaceID id: UUID) {
        let willSpotlight = model.spotlightedSurfaceID != id
        if willSpotlight {
            // Spotlight must SHOW the dashboard (the point is to see the agent). If
            // it's off, restore to the panel. If it's a docked tab, bring that tab
            // forward so the spotlighted tile is actually on screen.
            if presentation == .off {
                apply(.panel)
            } else if presentation == .tab {
                // Dormant tab mode (persisted .tab but not yet docked): dock now +
                // select, so spotlight actually surfaces the agent instead of no-op'ing
                // on a nil tab window. Otherwise just bring the docked tab forward.
                if tabWindow == nil { dockTabIntoFocusedWindow(select: true) }
                else { tabWindow?.makeKeyAndOrderFront(nil) }
            }
        }
        model.toggleSpotlight(id, duration: TimeInterval(ghostty.config.agentDashboardSpotlightSeconds))
    }

    /// (ramon fork / Agent Dashboard, tab mode) Jump to the dashboard — the
    /// `focus_agent_dashboard` keybind. Reveals + focuses it in its current
    /// presentation: in tab mode select the docked tab (docking into the focused
    /// terminal window if it's dormant); in panel mode bring the panel forward; if
    /// off, bring it up as a tab and select it.
    func focusDashboard() {
        switch presentation {
        case .off:
            apply(.tab)            // dockTabIntoFocusedWindow(select: true) via apply
        case .tab:
            if tabWindow == nil { dockTabIntoFocusedWindow(select: true) }
            else { tabWindow?.makeKeyAndOrderFront(nil) }
        case .panel:
            showPanel()
            window?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: Panel shell

    /// Mount + order the floating panel front, resuming its mirror renderers. The
    /// async re-drive handles mirror `SurfaceView`s that SwiftUI mounts a runloop
    /// after layout (empty on the synchronous pass) — see `setMirrorOcclusion`.
    private func showPanel() {
        guard let panel = window else { return }
        ensurePanelContent()
        rebuild()
        rebuildControllerObservers()
        panel.orderFrontRegardless()
        setMirrorOcclusion(true, in: panel)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentation == .panel else { return }
            self.setMirrorOcclusion(true, in: panel)
        }
    }

    /// Order the panel out + pause its mirrors. Does NOT mutate persistence (the
    /// caller owns that) — used both by an explicit `.off`/`.tab` transition and at
    /// teardown so an open-at-quit panel re-opens next launch.
    private func hidePanel() {
        guard let panel = window else { return }
        setMirrorOcclusion(false, in: panel)
        panel.orderOut(nil)
    }

    /// Mount the panel's SwiftUI content if it isn't currently (it's released while
    /// the tab shell is active so only one mirror set exists at a time).
    private func ensurePanelContent() {
        guard let panel = window else { return }
        if !(panel.contentView is NSHostingView<AnyView>) {
            panel.contentView = makeHostingView()
        }
    }

    /// Release the panel's SwiftUI content (drops its mirror `SurfaceView`s) when
    /// leaving panel mode, so the tab shell owns the only mirror set.
    private func releasePanelContent() {
        guard let panel = window,
              panel.contentView is NSHostingView<AnyView> else { return }
        setMirrorOcclusion(false, in: panel)
        panel.contentView = NSView()
    }

    // MARK: Tab shell

    /// The terminal window a fresh dock should target: the key terminal window,
    /// else the main one, else any visible/first terminal window. Nil when no
    /// terminal window exists yet (dock is deferred; a `didBecomeMain` retries).
    private func focusedTerminalWindow() -> NSWindow? {
        if let kw = NSApp.keyWindow, kw.windowController is TerminalController { return kw }
        if let mw = NSApp.mainWindow, mw.windowController is TerminalController { return mw }
        // ONLY a VISIBLE terminal window. A closed terminal window LINGERS in
        // `NSApp.windows` (Ghostty windows are `releasedWhenClosed = NO`), so an
        // unconditional `.first?.window` fallback would re-dock into a just-closed
        // zombie — resurrecting a phantom dashboard window (and keeping the app
        // alive) after the user closed their last terminal, in the default
        // `quit-after-last-window-closed = false` config. No visible terminal ⇒ nil
        // ⇒ the dashboard stays dormant and re-docks when one next becomes active.
        return TerminalController.all.first(where: { $0.window?.isVisible == true })?.window
    }

    /// Create (if needed) + dock the dashboard tab LEFTMOST in the focused terminal
    /// window's tab group. `select` brings the tab forward (a user cycle) vs. just
    /// slotting it in without stealing the terminal's selection (launch restore).
    /// A no-op (stays dormant) when no terminal window exists yet.
    private func dockTabIntoFocusedWindow(select: Bool) {
        guard presentation == .tab else { return }
        guard let host = focusedTerminalWindow() else {
            // Dormant: no terminal to host it. A later terminal `didBecomeMain`
            // (see `subscribeChurn`) docks it. Drop any stale tab window.
            undockTab()
            return
        }

        if tabWindow == nil {
            let win = AgentDashboardTabWindow()
            win.setFrame(host.frame, display: false)
            // Cap the dashboard column at the panel's width so the tab (full
            // terminal-window width) doesn't blow up the preview scale.
            win.contentView = makeHostingView(maxContentWidth: Self.defaultWidth)
            win.delegate = self
            tabWindow = win
        }
        guard let win = tabWindow, host !== win else { return }

        // Insert leftmost: add BELOW the group's current first window (the
        // `.below` = to-the-left pattern used by fullscreen tab restore). Remove
        // first if macOS already auto-grouped it, so ordering is deterministic.
        if let group = host.tabGroup, let first = group.windows.first {
            if group.windows.contains(win) { group.removeWindow(win) }
            if first === win {
                host.addTabbedWindowSafely(win, ordered: .below)
            } else {
                first.addTabbedWindowSafely(win, ordered: .below)
            }
        } else {
            host.addTabbedWindowSafely(win, ordered: .below)
        }

        if select { win.makeKeyAndOrderFront(nil) }
        rebuild()
        rebuildControllerObservers()
        let visible = win.occlusionState.contains(.visible)
        setMirrorOcclusion(visible, in: win)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentation == .tab, let w = self.tabWindow else { return }
            self.setMirrorOcclusion(w.occlusionState.contains(.visible), in: w)
        }
    }

    /// Remove the dashboard tab from its group + close it, releasing its mirrors.
    /// Safe to call when not docked.
    private func undockTab() {
        guard let win = tabWindow else { return }
        setMirrorOcclusion(false, in: win)
        win.contentView = NSView()
        if let group = win.tabGroup, group.windows.contains(win) {
            group.removeWindow(win)
        }
        win.delegate = nil
        tabWindow = nil
        win.close()
    }

    /// Resume/pause the off-main agent detector with the dashboard's visibility.
    private func updateDetector() {
        if presentation == .off {
            detector.pause()
        } else {
            detector.resume(snapshotProvider: { [weak self] in self?.detectorSnapshot() ?? [] })
        }
    }

    // MARK: Launch / teardown

    /// Restore the remembered presentation at launch. Reads `presentationKey`;
    /// on first launch after upgrade (key absent) it MIGRATES from the legacy
    /// `wasVisibleKey` bool (first-ever run → panel shown). For `.tab`, docking is
    /// deferred until a terminal window exists (tried immediately, else a
    /// `didBecomeMain` docks it).
    func restoreAtLaunch() {
        let defaults = UserDefaults.standard
        let legacy: Bool? = defaults.object(forKey: Self.wasVisibleKey) == nil
            ? nil
            : defaults.bool(forKey: Self.wasVisibleKey)
        let p = Self.resolveLaunchPresentation(
            persisted: defaults.string(forKey: Self.presentationKey),
            legacyWasVisible: legacy)

        if p == .tab {
            presentation = .tab
            defaults.set(p.rawValue, forKey: Self.presentationKey)
            defaults.set(true, forKey: Self.wasVisibleKey)
            // Release the panel's init-time content (empty at launch — the model
            // has no live surfaces yet — but keep hygiene explicit) so the tab shell
            // owns the only content, and DON'T steal the terminal's selection.
            releasePanelContent()
            dockTabIntoFocusedWindow(select: false)
            updateDetector()
        } else {
            apply(p)
        }
    }

    func teardown() {
        // Order the panel out + undock the tab WITHOUT clobbering the persisted
        // presentation, so an open-at-quit dashboard re-opens next launch. Don't
        // call apply() (that would persist `.off`).
        hidePanel()
        undockTab()
        detector.pause()
    }

    /// Drive `ghostty_surface_set_occlusion` across the mirror SurfaceViews so
    /// their renderers pause when the panel is hidden and resume when shown
    /// (spec §8). Mirrors are inside the SwiftUI host hierarchy; we find them by
    /// walking the content view's SurfaceViews.
    ///
    /// The call is driven UNCONDITIONALLY, NOT gated on the per-view
    /// `isWindowVisible` bookkeeping. That guard is unsafe here: the core
    /// renderer defaults `visible = true` (`src/renderer/Thread.zig`) while a
    /// freshly-mounted `SurfaceView` carries the Swift-side default
    /// `isWindowVisible = false`. A tile mounted WHILE the panel is already open
    /// (a new agent appearing, or a `.id(sessionID)` remount) therefore has a
    /// stale `false` that would make the equality guard SKIP the `false` call on
    /// the next `hide()`, leaving that mirror rendering while hidden and
    /// defeating the spec §8 "panel hidden ⇒ near-zero preview cost" invariant.
    /// `ghostty_surface_set_occlusion` is idempotent, so an unconditional call
    /// is safe and correct; we still write `isWindowVisible` to keep SurfaceView's
    /// own drag-restore bookkeeping coherent.
    private func setMirrorOcclusion(_ visible: Bool, in host: NSWindow? = nil) {
        guard let content = (host ?? activeHostWindow)?.contentView else { return }
        for surfaceView in Self.surfaceViews(in: content) {
            guard let surface = surfaceView.surface else { continue }
            ghostty_surface_set_occlusion(surface, visible)
            surfaceView.isWindowVisible = visible
        }
    }

    /// The window currently presenting the dashboard content (panel or docked tab),
    /// or nil when off / dormant. Drives occlusion + the ⌘V key-window ownership.
    private var activeHostWindow: NSWindow? {
        switch presentation {
        case .panel: return window
        case .tab:   return tabWindow
        case .off:   return nil
        }
    }

    /// (ramon fork / Agent Dashboard, tab mode) True iff `candidate` is (or is a
    /// sheet/child of) the dashboard's panel OR its docked tab window. Lets
    /// `AppDelegate.localEventKeyDown` route the standard editing keys to a
    /// dashboard modal's field editor in BOTH presentations.
    func ownsWindow(_ candidate: NSWindow?) -> Bool {
        guard let candidate else { return false }
        let mine: [NSWindow] = [window, tabWindow].compactMap { $0 }
        guard !mine.isEmpty else { return false }
        var current: NSWindow? = candidate
        var hops = 0
        while let win = current, hops < 8 {
            if mine.contains(where: { $0 === win }) { return true }
            current = win.sheetParent ?? win.parent
            hops += 1
        }
        return false
    }

    /// Recursively collect the mirror `SurfaceView`s mounted in the active shell.
    private static func surfaceViews(in view: NSView) -> [Ghostty.SurfaceView] {
        var out: [Ghostty.SurfaceView] = []
        if let sv = view as? Ghostty.SurfaceView { out.append(sv) }
        for sub in view.subviews { out.append(contentsOf: surfaceViews(in: sub)) }
        return out
    }

    // MARK: - Observation

    private func subscribeChurn() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.willCloseNotification,
            NSWindow.didBecomeMainNotification,
            .terminalWindowBellDidChangeNotification,
        ]
        for name in names {
            center.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    // Always re-attach bell observers (cheap) so a window opened
                    // WHILE the dashboard is hidden still gets its bell wired up
                    // — a bell there must auto-unhide a hidden tile even before
                    // the panel is next opened (the bell publisher is the
                    // guaranteed auto-unhide trigger, variant b). Only the
                    // grid/entry recompute is gated on visibility.
                    self.rebuildControllerObservers()
                    if self.isShown { self.rebuild() }
                    // (tab mode) If we want a docked tab but don't have one yet
                    // (launch before any terminal existed, or the host window
                    // closed), dock into the now-available terminal window.
                    self.redockIfDormant()
                }
                .store(in: &cancellables)
        }
    }

    /// (ramon fork / Agent Dashboard, tab mode) Dock the tab when we WANT tab mode
    /// but have no tab window (launch before any terminal existed, or the host
    /// window closed). Deferred one runloop so it never targets a window that is
    /// mid-close (a `willCloseNotification` fires BEFORE the window leaves
    /// `NSApp.windows`). Guarded on `tabWindow == nil`, so it does NOT follow focus
    /// once docked — the tab stays where you put it.
    private func redockIfDormant() {
        guard presentation == .tab, tabWindow == nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentation == .tab, self.tabWindow == nil,
                  self.focusedTerminalWindow() != nil else { return }
            self.dockTabIntoFocusedWindow(select: false)
        }
    }

    /// (ramon fork / Agent Dashboard, tab mode) Keep the docked tab consistent as
    /// windows close: when its host window closes (the tab itself goes away) re-dock
    /// into another terminal window if one remains; when the tab is left alone in a
    /// group (its last terminal sibling closed) undock so it can't strand the group
    /// or keep the app alive (it is not counted as a terminal window). Uses
    /// `willCloseNotification`; the group membership is re-checked next runloop, once
    /// AppKit has settled the close.
    private func subscribeWindowLifecycle() {
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self, let closing = note.object as? NSWindow else { return }
                self.handleWindowWillClose(closing)
            }
            .store(in: &cancellables)
    }

    private func handleWindowWillClose(_ closing: NSWindow) {
        // Our own tab window is closing (host window closed, or the tab's ⨯). Drop
        // the reference; if we still want tab mode and a terminal remains, re-dock.
        if closing === tabWindow {
            setMirrorOcclusion(false, in: tabWindow)
            tabWindow = nil
            // If we still want tab mode and a terminal remains, re-dock (deferred).
            redockIfDormant()
            return
        }

        // A terminal window closed. If our tab is now the only member left in its
        // group (no terminal siblings), undock it — then re-dock elsewhere if any
        // terminal window remains, else go dormant so the app can terminate.
        guard presentation == .tab, tabWindow != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentation == .tab, let win = self.tabWindow else { return }
            let terminals = (win.tabGroup?.windows ?? []).filter {
                $0.windowController is TerminalController
            }
            guard terminals.isEmpty else { return }
            self.undockTab()
            if self.focusedTerminalWindow() != nil {
                self.dockTabIntoFocusedWindow(select: false)
            }
        }
    }

    /// (ramon fork / Agent hooks) Observe `.ghosttyAgentStateDidChange` posted
    /// by the MCP `/agent-state` handler after it resolves the hook tty to a
    /// surface UUID. Registered UNCONDITIONALLY (like the bell observers, NOT
    /// gated on `isShown`): a `.waiting` event must auto-unhide + push even while
    /// the panel is hidden. The model already rebuilds its `@Published` entries,
    /// so there is nothing extra to do when shown.
    private func subscribeAgentState() {
        NotificationCenter.default.publisher(for: .ghosttyAgentStateDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self,
                      let id = note.userInfo?[AgentStateUserInfoKey.surfaceID] as? UUID,
                      let payload = note.userInfo?[AgentStateUserInfoKey.payload] as? AgentStatePayload
                else { return }
                let enteredWaiting = self.model.applyAgentState(id, payload)
                if enteredWaiting {
                    // Re-post the attention notification with title/pwd resolved
                    // on main (mirrors the bell auto-unhide path); WebPush
                    // observes this to fire a push.
                    self.postNeedsAttention(id: id, message: payload.message ?? "")
                }
            }
            .store(in: &cancellables)
    }

    /// (ramon fork / Agent Manager) Observe `.ghosttyAgentAnnotationDidChange`
    /// posted by the MCP `set_surface_annotation` handler after it resolves the
    /// tool's id to a surface UUID. Mirrors `subscribeAgentState`: registered
    /// unconditionally (not gated on `isShown`) and hands the annotation to the
    /// model, which rebuilds its `@Published` entries.
    private func subscribeAnnotation() {
        // (ramon fork / Agent Queue latency) NO `.receive(on: DispatchQueue.main)` here — the SOLE
        // poster of this notification is `MCPServer.applyAnnotation`, which now posts INSIDE a
        // `main.sync` block, so the notification is ALWAYS delivered on main and the sink runs
        // synchronously inline with the post. That synchronicity is load-bearing: it lets the MCP
        // `set_surface_annotation` handler return only AFTER the model has stored the annotation, so
        // the same sidecar sweep's `list_surfaces`/`hookSnapshot()` sees it and reconcile folds an
        // adopted split in THIS sweep (no extra round). A `receive(on: main)` here would re-dispatch
        // the apply to a LATER main turn — reintroducing exactly the deferral we removed. INVARIANT:
        // do NOT post `.ghosttyAgentAnnotationDidChange` from off-main, or this sink runs off-main
        // and mutates `@Published` model state off-main (post via `applyAnnotation` only).
        NotificationCenter.default.publisher(for: .ghosttyAgentAnnotationDidChange)
            .sink { [weak self] note in
                guard let self,
                      let id = note.userInfo?[AgentStateUserInfoKey.surfaceID] as? UUID,
                      let annotation = note.userInfo?[AgentStateUserInfoKey.annotation] as? AgentAnnotation
                else { return }
                self.model.applyAnnotation(id, annotation)
            }
            .store(in: &cancellables)
    }

    /// (ramon fork / Agent Queue, §11 health) Observe `.ghosttyQueueStatusDidChange`
    /// posted by the MCP `report_queue_status` handler and hand the run-level health to
    /// the model. Registered unconditionally (like the annotation/state subscribers).
    private func subscribeQueueStatus() {
        NotificationCenter.default.publisher(for: .ghosttyQueueStatusDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self,
                      let status = note.userInfo?[QueueCommandUserInfoKey.status] as? QueueStatus
                else { return }
                self.model.applyQueueStatus(status)
            }
            .store(in: &cancellables)
    }

    /// (ramon fork / Agent Dashboard) Observe `.ghosttyFocusedSurfaceDidChange` (posted
    /// by `Ghostty.App.recordFocusedSurface`) and record the focused surface id on the
    /// model, so the matching tile gets the light "you're looking at this" treatment.
    /// Registered unconditionally (like the state/annotation subscribers) — the model
    /// only stores the id; the tiles read it when they render. A nil object clears it.
    private func subscribeFocus() {
        NotificationCenter.default.publisher(for: Ghostty.Notification.ghosttyFocusedSurfaceDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self else { return }
                self.model.setFocusedSurface((note.object as? Ghostty.SurfaceView)?.id)
            }
            .store(in: &cancellables)
    }

    /// (ramon fork / Agent Queue, backlog graph) Observe `.ghosttyQueueGraphDidChange`
    /// posted by the MCP `report_queue_graph` handler and hand the whole-board snapshot to
    /// the model. Registered unconditionally (like the status subscriber).
    private func subscribeQueueGraph() {
        NotificationCenter.default.publisher(for: .ghosttyQueueGraphDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self,
                      let graph = note.userInfo?[QueueCommandUserInfoKey.graph] as? QueueGraph
                else { return }
                self.model.applyQueueGraph(graph)
            }
            .store(in: &cancellables)
    }

    /// (ramon fork / Agent Manager) Forward the model's per-surface hook/annotation
    /// snapshot for the MCP `list_surfaces` enrichment. MUST be called on main
    /// (the model is `@MainActor`); returns value types only.
    func hookSnapshot() -> [UUID: AgentDashboardModel.HookSnapshotEntry] {
        model.hookSnapshot()
    }

    /// (ramon fork / Web Monitor) The current detected-agent + hidden surface ids,
    /// so the web monitor's list filters ("agents only" / "hide hidden") mirror the
    /// dashboard exactly. Value types only; MUST be called on main (the model is
    /// `@MainActor`). `agents` is the live agent universe (same set the tiles use);
    /// `hidden` is the user's hide set (keyed by surface UUID). The mere existence
    /// of this controller is what the web monitor reads as "the dashboard is
    /// running" — so when it's nil the filters are offered disabled.
    func webMonitorFilterState() -> (agents: Set<UUID>, hidden: Set<UUID>, hero: Set<UUID>) {
        (model.liveAgentIDs, model.hidden, model.heroIDs)
    }

    /// (ramon fork / Hero Agents) True iff `id` is annotated a hero (`queueHero`). Used by the
    /// web-monitor push path to prefix a hero surface's BELL notification with the ⭐ glyph
    /// (the loud attention tier already stars via `onHero`). Cheap annotation read.
    func isHeroSurface(_ id: UUID) -> Bool {
        model.annotations[id]?.queueHero == true
    }

    /// (ramon fork / Agent hooks) Post `.ghosttyAgentNeedsAttention` for `id`,
    /// looking up the live title/pwd from `TerminalController.all` on main (this
    /// touches AppKit, so it lives on the controller, not the model). Observed by
    /// `WebPushManager` to fire a Web Push.
    private func postNeedsAttention(id: UUID, message: String) {
        var title = ""
        var pwd = ""
        outer: for controller in TerminalController.all {
            for view in controller.surfaceTree where view.id == id {
                title = view.title
                pwd = view.pwd ?? ""
                break outer
            }
        }
        // (ramon fork / Hero Agents) A hero surface routes into the LOUD attention tier + a
        // DISTINCT push glyph. We carry the hero verdict off the stored annotation
        // (`queueHero`) so the WebPush observer can call `onHero` instead of `onAttention`.
        let hero = model.annotations[id]?.queueHero ?? false
        NotificationCenter.default.post(
            name: .ghosttyAgentNeedsAttention, object: nil,
            userInfo: [
                AgentStateUserInfoKey.surfaceID: id,
                AgentStateUserInfoKey.title: title,
                AgentStateUserInfoKey.pwd: pwd,
                AgentStateUserInfoKey.message: message,
                AgentStateUserInfoKey.hero: hero,
            ])
    }

    /// Rebuild per-controller bell subscriptions + tree sinks for the current
    /// `TerminalController.all`, then merge all bell dicts into one.
    private func rebuildControllerObservers() {
        controllerCancellables.removeAll()
        for controller in TerminalController.all {
            var bag = Set<AnyCancellable>()
            controller
                .surfaceValuesPublisher(valueKeyPath: \.bell, publisherKeyPath: \.$bell)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.mergeAndApplyBells() }
                .store(in: &bag)
            // (ramon fork / Bell Attention) Mirror the bell subscription for the
            // per-surface attentionNeeded state → the model's attention map.
            controller
                .surfaceValuesPublisher(valueKeyPath: \.attentionNeeded, publisherKeyPath: \.$attentionNeeded)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.mergeAndApplyAttention() }
                .store(in: &bag)
            controller.$surfaceTree
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self, self.isShown else { return }
                    self.rebuild()
                }
                .store(in: &bag)
            controllerCancellables[ObjectIdentifier(controller)] = bag
        }
        mergeAndApplyBells()
        mergeAndApplyAttention()
    }

    /// Merge every live controller's per-surface bell into one `[UUID: Bool]`.
    private func mergeAndApplyBells() {
        var merged: [UUID: Bool] = [:]
        for controller in TerminalController.all {
            for view in controller.surfaceTree {
                merged[view.id] = view.bell
            }
        }
        model.applyBells(merged)
    }

    /// (ramon fork / Bell Attention) Merge every live controller's per-surface
    /// attentionNeeded into one `[UUID: Bool]` and hand it to the model.
    private func mergeAndApplyAttention() {
        var merged: [UUID: Bool] = [:]
        for controller in TerminalController.all {
            for view in controller.surfaceTree {
                merged[view.id] = view.attentionNeeded
            }
        }
        model.applyAttention(merged)
    }

    // MARK: - Reconcile

    /// Walk `TerminalController.all → surfaceTree` (WebMonitor pattern) on main,
    /// capturing value types + weak views, and hand them to the model.
    private func rebuild() {
        var live: [AgentDashboardModel.LiveSurface] = []
        for controller in TerminalController.all {
            for view in controller.surfaceTree {
                let sid: UInt64 = view.surfaceModel?.sessionID ?? 0
                live.append(.init(
                    id: view.id,
                    view: view,
                    title: view.title,
                    pwd: view.pwd ?? "",
                    sessionID: sid,
                    hostName: view.hostName ?? "local"
                ))
            }
        }
        model.rebuild(live: live)
    }

    /// Value-type snapshot for the off-main detector: (uuid, foregroundPID).
    private func detectorSnapshot() -> [(uuid: UUID, pid: pid_t)] {
        var out: [(UUID, pid_t)] = []
        for controller in TerminalController.all {
            for view in controller.surfaceTree {
                guard let pid = view.surfaceModel?.foregroundPID, pid > 0 else { continue }
                out.append((view.id, pid_t(pid)))
            }
        }
        return out
    }

    // MARK: - Default frame

    /// Fixed default width, in points. A flat value (not a screen fraction) so
    /// the panel isn't uselessly wide on a large external display — colleagues
    /// reported the old ~40%-of-screen default was too wide to be useful. Clamped
    /// to the visible width below so it can't overrun a narrow screen. Only the
    /// FIRST-run frame; a user-resized frame is restored from the autosave.
    static let defaultWidth: CGFloat = 757

    private static func defaultFrame() -> NSRect {
        // Top-right of the widest screen: fixed default width × full height.
        let screen = NSScreen.screens.max(by: { $0.frame.width < $1.frame.width })
            ?? NSScreen.main
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let width = min(Self.defaultWidth, vis.width)
        return NSRect(x: vis.maxX - width, y: vis.minY, width: width, height: vis.height)
    }
}

// MARK: - NSWindowDelegate

extension AgentDashboardController: NSWindowDelegate {
    /// A native close-button click on EITHER shell turns the dashboard off (undock /
    /// order-out) rather than destroying the controller. The state change is
    /// scheduled async so we don't mutate window state from inside the close
    /// callback (undock closes the tab window), and we suppress the AppKit close.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === tabWindow || sender === window {
            DispatchQueue.main.async { [weak self] in self?.apply(.off) }
            return false
        }
        return true
    }

    /// Drive mirror occlusion off the ACTUAL occlusion state of the active shell,
    /// not only the explicit show/hide path (matching `BaseTerminalController`).
    /// This catches cases the transitions miss — a panel occluded by a fullscreen
    /// window on its Space, a mirror mounted asynchronously, or (tab mode) the
    /// dashboard tab being deselected in its group — so a hidden/occluded shell's
    /// previews always pause (spec §8). Only acts on the shell we're presenting.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let win = notification.object as? NSWindow, win === activeHostWindow else { return }
        setMirrorOcclusion(win.occlusionState.contains(.visible), in: win)
    }
}

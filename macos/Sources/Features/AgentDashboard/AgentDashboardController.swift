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
}

/// Persistence boundary for per-session agent state, injected for testability
/// (mirrors `HideStore`). Keyed by the HOST session id (`UInt64`) — the STABLE
/// reattach key across a GUI restart, UNLIKE the surface UUID, which is freshly
/// minted each launch (so a UUID-keyed store could never re-associate).
protocol AgentStateStore {
    func load() -> [UInt64: PersistedAgentState]
    func save(_ map: [UInt64: PersistedAgentState])
}

/// Production store backed by the fork bundle-id `UserDefaults` domain. Encodes
/// `[String: PersistedAgentState]` (session id → record) as JSON `Data` (the
/// session id is stringified because plist/JSON keys must be strings).
struct UserDefaultsAgentStateStore: AgentStateStore {
    static let key = "agentDashboardAgentStates"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> [UInt64: PersistedAgentState] {
        guard let data = defaults.data(forKey: Self.key),
              let raw = try? JSONDecoder().decode([String: PersistedAgentState].self, from: data)
        else { return [:] }
        var out: [UInt64: PersistedAgentState] = [:]
        for (k, v) in raw { if let sid = UInt64(k) { out[sid] = v } }
        return out
    }

    func save(_ map: [UInt64: PersistedAgentState]) {
        var raw: [String: PersistedAgentState] = [:]
        for (k, v) in map { raw[String(k)] = v }
        guard let data = try? JSONEncoder().encode(raw) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// In-memory `AgentStateStore` for tests.
final class InMemoryAgentStateStore: AgentStateStore {
    private var map: [UInt64: PersistedAgentState]
    init(_ map: [UInt64: PersistedAgentState] = [:]) { self.map = map }
    func load() -> [UInt64: PersistedAgentState] { map }
    func save(_ map: [UInt64: PersistedAgentState]) { self.map = map }
}

/// (ramon fork / Agent Dashboard) Persistence boundary for the user's manual
/// tile order, injected for testability (mirrors `HideStore`/`AgentStateStore`).
/// An ORDERED list of stable HOST session ids (`UInt64`) — NOT surface UUIDs,
/// which are freshly minted each GUI launch (so a UUID-keyed order could never
/// survive a relaunch — the same lesson `AgentStateStore` encodes).
protocol OrderStore {
    func load() -> [UInt64]
    func save(_ order: [UInt64])
}

/// Production order store backed by the fork bundle-id `UserDefaults` domain.
/// Session ids are stringified (a `UInt64` can exceed `Int`, and a plist number
/// array can't safely hold the full range).
struct UserDefaultsOrderStore: OrderStore {
    static let key = "agentDashboardManualOrder"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> [UInt64] {
        (defaults.stringArray(forKey: Self.key) ?? []).compactMap { UInt64($0) }
    }

    func save(_ order: [UInt64]) {
        defaults.set(order.map(String.init), forKey: Self.key)
    }
}

/// In-memory `OrderStore` for tests.
final class InMemoryOrderStore: OrderStore {
    private var order: [UInt64]
    init(_ order: [UInt64] = []) { self.order = order }
    func load() -> [UInt64] { order }
    func save(_ order: [UInt64]) { self.order = order }
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

    /// Surfaces that have EVER reported a hook event. Hook-authoritative
    /// thereafter (mutes the `idleSeconds` heuristic for these ids).
    private(set) var hookBacked: Set<UUID> = []

    // MARK: - Manual order (ramon fork / Agent Dashboard)

    /// The user's manual tile order: an ORDERED list of stable HOST session ids
    /// (`UInt64`). Drives the manual-rank sort key, which sits ABOVE the UUID
    /// tie-break (placed tiles sort by this list; unplaced tiles — new agents —
    /// float to the top by recency). `@Published` so the "Reset order"
    /// affordance shows/hides reactively. Empty ⇒ no manual order. Persisted via
    /// `orderStore`. Each drag REWRITES this from the displayed order, so it
    /// never grows past the number of visible tiles.
    @Published private(set) var manualOrder: [UInt64] = []

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
    private var restored: [UInt64: PersistedAgentState]
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
    func setManualOrder(_ sessionIDs: [UInt64]) {
        manualOrder = sessionIDs.filter { $0 != 0 }
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
    func applyAgents(_ next: [UUID: AgentKind]) {
        let now = Date()
        for id in next.keys { lastSeen[id] = now }
        agents = next
        rebuildEntriesFromCurrentState()
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

    // MARK: - Reconciliation

    /// Snapshot of one live surface taken on main (value types + weak view).
    struct LiveSurface {
        let id: UUID
        weak var view: Ghostty.SurfaceView?
        let title: String
        let pwd: String
        let sessionID: UInt64
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
        _ map: [UInt64: PersistedAgentState], now: Date,
        maxAge: TimeInterval, maxCount: Int
    ) -> [UInt64: PersistedAgentState] {
        let nowS = now.timeIntervalSince1970
        var kept = map.filter { nowS - $0.value.updated <= maxAge }
        if kept.count > maxCount {
            let newest = kept.sorted { $0.value.updated > $1.value.updated }.prefix(maxCount)
            kept = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        return kept
    }

    /// The host session id for a live surface UUID, or nil if unknown (not yet
    /// in the `live` snapshot, or no host session).
    private func sessionID(for id: UUID) -> UInt64? {
        live.first { $0.id == id }?.sessionID
    }

    /// True iff `a` and `b` carry the same state/tool/prompt/message (IGNORING
    /// `updated`) — so a steady stream of identical states doesn't churn the store.
    private func sameContent(_ a: PersistedAgentState?, _ b: PersistedAgentState) -> Bool {
        guard let a else { return false }
        return a.state == b.state && a.tool == b.tool && a.prompt == b.prompt && a.message == b.message
    }

    /// Persist the current state for `id`'s host session, if its session id is
    /// known and non-zero. Saves only when the persisted CONTENT changes.
    private func writeThrough(id: UUID) {
        guard let sid = sessionID(for: id), sid != 0, let state = agentStates[id] else { return }
        let rec = PersistedAgentState(
            state: state.rawValue, tool: lastTool[id], prompt: lastPrompt[id],
            message: lastMessage[id], updated: Date().timeIntervalSince1970)
        if !sameContent(restored[sid], rec) {
            restored[sid] = rec
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
            if agentStates[s.id] == nil {
                guard let rec = restored[s.sessionID],
                      let state = AgentState(rawValue: rec.state) else { continue }
                agentStates[s.id] = state
                if let t = rec.tool { lastTool[s.id] = t }
                if let p = rec.prompt { lastPrompt[s.id] = p }
                if let m = rec.message { lastMessage[s.id] = m }
                hookBacked.insert(s.id)
            } else if let state = agentStates[s.id] {
                let rec = PersistedAgentState(
                    state: state.rawValue, tool: lastTool[s.id], prompt: lastPrompt[s.id],
                    message: lastMessage[s.id], updated: nowS)
                let cur = restored[s.sessionID]
                let stale = cur.map { nowS - $0.updated > Self.persistTouchInterval } ?? true
                if !sameContent(cur, rec) || stale {
                    restored[s.sessionID] = rec
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
    var liveAgentIDs: Set<UUID> { Set(live.map(\.id).filter { agents[$0] != nil }) }

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
    }

    /// Snapshot the hook + annotation state for every surface that has any of it.
    /// Surfaces with no state at all are omitted, so an absent map entry means
    /// "nothing known" (the MCP shaper then omits those fields — honest absence).
    func hookSnapshot() -> [UUID: HookSnapshotEntry] {
        var out: [UUID: HookSnapshotEntry] = [:]
        let ids = Set(agentStates.keys)
            .union(lastPrompt.keys).union(lastTool.keys)
            .union(annotations.keys).union(agents.keys)
            .union(hidden)
        for id in ids {
            out[id] = HookSnapshotEntry(
                agentState: agentStates[id]?.rawValue,
                lastPrompt: lastPrompt[id],
                lastTool: lastTool[id],
                notes: annotations[id]?.summary,
                agentKind: agents[id]?.command,
                hidden: hidden.contains(id))
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
            .filter { hidden.contains($0.id) && agents[$0.id] != nil }
            .map { HiddenAgent(id: $0.id, title: $0.title, agent: agents[$0.id]) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func rebuildEntriesFromCurrentState() {
        // LOCKED "agent-only": a tile exists ONLY for a live split the detector
        // matched as a CLI agent (`agents[id] != nil`). A plain shell / vim /
        // any non-agent split is never rendered, so spec §2.6 state-2
        // ("No CLI agents running.") is reachable whenever a terminal is open
        // but no agent is detected.
        let built: [AgentEntry] = live
            .filter { agents[$0.id] != nil }
            .map { s in
                AgentEntry(
                    id: s.id,
                    realView: s.view,
                    title: s.title,
                    pwd: s.pwd,
                    agent: agents[s.id],
                    bell: bells[s.id] ?? false,
                    attention: attention[s.id] ?? false,
                    hidden: hidden.contains(s.id),
                    sessionID: s.sessionID,
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
        // session id → its index in the user's manual order (keep-first on the
        // (impossible-in-practice) duplicate, to stay total).
        let manualRank = Dictionary(
            manualOrder.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first })
        entries = AgentDashboardModel.sorted(
            built.filter { !$0.hidden }, lastSeen: lastSeen, manualRank: manualRank,
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
        manualRank: [UInt64: Int] = [:],
        // Default true to match the config defaults (dashboard routed to both tiers);
        // the model passes its real flags.
        bellDashboard: Bool = true,
        attnDashboard: Bool = true
    ) -> [AgentEntry] {
        func rank(_ e: AgentEntry) -> Int? {
            e.sessionID == 0 ? nil : manualRank[e.sessionID]
        }
        return entries.sorted { a, b in
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
        let filtered = AgentDashboardModel.applyOriginFilter(entries, excluded: excludedOrigins)
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
        for s in live where hidden.contains(s.id) && agents[s.id] != nil {
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

    /// Whether the panel is currently visible. Persisted as
    /// `agentDashboardWasVisible` so launch can restore the open/closed state.
    private(set) var isShown = false

    static let wasVisibleKey = "agentDashboardWasVisible"
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

        let host = NSHostingView(rootView: AgentDashboardView(
            model: model,
            ghostty: ghostty,
            ptyHostEnabled: ghostty.config.ptyHost != nil,
            commands: ghostty.config.agentDashboardCommands
        ))
        host.autoresizingMask = [.width, .height]

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

        detector.onResults = { [weak self] results in
            self?.model.applyAgents(results)
        }

        subscribeChurn()
        subscribeAgentState()
        subscribeAnnotation()
        subscribeQueueStatus()
        subscribeQueueGraph()
        rebuildControllerObservers()
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    // MARK: - Show / hide

    func toggle() {
        if isShown { hide() } else { show() }
    }

    func show() {
        rebuild()
        rebuildControllerObservers()
        window?.orderFrontRegardless()
        isShown = true
        UserDefaults.standard.set(true, forKey: Self.wasVisibleKey)
        // Resume the mirror renderers (they were paused on the last hide).
        setMirrorOcclusion(true)
        // The SwiftUI NSHostingView mounts its mirror SurfaceViews ASYNCHRONOUSLY
        // after layout, so on the very first show() (and whenever a new tile
        // appears on this open) `surfaceViews(in:)` returns an empty / partial
        // set and the synchronous call above can't reach the not-yet-mounted
        // mirrors. Re-drive occlusion after a runloop hop so freshly-mounted
        // mirrors are resumed too (idempotent for the ones already handled).
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isShown else { return }
            self.setMirrorOcclusion(true)
        }
        detector.resume(snapshotProvider: { [weak self] in self?.detectorSnapshot() ?? [] })
    }

    func hide() {
        orderOutWithoutPersisting()
        UserDefaults.standard.set(false, forKey: Self.wasVisibleKey)
    }

    /// Order the panel out + pause work WITHOUT mutating the persisted
    /// `wasVisibleKey`. Used at app teardown so a panel that is OPEN at quit
    /// restores as open next launch (spec §1.4/§6.1) — only an explicit user
    /// `hide()` writes `false`.
    private func orderOutWithoutPersisting() {
        window?.orderOut(nil)
        // Inform the mirror surfaces they are off-screen so their renderers
        // pause (spec §8 cost-control). The panel is not an NSWindowDelegate on
        // the occlusion path, so we drive it explicitly here.
        setMirrorOcclusion(false)
        isShown = false
        detector.pause()
    }

    /// Restore visibility from the remembered default. Called at launch when
    /// `agent-dashboard` is enabled in config. First run (key absent) defaults
    /// to SHOWN (spec §6.1: "shown by default the first time").
    func restoreVisibility() {
        let defaults = UserDefaults.standard
        let wantShown = defaults.object(forKey: Self.wasVisibleKey) == nil
            ? true
            : defaults.bool(forKey: Self.wasVisibleKey)
        if wantShown { show() }
    }

    func teardown() {
        // Order out WITHOUT clobbering wasVisibleKey, so an open-at-quit panel
        // re-opens next launch.
        orderOutWithoutPersisting()
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
    private func setMirrorOcclusion(_ visible: Bool) {
        guard let content = window?.contentView else { return }
        for surfaceView in Self.surfaceViews(in: content) {
            guard let surface = surfaceView.surface else { continue }
            ghostty_surface_set_occlusion(surface, visible)
            surfaceView.isWindowVisible = visible
        }
    }

    /// Recursively collect the mirror `SurfaceView`s mounted in the panel.
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
                }
                .store(in: &cancellables)
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
        NotificationCenter.default.publisher(for: .ghosttyAgentAnnotationDidChange)
            .receive(on: DispatchQueue.main)
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
    func webMonitorFilterState() -> (agents: Set<UUID>, hidden: Set<UUID>) {
        (model.liveAgentIDs, model.hidden)
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
        NotificationCenter.default.post(
            name: .ghosttyAgentNeedsAttention, object: nil,
            userInfo: [
                AgentStateUserInfoKey.surfaceID: id,
                AgentStateUserInfoKey.title: title,
                AgentStateUserInfoKey.pwd: pwd,
                AgentStateUserInfoKey.message: message,
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
                    sessionID: sid
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

    private static func defaultFrame() -> NSRect {
        // Top-right quadrant of the widest screen: ~40% width × full height.
        let screen = NSScreen.screens.max(by: { $0.frame.width < $1.frame.width })
            ?? NSScreen.main
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let width = vis.width * 0.40
        return NSRect(x: vis.maxX - width, y: vis.minY, width: width, height: vis.height)
    }
}

// MARK: - NSWindowDelegate

extension AgentDashboardController: NSWindowDelegate {
    /// Route a native close-button click through `hide()` (so `isShown` stays in
    /// sync and the next `toggle()` re-opens instead of wasting a press) and
    /// suppress the actual close (the panel is reused, never destroyed).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    /// Drive mirror occlusion off the ACTUAL panel occlusion state, not only the
    /// explicit show/hide path (matching `BaseTerminalController`). This catches
    /// cases the show/hide gates miss — e.g. the panel becoming occluded by a
    /// fullscreen window on its Space, or a mirror that mounted asynchronously
    /// after `show()` already ran — so a hidden/occluded panel's previews always
    /// pause (spec §8). Only acts while we believe we're shown so an explicit
    /// `hide()` (which already paused) isn't second-guessed into resuming.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard isShown, let window else { return }
        setMirrorOcclusion(window.occlusionState.contains(.visible))
    }
}

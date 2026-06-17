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
    let hidden: Bool
    let sessionID: UInt64
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

    /// Latest detector results, keyed by surface UUID.
    private(set) var agents: [UUID: AgentKind] = [:]

    /// Coarse most-recently-seen-as-agent timestamps (the ~2s detector liveness
    /// heuristic), used as the secondary sort key (variant b — no per-frame
    /// activity tick).
    private(set) var lastSeen: [UUID: Date] = [:]

    private let store: HideStore

    init(store: HideStore) {
        self.store = store
        self.hidden = store.load()
    }

    // MARK: - Hide set

    /// Hide a surface (user gesture). Persists immediately.
    func hide(_ id: UUID) {
        guard !hidden.contains(id) else { return }
        hidden.insert(id)
        store.save(hidden)
        rebuildEntriesFromCurrentState()
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
        for (id, ringing) in next where ringing {
            if hidden.contains(id) {
                hidden.remove(id)
                changed = true
            }
        }
        bells = next
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
        agents = agents.filter { liveIDs.contains($0.key) }
        lastSeen = lastSeen.filter { liveIDs.contains($0.key) }
        rebuildEntriesFromCurrentState()
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
                    hidden: hidden.contains(s.id),
                    sessionID: s.sessionID
                )
            }
        entries = AgentDashboardModel.sorted(built.filter { !$0.hidden }, lastSeen: lastSeen)
    }

    // MARK: - Sort (pure, testable)

    /// Deterministic order: bell-first, then most-recently-seen-as-agent
    /// (descending), then stable UUID tie-break (variant b — no activity tick).
    static func sorted(_ entries: [AgentEntry], lastSeen: [UUID: Date] = [:]) -> [AgentEntry] {
        entries.sorted { a, b in
            if a.bell != b.bell { return a.bell && !b.bell }
            let sa = lastSeen[a.id] ?? .distantPast
            let sb = lastSeen[b.id] ?? .distantPast
            if sa != sb { return sa > sb }
            return a.id.uuidString < b.id.uuidString
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

    /// Whether the panel is currently visible. Persisted as
    /// `agentDashboardWasVisible` so launch can restore the open/closed state.
    private(set) var isShown = false

    static let wasVisibleKey = "agentDashboardWasVisible"
    static let autosaveName = "com.mitchellh.ghostty.agentDashboard"

    init(ghostty: Ghostty.App) {
        self.ghostty = ghostty
        self.model = AgentDashboardModel(store: UserDefaultsHideStore())
        self.detector = AgentDetector(commands: Set(ghostty.config.agentDashboardCommands))

        let panel = AgentDashboardPanel()
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

    /// Value-type snapshot for the off-main detector: per-surface HOST-RESOLVED
    /// foreground process name + command. NOT a pid: under the pty-host `.client`
    /// backend the agent runs on `ghostty-host`, so the surface has no GUI-local
    /// pid (`foregroundPID` is 0) and a libproc walk finds nothing — the host
    /// resolves the foreground name/command, which `foregroundProcessName` /
    /// `foregroundCommand` surface for both `.client` (host) and `.exec` (local).
    private func detectorSnapshot() -> [AgentDetector.SurfaceProc] {
        var out: [AgentDetector.SurfaceProc] = []
        for controller in TerminalController.all {
            for view in controller.surfaceTree {
                out.append(.init(
                    uuid: view.id,
                    processName: view.foregroundProcessName,
                    command: view.foregroundCommand))
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

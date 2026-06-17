import AppKit
import Testing
@testable import Ghostty

// MARK: - matchAgent (host-resolved name/command) pure logic

struct AgentDetectorTests {
    // 1) foreground process basename — the common Claude case (native binary, the
    //    foreground process IS `claude`).
    @Test func foregroundNameDirectHit() {
        #expect(matchAgent(processName: "claude", command: "claude --resume",
                           commands: ["claude", "codex"]) == AgentKind("claude"))
    }

    @Test func foregroundNamePathBasenamed() {
        // A full exe path is basenamed.
        #expect(matchAgent(processName: "/Users/x/.local/bin/claude", command: nil,
                           commands: ["claude"]) == AgentKind("claude"))
    }

    // 2) argv0 basename when the foreground name is unavailable/unhelpful.
    @Test func argv0Hit() {
        #expect(matchAgent(processName: nil, command: "/opt/homebrew/bin/codex chat",
                           commands: ["codex"]) == AgentKind("codex"))
    }

    // 3) interpreter-wrapped (node Codex): foreground process is `node`, the agent
    //    is a later command token.
    @Test func nodeWrappedCodex() {
        #expect(matchAgent(processName: "node",
                           command: "node /Users/x/.nvm/versions/node/v24/bin/codex",
                           commands: ["codex"]) == AgentKind("codex"))
    }

    @Test func interpreterArgv0AlsoTriggersScan() {
        // argv0 is the interpreter even when processName is missing.
        #expect(matchAgent(processName: nil,
                           command: "node /x/bin/codex --flag",
                           commands: ["codex"]) == AgentKind("codex"))
    }

    @Test func nonInterpreterDoesNotScanArgs() {
        // A stray path arg under a NON-interpreter must NOT false-match: editing a
        // file named `codex` is not running the agent.
        #expect(matchAgent(processName: "vim", command: "vim notes/codex",
                           commands: ["codex"]) == nil)
    }

    @Test func noMatchReturnsNil() {
        #expect(matchAgent(processName: "zsh", command: "-zsh",
                           commands: ["claude", "codex"]) == nil)
    }

    @Test func configurableCommandSet() {
        // Only watching codex: claude must NOT match; codex must.
        #expect(matchAgent(processName: "claude", command: "claude",
                           commands: ["codex"]) == nil)
        #expect(matchAgent(processName: "codex", command: "codex",
                           commands: ["codex"]) == AgentKind("codex"))
    }

    @Test func emptyCommandsNeverMatches() {
        #expect(matchAgent(processName: "claude", command: "claude", commands: []) == nil)
    }

    @Test func bothInputsNilOrEmptyIsNil() {
        // An old host that hasn't pushed process info yet -> not classified (rather
        // than crashing or false-matching).
        #expect(matchAgent(processName: nil, command: nil,
                           commands: ["claude", "codex"]) == nil)
        #expect(matchAgent(processName: "", command: "",
                           commands: ["claude", "codex"]) == nil)
    }

    @Test func foregroundNameWinsOverCommandToken() {
        // When both could match, the (cheaper, more authoritative) foreground name
        // is returned.
        #expect(matchAgent(processName: "claude", command: "node /x/bin/codex",
                           commands: ["claude", "codex"]) == AgentKind("claude"))
    }
}

// MARK: - AgentDetector cache / resolve logic

struct AgentDetectorCacheTests {
    private func proc(_ uuid: UUID, _ name: String?, _ cmd: String?) -> AgentDetector.SurfaceProc {
        .init(uuid: uuid, processName: name, command: cmd)
    }

    @Test func resolveMatchesAndCaches() {
        let a = UUID()
        let (r1, c1) = AgentDetector.resolve(
            snapshot: [proc(a, "claude", "claude --resume")],
            cache: [:], commands: ["claude"])
        #expect(r1[a] == AgentKind("claude"))
        #expect(c1[a]?.kind == AgentKind("claude"))

        // Same name/command -> cache hit (key unchanged), same result.
        let (r2, _) = AgentDetector.resolve(
            snapshot: [proc(a, "claude", "claude --resume")],
            cache: c1, commands: ["claude"])
        #expect(r2[a] == AgentKind("claude"))
    }

    @Test func reMatchOnNameOrCommandChange() {
        let a = UUID()
        let (_, c1) = AgentDetector.resolve(
            snapshot: [proc(a, "claude", "claude")],
            cache: [:], commands: ["claude"])
        #expect(c1[a]?.kind == AgentKind("claude"))

        // Foreground process changed (claude exited -> back at the shell): re-match,
        // and now no agent.
        let (r2, c2) = AgentDetector.resolve(
            snapshot: [proc(a, "zsh", "-zsh")],
            cache: c1, commands: ["claude"])
        #expect(r2[a] == nil)
        #expect(c2[a]?.kind == nil)
    }

    @Test func vanishedIDDroppedFromCache() {
        let a = UUID(), b = UUID()
        let (_, c1) = AgentDetector.resolve(
            snapshot: [proc(a, "claude", "claude"), proc(b, "codex", "codex")],
            cache: [:], commands: ["claude", "codex"])
        #expect(c1.count == 2)

        // b's surface vanished: next snapshot omits it -> next cache drops it.
        let (r2, c2) = AgentDetector.resolve(
            snapshot: [proc(a, "claude", "claude")],
            cache: c1, commands: ["claude", "codex"])
        #expect(c2.keys.contains(a))
        #expect(!c2.keys.contains(b))
        #expect(r2[b] == nil)
    }
}

// MARK: - Hide / auto-unhide state machine + persistence

@MainActor
struct AgentDashboardModelTests {
    private func live(_ ids: [UUID]) -> [AgentDashboardModel.LiveSurface] {
        ids.map { id in
            .init(id: id, view: nil, title: "t", pwd: "/x", sessionID: 0)
        }
    }

    /// Seed the detector results so the given ids are treated as agents — the
    /// dashboard is agent-only (LOCKED), so an entry only exists for a split the
    /// detector matched. Tests that assert `entries` contains an id MUST first
    /// mark it as an agent here.
    private func agents(_ ids: [UUID]) -> [UUID: AgentKind] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, AgentKind("claude")) })
    }

    @Test func hideAddsAndPersists() {
        let store = InMemoryHideStore()
        let model = AgentDashboardModel(store: store)
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))               // a is a detected agent
        #expect(model.entries.map(\.id).contains(a))

        model.hide(a)
        #expect(model.hidden.contains(a))
        #expect(store.load().contains(a))           // persisted
        #expect(!model.entries.map(\.id).contains(a)) // dropped from grid
    }

    @Test func nonAgentNeverShown() {
        // LOCKED "agent-only": a live split with NO detected agent must never
        // produce a tile, so spec §2.6 state-2 stays reachable.
        let store = InMemoryHideStore()
        let model = AgentDashboardModel(store: store)
        let plainShell = UUID()
        model.rebuild(live: live([plainShell]))      // no applyAgents → not an agent
        #expect(model.entries.isEmpty)
        // It IS a live terminal (state-1 vs state-2 discriminator)…
        #expect(model.liveIDs.contains(plainShell))
        // …but it is NOT in the agent universe.
        #expect(!model.liveAgentIDs.contains(plainShell))
    }

    @Test func bellAutoUnhides() {
        let store = InMemoryHideStore()
        let model = AgentDashboardModel(store: store)
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        model.hide(a)
        #expect(model.hidden.contains(a))

        // Bell false->true must unhide.
        model.applyBells([a: true])
        #expect(!model.hidden.contains(a))
        #expect(!store.load().contains(a))          // persistence updated
        #expect(model.entries.first?.bell == true)
    }

    @Test func hideWhileRingingReUnhides() {
        // LOCKED #1: a RINGING agent must never stay hidden. Sequence: agent
        // rings -> applyBells sets bells[a]=true; user hides it WHILE ringing;
        // detector republishes the SAME (still true) bell -> the agent must be
        // unhidden again (not stranded by the false->true-only transition logic).
        let store = InMemoryHideStore()
        let model = AgentDashboardModel(store: store)
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))

        model.applyBells([a: true])     // a starts ringing
        model.hide(a)                   // user hides it while ringing
        #expect(model.hidden.contains(a))

        // Same bell republished (no transition): the ringing agent must reappear.
        model.applyBells([a: true])
        #expect(!model.hidden.contains(a))
        #expect(!store.load().contains(a))
        #expect(model.entries.map(\.id).contains(a))
    }

    @Test func bellFalseKeepsHidden() {
        // Negative complement of the auto-unhide path (LOCKED #1 / spec §4.2):
        // a hidden agent that is NOT ringing must STAY hidden through applyBells.
        // Guards against a refactor that unhides on mere PRESENCE in the bell dict
        // rather than on truth — such a regression would pass every positive test.
        let store = InMemoryHideStore()
        let model = AgentDashboardModel(store: store)
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        model.hide(a)
        #expect(model.hidden.contains(a))

        // bell present but false: must NOT unhide.
        model.applyBells([a: false])
        #expect(model.hidden.contains(a))
        #expect(store.load().contains(a))
        #expect(!model.entries.map(\.id).contains(a))

        // bell dict omitting `a` entirely: must NOT unhide.
        model.applyBells([:])
        #expect(model.hidden.contains(a))
        #expect(store.load().contains(a))
        #expect(!model.entries.map(\.id).contains(a))
    }

    @Test func agentVanishedDropsTile() {
        // A previously-detected agent quits (surface stays). The next applyAgents
        // without that id must drop its tile.
        let store = InMemoryHideStore()
        let model = AgentDashboardModel(store: store)
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        #expect(model.entries.map(\.id).contains(a))

        // Agent process exits but the surface remains a live (non-agent) split.
        model.applyAgents([:])
        #expect(!model.entries.map(\.id).contains(a))
        #expect(model.liveIDs.contains(a))          // still a live terminal
        #expect(!model.liveAgentIDs.contains(a))    // no longer an agent
    }

    @Test func detectorDropReconcileRemovesTile() {
        // FAITHFUL to production reconciliation: a tile is built ONLY while the
        // detector reports the agent live (rebuildEntriesFromCurrentState filters
        // on `agents[id] != nil`). When a claude/codex process exits, the next
        // detector poll returns nil for that id and applyAgents is called WITHOUT
        // it — the tile must VANISH on that reconcile (LOCKED: finished agents
        // vanish immediately; there is no "ended" tile state). This drives the
        // removal the way production does, not by artificially keeping the agent
        // alive.
        let store = InMemoryHideStore()
        let model = AgentDashboardModel(store: store)
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))            // detector reports a live
        #expect(model.entries.map(\.id).contains(a))

        // Underlying surface stays live (still a terminal split) but the detector
        // no longer reports it as an agent: tile is removed on reconcile.
        model.applyAgents([:])
        #expect(!model.entries.map(\.id).contains(a))
        #expect(model.liveIDs.contains(a))        // still a live terminal
        #expect(!model.liveAgentIDs.contains(a))  // but no longer an agent

        // Still-live & still-detected agents remain normal live tiles — only the
        // detector dropping an id removes it (re-seed after rebuild drops stale).
        let b = UUID()
        model.rebuild(live: live([a, b]))
        model.applyAgents(agents([b]))
        #expect(model.entries.map(\.id).contains(b))
        #expect(!model.entries.map(\.id).contains(a))
    }

    @Test func rebuildDoesNotUnhide() {
        // Variant b: a panel-open rebuild re-evaluates live agents but NEVER
        // clears the hide set.
        let store = InMemoryHideStore()
        let model = AgentDashboardModel(store: store)
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        model.hide(a)
        // Multiple rebuilds (no bell) keep it hidden. Re-seed agents each rebuild
        // (rebuild drops stale agent state for vanished ids; a stays live).
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        #expect(model.hidden.contains(a))
        #expect(!model.entries.map(\.id).contains(a))
    }

    @Test func showAllClears() {
        let store = InMemoryHideStore()
        let model = AgentDashboardModel(store: store)
        let a = UUID(), b = UUID()
        model.rebuild(live: live([a, b]))
        model.applyAgents(agents([a, b]))
        model.hide(a)
        model.hide(b)
        #expect(model.hidden.count == 2)
        model.showAll()
        #expect(model.hidden.isEmpty)
        #expect(store.load().isEmpty)
    }

    @Test func hiddenCountAmongLive() {
        // `gone` is hidden in the store but not live: the chip count must reflect
        // only the hidden ids that are still live agents (a, b), not the stale
        // `gone` carried over from a previous launch.
        let a = UUID(), b = UUID(), gone = UUID()
        let store = InMemoryHideStore([a, b, gone])
        let model = AgentDashboardModel(store: store)
        model.rebuild(live: live([a, b]))
        model.applyAgents(agents([a, b]))
        // Counted over the agent subset: a and b are hidden live agents; `gone`
        // is excluded because it isn't live.
        #expect(model.hiddenCount(among: model.liveAgentIDs) == 2)
        #expect(model.hidden.contains(gone)) // still persisted, just not counted
    }

    @Test func hiddenCountIgnoresNonAgents() {
        // A hidden NON-agent split must not inflate the "N hidden" chip.
        let store = InMemoryHideStore()
        let model = AgentDashboardModel(store: store)
        let agent = UUID(), plainShell = UUID()
        model.rebuild(live: live([agent, plainShell]))
        model.applyAgents(agents([agent]))           // only `agent` is detected
        model.hide(agent)
        model.hide(plainShell)                        // hidden, but not an agent
        #expect(model.hiddenCount(among: model.liveAgentIDs) == 1)
        #expect(model.hiddenAgents.map(\.id) == [agent])
    }

    @Test func persistenceRoundTrip() {
        // Model A hides `a` -> store retains it -> fresh model B starts hidden.
        let store = InMemoryHideStore()
        let a = UUID()
        let modelA = AgentDashboardModel(store: store)
        modelA.rebuild(live: live([a]))
        modelA.applyAgents(agents([a]))
        modelA.hide(a)

        let modelB = AgentDashboardModel(store: store)
        #expect(modelB.hidden.contains(a))
        modelB.rebuild(live: live([a]))
        modelB.applyAgents(agents([a]))
        #expect(!modelB.entries.map(\.id).contains(a)) // still hidden after relaunch
    }
}

// MARK: - UserDefaultsHideStore (the REAL persistence backend)

/// Exercises the PRODUCTION `UserDefaultsHideStore` (not the in-memory fake), so
/// the actual UUID->String->UUID serialization that backs the LOCKED
/// persist-across-launches decision is covered: the `set([uuidString])` /
/// `stringArray(forKey:)` round-trip, the `compactMap { UUID(uuidString:) }`
/// parse, and the empty-array / absent-key edges. Each test uses a throwaway
/// suite so it never touches the real fork defaults domain.
struct UserDefaultsHideStoreTests {
    /// A fresh, isolated UserDefaults suite that is removed after the closure.
    private func withTempDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "agent-dashboard.test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("could not create temp UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    @Test func saveLoadRoundTrip() {
        withTempDefaults { defaults in
            let store = UserDefaultsHideStore(defaults: defaults)
            let a = UUID(), b = UUID()
            store.save([a, b])
            #expect(store.load() == [a, b])

            // A second store over the SAME suite (simulating a relaunch) reads it.
            let reopened = UserDefaultsHideStore(defaults: defaults)
            #expect(reopened.load() == [a, b])
        }
    }

    @Test func loadDefaultsToEmptyWhenAbsent() {
        withTempDefaults { defaults in
            let store = UserDefaultsHideStore(defaults: defaults)
            // Absent key -> empty set, never a crash.
            #expect(store.load().isEmpty)
        }
    }

    @Test func saveEmptyClearsPersistedSet() {
        withTempDefaults { defaults in
            let store = UserDefaultsHideStore(defaults: defaults)
            store.save([UUID()])
            #expect(!store.load().isEmpty)
            // "Show all" persists an empty set -> a relaunch starts visible.
            store.save([])
            #expect(store.load().isEmpty)
        }
    }

    @Test func malformedStringsAreDropped() {
        withTempDefaults { defaults in
            // A corrupted/legacy defaults entry must not crash load(); only the
            // parseable UUIDs survive the compactMap.
            let good = UUID()
            defaults.set([good.uuidString, "not-a-uuid", ""], forKey: UserDefaultsHideStore.key)
            let store = UserDefaultsHideStore(defaults: defaults)
            #expect(store.load() == [good])
        }
    }

    @Test func usesTheDocumentedDefaultsKey() {
        // Pin the key so a rename can't silently orphan everyone's saved hide set.
        #expect(UserDefaultsHideStore.key == "agentDashboardHiddenIDs")
    }
}

// MARK: - Config default substitution (agent-dashboard-commands)

struct AgentDashboardConfigTests {
    @Test func emptyParsedYieldsDefault() {
        // The Zig field defaults EMPTY; the user-facing default lives in the
        // Swift getter. An unset/empty key must substitute [claude, codex].
        #expect(Ghostty.Config.resolveAgentDashboardCommands([]) == ["claude", "codex"])
    }

    @Test func nonEmptyParsedPassesThrough() {
        // A configured set must pass through verbatim (no default injection).
        #expect(Ghostty.Config.resolveAgentDashboardCommands(["aider"]) == ["aider"])
        #expect(Ghostty.Config.resolveAgentDashboardCommands(["claude", "codex", "aider"])
            == ["claude", "codex", "aider"])
    }

    @Test func defaultMatchesPublishedConstant() {
        #expect(Ghostty.Config.agentDashboardCommandsDefault == ["claude", "codex"])
    }
}

// MARK: - Sort order + bell-frame derivation

@MainActor
struct AgentDashboardSortTests {
    private func entry(_ id: UUID, bell: Bool) -> AgentEntry {
        .init(id: id, realView: nil, title: "t", pwd: "/x", agent: nil,
              bell: bell, hidden: false, sessionID: 0)
    }

    @Test func bellFirst() {
        // Two non-bell + one bell; bell must come first regardless of UUID order.
        let ring = UUID()
        let q1 = UUID()
        let q2 = UUID()
        let entries = [entry(q1, bell: false), entry(q2, bell: false), entry(ring, bell: true)]
        let sorted = AgentDashboardModel.sorted(entries)
        #expect(sorted.first?.id == ring)
    }

    @Test func uuidTieBreakStable() {
        // No bells, no lastSeen: order is deterministic by uuidString.
        let ids = (0..<4).map { _ in UUID() }
        let entries = ids.map { entry($0, bell: false) }
        let sorted = AgentDashboardModel.sorted(entries).map(\.id)
        let expected = ids.sorted { $0.uuidString < $1.uuidString }
        #expect(sorted == expected)
    }

    @Test func livenessSecondaryKey() {
        // Among non-bell tiles, more-recently-seen comes first.
        let older = UUID(), newer = UUID()
        let entries = [entry(older, bell: false), entry(newer, bell: false)]
        let lastSeen: [UUID: Date] = [
            older: Date(timeIntervalSince1970: 1),
            newer: Date(timeIntervalSince1970: 100),
        ]
        let sorted = AgentDashboardModel.sorted(entries, lastSeen: lastSeen).map(\.id)
        #expect(sorted == [newer, older])
    }

    @Test func bellOutranksLiveness() {
        // A just-rang tile beats a more-recently-active non-bell tile.
        let ringOld = UUID(), busyNew = UUID()
        let entries = [entry(busyNew, bell: false), entry(ringOld, bell: true)]
        let lastSeen: [UUID: Date] = [
            ringOld: Date(timeIntervalSince1970: 1),
            busyNew: Date(timeIntervalSince1970: 100),
        ]
        let sorted = AgentDashboardModel.sorted(entries, lastSeen: lastSeen).map(\.id)
        #expect(sorted.first == ringOld)
    }
}

// MARK: - unzoomIfHidden decision (pure transform over SplitTree)

struct UnzoomDecisionTests {
    /// Exercises the SHIPPED decision `BaseTerminalController.unzoomedIfHidden`
    /// (not a clone), so a regression in the production guard / root-preservation
    /// fails the gate. The helper returns `nil` for a no-op; the test treats that
    /// as "tree unchanged".
    private func unzoomed(_ tree: SplitTree<MockView>, target: MockView) -> SplitTree<MockView> {
        BaseTerminalController.unzoomedIfHidden(tree, target: target) ?? tree
    }

    @Test func notZoomedIsNoOp() throws {
        let (tree, v1, _) = try SplitTreeTests.makeHorizontalSplit()
        #expect(tree.zoomed == nil)
        // No-op path returns nil from the production helper.
        #expect(BaseTerminalController.unzoomedIfHidden(tree, target: v1) == nil)
        let result = unzoomed(tree, target: v1)
        #expect(result.zoomed == nil)
        #expect(result.root == tree.root) // unchanged
    }

    @Test func targetInZoomedSubtreeIsNoOp() throws {
        let (base, _, v2) = try SplitTreeTests.makeHorizontalSplit()
        // Zoom onto v2's leaf node.
        let node = base.root?.node(view: v2)
        let zoomed = SplitTree<MockView>(root: base.root, zoomed: node)
        #expect(zoomed.zoomed != nil)
        // Target IS the zoomed split -> preserve the zoom (no-op → nil).
        #expect(BaseTerminalController.unzoomedIfHidden(zoomed, target: v2) == nil)
        let result = unzoomed(zoomed, target: v2)
        #expect(result.zoomed != nil)
    }

    @Test func targetHiddenUnderZoomClears() throws {
        let (base, v1, v2) = try SplitTreeTests.makeHorizontalSplit()
        // Zoom onto v2; target v1 is hidden -> clear zoom, preserve root.
        let node = base.root?.node(view: v2)
        let zoomed = SplitTree<MockView>(root: base.root, zoomed: node)
        let result = unzoomed(zoomed, target: v1)
        #expect(result.zoomed == nil)
        #expect(result.root == base.root) // ratios/structure unchanged
    }
}

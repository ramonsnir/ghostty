import AppKit
import Darwin
import Testing
@testable import Ghostty

// MARK: - AgentMirrorPreview geometry (pure)

struct AgentMirrorGeometryTests {
    @Test func framesFullHostGridAndPinsBottom() {
        // Realistic host grid (120x40, 14x30 backing px) on a 560x220 full-width
        // row at 2x backing.
        let g = AgentMirrorPreview.geometry(
            cols: 120, rows: 40, cellW: 14, cellH: 30, backing: 2,
            container: CGSize(width: 560, height: 220), referenceColumns: 120)
        // Natural size is the FULL host grid in points — NOT collapsed (the bug
        // that made the preview empty / one row produced a tiny naturalH here).
        #expect(abs(g.naturalW - 840) < 0.5)   // 120*14/2
        #expect(abs(g.naturalH - 600) < 0.5)   // 40*30/2
        // With referenceColumns == cols, the full width is filled (scale fits).
        #expect(abs(g.scale - 560.0 / 840.0) < 0.001)
        // The scaled content is TALLER than the row, so the top is clipped and
        // the agent's latest (bottom) rows are what's shown.
        #expect(g.naturalH * g.scale > 220)
    }

    @Test func fallsBackToContainerWhenGridUnknown() {
        // Before the first host frame (grid/cell == 0): no collapse, scale is a
        // no-op so the view fills the container rather than vanishing.
        let g = AgentMirrorPreview.geometry(
            cols: 0, rows: 0, cellW: 0, cellH: 0, backing: 2,
            container: CGSize(width: 560, height: 220))
        #expect(g.naturalW == 560)
        #expect(g.naturalH == 220)
        #expect(g.scale == 1)
    }

    @Test func zeroBackingDoesNotDivideByZero() {
        let g = AgentMirrorPreview.geometry(
            cols: 80, rows: 24, cellW: 16, cellH: 32, backing: 0,
            container: CGSize(width: 400, height: 200))
        // backing 0 is treated as 2; naturalW = 80*16/2 = 640.
        #expect(abs(g.naturalW - 640) < 0.5)
        #expect(g.scale > 0)
    }

    @Test func uniformScaleAcrossSplitsOfDifferentWidths() {
        // Two splits with DIFFERENT column counts but the same cell/backing must
        // get the SAME scale (uniform cell size), with `referenceColumns` (here
        // 120) filling the width. The narrow split's content is narrower than the
        // row (pads right); the wide split's overflows (horizontal scroll).
        let container = CGSize(width: 560, height: 220)
        let narrow = AgentMirrorPreview.geometry(
            cols: 80, rows: 24, cellW: 14, cellH: 30, backing: 2,
            container: container, referenceColumns: 120)
        let wide = AgentMirrorPreview.geometry(
            cols: 240, rows: 50, cellW: 14, cellH: 30, backing: 2,
            container: container, referenceColumns: 120)
        // Same uniform scale regardless of the split's own width.
        #expect(abs(narrow.scale - wide.scale) < 0.0001)
        #expect(abs(narrow.scale - 560.0 / (120.0 * 14.0 / 2.0)) < 0.001)
        // Narrow content fits within the row; wide content overflows → scroll.
        #expect(narrow.scaledW < container.width)
        #expect(wide.scaledW > container.width)
        // Exactly `referenceColumns` columns spans the width.
        let refWidth = AgentMirrorPreview.geometry(
            cols: 120, rows: 24, cellW: 14, cellH: 30, backing: 2,
            container: container, referenceColumns: 120).scaledW
        #expect(abs(refWidth - container.width) < 0.5)
    }
}

// MARK: - matchAgent pure logic

struct AgentDetectorTests {
    /// Helper: build a ProcSnapshot from (pid, name, children) tuples.
    private func snap(_ entries: [(pid_t, String, [pid_t])]) -> ProcSnapshot {
        var out: ProcSnapshot = [:]
        for (pid, name, children) in entries {
            out[pid] = (name: name, children: children)
        }
        return out
    }

    @Test func directHit() {
        let s = snap([(100, "claude", [])])
        #expect(matchAgent(rootPID: 100, snapshot: s, commands: ["claude", "codex"]) == AgentKind("claude"))
    }

    @Test func childHitShellNodeClaude() {
        // shell(100) -> node(200) -> claude(300)
        let s = snap([
            (100, "zsh", [200]),
            (200, "node", [300]),
            (300, "claude", []),
        ])
        #expect(matchAgent(rootPID: 100, snapshot: s, commands: ["claude"]) == AgentKind("claude"))
    }

    @Test func depthCapStopsWalk() {
        // Chain deeper than maxDepth=2: the claude at depth 3 must NOT be found.
        let s = snap([
            (1, "a", [2]),
            (2, "b", [3]),
            (3, "c", [4]),
            (4, "claude", []),
        ])
        #expect(matchAgent(rootPID: 1, snapshot: s, commands: ["claude"], maxDepth: 2) == nil)
        // With enough depth it IS found.
        #expect(matchAgent(rootPID: 1, snapshot: s, commands: ["claude"], maxDepth: 4) == AgentKind("claude"))
    }

    @Test func cycleVisitedCapTerminates() {
        // Self-referential / cyclic tree must terminate and return nil.
        let s = snap([
            (1, "a", [2]),
            (2, "b", [1, 2]), // points back at 1 and itself
        ])
        #expect(matchAgent(rootPID: 1, snapshot: s, commands: ["claude"]) == nil)
    }

    @Test func prefersPathBasename() {
        // The fixture stores a full path; matchAgent basenames it.
        let s = snap([(100, "/opt/homebrew/bin/codex", [])])
        #expect(matchAgent(rootPID: 100, snapshot: s, commands: ["codex"]) == AgentKind("codex"))
    }

    @Test func noMatchReturnsNil() {
        let s = snap([
            (100, "zsh", [200]),
            (200, "vim", []),
        ])
        #expect(matchAgent(rootPID: 100, snapshot: s, commands: ["claude", "codex"]) == nil)
    }

    @Test func configurableCommandSet() {
        let s = snap([(100, "claude", [])])
        // Only watching codex: claude should NOT match.
        #expect(matchAgent(rootPID: 100, snapshot: s, commands: ["codex"]) == nil)
        let s2 = snap([(100, "codex", [])])
        #expect(matchAgent(rootPID: 100, snapshot: s2, commands: ["codex"]) == AgentKind("codex"))
    }

    @Test func emptyCommandsNeverMatches() {
        let s = snap([(100, "claude", [])])
        #expect(matchAgent(rootPID: 100, snapshot: s, commands: []) == nil)
    }

    @Test func bfsShallowerMatchWins() {
        // claude at depth 1, codex at depth 2 under one root. BFS must return the
        // SHALLOWER match (claude) deterministically — a DFS would surface codex
        // and break the documented "shallower wins" contract.
        let s = snap([
            (1, "zsh", [2]),
            (2, "claude", [3]),
            (3, "codex", []),
        ])
        #expect(matchAgent(rootPID: 1, snapshot: s, commands: ["claude", "codex"]) == AgentKind("claude"))
    }

    @Test func bfsShallowerWinsAcrossBranches() {
        // Two matches at different depths on separate branches: depth-1 codex must
        // beat depth-2 claude regardless of dictionary/child ordering.
        let s = snap([
            (1, "zsh", [2, 3]),
            (2, "codex", []),       // depth 1
            (3, "node", [4]),
            (4, "claude", []),      // depth 2
        ])
        #expect(matchAgent(rootPID: 1, snapshot: s, commands: ["claude", "codex"]) == AgentKind("codex"))
    }
}

// MARK: - AgentDetector cache / resolve logic

/// Counting fake: records how many times each rootPID was walked, so we can
/// assert the cache skips a re-walk when the pid is unchanged.
private final class CountingEnumerator: ProcEnumerator {
    var byPID: [pid_t: ProcSnapshot]
    private(set) var walkCount: [pid_t: Int] = [:]
    init(_ byPID: [pid_t: ProcSnapshot]) { self.byPID = byPID }
    func snapshot(rootPID: pid_t) -> ProcSnapshot {
        walkCount[rootPID, default: 0] += 1
        return byPID[rootPID] ?? [:]
    }
}

struct AgentDetectorCacheTests {
    @Test func cacheHitSkipsRewalk() {
        let a = UUID()
        let claudeTree: ProcSnapshot = [100: (name: "claude", children: [])]
        let en = CountingEnumerator([100: claudeTree])

        // First tick: cold cache -> one walk, claude detected.
        let (r1, c1) = AgentDetector.resolve(
            snapshot: [(a, 100)], cache: [:], commands: ["claude"], enumerator: en)
        #expect(r1[a] == AgentKind("claude"))
        #expect(en.walkCount[100] == 1)

        // Second tick: same pid -> cache hit, NO re-walk.
        let (r2, _) = AgentDetector.resolve(
            snapshot: [(a, 100)], cache: c1, commands: ["claude"], enumerator: en)
        #expect(r2[a] == AgentKind("claude"))
        #expect(en.walkCount[100] == 1) // unchanged
    }

    @Test func cacheMissOnPIDChangeRewalks() {
        let a = UUID()
        let en = CountingEnumerator([
            100: [100: (name: "claude", children: [])],
            200: [200: (name: "vim", children: [])],
        ])
        let (_, c1) = AgentDetector.resolve(
            snapshot: [(a, 100)], cache: [:], commands: ["claude"], enumerator: en)
        #expect(en.walkCount[100] == 1)

        // Foreground pid changed (100 -> 200): must re-walk, and now no agent.
        let (r2, _) = AgentDetector.resolve(
            snapshot: [(a, 200)], cache: c1, commands: ["claude"], enumerator: en)
        #expect(en.walkCount[200] == 1)
        #expect(r2[a] == nil)
    }

    @Test func negativeResultRewalksWhenAgentAppearsUnderStablePID() {
        // Regression: the claude-accounts pool keeps a stable foreground pid (a
        // `bash …/claude-pool` leader) and spawns the `claude` child LATER. A
        // nil result must NOT be cached, or the agent stays invisible forever
        // (the pid never changes, so a pid-keyed cache would never re-walk).
        let a = UUID()
        let en = CountingEnumerator([
            // Tick 1: leader present, NO agent child yet.
            100: [100: (name: "bash", children: [])],
        ])
        let (r1, c1) = AgentDetector.resolve(
            snapshot: [(a, 100)], cache: [:], commands: ["claude"], enumerator: en)
        #expect(r1[a] == nil)
        #expect(en.walkCount[100] == 1)

        // The pool starts claude under the SAME leader pid.
        en.byPID[100] = [
            100: (name: "bash", children: [200]),
            200: (name: "/Users/ramon/.local/share/claude/versions/2.1.181", children: []),
        ]
        let (r2, _) = AgentDetector.resolve(
            snapshot: [(a, 100)], cache: c1, commands: ["claude"], enumerator: en)
        #expect(r2[a] == AgentKind("claude")) // now detected
        #expect(en.walkCount[100] == 2)       // re-walked despite the stable pid
    }

    @Test func vanishedIDDroppedFromCache() {
        let a = UUID(), b = UUID()
        let en = CountingEnumerator([
            100: [100: (name: "claude", children: [])],
            200: [200: (name: "codex", children: [])],
        ])
        let (_, c1) = AgentDetector.resolve(
            snapshot: [(a, 100), (b, 200)], cache: [:],
            commands: ["claude", "codex"], enumerator: en)
        #expect(c1.count == 2)

        // b's surface vanished: next snapshot has only a -> next cache drops b.
        let (r2, c2) = AgentDetector.resolve(
            snapshot: [(a, 100)], cache: c1, commands: ["claude", "codex"], enumerator: en)
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

    /// Like `live(_:)` but with explicit (uuid, sessionID) pairs — needed for the
    /// userNotes write-through, which persists by the stable host session id.
    private func live(_ pairs: [(UUID, UInt64)]) -> [AgentDashboardModel.LiveSurface] {
        pairs.map { (id, sid) in
            .init(id: id, view: nil, title: "t", pwd: "/x", sessionID: sid)
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
              bell: bell, hidden: false, sessionID: 0,
              agentState: nil, lastTool: nil, lastPrompt: nil, hookBacked: false,
              annotation: nil, userNotes: nil)
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

    // MARK: - Manual order (ramon fork / Agent Dashboard)

    private func entry(_ id: UUID, session: UInt64, bell: Bool = false, waiting: Bool = false) -> AgentEntry {
        .init(id: id, realView: nil, title: "t", pwd: "/x", agent: nil,
              bell: bell, hidden: false, sessionID: session,
              agentState: waiting ? .waiting : nil,
              lastTool: nil, lastPrompt: nil, hookBacked: false,
              annotation: nil, userNotes: nil)
    }

    @Test func manualRankOrdersPlacedTiles() {
        // All placed (sessions present in manualRank), no attention, equal
        // recency: order follows the manual rank, NOT UUID.
        let a = UUID(), b = UUID(), c = UUID()
        let entries = [entry(a, session: 10), entry(b, session: 20), entry(c, session: 30)]
        let rank: [UInt64: Int] = [30: 0, 10: 1, 20: 2]
        let sorted = AgentDashboardModel.sorted(entries, manualRank: rank).map(\.sessionID)
        #expect(sorted == [30, 10, 20])
    }

    @Test func unplacedTileFloatsAbovePlaced() {
        // A tile with no manual rank (a freshly-appeared agent) sorts ABOVE the
        // placed ones — the "new agents at top" choice.
        let a = UUID(), b = UUID(), fresh = UUID()
        let entries = [entry(a, session: 1), entry(b, session: 2), entry(fresh, session: 99)]
        let rank: [UInt64: Int] = [1: 0, 2: 1]   // 99 is unplaced
        let sorted = AgentDashboardModel.sorted(entries, manualRank: rank).map(\.sessionID)
        #expect(sorted == [99, 1, 2])
    }

    @Test func attentionOutranksManualOrder() {
        // A waiting tile placed LAST in the manual order still floats to the top.
        let a = UUID(), b = UUID(), wait = UUID()
        let entries = [
            entry(a, session: 1),
            entry(b, session: 2),
            entry(wait, session: 3, waiting: true),
        ]
        let rank: [UInt64: Int] = [1: 0, 2: 1, 3: 2]
        let sorted = AgentDashboardModel.sorted(entries, manualRank: rank)
        #expect(sorted.first?.id == wait)
    }

    @Test func sessionZeroIsNeverPlaced() {
        // A sessionless tile (id 0) is treated as unplaced even if a rank for 0
        // somehow exists — it can't be ordered stably, so it floats up (unplaced)
        // and never sorts by the bogus rank.
        let zero = UUID(), placed = UUID()
        let entries = [entry(placed, session: 5), entry(zero, session: 0)]
        let rank: [UInt64: Int] = [0: 9, 5: 0]
        let sorted = AgentDashboardModel.sorted(entries, manualRank: rank).map(\.sessionID)
        #expect(sorted == [0, 5])
    }
}

// MARK: - Manual order: model round-trip (ramon fork / Agent Dashboard)

@MainActor
struct AgentDashboardManualOrderModelTests {
    private func live(_ pairs: [(UUID, UInt64)]) -> [AgentDashboardModel.LiveSurface] {
        pairs.map { .init(id: $0.0, view: nil, title: "t", pwd: "/x", sessionID: $0.1) }
    }
    private func agents(_ ids: [UUID]) -> [UUID: AgentKind] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, AgentKind("claude")) })
    }

    @Test func setManualOrderPersistsAndReorders() {
        let store = InMemoryOrderStore()
        let model = AgentDashboardModel(store: InMemoryHideStore(), orderStore: store)
        let a = UUID(), b = UUID(), c = UUID()
        model.rebuild(live: live([(a, 1), (b, 2), (c, 3)]))
        model.applyAgents(agents([a, b, c]))
        model.setManualOrder([3, 1, 2])
        #expect(model.manualOrder == [3, 1, 2])
        #expect(store.load() == [3, 1, 2])           // persisted
        #expect(model.entries.map(\.sessionID) == [3, 1, 2])
        #expect(model.hasManualOrder)
    }

    @Test func sessionlessTilesDroppedFromOrder() {
        let store = InMemoryOrderStore()
        let model = AgentDashboardModel(store: InMemoryHideStore(), orderStore: store)
        model.setManualOrder([0, 5, 0, 7])
        #expect(model.manualOrder == [5, 7])
        #expect(store.load() == [5, 7])
    }

    @Test func resetOrderClearsAndPersists() {
        let store = InMemoryOrderStore([9, 8, 7])
        let model = AgentDashboardModel(store: InMemoryHideStore(), orderStore: store)
        #expect(model.manualOrder == [9, 8, 7])      // loaded from the store at init
        #expect(model.hasManualOrder)
        model.resetOrder()
        #expect(model.manualOrder.isEmpty)
        #expect(store.load().isEmpty)
        #expect(!model.hasManualOrder)
    }

    @Test func newAgentFloatsAbovePlacedAfterRebuild() {
        let store = InMemoryOrderStore()
        let model = AgentDashboardModel(store: InMemoryHideStore(), orderStore: store)
        let a = UUID(), b = UUID()
        model.rebuild(live: live([(a, 1), (b, 2)]))
        model.applyAgents(agents([a, b]))
        model.setManualOrder([1, 2])
        #expect(model.entries.map(\.sessionID) == [1, 2])
        // A new agent (session 3) appears: it's unplaced, so it floats to the top.
        let c = UUID()
        model.rebuild(live: live([(a, 1), (b, 2), (c, 3)]))
        model.applyAgents(agents([a, b, c]))
        #expect(model.entries.map(\.sessionID) == [3, 1, 2])
    }
}

// MARK: - Hook agent-state model transitions (ramon fork / Agent hooks)

@MainActor
struct AgentDashboardHookStateTests {
    private func live(_ ids: [UUID]) -> [AgentDashboardModel.LiveSurface] {
        ids.map { .init(id: $0, view: nil, title: "t", pwd: "/x", sessionID: 0) }
    }

    private func agents(_ ids: [UUID]) -> [UUID: AgentKind] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, AgentKind("claude")) })
    }

    private func payload(
        _ state: AgentState, tool: String? = nil, prompt: String? = nil, message: String? = nil
    ) -> AgentStatePayload {
        .init(tty: "ttys004", state: state, prompt: prompt, tool: tool, message: message)
    }

    @Test func hookBackedInsertedOnFirstEvent() {
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        #expect(!model.hookBacked.contains(a))

        model.applyAgentState(a, payload(.working))
        #expect(model.hookBacked.contains(a))
        #expect(model.agentStates[a] == .working)
        #expect(model.entries.first(where: { $0.id == a })?.hookBacked == true)
        #expect(model.entries.first(where: { $0.id == a })?.agentState == .working)
    }

    @Test func workingToWaitingReturnsTrueAndUnhides() {
        let store = InMemoryHideStore()
        let model = AgentDashboardModel(store: store)
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))

        // Enter working, then hide the tile.
        _ = model.applyAgentState(a, payload(.working))
        model.hide(a)
        #expect(model.hidden.contains(a))

        // working -> waiting: enters waiting (returns true) AND auto-unhides.
        let entered = model.applyAgentState(a, payload(.waiting, message: "approve?"))
        #expect(entered == true)
        #expect(!model.hidden.contains(a))
        #expect(!store.load().contains(a))            // persistence updated
        #expect(model.agentStates[a] == .waiting)
        #expect(model.entries.map(\.id).contains(a))  // reappears
    }

    @Test func nilToWaitingEntersWaiting() {
        // First event is .waiting (prev == nil): still the entering edge.
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        let entered = model.applyAgentState(a, payload(.waiting, message: "input?"))
        #expect(entered == true)
        #expect(model.agentStates[a] == .waiting)
    }

    @Test func waitingRepublishDoesNotReEnter() {
        // A second .waiting with the SAME message is coalesced (no transition):
        // returns false, so the controller does not re-post attention/push.
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        #expect(model.applyAgentState(a, payload(.waiting, message: "input?")) == true)
        // Identical republish: coalesced, returns false.
        #expect(model.applyAgentState(a, payload(.waiting, message: "input?")) == false)
        #expect(model.agentStates[a] == .waiting)
    }

    @Test func coalescedWaitingRepublishDoesNotReUnhideHiddenTile() {
        // LOCKED, deliberately counterintuitive (AgentDashboardController.swift
        // applyAgentState): a COALESCED identical `.waiting` republish does NOT
        // re-unhide a manually-hidden tile — weaker than applyBells' re-unhide on
        // every republish, because a Notification fires ONCE (not continuously like
        // a bell). So the user CAN re-hide a still-waiting tile. This is the only
        // safeguard against a future "fix" that makes waiting re-unhide on republish.
        let store = InMemoryHideStore()
        let model = AgentDashboardModel(store: store)
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))

        // Enter waiting (the edge auto-unhides if hidden; here it isn't hidden yet).
        #expect(model.applyAgentState(a, payload(.waiting, message: "input?")) == true)
        // User hides the still-waiting tile.
        model.hide(a)
        #expect(model.hidden.contains(a))

        // Identical `.waiting` republish: coalesced (returns false) AND — the locked
        // bit — does NOT re-unhide. Distinguishes this from the working->waiting
        // auto-unhide path tested in workingToWaitingReturnsTrueAndUnhides.
        #expect(model.applyAgentState(a, payload(.waiting, message: "input?")) == false)
        #expect(model.hidden.contains(a))            // STAYS hidden (locked)
        #expect(store.load().contains(a))            // persistence still has it
    }

    @Test func waitingWithNewMessageStaysWaitingButDoesNotReEnter() {
        // prev == .waiting, new message differs: NOT coalesced (message changed),
        // but the entering-waiting edge is prev != .waiting, so it returns false.
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        #expect(model.applyAgentState(a, payload(.waiting, message: "first")) == true)
        #expect(model.applyAgentState(a, payload(.waiting, message: "second")) == false)
        #expect(model.lastMessage[a] == "second")
    }

    @Test func coalesceUnchangedWorkingNoRebuild() {
        // Repeated PreToolUse(working) with no field changes must coalesce. The
        // GENUINE proof the rebuild was skipped is the early-return value `r == false`
        // (the early-return at applyAgentState returns BEFORE rebuilding). The id
        // array-compare below is only a sanity check that nothing was added/removed;
        // it does NOT prove "no rebuild thrash" (ids would match even if a full
        // rebuild ran, and AgentEntry isn't Equatable so a value compare isn't
        // possible) — the `r == false` assertion is the load-bearing one.
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        _ = model.applyAgentState(a, payload(.working, tool: "Bash"))
        let before = model.entries

        // Same state + same tool -> coalesced: returns false (early return, no rebuild).
        let r = model.applyAgentState(a, payload(.working, tool: "Bash"))
        #expect(r == false)                            // the genuine no-rebuild signal
        #expect(model.entries.map(\.id) == before.map(\.id))  // sanity: membership unchanged
        #expect(model.entries.first?.lastTool == "Bash")
    }

    @Test func newToolUpdatesEntryNotCoalesced() {
        // working -> working but a DIFFERENT tool: not coalesced; lastTool updates.
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        _ = model.applyAgentState(a, payload(.working, tool: "Bash"))
        let r = model.applyAgentState(a, payload(.working, tool: "Read"))
        #expect(r == false)                       // not entering waiting
        #expect(model.lastTool[a] == "Read")
        #expect(model.entries.first?.lastTool == "Read")
    }

    @Test func nilFieldLeavesPreviousValue() {
        // tool is only present on PreToolUse; a later .idle (tool nil) must LEAVE
        // the sticky lastTool/lastPrompt rather than wiping them.
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        _ = model.applyAgentState(a, payload(.working, tool: "Bash", prompt: "do it"))
        _ = model.applyAgentState(a, payload(.idle))
        #expect(model.agentStates[a] == .idle)
        #expect(model.lastTool[a] == "Bash")
        #expect(model.lastPrompt[a] == "do it")
    }

    @Test func waitingToIdleDoesNotEnterWaiting() {
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        _ = model.applyAgentState(a, payload(.waiting, message: "?"))
        let r = model.applyAgentState(a, payload(.idle))
        #expect(r == false)
        #expect(model.agentStates[a] == .idle)
    }

    @Test func entryProjectionCarriesHookFields() {
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        _ = model.applyAgentState(a, payload(.working, tool: "Grep", prompt: "find foo"))
        let e = model.entries.first { $0.id == a }
        #expect(e?.agentState == .working)
        #expect(e?.lastTool == "Grep")
        #expect(e?.lastPrompt == "find foo")
        #expect(e?.hookBacked == true)
    }

    @Test func hooklessEntryHasNilState() {
        // A detected agent that never POSTed a hook has nil agentState + false
        // hookBacked (the idleSeconds heuristic, if any, is NOT muted).
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        let e = model.entries.first { $0.id == a }
        #expect(e?.agentState == nil)
        #expect(e?.hookBacked == false)
        #expect(e?.lastTool == nil)
    }

    @Test func dropStalePrunesHookState() {
        // A closed surface's hook state is dropped on rebuild(live:) exactly like
        // bells/agents/lastSeen.
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID(), b = UUID()
        model.rebuild(live: live([a, b]))
        model.applyAgents(agents([a, b]))
        _ = model.applyAgentState(a, payload(.waiting, message: "?"))
        _ = model.applyAgentState(b, payload(.working, tool: "Bash"))
        #expect(model.hookBacked.contains(a))
        #expect(model.hookBacked.contains(b))

        // a's surface vanishes: its hook state must be pruned, b's kept.
        model.rebuild(live: live([b]))
        #expect(!model.hookBacked.contains(a))
        #expect(model.agentStates[a] == nil)
        #expect(model.lastMessage[a] == nil)
        #expect(model.hookBacked.contains(b))
        #expect(model.agentStates[b] == .working)
        #expect(model.lastTool[b] == "Bash")
    }

    @Test func waitingSortsFirstViaAttentionKey() {
        // A .waiting (no bell) tile floats above a plain working tile via the
        // attention-first sort key (bell OR waiting).
        let waiting = UUID(), working = UUID()
        let store = InMemoryHideStore()
        let model = AgentDashboardModel(store: store)
        model.rebuild(live: live([waiting, working]))
        model.applyAgents(agents([waiting, working]))
        _ = model.applyAgentState(working, payload(.working))
        _ = model.applyAgentState(waiting, payload(.waiting, message: "?"))
        #expect(model.entries.first?.id == waiting)
    }

    // MARK: - Annotations (ramon fork / Agent Manager)

    private func annotation(_ summary: String) -> AgentAnnotation {
        .init(summary: summary, suggestion: nil, phase: nil, needsUser: nil, confidence: nil)
    }

    @Test func applyAnnotationStoresAndRendersSummary() {
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))

        model.applyAnnotation(a, annotation("Running test suite"))
        #expect(model.annotations[a]?.summary == "Running test suite")
        #expect(model.entries.first(where: { $0.id == a })?.annotation?.summary == "Running test suite")
    }

    @Test func applyAnnotationMergesPartialUpdates() {
        // (Phase 2) Two independent partial updates — a summary then a suggestion —
        // MERGE: each preserves the other's field rather than clobbering it.
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))

        model.applyAnnotation(a, AgentAnnotation(
            summary: "Implementing fix", suggestion: nil, phase: nil,
            needsUser: nil, confidence: nil))
        model.applyAnnotation(a, AgentAnnotation(
            summary: nil, suggestion: "Approve it", phase: nil,
            needsUser: nil, confidence: nil))
        #expect(model.annotations[a]?.summary == "Implementing fix")  // preserved
        #expect(model.annotations[a]?.suggestion == "Approve it")     // added
        // A later summary-only update keeps the suggestion.
        model.applyAnnotation(a, annotation("Running tests"))
        #expect(model.annotations[a]?.summary == "Running tests")
        #expect(model.annotations[a]?.suggestion == "Approve it")
    }

    @Test func dismissSuggestionClearsSuggestionKeepsSummary() {
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        model.applyAnnotation(a, AgentAnnotation(
            summary: "Waiting on a decision", suggestion: "Approve", phase: "testing",
            needsUser: true, confidence: nil))
        model.dismissSuggestion(a)
        #expect(model.annotations[a]?.suggestion == nil)              // cleared
        #expect(model.annotations[a]?.summary == "Waiting on a decision")  // kept
        #expect(model.annotations[a]?.phase == "testing")            // kept
        #expect(model.annotations[a]?.needsUser == true)             // kept
        // The tile sees no suggestion now.
        #expect(model.entries.first { $0.id == a }?.annotation?.suggestion == nil)
    }

    @Test func annotationPrunedForVanishedSurface() {
        // A closed surface's annotation is dropped on rebuild(live:) like the other
        // per-id state (in-memory only — nothing persisted, just no leak).
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID(), b = UUID()
        model.rebuild(live: live([a, b]))
        model.applyAgents(agents([a, b]))
        model.applyAnnotation(a, annotation("a-note"))
        model.applyAnnotation(b, annotation("b-note"))

        model.rebuild(live: live([b]))
        #expect(model.annotations[a] == nil)
        #expect(model.annotations[b]?.summary == "b-note")
    }

    @Test func hookSnapshotCarriesStateAndNotes() {
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID()
        // sessionID non-zero so the userNotes write-through persists by session id.
        model.rebuild(live: live([(a, 11)]))
        model.applyAgents(agents([a]))
        _ = model.applyAgentState(a, payload(.working, tool: "Bash", prompt: "do it"))
        model.applyAnnotation(a, annotation("Implementing fix"))
        model.setUserNotes(a, "migrate to postgres")

        let snap = model.hookSnapshot()
        #expect(snap[a]?.agentState == "working")
        #expect(snap[a]?.lastTool == "Bash")
        #expect(snap[a]?.lastPrompt == "do it")
        #expect(snap[a]?.notes == "Implementing fix")
        #expect(snap[a]?.userNotes == "migrate to postgres")
    }

    @Test func hookSnapshotOmitsSurfaceWithNoState() {
        // A surface with no hook event and no annotation is absent from the
        // snapshot — so the MCP shaper omits its agent-* fields (honest absence).
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let a = UUID()
        model.rebuild(live: live([a]))
        model.applyAgents(agents([a]))
        #expect(model.hookSnapshot()[a] == nil)
    }
}

// MARK: - Attention-first sort key (bell OR waiting)

@MainActor
struct AgentDashboardWaitingSortTests {
    private func entry(_ id: UUID, bell: Bool, state: AgentState?) -> AgentEntry {
        .init(id: id, realView: nil, title: "t", pwd: "/x", agent: nil,
              bell: bell, hidden: false, sessionID: 0,
              agentState: state, lastTool: nil, lastPrompt: nil, hookBacked: state != nil,
              annotation: nil, userNotes: nil)
    }

    @Test func waitingBeatsWorking() {
        let waiting = UUID(), working = UUID()
        let sorted = AgentDashboardModel.sorted([
            entry(working, bell: false, state: .working),
            entry(waiting, bell: false, state: .waiting),
        ])
        #expect(sorted.first?.id == waiting)
    }

    @Test func bellAndWaitingBothFloatAboveQuiet() {
        let bellOnly = UUID(), waitingOnly = UUID(), quiet = UUID()
        let sorted = AgentDashboardModel.sorted([
            entry(quiet, bell: false, state: .working),
            entry(bellOnly, bell: true, state: .idle),
            entry(waitingOnly, bell: false, state: .waiting),
        ]).map(\.id)
        // Both attention tiles precede the quiet one; quiet is last.
        #expect(sorted.last == quiet)
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

// MARK: - Agent-state persistence across GUI restart (ramon fork / hooks)

@MainActor
struct AgentStatePersistenceTests {
    private func live(_ pairs: [(UUID, UInt64)]) -> [AgentDashboardModel.LiveSurface] {
        pairs.map { (id, sid) in .init(id: id, view: nil, title: "t", pwd: "/x", sessionID: sid) }
    }
    private func agents(_ ids: [UUID]) -> [UUID: AgentKind] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, AgentKind("claude")) })
    }
    private func rec(_ state: String, updated: Double = Date().timeIntervalSince1970) -> PersistedAgentState {
        PersistedAgentState(state: state, tool: nil, prompt: nil, message: nil, updated: updated)
    }
    private func payload(_ s: AgentState, tool: String? = nil) -> AgentStatePayload {
        AgentStatePayload(tty: "ttys1", state: s, prompt: nil, tool: tool, message: nil)
    }

    // MARK: pure prune

    @Test func prunesByAge() {
        let now = Date()
        let nowS = now.timeIntervalSince1970
        let out = AgentDashboardModel.prune(
            [1: rec("working", updated: nowS), 2: rec("idle", updated: nowS - 100_000)],
            now: now, maxAge: 3600, maxCount: 256)
        #expect(out[1] != nil)
        #expect(out[2] == nil)   // older than maxAge dropped
    }

    @Test func prunesByCountKeepingNewest() {
        let nowS = Date().timeIntervalSince1970
        var map: [UInt64: PersistedAgentState] = [:]
        for i in 0..<10 { map[UInt64(i)] = rec("idle", updated: nowS - Double(i)) }
        let out = AgentDashboardModel.prune(map, now: Date(), maxAge: 1_000_000, maxCount: 3)
        #expect(out.count == 3)
        #expect(out[0] != nil && out[1] != nil && out[2] != nil) // newest (closest to now)
        #expect(out[9] == nil)
    }

    // MARK: store round trip (UInt64 keys survive JSON string-keying)

    @Test func userDefaultsStoreRoundTripsUInt64Keys() {
        let suite = "ghostty-test-agentstate-roundtrip"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }
        let store = UserDefaultsAgentStateStore(defaults: d)
        let r = PersistedAgentState(state: "waiting", tool: "Bash", prompt: "hi", message: "approve?", updated: 123)
        store.save([42: r])
        #expect(store.load()[42] == r)
    }

    // MARK: hydrate on rebuild

    @Test func hydratesPersistedStateOntoFreshUUIDBySessionID() {
        let sid: UInt64 = 7
        let model = AgentDashboardModel(
            store: InMemoryHideStore(),
            agentStateStore: InMemoryAgentStateStore([sid: rec("waiting")]))
        let id = UUID()                              // a FRESH uuid (post-restart)
        model.applyAgents(agents([id]))
        model.rebuild(live: live([(id, sid)]))
        #expect(model.agentStates[id] == .waiting)   // restored onto the new uuid
        let entry = model.entries.first { $0.id == id }
        #expect(entry?.agentState == .waiting)       // and the tile shows it
        #expect(entry?.hookBacked == true)           // hook-authoritative
    }

    @Test func hydrateSkipsZeroSession() {
        let model = AgentDashboardModel(
            store: InMemoryHideStore(),
            agentStateStore: InMemoryAgentStateStore([5: rec("idle")]))
        let id = UUID()
        model.applyAgents(agents([id]))
        model.rebuild(live: live([(id, 0)]))         // sessionID 0 → never hydrated
        #expect(model.agentStates[id] == nil)
    }

    @Test func noCrossSessionContamination() {
        let a = UUID(), b = UUID()
        let model = AgentDashboardModel(
            store: InMemoryHideStore(),
            agentStateStore: InMemoryAgentStateStore([1: rec("working"), 2: rec("idle")]))
        model.applyAgents(agents([a, b]))
        model.rebuild(live: live([(a, 1), (b, 2)]))
        #expect(model.agentStates[a] == .working)
        #expect(model.agentStates[b] == .idle)
    }

    // MARK: write-through

    @Test func writeThroughPersistsBySessionID() {
        let sid: UInt64 = 99
        let store = InMemoryAgentStateStore()
        let model = AgentDashboardModel(store: InMemoryHideStore(), agentStateStore: store)
        let id = UUID()
        model.applyAgents(agents([id]))
        model.rebuild(live: live([(id, sid)]))       // populate `live` so the sid resolves
        model.applyAgentState(id, payload(.working, tool: "Bash"))
        #expect(store.load()[sid]?.state == "working")
        #expect(store.load()[sid]?.tool == "Bash")
    }

    @Test func writeThroughSkipsWhenSessionUnknown() {
        let store = InMemoryAgentStateStore()
        let model = AgentDashboardModel(store: InMemoryHideStore(), agentStateStore: store)
        // No rebuild → `live` empty → session id unknown → nothing persisted.
        model.applyAgentState(UUID(), payload(.working))
        #expect(store.load().isEmpty)
    }

    // MARK: live hook overrides a restored state

    @Test func liveHookOverridesHydratedState() {
        let sid: UInt64 = 3
        let store = InMemoryAgentStateStore([sid: rec("working")])
        let model = AgentDashboardModel(store: InMemoryHideStore(), agentStateStore: store)
        let id = UUID()
        model.applyAgents(agents([id]))
        model.rebuild(live: live([(id, sid)]))
        #expect(model.agentStates[id] == .working)        // hydrated
        let entered = model.applyAgentState(id, payload(.waiting))
        #expect(entered == true)                          // working→waiting edge fires
        #expect(model.agentStates[id] == .waiting)        // live wins over restored
        #expect(store.load()[sid]?.state == "waiting")    // and is persisted
    }

    // MARK: prune-on-load re-saves

    @Test func pruneOnLoadDropsAncientAndResaves() {
        let store = InMemoryAgentStateStore([1: rec("idle", updated: 0)])  // 1970 → ancient
        _ = AgentDashboardModel(store: InMemoryHideStore(), agentStateStore: store)
        #expect(store.load().isEmpty)    // pruned + re-saved at init
    }
}

// MARK: - User notes persistence (ramon fork / Agent Manager Phase 2)

@MainActor
struct UserNotesPersistenceTests {
    private func live(_ pairs: [(UUID, UInt64)]) -> [AgentDashboardModel.LiveSurface] {
        pairs.map { (id, sid) in .init(id: id, view: nil, title: "t", pwd: "/x", sessionID: sid) }
    }
    private func agents(_ ids: [UUID]) -> [UUID: AgentKind] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, AgentKind("claude")) })
    }

    // MARK: store round trip (UInt64 keys survive JSON string-keying)

    @Test func userDefaultsStoreRoundTripsUInt64Keys() {
        let suite = "ghostty-test-usernotes-roundtrip"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }
        let store = UserDefaultsUserNotesStore(defaults: d)
        store.save([42: "migrate to postgres", 7: "fix the flaky test"])
        let loaded = store.load()
        #expect(loaded[42] == "migrate to postgres")
        #expect(loaded[7] == "fix the flaky test")
    }

    // MARK: hydrate on rebuild (by session id, onto a fresh UUID)

    @Test func hydratesPersistedNoteOntoFreshUUIDBySessionID() {
        let sid: UInt64 = 7
        let model = AgentDashboardModel(
            store: InMemoryHideStore(),
            userNotesStore: InMemoryUserNotesStore([sid: "ship the migration"]))
        let id = UUID()                              // a FRESH uuid (post-restart)
        model.applyAgents(agents([id]))
        model.rebuild(live: live([(id, sid)]))
        #expect(model.userNotes[id] == "ship the migration")
        #expect(model.entries.first { $0.id == id }?.userNotes == "ship the migration")
    }

    @Test func hydrateSkipsZeroSession() {
        let model = AgentDashboardModel(
            store: InMemoryHideStore(),
            userNotesStore: InMemoryUserNotesStore([0: "orphan note"]))
        let id = UUID()
        model.applyAgents(agents([id]))
        model.rebuild(live: live([(id, 0)]))         // sessionID 0 → never hydrated
        #expect(model.userNotes[id] == nil)
    }

    @Test func noCrossSessionContamination() {
        let a = UUID(), b = UUID()
        let model = AgentDashboardModel(
            store: InMemoryHideStore(),
            userNotesStore: InMemoryUserNotesStore([1: "note-a", 2: "note-b"]))
        model.applyAgents(agents([a, b]))
        model.rebuild(live: live([(a, 1), (b, 2)]))
        #expect(model.userNotes[a] == "note-a")
        #expect(model.userNotes[b] == "note-b")
    }

    // MARK: write-through

    @Test func writeThroughPersistsBySessionID() {
        let sid: UInt64 = 99
        let store = InMemoryUserNotesStore()
        let model = AgentDashboardModel(store: InMemoryHideStore(), userNotesStore: store)
        let id = UUID()
        model.applyAgents(agents([id]))
        model.rebuild(live: live([(id, sid)]))       // populate `live` so the sid resolves
        model.setUserNotes(id, "use the new schema")
        #expect(model.userNotes[id] == "use the new schema")
        #expect(store.load()[sid] == "use the new schema")
    }

    @Test func writeThroughSkipsWhenSessionUnknown() {
        let store = InMemoryUserNotesStore()
        let model = AgentDashboardModel(store: InMemoryHideStore(), userNotesStore: store)
        // No rebuild → `live` empty → session id unknown → nothing persisted (but
        // the in-memory note is still set for the live UUID).
        let id = UUID()
        model.setUserNotes(id, "transient")
        #expect(model.userNotes[id] == "transient")
        #expect(store.load().isEmpty)
    }

    @Test func blankNoteRemovesAndPersistsRemoval() {
        let sid: UInt64 = 5
        let store = InMemoryUserNotesStore([sid: "old note"])
        let model = AgentDashboardModel(store: InMemoryHideStore(), userNotesStore: store)
        let id = UUID()
        model.applyAgents(agents([id]))
        model.rebuild(live: live([(id, sid)]))       // hydrates "old note"
        #expect(model.userNotes[id] == "old note")
        model.setUserNotes(id, "   ")                // blank → remove
        #expect(model.userNotes[id] == nil)
        #expect(store.load()[sid] == nil)            // removal persisted
    }

    @Test func noteTrimmedOnWrite() {
        let model = AgentDashboardModel(store: InMemoryHideStore())
        let id = UUID()
        model.applyAgents(agents([id]))
        model.rebuild(live: live([(id, 1)]))
        model.setUserNotes(id, "  spaced goal  ")
        #expect(model.userNotes[id] == "spaced goal")
    }

    @Test func noteDroppedFromMemoryForVanishedSurfaceButKeptBySession() {
        let sid: UInt64 = 8
        let store = InMemoryUserNotesStore()
        let model = AgentDashboardModel(store: InMemoryHideStore(), userNotesStore: store)
        let id = UUID()
        model.applyAgents(agents([id]))
        model.rebuild(live: live([(id, sid)]))
        model.setUserNotes(id, "persist me")
        // Surface closes (no longer live): in-memory entry pruned, persisted kept.
        model.rebuild(live: live([]))
        #expect(model.userNotes[id] == nil)          // pruned from the in-memory map
        #expect(store.load()[sid] == "persist me")   // but persisted by session id
        // Reappears under the SAME session id with a fresh UUID → rehydrates.
        let id2 = UUID()
        model.applyAgents(agents([id2]))
        model.rebuild(live: live([(id2, sid)]))
        #expect(model.userNotes[id2] == "persist me")
    }
}

// MARK: - Panel pin (window level)

@MainActor
struct AgentDashboardPanelTests {
    @Test func defaultPanelIsNormalLevel() {
        // Unpinned (default): normal stacking so other windows can cover it.
        let panel = AgentDashboardPanel()
        #expect(panel.level == .normal)
    }

    @Test func pinnedPanelFloatsAboveOtherWindows() {
        // `agent-dashboard-pin = true` → floating level (native always-on-top),
        // while the AX subrole stays a standard window (the pin is the level,
        // not the subrole).
        let panel = AgentDashboardPanel(pinned: true)
        #expect(panel.level == .floating)
        #expect(panel.accessibilitySubrole() == .standardWindow)
    }
}

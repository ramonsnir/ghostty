// (ramon fork / Agent Queue Supervisor, §8a) The GUI→sidecar command channel
// VALUE TYPE + the notification the local UI (palette / dashboard buttons / a
// keybind action) posts to ENQUEUE a control command onto the MCP server's
// in-memory FIFO.
//
// The sidecar is the MCP CLIENT (it polls the GUI); the GUI cannot call it. So a
// local "start run X" / "pause/stop/abort/resume run Y" intent flows as a command
// the sidecar DRAINS each sweep via the `take_queue_commands` MCP tool. This file
// defines ONLY the pure value type and the notification name — `MCPServer` observes
// the notification (see MCPServer's queue-command extension) and enqueues onto its
// FIFO on its own serial queue so the enqueue is race-free.
//
// PURE value type — safe across the main→serial-queue hop (no AppKit references).
// iOS-excluded (macOS-only feature), like the rest of the MCP module.

import Foundation

/// One GUI→sidecar control command (§8a). Mirrors the sidecar's TS `QueueCommand`
/// (macos/agent-manager/src/queue/commands.ts) and the wire shape
/// `take_queue_commands` returns. `template` is the template BASENAME (the
/// `*.json` filename minus extension) for `start`; `run` is the active run NAME
/// (= `template.name`, the dashboard origin) for pause/resume/stop/abort/setMaxItems.
/// Unused fields are nil (omitted from the wire JSON).
struct QueueCommand: Equatable, Sendable {
    /// The recognized actions. A raw-value enum so it round-trips to the
    /// lowercase strings the sidecar's `coerceQueueCommands` whitelists.
    /// `setMaxItems` serializes to the snake_case `"set_max_items"` the sidecar
    /// expects (a live lifetime-cap edit — the dashboard cap control).
    enum Action: String, Equatable, Sendable {
        case start, stop, abort, pause, resume
        case setMaxItems = "set_max_items"
        case setConcurrency = "set_concurrency"
    }

    let action: Action
    /// The template basename to start (start only).
    let template: String?
    /// The active run name to pause/resume/stop/abort/setMaxItems/setConcurrency.
    let run: String?
    /// (§8b) START-TIME parameter answers (param name → value) collected by the
    /// queue palette's prompt, passed through to the sidecar factory (start only).
    /// nil/empty when the template declares no params.
    let params: [String: String]?
    /// (live maxItems edit) The new lifetime-cap VALUE for `setMaxItems` — the raw
    /// string the dashboard cap control collected ("10", "unlimited"/"0"/…). The
    /// sidecar parses it (blank/garbage = ignored). nil for other actions.
    let maxItems: String?
    /// (live concurrency edit) The new max-simultaneous-agents VALUE for
    /// `setConcurrency` — the raw string the dashboard parallel control collected
    /// ("9", …). The sidecar parses it (blank/garbage/non-positive = ignored, NO
    /// "unlimited" token). nil for other actions.
    let concurrency: String?

    init(
        action: Action,
        template: String? = nil,
        run: String? = nil,
        params: [String: String]? = nil,
        maxItems: String? = nil,
        concurrency: String? = nil
    ) {
        self.action = action
        self.template = template
        self.run = run
        self.params = params
        self.maxItems = maxItems
        self.concurrency = concurrency
    }

    /// PURE: the wire dict drained by `take_queue_commands`. `action` is always
    /// present; `template`/`run`/`maxItems`/`concurrency` are emitted only when
    /// non-nil and non-empty (mirrors the sidecar's tolerant `coerceQueueCommands`,
    /// which only keeps non-empty strings); `params` is emitted only when non-nil AND
    /// non-empty (the sidecar drops empty/non-string entries regardless). Unit-tested.
    var jsonObject: [String: Any] {
        var d: [String: Any] = ["action": action.rawValue]
        if let template, !template.isEmpty { d["template"] = template }
        if let run, !run.isEmpty { d["run"] = run }
        if let params, !params.isEmpty { d["params"] = params }
        if let maxItems, !maxItems.isEmpty { d["maxItems"] = maxItems }
        if let concurrency, !concurrency.isEmpty { d["concurrency"] = concurrency }
        return d
    }
}

extension Notification.Name {
    /// (ramon fork / Agent Queue, §8a) Posted on MAIN by a local control surface
    /// (command palette / dashboard run-control buttons / a keybind action) to
    /// ENQUEUE a `QueueCommand` onto the MCP server's in-memory FIFO. `MCPServer`
    /// observes this (only while started) and hops the enqueue onto its serial
    /// queue so it is race-free against the drain.
    /// userInfo: [QueueCommandUserInfoKey.command: QueueCommand]
    static let ghosttyQueueCommand =
        Notification.Name("com.mitchellh.ghostty.ghosttyQueueCommand")
}

/// userInfo key for `.ghosttyQueueCommand`.
enum QueueCommandUserInfoKey {
    static let command = "command"  // QueueCommand
}

// MARK: - Queue HEALTH (§11) — sidecar → GUI run-level status push

/// (ramon fork / Agent Queue, §11 health) The run-level health snapshot the sidecar
/// supervisor PUSHES each sweep via the `report_queue_status` MCP tool, so the Agent
/// Dashboard can show — even BEFORE any split spawns — that a queue is present and what
/// it's about to do. Mirrors the TS `QueueStatusReport` (macos/agent-manager/src/queue/
/// status.ts). PURE value type, safe across the main hop.
struct QueueStatus: Equatable, Sendable {
    /// One item reference for the header dropdowns: key + optional title + the
    /// Linear/tracker URL (so a click can link out). `Identifiable` for SwiftUI lists.
    struct Item: Equatable, Sendable, Identifiable {
        let key: String
        let title: String?
        let url: String?
        var id: String { key }
    }

    /// The run NAME (= dashboard origin) this status is for.
    let queueName: String
    /// false ⇒ the run was removed (drained/aborted/quit) — the dashboard clears it.
    let present: Bool
    /// Coarse lifecycle phase for the header chip.
    let phase: String       // "starting"|"running"|"paused"|"draining"|"disabled"
    /// Count of actionable items waiting (not currently active) — the backlog.
    let queued: Int
    /// Whether the last `list` fetch succeeded (false ⇒ "starting"/provider error).
    let listOk: Bool
    /// Agents currently running (slot-occupying assignments).
    let active: Int
    /// Lifetime dispatches so far.
    let dispatched: Int
    /// Effective lifetime cap, or nil for unlimited.
    let maxItems: Int?
    /// Effective max SIMULTANEOUS agents (the live `set_concurrency` edit if set, else the
    /// template `concurrency`). 0 when unknown (legacy/missing). The header shows it +
    /// lets the user tap-to-edit it.
    let concurrency: Int
    /// Up to ~25 of the next actionable WAITING items (the "N waiting" dropdown). May be
    /// shorter than `queued` (capped) — the view shows "… and N more" then.
    let next: [Item]
    /// The currently-RUNNING items (one per slot-occupying agent) — the "M running"
    /// dropdown. `running.count == active`.
    let running: [Item]

    // MARK: - Optimistic edits (instant dashboard feedback before the sidecar confirms)

    /// A copy with `maxItems` replaced (nil = unlimited). Used to reflect a cap edit
    /// IMMEDIATELY in the header; the sidecar's next authoritative push reconciles it.
    func withMaxItems(_ newMax: Int?) -> QueueStatus {
        QueueStatus(
            queueName: queueName, present: present, phase: phase, queued: queued,
            listOk: listOk, active: active, dispatched: dispatched, maxItems: newMax,
            concurrency: concurrency, next: next, running: running)
    }

    /// A copy with `phase` replaced — optimistic pause/resume/stop feedback.
    func withPhase(_ newPhase: String) -> QueueStatus {
        QueueStatus(
            queueName: queueName, present: present, phase: newPhase, queued: queued,
            listOk: listOk, active: active, dispatched: dispatched, maxItems: maxItems,
            concurrency: concurrency, next: next, running: running)
    }

    /// A copy with `concurrency` replaced — optimistic parallel-edit feedback (the
    /// sidecar's next authoritative push reconciles it).
    func withConcurrency(_ newConcurrency: Int) -> QueueStatus {
        QueueStatus(
            queueName: queueName, present: present, phase: phase, queued: queued,
            listOk: listOk, active: active, dispatched: dispatched, maxItems: maxItems,
            concurrency: newConcurrency, next: next, running: running)
    }

    /// (pure, testable) Parse the concurrency-editor's raw string the SAME way the sidecar's
    /// `parseConcurrencyValue` does, for the optimistic update: a positive integer, else nil
    /// (blank / garbage / zero / negative — leave unchanged, the sidecar ignores it too).
    static func parseConcurrencyOptimistic(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = Int(s), n > 0 { return n }
        return nil
    }

    /// (pure, testable) Parse the cap-editor's raw string the SAME way the sidecar's
    /// `parseMaxItemsValue` does, for the optimistic update. Returns a DOUBLE optional so
    /// "leave unchanged" is distinct from "set to unlimited":
    ///   `.none`            → blank / garbage → caller should NOT optimistically change
    ///   `.some(nil)`       → unlimited (`0`/`unlimited`/`none`/`inf`/`∞`) → set maxItems = nil
    ///   `.some(.some(n))`  → a positive-integer cap
    static func parseCapOptimistic(_ raw: String) -> Int?? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.isEmpty { return .none }
        if ["0", "unlimited", "none", "inf", "infinity", "∞"].contains(s) { return .some(nil) }
        if let n = Int(s), n > 0 { return .some(n) }
        return .none
    }
}

/// PURE, unit-tested parser of the `report_queue_status` tool arguments → `QueueStatus`.
/// `queueName` is REQUIRED (non-empty); everything else defaults sanely so a partial
/// payload still yields a usable status. `maxItems` is a number or null/absent (unlimited).
struct QueueStatusPayload {
    let status: QueueStatus

    static func fromArguments(_ arguments: [String: Any]) -> QueueStatusPayload? {
        guard let queueName = (arguments["queueName"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !queueName.isEmpty
        else { return nil }

        func int(_ key: String) -> Int { (arguments[key] as? NSNumber)?.intValue ?? 0 }
        let present = (arguments["present"] as? Bool) ?? true
        let phase = (arguments["phase"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "running"
        let listOk = (arguments["listOk"] as? Bool) ?? false
        // maxItems: a number = cap; null/absent = unlimited (nil).
        let maxItems = (arguments["maxItems"] as? NSNumber)?.intValue

        // Parse an array of {key, title?, url?} item refs (used for both next + running);
        // each needs a non-empty key, title/url kept only when non-empty.
        func items(_ k: String) -> [QueueStatus.Item] {
            guard let raw = arguments[k] as? [[String: Any]] else { return [] }
            var out: [QueueStatus.Item] = []
            for entry in raw {
                guard let key = (entry["key"] as? String), !key.isEmpty else { continue }
                let title = (entry["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let url = (entry["url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                out.append(QueueStatus.Item(key: key, title: title, url: url))
            }
            return out
        }

        return QueueStatusPayload(status: QueueStatus(
            queueName: queueName, present: present, phase: phase,
            queued: int("queued"), listOk: listOk, active: int("active"),
            dispatched: int("dispatched"), maxItems: maxItems,
            concurrency: int("concurrency"),
            next: items("next"), running: items("running")))
    }
}

extension Notification.Name {
    /// (ramon fork / Agent Queue, §11) Posted on MAIN by `MCPServer.applyQueueStatus`
    /// when the sidecar reports a run's health. `AgentDashboardController` observes it
    /// (stores the status per run; drops it when `present == false`).
    /// userInfo: [QueueCommandUserInfoKey.status: QueueStatus]
    static let ghosttyQueueStatusDidChange =
        Notification.Name("com.mitchellh.ghostty.ghosttyQueueStatusDidChange")
}

extension QueueCommandUserInfoKey {
    static let status = "status"  // QueueStatus
}

extension MCPServer {
    /// Handle a `report_queue_status` tool call: post `.ghosttyQueueStatusDidChange` on
    /// MAIN so the dashboard can store/render the run-level health. Run-level (no surface
    /// to resolve), so unlike `applyAnnotation` it never fails — always returns true.
    func applyQueueStatus(_ status: QueueStatus) -> Bool {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .ghosttyQueueStatusDidChange, object: nil,
                userInfo: [QueueCommandUserInfoKey.status: status])
        }
        return true
    }
}

// MARK: - Backlog GRAPH — sidecar → GUI whole-board push (the "N backlog" button + canvas)

/// (ramon fork / Agent Queue, backlog graph) The run's WHOLE-board snapshot the sidecar
/// pushes (throttled to `intervals.listMs`) via the `report_queue_graph` MCP tool, for the
/// dashboard's "N backlog" header button + the dependency-graph canvas. Mirrors the TS
/// `QueueGraphReport` (macos/agent-manager/src/queue/status.ts). PURE value type, safe
/// across the main hop. Only present when the template declares the optional `provider.graph`.
struct QueueGraph: Equatable, Sendable {
    /// One node of the board — the FULL set of items in the run's scope (every state).
    /// `Identifiable` (by key) for the SwiftUI canvas.
    struct Node: Equatable, Sendable, Identifiable {
        let key: String
        let title: String?
        let url: String?
        /// Display workflow-state name, e.g. "In Progress".
        let state: String?
        /// Coarse category for the node COLOR (e.g. "started"/"completed"); nil → neutral.
        let stateType: String?
        /// Provider-declared TERMINAL flag — excluded from `backlog`, dimmed in the canvas.
        let done: Bool
        /// Free-form labels (e.g. "Design needed").
        let labels: [String]
        /// Keys that BLOCK this node — the DAG edges (may reference keys outside the set).
        let blockedBy: [String]
        /// GENERIC priority MARK (e.g. "Urgent", "High") the canvas renders as a prominent
        /// badge + tinted border. Provider-decided (like `done`/`stateType`); nil → no mark.
        let priorityLabel: String?
        var id: String { key }
    }

    /// The run NAME (= dashboard origin) this board is for.
    let queueName: String
    /// false ⇒ the run was removed — the dashboard clears the backlog button + canvas.
    let present: Bool
    /// The header-badge count: non-terminal nodes NOT currently waiting/running.
    let backlog: Int
    /// The full scoped board (every state) for the canvas.
    let nodes: [Node]
}

/// PURE, unit-tested parser of the `report_queue_graph` tool arguments → `QueueGraph`.
/// `queueName` is REQUIRED (non-empty); `present`/`backlog`/`nodes` default sanely. A node
/// needs a non-empty `key`; `done` defaults false; `labels`/`blockedBy` default []. Nodes
/// without a usable key are dropped (mirrors the sidecar's `parseGraphOutput`).
struct QueueGraphPayload {
    let graph: QueueGraph

    static func fromArguments(_ arguments: [String: Any]) -> QueueGraphPayload? {
        guard let queueName = (arguments["queueName"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !queueName.isEmpty
        else { return nil }

        let present = (arguments["present"] as? Bool) ?? true
        let backlog = (arguments["backlog"] as? NSNumber)?.intValue ?? 0

        var nodes: [QueueGraph.Node] = []
        if let raw = arguments["nodes"] as? [[String: Any]] {
            for entry in raw {
                guard let key = (entry["key"] as? String), !key.isEmpty else { continue }
                let strings: (String) -> [String] = { k in
                    (entry[k] as? [Any])?.compactMap { $0 as? String } ?? []
                }
                let opt: (String) -> String? = { k in
                    (entry[k] as? String).flatMap { $0.isEmpty ? nil : $0 }
                }
                nodes.append(QueueGraph.Node(
                    key: key, title: opt("title"), url: opt("url"),
                    state: opt("state"), stateType: opt("stateType"),
                    done: (entry["done"] as? Bool) ?? false,
                    labels: strings("labels"), blockedBy: strings("blockedBy"),
                    priorityLabel: opt("priorityLabel")))
            }
        }

        return QueueGraphPayload(graph: QueueGraph(
            queueName: queueName, present: present, backlog: backlog, nodes: nodes))
    }
}

extension Notification.Name {
    /// (ramon fork / Agent Queue, backlog graph) Posted on MAIN by `MCPServer.applyQueueGraph`
    /// when the sidecar pushes a run's whole-board snapshot. `AgentDashboardController`
    /// observes it (stores the graph per run; drops it when `present == false`).
    /// userInfo: [QueueCommandUserInfoKey.graph: QueueGraph]
    static let ghosttyQueueGraphDidChange =
        Notification.Name("com.mitchellh.ghostty.ghosttyQueueGraphDidChange")
}

extension QueueCommandUserInfoKey {
    static let graph = "graph"  // QueueGraph
}

extension MCPServer {
    /// Handle a `report_queue_graph` tool call: post `.ghosttyQueueGraphDidChange` on MAIN so
    /// the dashboard can store/render the backlog board. Run-level (no surface to resolve), so
    /// it never fails — always returns true.
    func applyQueueGraph(_ graph: QueueGraph) -> Bool {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .ghosttyQueueGraphDidChange, object: nil,
                userInfo: [QueueCommandUserInfoKey.graph: graph])
        }
        return true
    }
}

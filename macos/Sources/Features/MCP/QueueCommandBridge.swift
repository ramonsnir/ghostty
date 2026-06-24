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
    }

    let action: Action
    /// The template basename to start (start only).
    let template: String?
    /// The active run name to pause/resume/stop/abort/setMaxItems.
    let run: String?
    /// (§8b) START-TIME parameter answers (param name → value) collected by the
    /// queue palette's prompt, passed through to the sidecar factory (start only).
    /// nil/empty when the template declares no params.
    let params: [String: String]?
    /// (live maxItems edit) The new lifetime-cap VALUE for `setMaxItems` — the raw
    /// string the dashboard cap control collected ("10", "unlimited"/"0"/…). The
    /// sidecar parses it (blank/garbage = ignored). nil for other actions.
    let maxItems: String?

    init(
        action: Action,
        template: String? = nil,
        run: String? = nil,
        params: [String: String]? = nil,
        maxItems: String? = nil
    ) {
        self.action = action
        self.template = template
        self.run = run
        self.params = params
        self.maxItems = maxItems
    }

    /// PURE: the wire dict drained by `take_queue_commands`. `action` is always
    /// present; `template`/`run`/`maxItems` are emitted only when non-nil and
    /// non-empty (mirrors the sidecar's tolerant `coerceQueueCommands`, which only
    /// keeps non-empty strings); `params` is emitted only when non-nil AND non-empty
    /// (the sidecar drops empty/non-string entries regardless). Unit-tested.
    var jsonObject: [String: Any] {
        var d: [String: Any] = ["action": action.rawValue]
        if let template, !template.isEmpty { d["template"] = template }
        if let run, !run.isEmpty { d["run"] = run }
        if let params, !params.isEmpty { d["params"] = params }
        if let maxItems, !maxItems.isEmpty { d["maxItems"] = maxItems }
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
    /// Up to ~25 of the next actionable WAITING items (the "N waiting" dropdown). May be
    /// shorter than `queued` (capped) — the view shows "… and N more" then.
    let next: [Item]
    /// The currently-RUNNING items (one per slot-occupying agent) — the "M running"
    /// dropdown. `running.count == active`.
    let running: [Item]
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

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
/// (= `template.name`, the dashboard origin) for pause/resume/stop/abort. Unused
/// fields are nil (omitted from the wire JSON).
struct QueueCommand: Equatable, Sendable {
    /// The five recognized actions. A raw-value enum so it round-trips to the
    /// lowercase strings the sidecar's `coerceQueueCommands` whitelists.
    enum Action: String, Equatable, Sendable {
        case start, stop, abort, pause, resume
    }

    let action: Action
    /// The template basename to start (start only).
    let template: String?
    /// The active run name to pause/resume/stop/abort.
    let run: String?
    /// (§8b) START-TIME parameter answers (param name → value) collected by the
    /// queue palette's prompt, passed through to the sidecar factory (start only).
    /// nil/empty when the template declares no params.
    let params: [String: String]?

    init(
        action: Action,
        template: String? = nil,
        run: String? = nil,
        params: [String: String]? = nil
    ) {
        self.action = action
        self.template = template
        self.run = run
        self.params = params
    }

    /// PURE: the wire dict drained by `take_queue_commands`. `action` is always
    /// present; `template`/`run` are emitted only when non-nil (mirrors the
    /// sidecar's tolerant `coerceQueueCommands`, which only keeps non-empty
    /// strings); `params` is emitted only when non-nil AND non-empty (the sidecar
    /// drops empty/non-string entries regardless). Unit-tested.
    var jsonObject: [String: Any] {
        var d: [String: Any] = ["action": action.rawValue]
        if let template, !template.isEmpty { d["template"] = template }
        if let run, !run.isEmpty { d["run"] = run }
        if let params, !params.isEmpty { d["params"] = params }
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

// (ramon fork / Agent Queue Supervisor, §8a) The GUI→sidecar command channel
// SERVER side: the `.ghosttyQueueCommand` observer that enqueues onto the FIFO,
// and the `take_queue_commands` drain. The FIFO storage itself lives on `MCPServer`
// (`queueCommandFIFO`) because stored properties can't be added in an extension;
// the observer token (`queueCommandObserver`) likewise. Everything that TOUCHES the
// FIFO does so on the server's serial `queue` so the enqueue (from a main-thread
// notification) and the drain (from a `tools/call` handler) never race.

import Foundation
import AppKit
import GhosttyKit
import os

extension MCPServer {
    // MARK: - Observer lifecycle (main add/remove)

    /// Register the `.ghosttyQueueCommand` observer. Called from `start()` (on
    /// the serial queue), but the NotificationCenter add hops to main (observers
    /// fire on the queue they're registered with; we want main delivery, then a
    /// hop to `queue` for the actual enqueue). Idempotent-safe: a prior token is
    /// removed first.
    func startQueueCommandObserver() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let prior = self.queueCommandObserver {
                NotificationCenter.default.removeObserver(prior)
            }
            self.queueCommandObserver = NotificationCenter.default.addObserver(
                forName: .ghosttyQueueCommand, object: nil, queue: .main
            ) { [weak self] note in
                guard let self,
                      let cmd = note.userInfo?[QueueCommandUserInfoKey.command] as? QueueCommand
                else { return }
                self.enqueueQueueCommand(cmd)
            }
        }
    }

    /// Remove the `.ghosttyQueueCommand` observer (on main).
    func stopQueueCommandObserver() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let obs = self.queueCommandObserver else { return }
            NotificationCenter.default.removeObserver(obs)
            self.queueCommandObserver = nil
        }
    }

    // MARK: - Enqueue (hop to the serial queue)

    /// Enqueue a control command onto the FIFO. Hops onto the server serial
    /// `queue` so the append is race-free against `drainQueueCommands` (both run on
    /// `queue`). The notification is posted from main; this is the ONLY enqueue path.
    func enqueueQueueCommand(_ cmd: QueueCommand) {
        queue.async { [weak self] in
            guard let self else { return }
            self.queueCommandFIFO.append(cmd)
            // (Agent Queue latency) Wake the sidecar's queue-reactive long-poll so this
            // command is drained ~immediately instead of waiting out the in-flight sweep +
            // the sidecar's 5s timer gap. Fired AFTER the append (same serial queue) so the
            // woken drain always sees this command. No-op if no waiter is parked — the timer
            // sweep + the event ring are the fallbacks.
            self.bus.recordQueueCommand()
        }
    }

    // MARK: - Drain (serial queue — called from a tools/call handler)

    /// Drain + clear the FIFO, returning the buffered commands in FIFO order. MUST
    /// be called on the server serial `queue` (the `take_queue_commands` dispatch
    /// runs there). PURE-ish: reads + clears the stored FIFO, no AppKit / socket.
    func drainQueueCommands() -> [QueueCommand] {
        let drained = queueCommandFIFO
        queueCommandFIFO.removeAll()
        return drained
    }

    // MARK: - signal_attention (§8.3/§6)

    /// (Agent Queue, §8.3) Ring the bell for a surface, reusing Ghostty's normal
    /// `.ghosttyBellDidRing` pipeline so the dashboard bell aggregate, the web
    /// monitor, AND a push all fire (used by onAgentExit=leave-and-bell so a crashed
    /// agent surfaces itself for human review). Resolves the SurfaceView on MAIN and
    /// posts the SAME notification shape `Ghostty.App`'s bell callback uses (`object:
    /// surfaceView`, no userInfo) — every bell observer keys on `note.object as?
    /// SurfaceView`. The post happens INSIDE the main hop (the SurfaceView is never
    /// returned across the hop), honoring the value-types-only rule. Returns false
    /// when the uuid does not resolve (the tool reports an unknown id). `reason` is
    /// logged only.
    func signalAttention(uuid: UUID, reason: String?) -> Bool {
        return DispatchQueue.main.sync {
            guard let view = MCPLayout.surface(forUUID: uuid) else { return false }
            if let reason, !reason.isEmpty {
                Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
                       category: "mcp")
                    .debug("mcp: signal_attention for \(uuid.uuidString, privacy: .public): \(reason, privacy: .public)")
            }
            // Post on main with the ringing surfaceView as `object` (the bell
            // observers — AppDelegate, SurfaceView_AppKit, WebMonitorPush, MCPEventBus
            // — all read `note.object as? Ghostty.SurfaceView`). No userInfo, matching
            // the real bell post in Ghostty.App.
            NotificationCenter.default.post(name: .ghosttyBellDidRing, object: view)
            return true
        }
    }

    /// PURE: shape a drained command list into the `take_queue_commands` result
    /// envelope (`{"commands":[ {action, template?, run?}, … ]}`). Unit-tested. The
    /// sidecar's `coerceQueueCommands` tolerates extra keys + drops bad entries, so
    /// this stays minimal — only the recognized fields, emitted per `jsonObject`.
    static func queueCommandsJSONData(_ cmds: [QueueCommand]) -> [String: Any] {
        return ["commands": cmds.map { $0.jsonObject }]
    }
}

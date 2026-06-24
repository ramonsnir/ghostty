// (ramon fork) MCP tool registry: the `tools/list` schema set and the
// `tools/call` dispatch table. Dispatch maps a tool name + arguments onto a
// `ToolOutcome`; the JSON-RPC layer (MCPRPC) shapes that into a response. Pure
// argument validation happens here (before any main hop) so a bad call fails
// fast and testably; effects hop to main inside `DispatchQueue.main.sync`.

import Foundation
import AppKit

enum MCPTools {
    enum ToolOutcome {
        case ok([String: Any])              // -> result.content[text=JSON], isError:false
        case toolError(String)              // -> result.content[text=msg], isError:true
        case methodNotFound                 // -> JSON-RPC -32601
        case invalidParams(String)          // -> JSON-RPC -32602
        case waitForEvent(MCPEventBus.WaitSpec)     // park the connection
        case watchPattern(MCPEventBus.PatternSpec)  // park the connection
    }

    // MARK: - tools/list

    /// `{"tools":[ … ]}`. Built once.
    static let toolsListResult: [String: Any] = ["tools": toolSchemas]

    static let toolSchemas: [[String: Any]] = [
        [
            "name": "list_surfaces",
            "description": "List all live terminal surfaces (panes) with identity and layout position. Returns the stable surface id (UUID) used by every other tool. window/tab are POSITIONAL indices (encounter order), NOT stable across calls; only id is durable. NOTE on the per-row 'atPrompt' field: it is a COARSE heuristic derived from the inverse of Ghostty's close-confirmation state, NOT a true shell-prompt (OSC 133) signal, and it is gated by the 'confirm-close-surface' config: with the default ('true') it approximates 'a child is idle at a prompt'; with 'confirm-close-surface = false' atPrompt is ALWAYS true; with 'always' it is ALWAYS false. Treat it as a hint, not ground truth. Three OPTIONAL per-row fields are OMITTED when unknown: 'processName' (the foreground process, e.g. 'claude') and 'command' (its full command line, e.g. 'claude --resume') — these require the pty-host backend AND a host new enough to push them, so they are absent until the host is restarted after a GUI upgrade; and 'idleSeconds' (seconds since the surface's screen last changed) — ~0 while a TUI is repainting/working, growing while it waits for input, and a COARSE heuristic (a TUI that repaints on a timer never goes idle). Six more OPTIONAL fork fields are OMITTED when unknown, sourced from the Agent Dashboard (absent when the dashboard is disabled): 'agentState' ('working'/'waiting'/'idle'), 'lastPrompt' (last user prompt), 'lastTool' (last tool used), and 'notes' (the Agent Manager's latest annotation summary) come from Claude Code hooks; 'userNotes' is the user's per-session free-text note/goal typed into the Agent Dashboard tile (the strongest goal signal, persisted across restarts), omitted when unset; 'agentKind' ('claude'/'codex') is the dashboard's authoritative subtree-walk DETECTION of the agent running in the surface — reliable even when the foreground process is a wrapper (e.g. the claude-pool 'bash'), unlike 'processName'. One more fork field, 'suggestionDismissed' (a plain bool, ALWAYS present), is true when the user dismissed the manager's current suggestion — the Agent Manager uses it to suppress re-suggesting until the surface's change fingerprint shifts.",
            "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
        ],
        [
            "name": "read_surface",
            "description": "Read the text of a surface's VISIBLE SCREEN (the viewport). Scrollback/history is NOT exposed: under this fork's pty-host backend the GUI holds only a viewport-sized mirror (the real scrollback lives on the host), so there is no honest full-history read — only the current screen. The text comes from a short-lived (~500ms) cache, so a read issued immediately after send_text may not yet reflect the just-sent input — re-read after a brief delay if you need the freshest output. To see output that has scrolled off, use the `scroll` tool to bring it into the viewport, then read again.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Surface UUID from list_surfaces."],
                ],
                "required": ["id"],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "get_layout",
            "description": "Return the window -> tab -> split-tree layout of all terminal windows. window/tab ids are POSITIONAL (encounter order), not stable across calls; surface leaves carry their durable id.",
            "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
        ],
        [
            "name": "send_text",
            "description": "Type text into a surface as real key events (NOT a paste). submit:true appends a Return to submit. Does not focus the surface.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string"],
                    "text": ["type": "string"],
                    "submit": ["type": "boolean", "default": false],
                ],
                "required": ["id", "text"],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "send_key",
            "description": "Send a single named key (real keypress) to a surface. Useful to approve CLI-agent prompts (enter/y/n), interrupt (ctrl-c), clear a line (ctrl-u), or navigate.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string"],
                    "key": [
                        "type": "string",
                        "enum": ["enter", "escape", "tab", "backspace", "up", "down", "left", "right", "y", "n", "space", "ctrl-c", "ctrl-u"],
                    ],
                ],
                "required": ["id", "key"],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "scroll",
            "description": "Scroll a surface by signed wheel ticks. Positive dy scrolls back (up) toward older output; negative scrolls forward (down). Clamped to [-30, 30].",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string"],
                    "dy": ["type": "number"],
                ],
                "required": ["id", "dy"],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "wait_for_event",
            "description": "Block until a matching surface event fires or the timeout elapses. Events: 'bell' (terminal bell), 'exited' (child process exited), 'prompt' (COARSE heuristic). The 'prompt' event is derived from a false->true transition of Ghostty's close-confirmation state (NOT a true OSC 133 shell-prompt signal) and is gated by the 'confirm-close-surface' config: with the default ('true') it fires roughly when a child goes idle at a prompt; with 'confirm-close-surface = false' the 'prompt' event NEVER fires; with 'always' it fires for essentially every surface. Prefer 'bell'/'exited' (precise) and use 'prompt' only as a hint. Returns the event or null on timeout. timeoutMs is clamped to [1000, 120000].",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "filter": [
                        "type": "object",
                        "properties": [
                            "ids": ["type": "array", "items": ["type": "string"]],
                            "types": ["type": "array", "items": ["type": "string", "enum": ["bell", "exited", "prompt"]]],
                        ],
                        "additionalProperties": false,
                    ],
                    "timeoutMs": ["type": "number", "default": 30000, "minimum": 1000, "maximum": 120000, "description": "Milliseconds to wait. Clamped to [1000, 120000]."],
                ],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "watch_for_pattern",
            "description": "Poll a surface's text for a regular expression until it matches or the timeout elapses. Heuristic fallback for TUI agents that do not emit shell-prompt events.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string"],
                    "regex": ["type": "string"],
                    "timeoutMs": ["type": "number", "default": 30000, "minimum": 1000, "maximum": 120000, "description": "Milliseconds to wait. Clamped to [1000, 120000]."],
                ],
                "required": ["id", "regex"],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "focus_surface",
            "description": "Focus a surface: raise its window, select its tab, move keyboard focus to the pane.",
            "inputSchema": [
                "type": "object",
                "properties": ["id": ["type": "string"]],
                "required": ["id"],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "new_tab",
            "description": "Open a new terminal tab. Optional cwd sets the working directory (no '~' expansion — use an absolute path). Optional command runs as the new tab's first input in an interactive shell (it does NOT replace the shell). If a source surface id is given the tab inherits that surface's context and is created next to it; otherwise it opens from app defaults in the frontmost terminal window, or a brand-new window if none is open.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "cwd": ["type": "string"],
                    "command": ["type": "string"],
                    "id": ["type": "string", "description": "Optional source surface UUID to inherit context from."],
                ],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "close_surface",
            "description": "Request to close a surface (pane). Honors the terminal's normal close-confirmation behavior.",
            "inputSchema": [
                "type": "object",
                "properties": ["id": ["type": "string"]],
                "required": ["id"],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "perform_action",
            "description": "Run a Ghostty keybind action against a surface using the action grammar string, e.g. 'flip_split:horizontal', 'toggle_split_direction:vertical', 'swap_split:next', 'move_split_to_new_tab', 'merge_tabs:next_horizontal', 'mark_split', 'clear_split_mark', 'pull_marked_split:right', 'resize_split:down,2', 'goto_last_surface'. Relative verbs act relative to the given surface (v1 focuses it first).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string"],
                    "action": ["type": "string"],
                ],
                "required": ["id", "action"],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "set_surface_annotation",
            "description": "Write/update an annotation onto a surface's Agent Dashboard tile — the Agent Manager's DISPLAY channel. This is a PARTIAL update that MERGES into the surface's existing annotation: fields you OMIT keep their prior value, so the status summarizer can write 'summary' and the manager can write 'suggestion' INDEPENDENTLY without clobbering each other. Provide the 'id' and AT LEAST ONE of: 'summary' (one-line semantic status shown in place of the raw state chip), 'suggestion' (a proposed reply for a waiting agent, shown with Approve/Edit/Dismiss in the tile — the user can Approve, which TYPES it into the agent AND submits it in one user-initiated tap, or Edit, or Dismiss; the model never sends input on its own — only a human Approve tap submits), 'phase' (a coarse phase label), 'needsUser' (attention flag), 'confidence' (0..1). This annotation call itself NEVER sends input to the agent (it only writes display state).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Surface UUID from list_surfaces."],
                    "summary": ["type": "string", "description": "One-line semantic status to display."],
                    "suggestion": ["type": "string", "description": "A proposed reply for a waiting agent (shown with Approve/Edit/Dismiss; the user's Approve tap types AND submits it — never auto-sent by the model)."],
                    "phase": ["type": "string"],
                    "needsUser": ["type": "boolean"],
                    "confidence": ["type": "number"],
                    // (Agent Queue, §8.5) origin-tagging fields the supervisor writes
                    // through this same merge tool, so a strict MCP-client validator
                    // honoring additionalProperties:false doesn't reject the call.
                    "queueKey": ["type": "string", "description": "Agent Queue: the work-item key this surface is bound to."],
                    "queueName": ["type": "string", "description": "Agent Queue: the run/origin name (dashboard grouping)."],
                    "queueUrl": ["type": "string", "description": "Agent Queue: the work-item URL (clickable in the tile)."],
                ],
                "required": ["id"],
                "additionalProperties": false,
            ],
        ],
        [
            // (ramon fork / Agent Queue, §8.1)
            "name": "spawn_split_command",
            "description": "Agent Queue: spawn one agent split running a command, returning the NEW surface's stable identity {id (UUID), sessionId (the pty-host session id; 0 when there is no host session)}. With firstTab:true, opens the run's first TAB (from app defaults in cwd); otherwise SPLITS the targetUUID surface in the given direction. The command is run as the new surface's first input in an interactive shell (it does NOT replace the shell); interior newlines are collapsed so exactly one trailing submit is sent. SAFETY/GENERICITY: item context MUST be passed via the 'env' map (e.g. GHOSTTY_ITEM_KEY/TITLE/URL) — which is set on the new split's environment so the launched shell inherits it — and NEVER string-spliced into 'command' (that would be shell injection). 'command' is the template launch line passed VERBATIM. 'cwd' is NOT tilde-expanded (use an absolute path).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "targetUUID": ["type": "string", "description": "Surface UUID to split (required unless firstTab)."],
                    "direction": ["type": "string", "enum": ["right", "down", "left", "up"], "description": "Split direction (required unless firstTab)."],
                    "command": ["type": "string", "description": "The launch command, run VERBATIM as the new surface's first input."],
                    "cwd": ["type": "string", "description": "Working directory (no '~' expansion)."],
                    "firstTab": ["type": "boolean", "default": false, "description": "Open the run's first tab instead of splitting a target."],
                    "env": ["type": "object", "description": "Item-context env vars (GHOSTTY_ITEM_*) set on the launched shell. NEVER splice these into 'command'.", "additionalProperties": ["type": "string"]],
                ],
                "required": ["command"],
                "additionalProperties": false,
            ],
        ],
        [
            // (ramon fork / Agent Queue, §8.2/§10)
            "name": "force_close_surface",
            "description": "Agent Queue: close a surface WITHOUT the close-confirmation prompt. Unlike close_surface (which honors confirm-close and pops a modal for a live child), this bypasses confirmation. Intended to be called only AFTER the surface's child has exited (the supervisor first sends the template exit keys), so a done-but-still-rendering agent split actually closes instead of stalling on a modal.",
            "inputSchema": [
                "type": "object",
                "properties": ["id": ["type": "string"]],
                "required": ["id"],
                "additionalProperties": false,
            ],
        ],
        [
            // (ramon fork / Agent Queue, §8.3/§6)
            "name": "signal_attention",
            "description": "Agent Queue: ring the bell / raise attention for a surface, reusing Ghostty's normal bell pipeline so the dashboard bell aggregate, the web monitor, and a push notification all fire. Used by onAgentExit=leave-and-bell so a crashed/exited agent surfaces itself for human review. The optional 'reason' is a human-readable note (logged). Generic + reusable.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string"],
                    "reason": ["type": "string"],
                ],
                "required": ["id"],
                "additionalProperties": false,
            ],
        ],
        [
            // (ramon fork / Agent Queue, §8a)
            "name": "take_queue_commands",
            "description": "Agent Queue: DRAIN and return the GUI's in-memory FIFO of local control commands (start/stop/abort/pause/resume) enqueued by the command palette / dashboard buttons / a keybind. Returns {commands:[{action, template?, run?}, …]} and CLEARS the FIFO. The sidecar's supervisor pass calls this each sweep to learn which queues to start/pause/stop/abort. Empty when nothing is pending.",
            "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
        ],
        [
            // (ramon fork / Agent Queue, §11 health)
            "name": "report_queue_status",
            "description": "Agent Queue: PUSH a run's health snapshot to the GUI Agent Dashboard so it can show the queue's presence + backlog + what's next — even BEFORE any split spawns and even when every tile is hidden/filtered. The supervisor calls this each sweep. 'queueName' (= run/origin name) is required; 'present:false' tells the dashboard the run was removed (clear its section). 'phase' is one of starting/running/paused/draining/disabled; 'queued' is how many items are waiting (not yet dispatched), 'active' how many agents are running, 'dispatched' the lifetime count, 'maxItems' the cap (omit/null = unlimited), 'next' a few upcoming items [{key,title?}].",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "queueName": ["type": "string"],
                    "present": ["type": "boolean", "default": true],
                    "phase": ["type": "string", "enum": ["starting", "running", "paused", "draining", "disabled"]],
                    "queued": ["type": "integer"],
                    "listOk": ["type": "boolean"],
                    "active": ["type": "integer"],
                    "dispatched": ["type": "integer"],
                    "maxItems": ["type": ["integer", "null"], "description": "Lifetime cap; null/omitted = unlimited."],
                    "next": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "key": ["type": "string"],
                                "title": ["type": "string"],
                            ],
                            "required": ["key"],
                        ],
                    ],
                ],
                "required": ["queueName"],
                "additionalProperties": false,
            ],
        ],
    ]

    // MARK: - dispatch

    /// Map a tool call onto an outcome. Pure validation runs first; effects hop to
    /// main. `wait_for_event`/`watch_for_pattern` return a park outcome (resolved
    /// later by the bus).
    static func dispatch(name: String, arguments: [String: Any], server: MCPServer) -> ToolOutcome {
        switch name {
        case "list_surfaces":
            let payload: [String: Any] = DispatchQueue.main.sync {
                let rows = MCPLayout.surfaceRows()
                return ["surfaces": MCPLayout.surfacesJSONData(rows)]
            }
            return .ok(payload)

        case "read_surface":
            guard let uuid = uuidArg(arguments) else { return .invalidParams("missing or invalid id") }
            // Viewport-only: scrollback is intentionally NOT a mode. Under the
            // pty-host backend the GUI is a viewport-sized mirror, so a
            // "scrollback" read would silently return only the viewport — a lie.
            // Rather than expose a broken mode, read_surface always reads the
            // visible screen. (See MCPLayout.readText / read_surface schema.)
            let result: [String: Any]? = DispatchQueue.main.sync {
                guard let r = MCPLayout.readText(uuid: uuid) else { return nil }
                return ["text": r.text, "cols": r.cols, "rows": r.rows]
            }
            guard let result else { return .toolError("unknown surface id") }
            return .ok(result)

        case "get_layout":
            let payload: [String: Any] = DispatchQueue.main.sync {
                ["windows": MCPLayout.layoutTree()]
            }
            return .ok(payload)

        case "send_text":
            guard let uuid = uuidArg(arguments) else { return .invalidParams("missing or invalid id") }
            guard let text = arguments["text"] as? String else { return .invalidParams("missing text") }
            let submit = (arguments["submit"] as? Bool) ?? false
            let ok = DispatchQueue.main.sync { MCPInput.sendText(uuid: uuid, text: text, submit: submit) }
            return ok ? .ok(["ok": true]) : .toolError("unknown surface id")

        case "send_key":
            guard let uuid = uuidArg(arguments) else { return .invalidParams("missing or invalid id") }
            guard let key = arguments["key"] as? String else { return .invalidParams("missing key") }
            // Resolve the key mapping BEFORE any main hop so an unknown key is a
            // fast, AppKit-free tool error.
            guard MCPInput.keySpecs(forKey: key) != nil else { return .toolError("unknown key: \(key)") }
            let ok = DispatchQueue.main.sync { MCPInput.sendKey(uuid: uuid, key: key) ?? false }
            return ok ? .ok(["ok": true]) : .toolError("unknown surface id")

        case "scroll":
            guard let uuid = uuidArg(arguments) else { return .invalidParams("missing or invalid id") }
            guard let dyNum = arguments["dy"] as? NSNumber else { return .invalidParams("missing dy") }
            guard let dy = MCPInput.scrollDeltaClamped(dyNum.doubleValue) else {
                return .toolError("dy must be non-zero")
            }
            let ok = DispatchQueue.main.sync { MCPInput.scroll(uuid: uuid, dy: dy) }
            return ok ? .ok(["ok": true]) : .toolError("unknown surface id")

        case "focus_surface":
            guard let uuid = uuidArg(arguments) else { return .invalidParams("missing or invalid id") }
            let ok = DispatchQueue.main.sync { MCPLayout.focus(uuid: uuid) }
            return ok ? .ok(["ok": true]) : .toolError("unknown surface id")

        case "close_surface":
            guard let uuid = uuidArg(arguments) else { return .invalidParams("missing or invalid id") }
            let ok = DispatchQueue.main.sync { MCPLayout.close(uuid: uuid) }
            return ok ? .ok(["ok": true]) : .toolError("unknown surface id")

        case "new_tab":
            let cwd = arguments["cwd"] as? String
            let command = arguments["command"] as? String
            let sourceUUID = uuidArg(arguments)  // optional; nil = app-default tab
            let ok = DispatchQueue.main.sync { MCPLayout.newTab(cwd: cwd, command: command, sourceUUID: sourceUUID) }
            return ok ? .ok(["ok": true]) : .toolError("failed to open tab")

        case "perform_action":
            guard let uuid = uuidArg(arguments) else { return .invalidParams("missing or invalid id") }
            guard let action = arguments["action"] as? String, !action.isEmpty else {
                return .invalidParams("missing action")
            }
            let ok = DispatchQueue.main.sync { MCPLayout.performAction(uuid: uuid, action: action) }
            return ok ? .ok(["ok": true]) : .toolError("action failed or unknown surface id")

        case "wait_for_event":
            let filter = arguments["filter"] as? [String: Any]
            let ids = (filter?["ids"] as? [String]) ?? []
            let types = (filter?["types"] as? [String]) ?? []
            // Validate event types up front so a typo fails fast rather than
            // silently never matching and timing out after 30s.
            let knownTypes: Set<String> = ["bell", "exited", "prompt"]
            for t in types where !knownTypes.contains(t) {
                return .invalidParams("unknown event type: \(t)")
            }
            // Clamp into [floor, ceiling]. An unbounded value would park the
            // connection (idle-watchdog-exempt) up to the 32-conn cap = starvation;
            // the ceiling also stays below the shim's URLSession timeout so the
            // shim never reports a spurious transport error on a long wait.
            let timeoutMs = MCPEventBus.clampTimeoutMs(((arguments["timeoutMs"] as? NSNumber)?.doubleValue) ?? 30000)
            return .waitForEvent(MCPEventBus.WaitSpec(ids: Set(ids), types: Set(types), timeoutMs: timeoutMs))

        case "watch_for_pattern":
            guard let uuid = uuidArg(arguments) else { return .invalidParams("missing or invalid id") }
            guard let regex = arguments["regex"] as? String, !regex.isEmpty else {
                return .invalidParams("missing regex")
            }
            // Validate the regex BEFORE parking.
            guard (try? NSRegularExpression(pattern: regex)) != nil else {
                return .toolError("invalid regex")
            }
            let timeoutMs = MCPEventBus.clampTimeoutMs(((arguments["timeoutMs"] as? NSNumber)?.doubleValue) ?? 30000)
            return .watchPattern(MCPEventBus.PatternSpec(uuid: uuid, regex: regex, timeoutMs: timeoutMs))

        case "set_surface_annotation":
            guard let uuid = uuidArg(arguments) else { return .invalidParams("missing or invalid id") }
            // Validate the annotation body BEFORE any main hop so an empty body is
            // a fast, AppKit-free error (mirrors send_key's pre-hop keySpecs check
            // above). At least one updatable field (summary/suggestion/phase/
            // needsUser/confidence) must be present.
            guard let payload = AgentAnnotationPayload.fromArguments(arguments) else {
                return .invalidParams("empty annotation: provide at least one of summary/suggestion/phase/needsUser/confidence")
            }
            let ok = server.applyAnnotation(uuid: uuid, annotation: payload.annotation)
            return ok ? .ok(["ok": true]) : .toolError("unknown surface id")

        case "spawn_split_command":
            // command is required. targetUUID/direction are required UNLESS firstTab.
            guard let command = arguments["command"] as? String, !command.isEmpty else {
                return .invalidParams("missing command")
            }
            let firstTab = (arguments["firstTab"] as? Bool) ?? false
            let cwd = arguments["cwd"] as? String
            let direction = arguments["direction"] as? String
            // The item-context env: only string→string entries are kept (§13). A
            // non-string value is dropped rather than coerced.
            var env: [String: String] = [:]
            if let raw = arguments["env"] as? [String: Any] {
                for (k, v) in raw { if let s = v as? String { env[k] = s } }
            }
            // Validate the split target/direction up front (AppKit-free) so a bad
            // call fails fast rather than after a main hop.
            var targetUUID: UUID? = nil
            if !firstTab {
                guard let s = arguments["targetUUID"] as? String, let u = UUID(uuidString: s) else {
                    return .invalidParams("missing or invalid targetUUID (required unless firstTab)")
                }
                guard MCPLayout.newDirection(direction) != nil else {
                    return .invalidParams("missing or invalid direction (required unless firstTab)")
                }
                targetUUID = u
            }
            let result: (id: String, sessionID: UInt64)? = DispatchQueue.main.sync {
                MCPLayout.newSplitCommand(
                    targetUUID: targetUUID, direction: direction, command: command,
                    cwd: cwd, firstTab: firstTab, env: env)
            }
            guard let result else { return .toolError("failed to spawn split") }
            // Casing note: this returns "sessionId" (lowercase); list_surfaces emits
            // "sessionID" (capital, MCPLayout.swift). Each matches its TS reader in mcp.ts.
            return .ok(["id": result.id, "sessionId": NSNumber(value: result.sessionID)])

        case "force_close_surface":
            guard let uuid = uuidArg(arguments) else { return .invalidParams("missing or invalid id") }
            let ok = DispatchQueue.main.sync { MCPLayout.forceClose(uuid: uuid) }
            return ok ? .ok(["ok": true]) : .toolError("unknown surface id")

        case "signal_attention":
            guard let uuid = uuidArg(arguments) else { return .invalidParams("missing or invalid id") }
            let reason = arguments["reason"] as? String
            let ok = server.signalAttention(uuid: uuid, reason: reason)
            return ok ? .ok(["ok": true]) : .toolError("unknown surface id")

        case "report_queue_status":
            guard let payload = QueueStatusPayload.fromArguments(arguments) else {
                return .invalidParams("missing or empty queueName")
            }
            let ok = server.applyQueueStatus(payload.status)
            return ok ? .ok(["ok": true]) : .toolError("queue status not applied")

        case "take_queue_commands":
            // dispatch() ALREADY runs on the server serial `queue` (handleRPC is a
            // route handler on `queue`), which is the SAME queue the FIFO is mutated
            // on (enqueue hops there) — so draining directly here is race-free WITHOUT
            // a nested `queue.sync` (which would DEADLOCK on this serial queue).
            let drained = server.drainQueueCommands()
            return .ok(MCPServer.queueCommandsJSONData(drained))

        default:
            return .methodNotFound
        }
    }

    /// Parse the `id` argument as a UUID. nil if missing or malformed.
    static func uuidArg(_ arguments: [String: Any]) -> UUID? {
        guard let s = arguments["id"] as? String else { return nil }
        return UUID(uuidString: s)
    }
}

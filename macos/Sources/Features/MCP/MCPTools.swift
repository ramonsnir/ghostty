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
            "description": "List all live terminal surfaces (panes) with identity and layout position. Returns the stable surface id (UUID) used by every other tool. window/tab are POSITIONAL indices (encounter order), NOT stable across calls; only id is durable. NOTE on the per-row 'atPrompt' field: it is a COARSE heuristic derived from the inverse of Ghostty's close-confirmation state, NOT a true shell-prompt (OSC 133) signal, and it is gated by the 'confirm-close-surface' config: with the default ('true') it approximates 'a child is idle at a prompt'; with 'confirm-close-surface = false' atPrompt is ALWAYS true; with 'always' it is ALWAYS false. Treat it as a hint, not ground truth.",
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

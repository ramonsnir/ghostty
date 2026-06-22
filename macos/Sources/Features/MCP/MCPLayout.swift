// (ramon fork) MCP layout/read/control verbs against TerminalController /
// SplitTree / the libghostty C API. Every AppKit/surface-touching func MUST be
// called on the main thread (the dispatch hops there via DispatchQueue.main.sync)
// and returns ONLY value types across the hop — never a SurfaceView /
// ghostty_surface_t. The pure JSON-shaping helpers are `static internal` so they
// are unit-testable without AppKit.

import Foundation
import AppKit
import GhosttyKit

enum MCPLayout {
    // MARK: - UUID resolution (main)

    /// Find the surface view for a UUID. MUST be called on main.
    static func surface(forUUID uuid: UUID) -> Ghostty.SurfaceView? {
        return controllerAndView(forUUID: uuid)?.view
    }

    /// Find the tab controller + surface view that own a UUID. MUST be called on
    /// main. Copied from the web monitor.
    static func controllerAndView(forUUID uuid: UUID)
        -> (controller: TerminalController, view: Ghostty.SurfaceView)? {
        for c in TerminalController.all {
            for view in c.surfaceTree where view.id == uuid {
                return (c, view)
            }
        }
        return nil
    }

    /// If `view` is hidden under a zoom to a DIFFERENT split, un-zoom the tab so
    /// the surface re-mounts and is re-sized. MUST be called on main. Copied from
    /// the web monitor.
    static func revealIfZoomedAway(_ controller: TerminalController, _ view: Ghostty.SurfaceView) {
        let tree = controller.surfaceTree
        guard tree.zoomed != nil else { return }
        if tree.zoomedLeaves().contains(where: { $0.id == view.id }) { return }
        controller.surfaceTree = .init(root: tree.root, zoomed: nil)
    }

    // MARK: - list_surfaces

    /// One surface enriched with its window/tab/split position. PURE value type.
    /// `window`/`tab` are POSITIONAL (encounter-order) indices, NOT stable across
    /// calls — only `id` is durable.
    struct SurfaceRow {
        let id: String
        let title: String
        let pwd: String
        let window: Int
        let tab: Int
        let tabTitle: String
        let splitIndex: Int
        let splitCount: Int
        let focused: Bool
        let bell: Bool
        let exited: Bool
        /// COARSE heuristic = inverse of `needsConfirmQuit`, NOT a true OSC 133
        /// shell-prompt signal. The plan accepts this as the documented fallback
        /// (a real `at_prompt` bit would need a host/GUI wiring out of scope here).
        /// It is gated by `confirm-close-surface`: default `true` ⇒ approximates
        /// "idle at a prompt"; `false` ⇒ ALWAYS true; `always` ⇒ ALWAYS false.
        /// Additionally forced `false` when the child has exited (so exited and
        /// atPrompt are never both true). The tool schemas disclose this.
        let atPrompt: Bool
        /// fork: the focused FOREGROUND process name (e.g. "claude"), or nil if
        /// unknown. Requires the pty-host `.client` backend AND a host new enough
        /// to push it (protocol minor 3) — nil under `.exec` without a resolvable
        /// pid, or after a GUI upgrade before the host has been restarted.
        let processName: String?
        /// fork: the focused foreground COMMAND line (e.g. "claude --resume"), or
        /// nil if unknown. Same backend/host-gating semantics as `processName`.
        let command: String?
        /// fork: seconds since this surface's screen last changed; ~0 while a TUI
        /// repaints/works, growing while it waits for input; nil when unknown /
        /// unsupported backend. Coarse: a TUI that repaints on a timer never idles.
        let idleSeconds: Double?
        /// fork / Agent Manager: the hook-reported agent lifecycle state
        /// ("working"/"waiting"/"idle"), or nil if no hook has reported for this
        /// surface (or the Agent Dashboard is disabled). Sourced from the dashboard
        /// model, not the SurfaceView.
        let agentState: String?
        /// fork / Agent Manager: the last UserPromptSubmit prompt text, or nil.
        let lastPrompt: String?
        /// fork / Agent Manager: the last PreToolUse tool name, or nil.
        let lastTool: String?
        /// fork / Agent Manager: the manager's latest annotation summary for this
        /// surface, or nil if it has not annotated it (the LLM status round-trip).
        let notes: String?
        /// fork / Agent Manager Phase 2: the user's per-session NOTE (free-text
        /// goal/guidance typed into the tile), or nil if unset. Distinct from
        /// `notes` (the LLM summary): this is the strongest goal signal — persisted
        /// across a GUI restart. Omitted when nil.
        let userNotes: String?
        /// fork / Agent Manager: the DETECTED agent kind ("claude"/"codex") from the
        /// dashboard's authoritative subtree-walk detector, or nil. The summarizer
        /// keys off THIS (not `processName`, which is `bash` under the claude-pool
        /// wrapper) to decide a surface is an agent worth summarizing.
        let agentKind: String?
    }

    /// MUST be called on main. Walks AppKit surfaces and returns value rows.
    static func surfaceRows() -> [SurfaceRow] {
        var rows: [SurfaceRow] = []
        // (ramon fork / Agent Manager) Per-surface hook/annotation state from the
        // dashboard model (value types only). Empty when the dashboard is disabled
        // ⇒ all four agent-* fields are omitted (honest absence). `hookSnapshot()`
        // is @MainActor (the controller is); this static func is nonisolated but is
        // ALWAYS invoked inside `DispatchQueue.main.sync` (see MCPTools.dispatch),
        // so `assumeIsolated` is sound — it satisfies the compiler without changing
        // the existing on-main calling contract.
        let hooks: [UUID: AgentDashboardModel.HookSnapshotEntry] =
            MainActor.assumeIsolated {
                (NSApp.delegate as? AppDelegate)?.agentDashboard?.hookSnapshot() ?? [:]
            }
        var groupIndex: [ObjectIdentifier: Int] = [:]
        func windowIndex(_ c: TerminalController) -> Int {
            let key: ObjectIdentifier
            if let tg = c.window?.tabGroup { key = ObjectIdentifier(tg) }
            else if let w = c.window { key = ObjectIdentifier(w) }
            else { return 0 }
            if let i = groupIndex[key] { return i }
            let i = groupIndex.count
            groupIndex[key] = i
            return i
        }
        for c in TerminalController.all {
            let win = windowIndex(c)
            let tabIdx: Int
            if let tg = c.window?.tabGroup, let w = c.window,
               let idx = tg.windows.firstIndex(of: w) {
                tabIdx = idx
            } else {
                tabIdx = 0
            }
            let tabTitle = c.window?.title ?? ""
            let leaves = Array(c.surfaceTree)
            for (splitIdx, view) in leaves.enumerated() {
                let exited = view.processExited
                // atPrompt is the inverse of needsConfirmQuit, which is `false`
                // for a surface whose child has exited (surface==nil) — that
                // would report atPrompt:true alongside exited:true, which is
                // misleading. Gate atPrompt on !exited so an exited surface is
                // never also "at a prompt".
                let atPrompt = !exited && !view.needsConfirmQuit
                let hook = hooks[view.id]
                rows.append(SurfaceRow(
                    id: view.id.uuidString, title: view.title, pwd: view.pwd ?? "",
                    window: win, tab: tabIdx, tabTitle: tabTitle,
                    splitIndex: splitIdx, splitCount: leaves.count,
                    focused: view.focused, bell: view.bell,
                    exited: exited, atPrompt: atPrompt,
                    processName: view.foregroundProcessName,
                    command: view.foregroundCommand,
                    idleSeconds: view.idleSeconds,
                    agentState: hook?.agentState,
                    lastPrompt: hook?.lastPrompt,
                    lastTool: hook?.lastTool,
                    notes: hook?.notes,
                    userNotes: hook?.userNotes,
                    agentKind: hook?.agentKind))
            }
        }
        return rows
    }

    /// PURE JSON shaping for the surfaces list (testable; no AppKit).
    static func surfacesJSONData(_ rows: [SurfaceRow]) -> [[String: Any]] {
        return rows.map {
            var d: [String: Any] = [
                "id": $0.id, "title": $0.title, "pwd": $0.pwd,
                "window": $0.window, "tab": $0.tab, "tabTitle": $0.tabTitle,
                "splitIndex": $0.splitIndex, "splitCount": $0.splitCount,
                "focused": $0.focused, "bell": $0.bell,
                "exited": $0.exited, "atPrompt": $0.atPrompt,
            ]
            // fork: omit the new fields when unknown (null) — honest absence
            // rather than empty strings / sentinel numbers.
            if let n = $0.processName { d["processName"] = n }
            if let c = $0.command { d["command"] = c }
            if let idle = $0.idleSeconds { d["idleSeconds"] = idle }
            // fork / Agent Manager: agent-* fields are omitted when unknown.
            if let s = $0.agentState { d["agentState"] = s }
            if let p = $0.lastPrompt { d["lastPrompt"] = p }
            if let t = $0.lastTool { d["lastTool"] = t }
            if let notes = $0.notes { d["notes"] = notes }
            if let un = $0.userNotes { d["userNotes"] = un }
            if let kind = $0.agentKind { d["agentKind"] = kind }
            return d
        }
    }

    // MARK: - read_surface

    /// Read a surface's VISIBLE SCREEN (viewport) text + grid size. MUST be
    /// called on main. Reuses the cached viewport reader (~500ms TTL). Returns
    /// nil if the uuid does not resolve. Scrollback is deliberately NOT read:
    /// under pty-host the GUI is a viewport-only mirror, so `cachedScreenContents`
    /// would return only the viewport anyway — read_surface advertises viewport
    /// only rather than a misleading "scrollback" mode.
    static func readText(uuid: UUID) -> (text: String, cols: Int, rows: Int)? {
        guard let view = surface(forUUID: uuid) else { return nil }
        let text = view.cachedVisibleContents.get()
        var cols = 0
        var rows = 0
        if let s = view.surface {
            let size = ghostty_surface_size(s)
            cols = Int(size.columns)
            rows = Int(size.rows)
        }
        return (text, cols, rows)
    }

    // MARK: - get_layout

    /// Serialize a split node into a nested dict. PURE (no AppKit beyond reading
    /// the already-materialized leaf views' ids). `internal` for testability.
    static func nodeJSON(_ node: SplitTree<Ghostty.SurfaceView>.Node) -> [String: Any] {
        switch node {
        case .leaf(let view):
            return ["type": "leaf", "id": view.id.uuidString, "title": view.title]
        case .split(let split):
            return [
                "type": "split",
                "direction": directionString(split.direction),
                "ratio": split.ratio,
                "left": nodeJSON(split.left),
                "right": nodeJSON(split.right),
            ]
        }
    }

    /// PURE: map a split direction to its JSON string. Extracted from `nodeJSON`
    /// so the (otherwise SurfaceView-bound) split serializer's direction mapping
    /// is unit-testable without AppKit (the enum is independent of ViewType).
    static func directionString(_ direction: SplitTree<Ghostty.SurfaceView>.Direction) -> String {
        switch direction {
        case .horizontal: return "horizontal"
        case .vertical: return "vertical"
        }
    }

    /// MUST be called on main. The window -> tab -> split-tree layout. window/tab
    /// ids are POSITIONAL (encounter order), not stable.
    static func layoutTree() -> [[String: Any]] {
        // Group controllers (tabs) by window group in encounter order.
        var groupOrder: [ObjectIdentifier] = []
        var groups: [ObjectIdentifier: [TerminalController]] = [:]
        func key(_ c: TerminalController) -> ObjectIdentifier {
            if let tg = c.window?.tabGroup { return ObjectIdentifier(tg) }
            if let w = c.window { return ObjectIdentifier(w) }
            return ObjectIdentifier(c)
        }
        for c in TerminalController.all {
            let k = key(c)
            if groups[k] == nil {
                groups[k] = []
                groupOrder.append(k)
            }
            groups[k]?.append(c)
        }

        var windows: [[String: Any]] = []
        for (winIdx, k) in groupOrder.enumerated() {
            let controllers = groups[k] ?? []
            var tabs: [[String: Any]] = []
            for (tabIdx, c) in controllers.enumerated() {
                let tree: [String: Any]
                if let root = c.surfaceTree.root {
                    tree = nodeJSON(root)
                } else {
                    tree = ["type": "empty"]
                }
                tabs.append([
                    "id": tabIdx,
                    "title": c.window?.title ?? "",
                    "tree": tree,
                ])
            }
            windows.append(["id": winIdx, "tabs": tabs])
        }
        return windows
    }

    // MARK: - control verbs (main)

    /// Focus a surface (raises window, selects tab, moves keyboard focus). MUST
    /// be called on main. Returns false if the uuid does not resolve.
    static func focus(uuid: UUID) -> Bool {
        guard let (controller, view) = controllerAndView(forUUID: uuid) else { return false }
        revealIfZoomedAway(controller, view)
        controller.focusSurface(view)
        return true
    }

    /// Request to close a surface. MUST be called on main. Returns false if the
    /// uuid does not resolve.
    static func close(uuid: UUID) -> Bool {
        guard let view = surface(forUUID: uuid), let s = view.surface else { return false }
        ghostty_surface_request_close(s)
        return true
    }

    /// Open a new tab. MUST be called on main. If `sourceUUID` resolves AND that
    /// surface is live in a `TerminalController` window, the tab inherits that
    /// surface's tab context and is created next to it. We invoke
    /// `TerminalController.newTab(from:window)` DIRECTLY (not the `ghosttyNewTab`
    /// notification) and check its non-nil return, so the success report is real:
    /// posting the notification would be fire-and-forget, and its sole observer
    /// (AppDelegate.ghosttyNewTab) silently bails if the source's window is nil or
    /// its windowController is not a TerminalController — exactly the
    /// silent-no-op-reporting-success pattern we must avoid. If there is NO
    /// resolvable/seated source, we fall through to `TerminalController.newTab`
    /// against the frontmost terminal window (or a brand-new window if none is
    /// open). `cwd` is NOT tilde-expanded (use an absolute path). `command` is
    /// appended a trailing newline and set as the tab's initial input (an
    /// interactive shell runs it; it does not replace the shell). Returns false
    /// ONLY if nothing was created.
    static func newTab(cwd: String?, command: String?, sourceUUID: UUID?) -> Bool {
        let initialInput: String? = command.map { $0.hasSuffix("\n") ? $0 : $0 + "\n" }
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return false }

        if let sourceUUID,
           let view = surface(forUUID: sourceUUID),
           let s = view.surface,
           // Mirror AppDelegate.ghosttyNewTab's guards: the source must be in a
           // real TerminalController window, else creation would silently no-op.
           let window = view.window,
           window.windowController is TerminalController {
            var config = Ghostty.SurfaceConfiguration(
                from: ghostty_surface_inherited_config(s, GHOSTTY_SURFACE_CONTEXT_TAB))
            if let cwd { config.workingDirectory = cwd }
            if let initialInput { config.initialInput = initialInput }
            let created = TerminalController.newTab(
                appDelegate.ghostty, from: window, withBaseConfig: config)
            return created != nil
        }

        // No (resolvable/seated) source. The `ghosttyNewTab` notification's only observer
        // (AppDelegate.ghosttyNewTab) drops a nil object, so posting it here would
        // create nothing while reporting success. Instead reach a real entry point
        // directly: TerminalController.newTab(from: nil) falls through to
        // newWindow(...), opening a tab in the frontmost terminal window or a new
        // window if none exists.
        var config: Ghostty.SurfaceConfiguration? = nil
        if cwd != nil || initialInput != nil {
            var c = Ghostty.SurfaceConfiguration()
            c.workingDirectory = cwd
            c.initialInput = initialInput
            config = c
        }
        // Anchor on the frontmost terminal window if there is one so the tab joins
        // it; nil parent opens a new window.
        let parent = TerminalController.all.first?.window
        let created = TerminalController.newTab(
            appDelegate.ghostty, from: parent, withBaseConfig: config)
        return created != nil
    }

    /// Run a keybind-action grammar string against a surface. v1 = focus-then-act
    /// so relative verbs (swap_split:next, pull_marked_split, merge_tabs) act
    /// relative to the now-focused pane. MUST be called on main. Returns false on
    /// an unresolved uuid or an unknown/failed action.
    static func performAction(uuid: UUID, action: String) -> Bool {
        guard let (controller, view) = controllerAndView(forUUID: uuid),
              let s = view.surface else { return false }
        revealIfZoomedAway(controller, view)
        controller.focusSurface(view)
        // Mirrors Ghostty.Surface.perform(action:) (which is @MainActor and so not
        // callable from this nonisolated DispatchQueue.main.sync closure); the C
        // call is identical and matches the surrounding MCP code's direct-C style.
        let len = action.utf8CString.count
        guard len > 1 else { return false }  // count includes the NUL terminator
        return action.withCString { cString in
            ghostty_surface_binding_action(s, cString, UInt(len - 1))
        }
    }
}

import Cocoa

/// (ramon fork / Agent Dashboard, tab mode) Marker for a window that is a member
/// of a terminal tab group but is NOT a terminal (currently only the docked Agent
/// Dashboard tab). The terminal-only tab logic in `TerminalController` — numeric
/// `goto_tab:N`, the cmd-1…9 key-equivalent labeling in `relabelTabs`, and the
/// app-termination window count — skips windows marked with this so the dashboard
/// tab never masquerades as "tab N" or as a terminal that keeps the app alive.
///
/// It is a plain marker (no requirements): the concrete check is `window is
/// NonTerminalTabWindow`. Terminal windows are `TerminalWindow` and never conform.
protocol NonTerminalTabWindow: AnyObject {}

/// (ramon fork / Agent Dashboard, tab mode) The window that hosts the Agent
/// Dashboard as a native macOS **tab**, docked leftmost inside a terminal window's
/// tab group — the alternative presentation to the floating `AgentDashboardPanel`
/// (chosen by the `toggle_agent_dashboard` cycle: panel → tab → off). It hosts the
/// SAME `AgentDashboardView` SwiftUI; only the window shell differs.
///
/// It is deliberately a plain titled `NSWindow`, NOT a `TerminalWindow`: every
/// terminal-only tab path casts `window.windowController as? TerminalController`
/// (or `windowController is BaseTerminalController`) and this window has neither a
/// `TerminalController` nor a surface tree, so those paths skip it. `relabelTabs`'s
/// `tabbedWindows.compactMap { $0 as? TerminalWindow }` likewise drops it. The
/// `NonTerminalTabWindow` marker covers the two index/label paths that walk the raw
/// `tabGroup.windows` array (numeric goto + termination counting).
///
/// The `AgentDashboardController` owns and manages it directly (creating it on
/// dock, closing it on undock) and is its `delegate` — the panel is the
/// controller's `NSWindowController.window`; this is a second, controller-managed
/// window, so its own `windowController` stays nil (correct: it's not a terminal).
final class AgentDashboardTabWindow: NSWindow, NonTerminalTabWindow {
    // Must accept clicks (the tiles + the tab selection).
    override var canBecomeKey: Bool { true }

    // A docked tab CAN become main — it is a real selected tab in the group. This
    // keeps `AppDelegate.localEventKeyDown`'s `NSApp.mainWindow == nil` fast-path
    // behaving exactly as it does for a terminal tab (a terminal main window
    // suppresses the app-level key monitor), and lets standard menu key
    // equivalents resolve. The dashboard's own ⌘X/⌘C/⌘V/⌘A routing
    // (`agentDashboardOwnsKeyWindow`) still covers the SwiftUI-hosted modal fields,
    // exactly as for the panel.
    override var canBecomeMain: Bool { true }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 800),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        titlebarAppearsTransparent = false
        titleVisibility = .visible
        title = "Agent Dashboard"

        // CRITICAL: this window has NO `NSWindowController` (the controller manages
        // it directly and owns its lifetime via `tabWindow`). A controller-less
        // `NSWindow` defaults `isReleasedWhenClosed = true`, so `close()` would
        // enqueue an unbalanced autorelease on a window we still strongly reference
        // → over-release / use-after-free when that reference drops (undock, or the
        // host terminal window closing the whole tab group). The controller drops
        // `tabWindow` deterministically, so we own the release. (Same guard as the
        // sibling `QueueBacklogCanvas` window; terminal windows get it from their
        // XIBs, and `AgentDashboardPanel` gets it from `NSWindowController`.)
        isReleasedWhenClosed = false

        // AppKit's terminal-window restoration (`TerminalWindowRestoration`) only
        // knows how to rebuild a terminal surface tree; a restorable dashboard tab
        // would be mis-restored as a terminal. Instead the controller re-docks the
        // tab at launch from the persisted presentation, so mark it non-restorable.
        isRestorable = false

        // Defense-in-depth against goto_last_surface focus-history pollution: never
        // auto-promote one of the read-only mirror SurfaceViews to first responder
        // when the tab becomes key (identical guard to `AgentDashboardPanel`; the
        // primary guard is in `Ghostty.App.setNeedsFocusHistoryUpdate`).
        initialFirstResponder = nil
    }

    // ctrl+tab / ctrl+shift+tab tab-switching FROM this surface-less tab is handled
    // in `AppDelegate.localEventKeyDown` (the app-level key monitor, which runs
    // before AppKit dispatch) — a window `keyDown` override never sees Tab because
    // SwiftUI/the responder chain swallows it for focus traversal first.

    /// Never let AppKit pick a mirror `SurfaceView` subview as the initial first
    /// responder when this tab becomes key — same guard as `AgentDashboardPanel`.
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if let view = responder as? NSView,
           AgentDashboardTabWindow.containsSurfaceView(view) {
            return super.makeFirstResponder(nil)
        }
        return super.makeFirstResponder(responder)
    }

    private static func containsSurfaceView(_ view: NSView) -> Bool {
        var node: NSView? = view
        while let current = node {
            if String(describing: type(of: current)).contains("SurfaceView") {
                return true
            }
            node = current.superview
        }
        return false
    }
}

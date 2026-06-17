import Cocoa

/// (ramon fork / Agent Dashboard, Layer 3) The floating, persistent dashboard
/// panel. Modeled on `QuickTerminalWindow` but, unlike the quick terminal, it
/// STAYS visible when another app/window is frontmost ("locked to foreground")
/// and joins all Spaces — it is a glanceable status surface, not a transient
/// drop-down.
final class AgentDashboardPanel: NSPanel {
    // Must accept clicks (the tiles), but must never become the app's "main"
    // window (it's an overlay; becoming main would confuse window cycling and
    // the "new window inherits from main" logic).
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 800),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        // Floating + persistent overlay configuration.
        isFloatingPanel = true
        hidesOnDeactivate = false          // stay visible when another app is frontmost
        level = .floating                  // above terminal windows; below modal alerts
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true

        setAccessibilitySubrole(.floatingWindow)
        identifier = .init(rawValue: "com.mitchellh.ghostty.agentDashboard")

        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        title = "Agent Dashboard"

        // Defense-in-depth against goto_last_surface focus-history pollution
        // (the primary guard is in Ghostty.App.setNeedsFocusHistoryUpdate):
        // never auto-promote one of the read-only mirror SurfaceViews to first
        // responder when the panel becomes key. The tiles are plain SwiftUI
        // buttons; they do not need the mirror to hold first responder.
        initialFirstResponder = nil
    }

    /// Never let AppKit pick a subview (e.g. a mirror SurfaceView, which
    /// `acceptsFirstResponder`) as the initial first responder when this panel
    /// becomes key. Keeping the panel itself as first responder prevents the
    /// fork's global goto_last_surface history from recording a mirror.
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if let view = responder as? NSView,
           AgentDashboardPanel.containsSurfaceView(view) {
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

    /// This is set to the frame prior to setting `contentView` as a workaround
    /// for older-macOS SwiftUI corrupting the frameRect on first host. Same hack
    /// `QuickTerminalWindow` uses.
    var initialFrame: NSRect?

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(initialFrame ?? frameRect, display: flag)
    }
}

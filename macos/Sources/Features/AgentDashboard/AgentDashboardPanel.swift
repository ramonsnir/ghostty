import Cocoa

/// (ramon fork / Agent Dashboard, Layer 3) The persistent dashboard panel.
/// Modeled on `QuickTerminalWindow` but, unlike the quick terminal, it is a
/// glanceable status surface, not a transient drop-down. By default it behaves
/// like a normal window — it does NOT float above other windows (so windows can
/// be raised in front of it) and carries a real, visible title + standard-window
/// accessibility subrole so external window managers can target it by title. It
/// still stays visible when another app is frontmost and joins all Spaces — a
/// persistent sidebar.
///
/// When `pinned` is true (the `agent-dashboard-pin` config key) the panel uses a
/// floating window level so other windows can no longer be raised in front of
/// it — a NATIVE "always-on-top" pin. This exists because the dashboard and the
/// terminals share one bundle id, so a bundle-id-keyed external pin (Rectangle
/// Pro's "pin one app to a side") cannot tell them apart and ends up managing
/// the terminals too; pinning here, in-process, sidesteps that entirely. The AX
/// subrole stays `.standardWindow` regardless (a floating subrole is filtered
/// out by most window managers) — only the window LEVEL changes.
final class AgentDashboardPanel: NSPanel {
    // Must accept clicks (the tiles), but must never become the app's "main"
    // window (it's an overlay; becoming main would confuse window cycling and
    // the "new window inherits from main" logic).
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(pinned: Bool = false) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 800),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Persistent sidebar configuration. When NOT pinned, `level = .normal`
        // (and `isFloatingPanel = false`) so other windows can be raised in
        // front of it. When pinned, `level = .floating` lifts it above normal
        // windows — the native always-on-top pin (config `agent-dashboard-pin`).
        isFloatingPanel = false
        hidesOnDeactivate = false          // stay visible when another app is frontmost
        level = pinned ? .floating : .normal
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true

        // Standard-window subrole + a visible title so external window managers
        // can target this window by title. A floating-window subrole is filtered
        // out by most window managers, so we keep `.standardWindow` even when
        // pinned (the pin is the window level, not the subrole).
        setAccessibilitySubrole(.standardWindow)
        identifier = .init(rawValue: "com.mitchellh.ghostty.agentDashboard")

        titlebarAppearsTransparent = false
        titleVisibility = .visible
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

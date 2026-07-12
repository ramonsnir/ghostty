import Testing
@testable import Ghostty

/// Unit tests for the pure decision units on `AppDelegate`.
struct AppDelegateTests {
    // MARK: - quitAlwaysKeepsWindows (issue #5)
    //
    // (ramon fork) macOS state restoration is what carries the window archive
    // (each surface's host sessionID) across a GUI quit/relaunch, which is how
    // pty-host reattach recovers a live session. The fork now forces restoration
    // on UNCONDITIONALLY (`window-save-state` is no longer consulted —
    // Ghostty.Config.windowSaveState is pinned to "always"), so NSQuitAlwaysKeeps‑
    // Windows is always true regardless of the config or the hidden system pref.

    @Test func alwaysReturnsTrue() {
        #expect(AppDelegate.quitAlwaysKeepsWindows() == true)
    }
}

import Testing
@testable import Ghostty

/// Unit tests for the pure decision units on `AppDelegate`.
struct AppDelegateTests {
    // MARK: - quitAlwaysKeepsWindows (issue #5)
    //
    // The pty-host backend's "sessions survive a GUI quit/relaunch" promise
    // relies on macOS state restoration writing the window archive (which
    // carries each surface's host sessionID). Whether macOS does so on a clean
    // quit is gated by NSQuitAlwaysKeepsWindows, which this helper resolves.

    @Test func neverAlwaysReturnsFalseRegardlessOfPtyHost() {
        // An explicit opt-out is honored even with pty-host active.
        #expect(AppDelegate.quitAlwaysKeepsWindows(windowSaveState: "never", ptyHostConfigured: true) == false)
        #expect(AppDelegate.quitAlwaysKeepsWindows(windowSaveState: "never", ptyHostConfigured: false) == false)
    }

    @Test func alwaysReturnsTrueRegardlessOfPtyHost() {
        #expect(AppDelegate.quitAlwaysKeepsWindows(windowSaveState: "always", ptyHostConfigured: true) == true)
        #expect(AppDelegate.quitAlwaysKeepsWindows(windowSaveState: "always", ptyHostConfigured: false) == true)
    }

    @Test func defaultWithPtyHostForcesRestoration() {
        // The fix: pty-host active + window-save-state=default must force
        // restoration on (true), not defer to the hidden macOS system pref.
        #expect(AppDelegate.quitAlwaysKeepsWindows(windowSaveState: "default", ptyHostConfigured: true) == true)
    }

    @Test func defaultWithoutPtyHostDefersToSystem() {
        // Without pty-host, the historical behavior is preserved: nil means
        // "remove the override, defer to the macOS system preference".
        #expect(AppDelegate.quitAlwaysKeepsWindows(windowSaveState: "default", ptyHostConfigured: false) == nil)
    }

    @Test func unknownValueBehavesLikeDefault() {
        // An unexpected/unresolved value falls into the default arm (matching
        // the AppDelegate switch's `default:`), so pty-host still forces it.
        #expect(AppDelegate.quitAlwaysKeepsWindows(windowSaveState: "", ptyHostConfigured: true) == true)
        #expect(AppDelegate.quitAlwaysKeepsWindows(windowSaveState: "", ptyHostConfigured: false) == nil)
    }
}

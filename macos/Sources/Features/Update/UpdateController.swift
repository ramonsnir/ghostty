import Sparkle
import Cocoa
import Combine

/// Standard controller for managing Sparkle updates in Ghostty.
///
/// This controller wraps SPUStandardUpdaterController to provide a simpler interface
/// for managing updates with Ghostty's custom driver and delegate. It handles
/// initialization, starting the updater, and provides the check for updates action.
class UpdateController {
    private(set) var updater: SPUUpdater
    private let userDriver: UpdateDriver
    private var installCancellable: AnyCancellable?

    var viewModel: UpdateViewModel {
        userDriver.viewModel
    }

    /// True if we're installing an update.
    var isInstalling: Bool {
        installCancellable != nil
    }

    /// Initialize a new update controller.
    init() {
        let hostBundle = Bundle.main
        self.userDriver = UpdateDriver(
            viewModel: .init(),
            hostBundle: hostBundle)
        self.updater = SPUUpdater(
            hostBundle: hostBundle,
            applicationBundle: hostBundle,
            userDriver: userDriver,
            delegate: userDriver
        )
    }

    deinit {
        installCancellable?.cancel()
    }

    /// Start the updater.
    ///
    /// This must be called before the updater can check for updates. If starting fails,
    /// the error will be shown to the user.
    func startUpdater() {
        // Fork: auto-updates are RE-ENABLED, but the appcast feed is pinned to
        // this fork's own GitHub Releases (see UpdateDelegate.feedURLString), so
        // the fork is never replaced by an official Ghostty release. Whether
        // checks actually run is still gated by SUEnableAutomaticChecks /
        // `auto-update` (see AppDelegate); on dev builds the Info.plist ships
        // SUEnableAutomaticChecks=false so nothing auto-checks until the CI
        // release build (which deletes that key) is installed.
        do {
            try updater.start()
        } catch {
            userDriver.viewModel.state = .error(.init(
                error: error,
                retry: { [weak self] in
                    self?.userDriver.viewModel.state = .idle
                    self?.startUpdater()
                },
                dismiss: { [weak self] in
                    self?.userDriver.viewModel.state = .idle
                }
            ))
        }
    }

    /// Force install the current update. As long as we're in some "update available" state this will
    /// trigger all the steps necessary to complete the update.
    func installUpdate() {
        // Must be in an installable state
        guard viewModel.state.isInstallable else { return }

        // If we're already force installing then do nothing.
        guard installCancellable == nil else { return }

        // Setup a combine listener to listen for state changes and to always
        // confirm them. If we go to a non-installable state, cancel the listener.
        // The sink runs immediately with the current state, so we don't need to
        // manually confirm the first state.
        installCancellable = viewModel.$state.sink { [weak self] state in
            guard let self else { return }

            // If we move to a non-installable state (error, idle, etc.) then we
            // stop force installing.
            guard state.isInstallable else {
                self.installCancellable = nil
                return
            }

            // Continue the `yes` chain!
            state.confirm()
        }
    }

    /// Check for updates.
    ///
    /// This is typically connected to a menu item action.
    @objc func checkForUpdates() {
        // Fork: a build carrying the placeholder Sparkle key can't verify the fork
        // feed, so a check would only surface a signature error. Guard HERE (not
        // just in validateMenuItem) so EVERY entry point — menu, keybind, and
        // command palette (which call this directly) — is consistent.
        guard !Self.hasPlaceholderUpdateKey else { return }

        // If we're already idle, then just check for updates immediately.
        if viewModel.state == .idle {
            updater.checkForUpdates()
            return
        }

        // If we're not idle then we need to cancel any prior state.
        installCancellable?.cancel()
        viewModel.state.cancel()

        // The above will take time to settle, so we delay the check for some time.
        // The 100ms is arbitrary and I'd rather not, but we have to wait more than
        // one loop tick it seems.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            self?.updater.checkForUpdates()
        }
    }

    /// Validate the check for updates menu item.
    ///
    /// - Parameter item: The menu item to validate
    /// - Returns: Whether the menu item should be enabled
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(checkForUpdates) {
            // Fork: builds that still carry the fail-closed PLACEHOLDER Sparkle key
            // (any non-CI build — dev builds and a locally-installed Release built
            // via the CLAUDE.md step-6 block, which never injects the real key)
            // cannot verify the fork appcast signature, so a manual check would just
            // surface a verification error. Keep the item disabled on those builds.
            if Self.hasPlaceholderUpdateKey { return false }
            return updater.canCheckForUpdates
        }
        return true
    }

    /// The fail-closed placeholder `SUPublicEDKey` shipped in the committed
    /// Info.plist (32 zero bytes). Only the CI release build overwrites it with the
    /// fork's real key. See `Ghostty-Info.plist` + CLAUDE.md "Distribution".
    private static let placeholderUpdateKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

    /// True when this build still carries the placeholder Sparkle public key, i.e.
    /// it can never verify a real update and the "Check for Updates" action should
    /// stay disabled.
    static var hasPlaceholderUpdateKey: Bool {
        (Bundle.main.infoDictionary?["SUPublicEDKey"] as? String) == placeholderUpdateKey
    }
}

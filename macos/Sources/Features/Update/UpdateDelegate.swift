import Sparkle
import Cocoa

extension UpdateDriver: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else {
            return nil
        }

        // Fork: the feed is pinned to THIS fork's own GitHub Releases, never
        // ghostty.org, so the fork is never replaced by an official Ghostty
        // build. The fork ships a single continuous release stream (DMG + appcast
        // published by the local script dist/macos/release-local.sh, or the
        // manual-only .github/workflows/fork-release.yml fallback), so both
        // Sparkle "channels" resolve to the same fork appcast. The
        // `releases/latest/download/<asset>` URL always serves the asset from
        // the most recent release (each release is published `--latest`). The
        // appcast is a SINGLE newest-item feed (dist/macos/fork_appcast.py emits
        // one item, NOT a cumulative history) — that is all Sparkle needs, since
        // update detection compares the monotonic CFBundleVersion/sparkle:version.
        switch appDelegate.ghostty.config.autoUpdateChannel {
        case .tip, .stable:
            return "https://github.com/ramonsnir/ghostty/releases/latest/download/appcast.xml"
        }
    }

    /// Called when an update is scheduled to install silently,
    /// which occurs when `auto-update = download`.
    ///
    /// When `auto-update = check`, Sparkle will call the corresponding
    /// delegate method on the responsible driver instead.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        viewModel.state = .installing(.init(
            isAutoUpdate: true,
            retryTerminatingApplication: immediateInstallHandler,
            dismiss: { [weak viewModel] in
                viewModel?.state = .idle
            }
        ))
        return true
    }
}

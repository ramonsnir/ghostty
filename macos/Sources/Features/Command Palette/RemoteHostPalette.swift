import SwiftUI
import GhosttyKit

/// (ramon fork / cloud-hosts) A fuzzy palette of REMOTE hosts declared in the
/// `pty-remote-host` config key. Picking a host opens a new SPLIT running on
/// that cloud box (the `new_split_on_host` action): the split is created with a
/// bare `SurfaceConfiguration` carrying only `hostName = <name>`, so the
/// `SurfaceView` defers the dial to the tunnel supervisor's readiness signal
/// (E2) and resolves `<name>` → forwarded socket via `RemoteHostRegistry` /
/// `RemoteTunnelController`. No socket path is threaded here — the SurfaceView
/// owns the resolve/await/placeholder machinery (D4/D5).
///
/// This mirrors `ProjectPaletteView`, reusing the generic `CommandPaletteView`
/// (fuzzy match + arrow/ctrl-n/ctrl-p nav) and the same first-responder
/// handling.
struct RemoteHostPaletteView: View {
    /// The surface that this palette represents (and whose tab we split from).
    let surfaceView: Ghostty.SurfaceView

    /// Set this to true to show the view, this will be set to false if any
    /// actions result in the view disappearing.
    @Binding var isPresented: Bool

    /// The configuration so we can lookup the background color.
    @ObservedObject var ghosttyConfig: Ghostty.Config

    /// The raw `pty-remote-host` lines (verbatim values). Parsed here via
    /// `RemoteHostRegistry` — the SOLE home of the line grammar.
    let remoteHostLines: [String]

    var body: some View {
        ZStack {
            if isPresented {
                GeometryReader { geometry in
                    VStack {
                        Spacer().frame(height: geometry.size.height * 0.05)

                        ResponderChainInjector(responder: surfaceView)
                            .frame(width: 0, height: 0)

                        CommandPaletteView(
                            isPresented: $isPresented,
                            backgroundColor: ghosttyConfig.backgroundColor,
                            options: hostOptions
                        )
                        .zIndex(1) // Ensure it's on top

                        Spacer()
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                }
            }
        }
        .onChange(of: isPresented) { newValue in
            // When the palette disappears we need to send focus back to the
            // surface view we were overlaid on top of.
            if !newValue {
                DispatchQueue.main.async {
                    surfaceView.window?.makeFirstResponder(surfaceView)
                }
            }
        }
    }

    /// The list of host options. If nothing is configured (or every line is
    /// malformed / reserved) a single informational row is shown so the toggle
    /// is never a silent no-op.
    private var hostOptions: [CommandOption] {
        let entries = Self.sortedEntries(from: remoteHostLines)

        guard !entries.isEmpty else {
            Ghostty.logger.warning("remote host selector toggled with no pty-remote-host configured")
            return [emptyStateOption(
                title: "No remote hosts configured",
                subtitle: "Add `pty-remote-host = <name> = <ssh-target> : <socket>` to ~/.config/ghostty-ramon/config"
            )]
        }

        return entries.map { entry in
            CommandOption(
                title: entry.name,
                subtitle: entry.sshTarget,
                leadingIcon: "cloud"
            ) {
                Self.openSplit(on: entry, from: surfaceView)
            }
        }
    }

    /// (testable, pure) Parse the raw `pty-remote-host` lines into the registry
    /// and return its entries sorted case-insensitively by name. Malformed /
    /// reserved (`local`) lines are dropped by `RemoteHostRegistry.parse`.
    static func sortedEntries(from lines: [String]) -> [RemoteHostEntry] {
        RemoteHostRegistry.parse(lines: lines)
            .values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Open a new split on `entry`'s host by posting the same `ghosttyNewSplit`
    /// notification the `new_split_on_host` action uses. The config is BARE
    /// (only `hostName`) — the SurfaceView resolves the host + defers the dial
    /// to tunnel readiness (E2). Direction is aspect-derived (like
    /// `new_split:auto`).
    static func openSplit(on entry: RemoteHostEntry, from surfaceView: Ghostty.SurfaceView) {
        var config = Ghostty.SurfaceConfiguration()
        config.hostName = entry.name
        NotificationCenter.default.post(
            name: Ghostty.Notification.ghosttyNewSplit,
            object: surfaceView,
            userInfo: [
                "direction": autoDirection(for: surfaceView),
                Ghostty.Notification.NewSurfaceConfigKey: config,
            ]
        )
    }

    /// Aspect-based split direction, mirroring the core's `new_split:auto`
    /// (wider than tall ⇒ split right, else down).
    static func autoDirection(for surfaceView: Ghostty.SurfaceView) -> ghostty_action_split_direction_e {
        let size = surfaceView.bounds.size
        return size.width > size.height ? GHOSTTY_SPLIT_DIRECTION_RIGHT : GHOSTTY_SPLIT_DIRECTION_DOWN
    }

    /// An informational, no-op row used when there is nothing to show.
    private func emptyStateOption(title: String, subtitle: String) -> CommandOption {
        CommandOption(
            title: title,
            subtitle: subtitle,
            leadingIcon: "cloud.slash"
        ) {}
    }
}

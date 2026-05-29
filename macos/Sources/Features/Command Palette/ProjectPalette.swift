import SwiftUI
import GhosttyKit

/// (ramon fork) A fuzzy palette of project directories. Each configured
/// `project-directory` is a BASE directory whose immediate subdirectories are
/// offered as projects; selecting one opens a new tab in that directory.
///
/// This mirrors `TerminalCommandPaletteView`, reusing the generic
/// `CommandPaletteView` (fuzzy match + arrow/ctrl-n/ctrl-p nav) and the same
/// first-responder handling.
struct ProjectPaletteView: View {
    /// The surface that this palette represents (and whose tab we open into).
    let surfaceView: Ghostty.SurfaceView

    /// Set this to true to show the view, this will be set to false if any
    /// actions result in the view disappearing.
    @Binding var isPresented: Bool

    /// The configuration so we can lookup the background color.
    @ObservedObject var ghosttyConfig: Ghostty.Config

    /// The configured base directories to scan for projects.
    let projectDirectories: [String]

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
                            options: projectOptions
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

    /// The list of project options, enumerated dynamically from the configured
    /// base directories. If nothing is configured (or nothing is found), a
    /// single informational row is shown so the toggle is never a silent no-op.
    private var projectOptions: [CommandOption] {
        guard !projectDirectories.isEmpty else {
            Ghostty.logger.warning("project selector toggled with no project-directory configured")
            return [emptyStateOption(
                title: "No project directories configured",
                subtitle: "Add `project-directory = …` to ~/.config/ghostty-ramon/config"
            )]
        }

        let fm = FileManager.default
        var seen = Set<String>()
        var options: [CommandOption] = []

        for base in projectDirectories {
            let expanded = (base as NSString).expandingTildeInPath
            let baseURL = URL(fileURLWithPath: expanded)
            guard let entries = try? fm.contentsOfDirectory(
                at: baseURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in entries {
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                      values.isDirectory == true else { continue }

                // Dedupe across bases by canonical path.
                let canonical = url.standardizedFileURL.path
                guard seen.insert(canonical).inserted else { continue }

                let path = url.path
                options.append(CommandOption(
                    title: url.lastPathComponent,
                    subtitle: path.abbreviatedPath,
                    leadingIcon: "folder"
                ) {
                    var config = Ghostty.SurfaceConfiguration()
                    config.workingDirectory = path
                    NotificationCenter.default.post(
                        name: Ghostty.Notification.ghosttyNewTab,
                        object: surfaceView,
                        userInfo: [
                            Ghostty.Notification.NewSurfaceConfigKey: config,
                        ]
                    )
                })
            }
        }

        guard !options.isEmpty else {
            Ghostty.logger.warning("project selector found no project directories under the configured bases")
            return [emptyStateOption(
                title: "No projects found",
                subtitle: "No subdirectories under the configured project-directory bases"
            )]
        }

        return options.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    /// An informational, no-op row used when there is nothing to show.
    private func emptyStateOption(title: String, subtitle: String) -> CommandOption {
        CommandOption(
            title: title,
            subtitle: subtitle,
            leadingIcon: "folder.badge.questionmark"
        ) {}
    }
}

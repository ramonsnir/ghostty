import Combine
import SwiftUI
import GhosttyKit

/// (ramon fork) A fuzzy palette of project directories. Each configured
/// `project-directory` is a BASE directory whose immediate subdirectories are
/// offered as projects; selecting one opens a new tab in that directory.
///
/// (cloud-hosts) The palette is HOST-AWARE: `pty-remote-project-directory`
/// lines (`<host> = <base>`) add per-box projects. A local base is scanned
/// synchronously (`discoverProjectPaths`). A remote base cannot be `stat`'d
/// locally, so the immediate subdirs are listed on the box over the tunnel
/// supervisor's ControlMaster (`RemoteTunnelController.listProjects`) and CACHED;
/// the palette reads that cache SYNCHRONOUSLY (never blocks) and shows a
/// "listing…" informational row while a fetch is cold, then refreshes when the
/// cache fills. Selecting a remote project opens a new tab carrying the target
/// `hostName`, so it spawns on that box.
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

    /// The configured LOCAL base directories to scan for projects.
    let projectDirectories: [String]

    /// (cloud-hosts) Raw `pty-remote-project-directory` lines (`<host> = <base>`),
    /// parsed here by `parseRemoteProjectBases`. Empty when unset.
    var remoteProjectLines: [String] = []

    /// (cloud-hosts) Raw `pty-remote-host` lines, parsed by `RemoteHostRegistry`
    /// so a remote base's host name resolves to an ssh target + socket for the
    /// tunnel. Empty when unset.
    var remoteHostLines: [String] = []

    /// Bumped whenever the tunnel supervisor refreshes a host's project cache, so
    /// the remote rows recompute once a cold listing lands.
    @State private var remoteRefresh: Int = 0

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
        // Recompute the remote rows when a cold/stale listing is refreshed.
        .onReceive(RemoteTunnelController.shared.projectsDidUpdate.receive(on: RunLoop.main)) { _ in
            remoteRefresh &+= 1
        }
        .onChange(of: isPresented) { newValue in
            if newValue {
                // Warm the remote caches on open (stale-while-revalidate). Reading
                // the cache in `projectOptions` stays side-effect-free.
                prefetchRemoteProjects()
            } else {
                // When the palette disappears we need to send focus back to the
                // surface view we were overlaid on top of.
                DispatchQueue.main.async {
                    surfaceView.window?.makeFirstResponder(surfaceView)
                }
            }
        }
    }

    /// The list of project options: LOCAL projects first, then per-host REMOTE
    /// projects. If nothing is configured (or nothing is found anywhere) a single
    /// informational row is shown so the toggle is never a silent no-op.
    private var projectOptions: [CommandOption] {
        _ = remoteRefresh  // recompute remote rows when the cache updates

        let localOpts = Self.discoverProjectPaths(bases: projectDirectories).map { localOption(for: $0) }
        let remoteOpts = remoteOptions()

        guard localOpts.isEmpty && remoteOpts.isEmpty else {
            return localOpts + remoteOpts
        }

        // Nothing to show — distinguish "nothing configured" from "configured but
        // no projects found under the bases".
        if projectDirectories.isEmpty && Self.parseRemoteProjectBases(remoteProjectLines).isEmpty {
            Ghostty.logger.warning("project selector toggled with no project-directory / pty-remote-project-directory configured")
            return [emptyStateOption(
                title: "No project directories configured",
                subtitle: "Add `project-directory = …` (or `pty-remote-project-directory = <host> = <base>`) to ~/.config/ghostty-ramon/config"
            )]
        }
        Ghostty.logger.warning("project selector found no project directories under the configured bases")
        return [emptyStateOption(
            title: "No projects found",
            subtitle: "No subdirectories under the configured project-directory bases"
        )]
    }

    /// A local-project row: opens a new tab in `path` (no host — stays local).
    private func localOption(for path: String) -> CommandOption {
        CommandOption(
            title: (path as NSString).lastPathComponent,
            subtitle: path.abbreviatedPath,
            leadingIcon: "folder"
        ) {
            var config = Ghostty.SurfaceConfiguration()
            config.workingDirectory = path
            NotificationCenter.default.post(
                name: Ghostty.Notification.ghosttyNewTab,
                object: surfaceView,
                userInfo: [Ghostty.Notification.NewSurfaceConfigKey: config]
            )
        }
    }

    /// The REMOTE project rows, grouped by host (hosts sorted case-insensitively).
    /// A host with a cold cache contributes a single "Listing…" informational row;
    /// a stale cache is still shown (marked "refreshing"). A host named in a
    /// `pty-remote-project-directory` line but NOT in the `pty-remote-host`
    /// registry is skipped (there is no tunnel to reach it).
    private func remoteOptions() -> [CommandOption] {
        let registry = RemoteHostRegistry.parse(lines: remoteHostLines)
        let pairs = Self.parseRemoteProjectBases(remoteProjectLines)
        guard !pairs.isEmpty else { return [] }

        let hostNames = Set(pairs.map { $0.host })
            .filter { registry[$0] != nil }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        var opts: [CommandOption] = []
        for host in hostNames {
            guard let cached = RemoteTunnelController.shared.cachedProjects(hostName: host) else {
                // Cold: never a silent no-op — show a "listing…" row (the open
                // handler kicked the fetch via `prefetchRemoteProjects`).
                opts.append(emptyStateOption(
                    title: "Listing projects on \(host)…",
                    subtitle: "Fetching remote directories over the tunnel",
                    leadingIcon: "cloud"
                ))
                continue
            }
            if cached.paths.isEmpty {
                opts.append(emptyStateOption(
                    title: "No projects on \(host)",
                    subtitle: "No subdirectories under the configured remote bases",
                    leadingIcon: "cloud"
                ))
                continue
            }
            let refreshing = cached.freshness == .stale ? " · refreshing" : ""
            for path in cached.paths {
                opts.append(CommandOption(
                    title: (path as NSString).lastPathComponent,
                    subtitle: "\(host):\(path)\(refreshing)",
                    leadingIcon: "cloud"
                ) {
                    var config = Ghostty.SurfaceConfiguration()
                    config.workingDirectory = path
                    config.hostName = host
                    NotificationCenter.default.post(
                        name: Ghostty.Notification.ghosttyNewTab,
                        object: surfaceView,
                        userInfo: [Ghostty.Notification.NewSurfaceConfigKey: config]
                    )
                })
            }
        }
        return opts
    }

    /// Warm the project cache for every configured remote host (stale-while-
    /// revalidate; coalesced per host by the controller). Called on open — reading
    /// the cache in `projectOptions` stays side-effect-free.
    private func prefetchRemoteProjects() {
        let registry = RemoteHostRegistry.parse(lines: remoteHostLines)
        var basesByHost: [String: [String]] = [:]
        for pair in Self.parseRemoteProjectBases(remoteProjectLines) {
            basesByHost[pair.host, default: []].append(pair.base)
        }
        for (host, bases) in basesByHost {
            guard let entry = registry[host] else { continue }
            RemoteTunnelController.shared.ensureProjects(host: entry, bases: bases)
        }
    }

    /// (testable, pure) Parse `pty-remote-project-directory` lines. Each line is
    /// `<host> = <base>`: split on the FIRST `=`, trim both sides, and keep it only
    /// when BOTH are non-empty. Order is preserved and duplicate `(host, base)`
    /// pairs are collapsed. Malformed lines (no `=`, empty host, empty base) are
    /// dropped. The `<host>` is matched against the `pty-remote-host` registry by
    /// the caller — an unknown host contributes no rows.
    static func parseRemoteProjectBases(_ lines: [String]) -> [(host: String, base: String)] {
        var out: [(host: String, base: String)] = []
        var seen = Set<String>()
        for line in lines {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let host = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            let base = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, !base.isEmpty else { continue }
            // Collapse exact duplicates (a host may legitimately have several bases).
            guard seen.insert("\(host)\t\(base)").inserted else { continue }
            out.append((host: host, base: base))
        }
        return out
    }

    /// (testable, pure filesystem) Discover the LOCAL project directories under
    /// the given base directories: each base's immediate children that are real
    /// directories OR symlinks resolving to a directory. Deduped across bases by
    /// path, sorted case-insensitively by the displayed name (last path
    /// component). Bases are tilde-expanded; unreadable bases are skipped.
    static func discoverProjectPaths(
        bases: [String],
        fileManager fm: FileManager = .default
    ) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []

        for base in bases {
            let expanded = (base as NSString).expandingTildeInPath
            let baseURL = URL(fileURLWithPath: expanded)
            guard let entries = try? fm.contentsOfDirectory(
                at: baseURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in entries {
                guard Self.isProjectDirectory(url, fileManager: fm) else { continue }

                // Dedupe across bases by canonical path.
                let canonical = url.standardizedFileURL.path
                guard seen.insert(canonical).inserted else { continue }

                paths.append(url.path)
            }
        }

        return paths.sorted {
            ($0 as NSString).lastPathComponent
                .localizedCaseInsensitiveCompare(($1 as NSString).lastPathComponent) == .orderedAscending
        }
    }

    /// (testable) Whether a directory entry qualifies as a project: a real
    /// directory, or a symlink whose final target is a directory. Symlinks to
    /// files and dangling (broken) symlinks are excluded. `.isDirectoryKey`
    /// reports on the symlink itself (not its target), so a symlink-to-folder
    /// would otherwise be dropped — hence the explicit follow.
    static func isProjectDirectory(_ url: URL, fileManager fm: FileManager = .default) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if values?.isDirectory == true { return true }
        guard values?.isSymbolicLink == true else { return false }

        // Follow the symlink: fileExists(atPath:isDirectory:) uses stat (which
        // follows symlinks), so this is true only when the final target exists
        // and is a directory — not a file, and not a dangling link.
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// An informational, no-op row used when there is nothing to show.
    private func emptyStateOption(
        title: String,
        subtitle: String,
        leadingIcon: String = "folder.badge.questionmark"
    ) -> CommandOption {
        CommandOption(
            title: title,
            subtitle: subtitle,
            leadingIcon: leadingIcon
        ) {}
    }
}

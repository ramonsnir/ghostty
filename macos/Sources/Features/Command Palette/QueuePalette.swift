import SwiftUI
import GhosttyKit

/// (ramon fork / Agent Queue Supervisor) A fuzzy palette of the available queue
/// TEMPLATES. Each `*.json` file in the templates dir is offered by its basename
/// (minus the extension); selecting one ENQUEUES a `{action:"start", template:…}`
/// control command (via `.ghosttyQueueCommand`) so the sidecar supervisor starts
/// that run on its next sweep.
///
/// This mirrors `ProjectPaletteView` (which mirrors `TerminalCommandPaletteView`),
/// reusing the generic `CommandPaletteView` (fuzzy match + arrow/ctrl-n/ctrl-p
/// nav) and the same first-responder handling. The `start_agent_queue` keybind
/// action (with no template) opens this; a `start_agent_queue:<name>` action skips
/// it and enqueues directly (see `Ghostty.App.startAgentQueue`).
struct QueuePaletteView: View {
    /// The surface that this palette is overlaid on (focus returns to it on close).
    let surfaceView: Ghostty.SurfaceView

    /// Set this to true to show the view; set false when an action dismisses it.
    @Binding var isPresented: Bool

    /// The configuration so we can look up the background color.
    @ObservedObject var ghosttyConfig: Ghostty.Config

    /// The configured queue-templates directory, or nil to use the default
    /// (`~/.config/ghostty-ramon/agent-manager/queues`). `~/` is expanded here.
    let templatesDir: String?

    /// The default templates dir when `agent-queue-templates-dir` is unset — kept
    /// in sync with the sidecar's built-in default (see the queue templates loader).
    static let defaultTemplatesDir = "~/.config/ghostty-ramon/agent-manager/queues"

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
                            options: templateOptions
                        )
                        .zIndex(1) // Ensure it's on top

                        Spacer()
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                }
            }
        }
        .onChange(of: isPresented) { newValue in
            // When the palette disappears, send focus back to the surface view we
            // were overlaid on top of.
            if !newValue {
                DispatchQueue.main.async {
                    surfaceView.window?.makeFirstResponder(surfaceView)
                }
            }
        }
    }

    /// The list of template options discovered from the templates dir. If the dir
    /// is missing or holds no templates, a single informational row is shown so
    /// the toggle is never a silent no-op (mirrors `ProjectPaletteView`).
    private var templateOptions: [CommandOption] {
        let dir = templatesDir ?? Self.defaultTemplatesDir
        let templates = Self.discoverTemplates(dir: dir)

        guard !templates.isEmpty else {
            Ghostty.logger.warning("queue selector found no templates under the configured templates dir")
            return [emptyStateOption(
                title: "No queue templates found",
                subtitle: "Add a *.json template under \((dir as NSString).abbreviatingWithTildeInPath)"
            )]
        }

        return templates.map { name in
            CommandOption(
                title: name,
                subtitle: "Start a queue run from this template",
                leadingIcon: "square.stack.3d.up"
            ) {
                // Enqueue the start intent onto the MCP server's FIFO — the SAME
                // path `Ghostty.App.startAgentQueue` uses for the `:<name>` form
                // and the dashboard control buttons. The sidecar supervisor drains
                // this on its next sweep and starts the run.
                NotificationCenter.default.post(
                    name: .ghosttyQueueCommand,
                    object: nil,
                    userInfo: [
                        QueueCommandUserInfoKey.command:
                            QueueCommand(action: .start, template: name),
                    ]
                )
            }
        }
    }

    /// (testable, pure filesystem) Discover the queue templates under `dir`: every
    /// immediate child whose name ends in `.json` (case-insensitive), returned as
    /// the BASENAME minus the `.json` extension, deduped, sorted case-insensitively.
    /// `dir` is tilde-expanded; an unreadable dir yields an empty list. Hidden files
    /// are skipped (a leading-dot template is not a real queue template).
    static func discoverTemplates(
        dir: String,
        fileManager fm: FileManager = .default
    ) -> [String] {
        let expanded = (dir as NSString).expandingTildeInPath
        guard let entries = try? fm.contentsOfDirectory(atPath: expanded) else { return [] }

        var seen = Set<String>()
        var names: [String] = []
        for entry in entries {
            guard !entry.hasPrefix(".") else { continue }
            let ns = entry as NSString
            guard ns.pathExtension.lowercased() == "json" else { continue }
            let base = ns.deletingPathExtension
            guard !base.isEmpty, seen.insert(base).inserted else { continue }
            names.append(base)
        }

        return names.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    /// An informational, no-op row used when there is nothing to show.
    private func emptyStateOption(title: String, subtitle: String) -> CommandOption {
        CommandOption(
            title: title,
            subtitle: subtitle,
            leadingIcon: "square.stack.3d.up.slash"
        ) {}
    }
}

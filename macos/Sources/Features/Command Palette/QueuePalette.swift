import SwiftUI
import GhosttyKit

/// (ramon fork / Agent Queue Supervisor) A fuzzy palette of the available queue
/// TEMPLATES. Each `*.json` file in the templates dir is offered by its basename
/// (minus the extension); selecting one ENQUEUES a `{action:"start", template:…}`
/// control command (via `.ghosttyQueueCommand`) so the sidecar supervisor starts
/// that run on its next sweep.
///
/// (§8b) START-TIME PARAMS: when the selected template declares `params`, the palette
/// transitions to a small form (one field per param, pre-filled with the param's
/// `default`) and the start command carries the entered `{name:value}` answers so the
/// SAME generic template can be pointed at a different scope (e.g. a Linear project /
/// milestone) per run without editing files. A template with no params starts directly
/// (the prior behavior).
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

    /// (§8b) The active param-prompt, set when a template that declares params is
    /// picked. A reference-type holder so the (escaping) `CommandOption` action
    /// closures can flip it (a SwiftUI View struct is value-copied, so they can't set
    /// a plain `@State` directly).
    @StateObject private var prompt = QueueParamPromptModel()

    var body: some View {
        ZStack {
            if isPresented {
                GeometryReader { geometry in
                    VStack {
                        Spacer().frame(height: geometry.size.height * 0.05)

                        ResponderChainInjector(responder: surfaceView)
                            .frame(width: 0, height: 0)

                        if let active = prompt.active {
                            QueueParamFormView(
                                prompt: active,
                                backgroundColor: ghosttyConfig.backgroundColor,
                                onCancel: {
                                    prompt.active = nil
                                    isPresented = false
                                },
                                onStart: { values in
                                    Self.postStart(template: active.template, params: values)
                                    prompt.active = nil
                                    isPresented = false
                                }
                            )
                            .frame(maxWidth: 560)
                            .zIndex(1)
                        } else {
                            CommandPaletteView(
                                isPresented: $isPresented,
                                backgroundColor: ghosttyConfig.backgroundColor,
                                options: templateOptions
                            )
                            .zIndex(1) // Ensure it's on top
                        }

                        Spacer()
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                }
            }
        }
        .onChange(of: isPresented) { newValue in
            // When the palette disappears, send focus back to the surface view we
            // were overlaid on top of, and clear any pending param prompt.
            if !newValue {
                prompt.active = nil
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
                // (§8b) If the template declares start-time params, transition to the
                // prompt form (the start is enqueued from the form's Start). Otherwise
                // enqueue the start intent directly — the SAME path
                // `Ghostty.App.startAgentQueue` uses for the `:<name>` form and the
                // dashboard control buttons.
                let params = Self.templateParams(dir: dir, basename: name)
                if params.isEmpty {
                    Self.postStart(template: name, params: nil)
                } else {
                    prompt.active = QueueParamPrompt(template: name, params: params)
                }
            }
        }
    }

    /// Enqueue a `{action:start, template, params?}` command onto the MCP server's FIFO.
    static func postStart(template: String, params: [String: String]?) {
        NotificationCenter.default.post(
            name: .ghosttyQueueCommand,
            object: nil,
            userInfo: [
                QueueCommandUserInfoKey.command:
                    QueueCommand(action: .start, template: template, params: params),
            ]
        )
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

    /// (§8b, testable, pure filesystem) Read a template's declared `params` from its
    /// `<dir>/<basename>.json` file. Returns `[]` when the file is missing/unreadable,
    /// not an object, or has no (valid) `params` array. Only `name` is required per
    /// entry; `label` defaults to `name`, `default` to "", `required` to false. The
    /// `env` field (which the SIDECAR maps the value onto) is intentionally NOT surfaced
    /// to the GUI — the palette only needs to prompt by `name`.
    static func templateParams(
        dir: String,
        basename: String,
        fileManager fm: FileManager = .default
    ) -> [QueueParamSpec] {
        let expanded = (dir as NSString).expandingTildeInPath
        let path = (expanded as NSString).appendingPathComponent("\(basename).json")
        guard let data = fm.contents(atPath: path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let arr = obj["params"] as? [[String: Any]]
        else { return [] }

        var out: [QueueParamSpec] = []
        var seen = Set<String>()
        for p in arr {
            guard let name = p["name"] as? String, !name.isEmpty, seen.insert(name).inserted else { continue }
            out.append(QueueParamSpec(
                name: name,
                label: (p["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name,
                defaultValue: (p["default"] as? String) ?? "",
                required: (p["required"] as? Bool) ?? false
            ))
        }
        return out
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

// MARK: - §8b start-time params: model + spec + form

/// (§8b) One start-time parameter to prompt for (the GUI-facing projection of the
/// template's `params` entry; `env` is omitted — the sidecar owns name→env mapping).
struct QueueParamSpec: Equatable {
    let name: String
    let label: String
    let defaultValue: String
    let required: Bool
}

/// (§8b) A pending param prompt: which template + the fields to fill.
struct QueueParamPrompt: Equatable {
    let template: String
    let params: [QueueParamSpec]
}

/// Reference-type holder so the palette's escaping option closures can set the
/// pending prompt (a SwiftUI View struct is value-copied; a plain `@State` set from
/// an escaping closure wouldn't stick).
final class QueueParamPromptModel: ObservableObject {
    @Published var active: QueueParamPrompt?
}

/// (§8b) The param-entry form shown when a param-bearing template is picked. One
/// labeled field per param, pre-filled with its default. Start is disabled while any
/// REQUIRED field is empty; Start enqueues the run with the entered answers.
struct QueueParamFormView: View {
    let prompt: QueueParamPrompt
    let backgroundColor: Color
    let onCancel: () -> Void
    let onStart: ([String: String]) -> Void

    @State private var values: [String: String]

    init(
        prompt: QueueParamPrompt,
        backgroundColor: Color,
        onCancel: @escaping () -> Void,
        onStart: @escaping ([String: String]) -> Void
    ) {
        self.prompt = prompt
        self.backgroundColor = backgroundColor
        self.onCancel = onCancel
        self.onStart = onStart
        // Pre-fill each field with its declared default.
        var initial: [String: String] = [:]
        for p in prompt.params { initial[p.name] = p.defaultValue }
        _values = State(initialValue: initial)
    }

    /// (pure, testable) Whether Start is allowed: every REQUIRED param has a
    /// non-blank value.
    static func canStart(params: [QueueParamSpec], values: [String: String]) -> Bool {
        for p in params where p.required {
            let v = values[p.name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if v.isEmpty { return false }
        }
        return true
    }

    private var canStart: Bool { Self.canStart(params: prompt.params, values: values) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start “\(prompt.template)”")
                .font(.headline)

            ForEach(prompt.params, id: \.name) { p in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(p.label)
                            .font(.subheadline)
                        if p.required {
                            Text("required").font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    TextField(p.defaultValue.isEmpty ? p.name : p.defaultValue, text: bindingFor(p.name))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if canStart { onStart(values) } }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Start") { onStart(values) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
        }
        .padding(20)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.3)))
        .shadow(radius: 16)
    }

    private func bindingFor(_ name: String) -> Binding<String> {
        Binding(
            get: { values[name] ?? "" },
            set: { values[name] = $0 }
        )
    }
}

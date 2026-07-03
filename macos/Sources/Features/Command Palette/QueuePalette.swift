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

    /// The CONFIGURED queue-templates search dirs (repeatable; may be empty). The
    /// effective search path prepends `defaultTemplatesDir` (always searched first) and
    /// dedups; `~/` is expanded by `effectiveSearchDirs`.
    let templatesDirs: [String]

    /// The default templates dir, ALWAYS searched first (prepended to the configured
    /// list by `effectiveSearchDirs`). Kept in sync with the sidecar's built-in default
    /// (see the queue templates loader) and `AgentManagerController.defaultTemplatesDir`.
    static let defaultTemplatesDir = "~/.config/ghostty-ramon/agent-manager/queues"

    /// (§8b) The active param-prompt, set when a template that declares params is
    /// picked. A reference-type holder so the (escaping) `CommandOption` action
    /// closures can flip it (a SwiftUI View struct is value-copied, so they can't set
    /// a plain `@State` directly).
    @StateObject private var prompt = QueueParamPromptModel()

    var body: some View {
        ZStack {
            // The param FORM is shown whenever a prompt is pending — INDEPENDENT of
            // `isPresented`. This is load-bearing: `CommandPaletteView` sets the bound
            // `isPresented = false` BEFORE running the selected option's action (see
            // CommandPalette.swift), so by the time the option sets `prompt.active` the
            // picker has already dismissed. Gating the form on `isPresented` would mean it
            // never appears (and the onChange would clear `prompt.active`). The QueuePalette
            // view is always mounted (TerminalView gates it via this same `isPresented`
            // binding but keeps the view in the hierarchy), so its `@StateObject` survives
            // the flip and the form can render after the picker closes.
            if isPresented || prompt.active != nil {
                GeometryReader { geometry in
                    VStack {
                        Spacer().frame(height: geometry.size.height * 0.05)

                        ResponderChainInjector(responder: surfaceView)
                            .frame(width: 0, height: 0)

                        if let active = prompt.active {
                            QueueParamFormView(
                                prompt: active,
                                backgroundColor: ghosttyConfig.backgroundColor,
                                onCancel: { closeForm() },
                                onStart: { values in
                                    Self.postStart(template: active.template, params: values)
                                    closeForm()
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
            if newValue {
                // Fresh open of the picker — clear any stale pending prompt.
                prompt.active = nil
            } else {
                // The picker closed. Return focus to the surface ONLY if no param form is
                // (about to be) shown. Defer to the next runloop tick: when an option fires,
                // CommandPaletteView sets isPresented=false and THEN runs the action that
                // sets prompt.active synchronously — so by the time this async block runs,
                // prompt.active reflects whether a form is pending.
                DispatchQueue.main.async {
                    if prompt.active == nil {
                        surfaceView.window?.makeFirstResponder(surfaceView)
                    }
                }
            }
        }
    }

    /// Dismiss the param form: clear the pending prompt, ensure the palette binding is
    /// closed, and return focus to the surface (the picker already set isPresented=false,
    /// so its onChange won't fire again — return focus here explicitly).
    private func closeForm() {
        prompt.active = nil
        isPresented = false
        DispatchQueue.main.async {
            surfaceView.window?.makeFirstResponder(surfaceView)
        }
    }

    /// The list of template options discovered across the effective search path (the
    /// default dir first, then each configured dir; first-in-search-order wins on a
    /// basename clash). If the search path holds no templates, a single informational
    /// row is shown so the toggle is never a silent no-op (mirrors `ProjectPaletteView`).
    private var templateOptions: [CommandOption] {
        let dirs = Self.effectiveSearchDirs(configured: templatesDirs)
        let templates = Self.discoverTemplates(dirs: dirs)

        guard !templates.isEmpty else {
            Ghostty.logger.warning("queue selector found no templates under the configured search path")
            let pathDesc = dirs
                .map { ($0 as NSString).abbreviatingWithTildeInPath }
                .joined(separator: ", ")
            return [emptyStateOption(
                title: "No queue templates found",
                subtitle: "Add a *.json template under \(pathDesc)"
            )]
        }

        return templates.map { entry in
            // A shadowed basename (present in more than one search dir) badges its
            // WINNING source dir so the choice isn't silently ambiguous; a unique
            // basename keeps the plain subtitle.
            let subtitle = entry.hasDuplicate
                ? "Start a queue run · from \((entry.sourceDir as NSString).abbreviatingWithTildeInPath)"
                : "Start a queue run from this template"
            return CommandOption(
                // Show the template's human `name` (e.g. "ExampleOS"); the START command
                // still carries the file `basename` (the sidecar loads templates by it).
                title: entry.displayName,
                subtitle: subtitle,
                leadingIcon: "square.stack.3d.up"
            ) {
                // (§8b) If the template declares start-time params, transition to the
                // prompt form (the start is enqueued from the form's Start). Otherwise
                // enqueue the start intent directly — the SAME path
                // `Ghostty.App.startAgentQueue` uses for the `:<name>` form and the
                // dashboard control buttons. Params/probe resolve against the entry's
                // WINNING source dir (first-in-search-order).
                let params = Self.templateParams(dir: entry.sourceDir, basename: entry.basename)
                if params.isEmpty {
                    Self.postStart(template: entry.basename, params: nil)
                } else {
                    prompt.active = QueueParamPrompt(
                        template: entry.basename,
                        displayName: entry.displayName,
                        // The resolved winning dir, exported as GHOSTTY_QUEUE_TEMPLATE_DIR into
                        // the form's probe env (parity with the sidecar's queueProviderEnv).
                        templateDir: (entry.sourceDir as NSString).expandingTildeInPath,
                        params: params,
                        probe: Self.templateProbe(dir: entry.sourceDir, basename: entry.basename)
                    )
                }
            }
        }
    }

    /// (shared templates §2) The `{templateDir}` portability token. The palette is a
    /// SECOND exec path (live `list` preview + param `valuesCommand` suggestions) alongside
    /// the sidecar loader, so it must substitute the token itself to reach parity with the
    /// sidecar's `substituteTemplateDir` + `queueProviderEnv` — otherwise a shared-repo
    /// template that references sibling scripts via `{templateDir}` gets a broken preview and
    /// empty suggestions even though the actual queue run works.
    static let templateDirToken = "{templateDir}"

    /// (shared templates §2, pure, testable) Substring-replace ALL `{templateDir}`
    /// occurrences in each argv element with `dir` (the template's OWN resolved directory,
    /// no trailing slash). An empty `dir` leaves the argv untouched (the token stays literal,
    /// so the run fails visibly rather than silently pointing at the cwd). Matches the
    /// sidecar's `substituteTemplateDir` substring semantics (NOT the whole-element `{key}`).
    static func substituteTemplateDir(_ argv: [String], dir: String) -> [String] {
        guard !dir.isEmpty else { return argv }
        return argv.map { $0.replacingOccurrences(of: templateDirToken, with: dir) }
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

    /// (shared templates §1, pure) Build the effective template SEARCH PATH from the
    /// CONFIGURED dirs: the built-in `defaultTemplatesDir` is prepended FIRST, then each
    /// configured dir in order; each entry is `expandingTildeInPath` + `standardizingPath`,
    /// empties dropped, deduped by the standardized absolute path (order-preserving — first
    /// occurrence wins). This is the palette twin of
    /// `AgentManagerController.effectiveTemplateSearchPath(configured:defaultDir:)` — the two
    /// MUST agree (default-first, first-in-search-order wins, same dedup key), so this
    /// DELEGATES to that single authoritative implementation with `defaultTemplatesDir` as
    /// the default (both consts are the same string). This is not merely "kept in sync" —
    /// there is ONE implementation, so a one-sided edit is impossible. The `fileManager` is
    /// accepted for signature symmetry but unused (no filesystem access — pure expansion/
    /// standardization).
    static func effectiveSearchDirs(
        configured: [String],
        fileManager fm: FileManager = .default
    ) -> [String] {
        _ = fm
        return AgentManagerController.effectiveTemplateSearchPath(
            configured: configured, defaultDir: defaultTemplatesDir)
    }

    /// (shared templates §1, pure filesystem) Discover templates ACROSS the effective
    /// search path: iterate `dirs` in order, calling the single-dir primitive
    /// `discoverTemplates(dir:fileManager:)` for each, and merge by basename with
    /// FIRST-IN-SEARCH-ORDER WINS. Each kept entry records its WINNING source dir; a
    /// basename that also appears in a LATER dir is flagged `hasDuplicate == true` (so the
    /// palette can badge the winning dir). Sorted case-insensitively by displayName
    /// (basename tie-break), same as the single-dir version.
    static func discoverTemplates(
        dirs: [String],
        fileManager fm: FileManager = .default
    ) -> [QueueTemplateEntry] {
        var winners: [String: QueueTemplateEntry] = [:]  // basename -> winning entry
        var order: [String] = []                          // basename first-seen order
        var duplicated = Set<String>()                     // basenames seen in >1 dir
        for dir in dirs {
            for entry in discoverTemplates(dir: dir, fileManager: fm) {
                if winners[entry.basename] == nil {
                    winners[entry.basename] = entry
                    order.append(entry.basename)
                } else {
                    duplicated.insert(entry.basename)
                }
            }
        }

        let merged: [QueueTemplateEntry] = order.compactMap { base in
            guard let w = winners[base] else { return nil }
            guard duplicated.contains(base) else { return w }
            return QueueTemplateEntry(
                basename: w.basename,
                displayName: w.displayName,
                sourceDir: w.sourceDir,
                hasDuplicate: true)
        }

        return merged.sorted {
            let c = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if c != .orderedSame { return c == .orderedAscending }
            return $0.basename.localizedCaseInsensitiveCompare($1.basename) == .orderedAscending
        }
    }

    /// (testable, pure filesystem) Discover the queue templates under a SINGLE `dir`: every
    /// immediate child whose name ends in `.json` (case-insensitive), as a
    /// `QueueTemplateEntry` carrying both the `basename` (the `*.json` filename minus
    /// extension — the START command's `template` + the key for params/probe) AND the
    /// human `displayName` read from the template JSON's `name` field (so the palette
    /// shows e.g. "ExampleOS" rather than the file's "example"; falls back to the
    /// basename when the file has no `name`). The entry's `sourceDir` is `dir` (as passed);
    /// `hasDuplicate` is false (cross-dir shadowing is decided by the multi-dir merge).
    /// Deduped by basename; sorted case-insensitively by displayName (basename tie-break).
    /// `dir` is tilde-expanded; an unreadable dir yields an empty list. Hidden files
    /// are skipped. This is the per-dir PRIMITIVE the multi-dir `discoverTemplates(dirs:)`
    /// composes.
    static func discoverTemplates(
        dir: String,
        fileManager fm: FileManager = .default
    ) -> [QueueTemplateEntry] {
        let expanded = (dir as NSString).expandingTildeInPath
        guard let entries = try? fm.contentsOfDirectory(atPath: expanded) else { return [] }

        var seen = Set<String>()
        var out: [QueueTemplateEntry] = []
        for entry in entries {
            guard !entry.hasPrefix(".") else { continue }
            let ns = entry as NSString
            guard ns.pathExtension.lowercased() == "json" else { continue }
            let base = ns.deletingPathExtension
            guard !base.isEmpty, seen.insert(base).inserted else { continue }
            out.append(QueueTemplateEntry(
                basename: base,
                displayName: Self.templateDisplayName(dir: dir, basename: base, fileManager: fm),
                sourceDir: dir))
        }

        return out.sorted {
            let c = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if c != .orderedSame { return c == .orderedAscending }
            return $0.basename.localizedCaseInsensitiveCompare($1.basename) == .orderedAscending
        }
    }

    /// (testable, pure filesystem) A template's human DISPLAY name: the trimmed `name`
    /// field from its `<dir>/<basename>.json`, or the `basename` when the file is
    /// missing/unreadable, not an object, or has no non-empty `name`. `dir` is
    /// tilde-expanded here (same as the other readers).
    static func templateDisplayName(
        dir: String,
        basename: String,
        fileManager fm: FileManager = .default
    ) -> String {
        let expanded = (dir as NSString).expandingTildeInPath
        let path = (expanded as NSString).appendingPathComponent("\(basename).json")
        guard let data = fm.contents(atPath: path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = (obj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return basename }
        return name
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
            let isMax = (p["target"] as? String) == "maxItems"
            let rawValuesCommand = (p["valuesCommand"] as? [Any])?
                .compactMap { $0 as? String }
                .nonEmptyOrNil
            // (shared templates §2) Substitute `{templateDir}` = the resolved template dir
            // so a shared-repo template's sibling-script `valuesCommand` runs in the palette
            // suggestion probe (parity with the sidecar loader).
            let valuesCommand = rawValuesCommand.map { Self.substituteTemplateDir($0, dir: expanded) }
            out.append(QueueParamSpec(
                name: name,
                label: (p["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name,
                defaultValue: (p["default"] as? String) ?? "",
                required: (p["required"] as? Bool) ?? false,
                env: isMax ? nil : (p["env"] as? String),
                isMaxItems: isMax,
                valuesCommand: valuesCommand
            ))
        }
        return out
    }

    /// (preview, testable, pure filesystem) Read the `workdir` + `provider.list` bits a
    /// live preview needs from `<dir>/<basename>.json`. Returns nil when the file is
    /// missing/unreadable or has no usable list command — the form then omits the preview.
    static func templateProbe(
        dir: String,
        basename: String,
        fileManager fm: FileManager = .default
    ) -> QueueTemplateProbe? {
        let expanded = (dir as NSString).expandingTildeInPath
        let path = (expanded as NSString).appendingPathComponent("\(basename).json")
        guard let data = fm.contents(atPath: path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let workdir = (obj["workdir"] as? String), !workdir.isEmpty,
              let provider = obj["provider"] as? [String: Any],
              let list = provider["list"] as? [String: Any],
              let command = (list["command"] as? [Any])?.compactMap({ $0 as? String }).nonEmptyOrNil,
              let keyField = (list["keyField"] as? String), !keyField.isEmpty
        else { return nil }
        return QueueTemplateProbe(
            workdir: (workdir as NSString).expandingTildeInPath,
            // (shared templates §2) Substitute `{templateDir}` = the resolved template dir so
            // a shared-repo template's sibling-script `list` command runs in the live preview
            // probe (parity with the sidecar loader).
            listCommand: Self.substituteTemplateDir(command, dir: expanded),
            titleField: (list["titleField"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            keyField: keyField,
            templateDir: expanded
        )
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

// MARK: - Template discovery entry

/// One discovered queue template offered by the palette. The `basename` is the
/// `*.json` filename minus extension (the START command's `template`, and the key for
/// `templateParams`/`templateProbe`); the `displayName` is the template JSON's `name`
/// field (what the user sees), falling back to the basename when the file has no `name`.
struct QueueTemplateEntry: Equatable {
    let basename: String
    let displayName: String
    /// The search dir this entry was resolved from — the WINNING dir under multi-dir
    /// discovery (first-in-search-order), or the passed dir under the single-dir
    /// primitive. Params/probe/displayName are resolved against THIS dir.
    let sourceDir: String
    /// True when the SAME basename also exists in a LATER search dir (shadowed) — the
    /// palette badges the winning `sourceDir` so the choice isn't silently ambiguous.
    /// Always false from the single-dir primitive (cross-dir shadowing is a merge concern).
    let hasDuplicate: Bool

    init(
        basename: String,
        displayName: String,
        sourceDir: String = "",
        hasDuplicate: Bool = false
    ) {
        self.basename = basename
        self.displayName = displayName
        self.sourceDir = sourceDir
        self.hasDuplicate = hasDuplicate
    }
}

// MARK: - §8b start-time params: model + spec + form

/// (§8b) One start-time parameter to prompt for (the GUI-facing projection of the
/// template's `params` entry). Carries `env`/`isMaxItems` so the GUI can build the
/// provider env for the live preview / value suggestions, and `valuesCommand` (an
/// optional argv that prints suggested values for this field).
struct QueueParamSpec: Equatable {
    let name: String
    let label: String
    let defaultValue: String
    let required: Bool
    /// The env var an "env"-target param exports its value as (nil for maxItems). Needed
    /// so the GUI can reproduce the provider env when running the preview/suggestion probes.
    let env: String?
    /// True for a `target:"maxItems"` param (it tunes the engine; never goes to provider env).
    let isMaxItems: Bool
    /// Optional value-suggestion provider argv (see `QueueParam.valuesCommand`).
    let valuesCommand: [String]?

    init(
        name: String,
        label: String,
        defaultValue: String,
        required: Bool,
        env: String? = nil,
        isMaxItems: Bool = false,
        valuesCommand: [String]? = nil
    ) {
        self.name = name
        self.label = label
        self.defaultValue = defaultValue
        self.required = required
        self.env = env
        self.isMaxItems = isMaxItems
        self.valuesCommand = valuesCommand
    }
}

/// (preview) The bits of a template the GUI needs to run a live `list` PREVIEW from the
/// param form: the working dir + the list provider argv + its title/key field names.
struct QueueTemplateProbe: Equatable {
    /// The provider cwd (tilde-expanded to an absolute path).
    let workdir: String
    /// The `provider.list.command` argv (with `{templateDir}` already substituted).
    let listCommand: [String]
    /// Field on each emitted item to display (defaults to the keyField when absent).
    let titleField: String?
    /// The required dedup key field — used as the preview label when there is no title.
    let keyField: String
    /// (shared templates §2) The template's OWN resolved directory — exported as
    /// `GHOSTTY_QUEUE_TEMPLATE_DIR` into the preview probe env so a sibling script can find
    /// its neighbors (parity with the sidecar's `queueProviderEnv`). `""` when unknown.
    let templateDir: String

    init(
        workdir: String,
        listCommand: [String],
        titleField: String?,
        keyField: String,
        templateDir: String = ""
    ) {
        self.workdir = workdir
        self.listCommand = listCommand
        self.titleField = titleField
        self.keyField = keyField
        self.templateDir = templateDir
    }
}

/// (§8b) A pending param prompt: which template + the fields to fill + the optional
/// preview probe (list command + workdir) so the form can show a live success signal.
struct QueueParamPrompt: Equatable {
    /// The template BASENAME — what the START command carries (the sidecar loads by it).
    let template: String
    /// The template's human display name (its JSON `name`) — shown in the form title.
    let displayName: String
    /// (shared templates §2) The template's OWN resolved directory — exported as
    /// `GHOSTTY_QUEUE_TEMPLATE_DIR` into every probe env (list preview + each param
    /// `valuesCommand` suggestion) so sibling scripts resolve. `""` when unknown (probes
    /// then run without the var, back-compat).
    let templateDir: String
    let params: [QueueParamSpec]
    let probe: QueueTemplateProbe?

    init(
        template: String,
        displayName: String,
        templateDir: String = "",
        params: [QueueParamSpec],
        probe: QueueTemplateProbe?
    ) {
        self.template = template
        self.displayName = displayName
        self.templateDir = templateDir
        self.params = params
        self.probe = probe
    }
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
///
/// (UX) As fields change it runs two kinds of GUI-side probe (debounced, off-main, via
/// `QueueParamProber`): a live `list` PREVIEW (a success signal — how many items the
/// current values would queue, with a sample) and, for any param declaring a
/// `valuesCommand`, a SUGGESTIONS list the user can pick from instead of typing exact
/// names. Suggestions carry the current values as provider env, so a dependent one
/// (e.g. milestones for the chosen project) refreshes when its dependency changes.
struct QueueParamFormView: View {
    let prompt: QueueParamPrompt
    let backgroundColor: Color
    let onCancel: () -> Void
    let onStart: ([String: String]) -> Void

    @State private var values: [String: String]
    @StateObject private var prober: QueueParamProber

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
        _prober = StateObject(wrappedValue: QueueParamProber(prompt: prompt))
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
            Text("Start “\(prompt.displayName)”")
                .font(.headline)

            ForEach(prompt.params, id: \.name) { p in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(p.label)
                            .font(.subheadline)
                        if p.required {
                            Text("required").font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        suggestionControl(for: p)
                    }
                    TextField(p.defaultValue.isEmpty ? p.name : p.defaultValue, text: bindingFor(p.name))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if canStart { onStart(values) } }
                }
            }

            previewFooter

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
        .onAppear { prober.refresh(values: values) }
        .onChange(of: values) { newValues in prober.refresh(values: newValues) }
    }

    /// The per-field suggestions control: a spinner while a `valuesCommand` runs, else a
    /// small menu of the returned values (picking one fills the field). Hidden when the
    /// param has no `valuesCommand` or the command returned nothing.
    @ViewBuilder
    private func suggestionControl(for p: QueueParamSpec) -> some View {
        if p.valuesCommand != nil {
            if prober.loadingSuggestions.contains(p.name) {
                ProgressView().controlSize(.small)
            } else {
                let suggestions = prober.suggestions[p.name] ?? []
                if !suggestions.isEmpty {
                    Menu {
                        ForEach(suggestions) { s in
                            Button(s.label) { values[p.name] = s.value }
                        }
                    } label: {
                        Label("\(suggestions.count)", systemImage: "list.bullet")
                            .font(.caption2)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Pick a value (\(suggestions.count) available)")
                }
            }
        }
    }

    /// The live `list` preview footer — the success signal for the entered values.
    @ViewBuilder
    private var previewFooter: some View {
        switch prober.preview {
        case .unavailable:
            EmptyView()
        case .needsInput:
            Label("Fill the required fields to preview matching items.", systemImage: "ellipsis.circle")
                .font(.caption).foregroundColor(.secondary)
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking the queue…").font(.caption).foregroundColor(.secondary)
            }
        case .items(let total, let sample):
            VStack(alignment: .leading, spacing: 2) {
                Label("\(total) item\(total == 1 ? "" : "s") would be queued",
                      systemImage: "checkmark.circle")
                    .font(.caption).foregroundColor(.green)
                if !sample.isEmpty {
                    Text(sample.joined(separator: " · "))
                        .font(.caption2).foregroundColor(.secondary).lineLimit(2)
                }
            }
        case .empty:
            Label("No matching items — check the values above.", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundColor(.orange)
        case .failure(let msg):
            Label("Provider error: \(msg)", systemImage: "xmark.octagon")
                .font(.caption).foregroundColor(.red).lineLimit(2)
        }
    }

    private func bindingFor(_ name: String) -> Binding<String> {
        Binding(
            get: { values[name] ?? "" },
            set: { values[name] = $0 }
        )
    }
}

// MARK: - Param-form provider probes (live preview + value suggestions)

/// One suggested value for a param (a bare string, or a `{value,label}` object). `label`
/// is what the menu shows; `value` is what fills the field.
struct QueueSuggestion: Equatable, Identifiable {
    let value: String
    let label: String
    var id: String { "\(value)\u{1}\(label)" }
}

/// Runs the param form's GUI-side provider probes (live `list` preview + per-param
/// value suggestions) off the main thread, debounced, with a generation guard so a
/// stale in-flight result is discarded once newer field values supersede it. `@MainActor`
/// so its `@Published` state is mutated only on main; the blocking `Process` execs run on
/// a background queue and hop back.
@MainActor
final class QueueParamProber: ObservableObject {
    /// The live `list` preview state — the success signal for the entered values.
    enum PreviewState: Equatable {
        case unavailable                       // template has no usable list command
        case needsInput                        // required fields not yet filled
        case loading
        case items(total: Int, sample: [String])
        case empty
        case failure(String)
    }

    @Published var preview: PreviewState = .unavailable
    /// Suggested values per param name (from each param's `valuesCommand`).
    @Published var suggestions: [String: [QueueSuggestion]] = [:]
    /// Param names whose `valuesCommand` is currently running.
    @Published var loadingSuggestions: Set<String> = []

    private let params: [QueueParamSpec]
    private let probe: QueueTemplateProbe?
    private let cwd: String
    /// (shared templates §2) The template's resolved dir, overlaid as
    /// `GHOSTTY_QUEUE_TEMPLATE_DIR` on every probe env (parity with the sidecar).
    private let templateDir: String
    private var generation = 0
    private var pending: DispatchWorkItem?

    /// Debounce + per-probe timeout (ms). Generous because a values/list command may hit
    /// a remote API (e.g. Linear).
    private static let debounce: TimeInterval = 0.35
    private static let timeoutMs = 12_000

    init(prompt: QueueParamPrompt) {
        self.params = prompt.params
        self.probe = prompt.probe
        self.cwd = prompt.probe?.workdir ?? NSHomeDirectory()
        self.templateDir = prompt.templateDir
        if prompt.probe == nil { self.preview = .unavailable }
    }

    /// Schedule a probe run for the given values, coalescing rapid edits (debounce). The
    /// LATEST call within the debounce window wins.
    func refresh(values: [String: String]) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runProbes(values: values) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }

    private func runProbes(values: [String: String]) {
        generation += 1
        let gen = generation
        var env = QueueProviderProbe.providerEnv(params: params, values: values)
        // (shared templates §2) Export GHOSTTY_QUEUE_TEMPLATE_DIR so a sibling script invoked
        // by the list preview / a valuesCommand can find its neighbors (parity with the
        // sidecar's queueProviderEnv). Omitted when unknown (back-compat).
        if !templateDir.isEmpty { env["GHOSTTY_QUEUE_TEMPLATE_DIR"] = templateDir }

        // --- Preview: only when all REQUIRED params are filled (else the provider would
        // just error on a missing scope, which isn't a useful signal). ----------------
        if let probe = probe {
            if QueueParamFormView.canStart(params: params, values: values) {
                preview = .loading
                let cmd = probe.listCommand, dir = probe.workdir
                let titleField = probe.titleField, keyField = probe.keyField
                QueueProviderProbe.queue.async { [weak self] in
                    let result = QueueProviderProbe.run(
                        argv: cmd, cwd: dir, extraEnv: env, timeoutMs: Self.timeoutMs)
                    let state = QueueProviderProbe.previewState(
                        from: result, titleField: titleField, keyField: keyField)
                    DispatchQueue.main.async {
                        guard let self, self.generation == gen else { return }
                        self.preview = state
                    }
                }
            } else {
                preview = .needsInput
            }
        }

        // --- Suggestions: run every param's valuesCommand with the current env (so a
        // dependent one sees the other fields, e.g. milestones for the chosen project). -
        let cwd = self.cwd
        for p in params {
            guard let vc = p.valuesCommand else { continue }
            loadingSuggestions.insert(p.name)
            let name = p.name
            QueueProviderProbe.queue.async { [weak self] in
                let result = QueueProviderProbe.run(
                    argv: vc, cwd: cwd, extraEnv: env, timeoutMs: Self.timeoutMs)
                let parsed = QueueProviderProbe.suggestions(from: result)
                DispatchQueue.main.async {
                    guard let self, self.generation == gen else { return }
                    self.loadingSuggestions.remove(name)
                    // On success replace; on failure keep whatever we had (don't blank it).
                    if let parsed { self.suggestions[name] = parsed }
                }
            }
        }
    }
}

/// The outcome of running a provider probe: stdout bytes on a clean exit, or a short
/// error string (`String` can't be a `Result.Failure` — it isn't `Error` — so this is a
/// purpose-built two-case enum with the same `.success`/`.failure` shape).
enum QueueProbeOutcome: Equatable {
    case success(Data)
    case failure(String)
}

/// Pure-ish helpers to run a provider argv and parse its JSON for the param form. The
/// `run` exec BLOCKS (call it off-main); the parse helpers are pure + unit-tested.
enum QueueProviderProbe {
    /// Background queue for the blocking `Process` execs (concurrent — preview + each
    /// suggestion probe run independently; the prober's generation guard discards stale).
    static let queue = DispatchQueue(label: "com.mitchellh.ghostty.queueProbe", attributes: .concurrent)

    /// (pure, testable) Build the provider env from the current form values: each
    /// "env"-target param with a non-empty value → its env var. maxItems params and
    /// blank values are skipped (mirrors the sidecar's `resolveParamsEnv`).
    static func providerEnv(params: [QueueParamSpec], values: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for p in params {
            guard !p.isMaxItems, let env = p.env, !env.isEmpty else { continue }
            let v = (values[p.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { out[env] = v }
        }
        return out
    }

    /// (pure, testable) Parse a `valuesCommand` stdout into suggestions. Accepts a JSON
    /// array of bare strings (`["Acme","Globex"]`) or `{value,label?}` objects. Anything
    /// else (non-array, non-string/object element) yields no suggestions. Returns nil on
    /// a failed probe so the caller keeps the prior list rather than blanking it.
    static func suggestions(from result: QueueProbeOutcome) -> [QueueSuggestion]? {
        guard case .success(let data) = result else { return nil }
        return parseValues(data)
    }

    /// (pure, testable) The values-array parser (see `suggestions`).
    static func parseValues(_ data: Data) -> [QueueSuggestion] {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [] }
        var out: [QueueSuggestion] = []
        for el in arr {
            if let s = el as? String, !s.isEmpty {
                out.append(QueueSuggestion(value: s, label: s))
            } else if let o = el as? [String: Any], let v = o["value"] as? String, !v.isEmpty {
                let label = (o["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? v
                out.append(QueueSuggestion(value: v, label: label))
            }
        }
        return out
    }

    /// (pure, testable) Map a list-probe result into the form's preview state. A failed
    /// probe → `.failure`; unparseable stdout → `.failure`; an empty array → `.empty`;
    /// else `.items` with the total count + up to 6 sample titles (titleField, then
    /// keyField).
    static func previewState(
        from result: QueueProbeOutcome,
        titleField: String?,
        keyField: String,
        sampleLimit: Int = 6
    ) -> QueueParamProber.PreviewState {
        switch result {
        case .failure(let msg):
            return .failure(msg)
        case .success(let data):
            guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
                return .failure("unreadable list output")
            }
            if arr.isEmpty { return .empty }
            let sample: [String] = arr.prefix(sampleLimit).compactMap { el in
                guard let o = el as? [String: Any] else { return nil }
                if let tf = titleField, let t = o[tf] as? String, !t.isEmpty { return t }
                if let k = o[keyField] as? String, !k.isEmpty { return k }
                return nil
            }
            return .items(total: arr.count, sample: sample)
        }
    }

    /// Run a provider argv via `/usr/bin/env` (so a bare `python3`/`node` resolves on
    /// PATH), in `cwd`, with the inherited GUI env overlaid by `extraEnv`. BLOCKS until
    /// exit or the timeout (then terminates). Returns the stdout bytes on a clean exit, or
    /// a short error string (launch failure / non-zero exit's last stderr line). Call
    /// OFF the main thread.
    static func run(
        argv: [String],
        cwd: String,
        extraEnv: [String: String],
        timeoutMs: Int
    ) -> QueueProbeOutcome {
        guard !argv.isEmpty else { return .failure("empty command") }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = argv
        proc.currentDirectoryURL = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath)
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extraEnv { env[k] = v }
        proc.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
        } catch {
            return .failure("launch failed: \(error.localizedDescription)")
        }
        // Watchdog: terminate if it overruns the timeout (a hung/slow provider).
        let watchdog = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMs), execute: watchdog)
        // Read stdout to EOF BEFORE waiting, so a large output can't deadlock on a full pipe.
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        watchdog.cancel()
        if proc.terminationStatus != 0 {
            let err = String(
                data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let lastLine = err.split(separator: "\n").last.map(String.init) ?? ""
            let msg = lastLine.isEmpty ? "exit \(proc.terminationStatus)" : String(lastLine.prefix(140))
            return .failure(msg)
        }
        return .success(data)
    }
}

private extension Array {
    /// `nil` when empty, else `self` — for collapsing an empty parsed array to "absent".
    var nonEmptyOrNil: [Element]? { isEmpty ? nil : self }
}

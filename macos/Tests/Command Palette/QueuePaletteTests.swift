import Foundation
import Testing
@testable import Ghostty

/// (ramon fork / Agent Queue Supervisor) Unit tests for the queue-template
/// discovery on `QueuePaletteView` — the palette's only pure logic. Builds a real
/// temp tree and exercises `discoverTemplates`: the `.json` (case-insensitive)
/// filter, dotfile skip, basename extraction, dedup, and case-insensitive sort.
/// Mirrors the bar set by `ProjectPaletteTests.discoverProjectPaths`.
struct QueuePaletteTests {

    /// Builds an isolated temp directory and returns its URL; the caller removes it.
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-queue-palette-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func touch(_ url: URL) throws {
        try "{}".write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - discoverTemplates

    /// `.json` files become BASENAMEs (extension dropped); `.JSON` is accepted
    /// (case-insensitive); non-json files, hidden files, and directories are skipped;
    /// results are sorted case-insensitively.
    @Test func discoverFiltersSkipsAndSorts() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }

        try touch(base.appendingPathComponent("Backlog.json"))
        try touch(base.appendingPathComponent("alpha.JSON"))      // case-insensitive ext
        try touch(base.appendingPathComponent("notes.txt"))       // non-json, skipped
        try touch(base.appendingPathComponent(".hidden.json"))    // dotfile, skipped
        // A subdirectory named like a template must NOT be treated as one's content,
        // but discoverTemplates filters purely by name+extension, so a dir whose name
        // ends in .json WOULD list; use a dir name that doesn't, to keep intent clear.
        let sub = base.appendingPathComponent("subdir", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let entries = QueuePaletteView.discoverTemplates(dir: base.path)
        // Sorted case-insensitively: "alpha" before "Backlog". With no `name` field the
        // displayName falls back to the basename.
        #expect(entries.map(\.basename) == ["alpha", "Backlog"])
        #expect(entries.map(\.displayName) == ["alpha", "Backlog"])
    }

    /// The displayed name is the template JSON's `name` field (not the file basename), and
    /// the list is SORTED by that display name — so a "example.json" with `{"name":"ExampleOS"}`
    /// shows as "ExampleOS". A file with no `name` falls back to its basename.
    @Test func discoverUsesJSONNameForDisplayAndSort() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }

        try write(base.appendingPathComponent("example.json"), #"{ "name": "ExampleOS" }"#)
        try write(base.appendingPathComponent("zoo.json"), #"{ "name": "Aardvark" }"#)
        try touch(base.appendingPathComponent("plain.json"))   // no name → basename "plain"

        let entries = QueuePaletteView.discoverTemplates(dir: base.path)
        // Sorted by displayName: "Aardvark" (zoo) < "ExampleOS" (example) < "plain" (plain).
        #expect(entries.map(\.displayName) == ["Aardvark", "ExampleOS", "plain"])
        #expect(entries.map(\.basename) == ["zoo", "example", "plain"])
    }

    /// `templateDisplayName` reads the trimmed `name`; missing file / no `name` → basename.
    @Test func templateDisplayNameFallsBackToBasename() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        try write(base.appendingPathComponent("example.json"), #"{ "name": "  ExampleOS  " }"#)
        try write(base.appendingPathComponent("nameless.json"), #"{ "workdir": "/x" }"#)
        #expect(QueuePaletteView.templateDisplayName(dir: base.path, basename: "example") == "ExampleOS")
        #expect(QueuePaletteView.templateDisplayName(dir: base.path, basename: "nameless") == "nameless")
        #expect(QueuePaletteView.templateDisplayName(dir: base.path, basename: "missing") == "missing")
    }

    /// Two entries that collapse to the same basename (differing only in the `.json`
    /// extension case) are deduped to one.
    @Test func discoverDedupesSameBasename() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }

        try touch(base.appendingPathComponent("queue.json"))
        try touch(base.appendingPathComponent("queue.JSON"))

        let entries = QueuePaletteView.discoverTemplates(dir: base.path)
        #expect(entries.map(\.basename) == ["queue"])
    }

    /// An unreadable / absent directory yields an empty list (never throws).
    @Test func discoverSkipsUnreadableDir() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-no-such-queues-\(UUID().uuidString)")
        #expect(QueuePaletteView.discoverTemplates(dir: missing.path).isEmpty)
    }

    /// An empty directory yields an empty list.
    @Test func discoverEmptyDir() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(QueuePaletteView.discoverTemplates(dir: base.path).isEmpty)
    }

    // MARK: - templateParams (§8b)

    private func write(_ url: URL, _ json: String) throws {
        try json.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A template's `params` array is parsed: `name` required, `label` defaults to
    /// `name`, `default`/`required`/`env` carried (the GUI needs `env` to build the
    /// preview/suggestion provider env).
    @Test func templateParamsParsesDeclaredParams() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        try write(base.appendingPathComponent("example.json"), """
        { "name": "ExampleOS", "params": [
            { "name": "project", "env": "LINEAR_PROJECT", "label": "Project", "default": "Acme Foods", "required": true },
            { "name": "milestones", "env": "LINEAR_MILESTONES" }
        ] }
        """)
        let params = QueuePaletteView.templateParams(dir: base.path, basename: "example")
        #expect(params == [
            QueueParamSpec(name: "project", label: "Project", defaultValue: "Acme Foods", required: true, env: "LINEAR_PROJECT"),
            QueueParamSpec(name: "milestones", label: "milestones", defaultValue: "", required: false, env: "LINEAR_MILESTONES"),
        ])
    }

    /// `target:"maxItems"` (no env) and an optional `valuesCommand` are parsed onto the spec.
    @Test func templateParamsParsesTargetAndValuesCommand() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        try write(base.appendingPathComponent("example.json"), """
        { "name": "ExampleOS", "params": [
            { "name": "project", "env": "LINEAR_PROJECT", "valuesCommand": ["python3", "projects.py"] },
            { "name": "maxItems", "target": "maxItems", "default": "1" }
        ] }
        """)
        let params = QueuePaletteView.templateParams(dir: base.path, basename: "example")
        #expect(params == [
            QueueParamSpec(name: "project", label: "project", defaultValue: "", required: false,
                           env: "LINEAR_PROJECT", isMaxItems: false, valuesCommand: ["python3", "projects.py"]),
            QueueParamSpec(name: "maxItems", label: "maxItems", defaultValue: "1", required: false,
                           env: nil, isMaxItems: true, valuesCommand: nil),
        ])
    }

    // MARK: - templateProbe (preview)

    /// `templateProbe` reads workdir + provider.list bits; returns nil without a list command.
    @Test func templateProbeReadsListCommandOrNil() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        try write(base.appendingPathComponent("q.json"), """
        { "name": "Q", "workdir": "/tmp/repo",
          "provider": { "list": { "command": ["python3", "list.py"], "keyField": "identifier", "titleField": "title" } } }
        """)
        let probe = QueuePaletteView.templateProbe(dir: base.path, basename: "q")
        #expect(probe == QueueTemplateProbe(workdir: "/tmp/repo", listCommand: ["python3", "list.py"],
                                            titleField: "title", keyField: "identifier"))
        // No provider.list → nil.
        try write(base.appendingPathComponent("p.json"), #"{ "name": "P", "workdir": "/x" }"#)
        #expect(QueuePaletteView.templateProbe(dir: base.path, basename: "p") == nil)
    }

    // MARK: - QueueProviderProbe pure helpers

    /// providerEnv exports each non-blank "env"-target param under its env var; maxItems
    /// and blank values are skipped (mirrors the sidecar's resolveParamsEnv).
    @Test func providerEnvSkipsMaxItemsAndBlanks() {
        let params = [
            QueueParamSpec(name: "project", label: "p", defaultValue: "", required: true, env: "LINEAR_PROJECT"),
            QueueParamSpec(name: "ms", label: "m", defaultValue: "", required: false, env: "LINEAR_MILESTONES"),
            QueueParamSpec(name: "maxItems", label: "x", defaultValue: "1", required: false, env: nil, isMaxItems: true),
        ]
        let env = QueueProviderProbe.providerEnv(
            params: params, values: ["project": "Acme", "ms": "  ", "maxItems": "2"])
        #expect(env == ["LINEAR_PROJECT": "Acme"])  // blank ms + maxItems omitted
    }

    /// parseValues accepts bare strings and {value,label} objects; ignores garbage.
    @Test func parseValuesAcceptsStringsAndObjects() {
        let strings = Data(#"["Acme", "Globex", ""]"#.utf8)
        #expect(QueueProviderProbe.parseValues(strings) == [
            QueueSuggestion(value: "Acme", label: "Acme"),
            QueueSuggestion(value: "Globex", label: "Globex"),
        ])
        let objects = Data(#"[{"value":"v1","label":"One"}, {"value":"v2"}, {"label":"no value"}, 5]"#.utf8)
        #expect(QueueProviderProbe.parseValues(objects) == [
            QueueSuggestion(value: "v1", label: "One"),
            QueueSuggestion(value: "v2", label: "v2"),
        ])
        #expect(QueueProviderProbe.parseValues(Data("not json".utf8)).isEmpty)
        #expect(QueueProviderProbe.parseValues(Data(#"{"not":"array"}"#.utf8)).isEmpty)
    }

    /// previewState maps a probe result into the form's state.
    @Test func previewStateMapsResults() {
        // failure → .failure
        if case .failure(let m) = QueueProviderProbe.previewState(
            from: .failure("boom"), titleField: "title", keyField: "id") {
            #expect(m == "boom")
        } else { Issue.record("expected .failure") }
        // empty array → .empty
        #expect(QueueProviderProbe.previewState(
            from: .success(Data("[]".utf8)), titleField: "title", keyField: "id") == .empty)
        // unparseable → .failure
        if case .failure = QueueProviderProbe.previewState(
            from: .success(Data("nope".utf8)), titleField: "title", keyField: "id") {} else {
            Issue.record("expected .failure for unparseable")
        }
        // items: total + sampled titles (titleField, fallback keyField)
        let data = Data(#"[{"title":"First","id":"A"},{"id":"B"},{"title":"Third","id":"C"}]"#.utf8)
        #expect(QueueProviderProbe.previewState(from: .success(data), titleField: "title", keyField: "id")
                == .items(total: 3, sample: ["First", "B", "Third"]))
    }

    /// A template with no `params` (or a missing file) yields an empty list — the
    /// "start directly, no prompt" path.
    @Test func templateParamsEmptyWhenAbsentOrMissing() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        try write(base.appendingPathComponent("plain.json"), #"{ "name": "Plain" }"#)
        #expect(QueuePaletteView.templateParams(dir: base.path, basename: "plain").isEmpty)
        #expect(QueuePaletteView.templateParams(dir: base.path, basename: "nope").isEmpty)
    }

    // MARK: - QueueParamFormView.canStart (§8b)

    @Test func canStartRequiresNonBlankRequiredFields() {
        let params = [
            QueueParamSpec(name: "project", label: "Project", defaultValue: "", required: true),
            QueueParamSpec(name: "ms", label: "Milestones", defaultValue: "", required: false),
        ]
        #expect(!QueueParamFormView.canStart(params: params, values: [:]))
        #expect(!QueueParamFormView.canStart(params: params, values: ["project": "   "]))  // blank
        #expect(QueueParamFormView.canStart(params: params, values: ["project": "Acme"]))
        #expect(QueueParamFormView.canStart(params: params, values: ["project": "Acme", "ms": ""]))
    }

    // MARK: - QueueCommand wire shape carries params (§8b)

    @Test func startCommandEmitsParamsWhenPresent() {
        let cmd = QueueCommand(action: .start, template: "example", params: ["project": "Acme"])
        let json = cmd.jsonObject
        #expect(json["action"] as? String == "start")
        #expect(json["template"] as? String == "example")
        #expect((json["params"] as? [String: String]) == ["project": "Acme"])
    }

    @Test func startCommandOmitsEmptyOrNilParams() {
        #expect(QueueCommand(action: .start, template: "t", params: nil).jsonObject["params"] == nil)
        #expect(QueueCommand(action: .start, template: "t", params: [:]).jsonObject["params"] == nil)
    }
}

import Foundation

/// (ramon fork / suspend-resume) The per-suspended-split record needed to Resume an
/// idle agent split. Persisted in the SurfaceView restorable-state archive (see
/// `SurfaceView`'s Codable) so a suspended split survives a GUI restart as a
/// placeholder and resumes after it. See SUSPEND-RESUME-DESIGN.md.
struct SuspendManifest: Codable, Equatable {
    /// The agent's OWN session id — the `<pool> --resume <id>` token (from the Part-1
    /// hook capture). DISTINCT from the ghostty-host PTY session id.
    var claudeSessionId: String
    /// Working directory to respawn the fresh resume shell in (from the hook `cwd`).
    var cwd: String
    /// The detected agent kind: "claude" (MVP) or "codex" (postponed).
    var agentKind: String
    /// Split title at suspend time, for the placeholder label.
    var title: String
    /// The agent's last prompt, shown on the placeholder card as a reminder.
    var lastPrompt: String?
    /// When the split was suspended.
    var suspendedAt: Date

    /// The pool wrapper for this agent kind. MVP ships Claude; Codex is postponed but
    /// the mapping is here so a future Codex path is a one-line change.
    var poolCommand: String {
        agentKind == "codex" ? "codex-pool" : "claude-pool"
    }

    /// The exact line typed into the fresh resume shell (as `initialInput`), or nil if
    /// the captured session id is not a safe token. The id is GUARDED to a conservative
    /// charset (letters, digits, dash, underscore — Claude/Codex ids are uuid-ish) so it
    /// can never carry a shell metacharacter into the interactive shell. nil ⇒ do not
    /// attempt a resume (the caller keeps the placeholder).
    var resumeInputLine: String? {
        guard !claudeSessionId.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard claudeSessionId.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return "\(poolCommand) --resume \(claudeSessionId)\n"
    }
}

extension SuspendManifest {
    /// (ramon fork / suspend-resume) Parse a `--resume <id>` (claude) or `resume <id>` (codex)
    /// token from a split's foreground COMMAND line. This is the DEFINITIVE, per-process resume
    /// id for a RESUMED split — unambiguous even when many sessions share one cwd (where a
    /// transcript-by-mtime guess would mis-attribute). nil for a FRESH session (the id is minted
    /// internally and is NOT on the command line) — those must come from the hook capture (live or
    /// persisted); we deliberately never guess a fresh split's id.
    static func resumeId(fromCommand cmd: String) -> String? {
        let toks = cmd.split(separator: " ").map(String.init)
        guard let i = toks.firstIndex(where: { $0 == "--resume" || $0 == "resume" }),
              i + 1 < toks.count else { return nil }
        let id = toks[i + 1]
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard id.count >= 8, id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return id
    }
}

extension SuspendManifest {
    /// (ramon fork / suspend-resume) ONE-TIME re-attach seed. A build that predates resume-id
    /// persistence could suspend a split without ever recording its resume id (the id lived only
    /// in GUI memory), so after a relaunch the split came back as a dead pane with no way to
    /// Resume. This reads an operator-provided side table —
    /// `~/.config/ghostty-ramon/suspend-reattach-seed.json`, keyed by the split's STABLE surface
    /// UUID (which survives a relaunch in the window-state archive) — mapping each such dead leaf
    /// to its recovered resume manifest. The archive-decode restore path consults it ONLY for a
    /// surface with no archived manifest of its own, converting the dead leaf into a proper
    /// suspended placeholder with a working Resume button. Consumed once; the file is meant to be
    /// deleted after the splits are back. Fail-open: a missing/malformed file yields an empty map
    /// (normal restore, no behavior change).
    ///
    /// Schema: `{ "surfaces": { "<UUID>": { claudeSessionId, cwd, agentKind?, title? } } }`.
    /// Loaded once (cached) so repeated restore-decodes don't re-read disk.
    static let reattachSeed: [String: SuspendManifest] = loadReattachSeed(path: defaultReattachSeedPath)

    static var defaultReattachSeedPath: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent(".config/ghostty-ramon/suspend-reattach-seed.json")
    }

    /// Read + parse the seed file at `path`. Fail-open: any missing file / read / decode error
    /// yields `[:]`. Separated from `parseReattachSeed` so the parse is unit-testable without a
    /// filesystem.
    static func loadReattachSeed(path: String) -> [String: SuspendManifest] {
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        return parseReattachSeed(data)
    }

    /// One raw seed entry as authored in the JSON side table.
    private struct ReattachSeedEntry: Decodable {
        var claudeSessionId: String
        var cwd: String
        var agentKind: String?
        var title: String?
    }
    private struct ReattachSeedFile: Decodable { var surfaces: [String: ReattachSeedEntry] }

    /// PURE parse of the seed JSON → `[uppercased-UUID: manifest]`. Entries missing a session id
    /// or cwd are skipped (they could never resume safely). `agentKind` defaults to `"claude"`.
    static func parseReattachSeed(_ data: Data) -> [String: SuspendManifest] {
        guard let file = try? JSONDecoder().decode(ReattachSeedFile.self, from: data) else { return [:] }
        var out: [String: SuspendManifest] = [:]
        for (uuid, e) in file.surfaces {
            let key = uuid.uppercased()
            guard !key.isEmpty, !e.claudeSessionId.isEmpty, !e.cwd.isEmpty else { continue }
            out[key] = SuspendManifest(
                claudeSessionId: e.claudeSessionId,
                cwd: e.cwd,
                agentKind: e.agentKind ?? "claude",
                title: e.title ?? "",
                lastPrompt: nil,
                suspendedAt: Date())
        }
        return out
    }
}

/// (ramon fork / suspend-resume) GUI-only settings for the idle auto-suspend scanner,
/// persisted in `UserDefaults` — the same no-config-key approach the Agent Dashboard's
/// `agentDashboardPresentation` uses. OFF by default (opt-in). A ghostty-ramon
/// `suspend-idle*` config key is a documented follow-up (it would need a Zig
/// `Config.zig` change); UserDefaults keeps the MVP GUI-only.
enum SuspendSettings {
    private static let enabledKey = "suspendIdleEnabled"
    private static let thresholdKey = "suspendIdleBusinessDays"

    /// Master switch for the idle auto-suspend scanner. Default false.
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Business-days-idle threshold before an idle Claude split is auto-suspended.
    /// Default 2; a stored value < 1 (incl. the UserDefaults 0 default) reads as 2.
    static var businessDays: Int {
        let v = UserDefaults.standard.integer(forKey: thresholdKey)
        return v >= 1 ? v : 2
    }
}

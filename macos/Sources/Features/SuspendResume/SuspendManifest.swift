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

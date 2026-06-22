import Foundation

/// (ramon fork / Agent hooks) The agent's lifecycle state as reported by a
/// Claude Code hook. Authoritative for a hook-backed surface (mutes idleSeconds).
enum AgentState: String, Equatable, Sendable {
    case working   // UserPromptSubmit / PreToolUse / SessionStart
    case waiting   // Notification (agent is asking the user for input/approval)
    case idle      // Stop / SessionEnd
}

/// (ramon fork / Agent hooks) The parsed, validated hook event, carried as the
/// userInfo payload. PURE value type — safe across the serial-queue → main hop.
struct AgentStatePayload: Equatable, Sendable {
    let tty: String          // controlling tty as the hook saw it (raw, pre-normalize)
    let state: AgentState
    let prompt: String?      // UserPromptSubmit prompt text (truncated by the parser)
    let tool: String?        // PreToolUse tool name
    let message: String?     // Notification message (the "needs input" reason)
}

extension Notification.Name {
    /// Posted on MAIN by the MCP `/agent-state` handler after it resolves the
    /// hook's tty to a surface UUID. Observed by AgentDashboardModel.
    /// userInfo: [AgentStateUserInfoKey.surfaceID: UUID,
    ///            AgentStateUserInfoKey.payload: AgentStatePayload]
    static let ghosttyAgentStateDidChange =
        Notification.Name("com.mitchellh.ghostty.ghosttyAgentStateDidChange")

    /// Posted on MAIN by AgentDashboardModel when a surface ENTERS `.waiting`
    /// (transition into waiting only — not on every waiting republish). Observed
    /// by WebPushManager to fire a Web Push.
    /// userInfo: [AgentStateUserInfoKey.surfaceID: UUID,
    ///            AgentStateUserInfoKey.title: String,
    ///            AgentStateUserInfoKey.pwd: String,           // may be ""
    ///            AgentStateUserInfoKey.message: String]       // "" if none
    static let ghosttyAgentNeedsAttention =
        Notification.Name("com.mitchellh.ghostty.ghosttyAgentNeedsAttention")
}

/// userInfo keys for the two notifications above. String keys are intentionally
/// stable strings so a stale observer never silently misses a payload.
enum AgentStateUserInfoKey {
    static let surfaceID = "surfaceID"   // UUID
    static let payload   = "payload"     // AgentStatePayload
    static let title     = "title"       // String
    static let pwd        = "pwd"        // String
    static let message    = "message"    // String
}

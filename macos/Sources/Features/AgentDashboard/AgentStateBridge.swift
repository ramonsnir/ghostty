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

/// (ramon fork / Agent Manager) An LLM annotation for one surface, written by the
/// Agent Manager sidecar through the MCP `set_surface_annotation` tool and rendered
/// on the dashboard tile. PURE value type — safe across the MCP serial-queue →
/// main hop (the MCP handler builds it off-main, then posts it to main via
/// `.ghosttyAgentAnnotationDidChange`). Phase 0 renders only `summary`; the other
/// fields carry the manager's suggestion/phase/confidence for later phases.
struct AgentAnnotation: Equatable, Sendable {
    let summary: String      // one-line semantic status (the only field rendered in Phase 0)
    let suggestion: String?  // a suggested response for a waiting agent (Phase 2 UI)
    let phase: String?       // coarse phase label (e.g. "implementing", "testing")
    let needsUser: Bool      // the manager believes the user is needed
    let confidence: Double?  // 0..1 self-reported confidence, or nil if unstated
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

    /// (ramon fork / Agent Manager) Posted on MAIN by the MCP
    /// `set_surface_annotation` handler after it resolves the tool's `id` to a live
    /// surface UUID. Observed by AgentDashboardController, which stores the
    /// annotation on the model so the tile re-renders.
    /// userInfo: [AgentStateUserInfoKey.surfaceID: UUID,
    ///            AgentStateUserInfoKey.annotation: AgentAnnotation]
    static let ghosttyAgentAnnotationDidChange =
        Notification.Name("com.mitchellh.ghostty.ghosttyAgentAnnotationDidChange")
}

/// userInfo keys for the two notifications above. String keys are intentionally
/// stable strings so a stale observer never silently misses a payload.
enum AgentStateUserInfoKey {
    static let surfaceID = "surfaceID"   // UUID
    static let payload   = "payload"     // AgentStatePayload
    static let title     = "title"       // String
    static let pwd        = "pwd"        // String
    static let message    = "message"    // String
    static let annotation = "annotation" // AgentAnnotation
}

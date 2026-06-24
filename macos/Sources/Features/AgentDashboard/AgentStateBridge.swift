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

/// (ramon fork / Agent Manager) An LLM annotation for one surface, written through
/// the MCP `set_surface_annotation` tool and rendered on the dashboard tile. PURE
/// value type — safe across the MCP serial-queue → main hop (the MCP handler builds
/// it off-main, then posts it to main via `.ghosttyAgentAnnotationDidChange`).
///
/// Every field is OPTIONAL so a partial update can MERGE without clobbering: the
/// Haiku summarizer writes `summary` (+ phase/needsUser) and the Agent Queue
/// supervisor writes the queue tags (queueKey/queueName/queueUrl) INDEPENDENTLY into
/// the SAME stored annotation. `AgentAnnotationPayload.fromArguments` builds an
/// annotation carrying ONLY the provided fields; `merging(_:)` overlays the provided
/// (non-nil) fields onto the prior stored value (see `AgentDashboardModel.applyAnnotation`).
struct AgentAnnotation: Equatable, Sendable {
    let summary: String?     // one-line semantic status (Haiku summarizer)
    let phase: String?       // coarse phase label (e.g. "implementing", "testing")
    /// The summarizer believes the user is needed. OPTIONAL so a partial update that
    /// omits it does NOT reset a prior `true` to `false`; nil reads as "false" at
    /// the single tile render site.
    let needsUser: Bool?
    /// (ramon fork / Agent Queue, §8.5) The work-item dedup KEY tagging this surface
    /// as a queue tile. Written at dispatch (and re-stamped on reconcile when a GUI
    /// restart dropped the in-memory annotation map). Partial-merge, like the rest.
    let queueKey: String?
    /// (ramon fork / Agent Queue, §8.5) The owning run's NAME = the dashboard ORIGIN
    /// (§11). The dashboard derives the per-tile origin marker + grouping from this.
    let queueName: String?
    /// (ramon fork / Agent Queue, §8.5) The work-item URL for the dashboard's
    /// clickable origin badge.
    let queueUrl: String?

    init(
        summary: String? = nil,
        phase: String? = nil,
        needsUser: Bool? = nil,
        queueKey: String? = nil,
        queueName: String? = nil,
        queueUrl: String? = nil
    ) {
        self.summary = summary
        self.phase = phase
        self.needsUser = needsUser
        self.queueKey = queueKey
        self.queueName = queueName
        self.queueUrl = queueUrl
    }

    /// Overlay `other`'s PROVIDED (non-nil) fields onto `self`, keeping `self`'s
    /// value for every field `other` leaves nil. PURE + unit-tested. This is the
    /// merge that lets the summarizer and the Agent Queue supervisor update the same
    /// annotation independently: a summary-only update preserves a prior queue tag
    /// (and vice versa), and an update that omits `needsUser` preserves the prior flag.
    func merging(_ other: AgentAnnotation) -> AgentAnnotation {
        AgentAnnotation(
            summary: other.summary ?? summary,
            phase: other.phase ?? phase,
            needsUser: other.needsUser ?? needsUser,
            queueKey: other.queueKey ?? queueKey,
            queueName: other.queueName ?? queueName,
            queueUrl: other.queueUrl ?? queueUrl)
    }
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

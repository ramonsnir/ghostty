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
    /// (ramon fork / Agent Queue, keep) The split's KEEP verdict (effectiveKeep) the
    /// supervisor stamps each sweep: true ⇒ the queue will NOT auto-close this completed
    /// split (kept open for manual work); false ⇒ normal auto-close. Drives the dashboard
    /// 📌 pin's on/off state. OPTIONAL so a partial update that omits it preserves the prior
    /// value on merge; nil reads as "not kept" at the tile.
    let queueKeep: Bool?
    /// (ramon fork / Agent Queue, adopt) The Haiku-inferred work-item KEY suggestion for
    /// the adopt-modal's prefill, written by the sidecar's `infer_key` seam. Three states
    /// (load-bearing sentinel): nil ⇒ "no suggestion yet" (still inferring / never
    /// requested); "" (empty) ⇒ "the sidecar tried and inferred nothing" (definite
    /// negative); non-empty ⇒ the inferred key. Partial-merge like the rest — but BEWARE
    /// `merging` never NILS a field (see `clearingSuggestion()`), so the GUI clears a stale
    /// value directly at modal open rather than through `merging`.
    let queueKeySuggested: String?

    init(
        summary: String? = nil,
        phase: String? = nil,
        needsUser: Bool? = nil,
        queueKey: String? = nil,
        queueName: String? = nil,
        queueUrl: String? = nil,
        queueKeep: Bool? = nil,
        queueKeySuggested: String? = nil
    ) {
        self.summary = summary
        self.phase = phase
        self.needsUser = needsUser
        self.queueKey = queueKey
        self.queueName = queueName
        self.queueUrl = queueUrl
        self.queueKeep = queueKeep
        self.queueKeySuggested = queueKeySuggested
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
            queueUrl: other.queueUrl ?? queueUrl,
            queueKeep: other.queueKeep ?? queueKeep,
            queueKeySuggested: other.queueKeySuggested ?? queueKeySuggested)
    }

    /// (ramon fork / Agent Queue, adopt) A copy of `self` with `queueKeySuggested` reset
    /// to nil and EVERY other field preserved. This is the DELIBERATE bypass for
    /// `merging`'s never-nils asymmetry: an unrelated summarizer annotation omits
    /// `queueKeySuggested`, so `merging` would keep a STALE suggestion alive via `?? self`.
    /// The GUI overwrites `annotations[id]` with this (NOT via `merging`) when the adopt
    /// modal opens, so the modal starts from a clean nil and the next sidecar `infer_key`
    /// write is the only thing that can set the prefill. PURE.
    func clearingSuggestion() -> AgentAnnotation {
        AgentAnnotation(
            summary: summary, phase: phase, needsUser: needsUser,
            queueKey: queueKey, queueName: queueName, queueUrl: queueUrl,
            queueKeep: queueKeep, queueKeySuggested: nil)
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

    /// (ramon fork / Bell Attention) Posted on MAIN by the MCP `set_attention`
    /// handler after it resolves the tool's `id` to a live surface UUID. Observed by
    /// the SurfaceView for that id, which sets/clears its sticky `attentionNeeded`
    /// state (the loud Tier-2 treatment). This is DISTINCT from `.ghosttyBellDidRing`
    /// (a one-shot raw bell) — `set_attention` is a sticky state the sidecar promotes
    /// a bell into, cleared on focus.
    /// userInfo: [AgentStateUserInfoKey.surfaceID: UUID,
    ///            AgentStateUserInfoKey.attention: Bool,
    ///            AgentStateUserInfoKey.reason: String]   // "" if none
    static let ghosttyAttentionDidChange =
        Notification.Name("com.mitchellh.ghostty.ghosttyAttentionDidChange")
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
    static let attention  = "attention"  // Bool (ramon fork / Bell Attention)
    static let reason     = "reason"     // String (ramon fork / Bell Attention)
}

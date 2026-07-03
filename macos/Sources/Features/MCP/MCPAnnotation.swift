// (ramon fork / Agent Manager) The MCP `set_surface_annotation` tool: a PURE,
// unit-testable arguments parser (`AgentAnnotationPayload.fromArguments`) plus the
// side-effecting `MCPServer.applyAnnotation` handler that resolves the target
// surface on MAIN and posts `.ghosttyAgentAnnotationDidChange`.
//
// This is the Agent Manager sidecar's DISPLAY channel: the brain calls
// set_surface_annotation to write a one-line semantic status onto a dashboard
// tile. It mirrors the `/agent-state` ingest path exactly (parse purely off-main,
// hop to main only to confirm the surface exists, then post a notification the
// dashboard model observes) — MCPServer holds NO reference to the dashboard model.

import Foundation
import AppKit

/// PURE, unit-tested validation of the `set_surface_annotation` tool arguments.
/// The `id` argument is validated separately by `MCPTools.uuidArg`; this validates
/// the annotation BODY and builds a PARTIAL `AgentAnnotation` carrying ONLY the
/// provided fields (so the model can MERGE it onto the prior stored annotation
/// without clobbering — see `AgentDashboardModel.applyAnnotation`).
///
/// AT LEAST ONE updatable field (summary, phase, needsUser, queueKey, queueName,
/// queueUrl, keep, or hero) must be present, else the call is rejected (a fully-empty body is
/// invalid). The summarizer (summary-only) and the Agent Queue supervisor
/// (queueKey/queueName/queueUrl + the keep verdict at dispatch/restamp) both write
/// through this same parser.
struct AgentAnnotationPayload {
    let annotation: AgentAnnotation

    static func fromArguments(_ arguments: [String: Any]) -> AgentAnnotationPayload? {
        // Each string field: present-and-non-blank ⇒ trimmed value, else nil. A
        // non-string (e.g. a number) is treated as absent (nil), never coerced.
        func trimmedString(_ key: String) -> String? {
            (arguments[key] as? String).flatMap { s -> String? in
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
        }
        let summary = trimmedString("summary")
        let phase = trimmedString("phase")
        // needsUser is OPTIONAL: present-as-bool ⇒ that bool; absent or non-bool ⇒
        // nil (so a partial update omitting it leaves the prior value on merge).
        let needsUser = arguments["needsUser"] as? Bool
        // (ramon fork / Agent Queue, §8.5) the queue tag fields — same partial-merge
        // string semantics as summary (present-and-non-blank ⇒ trimmed).
        let queueKey = trimmedString("queueKey")
        let queueName = trimmedString("queueName")
        let queueUrl = trimmedString("queueUrl")
        // (keep) the split's keep verdict — present-as-bool ⇒ that bool; absent/non-bool ⇒
        // nil (so a partial update omitting it preserves the prior value on merge).
        let queueKeep = arguments["keep"] as? Bool
        // (ramon fork / Hero Agents) the split's hero verdict — present-as-bool ⇒ that bool;
        // absent/non-bool ⇒ nil (so a partial update omitting it preserves the prior value on
        // merge). Same partial-merge Bool semantics as `keep`.
        let queueHero = arguments["hero"] as? Bool
        // (adopt) the Haiku-inferred key suggestion. UNLIKE the other strings, an EMPTY
        // string is KEPT (NOT trimmed-to-nil): "" is the load-bearing "inferred nothing"
        // sentinel distinct from absent ("no suggestion yet"). Present-as-string ⇒ that
        // value verbatim (incl. ""); absent/non-string ⇒ nil.
        let queueKeySuggested = arguments["queueKeySuggested"] as? String

        // At least one updatable field must be present; otherwise the update is a
        // no-op and we reject it (mirrors the old "blank summary" rejection but for
        // an entirely empty body).
        guard summary != nil || phase != nil
            || needsUser != nil
            || queueKey != nil || queueName != nil || queueUrl != nil
            || queueKeep != nil
            || queueKeySuggested != nil
            || queueHero != nil
        else { return nil }

        return AgentAnnotationPayload(annotation: AgentAnnotation(
            summary: summary, phase: phase, needsUser: needsUser,
            queueKey: queueKey, queueName: queueName, queueUrl: queueUrl,
            queueKeep: queueKeep, queueKeySuggested: queueKeySuggested,
            queueHero: queueHero))
    }
}

extension MCPServer {
    /// Resolve `uuid` to a live surface on MAIN (value-types-only across the hop —
    /// never a SurfaceView), and if it exists post `.ghosttyAgentAnnotationDidChange`
    /// so the dashboard model can store the annotation and re-render the tile.
    /// Returns true iff the surface exists; false ⇒ the tool reports an unknown id.
    /// Mirrors `handleAgentState`'s resolve-on-main + post-on-main shape.
    func applyAnnotation(uuid: UUID, annotation: AgentAnnotation) -> Bool {
        // (ramon fork / Agent Queue latency) Resolve AND deliver SYNCHRONOUSLY on main, so the
        // annotation is applied to the dashboard model BEFORE this call returns. Load-bearing for
        // adopt latency: the sidecar `await`s set_surface_annotation and then, in the SAME sweep,
        // calls list_surfaces — which reads queueKey/queueName off the dashboard model's
        // hookSnapshot(). Delivering synchronously (the post below runs INSIDE this main.sync, and
        // NotificationCenter delivers to observers inline on the posting thread, so the observer's
        // `model.applyAnnotation` runs before we return — see `subscribeAnnotation`, which drops
        // `receive(on:)` precisely so this stays synchronous) guarantees that same-sweep
        // list_surfaces sees the fresh tags, so reconcile folds an adopted split into `run.active`
        // THIS sweep instead of on a later poll (the eliminated adopt "next round"). The prior
        // `main.async` post landed the write a main-thread turn LATER — after the same-sweep
        // snapshot was already taken — which is exactly what deferred adopt tracking by a sweep.
        return DispatchQueue.main.sync {
            guard MCPLayout.surface(forUUID: uuid) != nil else { return false }
            NotificationCenter.default.post(
                name: .ghosttyAgentAnnotationDidChange, object: nil,
                userInfo: [AgentStateUserInfoKey.surfaceID: uuid,
                           AgentStateUserInfoKey.annotation: annotation])
            return true
        }
    }

    /// (ramon fork / Bell Attention) Resolve `uuid` on MAIN and, if it exists, post
    /// `.ghosttyAttentionDidChange` so the target SurfaceView sets/clears its sticky
    /// `attentionNeeded` state (the loud Tier-2 treatment). The sidecar's bell pass
    /// calls this with `on:true` when Haiku promotes a bell; the GUI clears it on
    /// focus. Same resolve-on-main + post-on-main shape as `applyAnnotation`.
    func setAttention(uuid: UUID, on: Bool, reason: String) -> Bool {
        // Capture title/pwd as VALUE TYPES on the main hop (never a SurfaceView across
        // the hop) so the push observer can render a notification without a view ref.
        let info: (title: String, pwd: String)? = DispatchQueue.main.sync {
            guard let v = MCPLayout.surface(forUUID: uuid) else { return nil }
            return (v.title, v.pwd ?? "")
        }
        guard let info else { return false }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .ghosttyAttentionDidChange, object: nil,
                userInfo: [AgentStateUserInfoKey.surfaceID: uuid,
                           AgentStateUserInfoKey.attention: on,
                           AgentStateUserInfoKey.reason: reason,
                           AgentStateUserInfoKey.title: info.title,
                           AgentStateUserInfoKey.pwd: info.pwd])
        }
        return true
    }
}

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
/// (ramon fork / Agent Manager Phase 2) `summary` is no longer hard-required:
/// AT LEAST ONE updatable field (summary, suggestion, phase, needsUser, or
/// confidence) must be present, else the call is rejected (a fully-empty body is
/// still invalid). Both the summarizer (summary-only) and the manager
/// (suggestion-only) write through this same parser.
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
        let suggestion = trimmedString("suggestion")
        let phase = trimmedString("phase")
        // needsUser is OPTIONAL: present-as-bool ⇒ that bool; absent or non-bool ⇒
        // nil (so a partial update omitting it leaves the prior value on merge).
        let needsUser = arguments["needsUser"] as? Bool
        // confidence is a JSON number → NSNumber; missing/non-number ⇒ nil.
        let confidence = (arguments["confidence"] as? NSNumber)?.doubleValue

        // At least one updatable field must be present; otherwise the update is a
        // no-op and we reject it (mirrors the old "blank summary" rejection but for
        // an entirely empty body).
        guard summary != nil || suggestion != nil || phase != nil
            || needsUser != nil || confidence != nil
        else { return nil }

        return AgentAnnotationPayload(annotation: AgentAnnotation(
            summary: summary, suggestion: suggestion, phase: phase,
            needsUser: needsUser, confidence: confidence))
    }
}

extension MCPServer {
    /// Resolve `uuid` to a live surface on MAIN (value-types-only across the hop —
    /// never a SurfaceView), and if it exists post `.ghosttyAgentAnnotationDidChange`
    /// so the dashboard model can store the annotation and re-render the tile.
    /// Returns true iff the surface exists; false ⇒ the tool reports an unknown id.
    /// Mirrors `handleAgentState`'s resolve-on-main + post-on-main shape.
    func applyAnnotation(uuid: UUID, annotation: AgentAnnotation) -> Bool {
        let exists = DispatchQueue.main.sync {
            MCPLayout.surface(forUUID: uuid) != nil
        }
        guard exists else { return false }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .ghosttyAgentAnnotationDidChange, object: nil,
                userInfo: [AgentStateUserInfoKey.surfaceID: uuid,
                           AgentStateUserInfoKey.annotation: annotation])
        }
        return true
    }
}

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
/// the annotation BODY (a non-empty `summary` is required; the rest are optional)
/// and builds the shared `AgentAnnotation` value type. Returns nil only when
/// `summary` is missing or blank.
struct AgentAnnotationPayload {
    let annotation: AgentAnnotation

    static func fromArguments(_ arguments: [String: Any]) -> AgentAnnotationPayload? {
        guard let summaryRaw = arguments["summary"] as? String else { return nil }
        let summary = summaryRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return nil }

        let suggestion = (arguments["suggestion"] as? String).flatMap { s -> String? in
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let phase = (arguments["phase"] as? String).flatMap { s -> String? in
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let needsUser = (arguments["needsUser"] as? Bool) ?? false
        // confidence is a JSON number → NSNumber; missing/non-number ⇒ nil.
        let confidence = (arguments["confidence"] as? NSNumber)?.doubleValue

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

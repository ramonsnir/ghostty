// (ramon fork / Agent Manager) PURE safety helpers for the manager's reply path.
//
// `isDestructiveReply(_:screen:)` is the Phase-3 AUTO-APPLY gate (design §7.3): it
// flags a proposed reply that would auto-approve a DANGEROUS confirmation, so an
// autonomous send can be downgraded to suggest-only. It is implemented + fully
// unit-tested NOW, but is DELIBERATELY UNUSED in Phase 2 — Phase 2 is suggest-only
// and the only send path is the user tapping Approve in the tile (a human tap is
// the authorization, so this gate does NOT run on it). It lives here, beside the
// MCP boundary where the Phase-3 `agent_manager_respond` tool will enforce it.

import Foundation

enum MCPSafety {
    /// Patterns of DANGEROUS commands/contexts that an affirmative reply must never
    /// auto-approve. Matched case-insensitively against the visible screen (the
    /// prompt the agent is asking about). Kept conservative + explicit — a false
    /// positive just downgrades to suggest-only (safe), a false negative is the
    /// thing we must avoid. PURE/static so the list is testable + auditable.
    static let dangerousScreenPatterns: [String] = [
        "rm -rf",
        "rm -fr",
        "git push --force",
        "git push -f",
        "force push",
        "force-push",
        "git reset --hard",
        "drop table",
        "drop database",
        "truncate table",
        "delete from",
        "deleting",        // catches "Deleting N files?" style confirmations
        "permanently delete",
        "permanent deletion",
        "overwrite",
        "format disk",
        "mkfs",
        "dd if=",
        "payment",
        "charge",
        "purchase",
        "credit card",
        "wire transfer",
        "irreversible",
        "cannot be undone",
        "this action is destructive",
    ]

    /// An affirmative reply is one that, sent verbatim, would ANSWER YES to a
    /// yes/no confirmation. PURE. Only short, unambiguous affirmations count — a
    /// longer free-text reply that merely contains "yes" is NOT treated as a bare
    /// affirmation (it is a considered instruction, not a one-key approval).
    static func isAffirmativeReply(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Strip a single trailing punctuation char (e.g. "yes!", "y.").
        let stripped = t.last.map { ".!,;: ".contains($0) ? String(t.dropLast()) : t } ?? t
        let affirmatives: Set<String> = [
            "y", "yes", "yeah", "yep", "yup", "ok", "okay", "sure",
            "do it", "go", "go ahead", "approve", "approved", "confirm",
            "confirmed", "proceed", "1", "accept",
        ]
        return affirmatives.contains(stripped)
    }

    /// True when auto-applying `reply` against the current `screen` would risk
    /// approving a destructive action — i.e. the reply is a bare AFFIRMATION AND
    /// the visible screen mentions a dangerous command/context. PURE. Phase-3 gate
    /// only; UNUSED in Phase 2 (the user-tapped Approve bypasses it — a human is
    /// the authorization).
    ///
    /// Decision: an affirmation near danger is destructive; a NON-affirmative reply
    /// (a typed-out instruction) is never flagged here even over a dangerous screen
    /// (it is not a one-key approval), and an affirmation over an innocuous screen
    /// is fine. This keeps the gate targeted at the actual hazard — auto-confirming
    /// a dangerous y/N — without blocking ordinary replies.
    static func isDestructiveReply(_ reply: String, screen: String) -> Bool {
        guard isAffirmativeReply(reply) else { return false }
        let lower = screen.lowercased()
        return dangerousScreenPatterns.contains { lower.contains($0) }
    }
}

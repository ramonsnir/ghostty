import Foundation

/// (ramon fork / suspend-resume) PURE, unit-testable policy for deciding when an idle agent
/// split is overdue for suspension. Nothing here touches AppKit, the model, or the wall clock:
/// `now` and `calendar` are injected so the business-day math is deterministic in tests. The
/// side-effecting scanner (a timer on `AgentDashboardController` that calls the suspend action)
/// consumes this. Covers Claude AND Codex (both capture a resume id via their agent-state hook;
/// the pool wrapper differs — see `SuspendManifest.poolCommand`). See SUSPEND-RESUME-DESIGN.md →
/// "Part 2 — Idle scanner".
enum SuspendPolicy {

    /// The agent kinds the idle scanner is allowed to auto-suspend. Both capture a
    /// per-process resume id through their agent-state hook (Claude's `session_id` →
    /// `claude-pool --resume`, Codex's `session_id` → `codex-pool --resume`), so both
    /// can be resumed. A kind NOT in this set (a plain shell, an unknown agent) is never
    /// auto-suspended. Manual `suspend_split` is separately gated on a captured resume id.
    static let suspendableKinds: Set<String> = ["claude", "codex"]

    /// The number of BUSINESS days (weekdays; weekends skipped) elapsed between `from` and `to`,
    /// at calendar-day granularity: the count of weekday dates `d` with
    /// `startOfDay(from) < startOfDay(d) <= startOfDay(to)`.
    ///
    /// Returns 0 when `to <= from` (same day, or backwards clock skew). Weekend membership is the
    /// calendar's own (`isDateInWeekend`), so a Gregorian/en_US calendar skips Sat/Sun. Using
    /// `startOfDay` (not raw 24h arithmetic) makes it DST-correct — a 23h or 25h civil day still
    /// counts as one day boundary. Iterates day-by-day because ranges here are days-to-weeks;
    /// a `guardHops` cap keeps a pathological far-future `to` from spinning.
    ///
    /// Worked examples (Gregorian, Sat/Sun weekend):
    ///   - same day → 0; Mon→Tue → 1; Mon→Wed → 2
    ///   - Fri→Sat → 0, Fri→Sun → 0, Fri→Mon → 1, Fri→Tue → 2 (a Friday-idle split first
    ///     reaches the default threshold of 2 on the following TUESDAY)
    ///   - Fri→next Fri → 5
    static func businessDaysElapsed(from: Date, to: Date, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: from)
        let end = calendar.startOfDay(for: to)
        guard end > start else { return 0 }
        var count = 0
        var day = start
        var guardHops = 0
        while day < end && guardHops < 100_000 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
            guardHops += 1
            if !calendar.isDateInWeekend(day) { count += 1 }
        }
        return count
    }

    /// True iff a split last active at `lastActivity` has been idle for at least
    /// `thresholdBusinessDays` business days as of `now`. A threshold <= 0 makes this always true,
    /// so the caller must gate on a sane threshold (the config default is 2).
    static func isIdleOverdue(
        lastActivity: Date, now: Date, thresholdBusinessDays: Int, calendar: Calendar = .current
    ) -> Bool {
        businessDaysElapsed(from: lastActivity, to: now, calendar: calendar) >= thresholdBusinessDays
    }

    /// One split the scanner considers for suspension. A value snapshot so the selection is pure.
    struct Candidate: Equatable {
        let id: UUID
        let agentKind: String?   // "claude" / "codex" / nil (detector's command basename)
        let isIdle: Bool         // the hook-reported agentState is `.idle`
        let lastActivity: Date   // when the split's content last changed / last hook event
    }

    /// PURE selection: the ids overdue for suspension — a SUSPENDABLE agent kind (Claude or
    /// Codex, see `suspendableKinds`), currently idle, last active at least
    /// `thresholdBusinessDays` business days ago. Order is preserved from `candidates`.
    static func surfacesToSuspend(
        _ candidates: [Candidate], now: Date, thresholdBusinessDays: Int, calendar: Calendar = .current
    ) -> [UUID] {
        candidates.compactMap { c in
            guard let kind = c.agentKind, suspendableKinds.contains(kind), c.isIdle,
                  isIdleOverdue(
                    lastActivity: c.lastActivity, now: now,
                    thresholdBusinessDays: thresholdBusinessDays, calendar: calendar)
            else { return nil }
            return c.id
        }
    }
}

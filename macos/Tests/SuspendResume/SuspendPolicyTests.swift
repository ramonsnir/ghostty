import Foundation
import Testing
@testable import Ghostty

/// (ramon fork / suspend-resume) Unit tests for the PURE business-day / idle-overdue policy.
/// A fixed Gregorian en_US calendar in a fixed timezone makes the day math deterministic.
/// Real anchor dates (Sep 2026): 09-11 = Fri, 09-12 = Sat, 09-13 = Sun, 09-14 = Mon,
/// 09-15 = Tue, 09-16 = Wed, 09-17 = Thu, 09-18 = Fri.
struct SuspendPolicyTests {

    private func cal(_ tz: String = "America/New_York") -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        c.locale = Locale(identifier: "en_US")   // weekend = Sat/Sun
        return c
    }

    /// Build a local date in the test calendar's timezone.
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, cal c: Calendar) -> Date {
        var dc = DateComponents()
        dc.year = y; dc.month = m; dc.day = d; dc.hour = h
        return c.date(from: dc)!
    }

    // MARK: - businessDaysElapsed

    @Test func sameDayIsZero() {
        let c = cal()
        #expect(SuspendPolicy.businessDaysElapsed(
            from: date(2026, 9, 14, 9, cal: c), to: date(2026, 9, 14, 17, cal: c), calendar: c) == 0)
    }

    @Test func consecutiveWeekdays() {
        let c = cal()
        #expect(SuspendPolicy.businessDaysElapsed(
            from: date(2026, 9, 14, cal: c), to: date(2026, 9, 15, cal: c), calendar: c) == 1) // Mon→Tue
        #expect(SuspendPolicy.businessDaysElapsed(
            from: date(2026, 9, 14, cal: c), to: date(2026, 9, 16, cal: c), calendar: c) == 2) // Mon→Wed
    }

    @Test func weekendIsSkipped() {
        let c = cal()
        // From a Friday:
        #expect(SuspendPolicy.businessDaysElapsed(
            from: date(2026, 9, 11, cal: c), to: date(2026, 9, 12, cal: c), calendar: c) == 0) // →Sat
        #expect(SuspendPolicy.businessDaysElapsed(
            from: date(2026, 9, 11, cal: c), to: date(2026, 9, 13, cal: c), calendar: c) == 0) // →Sun
        #expect(SuspendPolicy.businessDaysElapsed(
            from: date(2026, 9, 11, cal: c), to: date(2026, 9, 14, cal: c), calendar: c) == 1) // →Mon
        #expect(SuspendPolicy.businessDaysElapsed(
            from: date(2026, 9, 11, cal: c), to: date(2026, 9, 15, cal: c), calendar: c) == 2) // →Tue
    }

    @Test func fullWeekIsFiveBusinessDays() {
        let c = cal()
        #expect(SuspendPolicy.businessDaysElapsed(
            from: date(2026, 9, 11, cal: c), to: date(2026, 9, 18, cal: c), calendar: c) == 5) // Fri→Fri
    }

    @Test func backwardsClockSkewIsZero() {
        let c = cal()
        #expect(SuspendPolicy.businessDaysElapsed(
            from: date(2026, 9, 16, cal: c), to: date(2026, 9, 14, cal: c), calendar: c) == 0)
    }

    @Test func dstTransitionCountsCivilDays() {
        // US DST ends Sun 2026-11-01 in America/New_York (a 25-hour civil day). startOfDay math
        // must still count one boundary per civil day: Fri 10-30 → Mon 11-02 skips Sat/Sun = 1.
        let c = cal("America/New_York")
        #expect(SuspendPolicy.businessDaysElapsed(
            from: date(2026, 10, 30, cal: c), to: date(2026, 11, 2, cal: c), calendar: c) == 1)
    }

    // MARK: - isIdleOverdue

    @Test func overdueAtThreshold() {
        let c = cal()
        let friday = date(2026, 9, 11, 15, cal: c)
        // Monday = 1 business day → not overdue at threshold 2; Tuesday = 2 → overdue.
        #expect(!SuspendPolicy.isIdleOverdue(
            lastActivity: friday, now: date(2026, 9, 14, 9, cal: c), thresholdBusinessDays: 2, calendar: c))
        #expect(SuspendPolicy.isIdleOverdue(
            lastActivity: friday, now: date(2026, 9, 15, 9, cal: c), thresholdBusinessDays: 2, calendar: c))
    }

    // MARK: - surfacesToSuspend

    @Test func selectionFiltersKindStateAndAge() {
        let c = cal()
        let now = date(2026, 9, 16, 9, cal: c) // Wednesday
        let old = date(2026, 9, 11, cal: c)    // Friday → 2 business days by Wed (Mon,Tue... +Wed = 3)
        let recent = date(2026, 9, 15, cal: c) // Tuesday → 1 business day by Wed
        let claudeIdleOld = UUID()
        let claudeIdleRecent = UUID()
        let claudeWorkingOld = UUID()
        let codexIdleOld = UUID()
        let shellIdleOld = UUID()
        let candidates: [SuspendPolicy.Candidate] = [
            .init(id: claudeIdleOld,     agentKind: "claude", isIdle: true,  lastActivity: old),
            .init(id: claudeIdleRecent,  agentKind: "claude", isIdle: true,  lastActivity: recent),
            .init(id: claudeWorkingOld,  agentKind: "claude", isIdle: false, lastActivity: old),
            .init(id: codexIdleOld,      agentKind: "codex",  isIdle: true,  lastActivity: old),
            .init(id: shellIdleOld,      agentKind: nil,      isIdle: true,  lastActivity: old),
        ]
        let picked = SuspendPolicy.surfacesToSuspend(candidates, now: now, thresholdBusinessDays: 2, calendar: c)
        // Both the idle, old-enough CLAUDE and CODEX splits, in candidate order. The
        // idle-but-recent claude, the working claude, and the plain shell are excluded.
        #expect(picked == [claudeIdleOld, codexIdleOld])
    }

    @Test func selectionExcludesUnknownAndWorkingKinds() {
        let c = cal()
        let now = date(2026, 9, 16, 9, cal: c) // Wednesday
        let old = date(2026, 9, 11, cal: c)    // Friday
        let codexWorking = UUID()
        let unknownIdle = UUID()
        let candidates: [SuspendPolicy.Candidate] = [
            .init(id: codexWorking, agentKind: "codex",  isIdle: false, lastActivity: old),
            .init(id: unknownIdle,  agentKind: "gemini", isIdle: true,  lastActivity: old),
        ]
        let picked = SuspendPolicy.surfacesToSuspend(candidates, now: now, thresholdBusinessDays: 2, calendar: c)
        #expect(picked.isEmpty) // a working codex and an unknown-kind idle are both skipped
    }
}

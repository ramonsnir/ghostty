@testable import Ghostty
import Testing
import Foundation

struct CachedValueTests {
    /// Basic caching: the value is fetched once and reused within the duration.
    @Test func cachesWithinDuration() {
        var fetchCount = 0
        let cached = CachedValue<String>(duration: .seconds(60)) {
            fetchCount += 1
            return "value-\(fetchCount)"
        }

        #expect(cached.get() == "value-1")
        #expect(cached.get() == "value-1")
        #expect(fetchCount == 1)
    }

    /// Refetches after the cached value expires.
    @Test func refetchesAfterExpiry() async throws {
        var fetchCount = 0
        let cached = CachedValue<String>(duration: .milliseconds(20)) {
            fetchCount += 1
            return "value-\(fetchCount)"
        }

        #expect(cached.get() == "value-1")
        // The expiry clear runs on a BACKGROUND executor, so under load it can be scheduled
        // well after the nominal 20ms — and this very suite also runs the 20k-iteration
        // `concurrentGetAndExpiryDoesNotRace` stress test, which saturates every core while
        // Swift Testing runs cases in parallel. A fixed 80ms margin therefore flaked
        // repeatedly in FULL-suite runs while passing in isolation (a false alarm that cost
        // three gate cycles). POLL up to a generous ceiling instead: still fast when idle,
        // but tolerant when the machine is busy. Each `get()` either returns the still-cached
        // value or triggers the refetch, so observing "value-2" is the real assertion.
        var value = cached.get()
        let deadline = Date().addingTimeInterval(5)
        while value == "value-1", Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
            value = cached.get()
        }
        #expect(value == "value-2")
    }

    /// Regression: `get()` runs on AppKit's accessibility thread (off the main thread)
    /// while the expiry `Task` clears the value from a background executor. Before the
    /// lock was added, those two threads raced on the stored value's refcount and the
    /// Swift runtime aborted (SIGABRT). Hammer `get()` from many threads with a tiny
    /// expiry so fills and clears interleave heavily; on the unfixed code this crashes,
    /// on the fixed code it returns a fresh heap-backed string every time without a fault.
    @Test func concurrentGetAndExpiryDoesNotRace() {
        let cached = CachedValue<String>(duration: .microseconds(50)) {
            // Return a fresh, heap-backed (non-small) string so each fill/clear
            // exercises real reference counting — the thing the race corrupted.
            "content-\(UUID().uuidString)-padding-to-force-heap-storage"
        }

        DispatchQueue.concurrentPerform(iterations: 20_000) { _ in
            let v = cached.get()
            #expect(v.hasPrefix("content-"))
        }
    }
}

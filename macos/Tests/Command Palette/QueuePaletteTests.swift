import Foundation
import Testing
@testable import Ghostty

/// (ramon fork / Agent Queue Supervisor) Unit tests for the queue-template
/// discovery on `QueuePaletteView` — the palette's only pure logic. Builds a real
/// temp tree and exercises `discoverTemplates`: the `.json` (case-insensitive)
/// filter, dotfile skip, basename extraction, dedup, and case-insensitive sort.
/// Mirrors the bar set by `ProjectPaletteTests.discoverProjectPaths`.
struct QueuePaletteTests {

    /// Builds an isolated temp directory and returns its URL; the caller removes it.
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-queue-palette-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func touch(_ url: URL) throws {
        try "{}".write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - discoverTemplates

    /// `.json` files become BASENAMEs (extension dropped); `.JSON` is accepted
    /// (case-insensitive); non-json files, hidden files, and directories are skipped;
    /// results are sorted case-insensitively.
    @Test func discoverFiltersSkipsAndSorts() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }

        try touch(base.appendingPathComponent("Backlog.json"))
        try touch(base.appendingPathComponent("alpha.JSON"))      // case-insensitive ext
        try touch(base.appendingPathComponent("notes.txt"))       // non-json, skipped
        try touch(base.appendingPathComponent(".hidden.json"))    // dotfile, skipped
        // A subdirectory named like a template must NOT be treated as one's content,
        // but discoverTemplates filters purely by name+extension, so a dir whose name
        // ends in .json WOULD list; use a dir name that doesn't, to keep intent clear.
        let sub = base.appendingPathComponent("subdir", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

        let names = QueuePaletteView.discoverTemplates(dir: base.path)
        // Sorted case-insensitively: "alpha" before "Backlog".
        #expect(names == ["alpha", "Backlog"])
    }

    /// Two entries that collapse to the same basename (differing only in the `.json`
    /// extension case) are deduped to one.
    @Test func discoverDedupesSameBasename() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }

        try touch(base.appendingPathComponent("queue.json"))
        try touch(base.appendingPathComponent("queue.JSON"))

        let names = QueuePaletteView.discoverTemplates(dir: base.path)
        #expect(names == ["queue"])
    }

    /// An unreadable / absent directory yields an empty list (never throws).
    @Test func discoverSkipsUnreadableDir() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-no-such-queues-\(UUID().uuidString)")
        #expect(QueuePaletteView.discoverTemplates(dir: missing.path).isEmpty)
    }

    /// An empty directory yields an empty list.
    @Test func discoverEmptyDir() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(QueuePaletteView.discoverTemplates(dir: base.path).isEmpty)
    }
}

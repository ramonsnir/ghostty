import Foundation
import Testing
import GhosttyKit
@testable import Ghostty

/// (ramon fork) Unit tests for the project-selector directory discovery,
/// specifically that it follows symlinks to directories but not symlinks to
/// files / dangling links. Builds a real temp tree and exercises the pure
/// filesystem helpers on `ProjectPaletteView`.
struct ProjectPaletteTests {

    /// Builds an isolated temp directory and returns its URL; the caller is
    /// responsible for removing it.
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-project-palette-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - isProjectDirectory

    @Test func realDirectoryIsProject() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        #expect(ProjectPaletteView.isProjectDirectory(dir))
    }

    @Test func symlinkToDirectoryIsProject() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let target = base.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(ProjectPaletteView.isProjectDirectory(link))
    }

    @Test func symlinkToFileIsNotProject() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("file.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        #expect(!ProjectPaletteView.isProjectDirectory(link))
    }

    @Test func regularFileIsNotProject() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("file.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        #expect(!ProjectPaletteView.isProjectDirectory(file))
    }

    @Test func danglingSymlinkIsNotProject() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let missing = base.appendingPathComponent("does-not-exist", isDirectory: true)
        let link = base.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missing)

        #expect(!ProjectPaletteView.isProjectDirectory(link))
    }

    // MARK: - discoverProjectPaths

    @Test func discoverIncludesDirsAndDirSymlinksOnly() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        // Symlink targets live outside the scanned base so they don't show up
        // as their own entries — keeps the expected result unambiguous.
        let outside = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: outside) }

        // Under `base`: a real dir, a symlink-to-dir, a symlink-to-file, a
        // plain file, a dangling symlink, and a hidden dir.
        let realDir = base.appendingPathComponent("alpha", isDirectory: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)

        let targetDir = outside.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let dirLink = base.appendingPathComponent("beta")
        try FileManager.default.createSymbolicLink(at: dirLink, withDestinationURL: targetDir)

        let file = outside.appendingPathComponent("note.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let fileLink = base.appendingPathComponent("gamma")
        try FileManager.default.createSymbolicLink(at: fileLink, withDestinationURL: file)

        let dangling = base.appendingPathComponent("delta")
        try FileManager.default.createSymbolicLink(
            at: dangling,
            withDestinationURL: outside.appendingPathComponent("nope", isDirectory: true))

        let hidden = base.appendingPathComponent(".hidden", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)

        let names = ProjectPaletteView.discoverProjectPaths(bases: [base.path])
            .map { ($0 as NSString).lastPathComponent }

        // Only the real dir (`alpha`) and the dir-symlink (`beta`) qualify; the
        // plain file, file-symlink, dangling link, and hidden dir are excluded.
        #expect(names == ["alpha", "beta"])
    }

    @Test func discoverDedupesAcrossBases() throws {
        let base = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let dir = base.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Same base listed twice -> the child appears once.
        let paths = ProjectPaletteView.discoverProjectPaths(bases: [base.path, base.path])
        #expect(paths.filter { ($0 as NSString).lastPathComponent == "shared" }.count == 1)
    }

    @Test func discoverSkipsUnreadableBase() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-no-such-base-\(UUID().uuidString)")
        #expect(ProjectPaletteView.discoverProjectPaths(bases: [missing.path]).isEmpty)
    }
}

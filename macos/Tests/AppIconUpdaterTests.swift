import Foundation
import Darwin
import Testing
@testable import Ghostty

/// (ramon fork) Tests for the custom-icon write verification / self-heal added to
/// `AppIconUpdater`. The bug: `NSWorkspace.setIcon` applying a custom icon can land
/// half-done during a busy boot — the Finder kHasCustomIcon bit set but the `Icon\r`
/// resource EMPTY — which macOS renders as a generic FOLDER icon. The fix verifies the
/// write produced real icon data and, failing that, clears the broken state so the app
/// degrades to its baked-in icon, never a folder.
struct AppIconUpdaterTests {
    // MARK: - Pure predicate: isFolderIconFallback

    @Test func folderFallbackWhenBitSetAndNoIconData() {
        var info = [UInt8](repeating: 0, count: 32)
        info[8] = 0x04 // kHasCustomIcon
        #expect(AppIconUpdater.isFolderIconFallback(finderInfo: info, iconResourceForkLength: 0))
    }

    @Test func healthyWhenBitSetAndIconDataPresent() {
        var info = [UInt8](repeating: 0, count: 32)
        info[8] = 0x04
        // A real icon resource is ~1.7 MB; any positive length means data is present.
        #expect(!AppIconUpdater.isFolderIconFallback(finderInfo: info, iconResourceForkLength: 1_700_000))
    }

    @Test func benignWhenBitClearEvenWithEmptyIcon() {
        // No custom-icon bit: an empty Icon\r is harmless (observed on the Debug build).
        let info = [UInt8](repeating: 0, count: 32)
        #expect(!AppIconUpdater.isFolderIconFallback(finderInfo: info, iconResourceForkLength: 0))
    }

    @Test func benignWhenBitClearWithData() {
        let info = [UInt8](repeating: 0, count: 32)
        #expect(!AppIconUpdater.isFolderIconFallback(finderInfo: info, iconResourceForkLength: 512))
    }

    @Test func notFallbackWhenFinderInfoAbsent() {
        #expect(!AppIconUpdater.isFolderIconFallback(finderInfo: [], iconResourceForkLength: 0))
    }

    @Test func notFallbackWhenFinderInfoTooShort() {
        #expect(!AppIconUpdater.isFolderIconFallback(finderInfo: [0x04], iconResourceForkLength: 0))
    }

    @Test func otherFinderFlagsAloneAreNotFallback() {
        // 0x40 on byte 8 is kIsInvisible, not kHasCustomIcon — must not count.
        var info = [UInt8](repeating: 0, count: 32)
        info[8] = 0x40
        #expect(!AppIconUpdater.isFolderIconFallback(finderInfo: info, iconResourceForkLength: 0))
    }

    @Test func customPlusOtherFlagsIsStillFallback() {
        var info = [UInt8](repeating: 0, count: 32)
        info[8] = 0x44 // kHasCustomIcon (0x04) + kIsInvisible (0x40)
        #expect(AppIconUpdater.isFolderIconFallback(finderInfo: info, iconResourceForkLength: 0))
    }

    // MARK: - Filesystem round-trip: detection + self-heal

    private func makeTempDir() -> String {
        let dir = NSTemporaryDirectory() + "appicon-selfheal-" + UUID().uuidString
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func setFinderCustomIconBit(_ path: String) {
        var info = [UInt8](repeating: 0, count: 32)
        info[8] = 0x04
        _ = info.withUnsafeBytes {
            setxattr(path, "com.apple.FinderInfo", $0.baseAddress, info.count, 0, 0)
        }
    }

    private func setResourceFork(_ path: String, bytes: Int) {
        let data = [UInt8](repeating: 0xAB, count: bytes)
        _ = data.withUnsafeBytes {
            setxattr(path, "com.apple.ResourceFork", $0.baseAddress, data.count, 0, 0)
        }
    }

    @Test func detectsBrokenBundleThenHealsIt() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // Reproduce the broken state: custom-icon bit set on the folder + an empty
        // Icon\r (no resource fork) — exactly what a half-done setIcon leaves behind.
        setFinderCustomIconBit(dir)
        let iconPath = "\(dir)/\(AppIconUpdater.customIconFileName)"
        FileManager.default.createFile(atPath: iconPath, contents: Data())
        #expect(AppIconUpdater.bundleShowsFolderFallback(atPath: dir))

        AppIconUpdater.clearCustomIcon(atPath: dir)

        // Healed: no longer a fallback, and the empty Icon\r is gone.
        #expect(!AppIconUpdater.bundleShowsFolderFallback(atPath: dir))
        #expect(!FileManager.default.fileExists(atPath: iconPath))
    }

    @Test func healthyBundleIsNotAFallback() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // Healthy: custom-icon bit set + Icon\r carrying a non-empty resource fork.
        setFinderCustomIconBit(dir)
        let iconPath = "\(dir)/\(AppIconUpdater.customIconFileName)"
        FileManager.default.createFile(atPath: iconPath, contents: Data())
        setResourceFork(iconPath, bytes: 1024)

        #expect(!AppIconUpdater.bundleShowsFolderFallback(atPath: dir))
    }

    @Test func clearIsANoOpWhenNoCustomIcon() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // No custom-icon state at all: clear must be a safe no-op.
        AppIconUpdater.clearCustomIcon(atPath: dir)
        #expect(!AppIconUpdater.bundleShowsFolderFallback(atPath: dir))
    }
}

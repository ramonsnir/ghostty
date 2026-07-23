import AppKit
import Darwin
import System

/// The icon style for the Ghostty App.
enum AppIcon: Equatable, Codable, Sendable {
    case official
    case blueprint
    case chalkboard
    case glass
    case holographic
    case microchip
    case paper
    case retro
    case xray
    /// Save full image data to avoid sandboxing issues
    case custom(_ iconFile: Data)
    case customStyle(_ icon: ColorizedGhosttyIcon)

#if !DOCK_TILE_PLUGIN
    init?(config: Ghostty.Config) {
        switch config.macosIcon {
        case .official:
            return nil
        case .blueprint:
            self = .blueprint
        case .chalkboard:
            self = .chalkboard
        case .glass:
            self = .glass
        case .holographic:
            self = .holographic
        case .microchip:
            self = .microchip
        case .paper:
            self = .paper
        case .retro:
            self = .retro
        case .xray:
            self = .xray
        case .custom:
            if let data = try? Data(contentsOf: URL(filePath: config.macosCustomIcon, relativeTo: nil)) {
                self = .custom(data)
            } else {
                return nil
            }
        case .customStyle:
            // Discard saved icon name
            // if no valid colours were found
            guard
                let ghostColor = config.macosIconGhostColor,
                let screenColors = config.macosIconScreenColor
            else {
                return nil
            }
            self = .customStyle(ColorizedGhosttyIcon(screenColors: screenColors, ghostColor: ghostColor, frame: config.macosIconFrame))
        }

        // Fork: per-build override of the fork default so the installed
        // Release (chalkboard), in-tree ReleaseLocal (paper), and Xcode
        // Debug (blueprint) builds are visually distinct at a glance.
        // Only fires when the resolved icon is the fork default — any
        // explicit non-chalkboard config still wins.
        if self == .chalkboard, let bundleID = Bundle.main.bundleIdentifier {
            if bundleID.hasSuffix(".debug") {
                self = .blueprint
            } else if bundleID.hasSuffix(".local") {
                self = .paper
            }
        }
    }
#endif

    func image(in bundle: Bundle) -> NSImage? {
        switch self {
        case .official:
            return nil
        case .blueprint:
            return bundle.image(forResource: "BlueprintImage")!
        case .chalkboard:
            return bundle.image(forResource: "ChalkboardImage")!
        case .glass:
            return bundle.image(forResource: "GlassImage")!
        case .holographic:
            return bundle.image(forResource: "HolographicImage")!
        case .microchip:
            return bundle.image(forResource: "MicrochipImage")!
        case .paper:
            return bundle.image(forResource: "PaperImage")!
        case .retro:
            return bundle.image(forResource: "RetroImage")!
        case .xray:
            return bundle.image(forResource: "XrayImage")!
        case let .custom(file):
            return NSImage(data: file)
        case let .customStyle(customIcon):
            return customIcon.makeImage(in: bundle)
        }
    }
}

#if !DOCK_TILE_PLUGIN
/// Making sure that `NSWorkspace.shared.setIcon` executes on only one thread at a time
actor AppIconUpdater {
    // (ramon fork) `NSWorkspace.setIcon` applying a custom icon can land HALF-DONE:
    // it sets the Finder kHasCustomIcon bit on the bundle but leaves the `Icon\r`
    // resource EMPTY, which macOS renders as a generic FOLDER icon. This bites the
    // fork after a laptop restart, when macOS auto-relaunches the (window-restoring)
    // app early during boot and the write into the bundle is interrupted by a busy
    // filesystem. So instead of trusting `setIcon`, `update(icon:)` VERIFIES the
    // write produced real icon data, RETRIES a few times, and — if it still fails —
    // CLEARS the broken state so the app degrades to its baked-in icon, NEVER a
    // folder. (The empty state also self-heals on the next launch where the write
    // succeeds, but the verify/retry recovers the chosen icon within the session.)
    private static let iconWriteAttempts = 3
    private static let iconWriteRetryDelays: [Double] = [0.5, 1.5]

    func update(icon: AppIcon?) async {
        UserDefaults.ghostty.appIcon = icon
        // Notify DockTilePlugin to update dock icon
        DistributedNotificationCenter.default()
            .postNotificationName(
                .ghosttyIconDidChange,
                object: nil,
                userInfo: nil,
                deliverImmediately: true,
            )

        let bundlePath = Bundle.main.bundlePath

        // No custom icon (official): removing a custom icon can never leave a
        // generic-folder fallback, so just clear it and return.
        guard let image = icon?.image(in: .main) else {
            NSWorkspace.shared.setIcon(nil, forFile: bundlePath)
            NSWorkspace.shared.noteFileSystemChanged(bundlePath)
            return
        }

        // Applying a custom icon — verify + retry (see the note above).
        for attempt in 0..<Self.iconWriteAttempts {
            if attempt > 0 {
                // Clear the half-done write before retrying, and wait out the
                // boot-busy window that likely caused it.
                Self.clearCustomIcon(atPath: bundlePath)
                let delay = Self.iconWriteRetryDelays[min(attempt - 1, Self.iconWriteRetryDelays.count - 1)]
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            NSWorkspace.shared.setIcon(image, forFile: bundlePath)
            NSWorkspace.shared.noteFileSystemChanged(bundlePath)

            if !Self.bundleShowsFolderFallback(atPath: bundlePath) {
                return
            }
        }

        // Every attempt landed half-done: never leave the app looking like a
        // folder — clear the broken state so it falls back to the baked-in icon.
        Self.clearCustomIcon(atPath: bundlePath)
        NSWorkspace.shared.noteFileSystemChanged(bundlePath)
    }

    // MARK: - (ramon fork) custom-icon write verification / self-heal

    /// The icon-resource file macOS stores inside a folder/bundle ("Icon" + `\r`).
    static let customIconFileName = "Icon\r"

    /// Pure predicate: given a bundle's raw `com.apple.FinderInfo` bytes and the
    /// byte length of its `Icon\r` file's resource fork, is the bundle stuck in the
    /// broken "custom-icon bit set but no icon data" state that macOS renders as a
    /// generic FOLDER icon? The Finder flags are a big-endian `UInt16` at FinderInfo
    /// bytes 8..9, and `kHasCustomIcon = 0x0400`, so byte 8 carries the `0x04`.
    static func isFolderIconFallback(finderInfo: [UInt8], iconResourceForkLength: Int) -> Bool {
        guard finderInfo.count >= 9 else { return false }
        let hasCustomIconBit = (finderInfo[8] & 0x04) != 0
        return hasCustomIconBit && iconResourceForkLength <= 0
    }

    /// Impure: does the on-disk bundle currently render as a generic folder icon?
    static func bundleShowsFolderFallback(atPath bundlePath: String) -> Bool {
        let iconPath = "\(bundlePath)/\(customIconFileName)"
        return isFolderIconFallback(
            finderInfo: finderInfo(atPath: bundlePath),
            iconResourceForkLength: xattrLength("com.apple.ResourceFork", atPath: iconPath))
    }

    /// Impure: remove any (possibly broken) `Icon\r` resource and clear the bundle's
    /// kHasCustomIcon bit, so it falls back to its baked-in icon. All of this lives at
    /// the bundle ROOT, outside the signed `Contents/`, so it never breaks the seal.
    static func clearCustomIcon(atPath bundlePath: String) {
        try? FileManager.default.removeItem(atPath: "\(bundlePath)/\(customIconFileName)")

        var info = finderInfo(atPath: bundlePath)
        guard info.count >= 9, (info[8] & 0x04) != 0 else { return }
        info[8] &= ~UInt8(0x04)
        if info.allSatisfy({ $0 == 0 }) {
            removexattr(bundlePath, "com.apple.FinderInfo", 0)
        } else {
            _ = info.withUnsafeBytes {
                setxattr(bundlePath, "com.apple.FinderInfo", $0.baseAddress, info.count, 0, 0)
            }
        }
    }

    /// Read up to 32 bytes of `com.apple.FinderInfo` for a path; `[]` if absent.
    private static func finderInfo(atPath path: String) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: 32)
        let n = buf.withUnsafeMutableBytes {
            getxattr(path, "com.apple.FinderInfo", $0.baseAddress, $0.count, 0, 0)
        }
        guard n > 0 else { return [] }
        return Array(buf.prefix(n))
    }

    /// Byte length of an xattr without reading its bytes; 0 if absent.
    private static func xattrLength(_ name: String, atPath path: String) -> Int {
        let n = getxattr(path, name, nil, 0, 0, 0)
        return n > 0 ? n : 0
    }
}
#endif

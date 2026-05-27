# Ghostty — ramon fork

Personal macOS fork of Ghostty that adds split/tab-reorganization commands and
runs side-by-side with an official Ghostty. Single working branch: **`ramon-fork`**.
Upstream conventions still apply (`AGENTS.md`, `macos/AGENTS.md`); this file only
covers what's specific to the fork.

## Functional changes — new keybind actions (also in the command palette)
All act on the focused surface. flip/toggle walk **up** to the nearest enclosing
split of the given orientation (like `resize_split`), so outer splits are
reachable from nested panes. The split tree is strictly binary.

- `flip_split:horizontal|vertical` — mirror the nearest left/right or up/down split (swap its two sides; divider stays put).
- `toggle_split_direction:horizontal|vertical` — re-orient the nearest split of that orientation (L/R ⇄ U/D).
- `move_split_to_new_tab` — eject the focused pane into its own new tab.
- `merge_tabs:{next,previous}_{horizontal,vertical}` — merge a neighboring tab into this one with a split.

Wiring — core: `src/input/Binding.zig`, `src/apprt/action.zig` (+`include/ghostty.h`),
`src/Surface.zig`, `src/input/command.zig`. macOS: `SplitTree.swift` (pure transforms),
`BaseTerminalController.swift`/`TerminalController.swift` (handlers, `newTab(tree:)`),
`Ghostty.App.swift`, `GhosttyPackage.swift`. Tests: `macos/Tests/Splits/SplitTreeTests.swift`.

## Fork-identity / non-functional changes
- **Bundle id** `com.mitchellh.ghostty-ramon` (Debug: `.debug`) — coexists with official `com.mitchellh.ghostty`; own state/defaults domain. (`macos/Ghostty.xcodeproj/project.pbxproj`, `DockTilePlugin.swift`)
- **Display name** "Ghostty (ramon)"; installed at `/Applications/Ghostty (ramon).app` next to the official one.
- **Icon** defaults to `chalkboard` (`macos-icon` default in `src/config/Config.zig`).
- **Auto-update hard-disabled** in code: Sparkle never starts, `checkForUpdates` is a no-op, menu item disabled — independent of config. (`macos/Sources/Features/Update/UpdateController.swift`)
- **Config separation**: the fork additionally loads `~/.config/ghostty-ramon/config` on top of the shared `~/.config/ghostty/config`. Put fork-only keybinds there so an official Ghostty (which shares `~/.config/ghostty/config`) never errors on unknown actions. (`src/config/file_load.zig` `forkXdgPath`, `Config.zig` `loadDefaultFiles`)

## Iteration lifecycle (macOS)
Toolchain: full **Xcode** (not just Command Line Tools) + Metal toolchain + accepted
license; **Homebrew `zig@0.15`** (the official 0.15.2 tarball has a broken linker on
this macOS); `nushell` for `build.nu`.

1. Edit code (Zig core in `src/`, macOS in `macos/Sources/`).
2. **Zig tests**: `zig build test -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=<name>`.
3. **Rebuild lib** (required after any Zig change before the app build): `zig build -Demit-macos-app=false -Doptimize=ReleaseFast`.
4. **Swift tests**: `macos/build.nu --action test` (or `xcodebuild … -only-testing:GhosttyTests/SplitTreeTests test`).
5. **Build the app**: `macos/build.nu --configuration ReleaseLocal --action build` → `macos/build/ReleaseLocal/Ghostty.app` (optimized, no debug banner).
6. **Install/update the fork**: `ditto macos/build/ReleaseLocal/Ghostty.app "/Applications/Ghostty (ramon).app"`. Never touch `/Applications/Ghostty.app`.
7. **Commit** to `ramon-fork`.

## ⚠️ Safety
NEVER run `osascript -e 'quit app "Ghostty"'` — the fork and the official build are
both *named* "Ghostty", so it's ambiguous and can quit the user's real, working
Ghostty (which may host your shell). To restart the fork, target it precisely:
`osascript -e 'tell application id "com.mitchellh.ghostty-ramon" to quit'`, or kill
the PID whose path is under `macos/build/`. Prefer letting the user quit/relaunch
while they're working live.

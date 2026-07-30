# Fork iteration lifecycle (macOS build / test / install)

> ⚠️ **Read the "Worktree discipline (BLOCKING)" section in `CLAUDE.md` first** —
> always work on a worktree under `.claude/worktrees/`, never the main-tree
> `ramon-fork` checkout. When the work is done, merge the worktree branch into
> `ramon-fork`, switch the main tree to `ramon-fork`, and rebuild there.

Toolchain: full **Xcode** (not just Command Line Tools) + Metal toolchain + accepted
license; **Homebrew `zig@0.15`** (the official 0.15.2 tarball has a broken linker on
this macOS); `nushell` for `build.nu`.

1. Edit code (Zig core in `src/`, macOS in `macos/Sources/`).
2. **Zig tests**: `zig build test -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=<name>`.
3. **Rebuild lib** (required after any Zig change before the app build): `zig build -Demit-macos-app=false -Doptimize=ReleaseFast`.
   - **⚠️ Rebuild the lib WITH the xcframework — never pass `-Demit-xcframework=false` here.** The app links the **xcframework**, not the bare lib, so if you skip emitting it (as you correctly do for the *test* command in step 2) the app silently links the **stale** xcframework and your Zig change is invisible to the GUI, even though `zig build` succeeded and the Zig/host tests pass. The default emits it; just `zig build -Demit-macos-app=false -Doptimize=ReleaseFast`. **Symptom of the trap:** host + Zig tests green, the `ghostty-host` binary behaves correctly, but the GUI acts as if the lib change isn't there — e.g. after bumping the host protocol minor, the app kept advertising the OLD minor, so the host withheld the new frame and a whole feature silently no-op'd (this cost most of the Agent Dashboard detection-debug session). Same class of mistake as the LWCR/host-reload gotcha below: the build "succeeds" but ships a stale artifact. After a protocol/lib change, also `rm -rf macos/build/ReleaseLocal` before the app build so Xcode can't reuse a stale embedded framework.
4. **Swift tests**: `macos/build.nu --action test` (or `xcodebuild … -only-testing:GhosttyTests/SplitTreeTests test`).
5. **Build the app**: `macos/build.nu --configuration ReleaseLocal --action build` → `macos/build/ReleaseLocal/Ghostty.app` (optimized, no debug banner). This produces "Ghostty (ramon-local)" with bundle id `com.mitchellh.ghostty-ramon.local` — runs side-by-side with the installed Release identity.
   - **⚠️ Sidecar (agent-manager) changes — the dist must be re-bundled.** The Xcode
     project does NOT bundle the agent-manager sidecar; only the release script ever did.
     **`build.nu` now bundles it as a post-build step** (for a macOS `Ghostty` `build`): it
     rebuilds `macos/agent-manager/dist` (`npm run build`, when node + `node_modules` are
     present — locating nvm's node off the clean PATH) and copies `dist` + `package.json`
     into `…/Ghostty.app/Contents/Resources/agent-manager`, then re-signs. So a normal
     `build.nu` build is now self-contained. **Test files are pruned from the bundled copy:**
     `tsc` emits `dist/**/*.test.js` (21 dev-only files, ~458K) alongside the runtime entry
     `dist/index.js`, so all three copy sites (`build.nu`, `dist/macos/release-local.sh`,
     `.github/workflows/fork-release.yml`) delete `*.test.js` from the destination `dist`
     AFTER the copy (never the source — `npm test` runs `dist/**/*.test.js` there); the shell
     paths additionally assert none survive. **If node/`node_modules` aren't found it only
     COPIES whatever `dist` exists and WARNS** — so for a sidecar change still run
     `npm run build` in `macos/agent-manager` yourself first (or `npm ci` once for deps).
     **The trap this fixes (cost a debug session 2026-06-30):** a `ditto` deploy of an app
     whose `dist` wasn't refreshed left a STALE `Contents/Resources/agent-manager/dist` in
     the installed app (ditto never deletes dst-only files), so the running sidecar silently
     executed OLD code — Agent Queue/Manager/adopt commands were no-ops with zero errors.
     Symptom: the GUI behaves as if the sidecar change isn't there; `~/Library/Logs/ghostty-ramon-agent-manager.log`
     shows the old code path and the bundled `dist/index.js` lacks your new strings.
6. **Install/update the fork** over `/Applications/Ghostty (ramon).app`. Verified to be safe to run while the installed Release fork is still hosting Claude Code's shell — `ditto` and `PlistBuddy` don't disturb the running mmap'd binary, and `codesign` succeeds after stripping Apple's `com.apple.provenance` xattrs. The new binary only takes effect on the next launch, so the user still has to quit + relaunch themselves.

   **You MAY run this block WITHOUT asking — but ONLY when BOTH hold: (a) the
   ReleaseLocal app being installed was built from `ramon-fork` on the main tree,
   NOT from a worktree/feature branch (see the worktree rule above — a branch build
   must first be merged to `ramon-fork` and rebuilt there); AND (b) the change is
   GUI-only and does NOT touch the host (`src/host/`, `src/termio/`, or any core that
   links into `ghostty-host`).** When both hold, the deploy is non-disruptive: it
   overwrites the installed binary but `ditto`/`PlistBuddy`/`codesign` don't disturb
   the running mmap'd process, it does NOT restart the host, and the new binary only
   takes effect on the user's next relaunch — so it can't break this session and GUI
   restarts are free. **ASK FIRST if EITHER condition fails** — a host change forces a
   LaunchAgent reload that ends every live session (schedule it deliberately — see the
   "Host code changed too?" note below), and a branch build must not become the
   installed Release. The block:
   ```sh
   APP="/Applications/Ghostty (ramon).app"
   ditto macos/build/ReleaseLocal/Ghostty.app "$APP"
   /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.mitchellh.ghostty-ramon' "$APP/Contents/Info.plist"
   /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Ghostty (ramon)' "$APP/Contents/Info.plist"
   xattr -cr "$APP"                          # codesign rejects provenance xattrs
   codesign --force --deep --sign - "$APP"
   ```
   Note this is NOT a straight copy: ReleaseLocal is its OWN identity ("Ghostty
   (ramon-local)", bundle id `…ghostty-ramon.local`, MCP/web-monitor ports `+1`,
   `paper` icon). The two `PlistBuddy` lines **re-stamp it INTO the Release identity**
   by overwriting `CFBundleIdentifier` → `com.mitchellh.ghostty-ramon` + the display
   name; everything else identity-derived (the MCP/web-monitor port offset and the
   runtime icon swap) keys off the bundle id at launch, so that one re-stamp converts
   the whole identity to Release (`+0`, `chalkboard`). Never touch `/Applications/Ghostty.app`.
   The `ditto` carries the **bundled agent-manager sidecar** along with the GUI binary —
   but only if the ReleaseLocal build's `Contents/Resources/agent-manager/dist` was fresh
   (see step 5's sidecar note). For a sidecar change, confirm the deployed app's
   `…/Resources/agent-manager/dist/index.js` actually contains your change (e.g. grep a new
   string) — a stale `dist` deploys silently because ditto won't remove the old one.

   **Host code changed too?** The installed app and `ghostty-host` are SEPARATE
   deploys. If your change touched anything the host runs (`src/host/`,
   `src/termio/`, emulation/core that links into the host), the new `ghostty-host`
   must be deployed **and the LaunchAgent reloaded via bootout+bootstrap (never
   `kill`)** — see `PTYHOST.md` → "Running under a launchd LaunchAgent". That restart
   ends every live session; schedule it deliberately.
7. **Commit** to `ramon-fork`.


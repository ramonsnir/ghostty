#!/usr/bin/env bash
#
# Local, FREE release of the ramon fork — the PRIMARY release path.
#
# Builds + signs + notarizes + DMGs + appcasts + publishes a GitHub Release, all
# on your Mac. No paid macOS CI minutes (the Fork Release GitHub workflow is a
# manual-only fallback; macOS runners bill at ~10x and a stuck Apple notary can
# burn a whole job). Notarization here is still Apple's free service — slowness
# only costs wall-clock, not dollars. Release assets are free + separate from Git
# LFS, so colleagues download the DMG straight from Releases.
#
# Run from the repo root on `ramon-fork` (Release builds must come from there).
#
# ONE-TIME SETUP on each release machine:
#   1. Developer ID cert in your login keychain (Xcode > Settings > Accounts >
#      Manage Certificates > + > Developer ID Application).
#   2. Sparkle private key in your keychain (already done at enrollment via
#      `generate_keys`; `sign_update` uses it automatically — no key file needed).
#   3. A stored notary credential profile:
#        xcrun notarytool store-credentials "$NOTARY_PROFILE" \
#          --key /path/AuthKey_XXXX.p8 --key-id <KEYID> --issuer <ISSUER-UUID>
#   4. Sparkle's `sign_update` + `create-dmg` on PATH:
#        export PATH="/path/to/Sparkle/bin:$PATH"   # from the Sparkle SPM zip
#        npm install --global create-dmg
#
# Overridable via env: REPO, IDENTITY, NOTARY_PROFILE.
set -euo pipefail

REPO="${REPO:-ramonsnir/ghostty}"
IDENTITY="${IDENTITY:-Developer ID Application: Ramon Snir (72PSTG4224)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-ghostty-ramon-notary}"
APP="macos/build/Release/Ghostty.app"

# ---- make node + create-dmg resolvable (nvm-friendly) ----------------------
# This release is almost always cut from this Mac, often from a non-login / GUI
# shell (or an unattended monitor run) where nvm's lazy-load shims aren't
# initialized: `node`/`npm` are recursive shell functions that error with
# "_load_nvm: command not found", and the real node bin (plus a globally
# `npm i -g`'d create-dmg) isn't on PATH. Drop the shims and, ONLY if create-dmg
# isn't already found, prepend the nvm node bin that has it (else the newest).
# A no-op when create-dmg is already on PATH (e.g. a Homebrew install).
unset -f node npm 2>/dev/null || true
if ! command -v create-dmg >/dev/null 2>&1; then
  for _bin in $(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | sort -Vr); do
    if [ -x "$_bin/create-dmg" ]; then PATH="$_bin:$PATH"; break; fi
  done
  # Still missing? At least put the newest node on PATH so create-dmg's
  # `#!/usr/bin/env node` shebang resolves once it's installed.
  if ! command -v create-dmg >/dev/null 2>&1; then
    _newest_node_bin="$(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | sort -V | tail -1)"
    [ -n "$_newest_node_bin" ] && PATH="$_newest_node_bin:$PATH"
  fi
fi
export PATH

# ---- preconditions (fail fast with actionable messages) --------------------
[ -f build.zig ] || { echo "ERROR: run from the repo root (build.zig not found)"; exit 1; }
command -v gh         >/dev/null || { echo "ERROR: gh not installed"; exit 1; }
command -v zig        >/dev/null || { echo "ERROR: zig not installed"; exit 1; }
command -v sign_update >/dev/null || { echo "ERROR: sign_update not on PATH (add Sparkle's bin/)"; exit 1; }
command -v create-dmg >/dev/null || { echo "ERROR: create-dmg not installed (npm i -g create-dmg)"; exit 1; }
security find-identity -v -p codesigning | grep -qF "$IDENTITY" \
  || { echo "ERROR: signing identity not found: $IDENTITY"; exit 1; }
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || { echo "ERROR: notary profile '$NOTARY_PROFILE' missing. Create it once:"; \
       echo "  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --key <AuthKey.p8> --key-id <KEYID> --issuer <ISSUER>"; exit 1; }

# All transient artifacts (notarize zip, DMG, appcast, sign_update) live in a temp
# dir and are auto-removed on exit, so a run — even one that fails mid-notarization —
# NEVER dirties the repo working tree. (The canonical DMG/appcast live on the
# GitHub Release; the build outputs in macos/build + zig-out are gitignored.)
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

GHOSTTY_BUILD="$(git rev-list --count HEAD)"
GHOSTTY_COMMIT="$(git rev-parse --short HEAD)"
GHOSTTY_COMMIT_LONG="$(git rev-parse HEAD)"
# Tag is UNIQUE per commit (the count alone can repeat across rebases/merges, which
# would clobber a prior release); the GitHub release will --target this exact commit.
TAG="build-${GHOSTTY_BUILD}-${GHOSTTY_COMMIT}"
echo ">> Releasing $TAG to $REPO"

# Releases build the LOCAL working tree, so the built commit must be on GitHub for a
# coherent release (tag = built commit = the DMG's source). Guard + push FIRST.
# `git push fork` uses the pinned refspec (ramon-fork -> fork/main) regardless of the
# checked-out branch, so the release MUST be cut from ramon-fork's tip.
if [ "$(git rev-parse HEAD)" != "$(git rev-parse ramon-fork)" ]; then
  echo "ERROR: HEAD ($GHOSTTY_COMMIT) is not ramon-fork's tip — releases must be cut from ramon-fork."; exit 1
fi
if [ "${RELEASE_YES:-}" != "1" ] && [ -t 0 ]; then
  read -r -p ">> Push ramon-fork -> fork/main and publish $TAG? [y/N] " _ans
  case "$_ans" in y|Y|yes|YES) ;; *) echo "aborted"; exit 1 ;; esac
fi
echo ">> [0/8] push ramon-fork -> fork/main (so the release tags the exact built commit)"
git push fork

# ---- 1. xcframework + ghostty-host -----------------------------------------
echo ">> [1/8] zig build (xcframework + ghostty-host)"
zig build -Doptimize=ReleaseFast -Demit-macos-app=false -Dversion-string="0.0.0-fork-${GHOSTTY_BUILD}"
test -f zig-out/bin/ghostty-host

# ---- 2. build the app ------------------------------------------------------
echo ">> [2/8] xcodebuild Release"
( cd macos && xcodebuild -target Ghostty -configuration Release \
    SYMROOT="$PWD/build" CODE_SIGNING_ALLOWED=NO )
test -d "$APP"

# ---- 3. bundle the host ----------------------------------------------------
echo ">> [3/8] bundle ghostty-host"
cp -f zig-out/bin/ghostty-host "$APP/Contents/MacOS/ghostty-host"
chmod +x "$APP/Contents/MacOS/ghostty-host"

# ---- 3a. bundle the ghostty-mcp stdio shim ---------------------------------
# Mirror the CI workflow: build the MCP stdio shim and bundle it alongside the
# host so it is signed + notarized as part of the app and carried by Sparkle. The
# app's ForkSetup copies it onto PATH (~/.local/bin/ghostty-mcp) on first launch so
# a colleague's `claude mcp add ghostty -- ghostty-mcp` works. Pure Swift/Foundation
# SPM package (NOT in Ghostty.xcodeproj), so it builds with the system swift.
echo ">> [3a/8] bundle ghostty-mcp shim"
swift build -c release --package-path macos/mcp-shim
cp -f macos/mcp-shim/.build/release/ghostty-mcp "$APP/Contents/MacOS/ghostty-mcp"
chmod +x "$APP/Contents/MacOS/ghostty-mcp"
test -x "$APP/Contents/MacOS/ghostty-mcp"

# ---- 3b. bundle the agent-manager sidecar (Agent Queue + Manager) ----------
# Build the TS sidecar and bundle ONLY dist/ + package.json into
# Contents/Resources/agent-manager (the path resolveSidecarDir() prefers). We do
# NOT bundle node_modules: it is ~271MB and ships a native ~215MB `claude` Mach-O
# (in @anthropic-ai/claude-agent-sdk-darwin-arm64) that would break notarization.
# `npm run build` = tsc + esbuild: esbuild RE-bundles dist/index.js with the Claude
# Agent SDK's JAVASCRIPT inlined (a few MB, NO native binary — it's marked external),
# so the SUMMARIZER works for colleagues from dist alone: model.ts points the SDK at
# the colleague's ALREADY-INSTALLED `claude` via pathToClaudeCodeExecutable
# (GHOSTTY_CLAUDE_PATH, set by AgentManagerController). The Agent QUEUE has ZERO npm
# deps and runs from dist regardless. package.json is required so node treats dist/*.js
# as ESM ("type":"module"). RUNTIME PREREQ on the target Mac: `node` on PATH (and, for
# the summarizer specifically, `claude` on PATH — both handled gracefully if absent).
echo ">> [3b/8] bundle agent-manager sidecar (dist only; SDK JS inlined; node prereq)"
( cd macos/agent-manager && npm ci && npm run build )
test -f macos/agent-manager/dist/index.js
# Sanity: the SDK JS must be inlined (so the summarizer works with no node_modules) and
# NO bare @anthropic-ai import may remain (which would throw at runtime under dist-only).
grep -q "Claude Code executable" macos/agent-manager/dist/index.js \
  || { echo "ERROR: Agent SDK JS not inlined into dist/index.js (esbuild bundle missing)"; exit 1; }
! grep -qE '(import|require)\(["'"'"'"]@anthropic-ai' macos/agent-manager/dist/index.js \
  || { echo "ERROR: a bare @anthropic-ai import survived bundling (would break dist-only)"; exit 1; }
SIDECAR_DST="$APP/Contents/Resources/agent-manager"
rm -rf "$SIDECAR_DST"
mkdir -p "$SIDECAR_DST"
cp -R macos/agent-manager/dist "$SIDECAR_DST/dist"
cp macos/agent-manager/package.json "$SIDECAR_DST/package.json"
# Belt-and-suspenders: never let node_modules sneak into the notarized bundle.
rm -rf "$SIDECAR_DST/node_modules"

# ---- 3c. bundle colleague-onboarding files ---------------------------------
# Ship the Claude Code agent-state hooks (so a DMG user has the hook script +
# settings block locally — the dashboard per-tile state + queue auto-close depend
# on them) and ONBOARDING.md (the cheat sheet the seed/welcome point at), inside
# Contents/Resources so they travel with the app (carried by Sparkle; no repo
# clone needed). Pure data — notarization-safe (the app seal covers Resources/).
echo ">> [3c/8] bundle claude-hooks + ONBOARDING.md"
HOOKS_DST="$APP/Contents/Resources/claude-hooks"
rm -rf "$HOOKS_DST"
mkdir -p "$HOOKS_DST"
cp -R example/claude-hooks/. "$HOOKS_DST/"
cp ONBOARDING.md "$APP/Contents/Resources/ONBOARDING.md"

# ---- 4. version + enable updates -------------------------------------------
echo ">> [4/8] inject version"
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :GhosttyCommit $GHOSTTY_COMMIT" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :GhosttyCommit string $GHOSTTY_COMMIT" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $GHOSTTY_BUILD" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $GHOSTTY_COMMIT" "$PLIST"
/usr/libexec/PlistBuddy -c "Delete :SUEnableAutomaticChecks" "$PLIST" 2>/dev/null || true
# SUPublicEDKey is the fork's real key, already committed in Ghostty-Info.plist.

# ---- 5. codesign (inside-out, hardened runtime) ----------------------------
echo ">> [5/8] codesign"
sign() { codesign --verbose -f -s "$IDENTITY" -o runtime "$@"; }
SPK="$APP/Contents/Frameworks/Sparkle.framework"
sign "$SPK/Versions/B/XPCServices/Downloader.xpc"
sign "$SPK/Versions/B/XPCServices/Installer.xpc"
sign "$SPK/Versions/B/Autoupdate"
sign "$SPK/Versions/B/Updater.app"
sign "$SPK"
sign "$APP/Contents/PlugIns/DockTilePlugin.plugin"
sign "$APP/Contents/MacOS/ghostty-host"
sign "$APP/Contents/MacOS/ghostty-mcp"
codesign --verbose -f -s "$IDENTITY" -o runtime --entitlements macos/Ghostty.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# ---- 6. notarize + staple the app (so the app inside the DMG is offline-ok) -
echo ">> [6/8] notarize + staple app (Apple's free service; may be slow)"
ditto -c -k --keepParent "$APP" "$WORKDIR/notarize-app.zip"
xcrun notarytool submit "$WORKDIR/notarize-app.zip" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 60m
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# ---- 7. DMG from the stapled app, then notarize + staple the DMG -----------
echo ">> [7/8] create + notarize DMG"
DMG="$WORKDIR/Ghostty.dmg"
create-dmg --identity="$IDENTITY" "$APP" "$WORKDIR" || true
shopt -s nullglob
dmgs=( "$WORKDIR"/Ghostty*.dmg )
[ ${#dmgs[@]} -eq 1 ] || { echo "ERROR: create-dmg did not produce exactly one DMG (${#dmgs[@]})"; exit 1; }
mv "${dmgs[0]}" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 60m
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# ---- 8. signed appcast + publish -------------------------------------------
echo ">> [8/8] appcast + GitHub Release"
sign_update "$DMG" > "$WORKDIR/sign_update.txt"   # uses the keychain-stored Sparkle key
export GHOSTTY_BUILD GHOSTTY_COMMIT
export GHOSTTY_DMG_URL="https://github.com/$REPO/releases/download/$TAG/Ghostty.dmg"
export GHOSTTY_PUBDATE="$(date -u +'%a, %d %b %Y %H:%M:%S +0000')"
export GHOSTTY_MIN_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST" 2>/dev/null || echo 13.0)"
export SIGN_UPDATE_FILE="$WORKDIR/sign_update.txt"
export APPCAST_OUT="$WORKDIR/appcast.xml"
python3 dist/macos/fork_appcast.py
test -f "$WORKDIR/appcast.xml"

# Recipient-facing release notes (the first thing a colleague reads). Written to a
# file + --notes-file rather than an inline $(cat <<EOF) — a heredoc inside $() is
# mishandled by macOS's bash 3.2 (swallows the closing paren).
NOTES_FILE="$WORKDIR/release-notes.md"
cat > "$NOTES_FILE" <<EOF
**Ghostty (ramon)** — a personal fork of Ghostty that runs side-by-side with the official build.

**Install (2 min):** download \`Ghostty.dmg\` below → drag it to \`/Applications\` → open it → **relaunch once** (the hosted terminal backend turns on for the second launch). It's signed + notarized, so it should open cleanly; if macOS ever complains, right-click → Open.

**New here?** Start with the onboarding guide (install, the \`ctrl+a\` keybind cheat sheet, what's optional):
https://github.com/$REPO/blob/main/ONBOARDING.md

_Built from $GHOSTTY_COMMIT._
EOF

# Idempotent publish (no destructive delete window).
gh release create "$TAG" --repo "$REPO" --target "$GHOSTTY_COMMIT_LONG" \
  --title "Ghostty (ramon) build $GHOSTTY_BUILD ($GHOSTTY_COMMIT)" \
  --notes-file "$NOTES_FILE" --latest 2>/dev/null || true
gh release upload "$TAG" "$DMG" "$WORKDIR/appcast.xml" --repo "$REPO" --clobber
gh release edit   "$TAG" --repo "$REPO" --latest

echo ">> DONE: https://github.com/$REPO/releases/tag/$TAG"

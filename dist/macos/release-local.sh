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
TAG="build-${GHOSTTY_BUILD}"
echo ">> Releasing $TAG ($GHOSTTY_COMMIT) to $REPO"

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

# Idempotent publish (no destructive delete window).
gh release create "$TAG" --repo "$REPO" \
  --title "Ghostty (ramon) build $GHOSTTY_BUILD ($GHOSTTY_COMMIT)" \
  --notes "Local fork build from $GHOSTTY_COMMIT." --latest 2>/dev/null || true
gh release upload "$TAG" "$DMG" "$WORKDIR/appcast.xml" --repo "$REPO" --clobber
gh release edit   "$TAG" --repo "$REPO" --latest

echo ">> DONE: https://github.com/$REPO/releases/tag/$TAG"

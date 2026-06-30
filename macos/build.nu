#!/usr/bin/env nu

# Build the macOS Ghostty app using xcodebuild with a clean environment
# to avoid Nix shell interference (NIX_LDFLAGS, NIX_CFLAGS_COMPILE, etc.).

def main [
    --scheme: string = "Ghostty"       # Xcode scheme (Ghostty, Ghostty-iOS, DockTilePlugin)
    --configuration: string = "Debug"  # Build configuration (Debug, Release, ReleaseLocal)
    --action: string = "build"         # xcodebuild action (build, test, clean, etc.)
] {
    let project = ($env.FILE_PWD | path join "Ghostty.xcodeproj")
    let build_dir = ($env.FILE_PWD | path join "build")

    # Skip UI tests for CLI-based invocations because it requires
    # special permissions.
    let skip_testing = if $action == "test" {
        [-skip-testing GhosttyUITests]
    } else {
        []
    }

    (^env -i
        $"HOME=($env.HOME)"
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
        xcodebuild
        -project $project
        -scheme $scheme
        -configuration $configuration
        $"SYMROOT=($build_dir)"
        ...$skip_testing
        $action)

    # (ramon fork) Bundle the agent-manager sidecar into the built macOS .app so a
    # ReleaseLocal/Debug build is SELF-CONTAINED. The xcodeproj does NOT bundle the
    # sidecar (historically only dist/macos/release-local.sh did), so without this a
    # `ditto` deploy of the built app leaves a STALE Contents/Resources/agent-manager/dist
    # in place (ditto never deletes dst-only files) and the sidecar features — Agent
    # Queue / Manager / adopt-a-split — silently run OLD code. Only for a macOS `Ghostty`
    # `build`; reaching here implies xcodebuild succeeded (nu stops on a non-zero exit).
    if $action == "build" and $scheme == "Ghostty" {
        bundle-sidecar $build_dir $configuration
    }
}

# Copy (and, when a real node + installed deps are present, first rebuild) the
# agent-manager sidecar dist into the built app, then re-sign. Best-effort: it WARNS
# rather than failing the build, so a GUI-only iteration with no sidecar change still
# succeeds. Matches dist/macos/release-local.sh's bundle step (dist + package.json).
def bundle-sidecar [build_dir: string, configuration: string] {
    let app = ([$build_dir, $configuration, "Ghostty.app"] | path join)
    let src = ($env.FILE_PWD | path join "agent-manager")
    if not ($app | path exists) {
        print $"WARNING: built app not found at ($app); skipping sidecar bundle."
        return
    }
    if not ($src | path exists) { return }

    # nvm's node lives outside the clean xcodebuild PATH; locate it explicitly. A plain
    # `bash -c` (non-login) won't see nvm's shell-function shims, so `npm` resolves to the
    # real binary alongside node. Only rebuild when deps are already installed (no network).
    let node_glob = (glob $"($env.HOME)/.nvm/versions/node/*/bin/node")
    let node_dir = (if ($node_glob | is-empty) { "" } else { ($node_glob | sort | last | path dirname) })
    if ($node_dir | is-not-empty) and (($src | path join "node_modules") | path exists) {
        print "bundle-sidecar: rebuilding agent-manager dist (npm run build)…"
        try {
            (^env -i $"HOME=($env.HOME)" $"PATH=($node_dir):/usr/bin:/bin" bash -c $"cd '($src)' && npm run build")
        } catch {
            print "WARNING: sidecar `npm run build` failed; bundling the EXISTING dist instead."
        }
    } else {
        print "bundle-sidecar: node/node_modules not found; bundling the EXISTING dist (run `npm run build` in macos/agent-manager to refresh it)."
    }

    let dist = ($src | path join "dist")
    if not (($dist | path join "index.js") | path exists) {
        print "WARNING: macos/agent-manager/dist/index.js missing — run `npm run build` in macos/agent-manager. Sidecar NOT bundled; the app may ship a STALE or absent sidecar."
        return
    }

    let dst = ([$app, "Contents", "Resources", "agent-manager"] | path join)
    mkdir $dst
    rm -r -f ($dst | path join "dist")
    cp -r $dist ($dst | path join "dist")
    cp ($src | path join "package.json") $dst

    # Re-sign: xcodebuild already signed the app and we just modified Resources. Match the
    # CLAUDE.md install block's ad-hoc deep sign so the locally-runnable app stays valid.
    (^xattr -cr $app)
    (^codesign --force --deep --sign - $app)
    print $"bundle-sidecar: bundled + re-signed agent-manager sidecar into ($app)"
}

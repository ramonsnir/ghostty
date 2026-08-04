# Fork identity, distribution & first-launch setup

How the fork stays distinct from an official Ghostty (bundle id / icon / update
feed), how colleague DMGs are built + released, and what `ForkSetup` does on first
launch. The fork-only config-key **index** lives in `CLAUDE.md` (Fork-only config
keys); this doc has the mechanisms. See also `SHARING.md` (user-facing) and
`PTYHOST.md` (the bundled host + LaunchAgent).

## Fork-identity / non-functional changes
- **Bundle id** `com.mitchellh.ghostty-ramon` for Release, `.local` for the in-tree ReleaseLocal dev build, `.debug` for Debug — all coexist with the official `com.mitchellh.ghostty`, each with its own state/defaults domain. (`macos/Ghostty.xcodeproj/project.pbxproj`, `DockTilePlugin.swift` reads the host bundle id at runtime so each domain reads its own defaults.)
- **Display name** "Ghostty (ramon)" for Release, "Ghostty (ramon-local)" for ReleaseLocal — so the installed app and the in-tree dev build are visually distinguishable in the dock and ⌘-Tab.
- **Single-instance guard** in `AppDelegate.applicationWillFinishLaunching`: if another process with the same bundle id is already running from a different bundle URL, that one is activated and this process exits. Stops two copies of the same fork identity from racing each other (e.g. dock-attention bouncing one while you click the other).
- **Icon** defaults to `chalkboard` (`macos-icon` default in `src/config/Config.zig`); macOS swaps it per build at runtime so each identity is distinct at a glance — Release stays on `chalkboard`, ReleaseLocal becomes `paper`, Debug becomes `blueprint`. The swap fires only when the resolved icon is the fork default, so an explicit non-chalkboard `macos-icon` still wins. (`macos/Sources/Features/Custom App Icon/AppIcon.swift`)
  - **Custom-icon write self-heal (fork-only, GUI-only; always on).** The fork applies the
    chosen icon at RUNTIME via `NSWorkspace.setIcon(image, forFile: bundlePath)` in
    `AppIconUpdater.update`, which writes the `Icon\r` resource + the Finder `kHasCustomIcon`
    bit at the BUNDLE ROOT (outside the signed `Contents/`). **That write can land HALF-DONE
    during a busy boot** — the bit set but `Icon\r`'s resource fork EMPTY — which macOS renders
    as a generic **FOLDER icon**. The fork amplifies the trigger: it forces window-state
    restoration ON (`quitAlwaysKeepsWindows`), so macOS auto-relaunches the app EARLY at login
    after a laptop restart, right when the FS is busiest. This hits EVERY Release install (local
    AND DMG colleagues) — same bundle id `com.mitchellh.ghostty-ramon` → same chalkboard runtime
    swap. Fix: `update(icon:)` no longer trusts `setIcon` — it VERIFIES the write produced real
    icon data (`bundleShowsFolderFallback`), RETRIES a few times (`iconWriteAttempts`=3, backoff
    `iconWriteRetryDelays` 0.5s/1.5s, made `async` for the sleeps — the sole caller already
    `await`s), and if it still fails CLEARS the broken state (`clearCustomIcon`) so the app
    degrades to its baked-in icon, NEVER a folder. **The detection predicate rests on the storage
    mechanism (empirically confirmed on this macOS):** a HEALTHY custom icon = FinderInfo byte 8
    has `0x04` (kHasCustomIcon) AND `Icon\r` carries a non-empty `com.apple.ResourceFork` xattr
    (~1.7 MB; its DATA fork is 0 bytes even when healthy — so DON'T size-check the data fork). The
    BROKEN/folder-fallback state = bit set AND that resource fork empty/absent; an empty `Icon\r`
    with the bit CLEAR is benign (seen on the Debug build). Pure predicate
    `AppIconUpdater.isFolderIconFallback(finderInfo:iconResourceForkLength:)` (byte-8 `0x04` mask +
    `≤0` length); impure `bundleShowsFolderFallback` / `clearCustomIcon` use `getxattr`/`setxattr`/
    `removexattr` (needs `import Darwin`). Manual one-off repair (if a build predates this fix):
    `rm "<app>/Icon"$'\r'` + `xattr -d com.apple.FinderInfo "<app>"` + refresh (`lsregister -f`,
    `killall Dock`). GUI relaunch only, no host/Zig change (ships to colleagues via Sparkle).
    Wiring: `macos/Sources/Features/Custom App Icon/AppIcon.swift` (`import Darwin`;
    `AppIconUpdater` verify/retry/`clearCustomIcon`/`isFolderIconFallback`/`bundleShowsFolderFallback`).
    Tests: `macos/Tests/AppIconUpdaterTests.swift` (pure-predicate matrix + a temp-dir round-trip
    that reproduces the broken state via xattrs, asserts detection, then self-heals it).
- **Auto-update via Sparkle, pinned to the fork's OWN GitHub Releases feed** (was hard-disabled; re-enabled for colleague distribution). Sparkle starts normally but `UpdateDelegate.feedURLString` points at `github.com/ramonsnir/ghostty/releases/latest/download/appcast.xml`, never ghostty.org, so the fork is never replaced by an official build. Dev builds still don't auto-check (`Ghostty-Info.plist` ships `SUEnableAutomaticChecks=false`); the CI release build deletes that key. The committed `SUPublicEDKey` is the fork's OWN real public key (generated at enrollment via Sparkle `generate_keys`; public keys aren't secret), matching the `SPARKLE_PRIVATE_KEY` CI secret; CI re-injects `SPARKLE_PUBLIC_KEY` as belt-and-suspenders. (`UpdateController.hasPlaceholderUpdateKey` still guards the all-zero placeholder so a future placeholder build fails closed.) See "Distribution / sharing the fork" below. (`macos/Sources/Features/Update/{UpdateController,UpdateDelegate}.swift`)
- **App Nap opt-out (fork-only, macOS; always on)** — `AppDelegate.applicationDidFinishLaunching` holds a process-lifetime `ProcessInfo.beginActivity(.userInitiatedAllowingIdleSystemSleep)` token (`appNapAssertion`) so macOS never naps/throttles the GUI while backgrounded or occluded. **Load-bearing for the `.client` backend:** the host connection is opened from per-surface IO threads at surface creation and is **single-shot (no retry — see `src/termio/Client.zig` `connectAndAttach`)**, so if the GUI is relaunched into the background with **no active display** (a remote restart while away), App Nap can suspend those threads before they connect to `ghostty-host`, leaving every restored surface permanently blank until a manual restart-while-present. This is exactly the 2026-06 weekend symptom ("restarted Ghostty remotely while away → monitor showed empty surfaces all weekend; restarting while at the Mac fixed it"). The `...AllowingIdleSystemSleep` option opts out of App Nap **without** preventing system/display sleep (it omits the idle-sleep-disable bits), so battery/sleep behavior is unchanged — we only decline to be napped (it also disables sudden/automatic termination, desirable for a terminal). Note: a connect-retry/reconnect in the `.client` backend was considered and **deliberately skipped** — the host is a KeepAlive LaunchAgent (≈always up, so connect rarely fails) and a dropped host can't restore RAM-only sessions anyway, so it was high-risk surgery on the most delicate lifecycle code for an unobserved failure mode. (`macos/Sources/App/macOS/AppDelegate.swift`)
- **Config separation**: the fork additionally loads `~/.config/ghostty-ramon/config` on top of the shared `~/.config/ghostty/config`. Put fork-only keybinds **and fork-only config keys** there so an official Ghostty (which shares `~/.config/ghostty/config`) never errors on unknown actions or keys. The canonical **index of every fork-only config key** (grouped, with types + which are secrets) lives in `CLAUDE.md` → "Fork-only config keys"; keep that index in sync whenever a key is added. Mechanism: `src/config/file_load.zig` `forkXdgPath`, `Config.zig` `loadDefaultFiles`.

- **Config files & secrets** (tracked example copies): the repo keeps reference
  copies of both live config files under **`example/`** — `example/ghostty/config`
  (mirror of the shared `~/.config/ghostty/config`) and `example/ghostty-ramon/config`
  (mirror of the fork-only `~/.config/ghostty-ramon/config`). These are the starting
  point for setting the fork up on a new Mac (clone, build, copy these two into
  `~/.config/`). **Keep them in sync with the on-disk files** — whenever you change
  either live config, re-copy it into `example/` in the same commit — **EXCEPT first
  sanitize any real-world names/paths per the "No real-world names" rule above.** The
  tracked `example/` copies use neutral placeholders (e.g. `~/git/your-project`,
  `Acme Foods`) and therefore intentionally diverge from the live files on those
  values; **never re-copy a real customer / personal / private-project name or path
  from a live config back into `example/`.** **They must also contain NO secrets and
  NO per-machine values.** Secrets + machine-specific
  values instead live in the **untracked** `~/.config/ghostty-ramon/local`, which the
  tracked fork config pulls in via an optional include
  (`config-file = ?~/.config/ghostty-ramon/local` — the `?` suppresses the
  file-not-found error, and config-file entries load *after* the file that defines
  them, so `local` cleanly supplies/overrides values). What lives in `local` today:
  `mcp-token` and `web-monitor-token` (both shell-execution credentials). NOTE:
  `web-monitor-listen` is **no longer** a per-machine value — the supported setup binds
  **loopback** `127.0.0.1:18787` (same on every Mac, fronted by `tailscale serve` for
  HTTPS — see WEB-MONITOR.md), so it can live in the tracked config; do NOT bind a
  Tailscale IP / `0.0.0.0` (unsupported: plain HTTP, breaks Web Push). When adding a new
  secret, put it in `local`, not in the tracked config. On a new machine, create `local`
  by hand (generate a fresh `mcp-token` with `openssl rand -hex 24`); if `local` is absent
  the fork still launches (MCP token-less / web monitor disabled until you add a token).

## Distribution / sharing the fork (colleague builds, CI release, auto-update)

The fork can be shared with colleagues as a signed/notarized DMG, released from the
PRIMARY local build script `dist/macos/release-local.sh` (the manual-only
`workflow_dispatch` CI workflow `fork-release.yml` is a fallback — NOT auto-on-push),
with in-app Sparkle updates. **User-facing guide: `SHARING.md`.** The load-bearing
facts for an agent touching this code:

- **Sparkle is RE-ENABLED but pinned to the fork's OWN feed.** `UpdateController`'s
  three methods (startUpdater/checkForUpdates/validateMenuItem) are restored to the
  real upstream implementation; `UpdateDelegate.feedURLString` points BOTH channels
  at `https://github.com/ramonsnir/ghostty/releases/latest/download/appcast.xml`
  (never ghostty.org — so the fork is never replaced by an official build). The
  committed `Ghostty-Info.plist` still ships `SUEnableAutomaticChecks=false`, so dev
  builds never auto-check; the CI release build DELETES that key (enables checks) and
  injects the fork's `SUPublicEDKey`. Wiring: `macos/Sources/Features/Update/{UpdateController,UpdateDelegate}.swift`.

- **First-launch setup (`ForkSetup`, GUI-only, distribution builds).** Idempotent, safe on
  every launch, and now SPLIT in two by launch ordering: `performHostSetup()` (host-critical)
  + `performDeferred()` (the rest); `perform()` still runs both for callers/tests. SEVEN jobs
  total: (1) seed a sanitized `~/.config/ghostty-ramon/config` if absent (embedded
  `seedTemplate`, `__HOME__` substituted, the whole `ctrl+a` keybind layer commented out, open
  `mcp-listen`/`web-monitor-listen` disabled — see the seed bullet below); (2) **auto-provision
  the untracked machine-local `~/.config/ghostty-ramon/local`** with `mcp-listen` + a CSPRNG
  `mcp-token` (see the local-secrets bullet below); (3) install/version-reload a launchd
  LaunchAgent that runs the host-handoff **SUPERVISOR** (`ghostty-host --supervise
  --listen=<socket>`, same binary BUNDLED at `Contents/MacOS/ghostty-host`; it fork/execs the
  worker that serves GUI sessions — see the two-identity reload paragraph below + HOST-HANDOFF.md); (4) install the
  bundled `ghostty-mcp` shim onto PATH (see the MCP-shim bullet below); (5) install a
  **`ghostty-ramon` CLI launcher** onto PATH (see the next bullet); (6) fire a **one-time
  first-run welcome notification** (idempotent via the persisted `forkSetup.welcomeShown`
  bool; pure predicate `shouldShowWelcome(alreadyShown:)`) that points the colleague at
  `ghostty-ramon +list-keybinds` / `ONBOARDING.md` — concrete discovery, NOT "scroll the
  command palette". The welcome bool is recorded BEFORE `notify()` fires so a failed/denied
  notification can't re-fire it every launch; (7) **auto-register the Ghostty MCP server with
  Claude Code** (`claude mcp add ghostty --scope user -- ~/.local/bin/ghostty-mcp`) so a fresh
  `claude` session can SEE it — see the MCP-registration bullet below. **`performHostSetup()` (jobs 1–3) runs
  SYNCHRONOUSLY and EARLY in `AppDelegate.applicationDidFinishLaunching` — before any window/
  `.client` surface is created — so the bundled host is installed + bootstrapped + RUNNING
  before a surface dials its socket, eliminating the blank-pane race** (steady-state fast path:
  one `launchctl print`; only first-install/version-change spends the bootstrap budget). It
  returns a Bool (true iff a host is bundled = the distribution path); the deferred jobs 4–6
  run off-main only when it returned true. **HONEST CAVEAT: pty-host still only takes EFFECT on
  the SECOND launch on a fresh machine** — the GUI reads `pty-host` in `Ghostty.App.init()`
  (before any launch callback), so the freshly-seeded value isn't seen until the next launch.
  `performHostSetup()` removes the connection RACE on every configured launch, not the one-time
  relaunch (no `Client.zig` connect-retry was added — deliberate). **⭐ The MCP / web-monitor /
  agent-manager servers, by contrast, DO start on the FIRST launch (issue #4 fix):** those gates
  read `mcp-listen`/`mcp-token`/`web-monitor-listen` from `ghostty.config` LATER in
  `applicationDidFinishLaunching`, so right after `performHostSetup()` seeds the config + `local`
  the AppDelegate calls `ghostty.reloadConfigFromDisk()` (a new synchronous `Ghostty.App` reload
  that reassigns `self.config` right away, unlike `reloadConfig(soft:)` which relies on the async
  `configChange` callback) — so the gates read the freshly-seeded values instead of the stale
  in-memory config, and the MCP server is listening on the very first launch (Claude Code no
  longer shows "MCP not connected" until a relaunch). Gated on `performHostSetup()`'s bundled-host
  return (dev/local builds never pay it); idempotent + cheap on steady-state launches (files
  already existed at `init`, so the reload yields identical values). `pty-host` can't ride this —
  it's consumed in `Ghostty.App.init` before any launch callback runs, so it alone still needs the
  second launch. Wiring: `Ghostty.App.swift` (`reloadConfigFromDisk()`), `AppDelegate.swift` (the
  `if forkHostSetupRan { ghostty.reloadConfigFromDisk() }` before the initial config load +
  server gates). Test: `ConfigTests.reloadPicksUpNewlySeededMCPKeys` (a config with no MCP keys
  reports them after a disk reload). **Two safety gates make it
  impossible to clobber a hand-managed host** (Ramon's own dev setup uses the SAME label
  `com.mitchellh.ghostty-ramon.host`): it only acts when a host is actually bundled
  (local/dev builds skip — they don't bundle it), and it writes an ownership marker
  (`GhosttyAppManaged` = bundle id) into any plist it creates, refusing to touch a
  pre-existing plist that lacks the marker. **The host reload is gated on a TWO-IDENTITY
  split — a SUPERVISOR identity + a WORKER identity — NOT the binary hash and NOT the bundle
  version** (host-handoff; see HOST-HANDOFF.md). Both are carved IN SWIFT from the SAME packed
  `ghostty_host_reload_identity()` (= protocol `PROTOCOL_VERSION_MAJOR`/`MINOR` + the GUI-side
  `host_reload_epoch` const in `embedded.zig`) by the pure `decodeReloadIdentities` — **no new
  C export**. FIRST-CUT MAPPING (documented in the code + HOST-HANDOFF.md): **supervisor
  identity = protocol MAJOR** (rare); **worker identity = protocol MINOR + `host_reload_epoch`**
  (common). `plan(...)` compares each recorded identity (`kInstalledHostSupervisorIdentity` /
  `kInstalledHostWorkerIdentity`) against the current:
  - **Worker identity changed, supervisor unchanged, supervisor RUNNING → `.handoffWorker`**
    (the COMMON path): the executor resolves the running supervisor's pid from `launchctl
    print` and `kill(pid, SIGHUP)`s it, so the supervisor re-execs its worker from the current
    bundle and BROKERS a freeze→adopt handoff — **NO bootout, sessions SURVIVE, no LWCR reload**
    (the new worker's cdhash is a supervisor child, not a launchd job). A worker change with no
    running supervisor is `.revive` (nothing to SIGHUP; bring the supervisor up).
  - **Supervisor identity changed → `.reload`** (the RARE, destructive `bootout`+`bootstrap`
    that re-derives launchd's LWCR and KILLS the host's RAM-only sessions). A concurrent worker
    change is dominated — a fresh supervisor re-establishes the whole job.
  - **Both unchanged → `.upToDate`** (healthy) / `.revive` (down) — so a GUI-only update (host
    recompiled to a new cdhash but same protocol/epoch) preserves sessions.

  **Why identity, not the cdhash: the notarized host's launchd LWCR is pinned to the
  Developer-ID identity (identifier + Team ID `72PSTG4224`), NOT the cdhash** — verified
  empirically (`codesign -dr -` shows no cdhash clause; a re-signed same-identity binary
  respawns under the old LWCR with no exit-78). So a new same-identity supervisor build
  satisfies the existing LWCR and loads on the next natural restart with NO reload. **⭐ THE
  NO-RECORDED-SUPERVISOR-IDENTITY BRANCH DISAMBIGUATES ON THE EXISTING PLIST'S ARGS** (pure
  `plistRunsSupervisor`, from the SAME single plist parse as the ownership marker — see
  `readPlist`), because a colleague reaching it is in ONE of two OPPOSITE situations:
  - **Genuine supervisor, record lost** (existing plist already runs `--supervise`): defaults
    were wiped but a real supervisor is up → `.adoptRunning` (running) / `.revive` (down),
    **`bootout: false`**, recording both identities WITHOUT killing sessions.
  - **Plain pre-supervisor host** (existing plist is `--listen`-only — the OLD build wrote a
    plain plist + only the single-key `kInstalledHostReloadIdentity`): this is the **ONE-TIME
    plain-host → supervisor switchover (P4)** → `.reload` when running (bootout the plain host,
    bootstrap the supervisor — the single unavoidable session-losing deploy), `.revive` when
    down (nothing to lose). **This is the bug-fix:** adopting a plain host as if it were a
    supervisor would leave a plain host under a supervisor plist (EPERM risk) and a later
    `.handoffWorker` would SIGHUP-KILL it (a plain host's default SIGHUP action is termination).
    After this one `.reload`, worker upgrades are non-destructive `.handoffWorker`s.

  (The two-key gate supersedes the former single `kInstalledHostReloadIdentity`, itself the
  successor to the SHA-256 hash gate `kInstalledHostHash`.) **⚠️ THE ONE RULE THAT KEEPS THE
  GENUINE-SUPERVISOR adopt SAFE: do NOT bump the protocol MAJOR in a release a colleague first
  adopts under** (while a genuine supervisor has no recorded identity): `.adoptRunning` leaves
  the OLD supervisor running without a reload, so a simultaneous MAJOR bump would leave a
  major-N GUI talking to a major-(N−1) host → handshake REJECTED → empty surfaces until a manual
  host restart. A protocol MINOR bump is safe (negotiated down; now a worker handoff), and a
  MAJOR bump is safe once every colleague has a recorded identity (then `plan` takes the normal
  `.reload` path). **The cdhash-pinning exit-78
  crash-loop gotcha still applies to Ramon's HAND-BUILT ad-hoc dev host (no cert chain → DR
  falls back to cdhash) — but that host is hand-managed, untouched by ForkSetup.** ONE RESIDUAL
  (a follow-up): the SUPERVISOR ideally runs from a STABLE path outside the churning bundle so
  its OWN exec path never goes stale; the first cut bundles it (same path as before), and the
  supervisor's own exec-path self-check WARNS if the bundle moves. Pure planner `plan(...)`,
  `makeSpec`, `configSeedContents`, `readPlist`/`readPlistMarker`, `plistRunsSupervisor`,
  `planCLIInstall`, `shouldShowWelcome`,
  `planLocalSecretsInstall`, `localHasMCPToken`, `planMCPRegister` are unit-tested. Wiring:
  `macos/Sources/Features/ForkSetup/ForkSetup.swift` (`import Security` for the CSPRNG;
  `registerMCPWithClaudeIfNeeded` + `loginShellStatus`/`claudeOnPath`/`ghosttyMCPRegistered`),
  `AppDelegate.swift` (the synchronous `performHostSetup()` call + the off-main
  `performDeferred()`), `project.pbxproj` (iOS exclusion). Tests:
  `macos/Tests/ForkSetup/ForkSetupTests.swift` (incl. `cli*` plan gates, `welcome*`,
  `mcpRegister*`, `localSecrets*`/`generateMCPToken`/`localHasMCPToken`, the TWO-IDENTITY reload
  gate `planUpToDateWhenBothIdentitiesMatch` / `planHandsOffWorkerWhenWorkerMinorChangedAndRunning`
  / `planHandsOffWorkerWhenEpochBumpedAndRunning` / `planReloadsWhenSupervisorIdentityChanged*` /
  `planReloadDominatesWhenBothIdentitiesChangedAndRunning`, the migration disambiguation
  `planAdoptsRunningSupervisorWhenNoRecordedIdentityAndPlistIsSupervisor` (lost-record recovery) vs
  `planReloadsWhenNoRecordedIdentityAndExistingPlistIsPlainHostAndRunning` (the one-time plain-host→
  supervisor switchover) / `planRevivesWhenNoRecordedIdentityAndPlainPlistNotRunning` /
  `plistRunsSupervisorDetectsSuperviseFlag` / `readPlistExtractsSupervisorProgramArgumentsEndToEnd` /
  `decodeReloadIdentitiesCarvesSupervisorMajorAndWorkerMinorEpoch`, and the seed-content
  `configSeed*` assertions incl. the `--supervise` ProgramArguments). **This change is Swift/GUI-only:
  it reuses the EXISTING `ghostty_host_reload_identity()` export (carving supervisor-vs-worker in
  Swift), so it needs NO new C export and NO lib/xcframework rebuild for the identity split** — the
  Zig side is untouched by ForkSetup here (the supervisor/worker/broker Zig lives in `src/host/`,
  a HOST change deployed by the deliberate P4 switchover; see HOST-HANDOFF.md).

- **Auto-provisioned MCP secrets (`~/.config/ghostty-ramon/local`, ForkSetup job 2).** On
  first launch the fork writes the untracked machine-local `local` with `mcp-listen =
  127.0.0.1:8765` + a freshly-generated CSPRNG `mcp-token` (`generateMCPToken` = 32
  `SecRandomCopyBytes` bytes → 64 hex chars, well over the 16-byte floor), so the MCP server,
  the `ghostty-mcp` shim, the Claude agent-state hooks, and the dashboard chips / agent queue /
  manager **work OUT OF THE BOX with no hand-written token** (the seeded config already pulls
  `local` in via the optional include). Pure decision `planLocalSecretsInstall(localExists:
  hasToken:)` → `.skipHasToken` / `.create` / `.append`: it NEVER rotates or clobbers an
  existing token (presence of a non-comment `mcp-token`, detected by `localHasMCPToken`, is the
  idempotency key); a missing `local` is created with a header; an existing `local` WITHOUT a
  token is APPENDED to (preserving any other machine-local keys like `web-monitor-listen`).
  Impure `seedLocalSecretsIfNeeded`; the token value is never logged. Wiring/Tests as in the
  ForkSetup bullet above.

- **`ghostty-ramon` CLI launcher on PATH (fork-only, ForkSetup job 4).** A SYMLINK at
  `~/.local/bin/ghostty-ramon` → the app's multitool binary `Contents/MacOS/ghostty`, so a
  colleague can run discovery commands like `ghostty-ramon +list-keybinds` /
  `ghostty-ramon +show-config` (the cheat-sheet entrypoint the seed + welcome point at).
  **Named `ghostty-ramon`, NOT `ghostty`,** so it can't collide with an official ghostty CLI
  already on PATH. A SYMLINK (not a copy) so it always tracks the installed app — no rewrite
  when a Sparkle update relocates the bundle. Idempotent + version-aware with the SAME safety
  gates as the MCP shim, via the pure `planCLIInstall(...)` → `CLIPlan` (`.skipNoBundledBinary`
  / `.skipExternallyManaged` / `.upToDate` / `.install`): acts only when the multitool is
  actually BUNDLED, NEVER clobbers a pre-existing NON-managed file (only a symlink WE created —
  one whose resolved destination is THIS app's multitool, recognized by `symlinkPointsAt`), and
  reinstalls on a deleted symlink or a `CFBundleVersion` change (recorded in
  `forkSetup.cliLauncherVersion`). Because `perform()` early-returns unless a host is bundled, a
  dev/local build never installs it (so it can't overwrite Ramon's own PATH). Wiring:
  `ForkSetup.swift` (`CLIPlan`/`planCLIInstall`/`installCLILauncherIfNeeded` +
  `fileExistsOrSymlink`/`symlinkPointsAt` helpers). Tests: `ForkSetupTests.swift` (`cli*`).

- **Seed-template REFRAME — FEATURE-FIRST, keybindings opt-in (`ForkSetup.seedTemplate`).**
  The auto-seeded `~/.config/ghostty-ramon/config` no longer IMPOSES the personal keybind
  layer (all asserted by `configSeed*` tests): (1) **the WHOLE tmux-style `ctrl+a` keybind
  layer is COMMENTED OUT** at the bottom of the file under an "OPTIONAL: my personal tmux-style
  `ctrl+a` keybindings — ALL COMMENTED OUT" header — nothing is bound for a colleague (so any
  matrix/example claim that the seed ships ACTIVE fork keybinds is no longer true). (2) the
  top-of-file **QUICK START** block now explains the FEATURES and the **Command Palette**
  (cmd+shift+p → type "split"/"tab"/"project"/"agent"), not keybindings, with the discovery
  pointers `ghostty-ramon +list-keybinds` / `+show-config --default --docs` and ONBOARDING.md.
  (3) feature SETTINGS stay ACTIVE — `agent-dashboard = true`, `agent-dashboard-commands`,
  `auto-update = check`, `bell-features`, the `pty-host` socket (parameterized), etc.; only the
  binds are commented. (4) `agent-queue = true` is present but COMMENTED (opt-in; needs node +
  the agent-state hooks + a template). (5) `project-directory = ~/git` is COMMENTED (so an
  unconfigured machine doesn't get an empty project picker). (6) softened
  `bell-features-focused` = VISUAL-ONLY `no-system,no-attention,no-title` (was
  `system,no-attention,no-title`) — no audible beep while the ringing split is focused. (7) the
  MCP section documents that `local` is AUTO-PROVISIONED with a bind + random token on first
  launch (no longer "enable only WITH a hand-written token"). (Keep `example/ghostty-ramon/config`
  in sync if the live config also changes — the seed is a separate sanitized template, not a
  copy of `example/`.)

- **`claude-hooks` + `ONBOARDING.md` bundled into `Contents/Resources` (BOTH release
  paths).** The colleague-onboarding deliverables ship INSIDE the notarized bundle (carried
  by Sparkle, like the host / shim / agent-manager sidecar): the Claude Code agent-state
  hooks (`example/claude-hooks/` → `Contents/Resources/claude-hooks/`) so a DMG user has the
  hook script + settings block locally (the dashboard per-tile state + the queue auto-close
  depend on it — see AGENT-DASHBOARD.md), and `ONBOARDING.md` → `Contents/Resources/` so the
  cheat-sheet the seed/welcome point at travels with the app (no repo clone needed). Both
  release paths copy them alongside the existing agent-manager bundle step: the PRIMARY local
  `dist/macos/release-local.sh` and the manual-only `.github/workflows/fork-release.yml`.
  DMG-user install instructions reference the bundled `…/Contents/Resources/claude-hooks`
  path; repo-clone developers keep using `example/claude-hooks/` (see AGENT-DASHBOARD.md).

- **`ONBOARDING.md` (repo-root colleague onboarding doc).** The single concrete onboarding
  entrypoint a colleague is pointed at by the first-run welcome notification, the seed config
  header, and SHARING.md — deliberately NOT "browse the command palette" (colleagues won't).
  Covers the keybind cheat sheet (`ctrl+a` prefix gestures), discovery commands
  (`ghostty-ramon +list-keybinds` / `+show-config`), and the works-OOTB-vs-needs-setup
  feature matrix. Bundled into `Contents/Resources` (above) so DMG users have it locally.

- **PRIMARY release path = LOCAL + FREE (`dist/macos/release-local.sh`).** Builds +
  signs + notarizes + DMGs + appcasts + `gh release`-publishes on your Mac. **Why not
  CI:** GitHub macOS runners bill at ~10x, the actool/Liquid-Glass-icon crash forces the
  scarce native `macos-26` image (long queues), and a backlogged Apple notary can sit
  `In Progress` until the 90-min job timeout — one run cost ~$9 of macOS minutes for a
  release that never even published. Notarization is Apple's FREE service; only the CI
  *runner time* costs money, so doing it locally is $0 (notary slowness = wall-clock
  only). Release assets are free and separate from Git LFS. Run it from `ramon-fork`
  on the main tree. **It PUSHES `ramon-fork` → `fork/main` FIRST (after a `[y/N]`
  confirmation; `RELEASE_YES=1` skips the prompt for unattended/monitor runs), then
  tags the release at the EXACT built commit** (`gh release create --target <sha>`),
  with a UNIQUE per-commit tag `build-<N>-<shortsha>`. This is load-bearing: the script
  builds the LOCAL working tree, so without the push the released binary's source isn't
  on GitHub and `gh` would otherwise tag `fork/main`'s (stale) head — the binary/tag/
  build-number mismatch that bit us once (released `build-16645` from local `f174b8a27`
  while the tag pointed at the older pushed `243f953`). Distinct commits → distinct
  preserved releases (old ones never deleted; only the `--latest` pointer moves);
  re-running on the SAME commit re-publishes that one tag idempotently. A guard refuses
  to release unless `HEAD == ramon-fork`. **One-time per machine:** Developer ID cert in the login keychain;
  Sparkle private key in the keychain (`sign_update` uses it automatically — no file);
  `sign_update`+`generate_keys` on PATH (copied to `~/.local/bin`) and `create-dmg`
  (`npm i -g create-dmg`). **nvm note:** when `create-dmg`/`node` live under nvm and
  aren't on a non-login/GUI shell's PATH (and `node`/`npm` are recursive lazy-load
  shims), the script SELF-HEALS — it `unset -f node npm` and prepends the nvm node bin
  that has `create-dmg`, so an unattended/monitor run from such a shell still works (no
  manual PATH setup). A Homebrew `create-dmg` already on PATH makes that a no-op. A
  notary keychain profile —
  `xcrun notarytool store-credentials ghostty-ramon-notary --key <AuthKey.p8> --key-id <ID> --issuer <UUID>`.
  **Notary note:** in steady state notarization is FAST (sub-minute per submit). The one
  historical exception was this account's FIRST submissions right after enrollment, which
  sat `status: In Progress` for a long time (one-time Apple-side provisioning) — long since
  resolved; don't expect it. If a submit ever DOES stall, it's Apple-side, not our artifact
  (a bad zip is `Invalid` with a `notarytool log`), so don't burn CI on it (a slow CI run
  there once cost ~$9 in macOS minutes) — check `developer.apple.com/system-status`
  (Developer ID Notary Service) and just re-run the local script; `xcrun notarytool history
  --keychain-profile ghostty-ramon-notary` shows whether old submissions drained.
- **CI release (`.github/workflows/fork-release.yml`) — MANUAL-ONLY fallback.** Its
  `on:` is `workflow_dispatch` only (NOT `push`) precisely so normal pushes don't burn
  macOS minutes; trigger it by hand only if you can't build locally (and expect
  `macos-26` queue + notary cost). It builds on `macos-26` (the `macos-15` image crashes
  AssetCatalogAgent on the Liquid Glass `.icon` via a MediaToolbox override cryptex).
  Fork-only (`if:
  github.repository == 'ramonsnir/ghostty'`); the inherited upstream CI/release +
  vouch/issue-template workflows were REMOVED from the fork (issue #1 — "reset issue
  templates and such for the fork to be independent"), so `fork-release.yml` is now the
  ONLY workflow under `.github/workflows/` (the upstream ones were previously left inert
  via owner/tag/repo guards; they are gone now, not merely guarded). Builds the
  xcframework + `ghostty-host` (`nix develop -c zig build … -Demit-macos-app=false`),
  builds the app (`xcodebuild -configuration Release` → already the fork's Release id +
  display name), bundles + signs the host AND the `ghostty-mcp` shim inside the app, injects
  `CFBundleVersion=git rev-list --count HEAD` (monotonic — Sparkle compares this),
  signs/notarizes/staples, builds the DMG (`create-dmg`), generates a SINGLE-item signed
  appcast (`dist/macos/fork_appcast.py`, enclosure → the release's DMG URL), and
  publishes a `build-<N>` GitHub Release marked `--latest` (so the
  `releases/latest/download/{Ghostty.dmg,appcast.xml}` URLs resolve). **Signing is
  gated on secrets** (`HAS_SIGNING`): without them the job is a build-only smoke test
  that uploads the unsigned `.app` as an artifact and creates NO release. Secrets
  (fork-owned): `MACOS_CERTIFICATE`/`_PWD`/`_NAME`, `MACOS_CI_KEYCHAIN_PWD`,
  `APPLE_NOTARIZATION_ISSUER`/`_KEY_ID`/`_KEY`, `SPARKLE_PRIVATE_KEY`/`SPARKLE_PUBLIC_KEY`.

- **The host is bundled IN the app for colleagues** (vs. Ramon's `~/.local/bin`
  hand-deploy), so Sparkle — which only updates the `.app` — carries new host builds,
  and notarization covers the host automatically. A colleague's update restarts the host
  (ends live RAM-only sessions) **only when the host RELOAD IDENTITY changed** (protocol
  version or the manual `host_reload_epoch`) — the ForkSetup reload is identity-gated (see
  the First-launch-setup bullet), so a GUI-only update — even one that recompiles the host
  to a new cdhash — leaves the running host (and its sessions) untouched. This relies on the
  notarized host's LWCR being Developer-ID-identity-pinned (verified), so the new same-identity
  binary loads on the next natural restart without a reload.

- **The `ghostty-mcp` shim is bundled + installed-to-PATH for colleagues too** — same
  pattern as the host, so the MCP agent-control feature isn't dropped from the DMG. **BOTH
  release paths** `swift build -c release`s the shim and copies+signs it into
  `Contents/MacOS/ghostty-mcp` (alongside the host, inside the notarized bundle, carried by
  Sparkle): `dist/macos/release-local.sh` step 3a (the PRIMARY local path — it was MISSING
  this until 2026-06-24, so locally-cut DMGs shipped no shim) and the CI workflow
  (`.github/workflows/fork-release.yml`, the manual-only fallback). On first launch
  `ForkSetup.installShimIfNeeded` copies it onto PATH at `~/.local/bin/ghostty-mcp`
  (version-aware via `kInstalledShimVersion`; reinstalls on a Sparkle bump or a manual
  delete). **Safety is symmetric with the host:** `planShimInstall` only acts when a shim
  is actually BUNDLED, and the whole of `perform()` early-returns unless a host is bundled
  — so a dev/local build never overwrites Ramon's hand-installed `~/.local/bin/ghostty-mcp`.
  The copy is a byte-level `Data.write(.atomic)` (NOT `copyItem`) so the bundle's quarantine
  xattr doesn't propagate to the loose copy. The colleague no longer registers by hand —
  ForkSetup job 7 runs `claude mcp add` for them (see the next bullet; token auto-read from
  `local`); the committed `.mcp.json` (bare `ghostty-mcp`) serves repo-clone developers, not
  DMG users.
  Wiring: `dist/macos/release-local.sh` (step 3a build+bundle + the `sign` line) and
  `.github/workflows/fork-release.yml` (build+bundle+sign steps),
  `macos/Sources/Features/ForkSetup/ForkSetup.swift` (`ShimPlan`/`planShimInstall`/
  `installShimIfNeeded`); tests in `macos/Tests/ForkSetup/ForkSetupTests.swift` (`shim*`).

- **Auto-registered MCP server with Claude Code (fork-only, ForkSetup job 7).** Installing the
  shim onto PATH is NOT enough for the MCP to appear in a colleague's Claude Code — Claude Code
  must be TOLD about it. So on first launch (deferred, AFTER the shim install) the fork runs
  `claude mcp add ghostty --scope user -- ~/.local/bin/ghostty-mcp` for them, making the Ghostty
  MCP visible in EVERY `claude` session (user scope = any cwd). The shim reads the token from
  `local` at runtime, so the registration carries NO secret. Pure decision
  `planMCPRegister(alreadyRecorded:claudeFound:shimExists:alreadyRegistered:)` →
  `.skipAlreadyRecorded` / `.skipNoClaude` / `.skipNoShim` / `.skipAlreadyRegistered` /
  `.register`: it records success (persisted `forkSetup.mcpRegisteredWithClaude`) so it stops
  probing, but leaves a transient miss (`claude` or the shim not present yet, or `claude mcp add`
  non-zero) UNrecorded so a later launch retries; it NEVER clobbers a pre-existing `ghostty`
  server (a hand-managed entry is left strictly alone). **`claude` resolution is ROBUST to the
  GUI's pristine launchd PATH** — `resolveClaude` checks well-known absolute locations FIRST
  (`~/.local/bin/claude` = the official native installer, `~/.claude/local/claude`, Homebrew,
  nix — pure `claudeCandidatePaths`/`firstExecutablePath`), then falls back to a LOGIN shell and
  an INTERACTIVE login shell `command -v` (`-lc` then `-ilc`, the latter sourcing `.zshrc` where
  most installs put the PATH). **This was a real colleague bug**: a plain `-l` `command -v claude`
  silently MISSES an install whose PATH entry lives in `.zshrc` (the common `~/.local/bin/claude`
  case), so job 7 took `.skipNoClaude` and nothing registered — fixed by the absolute-candidate
  check. `registerMCPWithClaudeIfNeeded` then runs `claude mcp add` via an INTERACTIVE login shell
  using the RESOLVED ABSOLUTE path (so claude is found deterministically AND gets node/env to run),
  with a bounded timeout + stdin=/dev/null so a hung/interactive `.zshrc` can't wedge the deferred
  thread (`runLoginShell`/`loginShellStatus`/`shellQuote`). If `claude` is never installed, this is
  a silent no-op (the colleague can still register by hand; ONBOARDING.md documents the command).
  Wiring/Tests as in the ForkSetup bullet above (`planMCPRegister`, `claudeCandidatePaths`,
  `firstExecutablePath`; `mcpRegister*`, `claudeCandidates*`/`firstExecutable*`).


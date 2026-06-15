# MCP server — verification report

Verification engineer pass over the fork-only MCP-server implementation in
`/Users/ramon/git/ghostty-mcp-server` (branch `mcp-server`). Scope: feasible,
watchdog-safe checks only (Zig config test + static Swift review + shim build).
NO multi-minute Swift app/test builds were run — those are listed below for the
human.

## What was run

### 1. Zig config test (PASS)
```
cd /Users/ramon/git/ghostty-mcp-server
zig build test -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=mcp
```
Result: **PASS** — `Build Summary: 59/59 steps succeeded; 68/68 tests passed`
(exit 0). The new `test "mcp: parse and default"` in `src/config/Config.zig`
compiles and passes: it asserts both keys default to `null` and round-trip
`--mcp-listen=127.0.0.1:8765` / `--mcp-token=supersecrettoken1234`. The
`web-monitor` filter was also run for parity (same 68/68 pass).

### 2. stdio shim build (PASS)
```
cd /Users/ramon/git/ghostty-mcp-server/macos/mcp-shim && swift build
```
Result: **PASS** — `Build complete! (2.59s)`. Foundation-only executable
`ghostty-mcp`; it is a separate SPM package and is correctly NOT wired into
`Ghostty.xcodeproj`.

### 3. Forbidden-file / repo-hygiene check (CLEAN)
```
git -C /Users/ramon/git/ghostty-mcp-server status --porcelain
git -C /Users/ramon/git/ghostty-mcp-server check-ignore macos/mcp-shim/.build/.lock
```
- NO changes under `macos/Sources/Features/WebMonitor/*` (web monitor untouched).
- NO changes under `src/host/*` or `src/termio/Client.zig`.
- The ONLY Zig change is `src/config/Config.zig` (two additive keys + one parse
  test), exactly as the plan permits.
- **SwiftPM build artifacts (`macos/mcp-shim/.build/`) are NOT tracked.** A prior
  pass had accidentally STAGED ~1287 `.build` artifact files (ModuleCache `.pcm`
  blobs, `.lock`, etc.). They have been `git rm -r --cached`'d and a scoped
  `macos/mcp-shim/.gitignore` (`/.build/`) now ignores them — `git check-ignore
  macos/mcp-shim/.build/.lock` exits 0 (ignored) and `.build/` no longer appears
  in `git status` except as the single ignored directory. Verify before commit
  that `git status --porcelain | grep mcp-shim/.build` is empty.

Changed/added files: `src/config/Config.zig` (M), `macos/Ghostty.xcodeproj/project.pbxproj`
(M), `macos/Sources/App/macOS/AppDelegate.swift` (M),
`macos/Sources/Ghostty/Ghostty.Config.swift` (M), the new
`macos/Sources/Features/MCP/{MCPServer,MCPRPC,MCPTools,MCPInput,MCPLayout,MCPEventBus}.swift`,
`macos/Tests/MCP/MCPServerTests.swift`, `macos/mcp-shim/*`, plus design docs.

## Static Swift verification (read-through; no compiler run)

Checked every MCP Swift file + the test file against `include/ghostty.h` and the
existing Swift symbols. Findings: **no compile errors established by reading.**

- **C API signatures (all confirmed in `include/ghostty.h`):**
  `ghostty_surface_key(ghostty_surface_t, ghostty_input_key_s)`,
  `ghostty_surface_mouse_scroll(_, double, double, ghostty_input_scroll_mods_t)`
  (`ghostty_input_scroll_mods_t = int`; `0` passed — OK),
  `ghostty_surface_size(_) -> ghostty_surface_size_s` (`columns`/`rows` are
  `uint16_t`; `Int(...)` cast — OK), `ghostty_surface_request_close`,
  `ghostty_surface_inherited_config(_, GHOSTTY_SURFACE_CONTEXT_TAB)`,
  `ghostty_surface_binding_action(_, const char*, uintptr_t)`,
  `ghostty_config_get(_, void*, const char*, uintptr_t)`.
- **`ghostty_input_key_s` field set matches MCPInput exactly:** `action`, `mods`,
  `consumed_mods`, `keycode`, `text`, `unshifted_codepoint`, `composing`. Enums
  `GHOSTTY_ACTION_PRESS/RELEASE`, `GHOSTTY_MODS_NONE/CTRL`,
  `GHOSTTY_SURFACE_CONTEXT_TAB` all present.
- **Swift symbols confirmed present:** `SurfaceView` `id: UUID`, `title`, `pwd`,
  `focused`, `bell`, `processExited`, `needsConfirmQuit`, `surface`,
  `cachedScreenContents`, `cachedVisibleContents`; `TerminalController.all`,
  `.focusSurface(_)`, `.surfaceTree`, static `newTab(_:from:withBaseConfig:)`
  (signature matches MCPLayout.newTab call); `SplitTree` `Node` (`.leaf(view:)` /
  `.split(Split)`), `Split{direction,ratio,left,right}`,
  `Direction{.horizontal,.vertical}`, `root`, `zoomed`, `zoomedLeaves()`,
  `Sequence` conformance (leaf iteration), memberwise `.init(root:zoomed:)`;
  `Ghostty.SurfaceConfiguration{workingDirectory,initialInput, init(from:)}`;
  `Ghostty.Notification.ghosttyNewTab`, `Ghostty.Notification.NewSurfaceConfigKey`
  (the cross-module qualified form the app target already uses),
  `Notification.Name.ghosttyBellDidRing` (object is the `SurfaceView`, matching
  the bus's `note.object as? Ghostty.SurfaceView`).
- **`revealIfZoomedAway`** is a verbatim copy of the web monitor's proven helper
  (`.init(root: tree.root, zoomed: nil)`), confirmed identical.
- **Test target resolution:** every symbol the test references is `internal`/
  `static` and reachable via `@testable import Ghostty` —
  `MCPServer.{parseListen, decideRoute, RouteDecision, RequestParser,
  maxRequestBytes, parseRPC, resultEnvelope, errorEnvelope, initializeResult,
  hostHeaderAllowed, tokensMatch, failedAuthThreshold, HTTPResponse.empty}`,
  `MCPInput.{keySpecs, KeySpec, scrollDeltaClamped}`,
  `MCPTools.{toolsListResult, dispatch}`, `MCPLayout.{SurfaceRow, surfacesJSONData}`.
  `failedAuthThreshold` is `static let` (not private) — accessible from tests. The
  test file lives under `macos/Tests/MCP/` and is picked up by the
  filesystem-synchronized `GhosttyTests` group (same mechanism as the WebMonitor
  tests), so no manual pbxproj test wiring is required.
- **pbxproj:** the 6 MCP source files are added to the same iOS
  `membershipExceptions` block (lines ~166-171) that already excludes the
  WebMonitor macOS-only files — correct copy of the established pattern.
- **Threading discipline (read-through):** listener + connections on a dedicated
  serial queue; effect handlers hop via `DispatchQueue.main.sync` and return only
  value types; `stop()` tears down with `queue.async`; `wait_for_event` parks the
  connection (idle watchdog cancelled) and is resolved single-shot off the serial
  queue; the event bus appends to a lock-guarded ring on main and fans out on the
  serial queue. Matches the plan's copied discipline.

No compile fixes were required — the Zig test passed on the first run and no
Swift compile error was identified by static review.

## Test-coverage additions made in this pass (closing the prior-review majors)

The prior review (A-, 95) flagged two test-breadth majors + three minors. All are
now closed by additions to `macos/Tests/MCP/MCPServerTests.swift` (+ one tiny pure
refactor in `MCPLayout.swift`). The Zig gate re-ran clean after the edits
(**68/68 tests passed, exit 0**); the Swift additions are static-only (human runs
the Swift suite).

- **MAJOR 1 — `nodeJSON` (get_layout split serializer) had no coverage.** The
  `.leaf` branch and full recursion need a real `SurfaceView` (a live ghostty
  surface), which is not constructible in a unit test. The only non-trivial branch
  logic — the split `direction -> string` mapping — was extracted into a pure,
  ViewType-independent helper `MCPLayout.directionString(_:)` (the `SplitTree.Direction`
  enum is independent of the view type, so it IS constructible). New test
  `nodeJSONDirectionString` asserts `.horizontal -> "horizontal"` / `.vertical ->
  "vertical"` — the mapping every `.split` node in the layout tree emits. The leaf
  shaping + recursion remain a documented runtime/manual concern (noted in residual
  risk).
- **MAJOR 2 — per-tool pre-hop guard coverage was incomplete.** Added one assertion
  per missing AppKit-free guard (all fire BEFORE any `DispatchQueue.main.sync`,
  proved reachable by the existing send_key missing-id test):
  `read_surface` missing/garbage id, `send_text` missing id + missing text,
  `scroll` missing id + missing dy + **zero-dy -> .toolError**, `focus_surface`
  missing id, `close_surface` missing id, `perform_action` missing id + **empty
  action -> .invalidParams**, `watch_for_pattern` missing id + **empty regex ->
  .invalidParams**.
- **MINORS:** `toolTextContent`/`toolContent` result-shape tests
  (`toolTextContentShape`, `toolContentJSONEncodesPayload`); `tokenAcceptable`
  length-floor test (`tokenAcceptableLengthFloor`, exercises `minTokenLength`);
  `uuidArg` valid/garbage/missing/non-string test (`uuidArgValidAndInvalid`).

New symbol referenced by the tests and confirmed reachable via `@testable import
Ghostty`: `MCPLayout.directionString` (static internal), `MCPServer.tokenAcceptable`
+ `minTokenLength` (static), `MCPServer.toolContent`/`toolTextContent` (static, on
the MCPRPC extension), `MCPTools.uuidArg` (static). `MCPLayout.directionString`
takes `SplitTree<Ghostty.SurfaceView>.Direction`, constructible standalone.

## Fixes made in the FIXER pass (closing the round-0 critic blocker + majors)

The final critic (B+, 88) found 1 blocker + 3 majors. All are now addressed:

- **BLOCKER — staged `.build` artifacts.** Fixed in §3 above (`git rm --cached` +
  scoped `.gitignore`). The single most visible repo-hygiene problem; the prior
  verify pass missed it. Now explicitly verified and documented.
- **MAJOR 1 — unbounded `wait_for_event`/`watch_for_pattern` timeoutMs.** A parked
  connection is exempt from BOTH watchdogs, so a huge `timeoutMs` (e.g. 24h) parks
  it indefinitely; 32 such calls hit the conn cap = starvation. Negative/zero was
  also degenerate. FIXED: a pure `MCPEventBus.clampTimeoutMs(_:default:)` clamps to
  `[timeoutFloorMs=1000, timeoutCeilingMs=120000]` (NaN/non-finite collapses to the
  30s default), applied in `MCPTools.dispatch` for BOTH tools; schemas now declare
  `minimum:1000, maximum:120000` and the prose says "clamped". New tests:
  `clampTimeoutMsPure`, `clampCeilingBelowShimTimeout`,
  `dispatchWaitForEventClampsHugeTimeout`, `dispatchWaitForEventClampsZeroTimeout`,
  `dispatchWatchPatternClampsHugeTimeout`.
- **MAJOR 2 — shim↔server timeout mismatch.** The shim never set
  `req.timeoutInterval`, so URLSession's 60s default fired a transport error (and a
  spurious `{error:-32000 'unreachable'}`) for any wait > ~60s while the server kept
  the waiter parked. FIXED on BOTH sides: the shim now sets
  `req.timeoutInterval = 180` and the server ceiling (120s) is enforced strictly
  below it (the `clampCeilingBelowShimTimeout` test asserts `ceiling < 180000`).
- **MAJOR 3 — prompt/atPrompt overpromised.** `prompt`/`atPrompt` is built on
  `needsConfirmQuit`, which is gated by `confirm-close-surface`: `false` ⇒ the
  `prompt` event never fires and `atPrompt` is always true; `always` ⇒ inverted.
  Wiring a real OSC-133 `at_prompt` bit needs host/GUI plumbing OUT OF SCOPE here
  (the plan explicitly accepts the coarse `needs_confirm_quit` fallback "and note
  it"). FIXED by honest disclosure: the `list_surfaces` and `wait_for_event` tool
  descriptions now spell out the `confirm-close-surface` dependency and the
  three-value behavior, and `MCPLayout.SurfaceRow.atPrompt` carries the same note
  for maintainers.

## Fixes made in the FIXER pass round 1 (closing the critic's 5 minors)

The round-1 critic (A, 97) found 0 blockers / 0 majors / 5 minors; all 5 are now
addressed (the gate wants A+ / ≥98 / 0 blockers). Swift edits are static-only
(human runs the Swift suite); the Zig gate is unchanged.

- **MINOR 1 — `watch_for_pattern` ReDoS / main-thread stall.** The token-supplied
  regex was run every 300ms over the surface text. FIXED: the scanned text is now
  (a) viewport-only (already) and (b) **capped to `patternScanCap = 16_384` chars**
  (tail-biased) before the match. Crucially the `regex.firstMatch` runs on the
  **serial queue**, not main — the `DispatchQueue.main.sync` hop only reads the
  cached text — so a catastrophic-backtracking pattern can at worst stall the MCP
  serial queue (itself bounded by the per-waiter hard deadline ≤120s on that same
  queue), NEVER the AppKit main thread. (`MCPEventBus.registerPattern`,
  `MCPEventBus.patternScanCap`.)
- **MINOR 2 — `read_surface` silent mode coercion.** Any `mode` != "scrollback"
  (e.g. a typo'd "full") was silently treated as viewport. FIXED: dispatch now
  rejects an unrecognized mode with `.invalidParams` BEFORE the main hop; only
  nil/"viewport"/"scrollback" are accepted. New test
  `dispatchReadSurfaceUnknownModeInvalidParams` (rejects "full"/"scrollbck",
  confirms the two valid modes are NOT rejected). (`MCPTools.dispatch`.)
- **MINOR 3 — `new_tab` source path reported success unconditionally.** It posted
  `ghosttyNewTab` and returned `{ok:true}`, but the sole observer bails if the
  source's window is nil or its windowController is not a `TerminalController` —
  a silent no-op reporting success. FIXED: the source path now mirrors those
  guards (`view.window` non-nil + `windowController is TerminalController`) and
  invokes `TerminalController.newTab(_:from:withBaseConfig:)` **directly**,
  returning `created != nil` (real success). A source that fails the guards falls
  through to the frontmost-window/new-window path (also `created != nil`-checked).
  No more notification fire-and-forget. (`MCPLayout.newTab`.)
- **MINOR 4 — `wait_for_event` id filter was case-sensitive on uppercase UUIDs.**
  A lowercase client UUID silently never matched and timed out. FIXED: the filter
  now delegates to a pure, unit-tested `MCPEventBus.eventMatches(...)` that
  compares ids case-insensitively (uppercased both sides). New test
  `eventMatchesPure` covers empty filters, type filtering, and the
  lowercase-id-matches-uppercase-event case. (`MCPEventBus.eventMatches`,
  `MCPEventBus.register`.)
- **MINOR 5 — `atPrompt:true` on a closed/exited surface.** `needsConfirmQuit`
  returns `false` when `surface==nil` (exited), so `atPrompt = !needsConfirmQuit`
  was `true` alongside `exited:true`. FIXED: `atPrompt` is now `!exited &&
  !needsConfirmQuit`, so an exited surface is never also reported at a prompt.
  Schema/`SurfaceRow` notes updated. (`MCPLayout.surfaceRows`,
  `MCPLayout.SurfaceRow.atPrompt` doc.) Not separately unit-tested (requires a
  live `SurfaceView`); the logic is a one-line guard.

## Residual risk (NOT verifiable without the full Swift build)

These are plausible-but-unconfirmed; the human's Swift build/test will settle them:

1. **Full Swift type-check / actor isolation.** MCP handlers call AppKit and
   `@Published`/main-actor-ish state from inside `DispatchQueue.main.sync`
   nonisolated closures. `MCPLayout.performAction` deliberately calls the C
   `ghostty_surface_binding_action` directly (noting `Surface.perform(action:)`
   is `@MainActor`). This compiled fine conceptually but Swift-6 concurrency
   checking (if enabled for the target) could still flag a capture; only the real
   build confirms.
2. **`TerminalController.newTab(_:from:withBaseConfig:)` return type** is used as
   `created != nil` — confirmed it returns `TerminalController?`. Behavior of the
   no-source path (frontmost-window anchor vs. new window) is logic, not a compile
   risk, and is untested here.
3. **`MCPServerTests` execution.** The test bodies (including the coverage
   additions made in this pass) were read and the asserted values match the
   implementation, but they were NOT executed (Swift test build is multi-minute).
   Expect them to pass; run them to confirm. Note the leaf-branch + full recursion
   of `nodeJSON` (get_layout) are NOT unit-covered (a live `SurfaceView` is not
   constructible in a unit test) — only the extracted `directionString` mapping is;
   exercise get_layout against a real split during the manual smoke.
4. **Live end-to-end** (real socket, `tools/call` effects, `wait_for_event`
   parking, shim↔server round-trip) is entirely unverified — manual smoke only.

## Commands the human must run for full verification

```sh
# 1. Rebuild the Zig lib (required before the app build after any Zig change)
cd /Users/ramon/git/ghostty-mcp-server
zig build -Demit-macos-app=false -Doptimize=ReleaseFast

# 2. Swift unit tests (the MCP suite + the rest)
macos/build.nu --action test
#   or just the MCP suite:
#   xcodebuild -only-testing:GhosttyTests/MCPServerTests \
#     -scheme Ghostty -destination 'platform=macOS' test

# 3. Build the dev app (ReleaseLocal — side-by-side, safe to relaunch)
macos/build.nu --configuration ReleaseLocal --action build
#   -> macos/build/ReleaseLocal/Ghostty.app  ("Ghostty (ramon-local)")

# 4. Build the stdio shim (already verified PASS here, re-run if desired)
cd /Users/ramon/git/ghostty-mcp-server/macos/mcp-shim && swift build

# 5. Manual smoke (in ~/.config/ghostty-ramon/config):
#     mcp-listen = 127.0.0.1:8765
#     mcp-token  = <a long random token>
#   then, with the dev app running:
curl -s -X POST http://127.0.0.1:8765/mcp \
  -H 'Content-Type: application/json' \
  -H 'X-Ghostty-Token: <token>' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
#   and register the shim:
GHOSTTY_MCP_URL=http://127.0.0.1:8765/mcp GHOSTTY_MCP_TOKEN=<token> \
  claude mcp add ghostty -- /path/to/.build/debug/ghostty-mcp
```

Do NOT quit/relaunch the installed Release fork
(`com.mitchellh.ghostty-ramon`) — it hosts this session. Use ReleaseLocal/Debug
for runtime testing.

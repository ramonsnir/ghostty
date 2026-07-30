# Fork standalone robustness / upstream-bug fixes

Self-contained fixes that are not tied to one fork feature. The PTY-host
input-freeze fix (`SegmentedPool` write-pool grow corruption) lives in
`PTYHOST.md` → "Write-request pool grow corruption".

## `CachedValue` thread-safety crash fix

- **`CachedValue` thread-safety crash FIX (upstream bug, GUI-only, always on).** THE cause of the
  recurring GUI **SIGABRT** (`~/.local/state/ghostty/crash/*.ghosttycrash`, e.g. build fork-16999 on
  2026-07-10; a sibling `EXC_BAD_ACCESS` family is the same race landing as a use-after-free). Root-
  caused via `minidump-stackwalk` (carve the raw `MDMP` out of the sentry envelope first): the crashing
  thread was `__pthread_kill`←`abort`←`libswiftCore`(fatal)←`closure #1 in CachedValue.get()` on a
  **background Swift-Concurrency worker**. `CachedValue<T>` (`SurfaceView_AppKit.swift`, UPSTREAM code
  from the "GetTerminalDetails" App Intent + accessibility support — still unfixed on `origin/main` as
  of the Jul-10 check) caches `cachedScreenContents`/`cachedVisibleContents` (`<String>`) and was NOT
  thread-safe: `get()` (called from AppKit's **accessibility thread**, OFF the main thread) mutated
  `value`/`expiryTask` while the expiry `Task {}` cleared them from a background executor, with NO
  lock → the `String` storage refcount corrupted → Swift-runtime abort. The fork's MCP/web-monitor/
  bell-classify screen reads + a bell storm (a workflow ringing many agents at once) crank the
  concurrency that makes it fire. Fix: an `NSLock` guarding every access to `value`/`expiryTask`;
  `fetch()` runs OUTSIDE the lock (may be an expensive full-screen read) with a double-checked
  re-lock so there's still exactly one expiry task per fill; the expiry closure clears via a locked
  `clear()`. Pure Swift — NO Zig/host/protocol change (GUI relaunch only, no session loss). Candidate
  to upstream (the defect is upstream). Wiring: `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`
  (`CachedValue` lock + `clear()`). Tests: `macos/Tests/Ghostty/CachedValueTests.swift`
  (`cachesWithinDuration`/`refetchesAfterExpiry` + the `concurrentGetAndExpiryDoesNotRace` 20k-iteration
  concurrent stress reproducer). **Test-robustness note:** `refetchesAfterExpiry` originally slept a
  FIXED 80ms for a 20ms expiry, which flaked in FULL-suite runs (it passed in isolation) — Swift
  Testing parallelizes cases, so the 20k-iteration stress test in the SAME suite saturates every
  core and the background expiry clear lands late. It now POLLS `get()` up to a 5s ceiling instead,
  so it is fast when idle and tolerant when loaded.


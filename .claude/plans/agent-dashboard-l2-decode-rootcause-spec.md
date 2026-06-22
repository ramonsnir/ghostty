# L2 grid_frame decode failure — root cause + fix spec

Branch: `ramon-fork`. Layer 1 committed; Layer 2 + fix pass in the working tree
(uncommitted). This spec covers the rare, load-dependent `grid_frame` decode
failure (`error.InvalidColorTag` / `error.InvalidCodepoint` /
`error.InvalidEnumTag`) seen in the host Layer-2 recovery test under heavy CPU
load. STATUS: ROOT-CAUSED, FIXED, and GUARDED.

> **Record-correction note (this pass).** An earlier revision of THIS spec
> asserted the root cause was purely a TEST-HARNESS bug (one `ClientReader`
> reused across two sockets) and concluded "no production change is warranted or
> correct." That conclusion was WRONG and has been corrected below. The operative
> root cause is a real **PRODUCER bug** — an undefined-memory read in
> `RenderState.Snapshot.fromRenderState` — and the working tree ships the
> production fix for it (`src/host/RenderState.zig`). The harness reader-per-socket
> change is also applied, but it is *latent-unsafety hardening*, NOT the cause of
> the observed failure. See "Why the earlier harness story was incomplete" below.

## TL;DR

**Root cause: a real producer-side UNDEFINED-MEMORY READ.** In
`src/host/RenderState.zig` `Snapshot.fromRenderState`, a `bg_color_rgb` /
`bg_color_palette` blank cell (`Screen.blankCell` → `Style.bgCell`) has
`style_id == 0` and does NOT mark its row `styled`, so a row of only bg-color
cells is NON-managed (`Row.managedMemory() == styled or hyperlink or grapheme`,
`src/terminal/page.zig`). The renderer's `RenderState.update` only populates
`cells_style[x]` inside `if (row.managedMemory())` (`src/terminal/render.zig:506`),
and `MultiArrayList.resize` does NOT zero new fields, so for a bg-color cell on a
non-managed row the `.style` slot is left **UNDEFINED** (whatever stale bytes the
reused per-row buffer held). The renderer itself never reads that slot for such a
cell — it derives the bg color from `raw.content` at draw time
(`render.zig:536-549`). But the host mirror's `fromRenderState` USED TO read it via
`StylePod.fromStyle(styles[x])` whenever `content_tag` was `bg_color_*`, projecting
a GARBAGE `Style.Color` union (out-of-range tag) → `serialize` emitted a garbage
`ColorTag` byte → `Snapshot.deserialize` (and the real `.client`/`.mirror` decode)
correctly REJECTED it as `error.InvalidColorTag`.

**Why load-dependent (the heisenbug):** idle, the reused arena/per-row buffer
backing the undefined `.style` slot was usually still zeroed (a zero tag happens to
be the valid `.none`/`.rgb` discriminant, so serialize emitted a benign byte and
decode passed). Under heavy CPU load the buffer had been churned and held non-zero
garbage, so the emitted `ColorTag` byte was out of range → decode failed.
~2/52 under load, 0% idle.

**The fix (producer-side, the correct side):** `fromRenderState` now DERIVES the
bg color for `bg_color_rgb` / `bg_color_palette` cells directly from `raw.content`
(which `render.zig` always copies, line 501-505, so it is ALWAYS defined), exactly
mirroring the renderer's own draw-time mapping (`render.zig:536-549`). The producer
therefore never emits a rejectable byte, regardless of arena state. The decode
validators are left STRICT (unchanged) — they remain the fail-closed guard against
genuinely-untrusted/desynced bytes. This matches the task's preferred remedy: fix
the PRODUCER so it never emits content the validator must reject; do not loosen the
validator.

This is a genuine bug for REAL `.mirror` use: the production mirror client
(`src/termio/Client.zig`, `.mirror` role) decodes the same host-produced
`grid_frame`s and would hit the same `error.InvalidColorTag` under load, dropping
the mirror connection. It is not a test-only artifact.

## The producer fix — APPLIED (this is the operative change)

`src/host/RenderState.zig` `Snapshot.fromRenderState`, the per-cell style
projection (see the in-source comment at ~lines 451-501):

```zig
const style_pod: StylePod = blk: {
    switch (raw.content_tag) {
        .bg_color_rgb => break :blk .{ .bg_color = .{
            .tag = .rgb,
            .rgb = .{ .r = raw.content.color_rgb.r, .g = raw.content.color_rgb.g, .b = raw.content.color_rgb.b },
        } },
        .bg_color_palette => break :blk .{ .bg_color = .{
            .tag = .palette,
            .palette = raw.content.color_palette,
        } },
        else => {},
    }
    if (raw.style_id > 0) break :blk StylePod.fromStyle(styles[x]); // styled => managed => defined
    break :blk .{};
};
```

THREE cases, in priority order:
1. `bg_color_rgb` / `bg_color_palette`: derive the bg `StylePod` from
   `raw.content`, NEVER from `styles[x]`.
2. `style_id > 0`: always lives on a `styled` (== managed) row, so `styles[x]` IS
   populated by `update`. Read it (no UB).
3. everything else (default cells): all-default POD.

The switch arms intentionally mirror `render.zig:536-549` (the canonical draw-time
color mapping). If a future `content_tag` variant carrying a color is added, the
`else => {}` fallthrough would route it to the `style_id` path; the existing
in-source comment ties the arms to `render.zig` so that watch-item is visible.

### Consistency across the three sibling sites

The same undefined-`styles[x]`-on-non-managed-row read existed in the difftest
validator and corpus; all three were updated together so the cross-path diff stays
honest (mirror==exec fidelity preserved):

- **Producer:** `src/host/RenderState.zig` `Snapshot.fromRenderState` (above).
- **Validator:** `src/host/RenderState.zig` `eqlRenderState` — derives the expected
  bg `StylePod` from `raw.content` for bg_color cells the same way, so it does not
  read the undefined slot when comparing.
- **Corpus:** `src/termio/client_difftest.zig` — same derivation, so the
  mirror==exec corpus no longer reads the undefined slot either.

I verified the SAME UB class does NOT exist elsewhere in `fromRenderState`:
`style_id > 0` implies the row is `styled` (a may-be-false-positive flag, never a
false-negative) so that `styles[x]` read is always defined; grapheme reads are
gated on `.codepoint_grapheme` (⇒ managed ⇒ populated); `cursor_style` reads
defined cursor state.

## Why the decode is the right canary, and why we did NOT loosen it

A structurally-complete, host-encoded `grid_frame` whose snapshot CONTENT fails to
deserialize is, per this task's established facts, a PRODUCER asymmetry — the host
emitted a byte the validator must reject. The correct fix is on the producer (stop
emitting it), not the validator. The decode validators
(`InvalidColorTag`/`InvalidCodepoint`/`InvalidDirty`/`InvalidCursorStyle`/
`InvalidRowIndex`/`GridTooLarge`, plus the highlight-tag drop and codepoint bound)
are fail-closed crash-safety guards against genuinely-untrusted/desynced bytes;
loosening them would open a UB hole. They did their job here — they refused to
silently coerce a garbage color union. Keep them strict.

The snapshot capture/lock structure was also examined and is NOT the cause: the
grid snapshot is captured FULLY OWNED under `render_mutex` at the render-tick lock
(`Session.captureSnapshotLocked` → `fromRenderState`), pointer-free and immutable
after capture; `onRender` re-locks only to read the small `ModeFrame`, never the
grid bytes, and encodes synchronously on the owning thread before the next tick can
free `prev_snapshot`. So "no torn capture" holds; the failure was the in-capture
undefined read, fixed at its source.

## Deterministic regression test — APPLIED

`src/host/test.zig`:
`test "host bg_color cell on a NON-managed row projects bg from cell content, never the undefined style slot (grid_frame decode failure root cause)"`

This is the fails-pre-fix / passes-post-fix regression guard, fully deterministic
and self-contained (no Server, no child shell, no socket, no load):

1. Build a terminal with a full row of `bg_color_rgb` blank cells WITHOUT marking
   the row styled (set a direct bg color, then `insertLines` fills the inserted
   line with `bgCell()` blanks, `style_id == 0`) — the exact NON-managed bg-color
   row.
2. Run `RenderStateCore.update`, then FIND a row whose cells are **ENTIRELY**
   `bg_color_rgb 0xABCDEF` (the WHOLE row, not just cell 0 — see "test robustness"
   below) and assert it is `!managedMemory()` (the precondition that makes
   `.style` undefined).
3. POISON every cell's `.style` slot with a wrong-but-valid `Style`
   (`bg_color.palette = 99`) — deterministically simulating the stale arena bytes
   that bit under load.
4. `fromRenderState` → assert every cell projects `ColorTag.rgb` 0xABCDEF (from
   `raw.content`), NEVER the poison palette 99.
5. `serialize` → `deserialize` → assert `eql` (the load symptom was a decode error
   exactly here) and that the restored row still carries the content-derived color.

PROVEN fails-pre-fix: temporarily reverting `fromRenderState` to the old
`fromStyle(styles[x])` form for bg_color cells makes this test fail
DETERMINISTICALLY (idle and under load) with `expected .rgb, found .palette`
at the assertion loop; restoring the fix makes it pass. The poison makes the
failure deterministic — it does not rely on the load-dependent garbage at all.

### Test robustness (resolved review finding)

An earlier version of this test selected a row by checking only `raws[0]` was
`bg_color_rgb` but then asserted EVERY cell projects from `raw.content`. If a
selected row were only PARTIALLY bg_color, a non-bg cell would (correctly) read the
poisoned `.style` slot and the assertion would fail with a CONFUSING
`expected .rgb, found .palette` — indistinguishable from a real regression. Under
the full host suite at ~2× hw.ncpu load this surfaced as a ~1/15 flake at the
assertion loop. Root cause of that flake was twofold and BOTH are addressed:
- **Test-internal:** the precondition was too narrow. The test now requires the
  WHOLE row to be uniform `bg_color_rgb 0xABCDEF` before selecting it, so the
  assertion loop is exactly the precondition (no partial-row ambiguity). In
  isolation the produced row is verified uniform (all 6 cells `bg_color_rgb`), so
  there is no internal non-determinism.
- **External (process-global):** the host suite is NOT cleanly green under heavy
  load due to a PRE-EXISTING, UNRELATED `terminal.search.Thread` libxev-kqueue
  teardown crash (`.BADF => unreachable` / "invalid state in submission queue").
  That is a hard PROCESS-LEVEL panic; when it fires it can collaterally corrupt any
  in-flight test's heap. No in-process unit test can be defended against a sibling
  test segfaulting the process. This crash is independent of the pty-host diff
  (see "Load story" below) and is out of scope for this decode root-cause. The
  bg_color test's own logic is deterministic; the only way it can "fail" under load
  is collateral corruption from that unrelated crash.

The now-tautological anti-poison assertion (`palette != 99 or tag == .rgb`, always
true once `tag == .rgb` is independently asserted) was REMOVED.

## Harness hardening (also applied — NOT the root cause)

The recovery test
(`"host Layer2: bounded-drop is DETERMINISTIC under a paused drain … recovers on resume"`)
now reads the render-sub socket `rndc` through its OWN dedicated `ClientReader`
(`rndrdr`), matching every other multi-socket test in the file
(`rndrdr`/`rawrdr`/`rdr2`) and the file-wide invariant "one `ClientReader` per
socket." A single binding `recover_rdr: *ClientReader = &rndrdr;` is shared by a
precondition guard (assert the reader is fresh: `consumed == 0`,
`unread == 0`) and the recovery read loop, so a future revert to reusing `rdr`
(which by the recovery point has consumed the high-rate primary stream) trips the
guard. There is also a standalone mechanism test
(`"host L2: a single FrameReader reused across two sockets corrupts grid_frame decode …"`).

This is **latent-unsafety hardening**, not the operative root cause:
- The recovery loop reads a STRUCTURALLY-COMPLETE, host-PRODUCED `grid_frame`; the
  frame reader does proper length-prefixed reassembly. A producer that emits a
  garbage `ColorTag` byte fails decode regardless of how the test reads it.
- The standalone mechanism test self-constructs a contamination scenario and
  asserts the bug exists; it has no fails-pre-fix value w.r.t. the producer fix.
  Its decode assertion is deliberately category-tolerant (it accepts the captured
  `error.InvalidColorTag` but does not HARD-pin only that error, because the exact
  fail-closed error a byte-cut lands on depends on the wire layout and could shift
  on a future additive wire change without any real regression).

Keeping the harness change is correct (one-reader-per-socket is the right
invariant), but its value is hardening against a DIFFERENT, never-observed failure
mode, not the load-dependent decode failure this task fixed.

## Instrumentation removal

All temporary diagnostics removed; no `TEMP-DIAGNOSTIC`/`RDR-DIAG`/`L2-DIAG`/
`roundTripCheckGridFrame`/`dumpBadGridFrame`/`l2-decode-fail` residue in `src/`.
The producer paths (`fromRenderState`, `renderOutPush`, `onRender`) carry no debug
round-trip check.

## Invariants preserved

- `.exec` byte-for-byte unchanged (`fromRenderState`/`Snapshot` are host/mirror-only;
  no `.exec` file edited).
- mirror==exec cell fidelity preserved — the producer, the `eqlRenderState`
  validator, and the `client_difftest.zig` corpus were updated CONSISTENTLY; the
  difftest corpus is green.
- crash-safety / untrusted-frame discipline intact — decode validators unchanged
  and still fail-closed; the producer was fixed to stop emitting rejectable content,
  not the validator loosened; no new UB.
- additive protocol discipline unaffected (no wire change; `src/host/protocol.zig`
  change is a comment only).
- the already-fixed bounded-drop determinism + M1 + M2 + session-gone guard from the
  fix pass stay correct and green.

## Load story (honest qualification)

Under ~2× hw.ncpu `yes` stressors, a `zig build test -Dtest-filter=host` run is
intermittently RED — but the failures are PRE-EXISTING and UNRELATED to the
pty-host decode diff:
- `terminal.search.Thread` libxev-kqueue teardown panic (`.BADF => unreachable`,
  `kqueue.zig:1839`) — a genuine process-level crash under load.
- `apprt.ipc` / `input.KeymapDarwin` runs trip the harness's "logged `err` →
  failure" gate via `[libxev_kqueue] (err): invalid state in submission queue`
  during exec-loop teardown — the run still reports 210/210 tests PASSED.

In every observed failure the host/decode/bg_color tests THEMSELVES pass
(210/210, or 209/210 where the 1 failure is the unrelated `terminal.search.Thread`
panic). The producer fix is sound and the regression test is deterministic in
isolation; "green under load" must be qualified by these pre-existing libxev
teardown races, which are tracked as the open item below.

## Open item
- The `terminal.search.Thread` libxev-kqueue teardown crash + the
  `[libxev_kqueue] (err): invalid state in submission queue` log-error under heavy
  load are SEPARATE, pre-existing teardown-timing artifacts (busy child / thread
  racing the xev loop deinit). They do not fail any pty-host assertion. Out of scope
  for this decode root-cause; recommend a follow-up to quiesce the
  child/search-thread deterministically (bounded poll for exit) rather than sleep
  before teardown.

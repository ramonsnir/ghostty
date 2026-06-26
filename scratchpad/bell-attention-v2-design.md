# Bell Attention v2 — fail-open, two-tier, fully configurable

Supersedes the slice-1–5 model. Captures the agreed redesign. EXPERIMENTAL branch
`bell-attention`; do NOT merge without Ramon's consent.

## Principles
1. **Fail-open.** A bell is suppressed ONLY by a LIVE sidecar that got a confident
   Haiku "ignore." Every other state — disabled, out-of-tokens, timeout, crash,
   unparseable, uncertain — leaves the bell LOUD.
2. **Fully configurable.** The per-effect routing is the USER's choice. Ramon's
   classification ships as the DEFAULT; colleagues can route any effect to either tier.
3. **The GUI never auto-sets attention.** `attentionNeeded` is set ONLY by the sidecar
   via `set_attention`. (No "loud then retract"; no GUI-side default-true.)

## Decision logic (in the sidecar — "the non-AI code that drives Haiku")
On a bell-edge (bellRang) classify, PROMOTE (`set_attention(true)`) unless we got a
clean, parsed, confident ignore:
- parsed `attention === false` → DO NOT promote   ← the ONLY suppression
- parsed `attention === true` → promote
- `attention` omitted / uncertain → promote (fail-open)
- Haiku call threw (error / timeout / out-of-tokens) → promote (fail-open)
- reply unparseable → promote (fail-open)
Prompt nudge: "return attention:false ONLY if you're confident the bell is incidental;
if unsure, omit it." (Model uncertainty rides the code's fail-open.)
`bell-filter` DISABLED ⇒ no attention tier; the raw bell is loud via `bell-features`
(today's behavior) — the "disabled" fail-open.

## Config: two tiers over one shared, expanded vocabulary
- `bell-features` / `bell-features-focused` — fires on EVERY bell, immediately.
- `attention-features` — ADDED when a bell is promoted. (NO `-focused` variant: a
  promotion means the user is away, and attention clears on focus, so a focused-promoted
  state is degenerate — the bell tier's focus split does not apply. Removed as a dead key
  per the slice-6 review.)
- **Additive:** promoted bell = bell-features ∪ attention-features; ignored bell =
  bell-features only. `bell-filter` off ⇒ bell-features only (today).

Vocabulary (each flag routable to either set):
`system` (beep), `audio` (sound file), `bounce` (dock bounce), `badge` (dock badge),
`title` (tab 🔔), `border` (surface border + zoom badge), `dashboard` (dashboard
unhide+sort+tile mark), `push` (web push), `monitor` (web-monitor indicator).
- Granularity (agreed): split today's `attention` → `bounce` + `badge`; keep
  `dashboard` as ONE flag. (Keep `attention` as a back-compat alias = bounce+badge.)
- Type-design decision (impl): extend the fork's BellFeatures option-set with the new
  flags so both sets share one vocabulary (vs. a separate fork effect-set type) —
  resolve in build; note the upstream-type caveat.

## Per-effect default routing (configurable)
| effect | flag | default tier |
|---|---|---|
| beep | system | bell |
| sound file | audio | bell |
| surface border (+ zoom badge) | border | attention |
| tab title 🔔 | title | attention |
| dock badge | badge | attention |
| dock bounce | bounce | attention |
| dashboard unhide/sort/mark | dashboard | attention |
| web push | push | attention |
| web-monitor indicator | monitor | attention |
| programmatic (list_surfaces.bell / .attentionNeeded) | — | TRUTHFUL (both, no flag) |

Defaults: `bell-filter` OFF; `bell-features` = today's (attention,title) PLUS the
always-on-pre-v2 effects dashboard,push,monitor (these were ungated/always-on before v2,
so keeping them on the bell tier by default = "defaults reproduce today"); thus a raw bell
by default fires bounce+badge (via the `attention` alias) + title + dashboard + push +
monitor. `attention-features` = title,border,bounce,badge,dashboard,push,monitor. Turning the
filter ON is when a user would dial `bell-features` down. NOTE the parse is ADDITIVE over the
BellFeatures TYPE defaults (`parsePackedStruct` starts from `BellFeatures{}` = attention+title
TRUE, the rest FALSE — NOT reset-to-listed), so the dial-down needs explicit negation:
`bell-features = system,audio,no-attention,no-title,no-dashboard,no-push,no-monitor` (a bare
`system,audio` leaves attention(bounce+badge)+title ON). Pinned by a Config.zig test.

## Separate bell vs attention state + clearing (P5 included)
Two INDEPENDENT per-surface states, each rendered per its tier's features:
- `bell` (raw) — clears on focus + web-monitor "clear" button (sound/transient +
  programmatic truthfulness).
- `attentionNeeded` (promoted) — clears on focus + sidecar `set_attention(false)`
  (recovery / explicit ignore).
- Web monitor surfaces BOTH distinctly (P5) with its own attention clear.

## Event-driven classify (responsiveness)
A real bell is sound-only until the sidecar promotes; on the 5s poll that's a visible
lag (and the push lags). Add a bell-REACTIVE path so promotion lands in ~1–2s (e.g.
`wait_for_event(bell)` long-poll, or a tight loop while bells are pending). The 5s
summarizer poll stays for summaries. NOTE: this is for responsiveness now, NOT to hold
the push (the push only fires post-decision, so spurious bells never push — the v1
"hold the push" tension is gone).

## Crashed-sidecar fallback (residual decision — DEFAULT: include)
`bell-filter` ON + sidecar process fully DOWN (not just Haiku failing): the two named
cases are covered (disabled → raw loud; out-of-tokens → sidecar promotes), but a CRASHED
sidecar promotes nothing → bell sound-only (fail-CLOSED). DEFAULT decision: the GUI
(which knows sidecar health via AgentManagerController) FALLS BACK to applying
`attention-features` to the raw bell while the sidecar is unhealthy — so a real bell is
never silently lost. (Supervisor still restarts the sidecar; this is belt-and-suspenders,
aligns with fail-open.) Flag for Ramon's review of this doc.

## Implementation deltas (file-by-file)
- **Zig:** expand BellFeatures vocabulary (bounce,badge,dashboard,push,monitor + the
  `attention` alias); add the `attention-features` key (NO `-focused` variant — see above);
  parse tests.
- **Swift:** expand the BellFeatures OptionSet; `Ghostty.Config.attentionFeatures(-Focused)`
  getters; route EACH consumer to read bell-features-tier on a raw bell vs
  attention-features-tier on `attentionNeeded` (AppDelegate sound/dock, SurfaceView
  border, BaseTerminalController title + dock-badge aggregate, AgentDashboard, WebPush,
  web monitor); SEPARATE bell/attention clearing; web-monitor attention (P5);
  crashed-sidecar GUI fallback.
- **Sidecar:** invert the bellRang decision to fail-open (catch/unparseable/uncertain →
  promote; only clean `false` suppresses); event-driven classify; prompt nudge.
- **Tests + blocking ≥98 multi-lens review; live Debug verification.**

## Build order (slices)
1. Sidecar fail-open decision + prompt nudge + tests.  ← FIRST (small, headline correctness)
2. Zig vocabulary + attention-features keys + tests.
3. Swift: config getters + per-tier routing across all consumers + separate clearing.
4. Event-driven classify (sidecar).
5. Web-monitor attention (P5) + crashed-sidecar GUI fallback.
6. Build Debug + live verify (drive set_attention + a real-agent bell) + review.

## Build status (v2)
- **Slice 1** (sidecar fail-open decision + prompt nudge + tests) — DONE (commit 42abf1675).
- **Slice 2** (Zig vocabulary + attention-features keys + tests) — DONE (97a23d703).
- **Slice 3a** (Swift config getters + BellFeatures flags) — DONE (8b88feab7).
- **Slice 3b-1** (bell-features default reproduces today) — DONE (6b1178e61).
- **Slice 3b-2** (per-tier consumer routing: AppDelegate sound/dock + badge, title,
  dashboard model, WebPush; replace the bellFilter gate) — DONE (2c4b996b4). Also bumped
  the shell-completion comptime branch quota (the new keys overflowed it).
- **Slice 3b-3** (two-tier surface border + zoom badge) — DONE (a05f5badb). Separate
  bell/attention clearing (P5) confirmed already wired (focus clears both independently;
  resetBell clears only bell; sidecar clears attention).
- **Slice 4** (event-driven classify: waitForEvent + coalesced wake) — DONE (1e1fa9827).
- **Slice 5a** (web-monitor `monitor` tier routing + P5 distinct attention + own clear) —
  DONE (662c0c863).
- **Slice 5b** (crashed-sidecar GUI fallback, §78) — DEFERRED, see below.
- **Slice 6** (Debug build + live verify + ≥98 review) — IN PROGRESS.
  - Review round 1 (FAIL/96): fixed a real FAIL-OPEN coerce bug (`coerceBool("maybe")`→false
    suppressed; added strict `coerceAttention`), removed the dead `attention-features-focused`
    key, added the cross-language BellFeatures bit-position tests.
  - Review round 2 (FAIL/82): fixed the BLOCKER — in the recommended `bell-features=system,audio`
    config the GUI never arms `view.bell`, so the sidecar's `list_surfaces.bell` edge detector
    was blind and promotion was silently DEAD. Fix: the GUI posts `.ghosttyBellDidRing` on EVERY
    ring (Ghostty.App.ringBell), so the MCP event bus + `wait_for_event(bell)` see every ring
    regardless of the visual flag; `bellReactiveLoop` now records `ev.id` into `pendingBellIds`,
    drained into `forcedBell` each sweep (PRIMARY signal). The `list_surfaces.bell` rising-edge
    stays as a BACKSTOP. This avoids regressing the v1 visual-bell arming gate (which Ramon's
    `bell-features-focused=...no-title` relies on to suppress a focused 🔔). Round-2 also found
    the CONFIG-MIGRATION item below.

## OPEN DECISION for review — crashed-sidecar fallback (§78)
Not implemented. The meaningful part of this fallback is the ATTENTION-TIER VISUALS
(title/border/badge/bounce/dashboard/push/monitor) — under the intended "filter on"
config SOUND is on the BELL tier, so it already fires on every raw bell regardless of
the sidecar, i.e. a real bell is never fully silent. Delivering the visual fallback on a
raw bell while the sidecar is DOWN requires one of:
  (a) a principle-#3 EXCEPTION — the GUI posts `ghosttyAttentionDidChange(true)` for the
      ringing surface when (bell-filter on && sidecar unhealthy). This drives every
      attention-tier consumer with NO new wiring and self-clears on focus. #3's rationale
      (no loud-then-retract) does NOT bite here because a DOWN sidecar never retracts.
      RECOMMENDED.
  (b) per-consumer health wiring — each consumer computes bell-features ∪ attention-
      features when unhealthy. More code, more risk, respects #3 literally.
Also needs a main-readable health signal from `AgentManagerController` (currently the
Process/backoff state is private + on a background serial queue). Deferred to your call
since §78 was flagged "for Ramon's review of this doc."

## OPEN DECISION for review — CONFIG MIGRATION (live bell-features) (found round 2)
The COMPILED default `bell-features` reproduces today (it carries attention,title +
dashboard,push,monitor). BUT the shared on-disk `~/.config/ghostty/config` (mirrored in
`example/ghostty/config`) explicitly sets `bell-features = system,attention,title,border`,
and the parse is ADDITIVE over the TYPE defaults (attention+title TRUE, the rest — incl.
dashboard/push/monitor — FALSE), so since that line doesn't list dashboard/push/monitor they
end up FALSE on the bell tier. With the filter OFF (default), the v2 consumers now gate those
three on `bell-features` (`bellDashboard`/`bellPush`/`monitorBell`), so a raw bell would
STOP auto-unhiding the dashboard tile, web-pushing, and lighting the web-monitor indicator
— a regression vs today for THIS machine (the compiled default alone would not regress).
This is INTENTIONALLY left for your config discussion: per your instruction I did NOT
touch the live config (and `example/` must stay byte-identical to it). NOTE this regression
is also partly your INTENDED design — your classification routes dashboard/push/monitor to
the ATTENTION tier, i.e. a raw bell SHOULD stop doing them and only a promotion should. The
migration when you adopt v2: either append `dashboard,push,monitor` to the `bell-features`
line (keep them on raw bells) OR accept them as attention-tier-only (your stated intent) and
rely on the sidecar promotion. Code is correct; this is a config choice, flagged for you.

## Review log (v2)
- Round 1 (88a9d7331-era): FAIL/96 — 1 major (dead `attention-features-focused`) + 2 test
  minors (string-"false" suppression untested; BellFeatures bit-ABI untested). All fixed
  (incl. the real `coerceBool` fail-open bug the "minor" masked).
- Round 2 (35732dc7d): FAIL/82 — 1 BLOCKER (promotion dead in `system,audio` config — the
  `view.bell` arming gate left `list_surfaces.bell` blind) + 1 major (the CONFIG-MIGRATION
  item above). Blocker FIXED (event-driven `pendingBellIds` promotion); config-migration
  documented as a deferred user decision (configs are off-limits per your instruction).
- Round 3 (1f03913c1): FAIL/90 — 1 major (mislabeled parse semantics: `bell-features=
  system,audio` does NOT dial down; attention+title stay on). Fixed (doc + test corrected to
  the real additive-over-type-defaults semantics + the `no-*` dial-down).
- Round 4 (ce18f3205): **PASS / 98** — all lenses ≥98 (correctness 98, design 98, threading
  99, config 98, tests 98), ZERO blocker/major. The review verified the promotion path
  end-to-end (ringBell unconditional → event bus → wait_for_event → pendingBellIds →
  forcedBell → classify), fail-open airtightness, per-effect routing across all consumers,
  principle #3, threading, and the cross-language BellFeatures bit-ABI. 3 polish nits, all
  already-documented deferrals (zoom-badge attention aggregate; tile-frame raw-vs-promoted
  visual distinction; a main-render config-read asymmetry) — cosmetic, not required.

## Verification status
- Unit: sidecar 420/420 (node --test); Zig config tests (attention-features additive +
  BellFeatures bit-ABI); Swift ConfigTests (bit-ABI mirror) + AgentDashboardTests +
  MCPServerTests + WebMonitorServerTests. Full Debug app BUILD SUCCEEDED; v2 markers
  confirmed embedded in the dylib.
- Live (prior session, core pipeline): set_attention → attentionNeeded → title 🔔 →
  clear-on-focus; real-claude bell → sidecar edge → Haiku → set_attention → attn=true; idle
  bell → attention=false.
- Live (NEW event-driven path, slice-6 round-2 fix): reviewed + unit-tested (pendingBellId
  forces a classify with bell=false); the underlying `wait_for_event` MCP tool predates v2
  (used by the queue). A full live Debug drive of bellReactiveLoop is the one remaining
  optional confidence step (offered to Ramon).

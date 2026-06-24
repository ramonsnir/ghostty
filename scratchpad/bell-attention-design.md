# Bell Attention — two-tier attention (design + build ledger)

> **Status: EXPERIMENTAL branch `bell-attention`. Do NOT merge to `ramon-fork`
> without Ramon's explicit consent.** Built on top of `ratelimit-bell` (the
> Haiku-classified rate-limit bell, also unmerged). Live config
> (`~/.config/ghostty-ramon/*`) must NOT be touched while iterating; the exact
> `bell-features` vs attention-features split is deferred to a later debate.

## Problem
A raw terminal bell (0x07) is a blunt low-level signal. Claude Code rings it for
things that need you (a permission prompt) AND things that don't (an agent that
launched a background workflow and printed "OK, it's running"). Today every bell
gets the full loud treatment (tab 🔔, dock bounce, dashboard auto-unhide, push),
so the spurious ones train you to ignore the bell.

## Principle — additive, never subtractive
The earlier "suppress the bell" framing forced *hold-and-wait* (defer every bell
until Haiku answers) — that is where all the expensive machinery (BellGate, two
channels, fail-open timers) came from. The two-tier model only ever ADDS emphasis:
- Raw bell fires IMMEDIATELY, just quietly. No deferral.
- Haiku only ever PROMOTES a bell to a louder "attention needed" state.
- Haiku latency is free (the raw bell already showed).
- Fail-safe: sidecar down/slow ⇒ you still get the quiet raw bell.

## Architecture — two separable parts
**Part A — the "attention needed" primitive (always on, no policy).**
- New sticky per-surface state `attentionNeeded` (+ optional `reason`), set by the
  sidecar via ONE new MCP tool `set_attention(id, on, reason?)`.
- When on, drives the LOUD treatment (≈ today's bell rendering): strong tab marker,
  dashboard unhide + sort-to-top + highlight, dock badge, push (rising edge).
- Auto-clears when the user focuses that surface; sidecar may also clear it.
- First-class concept; the rate-limit watchdog should route through it (unify).

**Part B — bell de-emphasis + auto-promotion (opt-in via config).**
- Config flag `agent-manager-bell-filter` (fork-only, default OFF).
- When ON: a raw PTY bell renders QUIET (dim tab indicator + quiet dashboard dot;
  no bounce/sound/push/unhide/sort). Loud reactions re-point to `attentionNeeded`.
- The sidecar promotes notable bells to `attentionNeeded`. Haiku decides, with the
  hook `agentState` as a hint.
- When OFF: behaves exactly as today. Zero change unless opted in.

## Cheap delivery mechanism (the cost-saver)
- NO new long-poll / drain tool. The sidecar already gets a per-surface `bell` flag
  in `list_surfaces`; it EDGE-DETECTS `bell` false→true each 5s sweep = a new bell.
- Classification FOLDS into the existing summarizer call: on a bell edge the sidecar
  force-summarizes that surface (bypassing debounce/idle) with a "a bell just rang"
  note in the context, and the summarizer output gains `attention?: boolean`.
  `attention:true` ⇒ `set_attention(id, true, reason)`.
- Net new surface area: 1 MCP tool (`set_attention`) + 1 config key + 1 summarizer
  output field + a prompt clause + the GUI rendering split. No deferral, no hold-path
  surgery, no host change.
- (Open: fold-into-summarizer vs a dedicated bell classifier. Folding is cheaper and
  is what we build first; the verdict-production is behind a seam so swapping is small.)

## Invariants / edge cases
- Rate-limit alert must stay LOUD regardless of the tone-down flag → route it through
  `set_attention` (unify). This is why the two features ship together.
- `attentionNeeded` is idempotent; push fires only on the off→on edge (existing
  WebPushManager debounce dedupes).
- Sticky until handled; cleared on focus.
- Compose with existing `bell-features` / `bell-features-focused`.
- A bell that stays true across sweeps classifies once (rising edge only).

## Sub-decisions (current, revisitable)
1. "Quiet" raw bell = dim tab dot + quiet dashboard dot; drops bounce/sound/push/
   unhide. Exact glyph/colour DEFERRED (bell-features debate).
2. `attentionNeeded` sticky, auto-cleared on focus.
3. Push fires only on Tier 2. Consequence: flag ON + sidecar down ⇒ no bell pushes
   (fail-closed for push only; raw bell still shows). Flag OFF ⇒ push as today.

## Open questions to settle before the GUI rendering slice
- Confirm `list_surfaces.bell` is per-surface, sticky-until-focus, AND still set under
  the quiet rendering (we edge-detect it). If window-aggregated, adjust the edge logic.
- Quiet-bell visual + the bell-features/attention-features mapping (DEFERRED, Ramon).
- Is `agentState` + "bell while working" enough to skip the Haiku call in the common
  case? Possible cheaper follow-up once we see real behavior.

## Build order (incremental, testable)
1. [ ] Zig: `agent-manager-bell-filter` config key + parse test. (no live-config edit)
2. [ ] Sidecar: `attention` field + parse; prompt "bell rang" clause; bell-edge
       detect (pure); force-classify-on-edge; `setAttention` client; tests.  ← THIS SLICE
3. [ ] Swift: `MCPAttention` pure parser + `set_attention` tool + `attentionNeeded`
       state + `.ghosttyAttentionNeeded` post + clear-on-focus + tests. (no rendering)
4. [ ] Swift rendering split (DEFERRED — needs the bell-features-vs-attention debate):
       quiet raw-bell rendering + loud attentionNeeded rendering across AppDelegate /
       SurfaceView_AppKit / BaseTerminalController / AgentDashboard / WebPushManager /
       web monitor.
5. [ ] Unify: route the rate-limit alert through `set_attention` instead of
       `signal_attention`.
6. [ ] Docs (CLAUDE.md + AGENT-MANAGER.md). Deploy: GUI relaunch + sidecar rebuild;
       no host restart.

## Test plan
- Sidecar: pure bell-edge (false→true / stays-true coalesces / clears re-arm);
  `attention` parse; orchestration — a bell edge forces a classify and `attention:true`
  calls `set_attention` (injected client). Mirrors the `bell:` rate-limit tests.
- Swift: `MCPAttention` payload parse; `set_attention` routing/decideRoute; rendering
  decision is logic-gated + unit-testable; focus-clear.
- Core: config-key parse test.

## Review log
- **Slices 1–3 reviewed** (multi-lens workflow `bell-attention-review`, 4 lenses +
  adversarial verify of blocker/major findings). Verdict **PASS / overall 98**:
  correctness 98, design 99, threading 98, tests 96. **Zero blockers, zero majors.**
  Design judged faithful to the additive/never-subtractive model; the deferred
  rendering correctly out of scope.
  - One verified MINOR (tests lens): `serializeContext`'s `bellRang` clause — the only
    thing that asks Haiku for the `attention` verdict — had no direct test (the
    runSweep tests stub `summarize`, so a regression would silently kill promotion).
    **FIXED**: added two pure `serializeContext` assertions (emits the clause on
    bellRang; absent otherwise). Sidecar now 376 tests pass.
  - Polish nit (direct `parseSummary.attention` round-trip) was already covered.
- **Build/test gate**: Zig lib+xcframework built; Debug app BUILD SUCCEEDED; sidecar
  376 `node --test` pass + typecheck; Swift MCPServerTests + MCPAnnotationTests
  TEST SUCCEEDED (19-tool count + set_attention guards). Reviewable in Debug.

## Slice 4 + 5 (DONE)
- **Slice 4 — full rendering** (committed): tab title (window attentionNeeded aggregate +
  computeTitle rule), push (WebPushManager gate + attention observer + setAttention
  userInfo enrich), dock/sound (AppDelegate), dashboard (applyAttention + needsAttention/
  sorted bellFilter gating + AgentEntry.attention + subscription + tile "needs you" pill).
- **Review round 2** (full diff incl. rendering): FAIL/92 — flag-OFF byte-identical
  (verified), but TWO majors on flag-ON:
  1. The filter SILENCED the rate-limit alert + Queue leave-and-bell (they rang via
     signal_attention→.ghosttyBellDidRing, which the tone-down suppresses; signal_attention
     never sets the sticky attentionNeeded). → **Slice 5 FIX**: route both through
     `set_attention` (the always-loud tier). `maybeSignalAlert` now setAttention(true) on
     the rising edge + setAttention(false) on clear; the Queue `signal()` wrapper →
     setAttention. Rate-limit tests updated (signalCalls→attentionCalls); runner fake gains
     setAttention→calls.signal so its leave-and-bell assertions hold.
  2. Dock badge not two-tier (raw bell still badged under filter; a promotion never
     badged). → **FIX**: `setDockBadge` counts `attentionNeeded || (bell && !bellFilter &&
     bellFeatures.attention)`; the attention aggregate publisher posts
     `.terminalWindowBellDidChangeNotification` so the badge recomputes on promotion.
  (The single deferred raw-bell TILE cosmetic under the filter was correctly out of scope.)
- Re-review after the fixes pending.

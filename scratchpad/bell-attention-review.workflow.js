export const meta = {
  name: 'bell-attention-review',
  description: 'Multi-lens A+/>=98 review of the bell-attention v2 diff (read-only, blocking gate)',
  phases: [
    { title: 'Review', detail: 'parallel lenses over the diff, each graded >=98' },
    { title: 'Verify', detail: 'adversarially verify each non-trivial finding' },
    { title: 'Synthesize', detail: 'aggregate + compute the blocking pass/fail verdict' },
  ],
}

// Each lens reviews the SAME v2 diff through a distinct lens and returns a strict
// score + findings. `args` carries { base, head, worktree, testStatus }.
const LENSES = [
  {
    key: 'correctness',
    prompt:
      'CORRECTNESS lens. Hunt for real bugs in the v2 logic. SIDECAR (macos/agent-manager): ' +
      'the FAIL-OPEN bell decision in summarizeOne/bellPromote — on a bell-edge classify, ' +
      'PROMOTE (set_attention(true)) unless we got a clean parsed attention===false; the ' +
      'unparseable / thrown / omitted / uncertain paths ALL promote; only a confident false ' +
      'suppresses. The event-driven path: parseWaitForEvent (fired {id,type} | null, never ' +
      'throws), makeCoalescedRunner (non-overlap: a wake mid-run coalesces to exactly one ' +
      're-run, suppressed when stopped), bellReactiveLoop (long-poll wait_for_event(bell) -> ' +
      'wake an immediate coalesced sweep; the sweep does the promote; never exits on error). ' +
      'SWIFT consumers — verify the TWO-TIER routing rule is applied CONSISTENTLY: a RAW bell ' +
      'fires bell-features effects; a PROMOTED attentionNeeded adds attention-features effects; ' +
      'each effect is gated by its own flag in the right tier. Check: AppDelegate playBellEffects ' +
      '(system->beep, audio->sound, bounce||attention->requestUserAttention) on bell-features for ' +
      'ghosttyBellDidRing and attention-features for ghosttyAttentionDidChange; setDockBadge two-tier ' +
      '((bell && bell.badge|attention) || (attentionNeeded && attn.badge|attention)); ' +
      'BaseTerminalController.computeTitle ((bell && bell.title) || (attention && attn.title)); ' +
      'SurfaceView BellBorderOverlay ((bell && bell.border) || (attentionNeeded && attn.border)) + ' +
      'the zoom-badge gate; AgentDashboardModel (applyBells unhide iff bellDashboard, applyAttention ' +
      'iff attnDashboard, needsAttention/sorted per-tier); WebMonitorPush (bellPush/attnPush gates); ' +
      'WebMonitorServer.surfacesJSONData attnIndicator = (bell && monitorBell) || (attentionNeeded && ' +
      'monitorAttn) + the /attention clear route -> resetAttention. INVARIANTS: the `attention` flag ' +
      'is a back-compat alias for bounce+badge consistently; filter-OFF + default config is ' +
      'byte-identical to upstream (bell-features default carries the rich set, attentionNeeded never ' +
      'set without the sidecar); the GUI NEVER auto-sets attentionNeeded (principle #3 — only the ' +
      'sidecar set_attention does); bell and attentionNeeded clear INDEPENDENTLY (focus clears both; ' +
      'resetBell only bell; resetAttention only attention).',
  },
  {
    key: 'design',
    prompt:
      'DESIGN/ARCHITECTURE lens. Judge adherence to scratchpad/bell-attention-v2-design.md: ' +
      '(1) FAIL-OPEN — a bell is suppressed ONLY by a live sidecar with a confident Haiku ignore; ' +
      'every other state (disabled/out-of-tokens/timeout/crash/unparseable/uncertain) stays loud. ' +
      '(2) FULLY CONFIGURABLE — per-effect routing is config (bell-features vs attention-features ' +
      'over one shared vocabulary), NOT hardcoded; Ramon\'s classification is just the DEFAULT. ' +
      '(3) The GUI NEVER auto-sets attention. Verify the v1 `bellFilter` consumer BRANCH was fully ' +
      'removed in favor of the two-tier config (no leftover bellFilter gate in a consumer). Verify ' +
      'the event-driven wake reuses the EXISTING sweep (no duplicated classify/edge bookkeeping) and ' +
      'only adds the wait_for_event capability (no new server tool). Verify the web monitor stayed ' +
      'scoped (no new foundation built on it). Confirm the deferred §78 crashed-sidecar fallback is a ' +
      'CLEAN omission (documented, default config does not need it) — do NOT raise §78 as a blocker.',
  },
  {
    key: 'threading',
    prompt:
      'CONCURRENCY/THREADING lens. The MCP/web-monitor servers run on dedicated serial queues; ' +
      'handlers hop to main and return ONLY value types (never a SurfaceView across the hop). ' +
      'Verify MCPServer.setAttention + WebMonitorServer.clearAttention/clearBell follow this ' +
      '(respondFromMain, capture title/pwd as values, no SurfaceView escaping). Verify the SurfaceView ' +
      'NotificationCenter observers (bell + ghosttyAttentionDidChange) are main-thread, surfaceID-' +
      'filtered, and torn down (no retain cycle). SIDECAR: makeCoalescedRunner is single-threaded JS ' +
      'but verify the running/again flags can\'t drop a wake or double-run; bellReactiveLoop holds ONE ' +
      'long-lived parked connection (within the conn cap) and the per-call fetch timeout exceeds the ' +
      'park window so it never aborts a live wait. Flag any main.sync that could deadlock from main. ' +
      'WebMonitorServer.monitorBell/monitorAttn are written once before start() and read on the main ' +
      'hop — confirm no torn read.',
  },
  {
    key: 'config',
    prompt:
      'CONFIG / BACK-COMPAT lens. The BellFeatures type is shared by both tiers. Verify the Zig ' +
      'packed-struct bit order (src/config/Config.zig: system/audio/attention/title/border/bounce/' +
      'badge/dashboard/push/monitor) EXACTLY matches the Swift OptionSet rawValues (Ghostty.Config.swift ' +
      '1<<0..1<<9) — a mismatch silently corrupts every flag read. Verify the new keys attention-features ' +
      '/ attention-features-focused parse, default correctly, and that bell-features / bell-features-' +
      'focused DEFAULTS reproduce TODAY (attention,title + the always-on dashboard/push/monitor) so an ' +
      'unconfigured fork behaves exactly as before. Verify the flag parser RESET-to-listed semantics ' +
      '(a provided value zeroes then ORs). Confirm all new keys are FORK-ONLY (an official Ghostty ' +
      'sharing ~/.config/ghostty/config must not see them) and documented as such. Check the shell-' +
      'completion comptime quota bump is correct (not masking a real overflow).',
  },
  {
    key: 'tests',
    prompt:
      'TEST-COVERAGE lens. The sidecar suite (414 node --test) + the Swift suites are the safety net. ' +
      'Assess whether the LOAD-BEARING v2 behaviors are tested: the fail-open decision (omitted/thrown/' +
      'unparseable promote; only confident false suppresses), parseWaitForEvent (fired/timeout/malformed/' +
      'partial), makeCoalescedRunner (serial, coalesce-one, stop-suppresses), the Zig attention-features ' +
      'parse + bell-features default, the Swift two-tier sort (AgentDashboardTests dashboardInBellTier / ' +
      'dashboardNotInBellTier / attentionFloatsFirst / rawBellFloatGatedByDashboardTier), and the web-' +
      'monitor attnIndicator routing + /attention route decode. Name SPECIFIC missing tests a reviewer ' +
      'would require for A+. Untestable-by-design (do NOT require): the exact SwiftUI visual pixels, the ' +
      'live bellReactiveLoop wiring in main() (only its pure parts are testable).',
  },
]

const FINDINGS_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['score', 'findings'],
  properties: {
    score: { type: 'integer', minimum: 0, maximum: 100, description: 'A+/>=98 is passing.' },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['severity', 'title', 'where', 'detail'],
        properties: {
          severity: { type: 'string', enum: ['blocker', 'major', 'minor', 'nit'] },
          title: { type: 'string' },
          where: { type: 'string', description: 'file:line or symbol' },
          detail: { type: 'string', description: 'what is wrong + the fix' },
        },
      },
    },
  },
}

const VERDICT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['real', 'severity', 'why'],
  properties: {
    real: { type: 'boolean', description: 'true if this is a genuine issue worth fixing' },
    severity: { type: 'string', enum: ['blocker', 'major', 'minor', 'nit'] },
    why: { type: 'string' },
  },
}

const ctx =
  `Review the bell-attention v2 feature on a git worktree.\n` +
  `Worktree: ${args.worktree}\n` +
  `Diff to review: \`git -C ${args.worktree} diff ${args.base}...${args.head}\` (also read the ` +
  `full files for context, and scratchpad/bell-attention-v2-design.md for the intended design + ` +
  `the build status / the §78 OPEN DECISION at the bottom).\n` +
  `Test status handed in: ${args.testStatus}\n` +
  `SCOPE: v2 is a fully-configurable, fail-open, TWO-TIER redesign. A RAW bell always fires the ` +
  `bell-features effects immediately; a sidecar PROMOTION (set_attention, fail-open: promote unless ` +
  `a confident Haiku ignore) ADDS the attention-features effects. Each effect (system,audio,bounce,` +
  `badge,title,border,dashboard,push,monitor; `+'`attention`'+` = bounce+badge alias) is routed to a ` +
  `tier by config. The v1 single `+'`bellFilter`'+` consumer gate was REPLACED by this. DEFAULTS ` +
  `reproduce today. The GUI NEVER auto-sets attentionNeeded (principle #3). The §78 crashed-sidecar ` +
  `fallback is DELIBERATELY DEFERRED (documented, flagged for the author\'s review) — do NOT raise it ` +
  `as a blocker/major.\n` +
  `ALSO OUT OF SCOPE (deferred user decisions — do NOT raise as blocker/major): (1) the CONFIG MIGRATION ` +
  `of the LIVE/example bell-features VALUES. The author was instructed NOT to touch the live config (and ` +
  `example/ must stay byte-identical to it), so example/ghostty/config etc. intentionally still hold the ` +
  `PRE-v2 values; what the CODE must guarantee is that the COMPILED DEFAULT in Config.zig reproduces today ` +
  `(judge THAT, not the on-disk example values) — the live-config update is part of the pending config ` +
  `discussion. Verify the compiled default + the routing code; treat the example-config values as the ` +
  `user\'s call.\n` +
  `PROMOTION PATH (verify THIS, not the stale assumption that it needs view.bell): a real bell posts ` +
  `.ghosttyBellDidRing UNCONDITIONALLY (Ghostty.App.ringBell) → the MCP event bus → wait_for_event(bell). ` +
  `The sidecar bellReactiveLoop records ev.id into pendingBellIds (the PRIMARY signal, truthful on every ` +
  `ring even when view.bell/list_surfaces.bell is never armed in the system,audio config), drained into ` +
  `forcedBell each sweep; the list_surfaces.bell rising-edge is only a BACKSTOP (for title/border configs). ` +
  `So promotion does NOT depend on view.bell being armed — confirm that holds.\n` +
  `Grade strictly: 98+ = A+. Return JSON per the schema.`

phase('Review')
// Pipeline: each lens reviews, then its blocker/major findings are adversarially
// verified as soon as that lens returns (no barrier between review and verify).
const reviewed = await pipeline(
  LENSES,
  (lens) =>
    agent(`${ctx}\n\nLENS: ${lens.prompt}`, {
      label: `review:${lens.key}`,
      phase: 'Review',
      schema: FINDINGS_SCHEMA,
    }).then((r) => ({ lens: lens.key, ...r })),
  (r) =>
    parallel(
      (r.findings || [])
        .filter((f) => f.severity === 'blocker' || f.severity === 'major')
        .map((f) => () =>
          agent(
            `${ctx}\n\nAdversarially VERIFY this ${r.lens} finding — try to REFUTE it; ` +
              `default real=false if you cannot confirm it against the actual code:\n` +
              `${f.title} @ ${f.where}\n${f.detail}`,
            { label: `verify:${r.lens}:${f.where}`.slice(0, 60), phase: 'Verify', schema: VERDICT_SCHEMA },
          ).then((v) => ({ ...f, lens: r.lens, verdict: v })),
        ),
    ).then((verified) => ({ ...r, verified: verified.filter(Boolean) })),
)

phase('Synthesize')
const confirmed = reviewed.flatMap((r) =>
  (r.verified || []).filter((f) => f.verdict?.real),
)
const minScore = reviewed.reduce((m, r) => Math.min(m, r.score ?? 0), 100)
const blockers = confirmed.filter((f) => f.verdict.severity === 'blocker')
const majors = confirmed.filter((f) => f.verdict.severity === 'major')
const pass = minScore >= 98 && blockers.length === 0 && majors.length === 0

const summary = await agent(
  `${ctx}\n\nSynthesize the review. Per-lens scores: ` +
    JSON.stringify(reviewed.map((r) => ({ lens: r.lens, score: r.score }))) +
    `\nConfirmed (verified-real) blocker/major findings: ` +
    JSON.stringify(confirmed.map((f) => ({ lens: f.lens, sev: f.verdict.severity, title: f.title, where: f.where, fix: f.detail }))) +
    `\nWrite a concise verdict: PASS (>=98, no blocker/major) or FAIL, the must-fix list ` +
    `(if any) in priority order with exact file:line + fix, and any A+ polish nits worth doing.`,
  { label: 'synthesize', phase: 'Synthesize' },
)

return {
  pass,
  minScore,
  perLens: reviewed.map((r) => ({ lens: r.lens, score: r.score, findings: (r.findings || []).length })),
  mustFix: confirmed.map((f) => ({ lens: f.lens, severity: f.verdict.severity, title: f.title, where: f.where, fix: f.detail })),
  summary,
}

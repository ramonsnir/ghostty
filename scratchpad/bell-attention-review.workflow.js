export const meta = {
  name: 'bell-attention-review',
  description: 'Multi-lens A+/>=98 review of the bell-attention feature diff (read-only, blocking gate)',
  phases: [
    { title: 'Review', detail: 'parallel lenses over the diff, each graded >=98' },
    { title: 'Verify', detail: 'adversarially verify each non-trivial finding' },
    { title: 'Synthesize', detail: 'aggregate + compute the blocking pass/fail verdict' },
  ],
}

// The lenses. Each reviews the SAME diff through a distinct lens and returns a
// strict score + findings. `args` carries { base, head, worktree } so each agent
// can read the diff itself.
const LENSES = [
  {
    key: 'correctness',
    prompt:
      'CORRECTNESS lens. Hunt for real bugs in the logic: the sidecar bell-edge ' +
      'detection (bellRoseEdge, the rising-edge map update + dead-id prune), the ' +
      'force-classify-past-debounce path (bellRang in summarizeOne + the runSweep ' +
      'gate that allows forced surfaces through ONLY on a debounce objection, never ' +
      'not-agent), the attention promotion (only on bellRang AND parsed.attention===true; ' +
      'idempotent set_attention; failures swallowed), the Swift set_attention tool ' +
      '(pre-hop id/on validation, main-hop resolve, .ghosttyAttentionDidChange post), ' +
      'the SurfaceView observer (filtered by surfaceID since posted object:nil) + ' +
      'clear-on-focus, and the config/env plumbing (agent-manager-bell-filter -> ' +
      'GHOSTTY_BELL_FILTER). Check the invariants hold: signal_attention (rate-limit) ' +
      'stays exempt from any tone-down; bellFilter OFF is byte-identical; nothing rings ' +
      'or promotes without a successful Haiku classify.',
  },
  {
    key: 'design',
    prompt:
      'DESIGN/ARCHITECTURE lens. Judge adherence to the two-tier ADDITIVE model in ' +
      'scratchpad/bell-attention-design.md: the raw bell must always fire immediately ' +
      '(no deferral / hold-and-wait anywhere), Haiku only ever PROMOTES (fail-safe: ' +
      'sidecar down => still the raw bell), and the design must reuse existing patterns ' +
      '(mirrors applyAnnotation / the alert path / the queue env plumbing). Flag any ' +
      'creeping deferral, any new long-poll/drain tool that was supposed to be avoided ' +
      '(only set_attention should be new), and whether the deferred rendering boundary ' +
      'is cleanly separated (no half-built visual that pre-empts the bell-features debate).',
  },
  {
    key: 'threading',
    prompt:
      'CONCURRENCY/THREADING lens. The MCP server runs on a dedicated serial queue; ' +
      'handlers hop to main via DispatchQueue.main.sync/async and must return ONLY ' +
      'value types across the hop (never a SurfaceView). Verify setAttention follows ' +
      'this (sync to check existence, async to post; no SurfaceView escaping). Verify ' +
      'the SurfaceView NotificationCenter observer is safe (main-thread @objc, id filter, ' +
      'no retain cycle / removed on deinit like the bell observer). Verify the sidecar ' +
      'bell pass cannot deadlock or double-fire (the per-sweep non-overlap + budget). ' +
      'Flag any main.sync that could deadlock if called from main.',
  },
  {
    key: 'tests',
    prompt:
      'TEST-COVERAGE lens. The sidecar suite (374 tests) and the Swift MCP dispatch ' +
      'guards are the safety net. Assess whether the LOAD-BEARING behaviors are tested: ' +
      'bellRoseEdge (rise/held/clear), parseSummary.attention, the runSweep bell ' +
      'force-through (bellFilter on/off, rising-edge-only, non-agent never, attention ' +
      'true/false promote/not, failure swallowed, dead-id prune, attention-only-on-bell), ' +
      'and the Swift set_attention pre-hop guards + tool-count. Name the SPECIFIC missing ' +
      'tests (if any) that a reviewer would require for A+ — but do NOT credit tests that ' +
      'cannot exist yet (the rendering is deferred).',
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
  `Review the bell-attention feature on a git worktree.\n` +
  `Worktree: ${args.worktree}\n` +
  `Diff to review: \`git -C ${args.worktree} diff ${args.base}...${args.head}\` (also read the ` +
  `full files for context, and scratchpad/bell-attention-design.md for the intended design).\n` +
  `Test status handed in: ${args.testStatus}\n` +
  `IMPORTANT: the quiet/loud RENDERING is DELIBERATELY deferred (the bell-features debate) — ` +
  `do NOT raise its absence as a blocker/major; only review what is implemented.\n` +
  `Grade strictly: 98+ = A+. Return JSON per the schema.`

phase('Review')
// Pipeline: each lens reviews, then its non-trivial findings are adversarially
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

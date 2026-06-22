export const meta = {
  name: 'webmon-perf',
  description: 'Fix web-monitor latency: de-block the serial queue (main.async) + cache surfaces JSON, with blocking A+/98 design and review gates',
  phases: [
    { title: 'Design', detail: 'spec the change; adversarial critics; gate avg>=98 & no blocker' },
    { title: 'Implement', detail: 'apply the approved spec to the worktree (single implementer)' },
    { title: 'Review', detail: '4-lens review of the real diff; fix loop until gate avg>=98 & no blocker' },
  ],
}

const WT = '/Users/ramon/git/ghostty/.claude/worktrees/webmon-perf'
const FILE = `${WT}/macos/Sources/Features/WebMonitor/WebMonitorServer.swift`
const TESTS = `${WT}/macos/Tests/WebMonitor/WebMonitorServerTests.swift`

// Shared grounding: the measured problem + the load-bearing code facts. Embedded
// in every phase so agents reason from the real code, not guesses.
const CONTEXT = `
PROJECT: Ghostty ramon-fork, macOS GUI web monitor (phone-only feature). Work ONLY in the
worktree: ${WT}. Target file: ${FILE}. Test file: ${TESTS}.
This is a GUI-only Swift change — NO Zig, NO host restart. DO NOT run xcodebuild/swift build/
build.nu (they are very slow and will trip the agent watchdog); the human runs builds + tests
after the workflow. You MAY run \`git -C ${WT} diff\` and read files.

MEASURED PROBLEM (diagnosed against the live server):
- A browser page load fires ~8 parallel requests (/, /xterm.js, /xterm.css, 2 fonts,
  /api/surfaces, /api/push/config, /sw.js). They are served HEAD-TO-TAIL: /api/surfaces did
  not start responding for 11s, assets queued behind it, full page ~14s. ttfb≈total on all.
- A single /api/surfaces in isolation swung 4–19s.
- /xterm.css (a STATIC asset needing nothing from main) hung 18–20s when stuck behind the
  backlog, then 0.0018s once drained.

ROOT CAUSE (two compounding factors):
1. WebMonitorServer.swift:52 — \`private let queue = DispatchQueue(label: ...)\` is a SERIAL
   queue. The NWListener AND every connection run on it (conn.start(queue: queue) at ~364,
   listener at ~251). So connections are processed strictly one-at-a-time.
2. Each /api/* handler does \`let result = DispatchQueue.main.sync { ... }\` to read AppKit/
   surface state. That BLOCKS the serial queue for the entire (multi-second, under load) hop,
   so every other connection — including static assets that need nothing from main — waits.
   Main is heavily loaded (SwiftUI NSHostingView.updateConstraints / GraphHost.flushTransactions
   from ~16 live surfaces + the agent dashboard's mirror SurfaceViews), so each hop is slow.

CODE FACTS (verified by reading the file):
- final class WebMonitorServer (NOT @MainActor). Serial \`queue\` at line ~52.
- The main.sync handlers in routeRequest (~631): .surfacesList (~676), .screen (~689),
  .input (~725), .scroll (~748), .clearBell (~767), and routeStream's resolve hop (~903).
  Each is \`let r: HTTPResponse = DispatchQueue.main.sync { ...AppKit... }; send(r, on: conn)\`.
- Static/push handlers (.asset ~774, .serviceWorker ~783, .pushConfig ~789, .pushSubscribe,
  .pushUnsubscribe, .pushEnabled, .page) DO NOT hop to main — leave them unchanged.
- send(_:on:) at ~1476 runs on \`queue\`: it calls cancelConnectionTimer(ObjectIdentifier(conn))
  (touches connectionTimers + connectionDeadlineTimers dicts), writes head+body, then
  conn.send(... completion: cancel). NWConnection methods are thread-safe but the dict access
  in cancelConnectionTimer is NOT — it relies on running on \`queue\`.
- Shared mutable state, all currently race-free BECAUSE serial, mutated on \`queue\`:
  connectionRefs (~68), connectionTimers (~71), connectionDeadlineTimers (~78),
  streamClients (~92), streamingConns (~101), failedAuth (~109). The auth helpers
  failedAuthCount/recordAuthFailure/clearAuthFailures (~115–143) are called from routeRequest.
- Timers: armConnectionTimer (idle ~10s) + armConnectionDeadline (absolute ~15s) are
  DispatchSourceTimer on \`queue\`. receiveRequest's .complete case (~464) calls
  cancelConnectionTimer(key) BEFORE routeRequest — so cancelConnectionTimer cancels BOTH the
  idle and the absolute-deadline timer there. (Verify this: cancelConnectionTimer at ~399
  cancels both connectionTimers[key] AND connectionDeadlineTimers[key].) routeStream removes
  the connection from timers and inserts into streamingConns; /stream is watchdog-exempt.
- stop() at ~260 tears down via queue.async (NEVER queue.sync from main — documented
  lock-order rule against handlers' main.sync).
- Existing tests: ${TESTS} (auto-discovered by the GhosttyTests filesystem-synchronized group).
  decideRoute / hostHeaderAllowed / surfacesJSONData / RequestParser / parseListen etc. are
  \`internal\` + unit-tested. surfacesJSON() (~1244) builds rows on main; surfacesJSONData(~1281)
  is the PURE shaper.

PROPOSED APPROACH (the seed to refine — keep the queue SERIAL, do NOT introduce a concurrent
queue + locks; the measurements show the synchronous per-connection work is tiny, so simply
not BLOCKING the serial queue on main is sufficient and far lower risk):
- LEVER 1 (de-block): add a helper that hops to main ASYNC to compute the value-type
  HTTPResponse, then hops BACK to \`queue\`.async to call send(result, on: conn). Roughly:
    private func respondFromMain(on conn: NWConnection, _ work: @escaping () -> HTTPResponse) {
      DispatchQueue.main.async {
        let response = work()
        self.queue.async { self.send(response, on: conn) }
      }
    }
  Convert each of the 6 main.sync handlers to use it. This frees \`queue\` during the main hop
  (next connection — e.g. a static asset — proceeds immediately), and send() still runs on
  \`queue\` so all dict access stays serialized (invariant preserved). Only value types cross
  the hop (HTTPResponse), preserving the "never a surface across the hop" rule. routeStream's
  resolve hop is special: it returns Resolved? then conditionally 404/501/streams — adapt the
  async pattern carefully (the streaming setup after resolve must run on \`queue\`).
- LEVER 2 (cache /api/surfaces): add \`private var cachedSurfaces: (data: Data, at: Date)?\`
  (accessed ONLY on \`queue\`) + a TTL (~1.0s; page polls every 3s). In .surfacesList, on
  \`queue\`: if fresh (Date().timeIntervalSince(at) < TTL) send cached data directly (NO main
  hop); else hop to main to build, then on \`queue\` store cache + send. Bounds main-thread
  surfacesJSON builds to ~1/sec regardless of client/poll count.
- TIMER/DEADLINE RACE (must address): today the 15s absolute-deadline timer is effectively
  frozen during a long main.sync because \`queue\` is blocked. Freeing \`queue\` (lever 1) lets it
  FIRE mid-compute and cancel the connection at 15s. Decide + justify the fix: simplest correct
  option is that the absolute deadline's purpose (bound a trickle/slowloris CLIENT) is already
  satisfied once the request is fully received, so cancel BOTH timers at .complete (the idle one
  already is). Confirm cancelConnectionTimer at .complete already cancels both; if so, the race
  may already be covered — VERIFY and state it explicitly. send() is idempotent re: a
  cancelled conn (writing to a dead conn just fails harmlessly).
- SECURITY/BEHAVIOR INVARIANTS that must be preserved: Host-header allowlist, per-peer token
  backoff (clearAuthFailures/recordAuthFailure ordering — these run on \`queue\` BEFORE the
  hop, keep them there), /stream head-of-line freedom, 32-conn cap, teardown via queue.async,
  Connection: close semantics, "only value types cross the main hop".
`

phase('Design')

const SPEC_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['spec', 'timerRaceVerdict', 'openQuestions'],
  properties: {
    spec: { type: 'string', description: 'Precise, diff-level implementation spec: exact new helper(s), each handler conversion, the surfaces TTL cache, timer/deadline handling, and the tests to add. Markdown.' },
    timerRaceVerdict: { type: 'string', description: 'Explicit determination of whether the absolute-deadline timer can fire mid-compute after de-blocking, and the chosen fix (or why already covered).' },
    openQuestions: { type: 'array', items: { type: 'string' } },
  },
}
const CRITIC_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['score', 'blockers', 'majors', 'notes'],
  properties: {
    score: { type: 'number', description: '0–100 quality of the spec for correctness + safety + meeting the perf goal with minimal risk.' },
    blockers: { type: 'array', items: { type: 'string' }, description: 'Issues that MUST be fixed (deadlock, regression, security, data race, perf goal not met).' },
    majors: { type: 'array', items: { type: 'string' } },
    notes: { type: 'string' },
  },
}

let spec = await agent(
  `${CONTEXT}\n\nYou are the DESIGN agent. Read the actual code at ${FILE} (focus on the lines cited
above) and produce a precise, diff-level implementation spec that refines the PROPOSED APPROACH.
Be concrete: name the exact helper signatures, show each of the 6 handler conversions, the
surfaces TTL cache fields + logic, and the timer/deadline resolution (verify the .complete path
yourself by reading cancelConnectionTimer). List the exact unit tests to add (e.g. a TTL-cache
freshness test on a pure helper, a respond-from-main ordering note). Keep it SERIAL-queue based;
do NOT propose a concurrent queue + locks. Minimal, surgical, invariant-preserving.`,
  { label: 'design:spec', phase: 'Design', schema: SPEC_SCHEMA },
)

const CRITIC_LENSES = [
  { key: 'threading', focus: 'Threading & deadlock correctness: every shared-dict access stays on `queue`; no main.sync re-introduced; respondFromMain ordering (main.async -> queue.async -> send) is sound; no new deadlock vs the stop() queue.async rule; routeStream resolve adaptation is correct.' },
  { key: 'regression', focus: 'Behavioral regression vs documented invariants: Host allowlist, per-peer backoff ordering, /stream head-of-line freedom + watchdog exemption, 32-conn cap, Connection: close, "only value types cross the hop", the absolute-deadline timer race. Does the surfaces TTL cache ever serve cross-token or stale-after-close data in a harmful way?' },
  { key: 'perfsimplicity', focus: 'Does it actually fix the measured problem (parallel requests no longer head-of-line blocked; /api/surfaces main builds bounded by TTL)? Is it the SIMPLEST change that does so, with no scope creep, no concurrent-queue complexity, and adequate but not excessive tests?' },
]

for (let round = 0; round < 3; round++) {
  const critiques = await parallel(CRITIC_LENSES.map(l => () =>
    agent(
      `${CONTEXT}\n\nYou are an adversarial CRITIC (lens: ${l.key}). Here is the proposed spec:\n\n` +
      `SPEC:\n${spec.spec}\n\nTIMER-RACE VERDICT:\n${spec.timerRaceVerdict}\n\n` +
      `Scrutinize it through your lens ONLY: ${l.focus}\nRead the real code at ${FILE} to verify claims. ` +
      `Score 0–100; default to LOW if anything is unverified or risky. List concrete blockers/majors.`,
      { label: `critic:${l.key}:r${round + 1}`, phase: 'Design', schema: CRITIC_SCHEMA },
    )))
  const valid = critiques.filter(Boolean)
  const scores = valid.map(c => c.score)
  const avg = scores.reduce((a, b) => a + b, 0) / (scores.length || 1)
  const minScore = Math.min(...scores)
  const blockers = valid.flatMap(c => c.blockers || [])
  log(`Design round ${round + 1}: avg=${avg.toFixed(1)} min=${minScore} blockers=${blockers.length}`)
  if (avg >= 98 && minScore >= 95 && blockers.length === 0) {
    log(`Design gate PASSED (avg ${avg.toFixed(1)})`)
    break
  }
  if (round === 2) {
    log(`Design gate not reached after 3 rounds (avg ${avg.toFixed(1)}); proceeding with best spec + caveats`)
    break
  }
  // Revise the spec against the critiques.
  const allCrit = valid.map((c, i) => `Lens ${CRITIC_LENSES[i].key} (score ${c.score}):\n  blockers: ${JSON.stringify(c.blockers)}\n  majors: ${JSON.stringify(c.majors)}\n  notes: ${c.notes}`).join('\n\n')
  spec = await agent(
    `${CONTEXT}\n\nYou are the DESIGN agent revising your spec to address critiques. CURRENT SPEC:\n\n${spec.spec}\n\n` +
    `TIMER-RACE VERDICT:\n${spec.timerRaceVerdict}\n\nCRITIQUES:\n${allCrit}\n\n` +
    `Produce an improved spec that resolves every blocker and the strongest majors, WITHOUT adding scope ` +
    `or switching to a concurrent queue. Re-verify against the real code.`,
    { label: `design:revise:r${round + 1}`, phase: 'Design', schema: SPEC_SCHEMA },
  )
}

phase('Implement')

const implementResult = await agent(
  `${CONTEXT}\n\nYou are the IMPLEMENTER. Apply this APPROVED SPEC to the worktree, editing\n${FILE}\n` +
  `and adding the specified unit tests to ${TESTS}. Make surgical edits with the Edit tool; match the\n` +
  `file's existing comment density and style (it is heavily commented — add a clear comment on the new\n` +
  `helper + cache explaining WHY, referencing the head-of-line-blocking fix). Do NOT build. When done,\n` +
  `run \`git -C ${WT} diff --stat\` and \`git -C ${WT} diff\` and return a summary of what you changed plus\n` +
  `any deviations from the spec and why.\n\nAPPROVED SPEC:\n${spec.spec}\n\nTIMER-RACE VERDICT:\n${spec.timerRaceVerdict}`,
  { label: 'implement', phase: 'Implement' },
)
log('Implementation applied; entering review loop')

phase('Review')

const REVIEW_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['score', 'blockers', 'majors', 'notes'],
  properties: {
    score: { type: 'number' },
    blockers: { type: 'array', items: { type: 'string' }, description: 'Each blocker: file:line + concrete problem + suggested fix.' },
    majors: { type: 'array', items: { type: 'string' } },
    notes: { type: 'string' },
  },
}
const REVIEW_LENSES = [
  { key: 'threading', focus: 'Threading/deadlock: all shared-dict access stays on `queue`; respondFromMain hop ordering correct; no main.sync left in the converted handlers; no new lock-order inversion; routeStream still correct + still watchdog-exempt.' },
  { key: 'regression', focus: 'Regression vs invariants: backoff ordering, Host allowlist, Connection: close, value-types-only hop, the absolute-deadline timer race resolved, surfaces cache cannot serve harmful stale/cross-context data.' },
  { key: 'perf', focus: 'Perf goal met: parallel requests no longer head-of-line blocked; static assets unaffected by a slow /api/surfaces; surfaces main builds bounded by the TTL. Confirm by reading the converted handlers.' },
  { key: 'tests', focus: 'Test coverage + Swift correctness/compile-sanity (you cannot build): new tests are meaningful and self-contained, match the existing test style, will plausibly compile (correct types, internal access), and actually exercise the cache/ordering logic. Flag any obvious compile error in the diff.' },
]

let reviewIssues = ''
for (let round = 0; round < 3; round++) {
  const reviews = await parallel(REVIEW_LENSES.map(l => () =>
    agent(
      `${CONTEXT}\n\nYou are a REVIEWER (lens: ${l.key}). Read the CURRENT diff with\n` +
      `\`git -C ${WT} diff\` and the full changed regions of ${FILE} (+ ${TESTS}). Review through your lens ` +
      `ONLY: ${l.focus}\nScore 0–100 (default LOW if unverified). Give blockers/majors as file:line + ` +
      `concrete problem + fix.`,
      { label: `review:${l.key}:r${round + 1}`, phase: 'Review', schema: REVIEW_SCHEMA },
    )))
  const valid = reviews.filter(Boolean)
  const scores = valid.map(r => r.score)
  const avg = scores.reduce((a, b) => a + b, 0) / (scores.length || 1)
  const minScore = Math.min(...scores)
  const blockers = valid.flatMap(r => r.blockers || [])
  const majors = valid.flatMap(r => r.majors || [])
  log(`Review round ${round + 1}: avg=${avg.toFixed(1)} min=${minScore} blockers=${blockers.length} majors=${majors.length}`)
  reviewIssues = valid.map((r, i) => `Lens ${REVIEW_LENSES[i].key} (score ${r.score}):\n  blockers: ${JSON.stringify(r.blockers)}\n  majors: ${JSON.stringify(r.majors)}\n  notes: ${r.notes}`).join('\n\n')
  if (avg >= 98 && minScore >= 95 && blockers.length === 0) {
    log(`Review gate PASSED (avg ${avg.toFixed(1)})`)
    return { status: 'passed', round: round + 1, avg, reviewIssues, implementSummary: implementResult }
  }
  if (round === 2) {
    log(`Review gate not reached after 3 rounds (avg ${avg.toFixed(1)})`)
    return { status: 'incomplete', avg, reviewIssues, implementSummary: implementResult }
  }
  // Fix the blockers + strong majors (sequential single fixer — same file).
  await agent(
    `${CONTEXT}\n\nYou are the FIXER. Address every BLOCKER and the strongest MAJORS from this review by ` +
    `editing the worktree files (surgical Edit calls; update tests too). Do NOT build. Do NOT regress ` +
    `anything already correct or add scope. When done, return a short summary of each fix.\n\nREVIEW:\n${reviewIssues}`,
    { label: `fix:r${round + 1}`, phase: 'Review' },
  )
}

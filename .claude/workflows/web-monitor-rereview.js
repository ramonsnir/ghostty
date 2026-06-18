export const meta = {
  name: 'web-monitor-rereview',
  description: 'Watchdog-hardened final re-review: 4 terse, targeted lenses (code/design/UX/test-coverage) graded for A+/>=98, then synthesized. NO builds inside agents (test results are handed in); each lens reads only its targeted sections to keep turns short.',
  phases: [
    { title: 'Re-review', detail: '4 targeted terse lenses in parallel' },
    { title: 'Synthesis', detail: 'consolidated verdict' },
  ],
}

const REPO = '/Users/ramon/git/ghostty'
const SERVER = REPO + '/macos/Sources/Features/WebMonitor/WebMonitorServer.swift'
const TESTS = REPO + '/macos/Tests/WebMonitor/WebMonitorServerTests.swift'

const VERIFIED = [
  'ALREADY-VERIFIED BUILD/TEST STATE (do NOT re-run any build or test — these are confirmed by the human in the main loop; running zig/xcodebuild is what STALLED the last review, so DO NOT):',
  '  - macОS ReleaseLocal app build: SUCCEEDED (the server Swift compiles).',
  '  - zig build test -Dtest-filter=web-monitor: PASS (config parse/default test).',
  '  - xcodebuild -only-testing:GhosttyTests/WebMonitorServerTests: ** TEST SUCCEEDED ** — ALL cases pass (incl. the',
  '    new A+ hardening tests: query-token-rejected-on-API, header-token-accepted-on-API, tokenAcceptable strength',
  '    gate, and the added route-branch tests),',
  '    covering tokensMatch (equal/diff-content/diff-len/empty/multibyte/off-by-one), decodeInput (named keys',
  '    incl. arrows/tab, unknown->nil, json/charset/non-json, raw, empty, brace-leading), parseListen (ipv4,',
  '    bracketed ipv6, missing/empty/non-numeric/oob port, hostname), the RequestParser (needMore, reassembly,',
  '    negative/non-numeric CL->badRequest, oversized CL->badRequest, over-cap->tooLarge, chunked->lengthRequired,',
  '    non-UTF8->badRequest, conflicting/duplicate Content-Length, at-cap boundary), hostHeaderAllowed (exact,',
  '    loopback, ipv6 loopback, wrong port, attacker hostname, case-insensitive), decideRoute (token missing/wrong,',
  '    bad host, host-before-token, throttle-before-token, page/surfaces/screen/input/notFound/method tables),',
  '    surfacesJSONData shaping, and a couple of htmlPage assertions.',
].join('\n')

const CONTEXT = [
  'UNDER REVIEW: a fork-only, GUI-embedded HTTP "web monitor" for Ghostty (macOS). One NWListener inside the app',
  'serves an embedded mobile HTML/JS page AND a JSON API on one port; from a phone over Tailscale you list live',
  'terminal surfaces, watch one (700ms polling, plain text), and send input to approve CLI-agent prompts.',
  'Token-gated, OFF by default, no TLS (tailnet/WireGuard encrypts), Host-header allowlist + per-peer auth backoff.',
  '',
  'This is a FINAL re-review AFTER TWO fix passes. The first removed the broken IP-allowlist filter (token+tailnet',
  'only), fixed an unauth negative-Content-Length crash, fixed a stop()/handler termination deadlock (stop() now',
  'queue.async), moved the token to the X-Ghostty-Token header (sessionStorage) after first load, added a',
  'Host-header allowlist + decaying per-peer auth backoff + slowloris idle timeout, made error banners sticky,',
  'added numeric 1/2/3/4 quick-keys + arrows/Tab, and added a Swift unit-test suite.',
  'The SECOND (A+ hardening) pass then added: (H1) an ABSOLUTE per-connection deadline (~15s, armed once, not',
  'rearmed) PLUS a max-concurrent-connection cap (32) in handle() — closing the slowloris/no-deadline + no-cap DoS',
  'gap; (H2) the query ?token= is now accepted ONLY on GET / (bootstrap) while every /api/* route REQUIRES the',
  'X-Ghostty-Token header (a real server boundary, not client convention); (H3) a startup token-strength gate',
  '(tokenAcceptable: >=16 chars, refuse+warn otherwise); (H4) per-peer backoff no longer throttles on an unresolved',
  'peer key / a peer that cleared auth in-window; (H5) reportSend 404 now runs the same sessionClosedTeardown() as',
  'the poll 404 path; (H6) UX polish (Ctrl-C separated, longer "Sent." toast, no-active-session feedback); plus new',
  'tests for the query-token boundary, tokenAcceptable, and previously-untested route branches.',
  'Verify ALL of these hold and hunt for anything still blocking RELIANCE or keeping a lens below A+ (>=98).',
  '',
  VERIFIED,
  '',
  'HARD RULES TO AVOID STALLING: Do NOT run zig/xcodebuild/build.nu or any long command. Read ONLY your lens\'s',
  'targeted sections (named below) — do not read the entire repo. Keep your output TERSE: at most ~8 findings,',
  'short detail/recommendation each, summary <= 150 words. Do NOT edit files. Ignore src/host/**, src/termio/**,',
  '.claude/**, the ghostty-phase2b worktree (unrelated pty-host project).',
  '',
  'FILES: server = ' + SERVER + ' ; tests = ' + TESTS + ' . Grade 0-100; A+ = >=98 with no blocker/major.',
].join('\n')

const REVIEW_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    dimension: { type: 'string' },
    score: { type: 'number' },
    grade: { type: 'string' },
    meets_a_plus: { type: 'boolean' },
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          severity: { type: 'string', enum: ['blocker', 'major', 'minor', 'nit'] },
          title: { type: 'string' },
          location: { type: 'string' },
          detail: { type: 'string' },
          recommendation: { type: 'string' },
        },
        required: ['severity', 'title', 'recommendation'],
      },
    },
    summary: { type: 'string' },
  },
  required: ['dimension', 'score', 'grade', 'meets_a_plus', 'findings', 'summary'],
}

const SYNTH_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    overall_grade: { type: 'string' },
    overall_score: { type: 'number' },
    production_ready: { type: 'boolean' },
    per_dimension: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: { dimension: { type: 'string' }, score: { type: 'number' }, grade: { type: 'string' }, meets_a_plus: { type: 'boolean' } },
        required: ['dimension', 'score', 'grade', 'meets_a_plus'],
      },
    },
    must_fix: { type: 'array', items: { type: 'object', additionalProperties: false, properties: { severity: { type: 'string' }, title: { type: 'string' }, recommendation: { type: 'string' } }, required: ['severity', 'title', 'recommendation'] } },
    should_fix: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
  },
  required: ['overall_grade', 'overall_score', 'production_ready', 'per_dimension', 'must_fix', 'summary'],
}

phase('Re-review')
const codeP = 'You are a SENIOR CODE REVIEWER. dimension="code". Read ONLY these parts of the server file: the class properties + start()/stop()/lifecycle, the connection handling + RequestParser.parse, routeRequest/decideRoute, decodeInput, tokensMatch, send(), and the main.sync hops. Verify: no remaining deadlock (stop() async vs handler main.sync), negative/oversized Content-Length rejected before slicing, no NWConnection/timer leaks, slowloris idle timeout sound, token gate on every route, no surface pointer crossing the background->main hop. Report conc/specific findings only. ' + CONTEXT
const designP = 'You are a SOFTWARE ARCHITECT. dimension="design". Read ONLY: the security-model header comment, start()/parseListen, hostHeaderAllowed, the failedAuth backoff fields/functions, and the token handling in routeRequest + the htmlPage token/sessionStorage JS. Judge the post-fix security model for a tailnet reliance tool (token + Host-header + backoff, no TLS, no IP filter, token-in-header-after-first-load). Flag anything still blocking reliance. ' + CONTEXT
const uxP = 'You are a UX/front-end REVIEWER. dimension="ux". Read ONLY the embedded htmlPage HTML/JS string in the server file. Confirm the prior majors are fixed: error/"session closed"/send-fail banners are now STICKY (not wiped by the next poll), and numeric 1/2/3/4 quick-keys exist (plus arrows/Tab). Check the minors (loading-flash on refresh, scroll-on-explicit-change + jump-to-bottom, aria-live, pause-poll-when-hidden, in-page token recovery) and that textContent is used for all untrusted data. Flag anything still blocking a phone approval workflow. ' + CONTEXT
const testP = 'You are a TEST-COVERAGE REVIEWER. dimension="test-coverage". DO NOT run anything — the suite is already GREEN (see verified state). Read ONLY the test file ' + TESTS + ' and grade whether the now-passing ~50 tests adequately cover the security/correctness-critical units (tokensMatch, decodeInput, parseListen, RequestParser, hostHeaderAllowed, decideRoute, surfacesJSONData). Note any meaningful UNTESTED branch worth adding, but credit that the critical surface is now covered and passing. ' + CONTEXT

const reviews = (await parallel([
  function () { return agent(codeP, { schema: REVIEW_SCHEMA, phase: 'Re-review', label: 'code' }) },
  function () { return agent(designP, { schema: REVIEW_SCHEMA, phase: 'Re-review', label: 'design' }) },
  function () { return agent(uxP, { schema: REVIEW_SCHEMA, phase: 'Re-review', label: 'ux' }) },
  function () { return agent(testP, { schema: REVIEW_SCHEMA, phase: 'Re-review', label: 'test-coverage' }) },
])).filter(Boolean)
reviews.forEach(function (r) { log(r.dimension + ': ' + r.score + ' (' + r.grade + ') ' + (r.meets_a_plus ? 'A+' : '') + ' findings=' + r.findings.length) })

phase('Synthesis')
const synth = await agent(
  'Consolidate these four lens re-reviews of the Ghostty web monitor into one verdict. Dedupe; keep highest severity. must_fix = blocker/major only. production_ready=true only if zero blocker/major. Honest overall grade/score. Terse.\n\nReviews JSON:\n' + JSON.stringify(reviews, null, 2),
  { schema: SYNTH_SCHEMA, phase: 'Synthesis', label: 'synthesis' })

return { synthesis: synth, reviews: reviews }

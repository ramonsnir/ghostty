export const meta = {
  name: 'web-monitor-fix',
  description: 'Fix ALL review findings on the web monitor (remove IP filter, fix the 2 blockers + deadlock + all majors + full should-fix polish + add a Swift test suite), then re-review with 4 parallel lenses until no blocker/major remains AND overall >=98 (blocking, <=6 iters).',
  phases: [
    { title: 'Fix', detail: 'implement the full findings list (scope-locked)' },
    { title: 'Re-review', detail: '4 lenses in parallel + synthesis; gate' },
  ],
}

const GATE = 98
const MAX = 6
const REPO = '/Users/ramon/git/ghostty'

// Expanded allow-list: the feature files + a NEW Swift test file + the test target registration.
const ALLOWLIST = [
  'macos/Sources/Features/WebMonitor/WebMonitorServer.swift  (the server + embedded page; bulk of the fixes; widen testable units to internal)',
  'macos/Tests/.../WebMonitorServerTests.swift  (NEW Swift unit tests; place + register exactly like macos/Tests/Splits/SplitTreeTests.swift in the GhosttyTests target)',
  'macos/Ghostty.xcodeproj/project.pbxproj  (register the new test file in the GhosttyTests target like SplitTreeTests; the app-target WebMonitorServer.swift entry already exists)',
  'src/config/Config.zig  (fix the web-monitor-listen doc: it is a BIND address, not an allowlist; remove any "bind to your Tailscale IP for filtering" implication; document token = shell credential + tailnet ACL is load-bearing)',
  'macos/Sources/Ghostty/Ghostty.Config.swift  (only if a getter needs to change; likely untouched)',
  'macos/Sources/App/macOS/AppDelegate.swift  (optional: surface listener bind-failure / empty-token refusal more visibly per the liveness finding)',
  'CLAUDE.md  (update the web-monitor docs to match: no IP filter, token-in-header, bind caveat, token=shell-cred, Console subsystem/category, input/keys)',
]
const ALLOWLIST_TEXT = ALLOWLIST.map(function (f) { return '  - ' + f }).join('\n')

const DECISIONS = [
  'USER DECISIONS (binding):',
  '  - IP FILTER: REMOVE IT ENTIRELY. Delete the bind-IP-as-allowlist logic — the handle() peer-IP',
  '    rejection (line ~137), allowedHost, normalizedAllowedHost, and remoteIP — and rely on the',
  '    token + the Tailscale ACL. (Its tests become moot; do not add normalizedAllowedHost tests.)',
  '  - SCOPE: EVERYTHING — both blockers, the deadlock, ALL majors, and the FULL should-fix list below,',
  '    plus a real Swift test suite.',
  '  - SKIP TLS (WireGuard/tailnet already encrypts). SSE/WebSocket push is OUT OF SCOPE — do NOT build',
  '    it; just leave a one-line doc note that live updates are poll-based and push is a future option.',
].join('\n')

const FINDINGS = [
  'BLOCKERS (must fix):',
  'B1. Negative/unbounded Content-Length crashes the whole app pre-auth (WebMonitorServer.swift:223-234).',
  '    Int("-1") is accepted; the bodyHave<contentLength guard is false for negative CL, then',
  '    buffer.subdata(in: bodyStart..<(bodyStart+CL)) traps on an inverted Range. FIX: parse CL with',
  '    guard let cl = Int(headers["content-length"] ?? "0"), cl >= 0, cl <= maxRequestBytes else { 400 }',
  '    BEFORE any slicing. Never feed an attacker-controlled int into a Range/subdata.',
  'B2. (resolved by the IP-filter removal decision above.)',
  '',
  'MAJORS (must fix):',
  'M1. stop()/handler deadlock (lines 102-114 vs 281/298/319): stop() runs on main with queue.sync while',
  '    handlers run on queue with DispatchQueue.main.sync -> lock-order inversion can hang termination.',
  '    FIX: make stop() teardown non-blocking (queue.async; NWListener/NWConnection.cancel() are',
  '    thread-safe) OR switch the in-handler main hops to async (send the response inside the closure)',
  '    so no handler blocks the queue on main. Ensure no remaining cross-directional blocking.',
  'M2. Defense-in-depth: token is the sole boundary while it can inject input into a live shell.',
  '    FIX (no TLS): (a) Host-header allowlist (reject Host values that are not the configured',
  '    host:port / loopback) to blunt DNS-rebinding; (b) a simple failed-token backoff/counter per peer',
  '    so brute force is not free; (c) document token = shell-exec credential + tailnet ACL load-bearing.',
  'M3. Token-in-URL leakage (JS puts ?token= on every request; server accepts X-Ghostty-Token).',
  '    FIX: on first authenticated GET /, stash the token in sessionStorage and send it via the',
  '    X-Ghostty-Token header on all subsequent fetches; keep ?token= only for initial page load.',
  '    Document that the token still appears in the initial URL/history and must be rotated if lost.',
  'M4. Silent connection loss (poll catch at 556, sendInput catch at 585): a dropped link / 401 / 404',
  '    leaves a frozen screen that looks live — dangerous when approving a prompt. FIX: show a visible',
  '    "connection lost / reconnecting" banner (and/or dim) on fetch error or non-ok status; clear on',
  '    next good poll; on 404 from /screen show "session closed" + offer return-to-list; reflect',
  '    sendInput success/failure so the user knows the keystroke landed.',
  'M5. Input flow (502, 587-591): no Enter-to-send, no autofocus, Send omits the newline. FIX: keydown',
  '    on #inp so Enter sends with a trailing \\n (offer a separate raw/no-newline send), enterkeyhint',
  '    ="send", autofocus #inp on open(); make the behavior obvious.',
  'M6. pre-wrap mangles boxed prompts (478). FIX: default #screen to white-space: pre with horizontal',
  '    scroll (overflow-x already auto) to preserve columns; make wrap an opt-in toggle; consider a',
  '    font-size control.',
  'M7. No-token notice clobbered (517-520, 548, 599): loadList() runs even with no token -> 401 ->',
  '    catch overwrites the helpful notice. FIX: if (!token) return after showing the notice; guard all',
  '    fetches on a non-empty token; distinguish 401 from network errors so the message stays actionable.',
  '',
  'SHOULD-FIX (full scope -> implement all):',
  'S1. Chunked Transfer-Encoding silently parsed as empty body. Detect transfer-encoding and respond',
  '    411/400, or hard-require Content-Length.',
  'S2. Empty-body POST /input returns {"ok":true} no-op. Return 400 (or {"ok":false,"sent":0}) on empty',
  '    decoded bytes and disable Send client-side when the field is empty.',
  'S3. Liveness/error surfacing: bind failure / port-in-use / empty-token refusal only hit the log.',
  '    Surface listener .failed and the refusal via a one-time notification (and/or menu state), and',
  '    document the Console.app subsystem/category in CLAUDE.md.',
  'S4. Connection:close = a fresh TCP+token-check per 700ms poll. Keep close for simplicity but ADD a',
  '    one-line doc note it is deliberate (keep-alive/SSE are future). (Do not implement keep-alive.)',
  'S5. Polling-only -> approvals can lag ~1.2s + RTT and there is no push. Document as a known v1',
  '    tradeoff (push is future/out-of-scope).',
  'S6. Session list has no empty/loading state. Add "Loading…" before the fetch and a "No active',
  '    sessions" row when empty.',
  'S7. Screen scroll jumps on each poll. Before replacing textContent, capture near-bottom state; after,',
  '    auto-scroll to bottom only if already there, else preserve scrollTop; consider pausing polling',
  '    while scrolled up in scrollback mode.',
  'S8. Quick-keys lack arrows/Tab needed by agent menus. Add Up/Down (and Left/Right, Tab) quick-keys',
  '    with new decodeInput cases (up=1b 5b 41, down=1b 5b 42, right=1b 5b 43, left=1b 5b 44, tab=09).',
  'S9. Surfaces list is a stale snapshot. Refresh it periodically and/or whenever a /screen poll 404s;',
  '    consider a last-seen indicator.',
  'S10. No refresh-on-foreground. Add a visibilitychange handler to immediately re-poll (and re-list)',
  '    when the page becomes visible.',
  'S11. Plain text starting with "{" is mis-sniffed as JSON (decodeInput at 351; Send posts no',
  '    Content-Type). FIX: send the text field with explicit Content-Type: text/plain and key',
  '    decodeInput off Content-Type ONLY (do not sniff body.first=="{").',
  'S12. Input field missing autocomplete="off" spellcheck="false" inputmode/enterkeyhint hints. Add them.',
  'S13. surfacesJSON shaping is pure but untestable because mixed with AppKit lookup. Extract the',
  '     dict/JSON assembly into a pure helper (value tuples in) and test it; keep SurfaceView iteration thin.',
  'S14. Header re-scan is O(n^2) + 256KB cap can overshoot by one 64KB chunk. Search only the newly',
  '     appended region (3-byte overlap) once; treat the cap as a hard ceiling. (Polish.)',
  'S15. decodeInput control-key map is ad hoc; document that input is literal-text + the fixed key set.',
  'S16. JS open(id,title) shadows window.open. Rename to openSurface()/showSurface().',
  'S17. Low-contrast pwd text + unlabeled controls. Bump pwd contrast; add aria-labels to <select>/input.',
  '',
  'TESTS (the F dimension — add a real suite):',
  'T1. Widen the pure/value units to internal so @testable import Ghostty can reach them: tokensMatch,',
  '    decodeInput, HTTPResponse, and EXTRACT two pure helpers from the side-effecting code: parseListen',
  '    (host:port string -> (host,port)?, handling bracketed IPv6 like [::1]:8787 and bad/missing port)',
  '    and a connection-free request parser (accumulated Data -> {needMore|tooLarge|badRequest|complete',
  '    {method,path,query,headers,body}}). Keep NWConnection I/O thin around them.',
  'T2. NEW macos/Tests/.../WebMonitorServerTests.swift (@testable import Ghostty), registered in the',
  '    GhosttyTests target in project.pbxproj exactly like macos/Tests/Splits/SplitTreeTests.swift.',
  '    Table tests: tokensMatch (equal->true, same-len-diff-content->false, diff-len->false, empty/empty,',
  '    multibyte-UTF8 equal->true, off-by-one byte->false); decodeInput (each key->exact bytes incl new',
  '    arrows/tab, unknown->nil, content-type json + non-json body->nil, raw plaintext->bytes,',
  '    empty->[], and the brace-leading-plaintext case asserts the FIXED behavior); parseListen (ipv4',
  '    host:port, [::1]:8787, missing port->nil, non-numeric/oob port->nil); request parser (header',
  '    detection across partial reads, Content-Length reassembly, negative/oversized CL->badRequest,',
  '    non-UTF8 header->badRequest, chunked->411/badRequest, query percent-decode); and a method+path',
  '    -> status routing table.',
].join('\n')

const CONTEXT = [
  'WHAT IS UNDER REVIEW: a fork-only, GUI-embedded HTTP "web monitor" for Ghostty (macOS). A single',
  'NWListener inside the running app serves an embedded mobile HTML/JS page AND a JSON API on one port,',
  'so a phone over Tailscale can list live terminal surfaces, watch one (polling), and send input',
  '(notably approving CLI-agent prompts). Plain HTTP, plain text, token-gated, OFF by default.',
  '',
  'Read the current code: open macos/Sources/Features/WebMonitor/WebMonitorServer.swift IN FULL, plus',
  'the new test file and "git -C ' + REPO + ' diff". Ground claims in the real codebase as needed',
  '(SurfaceView_AppKit.swift cached readers ~245-300; AppDelegate findSurface ~945; SplitTree Sequence;',
  'how macos/Tests/Splits/SplitTreeTests.swift is registered in project.pbxproj).',
  '',
  'SCOPE LOCK: the ONLY files that may be created/modified are the allow-list below. NEVER edit/read',
  'src/host/**, src/termio/**, src/Surface.zig, .claude/docs/**, or the ghostty-phase2b worktree — they',
  'are a SEPARATE pty-host project, irrelevant here; if you find yourself there, stop.',
  'ALLOW-LIST:',
  ALLOWLIST_TEXT,
  '',
  'FORK RULES: branch ramon-fork; never git commit, never git push (origin is UPSTREAM); zero new SPM',
  'deps (Foundation/Network/AppKit only); .exec/core terminal behavior untouched; fork-only keys default',
  'off and live in ~/.config/ghostty-ramon/config.',
  '',
  'BUILD (watchdog-safe): caches are warm. Run only the FAST checks: zig build test -Demit-macos-app',
  '=false -Demit-xcframework=false -Dtest-filter=web-monitor (Zig config parse test) and the incremental',
  'zig build -Demit-macos-app=false -Doptimize=Debug. If anything would exceed ~2 min, start it with the',
  'Bash run_in_background=true option and poll — never block on one multi-minute call. The macOS Swift',
  'test target + app build are run by the human AFTERWARD, so write the Swift tests but DO NOT run',
  'xcodebuild/build.nu here, and reviewers must NOT penalize for the macOS Swift tests not being executed',
  'in this run (grade the tests by READING them for correctness + coverage).',
].join('\n')

const REVIEW_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    dimension: { type: 'string' },
    scope_ok: { type: 'boolean', description: 'git diff --name-only (plus the new test file) all within the allow-list' },
    out_of_scope_files: { type: 'array', items: { type: 'string' } },
    score: { type: 'number' },
    grade: { type: 'string' },
    meets_a_plus: { type: 'boolean', description: 'score>=98 and no blocker/major findings in this dimension' },
    prior_findings_status: { type: 'string', description: 'confirm each prior blocker/major for this lens is resolved (or not)' },
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
        required: ['severity', 'title', 'detail', 'recommendation'],
      },
    },
    summary: { type: 'string' },
    tests_run: { type: 'string', description: 'test lens only: command + verbatim result' },
    tests_passed: { type: 'boolean' },
  },
  required: ['dimension', 'scope_ok', 'score', 'grade', 'meets_a_plus', 'findings', 'summary'],
}

const IMPL_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    summary: { type: 'string' },
    files_changed: { type: 'array', items: { type: 'string' } },
    scope_self_check: { type: 'string' },
    findings_addressed: { type: 'string', description: 'map each B*/M*/S*/T* to what you did' },
    zig_test_result: { type: 'string' },
    zig_build_result: { type: 'string' },
    notes: { type: 'string' },
  },
  required: ['summary', 'files_changed', 'scope_self_check', 'zig_test_result', 'zig_build_result'],
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
    must_fix: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          severity: { type: 'string', enum: ['blocker', 'major'] },
          title: { type: 'string' },
          location: { type: 'string' },
          recommendation: { type: 'string' },
          dimensions: { type: 'array', items: { type: 'string' } },
        },
        required: ['severity', 'title', 'recommendation'],
      },
    },
    should_fix: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
  },
  required: ['overall_grade', 'overall_score', 'production_ready', 'per_dimension', 'must_fix', 'summary'],
}

function reviewFeedback(synth) {
  if (!synth) return 'This is the first fix pass; implement the full FINDINGS list below.'
  const mf = (synth.must_fix || []).map(function (m, i) {
    return (i + 1) + '. [' + m.severity + '] ' + (m.title || '') + ' @ ' + (m.location || '') + ' -> ' + m.recommendation
  }).join('\n')
  const sf = (synth.should_fix || []).map(function (s, i) { return (i + 1) + '. ' + s }).join('\n')
  return 'PRIOR RE-REVIEW: overall ' + synth.overall_score + ' (' + synth.overall_grade + '), production_ready=' + synth.production_ready +
    '.\nREMAINING MUST-FIX (blocker/major):\n' + (mf || '(none)') + '\nREMAINING SHOULD-FIX:\n' + (sf || '(none)') +
    '\nResolve ALL remaining must-fix and as many should-fix as possible.'
}

// lens prompt builders (re-review): each verifies its prior findings are resolved
function codePrompt() {
  return 'You are a SENIOR CODE REVIEWER. dimension="code". Re-grade WebMonitorServer.swift + the new test file for CORRECTNESS/SAFETY after the fixes. CONFIRM each prior code finding is resolved: B1 negative/oversized Content-Length now rejected with 400 BEFORE slicing (no Range trap); M1 the stop()/handler deadlock is gone (no cross-directional sync block); chunked-TE handled (S1); empty-body POST (S2); header-scan/cap polish (S14). Then hunt for any NEW correctness/threading/leak/HTTP-parse bugs (incl. in the extracted parseListen / request-parser and the IP-filter removal). FIRST: run "git -C ' + REPO + ' diff --name-only" (account for the new untracked test file) — scope_ok=false if anything is outside the allow-list. Grade 0-100; meets_a_plus iff >=98 and no blocker/major. Do NOT edit files.\n\n' + CONTEXT
}
function designPrompt() {
  return 'You are a SOFTWARE ARCHITECT. dimension="design". Re-grade the DESIGN after the fixes. CONFIRM resolved: the IP filter is REMOVED and the docs no longer imply bind-IP filtering (the prior unusable-as-documented blocker); M2 defense-in-depth added (Host-header allowlist + failed-token backoff + token=shell-cred docs); M3 token moved to the X-Ghostty-Token header after initial load. Check the security model is now coherent for a tailnet tool (TLS intentionally skipped, push intentionally future). FIRST do the scope check. Grade 0-100; meets_a_plus iff >=98 and no blocker/major. Do NOT edit files.\n\n' + CONTEXT
}
function uxPrompt() {
  return 'You are a UX/front-end REVIEWER (website side). dimension="ux". Re-grade the embedded HTML/JS for a phone approving agent prompts. CONFIRM resolved: M4 connection-loss now visibly surfaced (banner/dim, 404 handling, sendInput feedback); M5 Enter-to-send + autofocus + newline; M6 white-space:pre default + wrap toggle; M7 no-token notice no longer clobbered; plus should-fix S6 empty/loading state, S7 scroll-follow, S8 arrow/Tab keys, S10 visibilitychange, S11 text/plain Content-Type, S12 input hints, S16 open() rename, S17 contrast/aria. Verify textContent is still used for all untrusted data (no innerHTML). FIRST do the scope check. Grade 0-100; meets_a_plus iff >=98 and no blocker/major. Do NOT edit files.\n\n' + CONTEXT
}
function testPrompt() {
  return 'You are a TEST-COVERAGE REVIEWER. dimension="test-coverage". FIRST run exactly "zig build test -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=web-monitor" in ' + REPO + ' (warm cache; run_in_background+poll only if >~2 min) and record tests_run + tests_passed. THEN grade the NEW Swift test suite by READING macos/Tests/.../WebMonitorServerTests.swift (the macOS Swift tests are executed later by the human — do not run xcodebuild; judge them by reading): does it actually cover the security/correctness-critical units — tokensMatch (equal/diff-content/diff-len/empty/multibyte/off-by-one), decodeInput (every key incl new arrows/tab, unknown->nil, json/non-json, raw, empty, brace-leading), parseListen (ipv4, [::1]:port, missing/oob port), the request parser (partial reads, Content-Length reassembly, negative/oversized CL, non-UTF8, chunked, percent-decode), routing table, and the extracted surfacesJSON shaper? Are those units now internal + reachable via @testable import Ghostty, and is the file registered in the GhosttyTests target in project.pbxproj like SplitTreeTests? FIRST do the scope check. Grade coverage honestly 0-100; meets_a_plus iff >=98 and no blocker/major (a critical unit left untested is a major). Do NOT edit files.\n\n' + CONTEXT
}

// ---------------- LOOP: Fix -> Re-review ----------------
let synth = null
let fixReport = null
for (let i = 0; i < MAX; i++) {
  phase('Fix')
  fixReport = await agent(
    'You are the IMPLEMENTER. Working dir ' + REPO + ' (branch ramon-fork). Apply the fixes with Edit/Write, touching ONLY the allow-list files. Implement EVERY remaining item. After editing: run "git -C ' + REPO + ' diff --name-only", git checkout -- any off-list file, and paste the final list into scope_self_check (note the new untracked test file separately). Run the fast Zig test (zig build test -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=web-monitor) and the incremental build (zig build -Demit-macos-app=false -Doptimize=Debug); report both verbatim. Do NOT run xcodebuild/build.nu (the human runs the macOS Swift tests). Do NOT commit/push.\n\n' + DECISIONS + '\n\nFINDINGS TO RESOLVE:\n' + FINDINGS + '\n\n' + reviewFeedback(synth) + '\n\n' + CONTEXT,
    { schema: IMPL_SCHEMA, phase: 'Fix', label: 'fix#' + (i + 1) })
  if (!fixReport) return { status: 'aborted', where: 'fix', iter: i + 1 }
  log('Fix#' + (i + 1) + ': ' + (fixReport.files_changed || []).length + ' files; zigtest=' + (fixReport.zig_test_result || '').slice(0, 24) + ' build=' + (fixReport.zig_build_result || '').slice(0, 24))

  phase('Re-review')
  const dims = await parallel([
    function () { return agent(codePrompt(), { schema: REVIEW_SCHEMA, phase: 'Re-review', label: 'code#' + (i + 1) }) },
    function () { return agent(designPrompt(), { schema: REVIEW_SCHEMA, phase: 'Re-review', label: 'design#' + (i + 1) }) },
    function () { return agent(uxPrompt(), { schema: REVIEW_SCHEMA, phase: 'Re-review', label: 'ux#' + (i + 1) }) },
    function () { return agent(testPrompt(), { schema: REVIEW_SCHEMA, phase: 'Re-review', label: 'tests#' + (i + 1) }) },
  ])
  const reviews = dims.filter(Boolean)
  const scopeViolation = reviews.some(function (r) { return r.scope_ok === false })
  synth = await agent(
    'You are the REVIEW SYNTHESIZER. Consolidate these four lens re-reviews of the web monitor into one verdict. Deduplicate; keep the highest severity. must_fix = blocker/major ONLY. Set production_ready=true ONLY if there are zero blocker AND zero major across all lenses. Give an honest overall grade/score.\n\nReviews JSON:\n' + JSON.stringify(reviews, null, 2),
    { schema: SYNTH_SCHEMA, phase: 'Re-review', label: 'synthesis#' + (i + 1) })
  if (!synth) return { status: 'aborted', where: 'synthesis', iter: i + 1 }
  reviews.forEach(function (r) { log(r.dimension + '#' + (i + 1) + ': ' + r.score + ' (' + r.grade + ') ' + (r.meets_a_plus ? 'A+' : '') + ' findings=' + r.findings.length) })
  log('Synthesis#' + (i + 1) + ': overall ' + synth.overall_score + ' (' + synth.overall_grade + ') ready=' + synth.production_ready + ' must_fix=' + (synth.must_fix || []).length + (scopeViolation ? ' SCOPE-VIOLATION' : ''))

  const passed = !scopeViolation && (synth.must_fix || []).length === 0 && synth.overall_score >= GATE && synth.production_ready
  if (passed) {
    return { status: 'PASSED', iterations: i + 1, synthesis: synth, lastReviews: reviews, fixReport: fixReport }
  }
}

return { status: 'FAILED', gate: 'exhausted ' + MAX + ' iters', synthesis: synth, fixReport: fixReport }

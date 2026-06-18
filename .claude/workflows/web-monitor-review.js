export const meta = {
  name: 'web-monitor-review',
  description: 'Parallel multi-lens review of the GUI-embedded web monitor (code / design / UX / test-coverage), each graded for A+/>=98, then synthesized. Read-only; the test lens actually runs the tests.',
  phases: [
    { title: 'Review', detail: '4 lenses in parallel: code, design, UX, test-coverage(+run)' },
    { title: 'Synthesis', detail: 'consolidate into a deduped, severity-ranked verdict' },
  ],
}

const REPO = '/Users/ramon/git/ghostty'

const FEATURE_FILES = [
  'macos/Sources/Features/WebMonitor/WebMonitorServer.swift  (NEW — the server + embedded HTML/JS page; the heart of the feature)',
  'src/config/Config.zig  (two fork-only keys web-monitor-listen / web-monitor-token + a parse test)',
  'macos/Sources/Ghostty/Ghostty.Config.swift  (webMonitorListen / webMonitorToken getters)',
  'macos/Sources/App/macOS/AppDelegate.swift  (start on launch / stop on terminate)',
  'macos/Ghostty.xcodeproj/project.pbxproj  (one iOS-target exclusion line)',
  'CLAUDE.md  (docs)',
]

const CONTEXT = [
  'WHAT IS UNDER REVIEW: a fork-only, GUI-embedded HTTP "web monitor" for Ghostty (macOS).',
  'A single NWListener INSIDE the running macOS app serves BOTH an embedded mobile HTML/JS page',
  'AND a small JSON API on one port. Intended use: from a phone over Tailscale, list the live',
  'terminal surfaces, watch one update (polling), and send input -- notably approving CLI-agent',
  '(e.g. Claude Code) prompts. Transport is plain HTTP polling (no WebSocket). Render is plain',
  'text (no ANSI color). It is OFF by default and refuses to start without a token.',
  '',
  'THE CHANGE (read it ALL): run "git -C ' + REPO + ' diff" and "git -C ' + REPO + ' status",',
  'and open macos/Sources/Features/WebMonitor/WebMonitorServer.swift IN FULL (it is untracked,',
  'so it will not appear in git diff -- read the file directly). Changed/new files:',
  FEATURE_FILES.map(function (f) { return '  - ' + f }).join('\n'),
  '',
  'GROUND YOUR CLAIMS in the real codebase where useful (read only what you need):',
  '  - macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift ~245-300: cachedScreenContents',
  '    / cachedVisibleContents (CachedValue<String>, ~500ms TTL, free their own text).',
  '  - macos/Sources/App/macOS/AppDelegate.swift ~945: findSurface(forUUID:) (the server replicates it).',
  '  - macos/Sources/Features/Terminal/TerminalController.swift: static var all.',
  '  - macos/Sources/Features/Splits/SplitTree.swift: Sequence conformance (yields SurfaceView leaves).',
  '  - include/ghostty.h: ghostty_surface_text / ghostty_surface_read_text signatures.',
  '',
  'RULES: This is a READ-ONLY review. Do NOT edit any files. Do NOT wander into unrelated code',
  '(src/host/**, src/termio/**, .claude/docs/**, the ghostty-phase2b worktree -- they are a',
  'SEPARATE pty-host project, irrelevant here). Build/lib state: the zig lib + macOS ReleaseLocal',
  'app already build cleanly (verified), so do not re-run those heavy builds.',
  '',
  'GRADING: score 0-100. A+ = >=98 AND no blocker/major findings. Be a demanding but fair',
  'reviewer for a tool the user will RELY ON. Prefer concrete, located, actionable findings over',
  'vague concerns. Severity: blocker (unsafe/broken/will fail in normal use), major (real bug or',
  'gap that matters for reliance), minor (quality), nit (cosmetic).',
].join('\n')

const REVIEW_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    dimension: { type: 'string' },
    score: { type: 'number' },
    grade: { type: 'string' },
    meets_a_plus: { type: 'boolean', description: 'true iff score>=98 and no blocker/major findings' },
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
    strengths: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
    tests_run: { type: 'string', description: 'test lens only: exact command(s) run + verbatim outcome' },
    tests_passed: { type: 'boolean', description: 'test lens only' },
  },
  required: ['dimension', 'score', 'grade', 'meets_a_plus', 'findings', 'summary'],
}

const SYNTH_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    overall_grade: { type: 'string' },
    overall_score: { type: 'number' },
    production_ready: { type: 'boolean', description: 'is it solid enough to rely on, as-is?' },
    per_dimension: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          dimension: { type: 'string' },
          score: { type: 'number' },
          grade: { type: 'string' },
          meets_a_plus: { type: 'boolean' },
        },
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

// ---------------- REVIEW PHASE (4 lenses in parallel) ----------------
phase('Review')

const codePrompt =
  'You are a SENIOR CODE REVIEWER. Dimension = "code". Review macos/Sources/Features/WebMonitor/WebMonitorServer.swift and the changed files for CORRECTNESS and SAFETY. Hunt for: threading/races (the dedicated serial queue vs DispatchQueue.main.sync hops; any path that could already be on main; surface freed/closed mid-request; the connections/connectionRefs bookkeeping); memory/resource leaks (NWConnection cleanup on every exit path, cachedReaders freeing their own text); hand-rolled HTTP/1.1 bugs (Content-Length parse, partial reads across TCP segments, chunked/Transfer-Encoding not handled, header case-folding, the 256KB cap path, Data index/subdata arithmetic, requests with no body, pipelined/extra bytes); routing + status codes (401/404/405/413/400, unknown UUID, empty body); the token check (constant-time, length-checked, gates EVERY route incl GET /); input decoding (decodeInput key map, raw bytes, empty Send -> nil baseAddress with len 0, JSON detection); ghostty_surface_text byte-length correctness; Swift API misuse. Verify symbols against the real codebase. Grade per the CONTEXT rules.\n\n' + CONTEXT

const designPrompt =
  'You are a SOFTWARE ARCHITECT. Dimension = "design". Review the DESIGN of the web monitor for someone who will RELY ON it. Assess: the GUI-embedded single-listener architecture (one binary serves page+API) vs alternatives; the security model (token as the boundary + bind-on-all-interfaces + best-effort IP filter -- is this sound over Tailscale? failure modes if exposed beyond the tailnet?); config design + lifecycle (read-at-launch, relaunch-to-change, refuse-without-token, start/stop placement in AppDelegate); the polling transport choice (700ms vs ~500ms cache TTL; latency/load tradeoff; no push) for the stated use (monitoring agents + approving prompts); API shape (REST, surface identity by UUID, viewport vs scrollback); robustness/failure modes (listener fails to bind, port in use, no surfaces, multiple windows, surface closes mid-request); extensibility; fork-convention + invariant adherence (zero new deps, .exec untouched, fork-only-off-by-default). Call out anything that would bite reliance. Grade per the CONTEXT rules.\n\n' + CONTEXT

const uxPrompt =
  'You are a UX/front-end REVIEWER focused on the WEBSITE side. Dimension = "ux". Review the embedded HTML/JS page (the htmlPage string in WebMonitorServer.swift) for the real use case: a phone, over Tailscale, monitoring CLI agents and approving prompts. Assess: mobile layout/readability (the <pre> screen, font, dark theme, viewport meta); the session list (titles, pwd, tap target, empty/loading state); the live viewer (700ms poll, scroll position jumping on refresh, viewport vs scrollback toggle); INPUT affordances (text field behaviors: autocapitalize/autocorrect/autocomplete, return-to-send, focus, clearing; the Enter/y/n/Esc/Ctrl-C quick buttons -- are these the right ones for approving agent prompts? anything missing like arrow keys / Tab / a "clear" / a send-without-newline?); error + no-token + connection-lost states; refresh-on-foreground; accessibility; any HTML/JS correctness bugs (textContent safety is required -- verify no innerHTML with untrusted data; the open() name shadowing; fetch error handling; scroll auto-follow). Recommend concrete improvements. Grade per the CONTEXT rules.\n\n' + CONTEXT

const testPrompt =
  'You are a TEST-COVERAGE REVIEWER. Dimension = "test-coverage". FIRST actually RUN the tests: run exactly "zig build test -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=web-monitor" in ' + REPO + ' (the test cache is WARM, so this is fast; if it would somehow exceed ~2 min, start it with the Bash run_in_background=true option and poll the log -- never block on a single multi-minute call). Record the exact command and verbatim result in tests_run and set tests_passed. THEN assess coverage: what is actually tested (currently essentially just the Zig config parse/default test) vs the substantial UNTESTED logic in WebMonitorServer.swift -- HTTP request parsing (Content-Length, partial reads, 413, malformed), routing + status codes, the constant-time token compare (length + content), decodeInput (key map, raw bytes, unknown key, empty), surfacesJSON, surface(forUUID:), the address parser (normalizedAllowedHost / port split). Determine whether the macOS project has a unit-test target these COULD live in (look for GhosttyTests, e.g. macos/Tests/), and which pieces are pure/value-level and thus easily unit-testable without a running app. Recommend a concrete, prioritized list of tests to add. Grade coverage honestly per the CONTEXT rules (do not inflate -- thin coverage should score low even though the code builds).\n\n' + CONTEXT

const dims = await parallel([
  function () { return agent(codePrompt, { schema: REVIEW_SCHEMA, phase: 'Review', label: 'code' }) },
  function () { return agent(designPrompt, { schema: REVIEW_SCHEMA, phase: 'Review', label: 'design' }) },
  function () { return agent(uxPrompt, { schema: REVIEW_SCHEMA, phase: 'Review', label: 'ux' }) },
  function () { return agent(testPrompt, { schema: REVIEW_SCHEMA, phase: 'Review', label: 'test-coverage' }) },
])
const reviews = dims.filter(Boolean)
reviews.forEach(function (r) { log(r.dimension + ': ' + r.score + ' (' + r.grade + ') ' + (r.meets_a_plus ? 'A+' : 'below A+') + ', ' + r.findings.length + ' findings') })

// ---------------- SYNTHESIS ----------------
phase('Synthesis')
const synth = await agent(
  'You are the REVIEW SYNTHESIZER. You are given four independent lens reviews (code, design, UX, test-coverage) of the Ghostty web monitor. Consolidate them into one verdict for a user deciding whether to RELY ON this tool. Deduplicate overlapping findings; keep the highest severity assigned. Produce: per_dimension grades; a single severity-ranked must_fix list (blocker/major ONLY, deduped, each with location + concrete recommendation + which lenses raised it); a should_fix list (minor improvements worth doing); an honest overall grade/score and a production_ready boolean (true only if no blocker/major remain). Be concise and concrete.\n\nThe four reviews (JSON):\n' + JSON.stringify(reviews, null, 2),
  { schema: SYNTH_SCHEMA, phase: 'Synthesis', label: 'synthesis' })

return { synthesis: synth, reviews: reviews }

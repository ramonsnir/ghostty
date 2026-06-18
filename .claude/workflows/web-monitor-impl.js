export const meta = {
  name: 'web-monitor-impl',
  description: 'Implement the GUI-embedded HTTP web-monitor for Ghostty splits (plan<->review, impl<->review, critic; each gate A+/>=98, blocking, <=6 iters; hardened: scope-locked + no cold builds)',
  phases: [
    { title: 'Plan', detail: 'plan <-> adversarial review until >=98' },
    { title: 'Implement', detail: 'implement <-> review until >=98' },
    { title: 'Critique', detail: 'final critic <-> fix until >=98' },
  ],
}

const GATE = 98
const MAX = 6
const REPO = '/Users/ramon/git/ghostty'

// The ONLY files this feature may create or modify. Anything else is OUT OF SCOPE.
const ALLOWLIST = [
  'src/config/Config.zig',
  'macos/Sources/Ghostty/Ghostty.Config.swift',
  'macos/Sources/Features/WebMonitor/WebMonitorServer.swift',
  'macos/Ghostty.xcodeproj/project.pbxproj',
  'macos/Sources/App/macOS/AppDelegate.swift',
  'CLAUDE.md',
]

const SPEC = [
  'FEATURE (macOS Swift, plus ONE tiny Zig config addition): a GUI-embedded HTTP "web',
  'monitor" for the ramon fork of Ghostty. From a phone over Tailscale, the user lists the',
  'live terminal splits/surfaces, watches a chosen surface update, and sends input (notably',
  'approving CLI-agent prompts). This is "Option C: GUI-embedded server" -- the server lives',
  'INSIDE the running macOS app.',
  '',
  'HARD ARCHITECTURE REQUIREMENT (non-negotiable): a SINGLE listener inside the macOS app',
  'serves BOTH the static HTML/JS page AND the JSON API on one port. One app binary, one',
  'rebuild/restart. No second process.',
  '',
  '================= SCOPE LOCK (read this twice) =================',
  'This is a self-contained macOS feature. The ONLY files you may create/modify are:',
  ALLOWLIST.map(function (f) { return '  - ' + f }).join('\n'),
  '',
  'NEVER read or edit ANY of these -- they are UNRELATED to this task and WILL MISLEAD YOU:',
  '  - src/host/** , src/termio/** , src/Surface.zig , src/apprt/** , src/renderer/**',
  '  - .claude/** (especially .claude/docs/*) and the /Users/ramon/git/ghostty-phase2b worktree',
  '  - anything mentioning "pty-host", or the files Client.zig / Server.zig / Session.zig /',
  '    protocol.zig. There is a separate pty-host project; it is NOT this task. If you find',
  '    yourself reading host/termio/pty-host code or .claude/docs, STOP immediately -- you have',
  '    wandered off-task.',
  'Before you finish an implementation turn, run: git -C ' + REPO + ' diff --name-only',
  'and git -C ' + REPO + ' checkout -- <file> to REVERT any change outside the allow-list.',
  '===============================================================',
  '',
  'FORK CONVENTIONS (inlined -- do NOT go read CLAUDE.md):',
  '  - Branch ramon-fork. Never git commit, never git push (origin is UPSTREAM). The human commits.',
  '  - Fork-only config keys live in src/config/Config.zig and must default to empty/off so an',
  '    official Ghostty would not error; they are set by the user in ~/.config/ghostty-ramon/config.',
  '    Follow the EXISTING pattern of the keys "project-directory" and "bell-features-focused"',
  '    (find them in src/config/Config.zig: a field with a doc comment and a sensible default).',
  '',
  'EXISTING PRIMITIVES TO REUSE (do NOT reinvent). Read ONLY these specific spots:',
  '  - include/ghostty.h ~lines 405-490 (ghostty_text_s / ghostty_selection_s / point structs)',
  '    and ~lines 1159-1216 (ghostty_surface_text, ghostty_surface_read_text, free_text).',
  '  - macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift ~lines 245-300:',
  '    cachedScreenContents (SCREEN = full scrollback) and cachedVisibleContents (VIEWPORT),',
  '    both backed by ghostty_surface_read_text (they handle selection/text/free_text). REUSE these.',
  '  - macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift ~lines 2220-2235: how',
  '    ghostty_surface_text(surface, ptr, len) sends bytes to the pty. Control bytes ride the',
  '    same path: Ctrl-C=0x03, Esc=0x1b, Enter=carriage-return 0x0d.',
  '  - macos/Sources/Ghostty/Ghostty.App.swift: findSurface(forUUID:) (~line 9) for id->surface,',
  '    and the surface-enumeration pattern.',
  '  - Enumerate all surfaces: iterate NSApp.windows, windowController as? BaseTerminalController,',
  '    then surfaceTree.root?.leaves() -> [Ghostty.SurfaceView]. (Pattern used in',
  '    macos/Sources/Features/Terminal/BaseTerminalController.swift around lines 545 and 1238.)',
  '    SurfaceView is Identifiable with a stable uuid (UUID) and a @Published title.',
  '  - macos/Sources/Ghostty/Ghostty.Config.swift: the projectDirectories getter -- mirror its',
  '    style for the two new getters (webMonitorListen, webMonitorToken).',
  '  - project.pbxproj add+iOS-exclusion pattern: grep "ProjectPalette" in',
  '    macos/Ghostty.xcodeproj/project.pbxproj and REPLICATE every entry it has (PBXBuildFile,',
  '    PBXFileReference, group membership, and the iOS-target exclusion) for the new file.',
  '  - macos/Sources/App/macOS/AppDelegate.swift: find applicationDidFinishLaunching /',
  '    applicationWillTerminate (or the equivalent launch/terminate hooks) to start/stop the server.',
  '',
  'TRANSPORT: plain HTTP polling (NO WebSocket). The browser polls the screen endpoint and POSTs',
  'input. cachedScreenContents/cachedVisibleContents cache ~500ms, so use a poll interval >= ~600ms.',
  '',
  'HTTP API (all under the one listener):',
  '  GET  /                                                       -> the embedded mobile HTML page',
  '  GET  /api/surfaces                                           -> JSON [{id,title,pwd}]',
  '  GET  /api/surface/{uuid}/screen?mode=viewport|scrollback     -> plain text body',
  '  POST /api/surface/{uuid}/input  body = raw bytes, OR {"key":"enter|ctrl-c|esc|y|n"}',
  '  Unknown surface id -> 404. Unknown path -> 404. Wrong method -> 405.',
  '',
  'WEB PAGE (one embedded HTML/JS string, mobile-first): a session list (title, tap to open); a',
  '<pre> auto-refreshing the screen text; a text field + Send; and the quick-action row',
  'Enter / y / n / Esc / Ctrl-C. Plain text only (no ANSI color). SECURITY: inject screen text',
  'via textContent (NEVER innerHTML) so terminal output cannot inject HTML/JS.',
  '',
  'THREADING (correctness-critical): the NWListener runs on a background queue. EVERY handler',
  'that touches AppKit / NSApp.windows / SurfaceView / ghostty_surface_* MUST hop to the main',
  'thread (DispatchQueue.main) for that work, then send the response. Do the findSurface(forUUID:)',
  'lookup on the main thread; treat a missing surface as 404; NEVER retain a raw surface pointer',
  'across the background->main hop.',
  '',
  'CONFIG + SECURITY (fork-only, OFF by default):',
  '  - Two string keys in src/config/Config.zig (default empty), e.g. web-monitor-listen',
  '    (addr:port; empty = disabled; recommend the Tailscale IP) and web-monitor-token (secret).',
  '  - Getters in macos/Sources/Ghostty/Ghostty.Config.swift (webMonitorListen, webMonitorToken).',
  '  - Server starts ONLY if web-monitor-listen is non-empty. DEFAULT POLICY: refuse to start',
  '    (log a clear warning) if no token is set, so it is never accidentally open. Every request',
  '    must present the token (?token=... or a header); compare length-checked / constant-time.',
  '',
  'INVARIANTS: zero new SPM dependencies (Foundation + Network.framework only). Core terminal',
  'behavior unchanged -- only the two additive Zig config keys + macOS Swift. Match surrounding style.',
  '',
  'BUILD (watchdog-safe): the zig lib cache is PRE-WARMED, so the only build you run is a FAST',
  'INCREMENTAL one to validate the Config.zig change: zig build -Demit-macos-app=false',
  '-Doptimize=Debug . If it ever looks like it will take more than ~2 minutes, you MUST start it',
  'with the Bash tool run_in_background=true and poll the log with separate tail calls -- NEVER',
  'block on a single multi-minute build call (that is what killed the previous run). The zig build',
  'does NOT compile the Swift; the macOS app build is run by the human afterward, so reviewers',
  'must NOT penalize for the macOS app build not being run here.',
].join('\n')

const REVIEW_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    scope_ok: { type: 'boolean', description: 'true ONLY if git diff --name-only is a subset of the allow-list' },
    out_of_scope_files: { type: 'array', items: { type: 'string' } },
    deliverables_present: { type: 'boolean', description: 'WebMonitorServer.swift exists AND the two config keys exist' },
    score: { type: 'number', description: '0-100; A+ requires >=98' },
    grade: { type: 'string' },
    verdict: { type: 'string', enum: ['pass', 'fail'], description: 'pass ONLY if score>=98, scope_ok, deliverables_present, and no blocking issues' },
    blocking_issues: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          severity: { type: 'string' },
          location: { type: 'string' },
          problem: { type: 'string' },
          fix: { type: 'string' },
        },
        required: ['severity', 'problem', 'fix'],
      },
    },
    minor: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
  },
  required: ['scope_ok', 'deliverables_present', 'score', 'grade', 'verdict', 'blocking_issues', 'summary'],
}

const PLAN_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    plan_markdown: { type: 'string' },
    files: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: { path: { type: 'string' }, change: { type: 'string' } },
        required: ['path', 'change'],
      },
    },
    open_risks: { type: 'array', items: { type: 'string' } },
    addressed_feedback: { type: 'string' },
  },
  required: ['plan_markdown', 'files'],
}

const IMPL_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    summary: { type: 'string' },
    files_changed: { type: 'array', items: { type: 'string' } },
    scope_self_check: { type: 'string', description: 'paste of git diff --name-only proving only allow-list files changed' },
    build_result: { type: 'string', description: 'verbatim outcome of the fast incremental zig build: SUCCESS or the error' },
    addressed_feedback: { type: 'string' },
    self_review: { type: 'string' },
  },
  required: ['summary', 'files_changed', 'scope_self_check', 'build_result'],
}

const PLAN_REVIEW_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    score: { type: 'number' },
    grade: { type: 'string' },
    verdict: { type: 'string', enum: ['pass', 'fail'] },
    blocking_issues: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          severity: { type: 'string' },
          location: { type: 'string' },
          problem: { type: 'string' },
          fix: { type: 'string' },
        },
        required: ['severity', 'problem', 'fix'],
      },
    },
    minor: { type: 'array', items: { type: 'string' } },
    summary: { type: 'string' },
  },
  required: ['score', 'grade', 'verdict', 'blocking_issues', 'summary'],
}

function reviewLine(r) {
  if (!r) return 'This is the first iteration; there is no prior review.'
  const issues = (r.blocking_issues || []).map(function (b, i) {
    return (i + 1) + '. [' + b.severity + '] ' + (b.location || '') + ': ' + b.problem + ' -> FIX: ' + b.fix
  }).join('\n')
  let scopeNote = ''
  if (r.scope_ok === false) scopeNote = '\nSCOPE VIOLATION -- you edited files outside the allow-list: ' + (r.out_of_scope_files || []).join(', ') + '. git checkout -- them.'
  if (r.deliverables_present === false) scopeNote += '\nDELIVERABLES MISSING -- WebMonitorServer.swift and/or the config keys do not exist yet.'
  return 'PRIOR REVIEW score ' + r.score + ' (' + r.verdict + ').' + scopeNote + '\nBLOCKING ISSUES YOU MUST RESOLVE:\n' +
    (issues || '(none listed)') + '\nMINOR: ' + ((r.minor || []).join('; ') || '(none)') + '\nREVIEWER SUMMARY: ' + (r.summary || '')
}

const ALLOWLIST_TEXT = ALLOWLIST.join('\n')

// ---------------- PLAN PHASE ----------------
phase('Plan')
let plan = null, planReview = null
for (let i = 0; i < MAX; i++) {
  plan = await agent(
    'You are the PLANNER for a self-contained macOS Swift feature in a Ghostty fork. Produce a COMPLETE, build-ready implementation plan. Read ONLY the specific files/line-ranges named in the SPEC to ground your symbols and patterns -- do NOT explore beyond them, and obey the SCOPE LOCK absolutely. Be concrete about each allow-list file change, the HTTP parsing approach, the background-queue->main-thread bridging, the token gate, and the project.pbxproj edits (replicate the ProjectPalette entries). Do not write code yet.\n\nSPEC:\n' + SPEC + '\n\nPRIOR PLAN ("(none)" on first pass):\n' + (plan ? plan.plan_markdown : '(none)') + '\n\n' + reviewLine(planReview),
    { schema: PLAN_SCHEMA, phase: 'Plan', label: 'plan#' + (i + 1) })
  if (!plan) return { status: 'aborted', where: 'plan', reason: 'planner skipped' }
  planReview = await agent(
    'You are a SKEPTICAL ADVERSARIAL PLAN REVIEWER. Grade 0-100; A+ (>=98) = complete, correct, unambiguous, no hidden bugs, implementable with no further questions. Verify EVERY claimed symbol by reading ONLY the SPEC-named spots (findSurface(forUUID:), ghostty_surface_text, ghostty_surface_read_text, cachedScreenContents, leaves(), the ProjectPalette pbxproj entries). FIRST check: does the plan stay strictly within the allow-list below and avoid all denied paths? If it proposes touching host/termio/pty-host/.claude or anything off-list, that is an automatic FAIL. Then penalize: vague steps, wrong symbols, missed background->main threading, security holes (no token gate, innerHTML, retained pointer across threads), missing free_text, missing pbxproj target+iOS-exclusion, or violating single-listener-serves-both. verdict "pass" ONLY if score>=98 AND blocking_issues empty. Do NOT edit files.\n\nALLOW-LIST:\n' + ALLOWLIST_TEXT + '\n\nSPEC:\n' + SPEC + '\n\nPLAN:\n' + plan.plan_markdown + '\n\nPLANNED FILES:\n' + JSON.stringify(plan.files, null, 2) + '\n\nRISKS: ' + ((plan.open_risks || []).join('; ') || '(none)'),
    { schema: PLAN_REVIEW_SCHEMA, phase: 'Plan', label: 'plan-review#' + (i + 1) })
  if (!planReview) return { status: 'aborted', where: 'plan-review' }
  log('Plan iter ' + (i + 1) + ': score ' + planReview.score + ' (' + planReview.verdict + ')')
  if (planReview.score >= GATE && planReview.verdict === 'pass') break
}
if (!(planReview && planReview.score >= GATE && planReview.verdict === 'pass')) {
  return { status: 'FAILED', gate: 'plan', lastScore: planReview ? planReview.score : null, review: planReview, plan }
}
const approvedPlan = plan
log('PLAN GATE PASSED at ' + planReview.score + '. Implementing.')

// ---------------- IMPLEMENT PHASE ----------------
phase('Implement')
let impl = null, implReview = null
for (let i = 0; i < MAX; i++) {
  impl = await agent(
    'You are the IMPLEMENTER. Working dir ' + REPO + ' (branch ramon-fork). Make ACTUAL edits with Edit/Write to implement the approved plan, touching ONLY the allow-list files. OBEY THE SCOPE LOCK: never edit/read host/termio/pty-host/.claude or anything off-list; if you catch yourself there, stop and revert. First run "git -C ' + REPO + ' diff --name-only" to see prior work, then add/fix. Key requirements: ONE NWListener serves both the HTML page and the JSON API; background handlers hop to the main thread for all AppKit/surface access and never retain a surface pointer across the hop; token required to start + checked per request; screen text via textContent; reuse cachedScreenContents/cachedVisibleContents; zero new SPM deps; replicate the ProjectPalette entries in project.pbxproj (PBXBuildFile + PBXFileReference + group + iOS exclusion); two additive Zig config keys following project-directory.\n\nThen VALIDATE: run "git -C ' + REPO + ' diff --name-only" and git checkout -- any off-list file; paste the final list into scope_self_check. Run the FAST INCREMENTAL build: zig build -Demit-macos-app=false -Doptimize=Debug (cache is pre-warmed; if it would exceed ~2 min, start it with run_in_background=true and poll the log -- never block on a single multi-minute build). Report build_result verbatim. Do NOT run the macOS app build. Do NOT commit/push.\n\nALLOW-LIST (the ONLY files you may change):\n' + ALLOWLIST_TEXT + '\n\nAPPROVED PLAN:\n' + approvedPlan.plan_markdown + '\n\nSPEC:\n' + SPEC + '\n\n' + reviewLine(implReview),
    { schema: IMPL_SCHEMA, phase: 'Implement', label: 'impl#' + (i + 1) })
  if (!impl) return { status: 'aborted', where: 'impl' }
  implReview = await agent(
    'You are a SKEPTICAL CODE REVIEWER. Read the ACTUAL working tree: run "git -C ' + REPO + ' diff" and "git -C ' + REPO + ' status" and open every changed/new file in full. \nCHECK 0 (SCOPE, mandatory first): run "git -C ' + REPO + ' diff --name-only"; set scope_ok=true ONLY if every changed file is in the allow-list below; list any others in out_of_scope_files. If scope_ok is false, verdict MUST be fail.\nCHECK 1 (DELIVERABLES): set deliverables_present=true ONLY if macos/Sources/Features/WebMonitor/WebMonitorServer.swift exists AND the two web-monitor keys exist in src/config/Config.zig. If false, verdict MUST be fail.\nThen grade 0-100 against SPEC + plan; verdict "pass" ONLY if score>=98, scope_ok, deliverables_present, and blocking_issues empty. MUST-CHECK: one NWListener serves BOTH page and API; all AppKit/surface access on the main thread with no pointer retained across the hop and missing surface -> 404; token required to start + per-request (length-checked/constant-time); textContent not innerHTML; free_text on any direct read; zero new SPM deps; project.pbxproj has the file in the macOS target AND iOS exclusion like ProjectPalette; the two Zig keys follow project-directory and default empty; quick buttons send correct bytes (Enter=0x0d, Ctrl-C=0x03, Esc=0x1b); HTTP parse handles Content-Length, unknown path->404, wrong method->405; build_result is SUCCESS. Do NOT penalize for the macOS app build not being run. Do NOT edit files.\n\nALLOW-LIST:\n' + ALLOWLIST_TEXT + '\n\nSPEC:\n' + SPEC + '\n\nIMPLEMENTER REPORT:\n' + JSON.stringify(impl, null, 2),
    { schema: REVIEW_SCHEMA, phase: 'Implement', label: 'impl-review#' + (i + 1) })
  if (!implReview) return { status: 'aborted', where: 'impl-review' }
  log('Impl iter ' + (i + 1) + ': score ' + implReview.score + ' (' + implReview.verdict + ') scope_ok=' + implReview.scope_ok + ' build=' + (impl.build_result || '').slice(0, 30))
  if (implReview.score >= GATE && implReview.verdict === 'pass') break
}
if (!(implReview && implReview.score >= GATE && implReview.verdict === 'pass')) {
  return { status: 'FAILED', gate: 'impl', lastScore: implReview ? implReview.score : null, review: implReview }
}
log('IMPL GATE PASSED at ' + implReview.score + '. Final critic.')

// ---------------- CRITIC PHASE ----------------
phase('Critique')
let critic = null
for (let i = 0; i < MAX; i++) {
  critic = await agent(
    'You are the FINAL ADVERSARIAL CRITIC, fresh eyes. Read the COMPLETE change: "git -C ' + REPO + ' diff", "git -C ' + REPO + ' status", and open every changed/new file. \nCHECK 0 (SCOPE): run "git -C ' + REPO + ' diff --name-only"; scope_ok=true ONLY if all changed files are in the allow-list; else verdict fail.\nCHECK 1 (DELIVERABLES): WebMonitorServer.swift exists AND the two config keys exist; else verdict fail.\nThen judge the whole feature vs SPEC + plan. Hunt hard for: correctness bugs; threading races (background queue vs main-thread AppKit; surface freed mid-request; weak-ref handling); security holes (token bypass/missing on any route, timing, path traversal / ".." in any static serving, binding exposure, innerHTML injection); hand-rolled HTTP bugs (Content-Length vs chunked, partial reads across TCP segments, keep-alive/close, header case, oversized bodies); resource leaks (free_text, NWConnection cleanup); single-listener-serves-both; mobile UX (correct quick-button bytes, poll interval vs 500ms cache); pbxproj target+iOS-exclusion; fork safety (no push/commit). Grade 0-100; verdict "pass" ONLY if score>=98, scope_ok, deliverables_present, blocking_issues empty. Do NOT penalize for the macOS app build not being run. Do NOT edit files.\n\nALLOW-LIST:\n' + ALLOWLIST_TEXT + '\n\nSPEC:\n' + SPEC + '\n\nAPPROVED PLAN:\n' + approvedPlan.plan_markdown,
    { schema: REVIEW_SCHEMA, phase: 'Critique', label: 'critic#' + (i + 1) })
  if (!critic) return { status: 'aborted', where: 'critic' }
  log('Critic iter ' + (i + 1) + ': score ' + critic.score + ' (' + critic.verdict + ') scope_ok=' + critic.scope_ok)
  if (critic.score >= GATE && critic.verdict === 'pass') break
  const fix = await agent(
    'You are the IMPLEMENTER applying the FINAL CRITIC blocking fixes. Working dir ' + REPO + ', branch ramon-fork. OBEY THE SCOPE LOCK (allow-list below; revert any off-list change). Apply EVERY blocking issue with Edit/Write, then re-run the fast incremental build zig build -Demit-macos-app=false -Doptimize=Debug (run_in_background+poll if it would exceed ~2 min) and report build_result verbatim. Do NOT commit/push or run the macOS app build.\n\nALLOW-LIST:\n' + ALLOWLIST_TEXT + '\n\nCRITIC ISSUES:\n' + reviewLine(critic) + '\n\nSPEC:\n' + SPEC,
    { schema: IMPL_SCHEMA, phase: 'Critique', label: 'critic-fix#' + (i + 1) })
  if (!fix) return { status: 'aborted', where: 'critic-fix' }
  log('Applied critic fixes (iter ' + (i + 1) + '), scope=' + (fix.scope_self_check || '').slice(0, 40) + ' build=' + (fix.build_result || '').slice(0, 30))
}
if (!(critic && critic.score >= GATE && critic.verdict === 'pass')) {
  return { status: 'FAILED', gate: 'critic', lastScore: critic ? critic.score : null, review: critic }
}

return {
  status: 'PASSED',
  planScore: planReview.score,
  implScore: implReview.score,
  criticScore: critic.score,
  files: approvedPlan.files,
  criticSummary: critic.summary,
}

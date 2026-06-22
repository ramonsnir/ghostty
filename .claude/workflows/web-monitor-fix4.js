export const meta = {
  name: 'web-monitor-fix4',
  description: 'A+ hardening: tiny SEQUENTIAL agents apply the high-value should-fix items (connection deadline+cap, query-token boundary, token-entropy floor, backoff-key safety, 404 send teardown, UX polish, added route tests). Each updates its own tests. Builds/tests run by the human after.',
  phases: [{ title: 'Harden', detail: 'sequential tiny per-item edits' }],
}

const REPO = '/Users/ramon/git/ghostty'
const SERVER = 'macos/Sources/Features/WebMonitor/WebMonitorServer.swift'
const TESTS = 'macos/Tests/WebMonitor/WebMonitorServerTests.swift'

const RULES = [
  'SCOPE LOCK: modify ONLY ' + SERVER + ' and/or ' + TESTS + '. Touch nothing else. Never read/edit',
  'src/host/**, src/termio/**, .claude/**, or the ghostty-phase2b worktree (unrelated pty-host project).',
  'Locate edit sites by CONTENT (read/grep the named functions), not line numbers. Make ONLY the change for',
  'THIS task. Keep the page XSS-safe (textContent for untrusted data, never innerHTML). When you change',
  'PRODUCTION behavior, UPDATE or ADD the matching test(s) in the same task so the suite stays correct and',
  'green. Do NOT run any build/test, do NOT commit/push. After editing, report the before/after hunk(s).',
].join('\n')

const TASKS = [
  {
    id: 'T1-conn-deadline-cap',
    title: 'Absolute per-connection deadline + concurrent-connection cap',
    detail: 'The idle watchdog (armConnectionTimer / receiveRequest .needMore path) REARMS per read, so a ' +
      'slowloris/trickle peer can hold a connection forever, and there is no cap on connectionRefs.count. Add: ' +
      '(a) an ABSOLUTE per-connection deadline armed ONCE in handle() (e.g. 15s) that cancels the connection ' +
      'regardless of progress — do not rearm it per read; keep or fold in the existing idle behavior but ensure ' +
      'the absolute deadline is the hard ceiling; (b) a max concurrent-connection cap (e.g. 32) enforced in ' +
      'handle(): if connectionRefs.count is at the cap, cancel/reject the new connection (log it). Mutate the ' +
      'bookkeeping only on the serial queue. Add a brief comment. (Timers are hard to unit-test; no test needed, ' +
      'but if you extract any pure helper, test it.)',
  },
  {
    id: 'T2-query-token-boundary',
    title: 'Accept ?token= only on GET /, require header on the API',
    detail: 'In decideRoute the token is read as query["token"] ?? headers["x-ghostty-token"], so ?token= ' +
      'authenticates EVERY endpoint. Make the query token acceptable ONLY for the GET / bootstrap; for all ' +
      '/api/* routes require the token via the X-Ghostty-Token header and IGNORE any query token. Implement this ' +
      'in the pure decideRoute so it is testable. UPDATE/ADD tests: query-token on /api/surfaces -> .unauthorized; ' +
      'header-token on /api/surfaces -> works; query-token on GET / -> .page (still allowed). Keep all existing ' +
      'decideRoute tests valid (the decide() helper already presents via header by default).',
  },
  {
    id: 'T3-token-entropy-floor',
    title: 'Enforce a minimum token strength at startup',
    detail: 'start() currently rejects only an EMPTY token. The token is a shell-execution credential. Add a pure ' +
      'static helper e.g. tokenAcceptable(_ t: String) -> Bool that requires a minimum length (>= 16 chars; ' +
      'reject obviously weak/short tokens), and have start() refuse to start (logger.warning + Self.notify) when ' +
      '!tokenAcceptable(token), with a message telling the user to use a long random token. ADD unit tests for ' +
      'tokenAcceptable (empty -> false, short like "abc" -> false, a 16+ char random-ish string -> true).',
  },
  {
    id: 'T4-backoff-key-safety',
    title: 'Do not throttle on unresolved peer keys / cleared peers',
    detail: 'The per-peer failed-auth backoff keys on remoteIP, which is best-effort and can fall back to a shared/' +
      'endpoint string; throttling runs before the token check, so a collision could 429 a legitimate peer ' +
      '(availability foot-gun for the approval use case). Change the throttle path so it only applies backoff when ' +
      'a CONCRETE peer IP was resolved (skip throttling when the key is the best-effort fallback / unresolved), and ' +
      'never throttle a peer that has cleared auth within the window. Keep the decideRoute peerFailureCount contract ' +
      'intact (its tests still pass); the resolved-vs-unresolved decision lives where the peer key is computed ' +
      '(handle/routeRequest). Add a brief comment.',
  },
  {
    id: 'T5-ux-404-send-teardown',
    title: 'reportSend 404 runs the same teardown as poll',
    detail: 'In the embedded htmlPage JS, a poll that gets 404 tears down (clear timer, current=null, sticky ' +
      '"Session closed." banner, loadList()+showList()), but reportSend (send/HTTP-error handler) treats a 404 ' +
      'differently, leaving a stale viewer + sticky banner until the next poll. Make reportSend detect HTTP 404 and ' +
      'run the SAME teardown as the poll 404 path (factor a small sharedclosure if convenient). Keep textContent-only.',
  },
  {
    id: 'T6-ux-polish',
    title: 'Ctrl-C guard, longer Sent toast, no-active-session feedback',
    detail: 'In the htmlPage: (a) visually separate/destyle the Ctrl-C quick-key (e.g. a danger color or a small gap) ' +
      'so it is not a one-tap fat-finger beside benign keys — a confirm/long-press is optional; (b) the "Sent." ' +
      'success toast auto-clears in 600ms (easy to miss on a throttled mobile tab) — leave it until the next ' +
      'successful poll render or bump to ~1500ms; (c) when a quick-key/Send is tapped with no current surface ' +
      '(dead tap after a 404 teardown), show a brief "No active session." banner (or hide the quick-key bar in ' +
      'showList()). Small, localized JS/HTML changes; textContent-only.',
  },
  {
    id: 'T7-route-branch-tests',
    title: 'Add the untested route/parse branch cases',
    detail: 'ADD @Test cases (no production change unless a gap is found) reflecting the FINAL behavior after T2: ' +
      '(1) empty/missing Host header on GET / -> .page (allowed; not .forbiddenHost); (2) token precedence — with ' +
      'T2 in place, query-token on /api/* is rejected while header-token works, and on GET / the query token is ' +
      'accepted; assert these; (3) screen mode defaults to viewport for an unknown/junk mode value (e.g. ' +
      'mode=garbage -> .screen(scrollback:false)); (4) the empty-decoded-input contract for /input (decodeInput on ' +
      'an empty body, and the intended 400/no-op behavior). Make them pass against the real code (adjust an ' +
      'assertion to the actual contract if needed, noting it).',
  },
]

const FIX_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    task_id: { type: 'string' },
    done: { type: 'boolean' },
    files_changed: { type: 'array', items: { type: 'string' } },
    hunk: { type: 'string' },
    tests_updated: { type: 'string', description: 'what tests you added/updated for this change' },
    scope_ok: { type: 'boolean' },
    notes: { type: 'string' },
  },
  required: ['task_id', 'done', 'files_changed', 'scope_ok'],
}

phase('Harden')
const results = []
for (const t of TASKS) {
  const r = await agent(
    'You are a focused IMPLEMENTER doing ONE small hardening change in a Ghostty fork. Read only the relevant ' +
    'function(s) named, make exactly this change (and its tests), nothing else.\n\nTASK ' + t.id + ': ' + t.title +
    '\nWHAT TO DO: ' + t.detail + '\n\nFILES: ' + SERVER + ' and/or ' + TESTS + '\n\n' + RULES,
    { schema: FIX_SCHEMA, phase: 'Harden', label: t.id })
  if (!r) { results.push({ task_id: t.id, done: false, skipped: true }); continue }
  results.push(r)
  log(t.id + ': ' + (r.done ? 'done' : 'NOT done') + ' scope_ok=' + r.scope_ok + ' files=' + (r.files_changed || []).join(','))
}

const failures = results.filter(function (r) { return !r.done || r.scope_ok === false })
return {
  status: failures.length === 0 ? 'ALL_APPLIED' : 'PARTIAL',
  applied: results.filter(function (r) { return r.done }).map(function (r) { return r.task_id }),
  failures: failures.map(function (r) { return r.task_id }),
  results: results,
}

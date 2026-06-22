export const meta = {
  name: 'web-monitor-fix6',
  description: 'Polish pass: tiny SEQUENTIAL agents apply the 8 nit-level should-fix items from the A+ review (timer teardown in send(), failedAuth hard cap, disabled-button CSS, quick-key local ack, header-comment note, + 3 added test groups). Builds/tests run by the human after.',
  phases: [{ title: 'Polish', detail: 'sequential tiny per-item edits' }],
}

const REPO = '/Users/ramon/git/ghostty'
const SERVER = 'macos/Sources/Features/WebMonitor/WebMonitorServer.swift'
const TESTS = 'macos/Tests/WebMonitor/WebMonitorServerTests.swift'

const RULES = [
  'SCOPE LOCK: modify ONLY ' + SERVER + ' and/or ' + TESTS + '. Touch nothing else. Never read/edit',
  'src/host/**, src/termio/**, .claude/**, or the ghostty-phase2b worktree (unrelated pty-host project).',
  'Locate edit sites by CONTENT (read/grep the named symbols), not line numbers. Make ONLY the change for THIS',
  'task. Keep the page XSS-safe (textContent for untrusted data; CSS/structure changes are fine). Mutate any',
  'server connection bookkeeping ONLY on the serial `queue`. Do NOT run builds/tests, commit, or push. Report the',
  'before/after hunk(s).',
].join('\n')

const TASKS = [
  {
    id: 'P1-send-timer-teardown',
    title: 'Disarm connection timers inside send()',
    detail: 'send() currently cancels the connection only via the send-completion conn.cancel() round-trip, leaving ' +
      'the idle + absolute-deadline timers armed until that completes. Call cancelConnectionTimer(ObjectIdentifier(conn)) ' +
      'at the TOP of send() so timer teardown is a property of send() itself (idempotent; cancelConnectionTimer already ' +
      'handles missing keys). This makes future callers safe without relying on each one pre-cancelling. No behavior ' +
      'change for current callers.',
  },
  {
    id: 'P2-failedAuth-hardcap',
    title: 'Hard-cap the failedAuth map (drop-oldest)',
    detail: 'recordAuthFailure prunes the failedAuth dict by the decay window only when at the cap, so a spray of ' +
      'failedAuthMaxEntries (4096) fresh distinct IPs within the 60s window removes nothing and the dict can momentarily ' +
      'exceed the cap. After the existing window-filter prune, if the count is STILL >= failedAuthMaxEntries, drop the ' +
      'OLDEST entry (smallest .last) before inserting, so the dict size is strictly bounded. Keep all mutation on the queue.',
  },
  {
    id: 'P3-disabled-button-css',
    title: 'Visible disabled state for Send/Raw buttons',
    detail: 'The empty-input disabled state on the Send/Raw buttons is not visually distinct on mobile. Add a ' +
      'button:disabled rule to the htmlPage CSS (e.g. opacity: 0.45; and cursor/pointer-events as appropriate) so a ' +
      'disabled control clearly reads as disabled. CSS-only.',
  },
  {
    id: 'P4-quickkey-local-ack',
    title: 'Immediate local highlight on quick-key tap',
    detail: 'Quick-key taps (the data-key buttons enter/y/n/esc/tab/ctrl-c/arrows AND the data-raw digits 1/2/3/4) ' +
      'currently give no local feedback until the network round-trip. Add a brief local visual acknowledgement on tap ' +
      '(e.g. add an "active"/flash CSS class for ~150ms via classList add + setTimeout remove, or a :active style) so ' +
      'the user sees the tap registered independent of latency. Do not change what bytes are sent. JS/CSS only.',
  },
  {
    id: 'P8-header-comment-note',
    title: 'Clarify the security-model header comment',
    detail: 'In the SECURITY MODEL header comment block, add two short clarifications: (1) the per-peer backoff counts ' +
      'consecutive wrong-token failures and is cleared on a token-valid request; (2) the Host-header allowlist is a ' +
      'DNS-rebinding guard ONLY — a request with no Host header is still subject to the token gate (the token, not the ' +
      'Host check, is the authentication boundary). Comment-only; no code change.',
  },
  {
    id: 'P5-surfacesJSON-hostile-chars-test',
    title: 'Test: surfacesJSONData with JSON-hostile chars',
    detail: 'Add a @Test that calls surfacesJSONData with title/pwd containing JSON-hostile characters — a double quote, ' +
      'a backslash, a newline, and a multibyte/emoji character — then round-trips the produced Data through ' +
      'JSONSerialization.jsonObject and asserts the values come back byte-identical (proving proper escaping). Test-only.',
  },
  {
    id: 'P6-decideRoute-notfound-tests',
    title: 'Test: decideRoute extra/short surface paths -> notFound',
    detail: 'Add @Test cases for decideRoute on /api/surface/{uuid} (no trailing action component) and ' +
      '/api/surface/{uuid}/screen/extra (an extra trailing component), BOTH expecting .notFound, using the existing ' +
      'decide() helper for auth defaults. Test-only (no production change unless a real gap is found — if so, note it).',
  },
  {
    id: 'P7-hostHeader-malformed-tests',
    title: 'Test (+harden if needed): malformed Host headers',
    detail: 'Add @Test cases for hostHeaderAllowed with malformed Host values — an unbalanced bracket (e.g. ' +
      '"[::1:8787") and a stray double-colon (e.g. "a::b:8787") — asserting it returns FALSE and does NOT crash/trap. ' +
      'If the current hostHeaderAllowed crashes or mis-accepts on these inputs, harden it defensively (production) so ' +
      'malformed Host parsing is safe, then assert the corrected behavior. Otherwise test-only.',
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
    scope_ok: { type: 'boolean' },
    notes: { type: 'string' },
  },
  required: ['task_id', 'done', 'files_changed', 'scope_ok'],
}

phase('Polish')
const results = []
for (const t of TASKS) {
  const r = await agent(
    'You are a focused IMPLEMENTER doing ONE small polish change in a Ghostty fork. Read only the relevant symbol(s), ' +
    'make exactly this change, nothing else.\n\nTASK ' + t.id + ': ' + t.title + '\nWHAT TO DO: ' + t.detail +
    '\n\nFILES: ' + SERVER + ' and/or ' + TESTS + '\n\n' + RULES,
    { schema: FIX_SCHEMA, phase: 'Polish', label: t.id })
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

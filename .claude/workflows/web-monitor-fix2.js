export const meta = {
  name: 'web-monitor-fix2',
  description: 'Decomposed fix: one tiny agent per finding, run SEQUENTIALLY (short turns dodge the 180s watchdog; sequential avoids same-file edit races). Fixes the test-compile typo + the UX majors + the UX minors. Builds/tests are run by the human afterward.',
  phases: [
    { title: 'Fix', detail: 'sequential tiny per-finding edits' },
  ],
}

const REPO = '/Users/ramon/git/ghostty'
const SERVER = 'macos/Sources/Features/WebMonitor/WebMonitorServer.swift'
const TESTS = 'macos/Tests/WebMonitor/WebMonitorServerTests.swift'

// Only these two files may be touched. Each task below is a SMALL, localized edit.
const RULES = [
  'SCOPE LOCK: the ONLY files you may modify are:',
  '  - ' + SERVER + '  (the server + the embedded htmlPage HTML/JS string)',
  '  - ' + TESTS + '  (the Swift unit tests)',
  'Touch NOTHING else. Never read/edit src/host/**, src/termio/**, .claude/**, or the',
  'ghostty-phase2b worktree (a separate pty-host project; irrelevant). Locate the edit site by',
  'CONTENT (grep/read for the quoted anchors) rather than trusting line numbers, which may have',
  'shifted. Make ONLY the change described for THIS task — do not refactor or fix other things',
  '(other tasks handle them). Keep the embedded page XSS-safe: untrusted data via textContent,',
  'never innerHTML. Do NOT run any build or test (the human runs them after). Do NOT commit/push.',
  'After editing, run "git -C ' + REPO + ' diff --name-only" and confirm only the allowed file(s)',
  'changed; report the exact hunk you changed.',
].join('\n')

const TASKS = [
  {
    id: 'T0-test-typo',
    file: TESTS,
    title: 'Fix the argument-order compile error in the test',
    detail: 'In the @Test func decideRouteWrongToken() the helper `decide(...)` is called with the ' +
      '`token:` argument BEFORE the `headers:` argument, but `decide` declares `headers:` before ' +
      '`token:` (Swift error: "Argument \'headers\' must precede argument \'token\'"). Reorder the ' +
      'call so `headers:` comes before `token:` (same values, just swap the two labeled args). This ' +
      'is the ONLY compile error; the whole GhosttyTests target currently fails to build because of it.',
  },
  {
    id: 'M1-banner-error-persist',
    file: SERVER,
    title: 'Error banners must not be wiped by the next successful poll',
    detail: 'In the embedded htmlPage JS: a failed send ("Send failed (HTTP ...)") and the ' +
      '"Session closed." banner are erased within ~700ms by the unconditional setBanner(null) on the ' +
      'next successful poll() and loadList(). Make error feedback sticky: introduce an isError flag ' +
      '(or a separate error element) so the poll()/loadList() SUCCESS paths call setBanner(null) ONLY ' +
      'when the current banner is NOT an error; a send-failure / session-closed banner must persist ' +
      'until the next explicit user action (next send, navigation, or manual dismiss). Find the ' +
      'setBanner(null) calls on the poll-success and loadList-success paths and the failure setBanner ' +
      'calls in the send/closed handlers.',
  },
  {
    id: 'M2-digit-quickkeys',
    file: SERVER,
    title: 'Add numeric 1/2/3 (and 4) quick-keys',
    detail: 'The quick-key button row offers enter/y/n/esc/tab/ctrl-c but NOT digits — yet 1/2/3 is ' +
      'how Claude Code permission menus are answered (the headline use case). Add one-tap buttons ' +
      '1 2 3 4 that send the raw digit with NO newline (reuse the existing raw-text send path / ' +
      'sendText that POSTs a text/plain body — the server already treats non-JSON bodies as raw UTF-8, ' +
      'so NO server change is needed). Match the existing button styling/wiring.',
  },
  {
    id: 'S1-list-loading-flash',
    file: SERVER,
    title: 'Stop the session-list "Loading…" flash on background refresh',
    detail: 'loadList() sets the list innerHTML to a "Loading…" placeholder every time, including the ' +
      'periodic (~3s) background refresh, causing a flash + scroll loss. Show the "Loading…" ' +
      'placeholder only on the FIRST/empty load; on a background refresh, render the rows in place ' +
      '(diff/replace content) without the placeholder.',
  },
  {
    id: 'S2-scroll-on-explicit-change',
    file: SERVER,
    title: 'On user-initiated mode/wrap/font change, jump to live bottom',
    detail: 'When the user explicitly switches viewport<->scrollback (or toggles wrap/font), the code ' +
      're-polls and restores the OLD pixel scrollTop, which is meaningless against new content. ' +
      'Distinguish a user-initiated change from a background poll: on the explicit change, force ' +
      'scroll to the live bottom (scrollTop = scrollHeight) instead of restoring prevTop. Leave the ' +
      'near-bottom auto-follow on background polls unchanged.',
  },
  {
    id: 'S3-jump-to-bottom',
    file: SERVER,
    title: 'Add a "jump to live bottom" affordance in scrollback mode',
    detail: 'Auto-follow only re-sticks when already near the bottom. Add a small "Bottom" / ' +
      'down-chevron button that sets screenEl.scrollTop = screenEl.scrollHeight; show it only when ' +
      'the user is NOT near the bottom. Keep it unobtrusive on mobile.',
  },
  {
    id: 'S4-aria-live',
    file: SERVER,
    title: 'Announce banner/notice state changes to screen readers',
    detail: 'The #banner and #notice are plain divs, so VoiceOver never announces connection-loss / ' +
      'error state changes. Add role="status" aria-live="polite" to #banner and role="alert" ' +
      'aria-live="assertive" to #notice.',
  },
  {
    id: 'S5-pause-poll-hidden',
    file: SERVER,
    title: 'Pause the 700ms poll while the tab is backgrounded',
    detail: 'The poll interval keeps firing while document.visibilityState !== "visible" (wasteful, ' +
      'and mobile throttles it anyway). Pause the interval when hidden and resume with an immediate ' +
      'poll on becoming visible (a visibilitychange handler already exists for the return-poll; extend ' +
      'it to also clear/re-arm the interval).',
  },
  {
    id: 'S6-token-recovery',
    file: SERVER,
    title: 'In-page token recovery when missing/401',
    detail: 'The no-token / 401 notice tells the user to "Reopen with ?token=…", but the URL was ' +
      'scrubbed via replaceState and there is no in-page way to re-enter it. Add a token <input> + ' +
      '"Connect" button (shown in the no-token/401 state) that stores the entered token to ' +
      'sessionStorage and retries the fetches, so a phone user who lost the URL can recover without ' +
      'editing the address bar.',
  },
]

const FIX_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    task_id: { type: 'string' },
    done: { type: 'boolean' },
    file_changed: { type: 'string' },
    hunk: { type: 'string', description: 'the exact before/after of what you changed' },
    scope_ok: { type: 'boolean', description: 'git diff --name-only shows only the allowed file(s)' },
    notes: { type: 'string' },
  },
  required: ['task_id', 'done', 'file_changed', 'scope_ok'],
}

// SEQUENTIAL — same-file edits must not race, and short single-task turns stay under the watchdog.
phase('Fix')
const results = []
for (const t of TASKS) {
  const r = await agent(
    'You are a focused IMPLEMENTER doing ONE small fix in a Ghostty fork. Make exactly this change and nothing else.\n\n' +
    'TASK ' + t.id + ': ' + t.title + '\nFILE: ' + t.file + '\nWHAT TO DO: ' + t.detail + '\n\n' + RULES,
    { schema: FIX_SCHEMA, phase: 'Fix', label: t.id })
  if (!r) { results.push({ task_id: t.id, done: false, skipped: true }); continue }
  results.push(r)
  log(t.id + ': ' + (r.done ? 'done' : 'NOT done') + ' scope_ok=' + r.scope_ok + ' file=' + (r.file_changed || ''))
}

const failures = results.filter(function (r) { return !r.done || r.scope_ok === false })
return {
  status: failures.length === 0 ? 'ALL_APPLIED' : 'PARTIAL',
  applied: results.filter(function (r) { return r.done }).map(function (r) { return r.task_id }),
  failures: failures.map(function (r) { return r.task_id }),
  results: results,
}

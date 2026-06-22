export const meta = {
  name: 'web-monitor-fix5',
  description: 'One tiny agent: relax the brittle whitespace assertion in htmlPageSessionClosedTeardownShared (test-only; production is correct).',
  phases: [{ title: 'Fix', detail: 'one test-assertion relaxation' }],
}

const REPO = '/Users/ramon/git/ghostty'
const TESTS = 'macos/Tests/WebMonitor/WebMonitorServerTests.swift'

const FIX_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    done: { type: 'boolean' },
    file_changed: { type: 'string' },
    hunk: { type: 'string' },
    notes: { type: 'string' },
  },
  required: ['done', 'file_changed', 'hunk'],
}

phase('Fix')
const r = await agent(
  'You are a focused IMPLEMENTER making ONE small TEST-ONLY correction in a Ghostty fork. Modify ONLY ' + TESTS +
  ' — do NOT change production code or any other file. Do NOT run builds/tests, commit, or push.\n\n' +
  'PROBLEM: @Test func htmlPageSessionClosedTeardownShared() fails on its THIRD #expect:\n' +
  '    #expect(page.contains("if (m === \\"404\\") {\\n              sessionClosedTeardown();"))\n' +
  'This hard-codes an exact newline + 14-space indentation that does not match the emitted htmlPage string. ' +
  'The PRODUCTION code is CORRECT: the embedded page defines `function sessionClosedTeardown()` and calls it from ' +
  'BOTH 404 paths — the poll() 404 handler and reportSend()\'s `r.status === 404` branch (verify this by reading ' +
  'the htmlPage in macos/Sources/Features/WebMonitor/WebMonitorServer.swift). \n\n' +
  'FIX (test-only): replace the brittle whitespace-exact assertion with a robust check that still verifies BOTH ' +
  '404 callers route through the shared helper WITHOUT depending on exact indentation/newlines. For example: assert ' +
  'the page contains "function sessionClosedTeardown()" (definition) AND that "sessionClosedTeardown()" appears at ' +
  'least 3 times total (1 definition + 2 call sites) — or assert two robust call-site substrings that ignore ' +
  'whitespace (e.g. the poll path "=== 404" context and the reportSend "r.status === 404" context each near a ' +
  'sessionClosedTeardown() call). Keep the first two #expect lines (function defined; setBanner("Session closed.", ' +
  'false, true)). Do NOT touch production code. Report the before/after hunk.',
  { schema: FIX_SCHEMA, phase: 'Fix', label: 'fix-teardown-test' })

return { status: r && r.done ? 'APPLIED' : 'INCOMPLETE', result: r }

export const meta = {
  name: 'web-monitor-fix3',
  description: 'One tiny agent: correct the single failing test expectation (requestParserContentLengthOverCapRejected) — a test-only fix; production behavior is correct.',
  phases: [{ title: 'Fix', detail: 'one test-expectation correction' }],
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
  'You are a focused IMPLEMENTER making ONE small TEST-ONLY correction in a Ghostty fork. Modify ONLY ' + TESTS + ' — do NOT change any production code, and touch no other file. Do NOT run builds/tests, commit, or push. Locate the edit by content.\n\n' +
  'PROBLEM: the @Test func requestParserContentLengthOverCapRejected() currently does:\n' +
  '    let smallCap = 16\n' +
  '    let raw = "POST /x HTTP/1.1\\r\\nContent-Length: \\(smallCap + 1)\\r\\n\\r\\n"\n' +
  '    let r = WebMonitorServer.RequestParser.parse(Data(raw.utf8), maxRequestBytes: smallCap)\n' +
  '    if case .badRequest = r {} else { Issue.record("expected badRequest, got \\(r)") }\n' +
  'and it FAILS because the parser is CORRECT: the whole request buffer (~40 bytes) exceeds ' +
  'maxRequestBytes (16), so the parser returns .tooLarge (413) on the overall buffer-size check ' +
  'BEFORE it ever reaches the Content-Length-over-cap guard. The request is still rejected — just ' +
  'as .tooLarge rather than .badRequest.\n\n' +
  'FIX (test-only): change THIS test to assert the oversized-buffer input is rejected as .tooLarge ' +
  '(not .badRequest), and update the comment to explain that for a cap smaller than the header ' +
  'block the buffer-size cap preempts the Content-Length guard. Note in the comment that the ' +
  'Content-Length-guard -> .badRequest path is already covered by ' +
  'requestParserOversizedContentLengthIsBadRequest (which uses the real large cap with a huge CL). ' +
  'Do NOT touch production code or any other test. Report the before/after hunk.\n\n' +
  'SCOPE: only ' + TESTS + '. After editing, confirm via reading that the change is exactly this one test.',
  { schema: FIX_SCHEMA, phase: 'Fix', label: 'fix-overcap-test' })

return { status: r && r.done ? 'APPLIED' : 'INCOMPLETE', result: r }

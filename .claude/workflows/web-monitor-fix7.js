export const meta = {
  name: 'web-monitor-fix7',
  description: 'Fix web-monitor input: send REAL key events (ghostty_surface_key) instead of the paste path (ghostty_surface_text/completeClipboardPaste), so Enter submits, Ctrl-C/Esc/Tab/arrows act as keys, and newline-pastes no longer trip paste-protection. ALL input becomes key events. GUI-only (no host change).',
  phases: [{ title: 'Fix', detail: 'sequential tiny edits: server key-sender, JS, tests' }],
}

const REPO = '/Users/ramon/git/ghostty'
const SERVER = 'macos/Sources/Features/WebMonitor/WebMonitorServer.swift'
const TESTS = 'macos/Tests/WebMonitor/WebMonitorServerTests.swift'

const RULES = [
  'SCOPE LOCK: modify ONLY ' + SERVER + ' and/or ' + TESTS + '. Touch nothing else. Never edit src/**, the host,',
  '.claude/**, or the ghostty-phase2b worktree. This is a GUI-ONLY fix — NO Zig/host/protocol changes.',
  'Locate by content. Keep the page XSS-safe (textContent for untrusted data). All AppKit / ghostty_surface_*',
  'access stays on the main thread inside the existing DispatchQueue.main.sync hop, with no surface pointer crossing',
  'the hop. When you change behavior, update/add tests in the same task. Do NOT run builds/tests, commit, or push.',
  'Report before/after hunks.',
].join('\n')

const BACKGROUND = [
  'ROOT CAUSE: the web monitor currently sends input via ghostty_surface_text, which calls',
  'surface.textCallback -> completeClipboardPaste — i.e. the PASTE path. Consequences: a sent "\\n" is a pasted',
  'literal newline (NOT an Enter keypress, so nothing submits); pasted control bytes (0x03, ESC[A, ...) are not real',
  'Ctrl-C / arrow keys; and newline-containing pastes trip Ghostty paste-protection (a Mac dialog, invisible to the',
  'phone), so the input never lands. FIX: send input as REAL KEY EVENTS via ghostty_surface_key, exactly like the',
  'app does when you type.',
  '',
  'MODEL TO MIRROR (read these): macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift around lines 1490-1540',
  '(how it fills a ghostty_input_key_s and calls ghostty_surface_key), and macos/Sources/Ghostty/Ghostty.Input.swift',
  'around line 198-225 (withCValue builds ghostty_input_key_s: action, mods, consumed_mods, keycode, text,',
  'unshifted_codepoint, composing). Key enums in include/ghostty.h: GHOSTTY_ACTION_PRESS/RELEASE, GHOSTTY_KEY_ENTER,',
  'GHOSTTY_KEY_ESCAPE, GHOSTTY_KEY_TAB, GHOSTTY_KEY_C, GHOSTTY_KEY_ARROW_UP/DOWN/LEFT/RIGHT, and the mods enum',
  '(ghostty_input_mods_e) for the ctrl modifier. ghostty_surface_key(surface, key_ev) is the call.',
].join('\n')

const TASKS = [
  {
    id: 'T1-server-key-sender',
    title: 'Send input as ghostty_surface_key events, not paste',
    detail: 'In WebMonitorServer.swift, replace the input path that calls ghostty_surface_text with one that sends ' +
      'REAL KEY EVENTS via ghostty_surface_key. Design: a PURE, unit-testable mapping (e.g. `static func ' +
      'keySpecs(forKey:)` and `keySpecs(forText:)`) that turns a request into an ordered list of key specs, plus a ' +
      'main-thread sender that builds a ghostty_input_key_s per spec and calls ghostty_surface_key on the surface. ' +
      'A "spec" is a small internal struct (keycode: ghostty_input_key_e value, mods, text: String?, ' +
      'unshiftedCodepoint). Mirror the macOS keyDown path for field values; for a PRESS you may also send the ' +
      'matching RELEASE if that path does (check the model). Mappings: named keys enter->GHOSTTY_KEY_ENTER, ' +
      'esc->GHOSTTY_KEY_ESCAPE, tab->GHOSTTY_KEY_TAB, ctrl-c->GHOSTTY_KEY_C with the ctrl modifier set, ' +
      'up/down/left/right->GHOSTTY_KEY_ARROW_*; printable TEXT -> one key spec per Character with text=that char and ' +
      'unshiftedCodepoint=its scalar (keycode 0/unset is fine for printable text — the model shows text-bearing ' +
      'events encode the text). y/n are just printable text "y"/"n". Update the POST /input route + decode so a ' +
      'JSON {key:...} maps via keySpecs(forKey:) and a text/plain body maps via keySpecs(forText:); unknown key -> ' +
      '400; empty -> 400. REMOVE the ghostty_surface_text/paste usage for input. Keep the main-thread hop + 404 on ' +
      'missing surface. \n\n' + BACKGROUND,
  },
  {
    id: 'T2-js-typed-submit',
    title: 'JS: type text + Enter key, stop pasting newlines',
    detail: 'In the embedded htmlPage JS: doSend(withNewline) must no longer append "\\n" to the body. Instead: send ' +
      'the typed text (sendText posts the text/plain body, which the server now turns into typed key events), and ' +
      'if withNewline, ALSO send a separate Enter key event (sendKey("enter")). So Send = type + Enter; Raw = type ' +
      'only; the inp keydown Enter handler = doSend(true). The quick-keys (enter/y/n/esc/tab/ctrl-c, digits, arrows) ' +
      'already POST {key:...} or text — leave their call sites but ensure Enter/control keys go through the {key:...} ' +
      'path (key events) and digits/letters through the text path. No bracketed-paste, no trailing newline anywhere.',
  },
  {
    id: 'T3-tests',
    title: 'Tests for the key-spec mapping',
    detail: 'Add @Test cases for the pure mapping: keySpecs(forKey:) returns the right keycode/mods for ' +
      'enter/esc/tab/ctrl-c(+ctrl mod)/up/down/left/right and nil/empty for an unknown key; keySpecs(forText:) ' +
      'returns one spec per character with the right text/unshifted codepoint (e.g. "hi" -> 2 specs; "y" -> 1; ' +
      'empty -> []); and that Ctrl-C carries the ctrl modifier while plain letters carry no mods. Test-only logic ' +
      '(the actual ghostty_surface_key call needs a live surface and is exercised by the human on-device).',
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

phase('Fix')
const results = []
for (const t of TASKS) {
  const r = await agent(
    'You are a focused IMPLEMENTER doing ONE change in a Ghostty fork. Read the named model code first, then make ' +
    'exactly this change (and its tests), nothing else.\n\nTASK ' + t.id + ': ' + t.title + '\nWHAT TO DO: ' +
    t.detail + '\n\nFILES: ' + SERVER + ' and/or ' + TESTS + '\n\n' + RULES,
    { schema: FIX_SCHEMA, phase: 'Fix', label: t.id })
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

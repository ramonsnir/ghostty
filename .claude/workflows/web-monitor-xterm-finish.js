export const meta = {
  name: 'web-monitor-xterm-finish',
  description: 'Finish Phase 2b: the xterm.js client-side page integration (the task that stalled) + the host-client framing tests. Small sequential turns to stay under the watchdog. GUI-only.',
  phases: [{ title: 'Finish', detail: 'small sequential: xterm render fn, wire open/back, framing tests' }],
}

const SRV = 'macos/Sources/Features/WebMonitor/WebMonitorServer.swift'
const TESTS = 'macos/Tests/WebMonitor/WebMonitorServerTests.swift'

const STATE = [
  'ALREADY DONE (do NOT redo): the server serves GET /xterm.js + /xterm.css (assetRoutes; query-token allowed),',
  'has a streaming GET /api/surface/{uuid}/stream route (routeStream) that opens a WebMonitorHostClient and pipes',
  'the host raw PTY bytes to the connection as a long-lived application/octet-stream response, and',
  'WebMonitorHostClient.swift is complete. The embedded htmlPage is still the PLAIN-TEXT viewer (a <pre> polled via',
  'GET /api/surface/{uuid}/screen) with working key-event input — KEEP that as the fallback. What is MISSING is the',
  'client-side xterm.js integration in the htmlPage and the host-client framing unit tests.',
  '',
  'SCOPE LOCK: only ' + SRV + ' (the htmlPage string + nothing else structural) and ' + TESTS + '. Touch nothing',
  'else. Keep XSS-safety (xterm.js renders the byte stream; never innerHTML untrusted text). Input stays exactly as',
  'today (text field + Enter/quick-keys/digits/arrows POST to /input). Do NOT run builds/tests, commit, or push.',
  'Read the current htmlPage first to match its style/structure (the viewer open()/showList()/Back, poll(), banner',
  'helpers, the token helpers `url(path)` / `headers(extra)` / sessionStorage).',
].join('\n')

const TASKS = [
  {
    id: 'F1-xterm-assets-and-render',
    title: 'Load xterm.js/css + an openStream() that renders the live byte stream',
    detail: 'In the htmlPage: (a) in <head>, add <link rel="stylesheet" href="/xterm.css?token=..."> and a ' +
      '<script src="/xterm.js?token=..."> (build the URLs with the token the page already has, like the existing ' +
      'url() helper but as plain attributes since these are tags, not fetches). (b) Add a container element for the ' +
      'terminal (e.g. <div id="xterm"></div>) in the viewer, alongside the existing <pre id="screen"> (which stays ' +
      'for fallback). (c) Add JS: a function openStream(uuid) that — only if window.Terminal exists — creates a new ' +
      'Terminal({ convertEol:false, scrollback: 10000, fontSize: <reuse the existing font-size pref if present> }), ' +
      'calls term.open(document.getElementById("xterm")), then fetch("/api/surface/"+uuid+"/stream", ' +
      '{ headers: headers({}) }) and pumps response.body.getReader(): loop reading {value,done}, term.write(value) ' +
      '(value is a Uint8Array — xterm.write accepts it), until done/abort. Return an object exposing dispose() ' +
      '(cancel the reader + term.dispose()) and a way to detect failure. On fetch reject / non-ok / 501 / stream ' +
      'end, surface the existing connection-lost / "Session closed." banner and signal fallback. Store the active ' +
      'stream handle in a module var so Back/teardown can dispose it. Do NOT change the input code.',
  },
  {
    id: 'F2-wire-open-back-fallback',
    title: 'Use xterm when available, fall back to the plain-text poll',
    detail: 'Wire it into the viewer lifecycle: when a surface is opened, if window.Terminal is available AND the ' +
      'stream starts OK, show #xterm (hide #screen + the viewport/scrollback mode toggle, which xterm makes moot) ' +
      'and use openStream(uuid); otherwise (no Terminal, or the stream fails/501) show #screen and use the EXISTING ' +
      'plain-text poll path unchanged. On Back/teardown/visibility-hide and on switching surfaces, dispose the xterm ' +
      'stream handle (cancel reader + term.dispose) AND clear the plain-text poll timer, so neither leaks and only ' +
      'one path is active at a time. Keep the no-token / 404 / connection-lost banners working in both modes.',
  },
  {
    id: 'F3-hostclient-framing-tests',
    title: 'Host-client framing unit tests',
    detail: 'In ' + TESTS + ', add @Test cases for the PURE WebMonitorHostClient framing helpers: encodeFrame / ' +
      'encodeHello / encodeSubscribeRaw produce [u32 BE length][tag byte][LE payload] with the correct tag values ' +
      '(hello=0, subscribe_raw=31) and little-endian scalars; a FrameReader (or the equivalent decode entry point) ' +
      'splits a concatenated buffer into frames and handles a trailing PARTIAL frame (returns nothing until the ' +
      'rest arrives); decodeRawOutput(payload) extracts (sessionID, bytes) including bytes containing embedded NUL ' +
      'and ESC (0x1b). Use only the pure/static API (no live socket). Mirror the existing test style.',
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

phase('Finish')
const results = []
for (const t of TASKS) {
  const r = await agent(
    'You are a focused IMPLEMENTER finishing the web-monitor xterm.js integration in a Ghostty fork. Read the ' +
    'current htmlPage (and for F3 the WebMonitorHostClient framing helpers) first, then make exactly this change, ' +
    'nothing else.\n\nTASK ' + t.id + ': ' + t.title + '\nWHAT TO DO: ' + t.detail + '\n\n' + STATE,
    { schema: FIX_SCHEMA, phase: 'Finish', label: t.id })
  if (!r) { results.push({ task_id: t.id, done: false, skipped: true }); continue }
  results.push(r)
  log(t.id + ': ' + (r.done ? 'done' : 'NOT done') + ' scope_ok=' + r.scope_ok)
}
const failures = results.filter(function (r) { return !r.done || r.scope_ok === false })
return {
  status: failures.length === 0 ? 'ALL_APPLIED' : 'PARTIAL',
  applied: results.filter(function (r) { return r.done }).map(function (r) { return r.task_id }),
  failures: failures.map(function (r) { return r.task_id }),
  results: results,
}

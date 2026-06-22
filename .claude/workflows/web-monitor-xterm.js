export const meta = {
  name: 'web-monitor-xterm',
  description: 'Phase 2b (Swift/JS): a host-protocol client that subscribes to raw_output, a streaming /stream HTTP route, vendored xterm.js served + rendered in the browser (color + scrollback + live), with the plain-text poll kept as fallback. GUI-only. Implement-only; human builds/tests/deploys.',
  phases: [{ title: 'Xterm', detail: 'sequential: assets, host-client, stream route, page, tests' }],
}

const REPO = '/Users/ramon/git/ghostty'
const SRV = 'macos/Sources/Features/WebMonitor/WebMonitorServer.swift'
const HC = 'macos/Sources/Features/WebMonitor/WebMonitorHostClient.swift (NEW)'
const TESTS = 'macos/Tests/WebMonitor/WebMonitorServerTests.swift'
const CFG = 'macos/Sources/Ghostty/Ghostty.Config.swift'
const PBX = 'macos/Ghostty.xcodeproj/project.pbxproj'

const WIRE = [
  'HOST WIRE FORMAT (verified in src/host/protocol.zig — read it to confirm the exact tag byte values):',
  '- A frame on the socket is: [u32 LENGTH, BIG-ENDIAN][1 byte TAG][payload of (LENGTH-1) bytes]. LENGTH counts',
  '  the tag byte + payload. Read 4 BE bytes, then read LENGTH bytes; byte[0]=tag, byte[1..]=payload.',
  '- Payload SCALARS are LITTLE-ENDIAN (writeInt uses .little). Byte-slices are encoded as [u32 LE length][bytes]',
  '  (writeBytes/readBytes).',
  '- FrameType is a u8 enum; the tag values are the enum ordinal. READ THE ENUM to get exact values for: hello,',
  '  hello_ack, subscribe_raw, raw_output (subscribe_raw/raw_output are the LAST two, appended in Phase 2a).',
  '- Hello payload: u16 LE major, u16 LE minor, then writeBytes(identity_bundle_id) (may be empty). HelloAck same',
  '  shape (major, minor, ...). PROTOCOL_VERSION_MAJOR is 1.',
  '- subscribe_raw payload: u64 LE session_id.',
  '- raw_output payload: u64 LE session_id, then [u32 LE len][bytes] (the raw PTY bytes).',
  '- Handshake order required by the host: connect -> send Hello -> read HelloAck (check major matches) -> send',
  '  subscribe_raw{session_id} -> read a stream of raw_output frames (first the ring-buffer replay, then live).',
].join('\n')

const RULES = [
  'SCOPE LOCK — only these files:',
  '  - ' + SRV + '  (asset routes, streaming response, /stream route, xterm.js page)',
  '  - ' + HC + '  (the Swift host-protocol client)',
  '  - ' + TESTS + '  (framing + route tests)',
  '  - ' + CFG + '  (add a ptyHost getter if the socket path is not already exposed)',
  '  - ' + PBX + '  (iOS-target exclusion for the NEW .swift file + the vendor/*.js,*.css; ensure the vendor',
  '    files are in the macOS app bundle as resources — verify with the built .app/Contents/Resources)',
  '  - the already-vendored macos/Sources/Features/WebMonitor/vendor/xterm.js + xterm.css (DO NOT edit their contents)',
  'Touch NOTHING else (no src/**, no host, no .claude). GUI-only. Keep XSS-safety (textContent for untrusted data;',
  'xterm.js renders the byte stream itself). All ghostty_surface_* / AppKit access stays on the main thread, no',
  'surface pointer across the hop. Do NOT run builds/tests, commit, or push. Read first; report before/after hunks.',
].join('\n')

const TASKS = [
  {
    id: 'X1-serve-xterm-assets',
    title: 'Serve vendored xterm.js + xterm.css; bundle them',
    detail: 'Add routes GET /xterm.js and GET /xterm.css that return the vendored files (Content-Type ' +
      'application/javascript and text/css). Read them from the app bundle (Bundle.main) — ensure the vendor files ' +
      'are copied into the macOS app bundle as resources (the Sources group is a synchronized root group, which ' +
      'usually auto-includes them; VERIFY and, if needed, add explicit resource membership in project.pbxproj — and ' +
      'add the vendor/*.js,*.css to the iOS-target exclusion set like WebMonitorServer.swift so iOS does not try to ' +
      'bundle them). These two asset routes accept the token via ?token= (like GET /), since <script>/<link> tags ' +
      'cannot send the X-Ghostty-Token header; every OTHER non-bootstrap route still requires the header. Note this ' +
      'allowance in the security comment.',
  },
  {
    id: 'X2-host-client',
    title: 'Swift host-protocol client (subscribe to raw_output)',
    detail: 'NEW file ' + HC + ': a WebMonitorHostClient that connects to the pty-host UNIX socket and streams a ' +
      'session’s raw PTY bytes. Use a POSIX AF_UNIX socket (socket/connect/read/write) on a dedicated background ' +
      'thread/queue (simplest + reliable for AF_UNIX). API: init(socketPath:, sessionID: UInt64, onBytes: (Data)->Void, ' +
      'onClose: ()->Void); start() does the handshake (send Hello, read HelloAck, verify major), sends subscribe_raw, ' +
      'then loops reading raw_output frames and calling onBytes with the raw bytes; stop() closes the socket. ' +
      'Implement PURE, UNIT-TESTABLE framing helpers: encodeFrame(tag,payload), a FrameReader that yields complete ' +
      'frames from accumulated Data (4-byte BE length + tag + payload), encodeHello(), encodeSubscribeRaw(sessionID), ' +
      'decodeRawOutput(payload)->(sessionID,bytes). Get the exact tag byte values + layouts from protocol.zig.\n\n' + WIRE,
  },
  {
    id: 'X3-stream-route',
    title: 'Streaming /stream route in the server',
    detail: 'Add a STREAMING response mode to the NWConnection server (today it is one-shot send-then-close): write ' +
      'the HTTP status + headers (Content-Type: application/octet-stream, Connection: close, no Content-Length / or ' +
      'chunked), then keep writing raw byte chunks as they arrive until the peer disconnects or the source closes. ' +
      'Route GET /api/surface/{uuid}/stream (token via header, like other /api/*): on the main thread resolve ' +
      'uuid -> SurfaceView -> session id via ghostty_surface_session_id(view.surface); read the pty-host socket path ' +
      '(Ghostty.Config ptyHost getter — add it if missing; if empty -> 501/Not Implemented so the page falls back). ' +
      'Open a WebMonitorHostClient(socketPath, sessionID); pipe its onBytes to the NWConnection as stream chunks; on ' +
      'NWConnection cancel/disconnect, stop the host client (and vice versa). Bound/clean up resources (this is a ' +
      'long-lived connection — exempt it from the absolute idle/deadline watchdog, or refresh it while bytes flow). ' +
      'Keep the existing GET /screen plain-text route intact as the fallback.',
  },
  {
    id: 'X4-xterm-page',
    title: 'Render the stream with xterm.js (fallback to plain text)',
    detail: 'In the embedded htmlPage: load <link rel=stylesheet href="/xterm.css?token=..."> and ' +
      '<script src="/xterm.js?token=..."> (append the token). When a surface is opened: create an xterm.js Terminal ' +
      'in a container div, then fetch("/api/surface/{uuid}/stream", {headers:{X-Ghostty-Token}}) and pump ' +
      'response.body.getReader() chunks into term.write(chunk) (Uint8Array) — color + scrollback + live come for ' +
      'free. If the stream request fails or returns 501 (no pty-host), FALL BACK to the existing plain-text ' +
      'viewport/scrollback poll into a <pre> (keep that code path). Input stays exactly as today (text field + ' +
      'Enter/quick-keys/digits/arrows POST to /input as key events) — do NOT wire xterm.js stdin. Show ' +
      'connection-lost/closed banners on stream end/error (reuse the existing banner logic). Dispose the Terminal + ' +
      'cancel the stream reader on Back/teardown so nothing leaks. Keep font-size control (xterm option) if easy.',
  },
  {
    id: 'X5-tests',
    title: 'Tests for framing + routes',
    detail: 'Add @Test cases (pure, no live socket): host-client framing — encodeHello/encodeSubscribeRaw produce ' +
      'the right [BE length][tag][LE payload]; FrameReader splits a buffer into frames incl. partial reads + a ' +
      'trailing partial; decodeRawOutput extracts (sessionID, bytes) incl. bytes with embedded NUL/ESC; tag values ' +
      'match protocol.zig. And decideRoute (or the route table) cases for GET /xterm.js + /xterm.css (token via ' +
      'query allowed) and GET /api/surface/{uuid}/stream (header token; unknown uuid -> 404).',
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

phase('Xterm')
const results = []
for (const t of TASKS) {
  const r = await agent(
    'You are a careful IMPLEMENTER doing ONE part of the web-monitor xterm.js upgrade in a Ghostty fork. Read the ' +
    'named code first (esp. src/host/protocol.zig for the wire format/tag values, and the existing WebMonitorServer ' +
    'routing/send()), then make exactly this change (and its tests), nothing else.\n\nTASK ' + t.id + ': ' + t.title +
    '\nWHAT TO DO: ' + t.detail + '\n\n' + RULES,
    { schema: FIX_SCHEMA, phase: 'Xterm', label: t.id })
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

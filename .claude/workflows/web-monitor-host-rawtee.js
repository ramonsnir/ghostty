export const meta = {
  name: 'web-monitor-host-rawtee',
  description: 'Phase 2a (host Zig): add a raw-PTY-output tee + per-session ring buffer + two additive protocol frames (subscribe_raw / raw_output) + Server raw-subscriber routing + host tests, so the web monitor can later stream raw bytes to xterm.js for color+history+live. Crash-safe, additive, .exec byte-unchanged. Implement-only; the human runs zig build/tests.',
  phases: [{ title: 'HostTee', detail: 'sequential edits across protocol/Termio/Session/Server/test' }],
}

const REPO = '/Users/ramon/git/ghostty'

const ALLOWLIST = [
  'src/host/protocol.zig      (two additive frames + minor version bump + crash-safe decode)',
  'src/termio/Termio.zig      (ONE additive nullable output-observer hook; nothing else)',
  'src/host/Session.zig       (per-session ring buffer; set the observer; broadcast raw_output)',
  'src/host/Server.zig        (subscribe_raw handler: register raw subscriber + replay + route)',
  'src/host/test.zig          (tests for the above)',
]
const ALLOWLIST_TEXT = ALLOWLIST.map(function (f) { return '  - ' + f }).join('\n')

const CONTEXT = [
  'GOAL: let the web monitor (later, Phase 2b) receive a session’s RAW PTY output bytes from the host, so a',
  'browser xterm.js can render color + scrollback + live updates under the pty-host .client backend (the .client',
  'screen mirror is viewport-only and colorless, so this MUST come from the host, which owns emulation).',
  '',
  'THE TEE POINT (verified): src/termio/Termio.zig:718 `pub fn processOutput(buf)` -> processOutputLocked ->',
  'terminal_stream.nextSlice(buf). `buf` is the raw PTY bytes BEFORE emulation. The host’s Session owns this',
  'Termio (Session.zig:112 `io: termio.Termio`).',
  '',
  'DESIGN (implement exactly this):',
  '1) Termio.zig — add ONE additive, optional observer, e.g.:',
  '     output_observer: ?*const fn (ctx: *anyopaque, buf: []const u8) void = null,',
  '     output_observer_ctx: ?*anyopaque = null,',
  '   In processOutputLocked, AFTER feeding the stream (or before — but unconditionally for every buf), if',
  '   output_observer is non-null call it with the raw buf. The GUI (.exec) NEVER sets it (stays null) => zero',
  '   behavior change; do not alter any existing logic. This is the ONLY change to Termio.zig.',
  '2) protocol.zig — append two FrameType variants at the END of the enum (additive; do not reorder existing):',
  '     subscribe_raw  (client->host): payload = session_id (u64).',
  '     raw_output     (host->client): payload = session_id (u64) + length-prefixed bytes (reuse the existing',
  '       length-prefixed bytes helper; bytes is the LAST field). Add encode/decode structs mirroring the existing',
  '       frames (e.g. Input/SessionIdFrame). Decode MUST be crash-safe: bounded length (<= MAX_FRAME_LEN), checked',
  '       reads, malformed -> error.InvalidFrame (the dispatch loop turns that into a clean connection close, never',
  '       an abort). Bump PROTOCOL_VERSION_MINOR (additive; major unchanged). Add a parse/roundtrip test pattern',
  '       consistent with the other frames if the file has inline tests; otherwise leave frame tests to test.zig.',
  '3) Session.zig — add a bounded per-session ring buffer (e.g. RAW_RING_BYTES = 256*1024) of recent raw output for',
  '   replay-on-connect. Set Termio.output_observer (+ ctx = the Session) so each processOutput buf is: appended to',
  '   the ring (oldest bytes evicted past the cap) AND broadcast as a raw_output frame to this session’s RAW',
  '   subscribers. Mutate/broadcast under the SAME locking discipline the existing GridFrame broadcast uses',
  '   (SessionEntry.mutex via the Server) — match how renderTick / pushFullFrames broadcast. Keep it allocation-',
  '   light on the hot path. Provide a way for the Server to read the ring buffer snapshot for replay.',
  '4) Server.zig — a Conn can be a RAW subscriber. On a `subscribe_raw` frame: validate the session_id exists (else',
  '   ignore/clean-close per existing unknown-id handling), register the Conn in a per-session raw-subscriber list',
  '   (parallel to `subscribers`, or a flag on Conn + reuse the list), IMMEDIATELY send the ring-buffer replay as',
  '   one or more raw_output frames, then forward live raw_output frames as the Session produces them. Remove the',
  '   raw subscriber on disconnect/teardown (mirror removeSubscriber). REUSE the existing writeFramed + the',
  '   slow-subscriber discipline (the SessionEntry.mutex broadcast); a raw subscriber that wedges must not corrupt',
  '   state (same caveat as the existing subscribers — the web monitor peer is LOCAL/fast).',
  '5) test.zig — add host tests: the ring buffer (append/evict/snapshot bounded at the cap), subscribe_raw ->',
  '   replay -> live raw_output delivery to a raw subscriber, raw_output/subscribe_raw decode robustness (truncated',
  '   / oversized length -> error.InvalidFrame, no panic), and an assertion that with NO observer set the .exec',
  '   processOutput path is byte-identical (the observer is purely additive). Mirror the existing host test style.',
  '',
  'HARD RULES:',
  '- Scope-locked to the allow-list below. Touch NOTHING else (no Swift, no web monitor, no Client.zig, no',
  '  config, no .claude). This phase is HOST-ZIG ONLY.',
  ALLOWLIST_TEXT,
  '- ADDITIVE + crash-safe: do not change existing frame encodings, enum order, or .exec behavior. Every new',
  '  decode is bounded + checked (malformed -> error, caught by the dispatch loop -> clean close). The host runs',
  '  the full emulator on adversarial child output; a panic kills ALL sessions, so no @enumFromInt on untrusted',
  '  bytes, no unbounded alloc, no unchecked slice.',
  '- Do NOT run any build or test (the human runs `zig build -Demit-macos-app=false -Doptimize=ReleaseFast` and',
  '  `zig build test -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=host`). Do NOT commit/push.',
  '- Read first to ground every symbol: protocol.zig (FrameType, Input/SessionIdFrame encode/decode, MAX_FRAME_LEN,',
  '  the length-prefixed bytes helper, PROTOCOL_VERSION_*), Server.zig (SessionEntry, subscribers, addSubscriber/',
  '  removeSubscriber, writeFramed, dispatch, the GridFrame broadcast in renderTick/pushFullFrames), Session.zig',
  '  (io: termio.Termio, renderTick), Termio.zig (processOutput/processOutputLocked).',
].join('\n')

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

const TASKS = [
  { id: 'H1-protocol-frames', title: 'Add subscribe_raw + raw_output frames (additive, crash-safe) + minor bump',
    detail: 'In src/host/protocol.zig only: append `subscribe_raw` and `raw_output` to the END of FrameType; add their encode/decode structs mirroring Input/SessionIdFrame (subscribe_raw = session_id u64; raw_output = session_id u64 + trailing length-prefixed bytes). Bounded/checked decode (<= MAX_FRAME_LEN, error.InvalidFrame on bad input). Bump PROTOCOL_VERSION_MINOR. Match existing frame style exactly.' },
  { id: 'H2-termio-observer', title: 'Add the optional raw-output observer hook to Termio',
    detail: 'In src/termio/Termio.zig only: add `output_observer: ?*const fn(*anyopaque, []const u8) void = null` and `output_observer_ctx: ?*anyopaque = null`; in processOutputLocked, if the observer is set, call it with the raw buf (unconditionally per buf). No other change; GUI leaves it null so .exec is byte-unchanged.' },
  { id: 'H3-session-ring-broadcast', title: 'Session ring buffer + set observer + broadcast raw_output',
    detail: 'In src/host/Session.zig only: add a bounded (256KB) per-session raw ring buffer; set io.output_observer(+ctx=self) so each buf appends to the ring (evict past cap) and triggers a broadcast of a raw_output frame to the session’s RAW subscribers via the Server, under the same mutex discipline as the existing GridFrame broadcast. Expose a ring snapshot for replay. Hot-path-light.' },
  { id: 'H4-server-raw-subscribers', title: 'Server: subscribe_raw handler + raw-subscriber list + replay + routing',
    detail: 'In src/host/Server.zig only: handle the subscribe_raw frame (validate session_id; register the Conn as a RAW subscriber in a per-session list parallel to subscribers; immediately send the ring-buffer replay as raw_output frame(s); then route live raw_output to raw subscribers). Remove raw subscribers on disconnect/teardown (mirror removeSubscriber). Reuse writeFramed + the existing slow-subscriber/locking discipline.' },
  { id: 'H5-host-tests', title: 'Host tests for ring buffer, subscribe/replay/live, decode robustness, .exec-unchanged',
    detail: 'In src/host/test.zig only: add tests for the ring buffer (append/evict/snapshot bounded at cap), subscribe_raw -> replay -> live raw_output to a raw subscriber, subscribe_raw/raw_output decode robustness (truncated/oversized -> error.InvalidFrame, no panic), and that with no observer set the .exec processOutput path is byte-identical. Mirror existing host test style.' },
]

phase('HostTee')
const results = []
for (const t of TASKS) {
  const r = await agent(
    'You are a careful systems IMPLEMENTER touching the FROZEN-ABI pty-host (a host crash kills every live session, so be conservative). Read the named code first, then make exactly this change, nothing else.\n\nTASK ' + t.id + ': ' + t.title + '\nWHAT TO DO: ' + t.detail + '\n\n' + CONTEXT,
    { schema: FIX_SCHEMA, phase: 'HostTee', label: t.id })
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

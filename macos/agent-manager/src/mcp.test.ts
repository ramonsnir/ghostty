// Unit tests for the MCP transport pure helpers (envelope extraction + double-
// encoding parse). Run via `npm test`. The McpClient's fetch path is covered by
// extractToolText/parseToolJson (the load-bearing logic); fetch itself is the
// platform's.

import test from "node:test";
import assert from "node:assert/strict";

import {
  extractToolText,
  parseToolJson,
  parseWaitForEvent,
  coerceQueueCommands,
  McpError,
  McpClient,
} from "./mcp.js";

test("extractToolText: success returns the inner text string", () => {
  const env = {
    jsonrpc: "2.0",
    id: 1,
    result: {
      content: [{ type: "text", text: '{"surfaces":[]}' }],
      isError: false,
    },
  };
  assert.equal(extractToolText("list_surfaces", env), '{"surfaces":[]}');
});

test("parseToolJson: parses the double-encoded payload", () => {
  const text = extractToolText("list_surfaces", {
    result: { content: [{ type: "text", text: '{"surfaces":[{"id":"a"}]}' }] },
  });
  const obj = parseToolJson(text) as { surfaces: Array<{ id: string }> };
  assert.equal(obj.surfaces[0].id, "a");
});

test("extractToolText: tool error (isError) throws with the plain message", () => {
  const env = {
    result: { content: [{ type: "text", text: "unknown surface id" }], isError: true },
  };
  assert.throws(
    () => extractToolText("read_surface", env),
    (e: unknown) => e instanceof McpError && /unknown surface id/.test((e as Error).message),
  );
});

test("extractToolText: protocol error (top-level error) throws with code", () => {
  const env = { jsonrpc: "2.0", id: 3, error: { code: -32602, message: "missing or empty summary" } };
  assert.throws(
    () => extractToolText("set_surface_annotation", env),
    (e: unknown) => e instanceof McpError && (e as McpError).code === -32602,
  );
});

test("extractToolText: malformed envelope (no result/error) throws", () => {
  assert.throws(() => extractToolText("x", { jsonrpc: "2.0", id: 1 }), McpError);
});

test("extractToolText: empty content array throws", () => {
  assert.throws(
    () => extractToolText("x", { result: { content: [] } }),
    McpError,
  );
});

test("extractToolText: non-string text throws", () => {
  assert.throws(
    () => extractToolText("x", { result: { content: [{ type: "text" }] } }),
    McpError,
  );
});

test("parseToolJson: invalid JSON throws McpError", () => {
  assert.throws(() => parseToolJson("not json"), McpError);
});

// --- setAnnotation argument forwarding ---------------------------------------
// setAnnotation only forwards fields that are present (a PARTIAL MERGE on the
// Swift side). We stub the global fetch to capture the JSON-RPC body and assert
// which `arguments` fields are forwarded.

/** Replace globalThis.fetch with a recorder that returns a benign ok envelope.
 *  Returns the captured tools/call `arguments` after the awaited call. */
async function captureSetAnnotationArgs(
  id: string,
  ann: Parameters<McpClient["setAnnotation"]>[1],
): Promise<Record<string, unknown>> {
  const originalFetch = globalThis.fetch;
  let capturedArgs: Record<string, unknown> = {};
  globalThis.fetch = (async (_url: unknown, init?: { body?: string }) => {
    const parsed = JSON.parse(init?.body ?? "{}") as {
      params?: { arguments?: Record<string, unknown> };
    };
    capturedArgs = parsed.params?.arguments ?? {};
    return {
      ok: true,
      status: 200,
      json: async () => ({
        jsonrpc: "2.0",
        id: 1,
        result: { content: [{ type: "text", text: '{"ok":true}' }], isError: false },
      }),
    } as unknown as Response;
  }) as typeof fetch;
  try {
    const client = new McpClient({ url: "http://127.0.0.1:0/mcp" });
    await client.setAnnotation(id, ann);
  } finally {
    globalThis.fetch = originalFetch;
  }
  return capturedArgs;
}

test("setAnnotation: forwards summary + phase when provided", async () => {
  const args = await captureSetAnnotationArgs("s1", { summary: "Running tests", phase: "testing" });
  assert.equal(args.id, "s1");
  assert.equal(args.summary, "Running tests");
  assert.equal(args.phase, "testing");
});

test("setAnnotation: forwards needsUser false (present, not undefined)", async () => {
  const args = await captureSetAnnotationArgs("s1", { summary: "ok", needsUser: false });
  assert.equal(args.needsUser, false);
});

test("setAnnotation: omits fields that are undefined", async () => {
  const args = await captureSetAnnotationArgs("s1", { summary: "ok" });
  assert.equal(args.summary, "ok");
  assert.equal("phase" in args, false);
  assert.equal("needsUser" in args, false);
});

// --- Agent Queue wrappers: envelope / encode --------------------------------
// The queue wrappers exist server-side only in a later Swift phase; here we mock
// the transport (stub global fetch) and assert the JSON-RPC method + arguments
// encoding and the success-payload decoding.

/** Capture the JSON-RPC body of ONE awaited client call, returning the parsed
 *  {method, name, arguments}. The stub fetch returns `responseText` as the tool's
 *  double-encoded success payload. */
async function captureCall(
  responseText: string,
  run: (c: McpClient) => Promise<unknown>,
): Promise<{ method: string; name: string; args: Record<string, unknown>; result: unknown }> {
  const originalFetch = globalThis.fetch;
  let method = "";
  let name = "";
  let args: Record<string, unknown> = {};
  globalThis.fetch = (async (_url: unknown, init?: { body?: string }) => {
    const parsed = JSON.parse(init?.body ?? "{}") as {
      method?: string;
      params?: { name?: string; arguments?: Record<string, unknown> };
    };
    method = parsed.method ?? "";
    name = parsed.params?.name ?? "";
    args = parsed.params?.arguments ?? {};
    return {
      ok: true,
      status: 200,
      json: async () => ({
        jsonrpc: "2.0",
        id: 1,
        result: { content: [{ type: "text", text: responseText }], isError: false },
      }),
    } as unknown as Response;
  }) as typeof fetch;
  let result: unknown;
  try {
    const client = new McpClient({ url: "http://127.0.0.1:0/mcp" });
    result = await run(client);
  } finally {
    globalThis.fetch = originalFetch;
  }
  return { method, name, args, result };
}

test("setAnnotation: forwards queueKey/queueName/queueUrl (partial merge)", async () => {
  const args = await captureSetAnnotationArgs("s1", {
    queueKey: "PROJ-42",
    queueName: "backlog",
    queueUrl: "https://example/PROJ-42",
  });
  assert.equal(args.id, "s1");
  assert.equal(args.queueKey, "PROJ-42");
  assert.equal(args.queueName, "backlog");
  assert.equal(args.queueUrl, "https://example/PROJ-42");
});

test("setAnnotation: omits the queue fields when undefined", async () => {
  const args = await captureSetAnnotationArgs("s1", { summary: "x" });
  assert.equal("queueKey" in args, false);
  assert.equal("queueName" in args, false);
  assert.equal("queueUrl" in args, false);
  assert.equal("keep" in args, false);
});

test("setAnnotation: forwards the keep flag (true and false are both present)", async () => {
  const on = await captureSetAnnotationArgs("s1", { queueKey: "K-1", keep: true });
  assert.equal(on.keep, true);
  const off = await captureSetAnnotationArgs("s1", { queueKey: "K-1", keep: false });
  assert.equal(off.keep, false);
});

test("spawnSplitCommand: encodes the tool + forwards only present fields", async () => {
  const { method, name, args, result } = await captureCall(
    '{"id":"new-uuid","sessionId":17}',
    (c) =>
      c.spawnSplitCommand({
        targetUUID: "t1",
        direction: "down",
        command: "claude work",
        cwd: "/repo",
      }),
  );
  assert.equal(method, "tools/call");
  assert.equal(name, "spawn_split_command");
  assert.equal(args.targetUUID, "t1");
  assert.equal(args.direction, "down");
  assert.equal(args.command, "claude work");
  assert.equal(args.cwd, "/repo");
  assert.equal("firstTab" in args, false);
  assert.deepEqual(result, { id: "new-uuid", sessionId: 17 });
});

test("moveSurfaceIntoTab: encodes move_surface_into_tab + forwards source/anchor/balanced", async () => {
  const { method, name, args } = await captureCall('{"ok":true}', (c) =>
    c.moveSurfaceIntoTab({ sourceUUID: "src", targetAnchorUUID: "anchor", balanced: true }),
  );
  assert.equal(method, "tools/call");
  assert.equal(name, "move_surface_into_tab");
  assert.equal(args.sourceUUID, "src");
  assert.equal(args.targetAnchorUUID, "anchor");
  assert.equal(args.balanced, true);
  // balanced omitted when not given.
  const noBalanced = await captureCall('{"ok":true}', (c) =>
    c.moveSurfaceIntoTab({ sourceUUID: "src", targetAnchorUUID: "anchor" }),
  );
  assert.equal("balanced" in noBalanced.args, false);
});

// --- (§12 grid cap) maxCols/maxRows forwarding ------------------------------

test("spawnSplitCommand: sends maxCols/maxRows when positive", async () => {
  const { args } = await captureCall('{"id":"u","sessionId":1}', (c) =>
    c.spawnSplitCommand({
      targetUUID: "t1",
      balanced: true,
      command: "claude work",
      maxCols: 3,
      maxRows: 2,
    }),
  );
  assert.equal(args.maxCols, 3);
  assert.equal(args.maxRows, 2);
});

test("spawnSplitCommand: omits grid caps when undefined or <=0", async () => {
  // undefined ⇒ absent from the wire (pure-aspect on the GUI).
  const undef = await captureCall('{"id":"u","sessionId":1}', (c) =>
    c.spawnSplitCommand({ targetUUID: "t1", balanced: true, command: "claude work" }),
  );
  assert.equal("maxCols" in undef.args, false);
  assert.equal("maxRows" in undef.args, false);
  // 0 / negative are non-positive ⇒ also omitted (a malformed cap never forces no-cap).
  const zero = await captureCall('{"id":"u","sessionId":1}', (c) =>
    c.spawnSplitCommand({
      targetUUID: "t1",
      balanced: true,
      command: "claude work",
      maxCols: 0,
      maxRows: -1,
    }),
  );
  assert.equal("maxCols" in zero.args, false);
  assert.equal("maxRows" in zero.args, false);
});

test("moveSurfaceIntoTab: sends/omits grid caps", async () => {
  const sent = await captureCall('{"ok":true}', (c) =>
    c.moveSurfaceIntoTab({
      sourceUUID: "src",
      targetAnchorUUID: "anchor",
      balanced: true,
      maxCols: 3,
      maxRows: 2,
    }),
  );
  assert.equal(sent.args.maxCols, 3);
  assert.equal(sent.args.maxRows, 2);
  // omitted when undefined.
  const undef = await captureCall('{"ok":true}', (c) =>
    c.moveSurfaceIntoTab({ sourceUUID: "src", targetAnchorUUID: "anchor", balanced: true }),
  );
  assert.equal("maxCols" in undef.args, false);
  assert.equal("maxRows" in undef.args, false);
  // omitted when non-positive.
  const zero = await captureCall('{"ok":true}', (c) =>
    c.moveSurfaceIntoTab({
      sourceUUID: "src",
      targetAnchorUUID: "anchor",
      balanced: true,
      maxCols: 0,
      maxRows: 0,
    }),
  );
  assert.equal("maxCols" in zero.args, false);
  assert.equal("maxRows" in zero.args, false);
});

test("spawnSplitCommand: forwards the item env (GHOSTTY_ITEM_*) and omits an empty env", async () => {
  const withEnv = await captureCall('{"id":"u","sessionId":1}', (c) =>
    c.spawnSplitCommand({
      command: "claude work",
      firstTab: true,
      env: { GHOSTTY_ITEM_KEY: "K-1", GHOSTTY_ITEM_TITLE: 'a"b $x' },
    }),
  );
  assert.deepEqual(withEnv.args.env, {
    GHOSTTY_ITEM_KEY: "K-1",
    GHOSTTY_ITEM_TITLE: 'a"b $x',
  });

  // An empty env map is omitted from the wire payload entirely.
  const emptyEnv = await captureCall('{"id":"u","sessionId":1}', (c) =>
    c.spawnSplitCommand({ command: "claude", firstTab: true, env: {} }),
  );
  assert.equal("env" in emptyEnv.args, false, "empty env omitted from the payload");

  // No env arg → no env key.
  const noEnv = await captureCall('{"id":"u","sessionId":1}', (c) =>
    c.spawnSplitCommand({ command: "claude", firstTab: true }),
  );
  assert.equal("env" in noEnv.args, false, "absent env omitted from the payload");
});

test("reportQueueStatus: encodes report_queue_status + forwards the fields (maxItems null kept)", async () => {
  const { method, name, args } = await captureCall('{"ok":true}', (c) =>
    c.reportQueueStatus({
      queueName: "ExampleOS",
      present: true,
      phase: "running",
      queued: 7,
      listOk: true,
      active: 2,
      dispatched: 2,
      maxItems: null,
      concurrency: 6,
      next: [{ key: "EX-1", title: "Fix seed", url: "https://linear.app/x/EX-1" }, { key: "EX-2" }],
      running: [{ key: "EX-3", title: "Running", url: "https://linear.app/x/EX-3" }],
      heldCount: 1,
      held: [{ key: "EX-4", title: "Held one", url: "https://linear.app/x/EX-4" }],
      heroMax: 2,
      heroActive: 1,
      schedules: [],
    }),
  );
  assert.equal(method, "tools/call");
  assert.equal(name, "report_queue_status");
  assert.equal(args.queueName, "ExampleOS");
  assert.equal(args.present, true);
  assert.equal(args.phase, "running");
  assert.equal(args.queued, 7);
  assert.equal(args.active, 2);
  assert.equal(args.maxItems, null);
  assert.equal(args.concurrency, 6);
  assert.deepEqual(args.next, [{ key: "EX-1", title: "Fix seed", url: "https://linear.app/x/EX-1" }, { key: "EX-2" }]);
  assert.deepEqual(args.running, [{ key: "EX-3", title: "Running", url: "https://linear.app/x/EX-3" }]);
  assert.equal(args.heldCount, 1);
  assert.deepEqual(args.held, [{ key: "EX-4", title: "Held one", url: "https://linear.app/x/EX-4" }]);
  // (hero) the fleet-wide globals are forwarded on the wire.
  assert.equal(args.heroMax, 2);
  assert.equal(args.heroActive, 1);
});

test("reportQueueGraph: encodes report_queue_graph + forwards backlog + nodes", async () => {
  const nodes = [
    { key: "EX-1", done: false, labels: ["Design needed"], blockedBy: ["EX-9"], state: "Backlog" },
  ];
  const { method, name, args } = await captureCall('{"ok":true}', (c) =>
    c.reportQueueGraph({ queueName: "ExampleOS", present: true, backlog: 7, nodes }),
  );
  assert.equal(method, "tools/call");
  assert.equal(name, "report_queue_graph");
  assert.equal(args.queueName, "ExampleOS");
  assert.equal(args.present, true);
  assert.equal(args.backlog, 7);
  assert.deepEqual(args.nodes, nodes);
});

test("reportQueueGraph: present:false (run gone) forwards empty nodes", async () => {
  const { name, args } = await captureCall('{"ok":true}', (c) =>
    c.reportQueueGraph({ queueName: "ExampleOS", present: false, backlog: 0, nodes: [] }),
  );
  assert.equal(name, "report_queue_graph");
  assert.equal(args.present, false);
  assert.deepEqual(args.nodes, []);
});

test("sendKey: encodes the send_key tool with id + key", async () => {
  const { method, name, args } = await captureCall('{"ok":true}', (c) =>
    c.sendKey("s9", "ctrl_d"),
  );
  assert.equal(method, "tools/call");
  assert.equal(name, "send_key");
  assert.equal(args.id, "s9");
  assert.equal(args.key, "ctrl_d");
});

test("spawnSplitCommand: firstTab open omits target/direction", async () => {
  const { args, result } = await captureCall('{"id":"u","sessionId":1}', (c) =>
    c.spawnSplitCommand({ command: "claude", firstTab: true }),
  );
  assert.equal(args.firstTab, true);
  assert.equal(args.command, "claude");
  assert.equal("targetUUID" in args, false);
  assert.equal("direction" in args, false);
  assert.deepEqual(result, { id: "u", sessionId: 1 });
});

test("spawnSplitCommand: defaults sessionId to 0 when absent", async () => {
  const { result } = await captureCall('{"id":"u"}', (c) =>
    c.spawnSplitCommand({ command: "claude", firstTab: true }),
  );
  assert.deepEqual(result, { id: "u", sessionId: 0 });
});

test("spawnSplitCommand: throws McpError on a payload with no id", async () => {
  await assert.rejects(
    () => captureCall('{"sessionId":3}', (c) => c.spawnSplitCommand({ command: "x", firstTab: true })),
    McpError,
  );
});

test("forceCloseSurface: encodes the tool + id", async () => {
  const { method, name, args } = await captureCall('{"ok":true}', (c) =>
    c.forceCloseSurface("s9"),
  );
  assert.equal(method, "tools/call");
  assert.equal(name, "force_close_surface");
  assert.equal(args.id, "s9");
});

test("signalAttention: encodes the tool, id, and optional reason", async () => {
  const withReason = await captureCall('{"ok":true}', (c) =>
    c.signalAttention("s9", "agent exited early"),
  );
  assert.equal(withReason.name, "signal_attention");
  assert.equal(withReason.args.id, "s9");
  assert.equal(withReason.args.reason, "agent exited early");

  const noReason = await captureCall('{"ok":true}', (c) => c.signalAttention("s9"));
  assert.equal(noReason.args.id, "s9");
  assert.equal("reason" in noReason.args, false);
});

// --- take_queue_commands envelope (§8a) -------------------------------------
// The GUI→sidecar command drain. The tool name + the {commands:[...]} envelope
// decode, plus the tolerant coercion (malformed → []), are the load-bearing logic.

test("takeQueueCommands: calls the take_queue_commands tool and decodes the envelope", async () => {
  const { method, name, args, result } = await captureCall(
    '{"commands":[{"action":"start","template":"backlog"},{"action":"pause","run":"backlog"}]}',
    (c) => c.takeQueueCommands(),
  );
  assert.equal(method, "tools/call");
  assert.equal(name, "take_queue_commands");
  assert.deepEqual(args, {}, "no arguments");
  assert.deepEqual(result, [
    { action: "start", template: "backlog" },
    { action: "pause", run: "backlog" },
  ]);
});

test("takeQueueCommands: an empty envelope yields []", async () => {
  const { result } = await captureCall('{"commands":[]}', (c) => c.takeQueueCommands());
  assert.deepEqual(result, []);
});

test("coerceQueueCommands: tolerant of malformed shapes → []", () => {
  assert.deepEqual(coerceQueueCommands(null), []);
  assert.deepEqual(coerceQueueCommands("nope"), []);
  assert.deepEqual(coerceQueueCommands([]), [], "a bare array (no envelope) → []");
  assert.deepEqual(coerceQueueCommands({}), [], "no commands field → []");
  assert.deepEqual(coerceQueueCommands({ commands: "x" }), [], "non-array commands → []");
});

test("coerceQueueCommands: drops non-object entries and unrecognized actions, keeps valid fields", () => {
  const out = coerceQueueCommands({
    commands: [
      { action: "start", template: "t1" },
      { action: "bogus", run: "x" }, // unrecognized action dropped
      "not-an-object", // dropped
      { action: "stop" }, // valid action, no run (kept; the reducer no-ops it)
      { action: "resume", run: "r", extra: "ignored" }, // extra fields stripped
      { action: "pause", template: 9 }, // non-string template stripped, action kept
    ],
  });
  assert.deepEqual(out, [
    { action: "start", template: "t1" },
    { action: "stop" },
    { action: "resume", run: "r" },
    { action: "pause" },
  ]);
});

test("coerceQueueCommands: carries the schedule actions + scheduleId (the chokepoint whitelist)", () => {
  const out = coerceQueueCommands({
    commands: [
      { action: "pause_schedule", run: "R", scheduleId: "doc-drift" },
      { action: "resume_schedule", run: "R", scheduleId: "doc-drift" },
      { action: "run_schedule_now", run: "R", scheduleId: "backlog" },
      { action: "pause_all_schedules", run: "R" },
      { action: "pause_schedule", run: "R", scheduleId: 9 }, // non-string scheduleId dropped
    ],
  });
  assert.deepEqual(out, [
    { action: "pause_schedule", run: "R", scheduleId: "doc-drift" },
    { action: "resume_schedule", run: "R", scheduleId: "doc-drift" },
    { action: "run_schedule_now", run: "R", scheduleId: "backlog" },
    { action: "pause_all_schedules", run: "R" },
    { action: "pause_schedule", run: "R" }, // scheduleId stripped, action + run kept
  ]);
});

test("coerceQueueCommands: carries set_max_items + its string maxItems value (non-strings dropped)", () => {
  const out = coerceQueueCommands({
    commands: [
      { action: "set_max_items", run: "r", maxItems: "10" },
      { action: "set_max_items", run: "r2", maxItems: "unlimited" },
      { action: "set_max_items", run: "r3", maxItems: 7 }, // non-string maxItems dropped, action kept
      { action: "set_max_items", run: "r4" }, // no value (kept; reducer ignores)
    ],
  });
  assert.deepEqual(out, [
    { action: "set_max_items", run: "r", maxItems: "10" },
    { action: "set_max_items", run: "r2", maxItems: "unlimited" },
    { action: "set_max_items", run: "r3" },
    { action: "set_max_items", run: "r4" },
  ]);
});

test("coerceQueueCommands: carries set_concurrency + its string concurrency value (non-strings dropped)", () => {
  const out = coerceQueueCommands({
    commands: [
      { action: "set_concurrency", run: "r", concurrency: "9" },
      { action: "set_concurrency", run: "r2", concurrency: 9 }, // non-string dropped, action kept
      { action: "set_concurrency", run: "r3" }, // no value (kept; reducer ignores)
    ],
  });
  assert.deepEqual(out, [
    { action: "set_concurrency", run: "r", concurrency: "9" },
    { action: "set_concurrency", run: "r2" },
    { action: "set_concurrency", run: "r3" },
  ]);
});

test("coerceQueueCommands: carries set_keep + its key (string) and keep (boolean); bad shapes dropped", () => {
  const out = coerceQueueCommands({
    commands: [
      { action: "set_keep", run: "r", key: "K-1", keep: true },
      { action: "set_keep", run: "r", key: "K-2", keep: false },
      { action: "set_keep", run: "r", key: 5, keep: true }, // non-string key dropped, action kept
      { action: "set_keep", run: "r", key: "K-3", keep: "yes" }, // non-boolean keep dropped
    ],
  });
  assert.deepEqual(out, [
    { action: "set_keep", run: "r", key: "K-1", keep: true },
    { action: "set_keep", run: "r", key: "K-2", keep: false },
    { action: "set_keep", run: "r", keep: true }, // bad key dropped; valid keep kept
    { action: "set_keep", run: "r", key: "K-3" }, // bad keep dropped; valid key kept
  ]);
});

test("coerceQueueCommands: carries release with an optional key (key omitted = release all held)", () => {
  const out = coerceQueueCommands({
    commands: [
      { action: "release", run: "r", key: "K-1" }, // single item
      { action: "release", run: "r" },              // no key → release all held (kept)
      { action: "release", run: "r", key: 9 },      // non-string key dropped, action kept
    ],
  });
  assert.deepEqual(out, [
    { action: "release", run: "r", key: "K-1" },
    { action: "release", run: "r" },
    { action: "release", run: "r" },
  ]);
});

test("coerceQueueCommands: parses start-time params (§8b) — string values only, non-strings dropped", () => {
  const out = coerceQueueCommands({
    commands: [
      { action: "start", template: "t1", params: { project: "Acme", milestones: "Q3", n: 5 } },
      { action: "start", template: "t2", params: {} }, // empty params object → omitted
      { action: "start", template: "t3", params: "nope" }, // non-object params → omitted
    ],
  });
  assert.deepEqual(out, [
    { action: "start", template: "t1", params: { project: "Acme", milestones: "Q3" } },
    { action: "start", template: "t2" },
    { action: "start", template: "t3" },
  ]);
});

// (adopt) ⭐ The coercer gate — the single most important sidecar test for the feature: an
// `adopt`/`infer_key` the GUI emits MUST survive coercion (whitelist + carried fields) or the
// whole feature is a silent no-op.
test("coerceQueueCommands: carries adopt + run/key/surfaceUUID/url (the ⭐ §1.5 fix)", () => {
  const out = coerceQueueCommands({
    commands: [{ action: "adopt", run: "R", key: "K", surfaceUUID: "U", url: "http://x" }],
  });
  assert.deepEqual(out, [
    { action: "adopt", run: "R", key: "K", surfaceUUID: "U", url: "http://x" },
  ]);
});

test("coerceQueueCommands: keeps infer_key + run + surfaceUUID (survives coercion)", () => {
  const out = coerceQueueCommands({
    commands: [{ action: "infer_key", run: "R", surfaceUUID: "U" }],
  });
  assert.deepEqual(out, [{ action: "infer_key", run: "R", surfaceUUID: "U" }]);
});

test("coerceQueueCommands: an adopt lacking surfaceUUID is still carried (field absent → reducer no-ops)", () => {
  const out = coerceQueueCommands({
    commands: [{ action: "adopt", run: "R", key: "K" }],
  });
  // action is whitelisted so the command is kept, but surfaceUUID is absent (a non-string/empty
  // surfaceUUID is dropped) so the reducer/runner degrade it to a no-op.
  assert.deepEqual(out, [{ action: "adopt", run: "R", key: "K" }]);
  assert.equal("surfaceUUID" in out[0], false);
});

test("coerceQueueCommands: a truly unknown action is STILL dropped (whitelist only widened by the two)", () => {
  const out = coerceQueueCommands({
    commands: [
      { action: "frobnicate", run: "R", surfaceUUID: "U" },
      { action: "adopt", run: "R", key: "K", surfaceUUID: "U" },
    ],
  });
  assert.deepEqual(out, [{ action: "adopt", run: "R", key: "K", surfaceUUID: "U" }]);
});

// (hero) ⭐ The promote/demote coercer gate — the same chokepoint that made `adopt` a silent
// no-op twice. A promote/demote the GUI emits MUST survive coercion (whitelist + carried
// {run, surfaceUUID, key}) or the whole feature is a no-op.
test("coerceQueueCommands: carries promote/demote + run/surfaceUUID/key (the hero wire chokepoint)", () => {
  const out = coerceQueueCommands({
    commands: [
      { action: "promote", run: "R", surfaceUUID: "U", key: "K" },
      { action: "demote", run: "R", surfaceUUID: "U2", key: "K2" },
    ],
  });
  assert.deepEqual(out, [
    { action: "promote", run: "R", surfaceUUID: "U", key: "K" },
    { action: "demote", run: "R", surfaceUUID: "U2", key: "K2" },
  ]);
});

test("coerceQueueCommands: a promote carries even when key is absent (eject keys off surfaceUUID)", () => {
  const out = coerceQueueCommands({ commands: [{ action: "promote", run: "R", surfaceUUID: "U" }] });
  assert.deepEqual(out, [{ action: "promote", run: "R", surfaceUUID: "U" }]);
  assert.equal("key" in out[0], false);
});

// (hero) setAnnotation forwards the hero verdict under the wire arg "hero" (Bool) — the write
// side of the annotation contract that drives the GUI `queueHero` tab marker / tile.
test("setAnnotation: forwards the hero Bool (both true and false)", async () => {
  const on = await captureSetAnnotationArgs("s1", { queueKey: "K", hero: true });
  assert.equal(on.hero, true, "hero:true forwarded under the 'hero' wire arg");
  const off = await captureSetAnnotationArgs("s1", { queueKey: "K", hero: false });
  assert.equal("hero" in off, true, "hero:false is forwarded (drops the marker), not dropped");
  assert.equal(off.hero, false);
});

test("setAnnotation: omits hero when undefined", async () => {
  const args = await captureSetAnnotationArgs("s1", { summary: "x" });
  assert.equal("hero" in args, false);
});

// (adopt) The queueKeySuggested annotation: forwarded even when "" (the load-bearing sentinel).
test("setAnnotation: forwards queueKeySuggested incl. the empty-string sentinel", async () => {
  const withKey = await captureSetAnnotationArgs("s1", { queueKeySuggested: "ENG-9" });
  assert.equal(withKey.queueKeySuggested, "ENG-9");
  const empty = await captureSetAnnotationArgs("s1", { queueKeySuggested: "" });
  assert.equal("queueKeySuggested" in empty, true, "the '' sentinel is forwarded, not dropped");
  assert.equal(empty.queueKeySuggested, "");
});

test("setAnnotation: omits queueKeySuggested when undefined", async () => {
  const args = await captureSetAnnotationArgs("s1", { summary: "x" });
  assert.equal("queueKeySuggested" in args, false);
});

// (bell-attention v2 slice 4) parseWaitForEvent — the wait_for_event payload parser.
test("parseWaitForEvent: fired bell event => {id,type}", () => {
  const out = parseWaitForEvent(
    JSON.stringify({ event: { id: "abc", type: "bell" } }),
  );
  assert.deepEqual(out, { id: "abc", type: "bell" });
});

test("parseWaitForEvent: timeout ({event:null}) => null", () => {
  assert.equal(parseWaitForEvent(JSON.stringify({ event: null })), null);
});

test("parseWaitForEvent: missing/partial fields => null", () => {
  assert.equal(parseWaitForEvent(JSON.stringify({ event: { id: "x" } })), null);
  assert.equal(parseWaitForEvent(JSON.stringify({ event: { type: "bell" } })), null);
  assert.equal(parseWaitForEvent(JSON.stringify({ event: {} })), null);
  assert.equal(parseWaitForEvent(JSON.stringify({})), null);
});

test("parseWaitForEvent: non-string fields => null", () => {
  assert.equal(
    parseWaitForEvent(JSON.stringify({ event: { id: 1, type: 2 } })),
    null,
  );
});

test("parseWaitForEvent: malformed JSON => null (no throw)", () => {
  assert.equal(parseWaitForEvent("not json"), null);
  assert.equal(parseWaitForEvent(""), null);
});

// Unit tests for the MCP transport pure helpers (envelope extraction + double-
// encoding parse). Run via `npm test`. The McpClient's fetch path is covered by
// extractToolText/parseToolJson (the load-bearing logic); fetch itself is the
// platform's.

import test from "node:test";
import assert from "node:assert/strict";

import { extractToolText, parseToolJson, McpError, McpClient } from "./mcp.js";

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
// which `arguments` fields are forwarded — notably `confidence` (Phase 2.1).

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

test("setAnnotation: forwards confidence when provided", async () => {
  const args = await captureSetAnnotationArgs("s1", { suggestion: "go", confidence: 0.9 });
  assert.equal(args.id, "s1");
  assert.equal(args.suggestion, "go");
  assert.equal(args.confidence, 0.9);
});

test("setAnnotation: forwards confidence 0 (present, not undefined)", async () => {
  const args = await captureSetAnnotationArgs("s1", { suggestion: "go", confidence: 0 });
  assert.equal(args.confidence, 0);
});

test("setAnnotation: omits confidence when undefined", async () => {
  const args = await captureSetAnnotationArgs("s1", { suggestion: "go" });
  assert.equal(args.suggestion, "go");
  assert.equal("confidence" in args, false);
});

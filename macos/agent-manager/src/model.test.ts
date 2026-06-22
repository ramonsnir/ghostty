// Unit tests for the single-shot model call's RESULT-message extraction — the
// #1 SDK gotcha per the Map findings ("you MUST narrow on subtype before reading
// .result"). `summarize` takes an injectable `queryFn` seam precisely so this
// discriminator logic can be exercised WITHOUT spawning the Claude Code CLI.
// Run via `npm test`.

import test from "node:test";
import assert from "node:assert/strict";

import { summarize, SUMMARIZER_MODEL, type QueryFn } from "./model.js";

/**
 * Build a fake `queryFn` that yields the given message-like objects in order.
 * The real `Query` type extends AsyncGenerator with extra control methods a bare
 * generator lacks, so we double-cast the returned generator to satisfy the seam
 * — `summarize` only ever `for await`s it, never calls a control method.
 */
function fakeQuery(messages: unknown[]): QueryFn {
  return (() =>
    (async function* () {
      for (const m of messages) yield m;
    })()) as unknown as QueryFn;
}

/** A fake that records the params it was called with, then yields `messages`. */
function recordingQuery(
  messages: unknown[],
  capture: { params?: unknown },
): QueryFn {
  return ((params: unknown) => {
    capture.params = params;
    return (async function* () {
      for (const m of messages) yield m;
    })();
  }) as unknown as QueryFn;
}

test("summarize: success result message => returns its .result text", async () => {
  const q = fakeQuery([
    { type: "system", subtype: "init" }, // ignored non-result message
    { type: "assistant", message: {} }, // ignored per-turn message
    { type: "result", subtype: "success", result: "Running tests" },
  ]);
  const text = await summarize({ system: "S", user: "U" }, q);
  assert.equal(text, "Running tests");
});

test("summarize: error-subtype result => throws with subtype + joined errors", async () => {
  const q = fakeQuery([
    {
      type: "result",
      subtype: "error_during_execution",
      errors: ["boom", "kapow"],
    },
  ]);
  await assert.rejects(
    () => summarize({ system: "S", user: "U" }, q),
    (e: unknown) =>
      e instanceof Error &&
      /error_during_execution/.test(e.message) &&
      /boom/.test(e.message) &&
      /kapow/.test(e.message),
  );
});

test("summarize: error subtype with no errors[] still throws naming the subtype", async () => {
  const q = fakeQuery([{ type: "result", subtype: "error_max_turns" }]);
  await assert.rejects(
    () => summarize({ system: "S", user: "U" }, q),
    (e: unknown) => e instanceof Error && /error_max_turns/.test(e.message),
  );
});

test("summarize: generator ends with NO result message => throws", async () => {
  const q = fakeQuery([
    { type: "system", subtype: "init" },
    { type: "assistant", message: {} },
  ]);
  await assert.rejects(
    () => summarize({ system: "S", user: "U" }, q),
    (e: unknown) => e instanceof Error && /no result message/.test(e.message),
  );
});

test("summarize: stops at the FIRST result message (success short-circuits)", async () => {
  // A second success that would change the answer must never be reached.
  const q = fakeQuery([
    { type: "result", subtype: "success", result: "first" },
    { type: "result", subtype: "success", result: "second" },
  ]);
  assert.equal(await summarize({ system: "S", user: "U" }, q), "first");
});

test("summarize: passes the safety flags + system/user prompt through to query", async () => {
  const cap: { params?: unknown } = {};
  const q = recordingQuery(
    [{ type: "result", subtype: "success", result: "ok" }],
    cap,
  );
  await summarize({ system: "SYS", user: "USR" }, q);
  const params = cap.params as {
    prompt: string;
    options: {
      tools: unknown;
      maxTurns: number;
      model: string;
      systemPrompt: string;
      mcpServers?: unknown;
      env?: unknown;
    };
  };
  assert.equal(params.prompt, "USR");
  assert.equal(params.options.systemPrompt, "SYS");
  assert.deepEqual(params.options.tools, []); // disables ALL built-ins
  assert.equal(params.options.maxTurns, 1); // true single shot
  assert.equal(params.options.model, SUMMARIZER_MODEL);
  // No mcpServers (read-only summarizer) and no env (inherit CLI OAuth + HOME/PATH).
  assert.equal(params.options.mcpServers, undefined);
  assert.equal(params.options.env, undefined);
});

test("summarize: honors a model override", async () => {
  const cap: { params?: unknown } = {};
  const q = recordingQuery(
    [{ type: "result", subtype: "success", result: "ok" }],
    cap,
  );
  await summarize({ system: "S", user: "U", model: "claude-sonnet-4-5" }, q);
  const params = cap.params as { options: { model: string } };
  assert.equal(params.options.model, "claude-sonnet-4-5");
});

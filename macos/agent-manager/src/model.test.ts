// Unit tests for the single-shot model call's RESULT-message extraction — the
// #1 SDK gotcha per the Map findings ("you MUST narrow on subtype before reading
// .result"). `summarize` takes an injectable `queryFn` seam precisely so this
// discriminator logic can be exercised WITHOUT spawning the Claude Code CLI.
// Run via `npm test`.

import test from "node:test";
import assert from "node:assert/strict";

import {
  summarize,
  resolveClaudePath,
  SUMMARIZER_MODEL,
  type QueryFn,
} from "./model.js";

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

test("summarize: onUsage receives tokens + cost off the success result", async () => {
  const q = fakeQuery([
    {
      type: "result",
      subtype: "success",
      result: "ok",
      total_cost_usd: 0.0032886,
      usage: {
        input_tokens: 10,
        output_tokens: 141,
        cache_read_input_tokens: 25736,
        cache_creation_input_tokens: 0,
      },
    },
  ]);
  let seen: unknown;
  await summarize({ system: "S", user: "U", onUsage: (u) => (seen = u) }, q);
  assert.deepEqual(seen, {
    model: SUMMARIZER_MODEL,
    inputTokens: 10,
    outputTokens: 141,
    cacheReadTokens: 25736,
    cacheCreationTokens: 0,
    costUsd: 0.0032886,
  });
});

test("summarize: onUsage tolerates a missing usage block (defaults to 0)", async () => {
  const q = fakeQuery([{ type: "result", subtype: "success", result: "ok" }]);
  let seen: { inputTokens: number; costUsd: number } | undefined;
  await summarize(
    { system: "S", user: "U", model: "m", onUsage: (u) => (seen = u) },
    q,
  );
  assert.equal(seen?.inputTokens, 0);
  assert.equal(seen?.costUsd, 0);
});

test("summarize: onUsage is NOT called on an error result", async () => {
  const q = fakeQuery([{ type: "result", subtype: "error_max_turns" }]);
  let called = false;
  await assert.rejects(() =>
    summarize({ system: "S", user: "U", onUsage: () => (called = true) }, q),
  );
  assert.equal(called, false);
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
  assert.equal(params.options.maxTurns, 3); // headroom over the error_max_turns failure
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

// --- claude-path resolution (colleague: use the system `claude`) ------------

test("resolveClaudePath: GHOSTTY_CLAUDE_PATH (trimmed) wins when non-empty", () => {
  assert.equal(
    resolveClaudePath({ GHOSTTY_CLAUDE_PATH: "/opt/homebrew/bin/claude" }),
    "/opt/homebrew/bin/claude",
  );
  assert.equal(
    resolveClaudePath({ GHOSTTY_CLAUDE_PATH: "  /usr/local/bin/claude  " }),
    "/usr/local/bin/claude",
  );
});

test("resolveClaudePath: unset/blank => undefined (SDK falls back to PATH)", () => {
  assert.equal(resolveClaudePath({}), undefined);
  assert.equal(resolveClaudePath({ GHOSTTY_CLAUDE_PATH: "" }), undefined);
  assert.equal(resolveClaudePath({ GHOSTTY_CLAUDE_PATH: "   " }), undefined);
});

test("summarize: GHOSTTY_CLAUDE_PATH => pathToClaudeCodeExecutable passed through", async () => {
  const prev = process.env.GHOSTTY_CLAUDE_PATH;
  process.env.GHOSTTY_CLAUDE_PATH = "/opt/homebrew/bin/claude";
  try {
    const cap: { params?: unknown } = {};
    const q = recordingQuery(
      [{ type: "result", subtype: "success", result: "ok" }],
      cap,
    );
    await summarize({ system: "S", user: "U" }, q);
    const params = cap.params as {
      options: { pathToClaudeCodeExecutable?: string };
    };
    assert.equal(
      params.options.pathToClaudeCodeExecutable,
      "/opt/homebrew/bin/claude",
    );
  } finally {
    if (prev === undefined) delete process.env.GHOSTTY_CLAUDE_PATH;
    else process.env.GHOSTTY_CLAUDE_PATH = prev;
  }
});

test("summarize: no GHOSTTY_CLAUDE_PATH => pathToClaudeCodeExecutable omitted", async () => {
  const prev = process.env.GHOSTTY_CLAUDE_PATH;
  delete process.env.GHOSTTY_CLAUDE_PATH;
  try {
    const cap: { params?: unknown } = {};
    const q = recordingQuery(
      [{ type: "result", subtype: "success", result: "ok" }],
      cap,
    );
    await summarize({ system: "S", user: "U" }, q);
    const params = cap.params as {
      options: { pathToClaudeCodeExecutable?: string };
    };
    assert.equal(params.options.pathToClaudeCodeExecutable, undefined);
  } finally {
    if (prev !== undefined) process.env.GHOSTTY_CLAUDE_PATH = prev;
  }
});

// --- account routing via configDir ------------------------------------------

test("summarize: configDir sets options.env CLAUDE_CONFIG_DIR but PRESERVES process.env", async () => {
  process.env.__AM_TEST__ = "preserved";
  try {
    const cap: { params?: unknown } = {};
    const q = recordingQuery(
      [{ type: "result", subtype: "success", result: "ok" }],
      cap,
    );
    await summarize({ system: "S", user: "U", configDir: "/acct/dir" }, q);
    const params = cap.params as {
      options: { env?: Record<string, string | undefined> };
    };
    assert.ok(params.options.env, "env passed when configDir is set");
    assert.equal(params.options.env!.CLAUDE_CONFIG_DIR, "/acct/dir");
    // The rest of process.env is spread in (HOME/PATH/OAuth preserved).
    assert.equal(params.options.env!.__AM_TEST__, "preserved");
  } finally {
    delete process.env.__AM_TEST__;
  }
});

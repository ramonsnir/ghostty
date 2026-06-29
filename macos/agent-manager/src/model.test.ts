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
import {
  WarmBaseUnavailable,
  type WarmBase,
  type WarmRunRequest,
} from "./warmbase.js";
import type { HaikuUsage } from "./usage.js";

/**
 * A minimal stub `WarmBase` for the model.ts integration tests. We only need its
 * `run(req)` method (summarize calls nothing else on it), so we build an object
 * with a fake `run` and cast it to WarmBase — no real SDK / fork seam involved.
 */
function stubWarm(run: (req: WarmRunRequest) => Promise<string>): WarmBase {
  return { run } as unknown as WarmBase;
}

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
  // total_cost_usd is now IGNORED — cost is a token-bucket estimate (LOCKED #1):
  // (10*1 + 141*5 + 0*2 + 25736*0.10)/1e6 = (10 + 705 + 2573.6)/1e6 = 0.0032886
  // (numerically identical here because cacheRead dominates at $0.10/MTok).
  const q = fakeQuery([
    {
      type: "result",
      subtype: "success",
      result: "ok",
      total_cost_usd: 999, // deliberately wrong — proves it is NOT read
      usage: {
        input_tokens: 10,
        output_tokens: 141,
        cache_read_input_tokens: 25736,
        cache_creation_input_tokens: 0,
      },
    },
  ]);
  let seen: HaikuUsage | undefined;
  await summarize({ system: "S", user: "U", onUsage: (u) => (seen = u) }, q);
  const { costUsd, ...rest } = seen as HaikuUsage;
  assert.deepEqual(rest, {
    model: SUMMARIZER_MODEL,
    inputTokens: 10,
    outputTokens: 141,
    cacheReadTokens: 25736,
    cacheCreationTokens: 0,
    mode: "cold",
  });
  assert.ok(Math.abs(costUsd - 0.0032886) < 1e-9, `cost ${costUsd}`);
});

test("summarize: onUsage tolerates a missing usage block (defaults to 0)", async () => {
  const q = fakeQuery([{ type: "result", subtype: "success", result: "ok" }]);
  let seen: { inputTokens: number; costUsd: number; mode?: string } | undefined;
  await summarize(
    { system: "S", user: "U", model: "m", onUsage: (u) => (seen = u) },
    q,
  );
  assert.equal(seen?.inputTokens, 0);
  assert.equal(seen?.costUsd, 0);
  assert.equal(seen?.mode, "cold");
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

// --- warm-base integration (third-arg seam) --------------------------------

/** Count how many times the COLD queryFn is invoked, to assert no double-call. */
function countingQuery(
  messages: unknown[],
  counter: { calls: number },
): QueryFn {
  return (() => {
    counter.calls += 1;
    return (async function* () {
      for (const m of messages) yield m;
    })();
  }) as unknown as QueryFn;
}

test("summarize warm: WarmBaseUnavailable => COLD fallback returns the cold result (one cold call)", async () => {
  const counter = { calls: 0 };
  const cold = countingQuery(
    [{ type: "result", subtype: "success", result: "cold-text" }],
    counter,
  );
  const warm = stubWarm(async () => {
    throw new WarmBaseUnavailable("fork");
  });
  const text = await summarize({ system: "S", user: "U" }, cold, warm);
  assert.equal(text, "cold-text");
  assert.equal(counter.calls, 1); // exactly one cold call
});

test("summarize warm: a PLAIN Error from run() REJECTS without a cold call (no double-cost)", async () => {
  const counter = { calls: 0 };
  const cold = countingQuery(
    [{ type: "result", subtype: "success", result: "cold-text" }],
    counter,
  );
  const warm = stubWarm(async () => {
    throw new Error("overloaded");
  });
  await assert.rejects(
    () => summarize({ system: "S", user: "U" }, cold, warm),
    (e: unknown) =>
      e instanceof Error &&
      !(e instanceof WarmBaseUnavailable) &&
      /overloaded/.test(e.message),
  );
  assert.equal(counter.calls, 0); // cold queryFn NEVER invoked
});

test("summarize warm: success => returns warm text; cold queryFn never called; onUsage rides through", async () => {
  const counter = { calls: 0 };
  const cold = countingQuery(
    [{ type: "result", subtype: "success", result: "cold-text" }],
    counter,
  );
  let seen: HaikuUsage | undefined;
  const warmUsage: HaikuUsage = {
    model: SUMMARIZER_MODEL,
    inputTokens: 1,
    outputTokens: 2,
    cacheReadTokens: 3,
    cacheCreationTokens: 0,
    costUsd: 0.000017,
    mode: "warm",
  };
  const warm = stubWarm(async (req) => {
    req.onUsage?.(warmUsage);
    return "warm-text";
  });
  const text = await summarize(
    { system: "S", user: "U", onUsage: (u) => (seen = u) },
    cold,
    warm,
  );
  assert.equal(text, "warm-text");
  assert.equal(counter.calls, 0);
  assert.equal(seen?.mode, "warm");
  assert.deepEqual(seen, warmUsage);
});

test("summarize warm: req fields (model/configDir) are threaded into run()", async () => {
  let captured: WarmRunRequest | undefined;
  const warm = stubWarm(async (req) => {
    captured = req;
    return "ok";
  });
  const cold = fakeQuery([{ type: "result", subtype: "success", result: "x" }]);
  await summarize(
    { system: "SYS", user: "USR", model: "m-override", configDir: "/acct" },
    cold,
    warm,
  );
  assert.equal(captured?.system, "SYS");
  assert.equal(captured?.user, "USR");
  assert.equal(captured?.model, "m-override");
  assert.equal(captured?.configDir, "/acct");
});

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

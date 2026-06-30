// (ramon fork / Agent Queue — adopt) Tests for the PURE Haiku key-inference helpers
// (infer.ts): the bespoke prompt composer, the reply parser, and the candidate-key collector.
// No SDK / MCP / fs. Run via `npm test`.

import test from "node:test";
import assert from "node:assert/strict";

import {
  composeInferPrompt,
  parseInferredKey,
  collectCandidateKeys,
  runInferKeyWithDeps,
  type InferKeyDeps,
} from "./infer.js";
import type { Annotation, SurfaceScreen } from "../mcp.js";
import { makeQueueRun, type QueueRun } from "./runner.js";
import type { RunRegistry } from "./commands.js";
import type { StoreIO } from "./store.js";
import type { QueueTemplate } from "./types.js";

const memStore = (): StoreIO => {
  let text: string | null = null;
  return { read: () => text, write: (t) => { text = t; } };
};

function tmpl(name = "R"): QueueTemplate {
  return {
    name,
    workdir: "/repo",
    agent: { command: "claude work" },
    concurrency: 9,
    maxItems: 200,
    grid: { cols: 3, rows: 3, fill: "columns" },
    intervals: { listMs: 0, statusMs: 0 },
    provider: {
      list: { command: ["list"], keyField: "id" },
      status: { command: ["status", "{key}"], doneStates: ["done"] },
    },
    onAgentExit: "leave-and-bell",
    closeOnComplete: true,
    keepOnComplete: false,
    closeStableSeconds: 5,
    params: [],
  };
}

// --- parseInferredKey -------------------------------------------------------

test("parseInferredKey: extracts a bare key", () => {
  assert.equal(parseInferredKey("ENG-1234"), "ENG-1234");
  assert.equal(parseInferredKey("  #4567 \n"), "#4567");
});

test("parseInferredKey: takes the first token on interior whitespace", () => {
  assert.equal(parseInferredKey("ENG-1 — the login bug"), "ENG-1");
});

test("parseInferredKey: strips code fences and quotes", () => {
  assert.equal(parseInferredKey('```\n"ENG-7"\n```'), "ENG-7");
  assert.equal(parseInferredKey("`PROJ-42`"), "PROJ-42");
});

test("parseInferredKey: empty / blank => null", () => {
  assert.equal(parseInferredKey(""), null);
  assert.equal(parseInferredKey("\n\n   \n"), null);
});

test("parseInferredKey: rejects obvious junk (a long blob with no spaces)", () => {
  assert.equal(parseInferredKey("x".repeat(80)), null);
});

// --- composeInferPrompt -----------------------------------------------------

test("composeInferPrompt: includes the candidate hint when keys are present", () => {
  const { system, user } = composeInferPrompt("$ claude on ENG-1", ["ENG-1", "ENG-2"]);
  assert.match(system, /extract a single work-item/i);
  assert.match(user, /Known keys for this queue/);
  assert.match(user, /- ENG-1/);
  assert.match(user, /- ENG-2/);
});

test("composeInferPrompt: omits the hint block entirely when candidates are empty", () => {
  const { user } = composeInferPrompt("$ claude session", []);
  assert.doesNotMatch(user, /Known keys for this queue/);
  assert.match(user, /\$ claude session/, "viewport tail still present");
});

// --- collectCandidateKeys ---------------------------------------------------

function runWith(over: Partial<Pick<QueueRun, "lastGraph" | "lastListItems">>): QueueRun {
  const run = makeQueueRun(tmpl("R"), memStore());
  if (over.lastGraph !== undefined) run.lastGraph = over.lastGraph;
  if (over.lastListItems !== undefined) run.lastListItems = over.lastListItems;
  return run;
}

function regOf(run: QueueRun): RunRegistry {
  const r: RunRegistry = new Map();
  r.set(run.runName, run);
  return r;
}

test("collectCandidateKeys: empty run name => []", () => {
  const run = runWith({ lastListItems: [{ key: "A" }] });
  assert.deepEqual(collectCandidateKeys(regOf(run), ""), []);
});

test("collectCandidateKeys: unknown run => []", () => {
  const run = runWith({ lastListItems: [{ key: "A" }] });
  assert.deepEqual(collectCandidateKeys(regOf(run), "ghost"), []);
});

test("collectCandidateKeys: unions graph node keys + list item keys, deduped (insertion order)", () => {
  const run = runWith({
    lastGraph: { nodes: [
      { key: "G1", done: false, labels: [], blockedBy: [] },
      { key: "SHARED", done: false, labels: [], blockedBy: [] },
    ] },
    lastListItems: [{ key: "SHARED" }, { key: "L1" }],
  });
  assert.deepEqual(collectCandidateKeys(regOf(run), run.runName), ["G1", "SHARED", "L1"]);
});

// --- runInferKeyWithDeps ----------------------------------------------------

function makeInferDeps(over: Partial<InferKeyDeps> & { summarizeReturns?: string; summarizeThrows?: boolean }): {
  deps: InferKeyDeps;
  writes: Array<{ id: string; ann: Annotation }>;
  usage: Array<{ u: unknown; durationMs: number }>;
} {
  const writes: Array<{ id: string; ann: Annotation }> = [];
  const usage: Array<{ u: unknown; durationMs: number }> = [];
  const deps: InferKeyDeps = {
    readSurface: async (): Promise<SurfaceScreen> => ({ text: "screen tail", cols: 80, rows: 24 }),
    setAnnotation: async (id, ann) => { writes.push({ id, ann }); },
    summarize: async (req) => {
      if (over.summarizeThrows) throw new Error("model boom");
      // Exercise the usage callback like the real seam.
      req.onUsage?.({ inputTokens: 1, outputTokens: 1 });
      return over.summarizeReturns ?? "ENG-9";
    },
    candidates: () => [],
    tail: (t) => t,
    recordUsage: (u, durationMs) => { usage.push({ u, durationMs }); },
    now: () => 1000,
    errlog: () => {},
    ...over,
  };
  return { deps, writes, usage };
}

test("runInferKeyWithDeps: writes the parsed key + records usage", async () => {
  const { deps, writes, usage } = makeInferDeps({ summarizeReturns: "ENG-9" });
  await runInferKeyWithDeps("u-1", "R", deps);
  assert.deepEqual(writes, [{ id: "u-1", ann: { queueKeySuggested: "ENG-9" } }]);
  assert.equal(usage.length, 1, "usage recorded once (the issue-key-infer feature is tagged by the caller)");
});

test("runInferKeyWithDeps: writes the '' sentinel when the model yields no parseable key", async () => {
  // An empty model reply parses to null → the '' sentinel is written.
  const { deps, writes } = makeInferDeps({ summarizeReturns: "" });
  await runInferKeyWithDeps("u-2", "R", deps);
  assert.deepEqual(writes, [{ id: "u-2", ann: { queueKeySuggested: "" } }]);
});

test("runInferKeyWithDeps: ALWAYS writes the '' sentinel on a model error (modal drops spinner)", async () => {
  const { deps, writes } = makeInferDeps({ summarizeThrows: true });
  await runInferKeyWithDeps("u-1", "R", deps);
  assert.deepEqual(writes, [{ id: "u-1", ann: { queueKeySuggested: "" } }]);
});

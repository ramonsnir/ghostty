// (ramon fork / Agent Queue Supervisor) Tests for the PURE command reducer (commands.ts):
// the §8a on-demand run lifecycle applied to the active-run registry. The run FACTORY is
// injected so no template loader / fs / MCP is touched. Run via `npm test`.

import test from "node:test";
import assert from "node:assert/strict";

import { applyCommand, applyCommands, type RunFactory, type RunRegistry } from "./commands.js";
import { makeQueueRun, type QueueRun } from "./runner.js";
import type { StoreIO } from "./store.js";
import type { QueueTemplate } from "./types.js";

const memStore = (): StoreIO => {
  let text: string | null = null;
  return { read: () => text, write: (t) => { text = t; } };
};

function tmpl(name: string): QueueTemplate {
  return {
    name,
    workdir: "/repo",
    agent: { command: "claude work" },
    concurrency: 9,
    maxItems: 200,
    grid: { cols: 3, rows: 3, fill: "columns" },
    intervals: { listMs: 45000, statusMs: 20000 },
    provider: {
      list: { command: ["list"], keyField: "id" },
      status: { command: ["status", "{key}"], doneStates: ["done"] },
    },
    onAgentExit: "leave-and-bell",
    closeOnComplete: true,
    closeStableSeconds: 5,
  };
}

/** A factory mapping a template basename → a run (name = template.name). `null` for an
 *  unknown basename (a failed start). Records how many times it was invoked. */
function makeFactory(names: Record<string, string>): { factory: RunFactory; calls: string[] } {
  const calls: string[] = [];
  const factory: RunFactory = (basename: string): QueueRun | null => {
    calls.push(basename);
    const runName = names[basename];
    if (runName === undefined) return null;
    return makeQueueRun(tmpl(runName), memStore(), { templateName: basename });
  };
  return { factory, calls };
}

test("applyCommand start: creates a run keyed by its template name", () => {
  const reg: RunRegistry = new Map();
  const { factory, calls } = makeFactory({ "backlog-file": "backlog" });
  const res = applyCommand(reg, { action: "start", template: "backlog-file" }, factory);
  assert.equal(res.kind, "started");
  assert.equal(res.runName, "backlog");
  assert.equal(reg.size, 1);
  assert.ok(reg.has("backlog"), "registry keyed by run name (template.name)");
  assert.equal(reg.get("backlog")!.templateName, "backlog-file", "carries the basename for reload");
  assert.deepEqual(calls, ["backlog-file"], "factory invoked once for the start");
});

test("applyCommand start: re-start of the same template basename is an idempotent NO-OP", () => {
  const reg: RunRegistry = new Map();
  const { factory, calls } = makeFactory({ "backlog-file": "backlog" });
  applyCommand(reg, { action: "start", template: "backlog-file" }, factory);
  const first = reg.get("backlog");
  const res = applyCommand(reg, { action: "start", template: "backlog-file" }, factory);
  assert.equal(res.kind, "noop", "second start is a no-op");
  assert.equal(res.runName, "backlog");
  assert.equal(reg.size, 1, "still one run");
  assert.equal(reg.get("backlog"), first, "the existing run object is NOT recreated");
  assert.deepEqual(calls, ["backlog-file"], "factory NOT invoked again on the re-start");
});

test("applyCommand start: a name collision from a DIFFERENT basename is REJECTED (no clobber)", () => {
  const reg: RunRegistry = new Map();
  // Two distinct basenames whose templates declare the SAME run name "dup".
  const { factory, calls } = makeFactory({ "file-a": "dup", "file-b": "dup" });
  const first = applyCommand(reg, { action: "start", template: "file-a" }, factory);
  assert.equal(first.kind, "started");
  const firstRun = reg.get("dup");
  const second = applyCommand(reg, { action: "start", template: "file-b" }, factory);
  assert.equal(second.kind, "noop", "the colliding second start is rejected");
  assert.equal(reg.size, 1, "still exactly one run");
  assert.equal(reg.get("dup"), firstRun, "the first run is NOT clobbered");
  assert.equal(reg.get("dup")!.templateName, "file-a", "first run's basename preserved");
  assert.deepEqual(calls, ["file-a", "file-b"], "factory consulted for both starts");
});

test("applyCommand start: a failed factory (bad/absent template) is a no-op (no run added)", () => {
  const reg: RunRegistry = new Map();
  const { factory } = makeFactory({}); // every basename → null
  const res = applyCommand(reg, { action: "start", template: "missing" }, factory);
  assert.equal(res.kind, "noop");
  assert.equal(res.runName, undefined);
  assert.equal(reg.size, 0, "a failed start adds no run");
});

test("applyCommand start: missing template field is a no-op", () => {
  const reg: RunRegistry = new Map();
  const { factory, calls } = makeFactory({ x: "x" });
  const res = applyCommand(reg, { action: "start" }, factory);
  assert.equal(res.kind, "noop");
  assert.equal(reg.size, 0);
  assert.deepEqual(calls, [], "factory not even consulted without a template");
});

test("applyCommand pause/resume: flips the run's paused flag", () => {
  const reg: RunRegistry = new Map();
  const { factory } = makeFactory({ f: "r" });
  applyCommand(reg, { action: "start", template: "f" }, factory);
  assert.equal(reg.get("r")!.paused, false);

  const p = applyCommand(reg, { action: "pause", run: "r" }, factory);
  assert.equal(p.kind, "paused");
  assert.equal(reg.get("r")!.paused, true);

  const re = applyCommand(reg, { action: "resume", run: "r" }, factory);
  assert.equal(re.kind, "resumed");
  assert.equal(reg.get("r")!.paused, false);
});

test("applyCommand stop: sets the draining flag (run kept until the supervisor drains it)", () => {
  const reg: RunRegistry = new Map();
  const { factory } = makeFactory({ f: "r" });
  applyCommand(reg, { action: "start", template: "f" }, factory);
  const res = applyCommand(reg, { action: "stop", run: "r" }, factory);
  assert.equal(res.kind, "stopping");
  assert.equal(reg.get("r")!.draining, true);
  assert.equal(reg.size, 1, "stop does NOT remove the run itself (the supervisor does once drained)");
});

test("applyCommand abort: sets the aborting flag (run kept until the supervisor force-closes it)", () => {
  const reg: RunRegistry = new Map();
  const { factory } = makeFactory({ f: "r" });
  applyCommand(reg, { action: "start", template: "f" }, factory);
  const res = applyCommand(reg, { action: "abort", run: "r" }, factory);
  assert.equal(res.kind, "aborting");
  assert.equal(reg.get("r")!.aborting, true);
  assert.equal(reg.size, 1, "abort does NOT remove the run itself (the supervisor does this sweep)");
});

test("applyCommand: pause/resume/stop/abort for an unknown run is a no-op", () => {
  const reg: RunRegistry = new Map();
  const { factory } = makeFactory({});
  for (const action of ["pause", "resume", "stop", "abort"] as const) {
    const res = applyCommand(reg, { action, run: "ghost" }, factory);
    assert.equal(res.kind, "noop", `${action} on an unknown run is a no-op`);
  }
  assert.equal(reg.size, 0);
});

test("applyCommands: returns true when the batch changed the persisted set, false otherwise", () => {
  const reg: RunRegistry = new Map();
  const { factory } = makeFactory({ f: "r" });

  // A start is a persistence-affecting change.
  assert.equal(applyCommands(reg, [{ action: "start", template: "f" }], factory), true);
  // A pause is captured by the active-runs persistence too.
  assert.equal(applyCommands(reg, [{ action: "pause", run: "r" }], factory), true);
  // An unknown-run command changes nothing.
  assert.equal(applyCommands(reg, [{ action: "stop", run: "ghost" }], factory), false);
  // A re-start no-op changes nothing.
  assert.equal(applyCommands(reg, [{ action: "start", template: "f" }], factory), false);
});

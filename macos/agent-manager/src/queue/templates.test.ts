// Unit tests for the queue template validator + mtime-cached loader. Run via
// `npm test`. The pure validator is tested directly; the loader uses an injected fs.

import test from "node:test";
import assert from "node:assert/strict";

import {
  TEMPLATE_DEFAULTS,
  makeTemplateLoader,
  validateTemplate,
  type TemplateFs,
} from "./templates.js";

/** A minimal VALID template object (the smallest input that validates). */
function goodTemplateObj(): Record<string, unknown> {
  return {
    name: "my-team backlog",
    workdir: "~/git/ourservice",
    agent: { command: "claude \"$GHOSTTY_ITEM_KEY\"" },
    provider: {
      list: {
        command: ["sh", "-lc", "list"],
        keyField: "identifier",
        titleField: "title",
        urlField: "url",
      },
      status: { command: ["state", "{key}"], doneStates: ["done", "merged"] },
    },
  };
}

// ---------------------------------------------------------------------------
// validateTemplate — good.
// ---------------------------------------------------------------------------

test("validateTemplate: minimal good template fills defaults", () => {
  const r = validateTemplate(goodTemplateObj());
  assert.equal(r.ok, true);
  if (!r.ok) return;
  const t = r.template;
  assert.equal(t.name, "my-team backlog");
  assert.equal(t.workdir, "~/git/ourservice");
  assert.equal(t.agent.command, 'claude "$GHOSTTY_ITEM_KEY"');
  assert.equal(t.concurrency, TEMPLATE_DEFAULTS.concurrency);
  assert.equal(t.maxItems, TEMPLATE_DEFAULTS.maxItems);
  assert.deepEqual(t.grid, TEMPLATE_DEFAULTS.grid);
  assert.deepEqual(t.intervals, TEMPLATE_DEFAULTS.intervals);
  assert.equal(t.onAgentExit, "leave-and-bell");
  assert.equal(t.closeOnComplete, true);
  assert.equal(t.closeStableSeconds, TEMPLATE_DEFAULTS.closeStableSeconds);
  assert.equal(t.provider.list.keyField, "identifier");
  assert.deepEqual(t.provider.status.doneStates, ["done", "merged"]);
  assert.equal(t.provider.claim, undefined);
});

test("validateTemplate: full template with all optionals", () => {
  const obj = {
    ...goodTemplateObj(),
    concurrency: 5,
    maxItems: 200,
    grid: { cols: 3, rows: 3, fill: "columns" },
    intervals: { listMs: 30000, statusMs: 10000 },
    onAgentExit: "leave-and-bell",
    closeOnComplete: false,
    closeStableSeconds: 8,
    agent: { command: "claude", exit: { keys: ["ctrl_d"] } },
    provider: {
      list: { command: ["list"], keyField: "k" },
      status: { command: ["s", "{key}"], doneStates: ["done"] },
      claim: { command: ["claim", "{key}"] },
    },
  };
  const r = validateTemplate(obj);
  assert.equal(r.ok, true);
  if (!r.ok) return;
  assert.equal(r.template.concurrency, 5);
  assert.equal(r.template.closeOnComplete, false);
  assert.deepEqual(r.template.agent.exit, { keys: ["ctrl_d"] });
  assert.deepEqual(r.template.provider.claim, { command: ["claim", "{key}"] });
});

test("validateTemplate: concurrency is clamped to the grid cap", () => {
  const obj = {
    ...goodTemplateObj(),
    concurrency: 50,
    grid: { cols: 3, rows: 3, fill: "columns" },
  };
  const r = validateTemplate(obj);
  assert.equal(r.ok, true);
  if (r.ok) assert.equal(r.template.concurrency, 9); // clamped from 50 to 3*3
});

// ---------------------------------------------------------------------------
// validateTemplate — bad.
// ---------------------------------------------------------------------------

test("validateTemplate: non-object => error", () => {
  assert.equal(validateTemplate(null).ok, false);
  assert.equal(validateTemplate([]).ok, false);
  assert.equal(validateTemplate("x").ok, false);
});

test("validateTemplate: missing name + workdir reports both", () => {
  const obj = goodTemplateObj();
  delete obj.name;
  delete obj.workdir;
  const r = validateTemplate(obj);
  assert.equal(r.ok, false);
  if (!r.ok) {
    assert.ok(r.errors.some((e) => e.includes("name")));
    assert.ok(r.errors.some((e) => e.includes("workdir")));
  }
});

test("validateTemplate: missing agent.command => error", () => {
  const obj = goodTemplateObj();
  obj.agent = {};
  const r = validateTemplate(obj);
  assert.equal(r.ok, false);
  if (!r.ok) assert.ok(r.errors.some((e) => e.includes("agent.command")));
});

test("validateTemplate: missing provider.list.keyField => error", () => {
  const obj = goodTemplateObj();
  obj.provider = {
    list: { command: ["list"] },
    status: { command: ["s"], doneStates: ["done"] },
  };
  const r = validateTemplate(obj);
  assert.equal(r.ok, false);
  if (!r.ok) assert.ok(r.errors.some((e) => e.includes("keyField")));
});

test("validateTemplate: empty provider.status.doneStates => error", () => {
  const obj = goodTemplateObj();
  obj.provider = {
    list: { command: ["list"], keyField: "k" },
    status: { command: ["s"], doneStates: [] },
  };
  const r = validateTemplate(obj);
  assert.equal(r.ok, false);
  if (!r.ok) assert.ok(r.errors.some((e) => e.includes("doneStates")));
});

test("validateTemplate: provider command must be a non-empty array", () => {
  const obj = goodTemplateObj();
  obj.provider = {
    list: { command: [], keyField: "k" },
    status: { command: ["s"], doneStates: ["done"] },
  };
  const r = validateTemplate(obj);
  assert.equal(r.ok, false);
  if (!r.ok) assert.ok(r.errors.some((e) => e.includes("provider.list.command")));
});

test("validateTemplate: bad grid fill => error", () => {
  const obj = { ...goodTemplateObj(), grid: { cols: 3, rows: 3, fill: "diagonal" } };
  const r = validateTemplate(obj);
  assert.equal(r.ok, false);
  if (!r.ok) assert.ok(r.errors.some((e) => e.includes("grid.fill")));
});

test("validateTemplate: non-positive grid dims => error", () => {
  const obj = { ...goodTemplateObj(), grid: { cols: 0, rows: -1, fill: "columns" } };
  const r = validateTemplate(obj);
  assert.equal(r.ok, false);
  if (!r.ok) {
    assert.ok(r.errors.some((e) => e.includes("grid.cols")));
    assert.ok(r.errors.some((e) => e.includes("grid.rows")));
  }
});

test("validateTemplate: bad concurrency => error", () => {
  const obj = { ...goodTemplateObj(), concurrency: 0 };
  const r = validateTemplate(obj);
  assert.equal(r.ok, false);
  if (!r.ok) assert.ok(r.errors.some((e) => e.includes("concurrency")));
});

test("validateTemplate: bad agent.exit.keys => error", () => {
  const obj = goodTemplateObj();
  obj.agent = { command: "claude", exit: { keys: [] } };
  const r = validateTemplate(obj);
  assert.equal(r.ok, false);
  if (!r.ok) assert.ok(r.errors.some((e) => e.includes("agent.exit.keys")));
});

// ---------------------------------------------------------------------------
// makeTemplateLoader — mtime-cached file wrapper.
// ---------------------------------------------------------------------------

/** A tiny in-memory fs seam holding one path's mtime + text. */
function fakeFs(state: { mtime: number | null; text: string | null }): {
  fs: TemplateFs;
  reads: number;
} {
  let reads = 0;
  const fs: TemplateFs = {
    statMtimeMs: () => state.mtime,
    readText: () => {
      reads++;
      return state.text;
    },
  };
  return {
    fs,
    get reads() {
      return reads;
    },
  };
}

test("makeTemplateLoader: missing file => not-found error", () => {
  const { fs } = fakeFs({ mtime: null, text: null });
  const loader = makeTemplateLoader("/x/none.json", fs);
  const r = loader.load();
  assert.equal(r.ok, false);
  if (!r.ok) assert.ok(r.errors[0].includes("not found"));
});

test("makeTemplateLoader: valid file loads, then is mtime-cached", () => {
  const state = { mtime: 100, text: JSON.stringify(goodTemplateObj()) };
  const holder = fakeFs(state);
  const loader = makeTemplateLoader("/x/q.json", holder.fs);

  const r1 = loader.load();
  assert.equal(r1.ok, true);
  assert.equal(holder.reads, 1);

  // Same mtime => cached (no re-read).
  const r2 = loader.load();
  assert.equal(r2.ok, true);
  assert.equal(holder.reads, 1);

  // Bumped mtime => re-read.
  state.mtime = 200;
  loader.load();
  assert.equal(holder.reads, 2);
});

test("makeTemplateLoader: invalid JSON => error result (not a throw)", () => {
  const { fs } = fakeFs({ mtime: 1, text: "{not json" });
  const loader = makeTemplateLoader("/x/q.json", fs);
  const r = loader.load();
  assert.equal(r.ok, false);
  if (!r.ok) assert.ok(r.errors[0].includes("valid JSON"));
});

test("makeTemplateLoader: valid JSON but invalid template surfaces validator errors", () => {
  const bad = goodTemplateObj();
  delete bad.name;
  const { fs } = fakeFs({ mtime: 1, text: JSON.stringify(bad) });
  const loader = makeTemplateLoader("/x/q.json", fs);
  const r = loader.load();
  assert.equal(r.ok, false);
  if (!r.ok) assert.ok(r.errors.some((e) => e.includes("name")));
});

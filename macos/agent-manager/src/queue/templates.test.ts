// Unit tests for the queue template validator + mtime-cached loader. Run via
// `npm test`. The pure validator is tested directly; the loader uses an injected fs.

import test from "node:test";
import assert from "node:assert/strict";

import {
  TEMPLATE_DEFAULTS,
  makeTemplateLoader,
  missingRequiredParams,
  resolveMaxItemsOverride,
  resolveParamsEnv,
  validateTemplate,
  type TemplateFs,
} from "./templates.js";
import type { QueueTemplate } from "./types.js";

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
// §8b start-time params: validateTemplate(params) + resolveParamsEnv + missingRequiredParams.
// ---------------------------------------------------------------------------

test("validateTemplate: params default to [] when absent", () => {
  const r = validateTemplate(goodTemplateObj());
  assert.equal(r.ok, true);
  if (!r.ok) return;
  assert.deepEqual(r.template.params, []);
});

test("validateTemplate: a valid params array is parsed (label/default/required kept)", () => {
  const obj = goodTemplateObj();
  obj.params = [
    { name: "project", env: "LINEAR_PROJECT", label: "Project", default: "Acme Foods", required: true },
    { name: "milestones", env: "LINEAR_MILESTONES" },
  ];
  const r = validateTemplate(obj);
  assert.equal(r.ok, true);
  if (!r.ok) return;
  assert.deepEqual(r.template.params, [
    { name: "project", env: "LINEAR_PROJECT", label: "Project", default: "Acme Foods", required: true },
    { name: "milestones", env: "LINEAR_MILESTONES" },
  ]);
});

test("validateTemplate: rejects a bad env name, duplicate name, duplicate env, non-string label", () => {
  for (const params of [
    [{ name: "p", env: "1BAD" }], // env not a valid var name
    [{ name: "p", env: "A" }, { name: "p", env: "B" }], // dup name
    [{ name: "a", env: "X" }, { name: "b", env: "X" }], // dup env
    [{ name: "p", env: "X", label: 5 }], // non-string label
    [{ name: "", env: "X" }], // empty name
    [{ name: "p" }], // missing env
  ]) {
    const obj = goodTemplateObj();
    obj.params = params;
    const r = validateTemplate(obj);
    assert.equal(r.ok, false, JSON.stringify(params));
  }
});

test("resolveParamsEnv: value > default > omit-empty; undeclared keys ignored", () => {
  const t = {
    params: [
      { name: "project", env: "LINEAR_PROJECT", default: "Default Co" },
      { name: "milestones", env: "LINEAR_MILESTONES" }, // no default
      { name: "team", env: "LINEAR_TEAM", default: "" }, // empty default → omitted
    ],
  } as unknown as QueueTemplate;
  // No answers → only the param WITH a non-empty default is set.
  assert.deepEqual(resolveParamsEnv(t, {}), { LINEAR_PROJECT: "Default Co" });
  // Answers override the default; an undeclared key ("bogus") is ignored.
  assert.deepEqual(
    resolveParamsEnv(t, { project: "Acme", milestones: "Q3", bogus: "x" }),
    { LINEAR_PROJECT: "Acme", LINEAR_MILESTONES: "Q3" },
  );
});

test("missingRequiredParams: only required-and-empty (no answer + no default) are missing", () => {
  const t = {
    params: [
      { name: "project", env: "LINEAR_PROJECT", required: true }, // no default
      { name: "milestones", env: "LINEAR_MILESTONES", required: true, default: "VP" }, // has default
      { name: "extra", env: "X" }, // not required
    ],
  } as unknown as QueueTemplate;
  assert.deepEqual(missingRequiredParams(t, {}), ["project"]);
  assert.deepEqual(missingRequiredParams(t, { project: "Acme" }), []);
  assert.deepEqual(missingRequiredParams(t, { project: "" }), ["project"]);
});

// ---------------------------------------------------------------------------
// §8b maxItems-target param: validate + resolveParamsEnv skip + resolveMaxItemsOverride.
// ---------------------------------------------------------------------------

test("validateTemplate: a maxItems-target param needs no env and is parsed", () => {
  const obj = goodTemplateObj();
  obj.params = [
    { name: "project", env: "LINEAR_PROJECT", required: true },
    { name: "maxItems", target: "maxItems", label: "Max items", default: "1" },
  ];
  const r = validateTemplate(obj);
  assert.equal(r.ok, true);
  if (!r.ok) return;
  assert.deepEqual(r.template.params, [
    { name: "project", env: "LINEAR_PROJECT", required: true },
    { name: "maxItems", target: "maxItems", label: "Max items", default: "1" },
  ]);
});

test("validateTemplate: rejects bad target, a 2nd maxItems param", () => {
  for (const params of [
    [{ name: "p", target: "bogus" }], // unknown target
    [
      { name: "a", target: "maxItems" },
      { name: "b", target: "maxItems" },
    ], // two maxItems params
  ]) {
    const obj = goodTemplateObj();
    obj.params = params;
    const r = validateTemplate(obj);
    assert.equal(r.ok, false, JSON.stringify(params));
  }
});

test("resolveParamsEnv: skips a maxItems-target param (never reaches provider env)", () => {
  const t = {
    params: [
      { name: "project", env: "LINEAR_PROJECT", default: "Acme" },
      { name: "maxItems", target: "maxItems", default: "2" },
    ],
  } as unknown as QueueTemplate;
  assert.deepEqual(resolveParamsEnv(t, { maxItems: "5" }), { LINEAR_PROJECT: "Acme" });
});

test("resolveMaxItemsOverride: blank/garbage → undefined, unlimited tokens → 0, positive int → N", () => {
  const t = {
    params: [{ name: "maxItems", target: "maxItems", default: "1" }],
  } as unknown as QueueTemplate;
  // No template maxItems param → no override.
  const noParam = { params: [] } as unknown as QueueTemplate;
  assert.equal(resolveMaxItemsOverride(noParam, { maxItems: "3" }), undefined);
  // Explicit positive integers.
  assert.equal(resolveMaxItemsOverride(t, { maxItems: "2" }), 2);
  assert.equal(resolveMaxItemsOverride(t, { maxItems: "100" }), 100);
  // Unlimited tokens (case-insensitive) → 0.
  for (const v of ["0", "unlimited", "UNLIMITED", "none", "inf", "∞"]) {
    assert.equal(resolveMaxItemsOverride(t, { maxItems: v }), 0, v);
  }
  // An explicitly-CLEARED answer ("") is a real answer (?? only falls back on
  // null/undefined), so it does NOT use the param default → undefined (template default).
  assert.equal(resolveMaxItemsOverride(t, { maxItems: "" }), undefined);
  // No answer at all → the param default ("1") applies.
  assert.equal(resolveMaxItemsOverride(t, {}), 1);
  // Garbage / non-integer → undefined (caller uses template maxItems, a safe finite).
  for (const v of ["abc", "1.5", "-3", "2x"]) {
    assert.equal(resolveMaxItemsOverride(t, { maxItems: v }), undefined, v);
  }
});

test("resolveMaxItemsOverride: a blank default with a blank answer → undefined", () => {
  const t = {
    params: [{ name: "maxItems", target: "maxItems" }], // no default
  } as unknown as QueueTemplate;
  assert.equal(resolveMaxItemsOverride(t, {}), undefined);
});

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

// Unit tests for the queue template validator + mtime-cached loader. Run via
// `npm test`. The pure validator is tested directly; the loader uses an injected fs.

import test from "node:test";
import assert from "node:assert/strict";

import {
  TEMPLATE_DEFAULTS,
  makeTemplateLoader,
  missingRequiredParams,
  parseConcurrencyValue,
  parseMaxItemsValue,
  resolveMaxItemsOverride,
  resolveParamsEnv,
  runDisplayName,
  runIdentityScope,
  scopeSlug,
  validateTemplate,
  type TemplateFs,
} from "./templates.js";
import type { QueueParam, QueueTemplate } from "./types.js";

/** Validate `goodTemplateObj()` (optionally with `params`) into a typed QueueTemplate. */
function goodTemplate(params?: QueueParam[]): QueueTemplate {
  const obj = goodTemplateObj();
  if (params !== undefined) obj.params = params;
  const r = validateTemplate(obj);
  if (!r.ok) throw new Error(`bad template: ${r.errors.join("; ")}`);
  return r.template;
}

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
// provider.graph (backlog board) — optional; same shape as claim.
// ---------------------------------------------------------------------------

test("validateTemplate: provider.graph is optional (absent => undefined)", () => {
  const r = validateTemplate(goodTemplateObj());
  assert.equal(r.ok, true);
  if (!r.ok) return;
  assert.equal(r.template.provider.graph, undefined);
});

test("validateTemplate: a valid provider.graph {command} is parsed", () => {
  const obj = goodTemplateObj();
  (obj.provider as Record<string, unknown>).graph = { command: ["python3", "graph.py"] };
  const r = validateTemplate(obj);
  assert.equal(r.ok, true);
  if (!r.ok) return;
  assert.deepEqual(r.template.provider.graph, { command: ["python3", "graph.py"] });
});

test("validateTemplate: a malformed provider.graph is rejected (not silently dropped)", () => {
  for (const graph of [{}, { command: [] }, { command: "x" }, 5, []]) {
    const obj = goodTemplateObj();
    (obj.provider as Record<string, unknown>).graph = graph;
    assert.equal(validateTemplate(obj).ok, false, JSON.stringify(graph));
  }
});

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

test("validateTemplate: an optional valuesCommand argv is parsed; a malformed one is rejected", () => {
  const ok = goodTemplateObj();
  ok.params = [
    { name: "project", env: "LINEAR_PROJECT", valuesCommand: ["python3", "list-projects.py"] },
  ];
  const r = validateTemplate(ok);
  assert.equal(r.ok, true);
  if (r.ok) {
    assert.deepEqual(r.template.params[0].valuesCommand, ["python3", "list-projects.py"]);
  }
  for (const vc of [[], "notarray", [""], [123]]) {
    const bad = goodTemplateObj();
    bad.params = [{ name: "project", env: "LINEAR_PROJECT", valuesCommand: vc }];
    assert.equal(validateTemplate(bad).ok, false, JSON.stringify(vc));
  }
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

test("parseMaxItemsValue: unlimited tokens → null, positive int → N, blank/garbage → undefined", () => {
  // Unlimited tokens (case-insensitive, trimmed) → null (NO cap).
  for (const v of ["0", "unlimited", "UNLIMITED", "  none ", "inf", "infinity", "∞"]) {
    assert.equal(parseMaxItemsValue(v), null, `"${v}" → null (unlimited)`);
  }
  // Positive integers → the number.
  assert.equal(parseMaxItemsValue("1"), 1);
  assert.equal(parseMaxItemsValue(" 10 "), 10);
  assert.equal(parseMaxItemsValue("100"), 100);
  // Blank / garbage / non-positive-int → undefined (caller decides the fallback).
  for (const v of ["", "   ", "abc", "1.5", "-3", "2x", "NaN"]) {
    assert.equal(parseMaxItemsValue(v), undefined, `"${v}" → undefined`);
  }
});

test("parseConcurrencyValue: positive int → N, blank/garbage/zero/negative → undefined (NO unlimited)", () => {
  assert.equal(parseConcurrencyValue("1"), 1);
  assert.equal(parseConcurrencyValue(" 9 "), 9);
  assert.equal(parseConcurrencyValue("12"), 12);
  // Unlike maxItems there is NO "unlimited"/0 token — concurrency is always a finite count.
  for (const v of ["", "   ", "0", "-3", "1.5", "abc", "unlimited", "∞", "NaN"]) {
    assert.equal(parseConcurrencyValue(v), undefined, `"${v}" → undefined`);
  }
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
  // The aligned default: list every 60s, status every 30s (honored by the runner's
  // interval throttling, not just stored). Pinned so an accidental edit is caught.
  assert.deepEqual(TEMPLATE_DEFAULTS.intervals, { listMs: 60000, statusMs: 30000 });
  assert.equal(t.onAgentExit, "leave-and-bell");
  assert.equal(t.closeOnComplete, true);
  // (keep) the per-queue keep default is false (auto-close) unless the template opts in.
  assert.equal(t.keepOnComplete, false);
  assert.equal(TEMPLATE_DEFAULTS.keepOnComplete, false);
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
    keepOnComplete: true,
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
  assert.equal(r.template.keepOnComplete, true);
  assert.deepEqual(r.template.agent.exit, { keys: ["ctrl_d"] });
  assert.deepEqual(r.template.provider.claim, { command: ["claim", "{key}"] });
});

test("validateTemplate: concurrency MAY exceed one grid (multi-tab) but clamps to capPerTab*MAX_QUEUE_TABS", () => {
  // grid 3x3 = 9 per tab; ceiling = 9 * 8 (MAX_QUEUE_TABS) = 72.
  // A value between the per-tab cap and the ceiling is KEPT (panes overflow to more tabs, §12).
  const kept = validateTemplate({
    ...goodTemplateObj(),
    concurrency: 18,
    grid: { cols: 3, rows: 3, fill: "columns" },
  });
  assert.equal(kept.ok, true);
  if (kept.ok) assert.equal(kept.template.concurrency, 18); // NOT clamped to 9
  // Beyond the ceiling it clamps (a fat-finger can't open hundreds of tabs).
  const clamped = validateTemplate({
    ...goodTemplateObj(),
    concurrency: 1000,
    grid: { cols: 3, rows: 3, fill: "columns" },
  });
  assert.equal(clamped.ok, true);
  if (clamped.ok) assert.equal(clamped.template.concurrency, 72); // clamped to 9*8
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

test("validateTemplate: provider.list.heroField is CARRIED (not dropped on load)", () => {
  // Regression: the validator once dropped heroField, so the live parse never set WorkItem.hero
  // → list-marked heroes went unmarked in the waiting/held dropdowns + hero-pool dispatch.
  const obj = goodTemplateObj();
  (obj.provider as Record<string, Record<string, unknown>>).list.heroField = "hero";
  const r = validateTemplate(obj);
  assert.equal(r.ok, true);
  if (!r.ok) return;
  assert.equal(r.template.provider.list.heroField, "hero");
});

test("validateTemplate: provider.list.heroField absent => undefined (no hero flag)", () => {
  const r = validateTemplate(goodTemplateObj());
  assert.equal(r.ok, true);
  if (!r.ok) return;
  assert.equal(r.template.provider.list.heroField, undefined);
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

// ---------------------------------------------------------------------------
// (parallel runs) runDisplayName / runIdentityScope / scopeSlug — the per-scope run
// identity that lets one template run in parallel for different project/milestone tuples.
// ---------------------------------------------------------------------------

test("runDisplayName: no env params → just the template name", () => {
  assert.equal(runDisplayName(goodTemplate([])), "my-team backlog");
});

test("runDisplayName: appends each non-empty env-param VALUE (declared order), ' · '-joined", () => {
  const t = goodTemplate([
    { name: "project", env: "LINEAR_PROJECT" },
    { name: "milestone", env: "LINEAR_MILESTONE" },
  ]);
  assert.equal(
    runDisplayName(t, { project: "Acme", milestone: "v2.0" }),
    "my-team backlog · Acme · v2.0",
  );
  // A blank value (no answer, no default) is skipped; remaining values still appended.
  assert.equal(runDisplayName(t, { project: "Acme" }), "my-team backlog · Acme");
  // A param `default` is used when there is no answer.
  const t2 = goodTemplate([{ name: "project", env: "LINEAR_PROJECT", default: "Globex" }]);
  assert.equal(runDisplayName(t2), "my-team backlog · Globex");
});

test("runDisplayName: maxItems params are EXCLUDED (engine tuning, not scope)", () => {
  const t = goodTemplate([
    { name: "project", env: "LINEAR_PROJECT" },
    { name: "max", target: "maxItems" },
  ]);
  assert.equal(runDisplayName(t, { project: "Acme", max: "3" }), "my-team backlog · Acme");
});

test("runIdentityScope: same resolved env → SAME scope regardless of answer ORDER", () => {
  const t = goodTemplate([
    { name: "project", env: "LINEAR_PROJECT" },
    { name: "milestone", env: "LINEAR_MILESTONE" },
  ]);
  const s1 = runIdentityScope(t, { project: "Acme", milestone: "M1" });
  const s2 = runIdentityScope(t, { milestone: "M1", project: "Acme" });
  assert.equal(s1, s2, "order-independent (keys are sorted)");
});

test("runIdentityScope: different scope → different identity; maxItems is ignored", () => {
  const t = goodTemplate([
    { name: "project", env: "LINEAR_PROJECT" },
    { name: "max", target: "maxItems" },
  ]);
  assert.notEqual(
    runIdentityScope(t, { project: "Acme" }),
    runIdentityScope(t, { project: "Globex" }),
  );
  // maxItems does not reach the provider env, so it does NOT change the run identity.
  assert.equal(
    runIdentityScope(t, { project: "Acme", max: "1" }),
    runIdentityScope(t, { project: "Acme", max: "9" }),
  );
  // No env params (or all blank) → empty scope.
  assert.equal(runIdentityScope(goodTemplate([])), "");
});

test("scopeSlug: empty scope → '' (bare basename); non-empty → a stable filename-safe slug", () => {
  assert.equal(scopeSlug(""), "");
  const a = scopeSlug("LINEAR_PROJECT=Acme");
  assert.ok(a.length > 0 && /^[a-z0-9]+$/.test(a), "base36, filename-safe");
  assert.equal(scopeSlug("LINEAR_PROJECT=Acme"), a, "deterministic");
  assert.notEqual(scopeSlug("LINEAR_PROJECT=Globex"), a, "distinct scopes → distinct slugs");
});

// ---------------------------------------------------------------------------
// schedules — validateTemplate (shape + cron) + loader promptFile resolution.
// ---------------------------------------------------------------------------

test("validateTemplate: schedules default to [] when absent", () => {
  const r = validateTemplate(goodTemplateObj());
  assert.equal(r.ok, true);
  if (r.ok) assert.deepEqual(r.template.schedules, []);
});

test("validateTemplate: a valid inline-prompt schedule parses (cron kept, closeOnComplete defaults true)", () => {
  const obj = goodTemplateObj();
  obj.schedules = [
    { id: "doc-drift", name: "Doc drift", cron: "0 9 * * 1-5", prompt: "scan the docs" },
  ];
  const r = validateTemplate(obj);
  assert.equal(r.ok, true, JSON.stringify(r.errors));
  if (r.ok) {
    assert.equal(r.template.schedules.length, 1);
    const s = r.template.schedules[0];
    assert.equal(s.id, "doc-drift");
    assert.equal(s.name, "Doc drift");
    assert.equal(s.cron, "0 9 * * 1-5");
    assert.equal(s.prompt, "scan the docs");
    assert.equal(s.closeOnComplete, true);
  }
});

test("validateTemplate: rejects a schedule with a bad cron, missing id, or neither/both prompt sources", () => {
  const badCron = goodTemplateObj();
  badCron.schedules = [{ id: "x", cron: "0 99 * * *", prompt: "p" }];
  assert.equal(validateTemplate(badCron).ok, false);

  const noId = goodTemplateObj();
  noId.schedules = [{ cron: "0 9 * * *", prompt: "p" }];
  assert.equal(validateTemplate(noId).ok, false);

  const noPrompt = goodTemplateObj();
  noPrompt.schedules = [{ id: "x", cron: "0 9 * * *" }];
  assert.equal(validateTemplate(noPrompt).ok, false);

  const bothPrompt = goodTemplateObj();
  bothPrompt.schedules = [{ id: "x", cron: "0 9 * * *", prompt: "p", promptFile: "f.md" }];
  assert.equal(validateTemplate(bothPrompt).ok, false);

  const dupId = goodTemplateObj();
  dupId.schedules = [
    { id: "x", cron: "0 9 * * *", prompt: "a" },
    { id: "x", cron: "0 10 * * *", prompt: "b" },
  ];
  assert.equal(validateTemplate(dupId).ok, false);
});

/** A path-aware in-memory fs seam: maps absolute paths → text; mtime non-null for known
 *  paths. Used to test promptFile resolution (the loader reads the template JSON AND the
 *  resolved prompt file). */
function pathFs(files: Record<string, string>): TemplateFs {
  return {
    statMtimeMs: (p: string) => (p in files ? 1 : null),
    readText: (p: string) => (p in files ? files[p] : null),
  };
}

test("makeTemplateLoader: resolves promptFile relative to the template dir into prompt", () => {
  const obj = goodTemplateObj();
  obj.schedules = [{ id: "doc-drift", cron: "0 9 * * 1-5", promptFile: "scans/doc.md" }];
  const fs = pathFs({
    "/cfg/queues/q.json": JSON.stringify(obj),
    "/cfg/queues/scans/doc.md": "review the docs and open issues",
  });
  const loader = makeTemplateLoader("/cfg/queues/q.json", fs);
  const r = loader.load();
  assert.equal(r.ok, true, JSON.stringify(r.errors));
  if (r.ok) {
    assert.equal(r.template.schedules[0].prompt, "review the docs and open issues");
    // The ABSOLUTE resolved path is kept too, so the runner can deliver the prose by FILE
    // (GHOSTTY_SCHEDULE_PROMPT_FILE) rather than putting the whole prose on the command line.
    assert.equal(r.template.schedules[0].promptFilePath, "/cfg/queues/scans/doc.md");
  }
});

test("makeTemplateLoader: an unreadable/empty promptFile fails the load", () => {
  const obj = goodTemplateObj();
  obj.schedules = [{ id: "doc-drift", cron: "0 9 * * 1-5", promptFile: "missing.md" }];
  const fs = pathFs({ "/cfg/queues/q.json": JSON.stringify(obj) }); // no missing.md
  const loader = makeTemplateLoader("/cfg/queues/q.json", fs);
  const r = loader.load();
  assert.equal(r.ok, false);
  if (!r.ok) assert.ok(r.errors[0].includes("promptFile"));
});

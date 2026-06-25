// Unit tests for the queue provider (the genericity boundary). Run via `npm test`.
// Built-in node:test; no spawning — the exec seam is injected.

import test from "node:test";
import assert from "node:assert/strict";

import {
  KEY_PLACEHOLDER,
  DEFAULT_PROVIDER_TIMEOUT_MS,
  MAX_ENV_VALUE_LEN,
  MAX_META_ENTRIES,
  buildItemEnv,
  clampEnvValue,
  fetchList,
  fetchListResult,
  parseListOutput,
  parseStatusOutput,
  probeStatus,
  renderArgv,
  runProvider,
  sanitizeEnvSuffix,
  type Exec,
  type ExecOptions,
  type ExecResult,
} from "./provider.js";
import type {
  ProviderListSpec,
  ProviderStatusSpec,
  WorkItem,
} from "./types.js";

// ---------------------------------------------------------------------------
// renderArgv — {key} is an ARGV ELEMENT replace, never a shell splice.
// ---------------------------------------------------------------------------

test("renderArgv: replaces the {key} element with the key", () => {
  assert.deepEqual(renderArgv(["linear-state", KEY_PLACEHOLDER], "ABC-12"), [
    "linear-state",
    "ABC-12",
  ]);
});

test("renderArgv: replaces every {key} element", () => {
  assert.deepEqual(renderArgv(["x", "{key}", "y", "{key}"], "K"), [
    "x",
    "K",
    "y",
    "K",
  ]);
});

test("renderArgv: an adversarial key stays ONE argv element (no shell metachars)", () => {
  const key = '"; rm -rf / #$(whoami)`id`';
  const argv = renderArgv(["probe", KEY_PLACEHOLDER], key);
  // The whole nasty string lands as exactly one element — argv arrays run without a
  // shell, so none of these chars are ever interpreted.
  assert.equal(argv.length, 2);
  assert.equal(argv[1], key);
});

test("renderArgv: only a WHOLE {key} element is swapped (substring left alone)", () => {
  // "prefix{key}" merely CONTAINS the placeholder — no partial interpolation.
  assert.deepEqual(renderArgv(["a", "prefix{key}"], "K"), ["a", "prefix{key}"]);
});

test("renderArgv: empty command -> empty", () => {
  assert.deepEqual(renderArgv([], "K"), []);
});

// ---------------------------------------------------------------------------
// buildItemEnv — item fields become ENV VARS (never spliced into a shell line).
// ---------------------------------------------------------------------------

test("buildItemEnv: key only", () => {
  assert.deepEqual(buildItemEnv({ key: "ABC-1" }), {
    GHOSTTY_ITEM_KEY: "ABC-1",
  });
});

test("buildItemEnv: key + title + url", () => {
  assert.deepEqual(
    buildItemEnv({ key: "K", title: "Fix bug", url: "https://x/1" }),
    {
      GHOSTTY_ITEM_KEY: "K",
      GHOSTTY_ITEM_TITLE: "Fix bug",
      GHOSTTY_ITEM_URL: "https://x/1",
    },
  );
});

test("buildItemEnv: a hostile title is preserved VERBATIM as an env value", () => {
  // quotes / $ / backticks / newlines are all inert as an env VALUE — they are data,
  // not shell text. This is the injection defense: nothing here can become a
  // metacharacter in a command line.
  const title = 'a"b\'c $HOME `id` $(whoami) && rm -rf /\nsecond line';
  const env = buildItemEnv({ key: "K", title });
  assert.equal(env.GHOSTTY_ITEM_TITLE, title);
  // No new keys leaked from the nasty value.
  assert.deepEqual(Object.keys(env).sort(), [
    "GHOSTTY_ITEM_KEY",
    "GHOSTTY_ITEM_TITLE",
  ]);
});

test("buildItemEnv: meta becomes GHOSTTY_ITEM_META_* with sanitized names", () => {
  const env = buildItemEnv({
    key: "K",
    meta: { priority: "high", "team name": "core", "1st": "x" },
  });
  assert.equal(env.GHOSTTY_ITEM_META_PRIORITY, "high");
  assert.equal(env.GHOSTTY_ITEM_META_TEAM_NAME, "core");
  assert.equal(env.GHOSTTY_ITEM_META__1ST, "x"); // leading digit -> _ prefix
});

test("buildItemEnv: title/url omitted when undefined", () => {
  const env = buildItemEnv({ key: "K" });
  assert.equal("GHOSTTY_ITEM_TITLE" in env, false);
  assert.equal("GHOSTTY_ITEM_URL" in env, false);
});

test("sanitizeEnvSuffix: cases", () => {
  assert.equal(sanitizeEnvSuffix("foo"), "FOO");
  assert.equal(sanitizeEnvSuffix("foo-bar.baz"), "FOO_BAR_BAZ");
  assert.equal(sanitizeEnvSuffix("9lives"), "_9LIVES");
  assert.equal(sanitizeEnvSuffix(""), "_");
});

// ---------------------------------------------------------------------------
// buildItemEnv — defense-in-depth caps (§13): truncate long values + cap meta count.
// ---------------------------------------------------------------------------

test("clampEnvValue: truncates over-long values, passes short ones through", () => {
  assert.equal(clampEnvValue("short"), "short");
  const big = "x".repeat(MAX_ENV_VALUE_LEN + 100);
  assert.equal(clampEnvValue(big).length, MAX_ENV_VALUE_LEN);
});

test("buildItemEnv: a multi-megabyte title is TRUNCATED to MAX_ENV_VALUE_LEN (not dropped)", () => {
  const huge = "A".repeat(4 * 1024 * 1024); // ~4MB
  const env = buildItemEnv({ key: "K", title: huge });
  assert.equal(env.GHOSTTY_ITEM_TITLE.length, MAX_ENV_VALUE_LEN, "title bounded");
  assert.equal(env.GHOSTTY_ITEM_KEY, "K");
});

test("buildItemEnv: caps the META-field COUNT at MAX_META_ENTRIES (excess dropped in key order)", () => {
  const meta: Record<string, string> = {};
  for (let i = 0; i < MAX_META_ENTRIES + 50; i++) meta[`f${i}`] = String(i);
  const env = buildItemEnv({ key: "K", meta });
  const metaCount = Object.keys(env).filter((k) => k.startsWith("GHOSTTY_ITEM_META_")).length;
  assert.equal(metaCount, MAX_META_ENTRIES, "meta entries capped");
  // The canonical key var is always present + unaffected by the meta cap.
  assert.equal(env.GHOSTTY_ITEM_KEY, "K");
});

// ---------------------------------------------------------------------------
// parseListOutput — good / garbage / missing-key / empty.
// ---------------------------------------------------------------------------

const listFields: Pick<ProviderListSpec, "keyField" | "titleField" | "urlField"> = {
  keyField: "identifier",
  titleField: "title",
  urlField: "url",
};

test("parseListOutput: good array maps the fields", () => {
  const stdout = JSON.stringify([
    { identifier: "A-1", title: "First", url: "https://x/1" },
    { identifier: "A-2", title: "Second", url: "https://x/2" },
  ]);
  const items = parseListOutput(stdout, listFields);
  assert.equal(items.length, 2);
  assert.deepEqual(items[0], {
    key: "A-1",
    title: "First",
    url: "https://x/1",
  });
});

test("parseListOutput: drops items with no/empty key", () => {
  const stdout = JSON.stringify([
    { identifier: "A-1", title: "ok" },
    { title: "no key" },
    { identifier: "", title: "empty key" },
    { identifier: 42, title: "non-string key" },
    { identifier: "A-2" },
  ]);
  const items = parseListOutput(stdout, listFields);
  assert.deepEqual(
    items.map((i) => i.key),
    ["A-1", "A-2"],
  );
});

test("parseListOutput: collects unmapped scalar fields into meta", () => {
  const stdout = JSON.stringify([
    {
      identifier: "A-1",
      title: "t",
      priority: 2,
      blocked: false,
      nested: { ignored: true },
    },
  ]);
  const [item] = parseListOutput(stdout, listFields);
  assert.deepEqual(item.meta, { priority: "2", blocked: "false" });
});

test("parseListOutput: garbage / non-array / empty => []", () => {
  assert.deepEqual(parseListOutput("not json", listFields), []);
  assert.deepEqual(parseListOutput("", listFields), []);
  assert.deepEqual(parseListOutput("{}", listFields), []); // object, not array
  assert.deepEqual(parseListOutput("null", listFields), []);
  assert.deepEqual(parseListOutput("[]", listFields), []);
  assert.deepEqual(parseListOutput("42", listFields), []);
});

test("parseListOutput: title/url absent when fields not configured", () => {
  const items = parseListOutput(
    JSON.stringify([{ k: "A-1", title: "ignored" }]),
    { keyField: "k" },
  );
  assert.deepEqual(items[0], { key: "A-1", meta: { title: "ignored" } });
});

// ---------------------------------------------------------------------------
// parseStatusOutput — done / not-done / garbage => not terminal.
// ---------------------------------------------------------------------------

const doneStates = ["done", "canceled", "merged"];

test("parseStatusOutput: a done state is terminal", () => {
  assert.deepEqual(parseStatusOutput('{"state":"done"}', doneStates), {
    terminal: true,
  });
});

test("parseStatusOutput: matching is case/space-insensitive", () => {
  assert.deepEqual(parseStatusOutput('{"state":"  Merged "}', doneStates), {
    terminal: true,
  });
});

test("parseStatusOutput: a non-done state is not terminal", () => {
  assert.deepEqual(parseStatusOutput('{"state":"in-progress"}', doneStates), {
    terminal: false,
  });
});

test("parseStatusOutput: garbage / empty / missing / non-string => not terminal", () => {
  assert.deepEqual(parseStatusOutput("not json", doneStates), { terminal: false });
  assert.deepEqual(parseStatusOutput("", doneStates), { terminal: false });
  assert.deepEqual(parseStatusOutput("{}", doneStates), { terminal: false });
  assert.deepEqual(parseStatusOutput('{"state":""}', doneStates), {
    terminal: false,
  });
  assert.deepEqual(parseStatusOutput('{"state":5}', doneStates), {
    terminal: false,
  });
  assert.deepEqual(parseStatusOutput("[]", doneStates), { terminal: false });
  assert.deepEqual(parseStatusOutput("null", doneStates), { terminal: false });
});

// ---------------------------------------------------------------------------
// runProvider — the injected exec seam; never throws into the loop.
// ---------------------------------------------------------------------------

function fakeExec(result: ExecResult | Error): {
  exec: Exec;
  calls: Array<{ argv: string[]; opts: ExecOptions }>;
} {
  const calls: Array<{ argv: string[]; opts: ExecOptions }> = [];
  const exec: Exec = async (argv, opts) => {
    calls.push({ argv, opts });
    if (result instanceof Error) throw result;
    return result;
  };
  return { exec, calls };
}

test("runProvider: success returns the exec result", async () => {
  const { exec } = fakeExec({ code: 0, stdout: "[]", stderr: "" });
  const r = await runProvider(["x"], exec);
  assert.equal(r.ok, true);
  if (r.ok) assert.equal(r.result.stdout, "[]");
});

test("runProvider: default tight timeout is passed to the seam", async () => {
  const { exec, calls } = fakeExec({ code: 0, stdout: "", stderr: "" });
  await runProvider(["x"], exec);
  assert.equal(calls[0].opts.timeoutMs, DEFAULT_PROVIDER_TIMEOUT_MS);
});

test("runProvider: caller timeout overrides the default", async () => {
  const { exec, calls } = fakeExec({ code: 0, stdout: "", stderr: "" });
  await runProvider(["x"], exec, { timeoutMs: 1234 });
  assert.equal(calls[0].opts.timeoutMs, 1234);
});

test("runProvider: empty argv => skip, no exec call", async () => {
  const { exec, calls } = fakeExec({ code: 0, stdout: "", stderr: "" });
  const r = await runProvider([], exec);
  assert.equal(r.ok, false);
  assert.equal(calls.length, 0);
});

test("runProvider: non-zero exit => skip (does not throw)", async () => {
  const { exec } = fakeExec({ code: 1, stdout: "boom", stderr: "err" });
  const r = await runProvider(["x"], exec);
  assert.equal(r.ok, false);
  if (!r.ok) assert.match(r.reason, /nonzero-exit: 1/);
});

test("runProvider: exec rejection => skip (does not throw)", async () => {
  const { exec } = fakeExec(new Error("spawn ENOENT"));
  const r = await runProvider(["x"], exec);
  assert.equal(r.ok, false);
  if (!r.ok) assert.match(r.reason, /exec-failed/);
});

// ---------------------------------------------------------------------------
// probeStatus / fetchList — render + run + parse convenience.
// ---------------------------------------------------------------------------

test("probeStatus: renders {key}, runs, parses terminal", async () => {
  const spec: ProviderStatusSpec = {
    command: ["state", KEY_PLACEHOLDER],
    doneStates,
  };
  const { exec, calls } = fakeExec({
    code: 0,
    stdout: '{"state":"done"}',
    stderr: "",
  });
  const r = await probeStatus(spec, "A-1", exec);
  assert.deepEqual(r, { terminal: true });
  assert.deepEqual(calls[0].argv, ["state", "A-1"]);
});

test("probeStatus: a flaky probe (non-zero exit) => not terminal", async () => {
  const spec: ProviderStatusSpec = { command: ["state"], doneStates };
  const { exec } = fakeExec({ code: 2, stdout: "", stderr: "down" });
  assert.deepEqual(await probeStatus(spec, "A-1", exec), { terminal: false });
});

test("fetchList: success parses items", async () => {
  const spec: ProviderListSpec = {
    command: ["list"],
    keyField: "identifier",
    titleField: "title",
  };
  const { exec } = fakeExec({
    code: 0,
    stdout: JSON.stringify([{ identifier: "A-1", title: "t" }]),
    stderr: "",
  });
  const items: WorkItem[] = await fetchList(spec, exec);
  assert.deepEqual(items, [{ key: "A-1", title: "t" }]);
});

test("fetchList: a flaky list (non-zero exit) => [] (skip the tick)", async () => {
  const spec: ProviderListSpec = { command: ["list"], keyField: "k" };
  const { exec } = fakeExec({ code: 1, stdout: "", stderr: "boom" });
  assert.deepEqual(await fetchList(spec, exec), []);
});

// fetchListResult — distinguishes a SUCCESSFUL empty list from a FAILED/skip one (used by
// the dispatch-latch re-arm + the §11 health cache). A failed list must NEVER read as "empty".
test("fetchListResult: a clean empty list => {ok:true, items:[]}", async () => {
  const spec: ProviderListSpec = { command: ["list"], keyField: "k" };
  const { exec } = fakeExec({ code: 0, stdout: "[]", stderr: "" });
  assert.deepEqual(await fetchListResult(spec, exec), { ok: true, items: [] });
});

test("fetchListResult: a non-zero exit => {ok:false, items:[]} (NOT empty — never quits)", async () => {
  const spec: ProviderListSpec = { command: ["list"], keyField: "k" };
  const { exec } = fakeExec({ code: 1, stdout: "", stderr: "boom" });
  assert.deepEqual(await fetchListResult(spec, exec), { ok: false, items: [] });
});

test("fetchListResult: a spawn error => {ok:false, items:[]}", async () => {
  const spec: ProviderListSpec = { command: ["list"], keyField: "k" };
  const { exec } = fakeExec(new Error("spawn ENOENT"));
  assert.deepEqual(await fetchListResult(spec, exec), { ok: false, items: [] });
});

test("fetchListResult: success parses items with ok:true", async () => {
  const spec: ProviderListSpec = { command: ["list"], keyField: "identifier" };
  const { exec } = fakeExec({ code: 0, stdout: JSON.stringify([{ identifier: "A-1" }]), stderr: "" });
  assert.deepEqual(await fetchListResult(spec, exec), { ok: true, items: [{ key: "A-1" }] });
});

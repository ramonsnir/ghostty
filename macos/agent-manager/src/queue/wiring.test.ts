// (ramon fork / Agent Queue Supervisor) Tests for the PURE production-seam helpers in
// wiring.ts that are safely testable WITHOUT touching node:child_process / node:fs —
// today, the provider-env sanitizer (§5 "sanitized env"). The exec/fs seams themselves
// are exercised only in production (the runner tests inject fakes), so they are not
// covered here; sanitizeProviderEnv is the load-bearing security boundary that IS pure.

import test from "node:test";
import assert from "node:assert/strict";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";

import {
  sanitizeProviderEnv,
  normalizeExecCode,
  expandHome,
  shouldMigrateLegacyState,
  parseTemplatesDirs,
  resolveTemplatePath,
  loadTemplateAtPath,
  makeFileRunFactory,
  rehydrateActiveRuns,
  defaultTemplatesDir,
  activeRunsFilePath,
} from "./wiring.js";

// shouldMigrateLegacyState — the rehydrate-path decision to rename a pre-parallel
// `<basename>.state.json` to the scope-suffixed file, so lifetimeDispatched / live cap /
// records survive the upgrade instead of resetting to 0.
test("shouldMigrateLegacyState: migrates only when scoped is absent, legacy exists, paths differ", () => {
  const scoped = "/s/example.132if54.state.json";
  const legacy = "/s/example.state.json";
  // The migration case: an in-flight scoped run with no scoped file yet but a legacy one.
  assert.equal(shouldMigrateLegacyState(scoped, legacy, false, true), true);
  // Scoped file already present (already migrated / fresh scoped run) → no migration.
  assert.equal(shouldMigrateLegacyState(scoped, legacy, true, true), false);
  // No legacy file (nothing to migrate) → no migration.
  assert.equal(shouldMigrateLegacyState(scoped, legacy, false, false), false);
  // Empty-scope run: scoped path === legacy path (the bare file IS the path) → no migration.
  assert.equal(shouldMigrateLegacyState(legacy, legacy, false, true), false);
});

// expandHome — the provider-cwd `~` expansion (execFile does NOT expand `~`, so a literal
// `~/repo` cwd fails ENOENT and every provider call silently skips). §workdir.
test("expandHome: '~' and '~/x' expand to the home dir; other paths pass through", () => {
  assert.equal(expandHome("~"), homedir());
  assert.equal(expandHome("~/git/ExampleOS"), join(homedir(), "git/ExampleOS"));
  assert.equal(expandHome("/abs/path"), "/abs/path");
  assert.equal(expandHome("rel/path"), "rel/path");
  // Only a LEADING ~/ is a home ref; a mid-path ~ is left alone.
  assert.equal(expandHome("/x/~/y"), "/x/~/y");
  // A bare "~user" form is not expanded (we only handle the current user's home).
  assert.equal(expandHome("~other/x"), "~other/x");
});

test("sanitizeProviderEnv: strips the MCP token + Ghostty control vars, keeps the rest", () => {
  const base: NodeJS.ProcessEnv = {
    PATH: "/usr/bin",
    HOME: "/home/me",
    GHOSTTY_MCP_TOKEN: "secret-shell-exec-credential",
    GHOSTTY_MCP_URL: "http://127.0.0.1:8765/mcp",
    GHOSTTY_AGENT_MANAGER: "1",
    GHOSTTY_AGENT_QUEUE: "1",
    GHOSTTY_AGENT_QUEUE_MAX_TOTAL: "8",
  };
  const out = sanitizeProviderEnv(base);
  // Kept: ordinary inherited env.
  assert.equal(out.PATH, "/usr/bin");
  assert.equal(out.HOME, "/home/me");
  // Stripped: every Ghostty MCP credential + agent control flag (exact + prefix).
  assert.equal("GHOSTTY_MCP_TOKEN" in out, false, "MCP token NOT leaked to a provider");
  assert.equal("GHOSTTY_MCP_URL" in out, false);
  assert.equal("GHOSTTY_AGENT_MANAGER" in out, false);
  assert.equal("GHOSTTY_AGENT_QUEUE" in out, false);
  assert.equal("GHOSTTY_AGENT_QUEUE_MAX_TOTAL" in out, false);
});

test("sanitizeProviderEnv: overlays the caller's extra env after stripping", () => {
  const out = sanitizeProviderEnv(
    { PATH: "/usr/bin", GHOSTTY_MCP_TOKEN: "x" },
    { FOO: "bar" },
  );
  assert.equal(out.PATH, "/usr/bin");
  assert.equal(out.FOO, "bar");
  assert.equal("GHOSTTY_MCP_TOKEN" in out, false);
});

test("sanitizeProviderEnv: drops undefined-valued env entries (NodeJS.ProcessEnv shape)", () => {
  const base: NodeJS.ProcessEnv = { A: "1", B: undefined };
  const out = sanitizeProviderEnv(base);
  assert.equal(out.A, "1");
  assert.equal("B" in out, false);
});

// normalizeExecCode — the realExec error→exit-code mapping (§13: every failure must
// surface as a NON-ZERO code so runProvider treats it as a skip, never as success).
test("normalizeExecCode: a numeric non-zero exit code passes through", () => {
  assert.equal(normalizeExecCode({ code: 2 }), 2);
  assert.equal(normalizeExecCode({ code: 127 }), 127);
});

test("normalizeExecCode: a string spawn/timeout code (ETIMEDOUT/ENOENT) → generic non-zero 1", () => {
  assert.equal(normalizeExecCode({ code: "ETIMEDOUT" }), 1);
  assert.equal(normalizeExecCode({ code: "ENOENT" }), 1);
});

test("normalizeExecCode: a (degenerate) numeric 0 on the error path is coerced to non-zero", () => {
  // A "failure with code 0" must never read as success.
  assert.equal(normalizeExecCode({ code: 0 }), 1);
});

test("normalizeExecCode: a missing/absent code or null err → generic non-zero 1", () => {
  assert.equal(normalizeExecCode({}), 1);
  assert.equal(normalizeExecCode(null), 1);
  assert.equal(normalizeExecCode(new Error("boom")), 1);
});

// ===========================================================================
// (shared templates) multi-location search path + {templateDir} loader + rehydrate.
// ===========================================================================

/** Write a minimal VALID template JSON at `dir/<basename>.json`. `command` (list) may embed a
 *  `{templateDir}` token so a test can assert substitution. Returns the file path. */
function writeTemplate(
  dir: string,
  basename: string,
  over: { workdir?: string; listCommand?: string[] } = {},
): string {
  mkdirSync(dir, { recursive: true });
  const obj = {
    name: `${basename}-name`,
    workdir: over.workdir ?? "/repo",
    agent: { command: "claude work" },
    provider: {
      list: { command: over.listCommand ?? ["list"], keyField: "id" },
      status: { command: ["status", "{key}"], doneStates: ["done"] },
    },
  };
  const path = join(dir, `${basename}.json`);
  writeFileSync(path, JSON.stringify(obj), "utf8");
  return path;
}

function tmpTree(): string {
  return mkdtempSync(join(tmpdir(), "ghostty-queues-"));
}

// --- parseTemplatesDirs (contract item 4) ----------------------------------

test("parseTemplatesDirs: plural GHOSTTY_AGENT_QUEUE_TEMPLATES_DIRS split on newline, empties dropped", () => {
  const env = { GHOSTTY_AGENT_QUEUE_TEMPLATES_DIRS: "/a/b\n\n  /c/d  \n" } as NodeJS.ProcessEnv;
  assert.deepEqual(parseTemplatesDirs(env), ["/a/b", "/c/d"]);
});

test("parseTemplatesDirs: singular legacy env is a one-element fallback when plural absent", () => {
  const env = { GHOSTTY_AGENT_QUEUE_TEMPLATES_DIR: "/legacy/dir" } as NodeJS.ProcessEnv;
  assert.deepEqual(parseTemplatesDirs(env), ["/legacy/dir"]);
});

test("parseTemplatesDirs: plural wins over the legacy singular", () => {
  const env = {
    GHOSTTY_AGENT_QUEUE_TEMPLATES_DIRS: "/plural/x\n/plural/y",
    GHOSTTY_AGENT_QUEUE_TEMPLATES_DIR: "/legacy/dir",
  } as NodeJS.ProcessEnv;
  assert.deepEqual(parseTemplatesDirs(env), ["/plural/x", "/plural/y"]);
});

test("parseTemplatesDirs: both absent (or blank) → [defaultTemplatesDir(home)]", () => {
  assert.deepEqual(parseTemplatesDirs({} as NodeJS.ProcessEnv, "/home/me"), [
    defaultTemplatesDir("/home/me"),
  ]);
  // A plural that is all-blank lines also falls back to the default.
  assert.deepEqual(
    parseTemplatesDirs({ GHOSTTY_AGENT_QUEUE_TEMPLATES_DIRS: "\n  \n" } as NodeJS.ProcessEnv, "/home/me"),
    [defaultTemplatesDir("/home/me")],
  );
});

// --- resolveTemplatePath (first-in-search-order wins, §1) -------------------

test("resolveTemplatePath: the FIRST search dir containing <b>.json wins", () => {
  const root = tmpTree();
  try {
    const dirA = join(root, "a");
    const dirB = join(root, "b");
    const pathA = writeTemplate(dirA, "dup");
    writeTemplate(dirB, "dup");
    // Search order [dirA, dirB] → dirA wins.
    assert.equal(resolveTemplatePath([dirA, dirB], "dup"), pathA);
    // Reversed order → dirB's copy wins instead.
    assert.equal(resolveTemplatePath([dirB, dirA], "dup"), join(dirB, "dup.json"));
    // A basename in NO dir → null.
    assert.equal(resolveTemplatePath([dirA, dirB], "absent"), null);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

// --- loadTemplateAtPath ({templateDir} substitution + workdir expansion, §2) ---

test("loadTemplateAtPath: expands workdir ~ AND substitutes {templateDir} = dirname(path)", () => {
  const root = tmpTree();
  try {
    const path = writeTemplate(root, "t", {
      workdir: "~/git/proj",
      listCommand: ["python3", "{templateDir}/list.py"],
    });
    const res = loadTemplateAtPath(path);
    assert.ok(res.ok);
    if (!res.ok) return;
    assert.equal(res.template.workdir, join(homedir(), "git/proj"), "~ expanded");
    assert.deepEqual(
      res.template.provider.list.command,
      ["python3", join(dirname(path), "list.py")],
      "{templateDir} substituted with the file's own dir",
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("loadTemplateAtPath: an absent path is a not-found LoadResult (no throw)", () => {
  const res = loadTemplateAtPath("/no/such/template.json");
  assert.equal(res.ok, false);
});

// --- makeFileRunFactory (threads the resolved path onto the run, §3) --------

test("makeFileRunFactory: the produced run carries templatePath + templateDir", () => {
  const root = tmpTree();
  try {
    const dir = join(root, "templates");
    const path = writeTemplate(dir, "backlog");
    const stateDir = join(root, "state");
    const factory = makeFileRunFactory([dir], stateDir);
    const run = factory("backlog");
    assert.ok(run !== null);
    if (run === null) return;
    assert.equal(run.templatePath, path);
    assert.equal(run.templateDir, dir);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("makeFileRunFactory: an unresolvable basename returns null", () => {
  const root = tmpTree();
  try {
    const factory = makeFileRunFactory([join(root, "empty")], join(root, "state"));
    assert.equal(factory("nope"), null);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

// --- rehydrateActiveRuns (determinism §3) ----------------------------------

/** Write the active-runs.json under `stateDir` for a single record. */
function writeActiveRuns(stateDir: string, rec: Record<string, unknown>): void {
  mkdirSync(stateDir, { recursive: true });
  writeFileSync(
    activeRunsFilePath(stateDir),
    JSON.stringify({ version: 1, runs: [{ name: "r", paused: false, draining: false, ...rec }] }),
    "utf8",
  );
}

test("rehydrateActiveRuns: rec.templatePath pins the SAME file even when an earlier dir shadows it", () => {
  const root = tmpTree();
  try {
    const dirA = join(root, "a"); // the run was originally loaded from here
    const dirB = join(root, "b"); // earlier in the search path, later gains the same basename
    const pathA = writeTemplate(dirA, "backlog");
    writeTemplate(dirB, "backlog"); // shadow: dirB is earlier in the search path below
    const stateDir = join(root, "state");
    writeActiveRuns(stateDir, { template: "backlog", templatePath: pathA });
    // Search path puts dirB FIRST (would win first-wins), but the recorded templatePath must win.
    const runs = rehydrateActiveRuns([dirB, dirA], stateDir);
    assert.equal(runs.length, 1);
    assert.equal(runs[0].templatePath, pathA, "determinism: loaded the recorded file, not the shadow");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("rehydrateActiveRuns: no templatePath → first-in-search-order resolution", () => {
  const root = tmpTree();
  try {
    const dirA = join(root, "a");
    const dirB = join(root, "b");
    writeTemplate(dirA, "backlog");
    const pathB = writeTemplate(dirB, "backlog");
    const stateDir = join(root, "state");
    writeActiveRuns(stateDir, { template: "backlog" }); // no templatePath
    // dirB is FIRST → first-wins picks dirB's file.
    const runs = rehydrateActiveRuns([dirB, dirA], stateDir);
    assert.equal(runs.length, 1);
    assert.equal(runs[0].templatePath, pathB);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("rehydrateActiveRuns: a vanished templatePath + unresolvable basename drops the run", () => {
  const root = tmpTree();
  try {
    const stateDir = join(root, "state");
    writeActiveRuns(stateDir, { template: "gone", templatePath: join(root, "gone/backlog.json") });
    const runs = rehydrateActiveRuns([join(root, "empty")], stateDir);
    assert.equal(runs.length, 0);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

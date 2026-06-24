// (ramon fork / Agent Queue Supervisor) Tests for the PURE production-seam helpers in
// wiring.ts that are safely testable WITHOUT touching node:child_process / node:fs —
// today, the provider-env sanitizer (§5 "sanitized env"). The exec/fs seams themselves
// are exercised only in production (the runner tests inject fakes), so they are not
// covered here; sanitizeProviderEnv is the load-bearing security boundary that IS pure.

import test from "node:test";
import assert from "node:assert/strict";
import { homedir } from "node:os";
import { join } from "node:path";

import {
  sanitizeProviderEnv,
  normalizeExecCode,
  expandHome,
  shouldMigrateLegacyState,
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

// Unit tests for the optional summarizer config overlay (config.ts).

import test from "node:test";
import assert from "node:assert/strict";

import { parseConfig, loadConfig, configFilePath } from "./config.js";
import { DEFAULT_CONFIG } from "./summarizer.js";

test("parseConfig: empty object => defaults unchanged", () => {
  assert.deepEqual(parseConfig({}), DEFAULT_CONFIG);
});

test("parseConfig: non-object => defaults", () => {
  assert.deepEqual(parseConfig(null), DEFAULT_CONFIG);
  assert.deepEqual(parseConfig(42), DEFAULT_CONFIG);
  assert.deepEqual(parseConfig([1, 2]), DEFAULT_CONFIG);
});

test("parseConfig: overlays known numeric/boolean keys", () => {
  const c = parseConfig({
    debounceMs: 60000,
    changeRatioThreshold: 0.35,
    skipHidden: false,
    idleSkipSeconds: 90,
    maxConcurrent: 4,
  });
  assert.equal(c.debounceMs, 60000);
  assert.equal(c.changeRatioThreshold, 0.35);
  assert.equal(c.skipHidden, false);
  assert.equal(c.idleSkipSeconds, 90);
  assert.equal(c.maxConcurrent, 4);
  // Untouched keys keep their defaults.
  assert.equal(c.promptTailLines, DEFAULT_CONFIG.promptTailLines);
});

test("parseConfig: overlays rateLimitBackoffMaxMs in range, rejects out-of-range", () => {
  assert.equal(parseConfig({ rateLimitBackoffMaxMs: 120000 }).rateLimitBackoffMaxMs, 120000);
  assert.equal(
    parseConfig({ rateLimitBackoffMaxMs: 99_999_999 }).rateLimitBackoffMaxMs,
    DEFAULT_CONFIG.rateLimitBackoffMaxMs,
  );
});

test("parseConfig: overlays hiddenDebounceMs in range, rejects out-of-range", () => {
  assert.equal(parseConfig({ hiddenDebounceMs: 900000 }).hiddenDebounceMs, 900000);
  assert.equal(
    parseConfig({ hiddenDebounceMs: 99_999_999 }).hiddenDebounceMs,
    DEFAULT_CONFIG.hiddenDebounceMs,
  );
});

test("parseConfig: rejects out-of-range / wrong-type values (keeps base)", () => {
  const c = parseConfig({
    changeRatioThreshold: 5, // > 1 → ignored
    debounceMs: -100, // < 0 → ignored
    maxConcurrent: 2.5, // non-integer → ignored
    skipHidden: "yes", // not a boolean → ignored
    bogusKey: 1, // unknown → ignored
  });
  assert.deepEqual(c, DEFAULT_CONFIG);
});

test("parseConfig: changeRatioThreshold 0 is allowed (binary mode)", () => {
  assert.equal(parseConfig({ changeRatioThreshold: 0 }).changeRatioThreshold, 0);
});

test("parseConfig: agentProcessNames filters to non-empty strings", () => {
  const c = parseConfig({ agentProcessNames: ["claude", "", 5, "aider"] });
  assert.deepEqual(c.agentProcessNames, ["claude", "aider"]);
  // An all-invalid array leaves the default.
  assert.deepEqual(
    parseConfig({ agentProcessNames: [1, 2] }).agentProcessNames,
    DEFAULT_CONFIG.agentProcessNames,
  );
});

test("parseConfig: does not mutate base", () => {
  const before = { ...DEFAULT_CONFIG };
  parseConfig({ debounceMs: 99999 });
  assert.deepEqual(DEFAULT_CONFIG, before);
});

test("loadConfig: absent file => defaults, loaded=false", () => {
  const res = loadConfig("/home/x", () => {
    throw new Error("ENOENT");
  });
  assert.equal(res.loaded, false);
  assert.deepEqual(res.cfg, DEFAULT_CONFIG);
});

test("loadConfig: malformed JSON => defaults, loaded=false, warns", () => {
  let warned = "";
  const res = loadConfig("/home/x", () => "{ not json", (m) => (warned = m));
  assert.equal(res.loaded, false);
  assert.deepEqual(res.cfg, DEFAULT_CONFIG);
  assert.ok(warned.includes("not valid JSON"));
});

test("loadConfig: valid JSON => parsed overlay, loaded=true", () => {
  const res = loadConfig("/home/x", () => '{"debounceMs":45000,"skipHidden":false}');
  assert.equal(res.loaded, true);
  assert.equal(res.cfg.debounceMs, 45000);
  assert.equal(res.cfg.skipHidden, false);
});

test("configFilePath: lands in the agent-manager config dir", () => {
  assert.ok(
    configFilePath("/Users/ramon").endsWith(
      "/.config/ghostty-ramon/agent-manager/config.json",
    ),
  );
});

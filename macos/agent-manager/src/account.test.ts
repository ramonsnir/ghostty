// Unit tests for the summarizer account routing resolver (PURE over an injected
// fs seam). Run via `npm test`.

import test from "node:test";
import assert from "node:assert/strict";

import {
  accountSpecPath,
  resolveAccountDir,
  type AccountFs,
} from "./account.js";

const HOME = "/home/test";

/** An AccountFs where `isDir` returns true for a fixed allow-set. */
function fsWithDirs(dirs: string[]): AccountFs {
  const set = new Set(dirs);
  return {
    readText: () => null,
    isDir: (p) => set.has(p),
  };
}

test("accountSpecPath: builds the expected path", () => {
  assert.equal(
    accountSpecPath("/home/x"),
    "/home/x/.config/ghostty-ramon/agent-manager/account",
  );
});

test("resolveAccountDir: null/empty/whitespace => null (inherit)", () => {
  const fs = fsWithDirs([]);
  assert.equal(resolveAccountDir(null, HOME, fs), null);
  assert.equal(resolveAccountDir(undefined, HOME, fs), null);
  assert.equal(resolveAccountDir("", HOME, fs), null);
  assert.equal(resolveAccountDir("   \n ", HOME, fs), null);
});

test("resolveAccountDir: bare name => <home>/.claude-accounts/<name> when it exists", () => {
  const dir = "/home/test/.claude-accounts/dev";
  const fs = fsWithDirs([dir]);
  assert.equal(resolveAccountDir("dev", HOME, fs), dir);
  assert.equal(resolveAccountDir("  dev  ", HOME, fs), dir); // trimmed
});

test("resolveAccountDir: bare name whose dir is MISSING => null (inherit)", () => {
  const fs = fsWithDirs([]); // nothing exists
  assert.equal(resolveAccountDir("dev", HOME, fs), null);
});

test("resolveAccountDir: absolute path used directly", () => {
  const fs = fsWithDirs(["/opt/acct"]);
  assert.equal(resolveAccountDir("/opt/acct", HOME, fs), "/opt/acct");
  assert.equal(resolveAccountDir("/opt/missing", HOME, fs), null);
});

test("resolveAccountDir: ~ and ~/x expand against home", () => {
  const fs = fsWithDirs([HOME, "/home/test/foo"]);
  assert.equal(resolveAccountDir("~", HOME, fs), HOME);
  assert.equal(resolveAccountDir("~/foo", HOME, fs), "/home/test/foo");
});

test("resolveAccountDir: a relative-with-slash value is treated as a path", () => {
  const fs = fsWithDirs(["foo/bar"]);
  assert.equal(resolveAccountDir("foo/bar", HOME, fs), "foo/bar");
});

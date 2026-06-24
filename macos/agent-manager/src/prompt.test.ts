// Unit tests for prompt layering: the mtime-cached override loader (with an
// injectable fs seam) + composeSystemPrompt. Run via `npm test`.

import test from "node:test";
import assert from "node:assert/strict";

import {
  composeSystemPrompt,
  makeOverrideLoader,
  summarizerOverridePath,
  type OverrideFs,
} from "./prompt.js";

const HOME = "/home/test";
const PATH = summarizerOverridePath(HOME);

/** A controllable in-memory fs seam for the loader tests. */
class FakeFs implements OverrideFs {
  mtime: number | null = null;
  text: string | null = null;
  statCalls = 0;
  readCalls = 0;
  statMtimeMs(path: string): number | null {
    assert.equal(path, PATH);
    this.statCalls++;
    return this.mtime;
  }
  readText(path: string): string | null {
    assert.equal(path, PATH);
    this.readCalls++;
    return this.text;
  }
}

test("summarizerOverridePath: builds the expected path", () => {
  assert.equal(
    summarizerOverridePath("/home/x"),
    "/home/x/.config/ghostty-ramon/agent-manager/summarizer.md",
  );
});

test("loadOverride: missing file => null (not an error), no read", () => {
  const fs = new FakeFs();
  fs.mtime = null; // absent
  const loader = makeOverrideLoader(HOME, fs);
  assert.equal(loader.load(), null);
  assert.equal(fs.readCalls, 0);
});

test("loadOverride: present file => content", () => {
  const fs = new FakeFs();
  fs.mtime = 100;
  fs.text = "Be terse.";
  const loader = makeOverrideLoader(HOME, fs);
  assert.equal(loader.load(), "Be terse.");
});

test("loadOverride: mtime-cached (no re-read when unchanged)", () => {
  const fs = new FakeFs();
  fs.mtime = 100;
  fs.text = "v1";
  const loader = makeOverrideLoader(HOME, fs);
  assert.equal(loader.load(), "v1");
  assert.equal(fs.readCalls, 1);
  // Same mtime -> cache hit, no second read.
  assert.equal(loader.load(), "v1");
  assert.equal(fs.readCalls, 1);
});

test("loadOverride: re-reads when mtime changes", () => {
  const fs = new FakeFs();
  fs.mtime = 100;
  fs.text = "v1";
  const loader = makeOverrideLoader(HOME, fs);
  assert.equal(loader.load(), "v1");
  fs.mtime = 200;
  fs.text = "v2";
  assert.equal(loader.load(), "v2");
  assert.equal(fs.readCalls, 2);
});

test("loadOverride: file vanishing clears cache and returns null", () => {
  const fs = new FakeFs();
  fs.mtime = 100;
  fs.text = "v1";
  const loader = makeOverrideLoader(HOME, fs);
  assert.equal(loader.load(), "v1");
  fs.mtime = null; // deleted
  assert.equal(loader.load(), null);
});

test("composeSystemPrompt: null override => base only", () => {
  assert.equal(composeSystemPrompt("BASE", null), "BASE");
});

test("composeSystemPrompt: blank override => base only", () => {
  assert.equal(composeSystemPrompt("BASE", "   \n  "), "BASE");
});

test("composeSystemPrompt: present override appended with delimiter", () => {
  const out = composeSystemPrompt("BASE", "  Prefer verbs.  ");
  assert.match(out, /^BASE/);
  assert.match(out, /USER NOTES/);
  assert.match(out, /Prefer verbs\.$/); // trimmed
});

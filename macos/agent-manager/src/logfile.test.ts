import { test } from "node:test";
import assert from "node:assert/strict";

import { formatLogLine, defaultLogPath } from "./logfile.js";

test("formatLogLine: '<iso> <level> <message>\\n', single trailing newline", () => {
  assert.equal(
    formatLogLine("INFO", "hello world", "2026-06-24T20:00:00.000Z"),
    "2026-06-24T20:00:00.000Z INFO hello world\n",
  );
});

test("formatLogLine: collapses trailing newlines so each call is exactly one line", () => {
  assert.equal(
    formatLogLine("ERR ", "boom\n\n", "2026-06-24T20:00:00.000Z"),
    "2026-06-24T20:00:00.000Z ERR  boom\n",
  );
  // Interior newlines are preserved (a multi-line message stays intact, only the tail is trimmed).
  assert.equal(
    formatLogLine("WARN", "line1\nline2\n", "T"),
    "T WARN line1\nline2\n",
  );
});

test("defaultLogPath: lands under ~/Library/Logs with the agent-manager name", () => {
  const p = defaultLogPath();
  assert.ok(p.endsWith("/Library/Logs/ghostty-ramon-agent-manager.log"), p);
});

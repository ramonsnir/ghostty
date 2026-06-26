import { test } from "node:test";
import assert from "node:assert/strict";

import { formatDiagLine, diagPath } from "./diag.js";

test("formatDiagLine: reserved ts/src/ev win over fields, keys sorted, single newline", () => {
  assert.equal(
    formatDiagLine(
      "classify",
      { surface: "ABC", verdict: "false", decision: "ignore" },
      "2026-06-26T12:00:00.000Z",
    ),
    '{"decision":"ignore","ev":"classify","src":"sidecar","surface":"ABC","ts":"2026-06-26T12:00:00.000Z","verdict":"false"}\n',
  );
});

test("formatDiagLine: caller cannot override the reserved fields", () => {
  const line = formatDiagLine(
    "alert",
    { src: "evil", ev: "evil", ts: "evil", tag: "rate_limited" },
    "T",
  );
  const obj = JSON.parse(line);
  assert.equal(obj.src, "sidecar");
  assert.equal(obj.ev, "alert");
  assert.equal(obj.ts, "T");
  assert.equal(obj.tag, "rate_limited");
});

test("diagPath: under ~/Library/Logs with the shared filename", () => {
  assert.match(diagPath(), /Library\/Logs\/ghostty-ramon-bell-diagnostics\.jsonl$/);
});

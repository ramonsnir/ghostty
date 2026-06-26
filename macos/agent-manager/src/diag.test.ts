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

test("formatDiagLine: a classify line carries durationMs (the Haiku call time)", () => {
  const obj = JSON.parse(
    formatDiagLine(
      "classify",
      { surface: "S1", verdict: "true", decision: "promote", reason: "needs you", durationMs: 842 },
      "T",
    ),
  );
  assert.equal(obj.ev, "classify");
  assert.equal(obj.durationMs, 842);
  assert.equal(obj.verdict, "true");
});

test("formatDiagLine: a backoff engage line (classifier's own account throttled)", () => {
  const obj = JSON.parse(
    formatDiagLine("backoff", { edge: "engage", streak: 1, failed: 3, nextProbeInS: 120 }, "T"),
  );
  assert.equal(obj.ev, "backoff");
  assert.equal(obj.edge, "engage");
  assert.equal(obj.nextProbeInS, 120);
});

test("diagPath: under ~/Library/Logs with the shared filename", () => {
  assert.match(diagPath(), /Library\/Logs\/ghostty-ramon-bell-diagnostics\.jsonl$/);
});

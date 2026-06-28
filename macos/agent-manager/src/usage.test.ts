import test from "node:test";
import assert from "node:assert/strict";
import {
  formatUsageLine,
  trimUsageText,
  usageEnabled,
  type UsageRecord,
} from "./usage.js";

const rec: UsageRecord = {
  feature: "summarizer",
  account: "dev",
  model: "claude-haiku-4-5",
  inputTokens: 10,
  outputTokens: 39,
  cacheReadTokens: 0,
  cacheCreationTokens: 25736,
  costUsd: 0.0517,
  durationMs: 1234,
};

test("formatUsageLine: one JSON object per line, ts injected, keys sorted", () => {
  const line = formatUsageLine(rec, "2026-06-28T12:00:00.000Z");
  assert.ok(line.endsWith("\n"));
  const obj = JSON.parse(line);
  assert.equal(obj.ts, "2026-06-28T12:00:00.000Z");
  assert.equal(obj.feature, "summarizer");
  assert.equal(obj.account, "dev");
  assert.equal(obj.costUsd, 0.0517);
  assert.equal(obj.cacheCreationTokens, 25736);
  // Keys are sorted for deterministic output.
  const keys = Object.keys(obj);
  assert.deepEqual(keys, [...keys].sort());
});

test("formatUsageLine: injected ts wins over any ts in the record", () => {
  const sneaky = { ...rec, ts: "1999-01-01T00:00:00.000Z" } as unknown as UsageRecord;
  const obj = JSON.parse(formatUsageLine(sneaky, "2026-06-28T12:00:00.000Z"));
  assert.equal(obj.ts, "2026-06-28T12:00:00.000Z");
});

test("trimUsageText: keeps lines at/after cutoff, drops older + blank + unparseable", () => {
  const old = formatUsageLine(rec, "2026-06-01T00:00:00.000Z");
  const fresh = formatUsageLine(rec, "2026-06-28T00:00:00.000Z");
  const text = old + "\n" + "not json\n" + fresh; // blank-ish + garbage interleaved
  const kept = trimUsageText(text, "2026-06-15T00:00:00.000Z");
  assert.ok(kept.includes("2026-06-28T00:00:00.000Z"));
  assert.ok(!kept.includes("2026-06-01T00:00:00.000Z"));
  assert.ok(!kept.includes("not json"));
  assert.ok(kept.endsWith("\n"));
});

test("trimUsageText: everything older than cutoff => empty string", () => {
  const text = formatUsageLine(rec, "2026-06-01T00:00:00.000Z");
  assert.equal(trimUsageText(text, "2026-06-15T00:00:00.000Z"), "");
});

test("usageEnabled: default ON, GHOSTTY_HAIKU_USAGE=0 disables", () => {
  const prev = process.env.GHOSTTY_HAIKU_USAGE;
  try {
    delete process.env.GHOSTTY_HAIKU_USAGE;
    assert.equal(usageEnabled(), true);
    process.env.GHOSTTY_HAIKU_USAGE = "1";
    assert.equal(usageEnabled(), true);
    process.env.GHOSTTY_HAIKU_USAGE = "0";
    assert.equal(usageEnabled(), false);
  } finally {
    if (prev === undefined) delete process.env.GHOSTTY_HAIKU_USAGE;
    else process.env.GHOSTTY_HAIKU_USAGE = prev;
  }
});

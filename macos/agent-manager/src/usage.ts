// (ramon fork / Agent Manager) Haiku usage / budget tracking.
//
// Records ONE JSONL line per Haiku call so you can later answer "how much did
// each FEATURE spend over the last N hours". All Haiku traffic funnels through
// model.ts `summarize()`; the caller tags each call with its feature (e.g.
// "summarizer" vs "bell-classify"), so a single sink here covers every feature.
//
// SURVIVES GUI/sidecar restarts for free: this is an append-only file on disk.
// The sidecar restarts with the GUI, but the file persists, so totals are
// cumulative across restarts. The Swift MCP `get_haiku_usage` tool reads the
// same file to answer time-windowed queries.
//
// Mirrors diag.ts: a PURE line-builder + a best-effort appender that NEVER
// throws into the loop. ALWAYS ON by default (continuous tracking is the point);
// set GHOSTTY_HAIKU_USAGE=0 to disable. trimUsageLog() bounds retention so the
// file cannot grow without limit.

import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/** Token + cost usage parsed off one Haiku call's SDK result message. */
export interface HaikuUsage {
  model: string;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheCreationTokens: number;
  /** Per-call cost — a TOKEN-BUCKET estimate (token counts × Haiku-4.5 rates, see
   *  `costFromUsage` in warmbase.ts), NOT the SDK's cumulative-per-session
   *  `total_cost_usd`. Computed the same way for both warm and cold so the two are
   *  directly comparable in `get_haiku_usage`. */
  costUsd: number;
  /** Whether this call went through the warm-base fork-per-call path ("warm") or
   *  today's cold one-shot ("cold"). Absent on records from before this field. */
  mode?: "warm" | "cold";
}

/** One recorded usage line: a HaikuUsage tagged with the feature + account. */
export interface UsageRecord extends HaikuUsage {
  /** Which feature triggered the call, e.g. "summarizer" | "bell-classify". */
  feature: string;
  /** Routed account (basename of CLAUDE_CONFIG_DIR), or "ambient" when unrouted. */
  account: string;
  /** Wall-clock duration of the model call, when known. */
  durationMs?: number | null;
}

/** Shared usage file — kept in sync with Swift `MCPUsage.fileURL`. */
export function usagePath(): string {
  return join(homedir(), "Library", "Logs", "ghostty-ramon-haiku-usage.jsonl");
}

/** True unless explicitly disabled. Default ON (the feature is meant to be
 *  always-tracking); GHOSTTY_HAIKU_USAGE=0 turns it off. */
export function usageEnabled(): boolean {
  return process.env.GHOSTTY_HAIKU_USAGE !== "0";
}

/** PURE: build one JSONL line. `nowIso` is injected (caller passes
 *  `new Date().toISOString()`) and the resulting `ts` wins over any record field;
 *  keys are sorted so output is deterministic (testable). */
export function formatUsageLine(rec: UsageRecord, nowIso: string): string {
  const obj: Record<string, unknown> = { ...rec, ts: nowIso };
  const sorted = Object.keys(obj)
    .sort()
    .reduce<Record<string, unknown>>((acc, k) => {
      acc[k] = obj[k];
      return acc;
    }, {});
  return JSON.stringify(sorted) + "\n";
}

/** Append one usage record (no-op unless enabled). Best-effort: never throws. */
export function recordUsage(rec: UsageRecord): void {
  if (!usageEnabled()) return;
  try {
    appendFileSync(usagePath(), formatUsageLine(rec, new Date().toISOString()));
  } catch {
    /* a usage write must never break the sidecar */
  }
}

/** PURE: keep only lines whose `ts` is >= `cutoffIso`. ISO-8601 UTC timestamps
 *  (fixed `…Z` format from toISOString) sort lexicographically == chronologically,
 *  so a string compare is correct. Blank lines and lines without a parseable `ts`
 *  are dropped (defensive). Returns the retained text (trailing newline kept). */
export function trimUsageText(text: string, cutoffIso: string): string {
  const out: string[] = [];
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    let ts: string | undefined;
    try {
      ts = (JSON.parse(line) as { ts?: string }).ts;
    } catch {
      continue;
    }
    if (typeof ts === "string" && ts >= cutoffIso) out.push(line);
  }
  return out.length ? out.join("\n") + "\n" : "";
}

/** Best-effort retention: rewrite the file keeping only the last `maxAgeDays`.
 *  `nowMs` is injected for testability. Never throws (no file yet ⇒ no-op). */
export function trimUsageLog(maxAgeDays: number, nowMs: number): void {
  if (!usageEnabled()) return;
  try {
    const text = readFileSync(usagePath(), "utf8");
    const cutoffIso = new Date(nowMs - maxAgeDays * 86_400_000).toISOString();
    const trimmed = trimUsageText(text, cutoffIso);
    if (trimmed.length !== text.length) writeFileSync(usagePath(), trimmed);
  } catch {
    /* no file yet / unreadable — nothing to trim */
  }
}

// (ramon fork / Bell Attention v2) Bell/attention diagnostics for the sidecar.
//
// Appends a structured JSONL trace of what the sidecar DECIDED per bell — the classify
// verdict + promote/ignore decision, and rate-limit alert edges — to the SAME file the
// GUI writes its ring/attention/clear events to. A single read then reconstructs the
// full per-surface timeline behind "why did it fire" / "why DIDN'T it fire an hour ago".
//
// Gated by `GHOSTTY_BELL_DIAG=1` (the GUI forwards it when `bell-diagnostics` is on).
// Best-effort: any fs error is swallowed and NEVER throws into the sweep. Uses
// `appendFileSync` (O_APPEND) so GUI + sidecar appends interleave atomically per line.

import { appendFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/** Shared diagnostics file — kept in sync with Swift `BellDiagnostics.fileURL`. */
export function diagPath(): string {
  return join(homedir(), "Library", "Logs", "ghostty-ramon-bell-diagnostics.jsonl");
}

/** True when diagnostics are enabled for this sidecar process. */
export function diagEnabled(): boolean {
  return process.env.GHOSTTY_BELL_DIAG === "1";
}

/** PURE: build one JSONL line. `ts`/`src`/`ev` are reserved and win over `fields`; keys
 *  are sorted so output is deterministic (testable). `nowIso` is injected by the caller
 *  (`new Date().toISOString()`) to keep this pure. */
export function formatDiagLine(
  event: string,
  fields: Record<string, unknown>,
  nowIso: string,
): string {
  const obj: Record<string, unknown> = { ...fields, ts: nowIso, src: "sidecar", ev: event };
  const sorted = Object.keys(obj)
    .sort()
    .reduce<Record<string, unknown>>((acc, k) => {
      acc[k] = obj[k];
      return acc;
    }, {});
  return JSON.stringify(sorted) + "\n";
}

/** Append one diagnostics event (no-op unless `GHOSTTY_BELL_DIAG=1`). Best-effort. */
export function recordDiag(event: string, fields: Record<string, unknown>): void {
  if (!diagEnabled()) return;
  try {
    appendFileSync(diagPath(), formatDiagLine(event, fields, new Date().toISOString()));
  } catch {
    /* a diagnostics write must never break the sidecar */
  }
}

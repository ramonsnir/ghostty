// (ramon fork / Agent Manager) Persistent file log for the sidecar.
//
// WHY: the Swift `AgentManagerController` pipes the sidecar's stdout to an UNREAD
// pipe and sends its stderr to `FileHandle.nullDevice` — so the queue engine's
// console.log/console.error (run removals, prune reasons, command applications) had
// NO durable trail. When a run vanished (e.g. the old quitWhenEmpty quit, or a
// premature session-gone prune) there was nothing to diagnose after the fact. This
// tees console.{log,info,warn,error} to a small ROTATING file so the next incident is
// debuggable. Best-effort: any fs error falls back to the original console only and
// NEVER throws into the sidecar.

import { openSync, writeSync, statSync, renameSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/** Default log path — mirrors the host's `~/Library/Logs/ghostty-ramon-host.log`. */
export function defaultLogPath(): string {
  return join(homedir(), "Library", "Logs", "ghostty-ramon-agent-manager.log");
}

/** PURE: format one log line. Trailing newlines in `message` are collapsed so each
 *  console call is exactly one line; `nowIso` is injected (caller passes
 *  `new Date().toISOString()`) to keep this testable. */
export function formatLogLine(level: string, message: string, nowIso: string): string {
  return `${nowIso} ${level} ${message.replace(/\n+$/, "")}\n`;
}

/** Rotate at ~5MB so the log can't grow unbounded across long-lived sidecars. */
const MAX_BYTES = 5 * 1024 * 1024;

let installed = false;

/**
 * Tee `console.{log,info,warn,error}` to `filePath` (append mode), rotating the
 * existing file to `<path>.1` once past `MAX_BYTES`. Idempotent (second call is a
 * no-op). Best-effort throughout — a failed open/stat/write degrades to the original
 * console only and never throws. The original console methods still run (so the
 * controller's stdout pipe is unaffected); this only ADDS the file sink.
 */
export function installFileLogger(filePath: string = defaultLogPath()): void {
  if (installed) return;
  installed = true;

  // Rotate a large existing file (best-effort; a failure just keeps appending).
  try {
    if (statSync(filePath).size > MAX_BYTES) renameSync(filePath, `${filePath}.1`);
  } catch {
    /* no file yet, or rotate failed — ignore */
  }

  let fd: number | undefined;
  try {
    fd = openSync(filePath, "a");
  } catch {
    fd = undefined; // can't open the log → leave console untouched
  }
  if (fd === undefined) return;

  const tee =
    (level: string, orig: (...a: unknown[]) => void) =>
    (...args: unknown[]): void => {
      orig(...args);
      try {
        const msg = args
          .map((a) => (typeof a === "string" ? a : String(a)))
          .join(" ");
        writeSync(fd!, formatLogLine(level, msg, new Date().toISOString()));
      } catch {
        /* a write failure must never break the sidecar */
      }
    };

  /* eslint-disable no-console */
  console.log = tee("INFO", console.log.bind(console));
  console.info = tee("INFO", console.info.bind(console));
  console.warn = tee("WARN", console.warn.bind(console));
  console.error = tee("ERR ", console.error.bind(console));
  /* eslint-enable no-console */
}

// (ramon fork / Agent Queue Supervisor) PRODUCTION seams for the supervisor pass —
// the ONLY place in the queue subsystem that touches `node:child_process` and the real
// filesystem for run state. Kept OUT of runner.ts (which stays seam-only + testable)
// so the orchestrator never imports a non-injectable effect. Mirrors how templates.ts
// isolates its `node:fs` loader behind the pure `validateTemplate`.
//
// This module is exercised only in production (main wires it); the unit/integration
// tests inject fakes for `exec` and `StoreIO`, never these.

import { execFile } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

import type { RunFactory } from "./commands.js";
import type { Exec, ExecOptions, ExecResult } from "./provider.js";
import {
  loadActiveRuns as loadActiveRunRecords,
  type ActiveRunRecord,
  type StoreIO,
} from "./store.js";
import { makeQueueRun, type QueueRun } from "./runner.js";
import {
  QUEUES_DIR,
  makeTemplateLoader,
  missingRequiredParams,
  realTemplateFs,
  runIdentityScope,
  scopeSlug,
  type LoadResult,
} from "./templates.js";
import type { QueueTemplate } from "./types.js";

/**
 * Env-var names (and prefixes) STRIPPED from the inherited process env before it is
 * handed to a team-authored PROVIDER subprocess (§5 "sanitized env"). The sidecar's own
 * process env carries Ghostty/agent-manager credentials + control flags — notably
 * `GHOSTTY_MCP_TOKEN` (a SHELL-EXECUTION credential) — which a provider script has no
 * business seeing. Provider commands take `{key}` as an argv element, not env, so nothing
 * legitimate is lost. (The agent LAUNCH command's GHOSTTY_ITEM_* env is a SEPARATE path —
 * delivered surface-side via spawn_split_command, not through this exec — so this strip
 * does not affect item-context delivery.)
 */
const PROVIDER_ENV_DENY_PREFIXES = ["GHOSTTY_MCP_", "GHOSTTY_AGENT_"] as const;
const PROVIDER_ENV_DENY_EXACT = new Set<string>(["GHOSTTY_MCP_TOKEN", "GHOSTTY_AGENT_MANAGER"]);

/** Build a sanitized env for a provider subprocess: the inherited env minus the
 *  Ghostty/MCP credential + control keys, then the caller's `extra` overlaid. PURE.
 *  Exported for unit testing. */
export function sanitizeProviderEnv(
  base: NodeJS.ProcessEnv,
  extra?: Record<string, string>,
): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(base)) {
    if (v === undefined) continue;
    if (PROVIDER_ENV_DENY_EXACT.has(k)) continue;
    if (PROVIDER_ENV_DENY_PREFIXES.some((p) => k.startsWith(p))) continue;
    out[k] = v;
  }
  if (extra) for (const [k, v] of Object.entries(extra)) out[k] = v;
  return out;
}

/**
 * Normalize an `execFile` callback error into a NON-ZERO exit code so `runProvider`
 * uniformly treats every failure as a skip. `execFile` sets `err.code` to the numeric
 * exit code for a non-zero exit, or a STRING ("ETIMEDOUT"/"ENOENT") for a spawn/timeout
 * failure; a numeric 0 (should not happen on the error path) is coerced to 1 so a
 * "failure with code 0" can never read as success. PURE — exported for unit testing. */
export function normalizeExecCode(err: unknown): number {
  const code = (err as { code?: unknown } | null)?.code;
  if (typeof code === "number") return code === 0 ? 1 : code;
  return 1; // string code (ETIMEDOUT/ENOENT/…) or absent → generic non-zero
}

/**
 * Expand a leading `~` / `~/` to the user's home dir. PURE — exported for unit testing.
 * The template `workdir` is authored with `~` (the spec says it is expanded "macOS-side"
 * for the agent SPLIT, which the GUI does), but the PROVIDER commands run here in the
 * sidecar via `execFile`, which does NOT expand `~` in its `cwd` — a literal `~/foo` cwd
 * makes `execFile` fail with ENOENT (it can't chdir there), so EVERY provider call silently
 * fails (ok:false → no dispatch). So we expand it before handing the cwd to `execFile`.
 */
export function expandHome(p: string): string {
  if (p === "~") return homedir();
  if (p.startsWith("~/")) return join(homedir(), p.slice(2));
  return p;
}

/**
 * The production process-runner: spawn an argv via `execFile` (NO shell — the genericity
 * boundary's safety, §13) with a tight timeout + a SANITIZED/merged env (Ghostty/MCP
 * credentials stripped — see sanitizeProviderEnv). NEVER rejects for a non-zero exit
 * (resolves with the code so the caller decides); a spawn error or a timeout resolves
 * with a non-zero synthetic code so `runProvider` maps it to a skip.
 */
export const realExec: Exec = (argv: string[], opts: ExecOptions = {}): Promise<ExecResult> =>
  new Promise<ExecResult>((resolve) => {
    const [cmd, ...args] = argv;
    if (cmd === undefined) {
      resolve({ code: 127, stdout: "", stderr: "empty command" });
      return;
    }
    const env = sanitizeProviderEnv(process.env, opts.env);
    execFile(
      cmd,
      args,
      {
        timeout: opts.timeoutMs,
        cwd: opts.cwd === undefined ? undefined : expandHome(opts.cwd),
        env,
        maxBuffer: 4 * 1024 * 1024,
        windowsHide: true,
      },
      (err, stdout, stderr) => {
        if (err) {
          resolve({ code: normalizeExecCode(err), stdout: stdout ?? "", stderr: stderr ?? "" });
          return;
        }
        resolve({ code: 0, stdout: stdout ?? "", stderr: stderr ?? "" });
      },
    );
  });

/** A real-filesystem StoreIO for one run, persisting to a JSON file. Read returns null
 *  when the file is absent (first run); write is ATOMIC (write a sibling `.tmp` then
 *  `rename` over the target — POSIX rename is atomic within a directory) so a crash
 *  mid-write can never leave a torn/half JSON that would corrupt the adoption hints on
 *  the next reconcile (§9). Both swallow nothing: they THROW on a hard fs error and the
 *  store layer maps that to a safe empty/logged-and-continue. */
export function makeFileStoreIO(filePath: string): StoreIO {
  return {
    read(): string | null {
      try {
        return readFileSync(filePath, "utf8");
      } catch {
        return null; // absent → first run
      }
    },
    write(text: string): void {
      mkdirSync(dirname(filePath), { recursive: true });
      const tmp = `${filePath}.tmp`;
      writeFileSync(tmp, text, "utf8");
      renameSync(tmp, filePath); // atomic replace — never a torn target file
    },
  };
}

/** The default run-state directory: beside the templates, under the agent-manager dir. */
export function defaultStateDir(home: string = homedir()): string {
  return join(home, ...QUEUES_DIR, ".state");
}

/** The default templates directory (the spec §15 default). Overridable by the Swift
 *  side via `agent-queue-templates-dir` → the GHOSTTY_AGENT_QUEUE_TEMPLATES_DIR env. */
export function defaultTemplatesDir(home: string = homedir()): string {
  return join(home, ...QUEUES_DIR);
}

/** The active-runs persistence file (one per state dir), holding the started-run SET (§8a). */
export function activeRunsFilePath(stateDir: string): string {
  return join(stateDir, "active-runs.json");
}

/** A StoreIO over the active-runs file (atomic-write like the per-run state files). */
export function makeActiveRunsStoreIO(stateDir: string): StoreIO {
  return makeFileStoreIO(activeRunsFilePath(stateDir));
}

/**
 * (§8a) Load + validate ONE template by BASENAME (the `*.json` filename minus extension)
 * from `templatesDir`. The `start` command's run factory + active-run rehydration both
 * resolve a template this way (on demand) — a template merely existing on disk no longer
 * auto-runs (replaces the Phase-1 `loadRuns(all)`). Returns the loader's LoadResult; an
 * absent/invalid template is `{ok:false, errors}` the caller surfaces (a failed start).
 */
export function loadTemplateByName(
  templatesDir: string,
  basename: string,
): LoadResult {
  const path = join(templatesDir, `${basename}.json`);
  const loader = makeTemplateLoader(path, realTemplateFs);
  const res = loader.load();
  // Expand a leading `~` in the template's workdir to an ABSOLUTE path HERE (once, at
  // load), so every downstream use is absolute: the provider commands' cwd (realExec)
  // AND the spawned agent split's cwd (passed to spawn_split_command). The macOS
  // SurfaceConfiguration.workingDirectory does NOT expand `~` (it only normalizes
  // separators), so an unexpanded `~/foo` is dropped and the split inherits the parent's
  // cwd — the agent then runs in the WRONG directory. The validator stays pure (no
  // homedir lookup); this impure seam owns the expansion.
  if (res.ok) res.template.workdir = expandHome(res.template.workdir);
  return res;
}

/**
 * (parallel runs) The per-run STATE FILE path under `stateDir`. Parallel runs of ONE
 * template (different param scopes) must NOT share a state file, so a NON-EMPTY scope adds
 * a short scope-hash suffix (`<basename>.<slug>.state.json`); an EMPTY scope keeps the bare
 * `<basename>.state.json` (byte-compatible with the pre-parallel single-run file). The
 * factory + rehydration derive it identically from (basename + template + params), so a
 * started run rehydrates to the SAME file. Path-only (no I/O).
 */
function runStatePath(
  stateDir: string,
  basename: string,
  template: QueueTemplate,
  params: Record<string, string>,
): string {
  const slug = scopeSlug(runIdentityScope(template, params));
  const file = slug === "" ? `${basename}.state.json` : `${basename}.${slug}.state.json`;
  return join(stateDir, file);
}

/**
 * (migration) Whether to MIGRATE a pre-parallel single-run state file
 * (`<basename>.state.json`) to the scope-suffixed path. PURE (the caller supplies the
 * existence bits). True ONLY when the scoped path DIFFERS from the legacy path (the run has
 * a non-empty scope), the scoped file is ABSENT, and the legacy file EXISTS — i.e. a run
 * whose durable state predates the scope-suffix rename (the `queue-parallel` change). This
 * preserves `lifetimeDispatched` + the live maxItems edit + the in-flight assignment records
 * across the upgrade instead of silently starting the count over at 0. Done ONLY on the
 * rehydrate path (a run that WAS active); a fresh `start` must NOT adopt a stale bare file.
 * Exported for unit testing.
 */
export function shouldMigrateLegacyState(
  scopedPath: string,
  legacyPath: string,
  scopedExists: boolean,
  legacyExists: boolean,
): boolean {
  return scopedPath !== legacyPath && !scopedExists && legacyExists;
}

/**
 * (§8a) Build the production RUN FACTORY a `start` command uses: load+validate the template
 * by basename, wire a per-run file StoreIO under `stateDir` (named by the basename + the
 * param SCOPE so parallel scoped runs of one template don't collide on disk, yet a run
 * rehydrates to the same file across restarts), and construct the QueueRun (carrying the
 * basename for reload + the optional rehydrated paused/draining flags). Returns null on a
 * bad/absent template (logged here) so `applyCommand` treats it as a failed start.
 */
export function makeFileRunFactory(
  templatesDir: string,
  stateDir: string,
): RunFactory {
  return (basename: string, params?: Record<string, string>): QueueRun | null => {
    const res = loadTemplateByName(templatesDir, basename);
    if (!res.ok) {
      console.error(
        `agent-manager: queue: cannot start template "${basename}": ${res.errors.join("; ")}`,
      );
      return null;
    }
    // (§8b) REJECT the start if a REQUIRED param was left empty (no answer + no default) —
    // a required scope (e.g. the Linear project) must be present before any dispatch.
    const missing = missingRequiredParams(res.template, params ?? {});
    if (missing.length > 0) {
      console.error(
        `agent-manager: queue: cannot start template "${basename}": missing required param(s): ${missing.join(", ")}`,
      );
      return null;
    }
    const runParams = params ?? {};
    const storeIO = makeFileStoreIO(runStatePath(stateDir, basename, res.template, runParams));
    return makeQueueRun(res.template, storeIO, { templateName: basename, params: runParams });
  };
}

/**
 * (§8a/§9) REHYDRATE the persisted active runs from `stateDir/active-runs.json` into a list
 * of fresh QueueRuns — re-loading each persisted run's template and carrying its
 * paused/draining flags. A persisted record whose template is now absent/invalid is SKIPPED
 * with a logged error (its run is silently dropped — a deleted/broken template can't run).
 * The supervisor's per-sweep reconcile (§9) then re-adopts each rehydrated run's in-flight
 * assignments from its own per-run state file, so the started queue + its tiles survive a
 * sidecar restart with NO re-dispatch. A template merely existing on disk does NOT appear
 * here — only a persisted/started run does.
 */
export function rehydrateActiveRuns(templatesDir: string, stateDir: string): QueueRun[] {
  const records: ActiveRunRecord[] = loadActiveRunRecords(makeActiveRunsStoreIO(stateDir));
  const runs: QueueRun[] = [];
  for (const rec of records) {
    const res = loadTemplateByName(templatesDir, rec.template);
    if (!res.ok) {
      console.error(
        `agent-manager: queue: dropping rehydrated run "${rec.name}" (template "${rec.template}"): ${res.errors.join("; ")}`,
      );
      continue;
    }
    const runParams = rec.params ?? {};
    const scopedPath = runStatePath(stateDir, rec.template, res.template, runParams);
    // (migration) An in-flight run whose state file predates the scope-suffix rename lives at
    // the bare `<basename>.state.json`. Rename it to the scoped path so its lifetimeDispatched
    // + live cap + assignment records survive the upgrade (otherwise rehydrate would read an
    // absent scoped file → start the count over at 0 + re-adopt orphans). Best-effort: a
    // failed rename just falls back to a fresh state (never throws into startup).
    const legacyPath = join(stateDir, `${rec.template}.state.json`);
    if (shouldMigrateLegacyState(scopedPath, legacyPath, existsSync(scopedPath), existsSync(legacyPath))) {
      try {
        renameSync(legacyPath, scopedPath);
        console.log(
          `agent-manager: queue: migrated legacy state for "${rec.template}" → scope-suffixed file`,
        );
      } catch (err) {
        console.error(`agent-manager: queue: legacy state migration failed for "${rec.template}": ${String(err)}`);
      }
    }
    const storeIO = makeFileStoreIO(scopedPath);
    runs.push(
      makeQueueRun(res.template, storeIO, {
        templateName: rec.template,
        paused: rec.paused,
        draining: rec.draining,
        params: runParams,
        maxItemsLive: rec.maxItemsLive,
      }),
    );
  }
  return runs;
}

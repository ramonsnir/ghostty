// (ramon fork / Agent Queue Supervisor) The GUI→sidecar command channel + the PURE
// reducer that applies a drained command to the ACTIVE-RUN registry (§8a).
//
// The sidecar is the MCP CLIENT (it polls the GUI); the GUI cannot call it. So a local
// "start run X" / "pause/stop/abort run Y" intent (keybind / palette / dashboard button)
// is enqueued GUI-side into an in-memory FIFO that the sidecar DRAINS each sweep via the
// `take_queue_commands` MCP tool. This module models a single drained command and the
// reducer that mutates the live `Map<runName, QueueRun>` registry from it — kept PURE
// (the run FACTORY + a clock are injected) so it is unit-testable with no MCP / fs.
//
// Run lifecycle (§8a):
//   start{template}  → load+validate the template by BASENAME; create a QueueRun unless a run
//                      with the SAME (basename + resolved param scope) is already active
//                      (re-start of the same scope = NO-OP, idempotent). A DIFFERENT scope of
//                      the same template (e.g. another project/milestone) starts in PARALLEL.
//   pause{run}       → set the run's `paused` flag (skip dispatch; keep tracking + closing).
//   resume{run}      → clear `paused`.
//   stop{run}        → set `draining` (no new dispatch; the run is removed once its active set empties).
//   abort{run}       → set `aborting` (exit+force-close ALL its assignments this sweep, then remove).
//   set_max_items{run,maxItems} → re-set a LIVE run's lifetime cap (the dashboard cap control)
//                      without restarting it; persisted so a restart re-applies it.
//   set_concurrency{run,concurrency} → re-set a LIVE run's max simultaneous agents (the dashboard
//                      parallel control) without restarting it; persisted so a restart re-applies it.
//
// A command naming an UNKNOWN run (pause/resume/stop/abort with no matching active run) or a
// start whose template fails to load is a logged NO-OP — never a throw into the loop.

import type { QueueRun } from "./runner.js";
import { parseConcurrencyValue, parseMaxItemsValue } from "./templates.js";

/** A drained GUI→sidecar control command (§8a). `template` is the template BASENAME
 *  (the `*.json` filename minus extension) for `start`; `run` is the active run NAME
 *  (the run's `runName` IDENTITY = `template.name` + its env-param scope, the dashboard
 *  origin) for pause/resume/stop/abort/set_max_items. */
export interface QueueCommand {
  action: "start" | "stop" | "abort" | "pause" | "resume" | "set_max_items" | "set_concurrency";
  /** The template basename to start (start only). */
  template?: string;
  /** The active run name (its `runName`) to pause/resume/stop/abort/set_max_items/set_concurrency. */
  run?: string;
  /** (§8b) START-TIME parameter answers (param name → value) collected by the GUI prompt,
   *  passed through to the factory (start only). Absent when the template declares no params. */
  params?: Record<string, string>;
  /** (live maxItems edit) The new lifetime-cap VALUE for `set_max_items` — a raw string the
   *  dashboard cap control collected ("10", "unlimited"/"0"/…, etc.), parsed by
   *  `parseMaxItemsValue` (blank/garbage = ignored). Absent for other actions. */
  maxItems?: string;
  /** (live concurrency edit) The new max-simultaneous-agents VALUE for `set_concurrency` — a
   *  raw string the dashboard parallel control collected ("9", etc.), parsed by
   *  `parseConcurrencyValue` (blank/garbage/non-positive = ignored). Absent for other actions. */
  concurrency?: string;
}

/** The injectable run FACTORY: build a fresh QueueRun for a template BASENAME (+ the
 *  start-time param answers, §8b), or return null when the template is absent/invalid OR a
 *  REQUIRED param is missing (logged by the factory; `applyCommand` treats null as a failed
 *  start). Production wires this to the template loader + a file StoreIO (wiring.ts); tests
 *  inject a fake. Keeping it a seam keeps `applyCommand` PURE. */
export type RunFactory = (
  templateBasename: string,
  params?: Record<string, string>,
) => QueueRun | null;

/** The active-run registry: live runs keyed by run NAME (the `runName` IDENTITY =
 *  `template.name` + the run's env-param scope), so parallel scoped runs of one template
 *  coexist under distinct keys. */
export type RunRegistry = Map<string, QueueRun>;

const log = (msg: string): void => console.log(`agent-manager: queue: ${msg}`);
const errlog = (msg: string): void => console.error(`agent-manager: queue: ${msg}`);

/** The outcome of applying one command — what changed, for the caller to persist/act on. */
export interface ApplyResult {
  /** "started" when a new run was created; "noop" when an idempotent re-start (or an
   *  unknown-run / failed-start no-op); else the flag mutation that occurred. */
  kind:
    | "started"
    | "paused"
    | "resumed"
    | "stopping"
    | "aborting"
    | "maxItemsSet"
    | "concurrencySet"
    | "noop";
  /** The affected run's NAME, when one was resolved (started/flag-flipped). */
  runName?: string;
}

/**
 * Apply ONE drained command to the active-run registry. PURE (mutates only the passed
 * `registry` via the injected `factory`; reads no clock/fs/MCP). Returns what changed so
 * the caller can re-persist the active-run set (§8a/§9). Idempotent where the spec requires:
 * a `start` for an already-active run is a no-op; an unknown-run flag command is a no-op.
 */
export function applyCommand(
  registry: RunRegistry,
  cmd: QueueCommand,
  factory: RunFactory,
): ApplyResult {
  switch (cmd.action) {
    case "start": {
      const basename = cmd.template;
      if (basename === undefined || basename.length === 0) {
        errlog(`start command with no template — ignored`);
        return { kind: "noop" };
      }
      // Build the candidate run FIRST so we have its resolved IDENTITY (the basename + its
      // `identityScope` = the resolved provider env) and its display `runName` before we
      // dedup. The factory only loads+validates the template + creates an in-memory object
      // (no store write until dispatch), so building a candidate we may discard is cheap
      // (the template loader is mtime-cached).
      const run = factory(basename, cmd.params);
      if (run === null) {
        // The factory logged the validation/load/required-param error; a failed start is a no-op.
        return { kind: "noop" };
      }
      // Idempotent: a run with the SAME template basename AND the SAME resolved scope
      // (project/milestone/…) is already active → NO-OP (a second identical start must not
      // reset its in-flight tracking). A DIFFERENT scope of the same template is a DISTINCT
      // run that proceeds in PARALLEL (its own tab, its own state file) — the headline
      // requirement: the Example queue is re-used in parallel for different project/milestone
      // tuples, never collapsed into one.
      for (const existing of registry.values()) {
        if (existing.templateName === basename && existing.identityScope === run.identityScope) {
          return { kind: "noop", runName: existing.runName };
        }
      }
      // The run's IDENTITY name (`runName`) keys the registry. GUARD a name collision: if a
      // DIFFERENT identity already occupies this display name (two distinct templates/scopes
      // that happen to render the same name), reject the second rather than last-wins clobber
      // it (which would orphan the first run's active map + store file until reconcile/prune).
      // The common same-template same-scope double-start is already caught by the dedup above.
      const clash = registry.get(run.runName);
      if (clash !== undefined) {
        errlog(
          `start of template "${basename}" REJECTED — run name "${run.runName}" ` +
            `is already in use (template "${clash.templateName}")`,
        );
        return { kind: "noop" };
      }
      registry.set(run.runName, run);
      log(`run "${run.runName}" STARTED (template ${basename})`);
      return { kind: "started", runName: run.runName };
    }
    case "pause":
    case "resume":
    case "stop":
    case "abort": {
      const name = cmd.run;
      if (name === undefined || name.length === 0) {
        errlog(`${cmd.action} command with no run — ignored`);
        return { kind: "noop" };
      }
      const run = registry.get(name);
      if (run === undefined) {
        errlog(`${cmd.action} for unknown run "${name}" — ignored`);
        return { kind: "noop" };
      }
      if (cmd.action === "pause") {
        run.paused = true;
        log(`run "${name}" PAUSED`);
        return { kind: "paused", runName: name };
      }
      if (cmd.action === "resume") {
        run.paused = false;
        log(`run "${name}" RESUMED`);
        return { kind: "resumed", runName: name };
      }
      if (cmd.action === "stop") {
        run.draining = true;
        log(`run "${name}" STOPPING (draining)`);
        return { kind: "stopping", runName: name };
      }
      // abort
      run.aborting = true;
      log(`run "${name}" ABORTING`);
      return { kind: "aborting", runName: name };
    }
    case "set_max_items": {
      // (live maxItems edit) Re-set a LIVE run's lifetime cap without restarting it. The
      // value is parsed exactly like the start-time maxItems param (null = unlimited; a
      // positive integer = the cap); a blank/garbage value is IGNORED (no change) so a bad
      // dashboard entry never silently removes the cap.
      const name = cmd.run;
      if (name === undefined || name.length === 0) {
        errlog(`set_max_items command with no run — ignored`);
        return { kind: "noop" };
      }
      const run = registry.get(name);
      if (run === undefined) {
        errlog(`set_max_items for unknown run "${name}" — ignored`);
        return { kind: "noop" };
      }
      const parsed = parseMaxItemsValue(cmd.maxItems ?? "");
      if (parsed === undefined) {
        errlog(`set_max_items for run "${name}" with invalid value "${cmd.maxItems ?? ""}" — ignored`);
        return { kind: "noop" };
      }
      run.maxItemsLive = parsed; // null = unlimited; number = cap
      log(`run "${name}" maxItems set LIVE to ${parsed === null ? "unlimited" : parsed}`);
      return { kind: "maxItemsSet", runName: name };
    }
    case "set_concurrency": {
      // (live concurrency edit) Re-set a LIVE run's max simultaneous agents without restarting
      // it. Parsed exactly like the dashboard parallel control (a positive integer; blank/
      // garbage/non-positive is IGNORED so a bad entry never silently changes parallelism).
      // Raising it past the template `cols*rows` also lifts the effective grid (pane) cap — see
      // `effectiveGridCap` — so the extra agents actually get panes (§12). Lowering it only
      // stops FUTURE dispatch; running agents are never killed.
      const name = cmd.run;
      if (name === undefined || name.length === 0) {
        errlog(`set_concurrency command with no run — ignored`);
        return { kind: "noop" };
      }
      const run = registry.get(name);
      if (run === undefined) {
        errlog(`set_concurrency for unknown run "${name}" — ignored`);
        return { kind: "noop" };
      }
      const parsed = parseConcurrencyValue(cmd.concurrency ?? "");
      if (parsed === undefined) {
        errlog(`set_concurrency for run "${name}" with invalid value "${cmd.concurrency ?? ""}" — ignored`);
        return { kind: "noop" };
      }
      run.concurrencyLive = parsed;
      log(`run "${name}" concurrency set LIVE to ${parsed}`);
      return { kind: "concurrencySet", runName: name };
    }
    default: {
      // Exhaustive guard for an unknown action (tolerant — a malformed drained command).
      errlog(`unknown queue command action "${String((cmd as { action?: unknown }).action)}" — ignored`);
      return { kind: "noop" };
    }
  }
}

/** Apply a BATCH of drained commands in order, returning true if ANY of them changed the
 *  active-run SET (a start, or a field the active-runs persistence captures: pause/resume/
 *  stop/set_max_items — the last persists the live cap so a restart re-applies it). Abort is
 *  NOT counted as a persistence change here — the run is removed this sweep and the caller
 *  re-persists after the removal regardless. PURE (delegates to applyCommand). */
export function applyCommands(
  registry: RunRegistry,
  cmds: QueueCommand[],
  factory: RunFactory,
): boolean {
  let changed = false;
  for (const cmd of cmds) {
    const res = applyCommand(registry, cmd, factory);
    if (
      res.kind === "started" ||
      res.kind === "paused" ||
      res.kind === "resumed" ||
      res.kind === "stopping" ||
      res.kind === "maxItemsSet" ||
      res.kind === "concurrencySet"
    ) {
      changed = true;
    }
  }
  return changed;
}

/**
 * Register REHYDRATED runs (restored from `active-runs.json` at sidecar startup) into the
 * registry — keyed by each run's `runName` IDENTITY, the SAME key a `start` command uses
 * (see `applyCommand`). This MUST match: control commands (pause/resume/stop/abort/
 * set_max_items) target the `runName` the dashboard shows, so a restored run keyed by
 * anything else (it was `template.name`) makes EVERY command a silent "unknown run" no-op —
 * and two parallel scoped runs of one template would collide on the bare name. Keying by
 * `runName` here is what makes a restored run behave identically to a freshly started one.
 * PURE. A `runName` collision between two restored runs keeps the LAST (degenerate; distinct
 * scopes yield distinct runNames). Exported for unit testing.
 */
export function registerRehydratedRuns(registry: RunRegistry, runs: QueueRun[]): void {
  for (const run of runs) registry.set(run.runName, run);
}

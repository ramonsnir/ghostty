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
//   start{template}  → load+validate the template by BASENAME; create a QueueRun if no run
//                      with that template's name is already active (re-start = NO-OP, idempotent).
//   pause{run}       → set the run's `paused` flag (skip dispatch; keep tracking + closing).
//   resume{run}      → clear `paused`.
//   stop{run}        → set `draining` (no new dispatch; the run is removed once its active set empties).
//   abort{run}       → set `aborting` (exit+force-close ALL its assignments this sweep, then remove).
//
// A command naming an UNKNOWN run (pause/resume/stop/abort with no matching active run) or a
// start whose template fails to load is a logged NO-OP — never a throw into the loop.

import type { QueueRun } from "./runner.js";

/** A drained GUI→sidecar control command (§8a). `template` is the template BASENAME
 *  (the `*.json` filename minus extension) for `start`; `run` is the active run NAME
 *  (= `template.name`, the dashboard origin) for pause/resume/stop/abort. */
export interface QueueCommand {
  action: "start" | "stop" | "abort" | "pause" | "resume";
  /** The template basename to start (start only). */
  template?: string;
  /** The active run name to pause/resume/stop/abort. */
  run?: string;
}

/** The injectable run FACTORY: build a fresh QueueRun for a template BASENAME, or return
 *  null when the template is absent/invalid (logged by the factory; `applyCommand` treats
 *  null as a failed start). Production wires this to the template loader + a file StoreIO
 *  (wiring.ts); tests inject a fake. Keeping it a seam keeps `applyCommand` PURE. */
export type RunFactory = (templateBasename: string) => QueueRun | null;

/** The active-run registry: live runs keyed by run NAME (= `template.name`). */
export type RunRegistry = Map<string, QueueRun>;

const log = (msg: string): void => console.log(`agent-manager: queue: ${msg}`);
const errlog = (msg: string): void => console.error(`agent-manager: queue: ${msg}`);

/** The outcome of applying one command — what changed, for the caller to persist/act on. */
export interface ApplyResult {
  /** "started" when a new run was created; "noop" when an idempotent re-start (or an
   *  unknown-run / failed-start no-op); else the flag mutation that occurred. */
  kind: "started" | "paused" | "resumed" | "stopping" | "aborting" | "noop";
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
      // Idempotent: if a run started from this template basename is already active, do
      // NOT recreate it (a second start would reset its in-flight tracking). Key dedup off
      // the template BASENAME so it matches before we know the (loaded) run name.
      for (const run of registry.values()) {
        if (run.templateName === basename) {
          return { kind: "noop", runName: run.template.name };
        }
      }
      const run = factory(basename);
      if (run === null) {
        // The factory logged the validation/load error; a failed start is a no-op.
        return { kind: "noop" };
      }
      // The run NAME (origin) keys the registry. GUARD a name collision: if a DIFFERENT
      // basename's run already occupies this name, reject the second start rather than
      // last-wins clobber it (which would orphan the first run's active map + store file
      // until reconcile/prune). The common single-file double-start is already caught by
      // the basename dedup above; this only fires for two distinct templates declaring the
      // same `name`.
      const existing = registry.get(run.template.name);
      if (existing !== undefined && existing.templateName !== basename) {
        errlog(
          `start of template "${basename}" REJECTED — its name "${run.template.name}" ` +
            `is already in use by template "${existing.templateName}"`,
        );
        return { kind: "noop" };
      }
      registry.set(run.template.name, run);
      log(`run "${run.template.name}" STARTED (template ${basename})`);
      return { kind: "started", runName: run.template.name };
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
    default: {
      // Exhaustive guard for an unknown action (tolerant — a malformed drained command).
      errlog(`unknown queue command action "${String((cmd as { action?: unknown }).action)}" — ignored`);
      return { kind: "noop" };
    }
  }
}

/** Apply a BATCH of drained commands in order, returning true if ANY of them changed the
 *  active-run SET (a start, or a flag the active-runs persistence captures: pause/resume/
 *  stop). Abort is NOT counted as a persistence change here — the run is removed this sweep
 *  and the caller re-persists after the removal regardless. PURE (delegates to applyCommand). */
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
      res.kind === "stopping"
    ) {
      changed = true;
    }
  }
  return changed;
}

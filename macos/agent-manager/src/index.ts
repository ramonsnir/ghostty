// (ramon fork / Agent Manager) The sidecar. A standalone Node/TS program (built
// with npm/tsc; NOT in Ghostty.xcodeproj). It runs two independent, self-paced
// loops:
//   1. The SUMMARIZER (this file's `runSweep`): every POLL_INTERVAL it lists the
//      live surfaces via Ghostty's MCP server, applies PURE debounce/skip-idle/
//      budget gates (summarizer.ts), and for each due agent surface reads the
//      viewport, makes a SINGLE-SHOT Haiku call (model.ts), parses the strict JSON
//      (summarizer.parseSummary), and writes the one-line `summary` (+ optional
//      phase/needsUser) back via set_surface_annotation. It is READ-ONLY: no
//      autonomous send (no send_text/send_key/perform_action) — it only describes.
//   2. The AGENT QUEUE SUPERVISOR (queue/, `runQueueSweepSafe`): a deterministic,
//      LLM-free dispatch/track/close loop on its OWN timer (decoupled so the slow
//      summarizer can never starve it). Armed only when a queue is configured.
//
// The summarizer's Haiku calls bill against the ambient Claude Code auth by
// default; an optional account spec (account.ts) routes them to a separate account.
//
// Config (env, set by the Swift AgentManagerController; mirrors macos/mcp-shim):
//   GHOSTTY_MCP_URL      MCP server URL (default http://127.0.0.1:8765/mcp)
//   GHOSTTY_MCP_TOKEN    shared secret, sent as the X-Ghostty-Token header (opt.)
//   GHOSTTY_AGENT_MANAGER=1  set by the controller (and inherited by the `claude`
//                            subprocess the SDK spawns) so the agent-state hook
//                            early-exits and the summarizer's own model activity
//                            never loops back through the hook (no recursion).
//
// Build/run: `npm install && npm run build && npm start`. The A+ gate is
// `npm run typecheck` (tsc --noEmit) + `npm test` (node --test over the pure
// modules). The sidecar is spawned + supervised by the Swift controller; it runs
// until SIGTERM (clean shutdown) on app quit. A transient MCP/model failure is
// logged + skipped — one bad surface never stops the loop; the loop never exits
// on its own.

import { homedir } from "node:os";
import { pathToFileURL } from "node:url";

import { McpClient, McpError, type Surface } from "./mcp.js";
import { SUMMARIZER_BASE_PROMPT } from "./prompts.js";
import { makeOverrideLoader, type OverrideLoader } from "./prompt.js";
import { summarize as defaultSummarize } from "./model.js";
import { readAccountSpec, resolveAccountDir } from "./account.js";
import {
  DEFAULT_CONFIG,
  ConcurrencyBudget,
  buildContext,
  composePrompt,
  preGate,
  fingerprint,
  parseSummary,
  shouldSummarize,
  type LastSummary,
  type SummarizerConfig,
  type SurfaceSnapshot,
} from "./summarizer.js";
import {
  runQueueSweep,
  DEFAULT_PENDING_GRACE_MS,
  type QueueDeps,
} from "./queue/runner.js";
import type { RunRegistry } from "./queue/commands.js";
import { ConcurrencyBudget as QueueConcurrencyBudget } from "./queue/supervisor.js";
import {
  persistActiveRuns as persistActiveRunsToIO,
  type ActiveRunRecord,
} from "./queue/store.js";
import {
  defaultStateDir,
  defaultTemplatesDir,
  rehydrateActiveRuns,
  makeActiveRunsStoreIO,
  makeFileRunFactory,
  realExec,
} from "./queue/wiring.js";

/** Poll interval between list_surfaces sweeps (the summarizer pass). */
const POLL_INTERVAL_MS = 5000;

/** Poll interval for the INDEPENDENT Agent Queue supervisor loop (decoupled from the
 *  slow LLM passes — see `runQueueSweepSafe` / `queueTick`). */
const QUEUE_POLL_INTERVAL_MS = 5000;

const log = (msg: string): void => console.log(`agent-manager: ${msg}`);
const errlog = (msg: string): void => console.error(`agent-manager: ${msg}`);

/** Parse a positive integer from an env string, falling back to `def` on
 *  absent/blank/invalid/non-positive input. PURE. */
function parsePositiveInt(v: string | undefined, def: number): number {
  if (v === undefined) return def;
  const n = Number.parseInt(v.trim(), 10);
  return Number.isInteger(n) && n > 0 ? n : def;
}

/** The single-shot model call seam (defaults to the real SDK-backed summarize).
 *  Injectable so the loop can be exercised without spawning the CLI. `configDir`
 *  (optional) routes the spawned `claude`'s auth/billing to a specific account. */
export type SummarizeFn = (
  req: { system: string; user: string; configDir?: string },
) => Promise<string>;

export interface LoopDeps {
  client: McpClient;
  overrides: OverrideLoader;
  cfg: SummarizerConfig;
  budget: ConcurrencyBudget;
  now: () => number;
  /** The model call. Injectable; defaults to model.ts `summarize`. */
  summarize: SummarizeFn;
  /** Per-session memory of the last successful summary, keyed by surface id.
   *  Held on deps (NOT module scope) so a test can seed/inspect it. */
  lastBySession: Map<string, LastSummary>;
  /** Optional CLAUDE_CONFIG_DIR for the summarizer's model calls — routes auth/billing
   *  to a specific claude-accounts account (see account.ts). Omitted ⇒ inherit the
   *  ambient auth (the default; works with no claude-accounts installed). */
  summarizerConfigDir?: string;

  // --- The Agent Queue Supervisor (ramon fork / Agent Queue) ---
  /** The supervisor pass's seams. OPTIONAL: when omitted (or carrying no runs), the
   *  queue pass is a NO-OP and the summarizer behavior is byte-identical — so a build
   *  with no queue configured behaves exactly as the summarizer-only sidecar. Its OWN
   *  ConcurrencyBudget lives inside `QueueDeps` (the starvation lesson). */
  queue?: QueueDeps;
}

/**
 * Summarize one candidate surface end-to-end: read viewport, run the FULL gate
 * on the real snapshot, and (if still due) compose, call model, parse, annotate,
 * record. Catches its OWN errors (logs + returns) so one bad surface never stops
 * the sweep. Assumes a budget slot has been acquired by the caller and releases
 * it here (in finally). The viewport-aware fingerprint gate runs here — NOT in
 * the sweep — so the gate and the recorded fingerprint share the SAME basis
 * (the freshly-read viewport tail), keeping idle-skip honest.
 */
async function summarizeOne(
  surface: Surface,
  deps: LoopDeps,
): Promise<void> {
  const { client, overrides, cfg } = deps;
  const prev = deps.lastBySession.get(surface.id);

  // Record a spent ATTEMPT: advance the per-session debounce clock (atMs) so a
  // FAILED or UNPARSEABLE attempt is throttled exactly like a successful one. Both
  // gates (preGate/shouldSummarize) debounce purely off atMs, so without this a
  // surface whose model call keeps failing / returning junk would be re-summarized
  // on EVERY poll forever — an unbounded Haiku-cost leak with no backoff. We PRESERVE
  // the prior fingerprint + summary so the change-detector is not poisoned: a genuine
  // state change still re-summarizes once debounce passes, and a persistently failing
  // surface keeps retrying (its recorded fingerprint differs from the live one) until
  // it succeeds — just no more than once per debounceMs. With no prior record the
  // sentinel "" fingerprint differs from any real one, so the retry still fires.
  const recordAttempt = (): void => {
    deps.lastBySession.set(surface.id, {
      fingerprint: prev?.fingerprint ?? "",
      atMs: deps.now(),
      summary: prev?.summary ?? "",
    });
  };

  try {
    const screen = await client.readSurface(surface.id);
    const snapshot: SurfaceSnapshot = { surface, viewport: screen.text };

    // Full, viewport-aware decision (the sweep only did the cheap pre-gate).
    const decision = shouldSummarize(snapshot, prev, deps.now(), cfg);
    // A SKIP spent no model call, so do NOT advance the debounce clock — that keeps
    // a real change caught at the very next poll rather than delayed by debounceMs.
    if (!decision.due) return; // unchanged/idle on the real viewport — skip

    // Prefer the loop's own record for continuity; fall back to the round-tripped
    // `notes` (our last summary echoed by list_surfaces). `||` so the "" sentinel
    // from a prior failed attempt falls back to notes rather than an empty string.
    const prevSummary = prev?.summary || surface.notes;
    const ctx = buildContext(snapshot, prevSummary, cfg);
    const { system, user } = composePrompt(
      SUMMARIZER_BASE_PROMPT,
      overrides.load(),
      ctx,
    );

    const raw = await deps.summarize({ system, user, configDir: deps.summarizerConfigDir });
    const parsed = parseSummary(raw);
    if (!parsed) {
      // Spent a model call but got nothing usable — throttle the retry.
      recordAttempt();
      errlog(`surface ${surface.id}: model reply not parseable; skipping`);
      return;
    }

    await client.setAnnotation(surface.id, {
      summary: parsed.summary,
      phase: parsed.phase,
      needsUser: parsed.needsUser,
    });

    deps.lastBySession.set(surface.id, {
      fingerprint: fingerprint(snapshot, cfg),
      atMs: deps.now(),
      summary: parsed.summary,
    });
    log(`surface ${surface.id}: "${parsed.summary}"`);
  } catch (err) {
    // A read/model/annotate failure — throttle the retry so a persistently failing
    // surface costs at most one attempt per debounceMs, not one per poll.
    recordAttempt();
    const what = err instanceof McpError ? "mcp" : "model";
    errlog(
      `surface ${surface.id}: ${what} error: ${
        err instanceof Error ? err.message : String(err)
      }`,
    );
  } finally {
    deps.budget.release();
  }
}

/**
 * One sweep: list surfaces, then run the SUMMARIZER pass over every due agent
 * surface, sharing the loop's MCP client + concurrency budget. Awaits all fired
 * calls so the budget is settled before the next sweep. Catches list_surfaces
 * failure (logs + returns) so a transient MCP outage just skips a sweep. Exported
 * for testing the gating.
 */
export async function runSweep(deps: LoopDeps): Promise<void> {
  let surfaces: Surface[];
  try {
    surfaces = await deps.client.listSurfaces();
  } catch (err) {
    errlog(
      `list_surfaces failed: ${err instanceof Error ? err.message : String(err)}`,
    );
    return;
  }

  // Drop session records for surfaces that no longer exist (closed/exited).
  const liveIds = new Set(surfaces.map((s) => s.id));
  for (const id of [...deps.lastBySession.keys()]) {
    if (!liveIds.has(id)) deps.lastBySession.delete(id);
  }

  const fired: Array<Promise<void>> = [];

  // SUMMARIZER pass.
  for (const surface of surfaces) {
    // Cheap pre-gate from row fields only (no read_surface yet): skip non-agent
    // + debounced surfaces. The viewport-aware fingerprint/idle decision happens
    // inside summarizeOne after the read, so the gate and the recorded
    // fingerprint share the same basis.
    const pre = preGate(surface, deps.lastBySession.get(surface.id), deps.now(), deps.cfg);
    if (!pre.pass) continue;
    // NOTE: because the loop is self-paced + non-overlapping (a sweep fully
    // settles before the next setTimeout), `cfg.maxConcurrent` doubles as a
    // per-sweep BATCH cap: at most maxConcurrent tiles are summarized per
    // POLL_INTERVAL_MS sweep, so with N>maxConcurrent due tiles a full refresh
    // takes ceil(N/maxConcurrent) sweeps. This is fine for Phase 1 (it also
    // rate-limits a many-tile setup); it is not the cross-overlap global cap the
    // design's wording might imply, but is functionally equivalent given no
    // overlap.
    if (!deps.budget.tryAcquire()) break; // budget exhausted this sweep
    fired.push(summarizeOne(surface, deps));
  }

  await Promise.all(fired);
  // NOTE: the AGENT QUEUE SUPERVISOR is NOT run here. It is a deterministic,
  // latency-sensitive loop that must NOT be gated behind the (slow, LLM-bound)
  // summarizer pass above — with many agents, `Promise.all(fired)` can take tens of
  // seconds, which would starve the queue's dispatch/track/close cadence. So the
  // queue runs on its OWN independent timer (`queueTick` in main), decoupled from
  // this sweep entirely. See `runQueueSweep`.
}

/** One queue-supervisor sweep, error-isolated (a bad provider/run never stops the loop).
 *  Driven by its OWN timer in `main` so the deterministic queue is never blocked by the
 *  slow summarizer pass in `runSweep`. A NO-OP when no queue is configured. */
export async function runQueueSweepSafe(deps: LoopDeps): Promise<void> {
  if (deps.queue === undefined) return;
  try {
    await runQueueSweep(deps.queue);
  } catch (err) {
    errlog(`queue sweep error: ${err instanceof Error ? err.message : String(err)}`);
  }
}

async function main(): Promise<void> {
  const url = process.env.GHOSTTY_MCP_URL ?? "http://127.0.0.1:8765/mcp";
  const token = process.env.GHOSTTY_MCP_TOKEN;

  const cfg: SummarizerConfig = { ...DEFAULT_CONFIG };
  const client = new McpClient({ url, token });

  // Optional summarizer ACCOUNT routing (see account.ts). Default ⇒ inherit the
  // ambient Claude Code auth (works with no claude-accounts installed). When set,
  // the summarizer's model calls bill against the configured account's CLAUDE_CONFIG_DIR.
  const home = homedir();
  const accountSpec = readAccountSpec(home);
  const summarizerConfigDir = resolveAccountDir(accountSpec, home) ?? undefined;
  if (accountSpec && accountSpec.trim() && summarizerConfigDir === undefined) {
    errlog(
      `summarizer account "${accountSpec.trim()}" did not resolve to a directory; using default auth`,
    );
  } else if (summarizerConfigDir) {
    log(`summarizer billing routed to CLAUDE_CONFIG_DIR=${summarizerConfigDir}`);
  }

  const deps: LoopDeps = {
    client,
    overrides: makeOverrideLoader(),
    cfg,
    budget: new ConcurrencyBudget(cfg.maxConcurrent),
    now: () => Date.now(),
    summarize: defaultSummarize,
    lastBySession: new Map<string, LastSummary>(),
    summarizerConfigDir,
  };

  // The AGENT QUEUE SUPERVISOR. ENABLE GATE: only when `agent-queue` is on AND at
  // least one valid template loads from the templates dir. The Swift controller sets
  // GHOSTTY_AGENT_QUEUE=1 (master enable) + GHOSTTY_AGENT_QUEUE_TEMPLATES_DIR +
  // GHOSTTY_AGENT_QUEUE_MAX_TOTAL from the fork config keys; absent ⇒ the queue stays
  // a no-op and the summarizer behavior is byte-identical.
  if (process.env.GHOSTTY_AGENT_QUEUE === "1") {
    const templatesDir = process.env.GHOSTTY_AGENT_QUEUE_TEMPLATES_DIR ?? defaultTemplatesDir();
    const stateDir = defaultStateDir();
    const maxTotal = parsePositiveInt(process.env.GHOSTTY_AGENT_QUEUE_MAX_TOTAL, 8);

    // ON-DEMAND run lifecycle (§8a): runs are NOT auto-started from every template.
    // Build a DYNAMIC registry, REHYDRATE any previously-started runs from the persisted
    // active-runs set (so a started queue + its in-flight items survive a sidecar restart
    // with no re-dispatch — §9), and DRAIN GUI→sidecar `start/pause/stop/abort` commands
    // each sweep. A template merely existing on disk does NOT auto-run — only a
    // persisted/started run, or one a `start` command arms.
    const registry: RunRegistry = new Map();
    for (const run of rehydrateActiveRuns(templatesDir, stateDir)) {
      registry.set(run.template.name, run);
    }
    const activeRunsIO = makeActiveRunsStoreIO(stateDir);

    deps.queue = {
      client,
      exec: realExec,
      // The supervisor's OWN budget (NOT the summarizer's / manager's) — the starvation
      // lesson. Cap it at the global fleet total so a sweep can't try to dispatch more
      // than the fleet allows in one batch.
      budget: new QueueConcurrencyBudget(maxTotal),
      now: () => Date.now(),
      registry,
      factory: makeFileRunFactory(templatesDir, stateDir),
      takeCommands: () => client.takeQueueCommands(),
      persistActiveRuns: (records: ActiveRunRecord[]) =>
        persistActiveRunsToIO(activeRunsIO, records),
      maxTotal,
      pendingGraceMs: DEFAULT_PENDING_GRACE_MS,
    };
    log(
      `queue: supervisor armed (on-demand); ${registry.size} run(s) rehydrated; ` +
        `templatesDir=${templatesDir}; maxTotal=${maxTotal}`,
    );
  }

  log(`summarizer started; MCP=${url} (poll ${POLL_INTERVAL_MS}ms)`);

  let stopped = false;
  let timer: NodeJS.Timeout | undefined;
  let queueTimer: NodeJS.Timeout | undefined;
  const shutdown = (sig: string): void => {
    if (stopped) return;
    stopped = true;
    if (timer) clearTimeout(timer);
    if (queueTimer) clearTimeout(queueTimer);
    log(`received ${sig}; shutting down`);
    process.exit(0);
  };
  process.on("SIGTERM", () => shutdown("SIGTERM"));
  process.on("SIGINT", () => shutdown("SIGINT"));

  // Self-pacing loop: run a sweep, then schedule the next POLL_INTERVAL_MS after
  // it settles (no overlap). setTimeout (not setInterval) avoids piling sweeps
  // when a sweep runs long.
  const tick = async (): Promise<void> => {
    if (stopped) return;
    try {
      await runSweep(deps);
    } catch (err) {
      // runSweep already catches its own errors, but belt-and-suspenders so the
      // loop can never die from an unexpected throw.
      errlog(`sweep error: ${err instanceof Error ? err.message : String(err)}`);
    }
    if (!stopped) timer = setTimeout(() => void tick(), POLL_INTERVAL_MS);
  };

  // INDEPENDENT queue loop (ramon fork / Agent Queue): the deterministic supervisor
  // runs on its OWN self-paced timer, NOT inside `tick`/`runSweep`. This decouples the
  // latency-sensitive queue (dispatch/track/close) from the slow LLM summarizer pass —
  // with many agents a single `runSweep` can take tens of seconds, which would otherwise
  // starve the queue. Only armed when a queue is configured. Same non-overlapping
  // self-pace as `tick`.
  const queueTick = async (): Promise<void> => {
    if (stopped) return;
    await runQueueSweepSafe(deps); // self-isolating; no-op when no queue configured
    if (!stopped) queueTimer = setTimeout(() => void queueTick(), QUEUE_POLL_INTERVAL_MS);
  };

  // Start the INDEPENDENT queue loop FIRST, so it is never delayed (or blocked
  // forever) by the slow — or occasionally hanging — first summarizer sweep in
  // `tick`. Both loops then run concurrently on the event loop.
  if (deps.queue !== undefined) void queueTick();
  await tick();
}

// Only start the poll loop when this module is the program ENTRY POINT (i.e.
// `node dist/index.js`), NOT when it is imported (e.g. by index.test.ts, which
// exercises runSweep directly with injected deps). Without this guard, importing
// the module would spin up the real 5s loop against the live MCP server and the
// test process would never settle.
const isEntryPoint =
  process.argv[1] !== undefined &&
  import.meta.url === pathToFileURL(process.argv[1]).href;

if (isEntryPoint) {
  main().catch((err) => {
    errlog(`fatal: ${err instanceof Error ? err.message : String(err)}`);
    process.exit(1);
  });
}

// (ramon fork / Agent Manager) Phase-1 sidecar: the SUMMARIZER. A standalone
// Node/TS program (built with npm/tsc; NOT in Ghostty.xcodeproj). It is the
// deterministic TS control loop that REPLACES the Phase-0 one-shot round-trip
// prover: every POLL_INTERVAL it lists the live surfaces via Ghostty's MCP
// server, applies PURE debounce/skip-idle/budget gates (summarizer.ts), and for
// each due agent surface reads the viewport, makes a SINGLE-SHOT Haiku call
// (model.ts), parses the strict JSON (summarizer.parseSummary), and writes the
// one-line `summary` (+ optional phase/needsUser) back via set_surface_annotation.
//
// SCOPE — Phase 1 is the SUMMARIZER ONLY: READ-ONLY. No autonomous send (no
// send_text/send_key/perform_action), no manager/coordinator logic, no
// suggestions. The summarizer writes ONLY the `summary` (+ phase/needsUser).
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

import { pathToFileURL } from "node:url";

import { McpClient, McpError, type Surface } from "./mcp.js";
import { SUMMARIZER_BASE_PROMPT } from "./prompts.js";
import { makeOverrideLoader, type OverrideLoader } from "./prompt.js";
import { summarize as defaultSummarize } from "./model.js";
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

/** Poll interval between list_surfaces sweeps. */
const POLL_INTERVAL_MS = 5000;

const log = (msg: string): void => console.log(`agent-manager: ${msg}`);
const errlog = (msg: string): void => console.error(`agent-manager: ${msg}`);

/** The single-shot model call seam (defaults to the real SDK-backed summarize).
 *  Injectable so the loop can be exercised without spawning the CLI. */
export type SummarizeFn = (
  req: { system: string; user: string },
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

    const raw = await deps.summarize({ system, user });
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
 * One sweep: list surfaces, gate each, and fire summaries for due agent surfaces
 * up to the concurrency budget. Awaits all fired calls so the budget is settled
 * before the next sweep. Catches list_surfaces failure (logs + returns) so a
 * transient MCP outage just skips a sweep. Exported for testing the gating.
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
}

async function main(): Promise<void> {
  const url = process.env.GHOSTTY_MCP_URL ?? "http://127.0.0.1:8765/mcp";
  const token = process.env.GHOSTTY_MCP_TOKEN;

  const cfg: SummarizerConfig = { ...DEFAULT_CONFIG };
  const deps: LoopDeps = {
    client: new McpClient({ url, token }),
    overrides: makeOverrideLoader(),
    cfg,
    budget: new ConcurrencyBudget(cfg.maxConcurrent),
    now: () => Date.now(),
    summarize: defaultSummarize,
    lastBySession: new Map<string, LastSummary>(),
  };

  log(`summarizer started; MCP=${url} (poll ${POLL_INTERVAL_MS}ms)`);

  let stopped = false;
  let timer: NodeJS.Timeout | undefined;
  const shutdown = (sig: string): void => {
    if (stopped) return;
    stopped = true;
    if (timer) clearTimeout(timer);
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

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
// The two loops are INDEPENDENT (see parseLoopEnablement): the shared sidecar runs
// whichever the controller arms, so the queue can run with the summarizer OFF (no
// Haiku billing) and vice-versa. The controller launches the sidecar when EITHER
// feature is enabled.
//
// The summarizer's Haiku calls bill against the ambient Claude Code auth by
// default; an optional account spec (account.ts) routes them to a separate account.
//
// Config (env, set by the Swift AgentManagerController; mirrors macos/mcp-shim):
//   GHOSTTY_MCP_URL      MCP server URL (default http://127.0.0.1:8765/mcp)
//   GHOSTTY_MCP_TOKEN    shared secret, sent as the X-Ghostty-Token header (opt.)
//   GHOSTTY_SUMMARIZER   "1"/ABSENT ⇒ run the summarizer; "0" ⇒ don't (gated on the
//                        `agent-manager` key). Absent means ON for back-compat (the
//                        summarizer used to be unconditional), so an old GUI that
//                        respawns a new dist keeps summarizing.
//   GHOSTTY_AGENT_QUEUE  "1" ⇒ arm the queue supervisor (gated on `agent-queue`);
//                        absent ⇒ off. INDEPENDENT of GHOSTTY_SUMMARIZER.
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
import { mkdirSync, readdirSync, rmSync } from "node:fs";

import { installFileLogger } from "./logfile.js";
import { recordDiag } from "./diag.js";
import { recordUsage, trimUsageLog, type HaikuUsage } from "./usage.js";
import { basename, join } from "node:path";
import { McpClient, McpError, type Surface } from "./mcp.js";
import { SUMMARIZER_BASE_PROMPT } from "./prompts.js";
import { makeOverrideLoader, type OverrideLoader } from "./prompt.js";
import {
  summarize as defaultSummarize,
  resolveClaudePath,
  SUMMARIZER_MODEL,
} from "./model.js";
import {
  WarmBase,
  warmbaseEnabled,
  loadForkSeam,
  warmbaseProjectDir,
  warmbaseInstanceDir,
  warmbaseInstanceKey,
  warmbaseRunDirName,
  planDeadRunDirs,
} from "./warmbase.js";
import { readAccountSpec, resolveAccountDir } from "./account.js";
import { loadConfig } from "./config.js";
import {
  ConcurrencyBudget,
  buildContext,
  composePrompt,
  preGate,
  changeSignals,
  changeTail,
  backoffDelayMs,
  parseSummary,
  lastLines,
  shouldSummarize,
  isAgentSurface,
  alertEdge,
  bellRoseEdge,
  ALERT_RATE_LIMITED,
  type LastSummary,
  type SummarizerConfig,
  type SurfaceSnapshot,
} from "./summarizer.js";
import {
  runQueueSweep,
  DEFAULT_PENDING_GRACE_MS,
  type QueueDeps,
} from "./queue/runner.js";
import { registerRehydratedRuns, type RunRegistry } from "./queue/commands.js";
import { collectCandidateKeys, runInferKeyWithDeps } from "./queue/infer.js";
import { ConcurrencyBudget as QueueConcurrencyBudget } from "./queue/supervisor.js";
import {
  persistActiveRuns as persistActiveRunsToIO,
  type ActiveRunRecord,
} from "./queue/store.js";
import {
  defaultStateDir,
  parseTemplatesDirs,
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

/** (bell-attention v2 slice 4) The bell-reactive long-poll park window. Below the MCP
 *  tool's 120s ceiling and the connection caps; on timeout the loop simply re-parks. */
const BELL_WAIT_MS = 60000;
/** Backoff before re-parking after a failed `wait_for_event` (MCP down / restarting), so
 *  a wedged server doesn't spin the loop. */
const BELL_WAIT_RETRY_MS = 3000;

/** (Agent Queue latency) The queue-command reactive long-poll park window. Same shape as the
 *  bell loop: below the MCP tool's 120s ceiling, on timeout the loop just re-parks. */
const QUEUE_WAIT_MS = 60000;
/** Backoff before re-parking after a failed queue-command `wait_for_event`. */
const QUEUE_WAIT_RETRY_MS = 3000;
/** (Agent Queue latency — anti-spin) MINIMUM gap between two reactive wakes. The GUI's
 *  `MCPEventBus.register` COALESCES: a `wait_for_event` resolves IMMEDIATELY on any matching
 *  event seen within its 0.5s ring window. The bell loop is naturally spaced by its slow
 *  Haiku classify between re-parks, but the queue loop fires its sweep fire-and-forget and
 *  re-parks with NO await — so a single `recordQueueCommand` event stays "recent" and the loop
 *  re-resolves on that SAME stale event hundreds of times/sec for the whole window (an event
 *  STORM that saturates the MCP serial queue → other tool calls time out → the GUI beachballs;
 *  observed live at ~471 wakes/sec). Sleeping past the coalesce window before re-parking lets
 *  the event age out, so the next park is a real park. Cost: a distinct command that lands
 *  during the sleep is drained ≤ this-many-ms later — still far under the 5s timer, and the
 *  command is never lost (the FIFO holds it + the timer is a backstop). MUST exceed the GUI's
 *  0.5s `coalesceWindow`. */
const QUEUE_REACTIVE_MIN_INTERVAL_MS = 750;

/** (orphan guard) How often the parent-death watchdog checks `process.ppid`. The sidecar
 *  is a child of the GUI; when that GUI dies (crash / SIGKILL / a clean-quit teardown that
 *  loses the race), the OS reparents this process — `process.ppid` flips to launchd (1) or
 *  another reaper. The watchdog then exits, so an orphaned sidecar can never resume reporting
 *  to a *new* GUI that rebinds the same loopback MCP port (the split-brain that made the
 *  Agent Queue health row alternate between two diverged snapshots). 2s is a tight reap with
 *  negligible cost; the interval is `.unref()`'d so it never keeps an idle process alive. */
const PARENT_WATCH_INTERVAL_MS = 2000;

const sleep = (ms: number): Promise<void> =>
  new Promise((resolve) => setTimeout(resolve, ms));

/**
 * (orphan guard) Parse the parent GUI's pid from `GHOSTTY_PARENT_PID` (set by the Swift
 * `AgentManagerController`). Returns a positive integer, or `undefined` when the var is
 * absent / malformed / non-positive (an OLD controller that doesn't set it). PURE +
 * unit-tested. When undefined, `shouldExitForParentDeath` falls back to the reparent-to-1
 * heuristic so the watchdog still works against an old GUI.
 */
export function parseParentPid(raw: string | undefined): number | undefined {
  if (raw === undefined) return undefined;
  const n = Number(raw.trim());
  return Number.isInteger(n) && n > 0 ? n : undefined;
}

/**
 * (orphan guard) Decide whether the sidecar should exit because its parent GUI is gone.
 * PURE + unit-tested. When we know the expected parent pid (passed via env), ANY change of
 * the live `process.ppid` away from it means we've been reparented (the GUI died) → exit.
 * Without it (old controller), fall back to "reparented to launchd" (`ppid === 1`), the
 * canonical Unix orphan signal. macOS `process.ppid` re-reads `getppid()` each access, so
 * it reflects the reparent promptly.
 */
export function shouldExitForParentDeath(
  currentPpid: number,
  expectedParentPid: number | undefined,
): boolean {
  if (expectedParentPid !== undefined) return currentPpid !== expectedParentPid;
  return currentPpid === 1;
}

/**
 * (bell-attention v2 slice 4) Wrap an async run so concurrent callers COALESCE instead
 * of overlapping: while one run is in flight, additional calls set a re-run flag and
 * return immediately; when the run finishes it loops once more iff a wake arrived (and we
 * are not stopped). This lets the 5s summarizer timer AND the bell-reactive long-poll both
 * request a sweep without ever running two sweeps at once (the design's non-overlap
 * invariant). PURE over its injected `run`/`isStopped` — unit-tested.
 */
export function makeCoalescedRunner(
  run: () => Promise<void>,
  isStopped: () => boolean = () => false,
): () => Promise<void> {
  let running = false;
  let again = false;
  return async (): Promise<void> => {
    if (running) {
      again = true;
      return;
    }
    running = true;
    try {
      do {
        again = false;
        await run();
      } while (again && !isStopped());
    } finally {
      running = false;
    }
  };
}

const log = (msg: string): void => console.log(`agent-manager: ${msg}`);
const errlog = (msg: string): void => console.error(`agent-manager: ${msg}`);

/** Parse a positive integer from an env string, falling back to `def` on
 *  absent/blank/invalid/non-positive input. PURE. */
function parsePositiveInt(v: string | undefined, def: number): number {
  if (v === undefined) return def;
  const n = Number.parseInt(v.trim(), 10);
  return Number.isInteger(n) && n > 0 ? n : def;
}

/** (hero) Parse a NON-NEGATIVE integer env, honoring an explicit `0` (unlike `parsePositiveInt`,
 *  which clamps 0 back to the default). Used for `agent-queue-hero-max`, where `0` is a
 *  meaningful value (DISABLE hero dispatch), not "use the default". An absent / blank / negative /
 *  non-integer value falls back to `def`. */
export function parseNonNegativeInt(v: string | undefined, def: number): number {
  if (v === undefined) return def;
  const n = Number.parseInt(v.trim(), 10);
  return Number.isInteger(n) && n >= 0 ? n : def;
}

/** Which INDEPENDENT loops the shared sidecar should run, from its env. PURE.
 *  The Swift controller (AgentManagerController) sets GHOSTTY_SUMMARIZER per the
 *  `agent-manager` key and GHOSTTY_AGENT_QUEUE per `agent-queue`; either alone (or
 *  both) can run.
 *  - summarizer: ON unless explicitly "0". An ABSENT flag is ON for BACK-COMPAT —
 *    the summarizer used to be unconditional, so an old GUI that respawns this (new)
 *    dist without the flag keeps summarizing; only a new GUI with agent-manager off
 *    writes the explicit "0".
 *  - queue: opt-in, ON only on exactly "1" (absent ⇒ off, unchanged). */
export function parseLoopEnablement(
  env: Record<string, string | undefined>,
): { summarizer: boolean; queue: boolean } {
  return {
    summarizer: env.GHOSTTY_SUMMARIZER !== "0",
    queue: env.GHOSTTY_AGENT_QUEUE === "1",
  };
}

/**
 * PURE gate predicate for the warm-base mechanism: ON iff `GHOSTTY_WARMBASE=1`
 * (via `warmbaseEnabled`) AND a Haiku-making feature (summarizer or bell-filter)
 * is armed. A queue-only process makes ZERO Haiku calls, so it never builds a
 * WarmBase. Extracted so a regression that flips the gate condition is caught by
 * a unit test. PURE over its injected env + the two feature bools.
 */
export function shouldEnableWarmBase(
  env: Record<string, string | undefined>,
  summarizerEnabled: boolean,
  bellFilter: boolean,
): boolean {
  return warmbaseEnabled(env) && (summarizerEnabled || bellFilter);
}

/** The single-shot model call seam (defaults to the real SDK-backed summarize).
 *  Injectable so the loop can be exercised without spawning the CLI. `configDir`
 *  (optional) routes the spawned `claude`'s auth/billing to a specific account. */
export type SummarizeFn = (
  req: {
    system: string;
    user: string;
    configDir?: string;
    onUsage?: (usage: HaikuUsage) => void;
    /** (floor hardening) Validity predicate over a WARM reply; false ⇒ fall back to the
     *  cold one-shot (see model.ts). Only consulted on the warm path. */
    isUsable?: (raw: string) => boolean;
  },
) => Promise<string>;

/**
 * The underlying model.ts `summarize` signature (3-arg: req, queryFn?, warm?). It IS
 * `typeof defaultSummarize`, so `makeSummarizeFn` can be unit-tested with a spy that
 * records HOW it was called (2-arg bare vs 3-arg with a WarmBase).
 */
export type BaseSummarizeFn = typeof defaultSummarize;

/**
 * PURE wiring of the loop's `summarize` seam (extracted so a regression that
 * mis-wires warm vs cold is caught by a unit test): when a WarmBase is present, route
 * through it (`base(req, undefined, warmBase)`); when ABSENT, return the BARE
 * `base` UNWRAPPED so the cold path is control-flow IDENTICAL to before the feature
 * existed (the 1-arg call `base(req)` — no queryFn, no warm). The gate decision
 * itself is `shouldEnableWarmBase`.
 */
export function makeSummarizeFn(
  base: BaseSummarizeFn,
  warmBase: WarmBase | undefined,
): SummarizeFn {
  return warmBase
    ? (req) => base(req, undefined, warmBase)
    : (base as SummarizeFn);
}

/** Deps for {@link buildWarmBase} — the impure bits injected so the startup
 *  construction floor is unit-testable WITHOUT a real SDK import or a real sweep. */
export interface BuildWarmBaseDeps {
  projectDir: string;
  model: string;
  /** The SINGLE account this sidecar binds (summarizer + bell-classify); set ONCE on
   *  the WarmBase. OMITTED ⇒ ambient (no binding). ROUND-2 resolution #1. */
  configDir?: string;
  claudePath?: string;
  /** Best-effort mkdir of projectDir; a throw is swallowed. */
  ensureDir: (dir: string) => void;
  /** Best-effort per-launch dead-pid run-dir sweep (ROUND-2 resolution #2): remove
   *  sibling run dirs whose owning sidecar pid is dead. Returns the count removed; a
   *  throw is swallowed. OMITTED ⇒ no run-dir sweep (back-compat / legacy shared
   *  dir). Composed in main() from the pure `planDeadRunDirs` + fs. */
  sweepDeadRunDirs?: () => number;
  /** Store roots the startup sweep scans for OUR orphan forks/bases. Always include
   *  ambient (`undefined`); add the account configDir under account routing so an
   *  account-dir base/fork from a prior run is reaped (not just ~/.claude leftovers).
   *  Defaults to `[undefined]` (ambient only) for back-compat. */
  sweepConfigDirs?: ReadonlyArray<string | undefined>;
  log: (m: string) => void;
  errlog: (m: string) => void;
}

/**
 * FLOOR-critical: construct the WarmBase, guarding EVERY impure step so that ANY
 * failure leaves the result `undefined` and the COLD path (the floor) + the queue
 * still come up. This is the "never worse than today even at startup" branch:
 * `loadSeam()` does a dynamic SDK import (the exact no-bundle / module-resolution
 * failure the lazy-load seam exists to survive) and the orphan sweep can throw —
 * neither may kill the sidecar merely because GHOSTTY_WARMBASE=1. Extracted from
 * `main()` (with `loadSeam` injectable) so a regression here — e.g. a rethrow where
 * a swallow was intended — is caught by a unit test rather than only by inspection.
 *
 * Contract: loadSeam-throw ⇒ returns undefined (cold deps still build); a
 * sweep-throw is swallowed (count 0) and the WarmBase is STILL returned.
 */
export async function buildWarmBase(
  deps: BuildWarmBaseDeps,
  loadSeam: () => Promise<Awaited<ReturnType<typeof loadForkSeam>>>,
): Promise<WarmBase | undefined> {
  try {
    deps.ensureDir(deps.projectDir);
    // Per-launch dead-pid run-dir sweep (ROUND-2 resolution #2): reap sibling run
    // dirs whose owning sidecar pid is dead, BEFORE this launch's own base lands.
    // Best-effort (swallowed) so it can never block construction; never touches a
    // live peer's dir or this launch's own run dir (see `planDeadRunDirs`).
    let reapedRunDirs = 0;
    try {
      reapedRunDirs = deps.sweepDeadRunDirs?.() ?? 0;
    } catch {
      /* best-effort */
    }
    const wb = new WarmBase({
      seam: await loadSeam(),
      projectDir: deps.projectDir,
      model: deps.model,
      // SET-ONCE account binding (ROUND-2 resolution #1) — bound in the constructor.
      configDir: deps.configDir,
      claudePath: deps.claudePath,
      log: (m) => deps.log(`warm-base: ${m}`),
    });
    const swept = await wb
      .sweepOrphanForks(deps.sweepConfigDirs ?? [undefined])
      .catch(() => 0);
    deps.log(
      `warm-base: ENABLED (projectDir=${deps.projectDir}, swept ${swept} orphan fork(s)` +
        `, reaped ${reapedRunDirs} dead run dir(s))`,
    );
    return wb;
  } catch (e) {
    // Cold path is the floor — never worse than today. Log and carry on.
    deps.errlog(
      `warm-base: construction failed, falling back to COLD path: ${
        e instanceof Error ? e.message : String(e)
      }`,
    );
    return undefined;
  }
}

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
  /** Per-session memory of the last ATTENTION alert tag (e.g. "rate_limited")
   *  seen for a surface, keyed by surface id. Drives the edge-triggered bell:
   *  signal_attention fires once when an alert first appears and re-arms only
   *  after the alert clears (the screen changes). Held on deps so a test can
   *  seed/inspect it; cleaned up alongside lastBySession when a surface dies. */
  alertBySession: Map<string, string>;
  /** Whether the CONTINUOUS summarizer pass runs (mirrors `agent-manager` /
   *  GHOSTTY_SUMMARIZER). When false, `runSweep` does NOT summarize the periodic due
   *  agents — only the cheap, INDEPENDENT per-bell FORCED pass below still runs (so
   *  bell-promotion works with agent-manager OFF, e.g. queue-only or bell-only mode). The
   *  expensive continuous Haiku polling is what `agent-manager` gates; bell promotion is
   *  per-bell + fail-open and is gated separately by `bellFilter`. */
  summarizerEnabled: boolean;
  /** (bell-attention) Whether the per-bell promotion pass is active (mirrors the GUI's
   *  `agent-manager-bell-filter` config, delivered via GHOSTTY_BELL_FILTER=1). When
   *  false the sweep does NO bell-edge work and behaves byte-identically to before;
   *  when true, a `bell` rising-edge / `pendingBellIds` force-classifies that surface
   *  (bellRang) so Haiku can PROMOTE it via set_attention. INDEPENDENT of
   *  `summarizerEnabled` — a bell still promotes when the continuous summarizer is off. */
  bellFilter: boolean;
  /** (bell-attention) Per-session memory of the last-seen `bell` flag, keyed by surface
   *  id, for rising-edge detection. Held on deps so a test can seed/inspect it; cleaned
   *  up alongside lastBySession when a surface dies. This is the POLL BACKSTOP — it only
   *  catches rings when `list_surfaces.bell` is armed (i.e. bell-features routes a visual
   *  bell: title/border). The PRIMARY signal is `pendingBellIds` below. */
  bellSeenBySession: Map<string, boolean>;
  /** (bell-attention v2 slice 6) Surface ids the bell-reactive loop saw ring via
   *  `wait_for_event(bell)` — the GUI posts `.ghosttyBellDidRing` UNCONDITIONALLY on every
   *  ring (Ghostty.App.ringBell), so the MCP event bus sees every bell REGARDLESS of
   *  whether the per-surface `view.bell` visual flag was armed. This is what makes
   *  promotion work in the feature's recommended `bell-features = system,audio` config
   *  (where `view.bell`/`list_surfaces.bell` is never set, so the poll backstop above is
   *  blind). Drained into `forcedBell` at the start of each sweep. */
  pendingBellIds: Set<string>;
  /** Adaptive RATE-LIMIT BACKOFF state (account-WIDE, not per-session). When the
   *  summarizer's own model calls keep failing — its account is rate-limited / returns
   *  no usable summary — `failureStreak` rises and `nextProbeMs` pushes the next probe
   *  out (exponential, capped by `cfg.rateLimitBackoffMaxMs`). While backed off the
   *  sweep makes at most ONE probe call per window; the first SUCCESS resets the streak
   *  to 0 and normal cadence resumes. Held on deps so a test can seed/inspect it. */
  summarizerBackoff: { failureStreak: number; nextProbeMs: number };
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
/** The outcome of one summarizeOne attempt, for the rate-limit backoff aggregator:
 *  "ok" = a model call SUCCEEDED + parsed (the account works); "fail" = a call was
 *  made but threw / returned no usable summary (rate-limited or junk); "skip" = no
 *  model call happened (the full gate said not-due). */
type SummarizeResult = "ok" | "fail" | "skip";

async function summarizeOne(
  surface: Surface,
  deps: LoopDeps,
  opts: { bellRang?: boolean } = {},
): Promise<SummarizeResult> {
  const { client, overrides, cfg } = deps;
  const bellRang = opts.bellRang === true;
  const prev = deps.lastBySession.get(surface.id);

  // Record a spent ATTEMPT: advance the per-session debounce clock (atMs) so a
  // FAILED or UNPARSEABLE attempt is throttled exactly like a successful one. Both
  // gates (preGate/shouldSummarize) debounce purely off atMs, so without this a
  // surface whose model call keeps failing / returning junk would be re-summarized
  // on EVERY poll forever — an unbounded Haiku-cost leak with no backoff. We PRESERVE
  // the prior fingerprint + summary so the change-detector is not poisoned: a genuine
  // state change still re-summarizes once debounce passes, and a persistently failing
  // surface keeps retrying (its recorded signals/tail differ from the live one) until
  // it succeeds — just no more than once per debounceMs. With no prior record the
  // sentinel "" signals/tail differ from any real one, so the retry still fires.
  const recordAttempt = (): void => {
    deps.lastBySession.set(surface.id, {
      signals: prev?.signals ?? "",
      tail: prev?.tail ?? "",
      atMs: deps.now(),
      summary: prev?.summary ?? "",
    });
  };

  // (diagnostics) Wall-clock duration of the Haiku classify call itself, so the trace
  // can decompose total ring->attention delay into model time vs. poll/queue latency.
  // Set right before `summarize()`; in the catch it measures a FAILED call's time (e.g.
  // how long a rate-limited call hung before erroring). Null if we erred before the call.
  let modelStartedAt: number | null = null;
  const durMs = (): number | null =>
    modelStartedAt != null ? deps.now() - modelStartedAt : null;

  try {
    const screen = await client.readSurface(surface.id);
    const snapshot: SurfaceSnapshot = { surface, viewport: screen.text };

    // Full, viewport-aware decision (the sweep only did the cheap pre-gate).
    const decision = shouldSummarize(snapshot, prev, deps.now(), cfg);
    // A SKIP spent no model call, so do NOT advance the debounce clock — that keeps
    // a real change caught at the very next poll rather than delayed by debounceMs.
    // The attention alert is the MODEL's verdict (below), so an idle-skip — where no
    // model call runs — deliberately LEAVES the alert state untouched: a held alert
    // stays armed (no re-ring), and nothing rings or clears without a fresh classify.
    // EXCEPTION: a bell-triggered classify (bellRang) always proceeds, even when the
    // gate would skip — a bell is an event worth one classify so Haiku can decide
    // whether to promote it to the "attention needed" state.
    if (!decision.due && !bellRang) return "skip"; // unchanged/idle — skip (no model call)

    // Prefer the loop's own record for continuity; fall back to the round-tripped
    // `notes` (our last summary echoed by list_surfaces). `||` so the "" sentinel
    // from a prior failed attempt falls back to notes rather than an empty string.
    const prevSummary = prev?.summary || surface.notes;
    const ctx = buildContext(snapshot, prevSummary, cfg, bellRang);
    const { system, user } = composePrompt(
      SUMMARIZER_BASE_PROMPT,
      overrides.load(),
      ctx,
    );

    modelStartedAt = deps.now();
    // (usage/budget tracking) Tag this Haiku call with the FEATURE that triggered
    // it (a bell-triggered classify vs the continuous summarizer) and the routed
    // ACCOUNT, then record the token/cost usage the SDK reports. Survives restarts
    // via the on-disk JSONL (see usage.ts); queried by the get_haiku_usage MCP tool.
    const usageFeature = bellRang ? "bell-classify" : "summarizer";
    const usageAccount = deps.summarizerConfigDir
      ? basename(deps.summarizerConfigDir)
      : "ambient";
    const raw = await deps.summarize({
      system,
      user,
      configDir: deps.summarizerConfigDir,
      onUsage: (u) =>
        recordUsage({ ...u, feature: usageFeature, account: usageAccount, durationMs: durMs() }),
      // (floor hardening) An unparseable WARM reply falls back to the cold one-shot
      // (see model.ts). Mirrors the parse check below, so a hollow/garbage warm reply
      // can't silently skip the surface without the cold floor firing.
      isUsable: (r) => parseSummary(r) !== null,
    });
    const parsed = parseSummary(raw);
    if (!parsed) {
      // Spent a model call but got nothing usable — throttle the retry. No usable
      // classify this sweep ⇒ leave the SUMMARY/alert state untouched. But a bell
      // rang and we have no confident verdict ⇒ FAIL-OPEN: promote (an unparseable
      // reply must NEVER silence a bell).
      recordAttempt();
      errlog(`surface ${surface.id}: model reply not parseable; skipping`);
      if (bellRang) {
        recordDiag("classify", {
          surface: surface.id,
          verdict: "unparseable",
          decision: "promote",
          reason: "unparseable classify (fail-open)",
          durationMs: durMs(),
        });
        await bellPromote(deps, surface, "unparseable classify (fail-open)");
      }
      return "fail";
    }

    await client.setAnnotation(surface.id, {
      summary: parsed.summary,
      phase: parsed.phase,
      needsUser: parsed.needsUser,
    });

    deps.lastBySession.set(surface.id, {
      signals: changeSignals(surface),
      tail: changeTail(snapshot.viewport, cfg),
      atMs: deps.now(),
      summary: parsed.summary,
    });
    if (bellRang) {
      log(`surface ${surface.id}: bellRang classify -> attention=${parsed.attention} alert=${parsed.alert}`);
    }
    // The model is the SOLE judge of the attention alert: ring on a rising edge,
    // clear when it reports no alert (the screen changed and Haiku no longer sees
    // the live condition — this is how recovery un-rings, immune to scrolled-up text).
    await maybeSignalAlert(deps, surface, parsed.alert);
    // (bell-attention v2, FAIL-OPEN) On a bell-triggered classify, PROMOTE unless Haiku
    // confidently said ignore. `attention === false` is the ONLY suppression; `true` and
    // an OMITTED/uncertain verdict both promote (so model hedging never silences a bell).
    if (bellRang) {
      const verdict =
        parsed.attention === true
          ? "true"
          : parsed.attention === false
            ? "false"
            : "omitted";
      const decision = parsed.attention !== false ? "promote" : "ignore";
      recordDiag("classify", {
        surface: surface.id,
        verdict,
        decision,
        reason: parsed.summary,
        durationMs: durMs(),
      });
      if (parsed.attention !== false) await bellPromote(deps, surface, parsed.summary);
    }
    log(`surface ${surface.id}: "${parsed.summary}"`);
    return "ok";
  } catch (err) {
    // A read/model/annotate failure — throttle the retry so a persistently failing
    // surface costs at most one attempt per debounceMs, not one per poll. No fresh
    // classify ⇒ the alert state is left untouched (a held alert stays armed). NOTE:
    // if the summarizer's OWN account is the one rate-limited, its calls fail here and
    // the watchdog goes blind — route the summarizer to a separate account (see
    // AGENT-MANAGER.md "Account routing") so the watchdog survives the main limit.
    recordAttempt();
    const what = err instanceof McpError ? "mcp" : "model";
    errlog(
      `surface ${surface.id}: ${what} error: ${
        err instanceof Error ? err.message : String(err)
      }`,
    );
    // (bell-attention v2, FAIL-OPEN) A bell rang but the read/model/annotate failed
    // (incl. the summarizer's own account being out of tokens) ⇒ we have no confident
    // verdict ⇒ promote. A failing classifier must never silence a bell.
    if (bellRang) {
      recordDiag("classify", {
        surface: surface.id,
        verdict: "error",
        decision: "promote",
        reason: "classify error (fail-open)",
        // The real failure — so a fail-open promotion caused by the classifier's OWN
        // account being rate-limited (vs. some other error) is visible in the trace.
        error: (err instanceof Error ? err.message : String(err)).slice(0, 300),
        errorKind: what,
        durationMs: durMs(),
      });
      await bellPromote(deps, surface, "classify error (fail-open)");
    }
    return "fail";
  } finally {
    deps.budget.release();
  }
}

/** A short human-readable note for an alert tag, passed to signal_attention. */
function alertReason(alert: string): string {
  if (alert === ALERT_RATE_LIMITED) return "Rate limited — waiting for you";
  return `Attention: ${alert}`;
}

/**
 * (bell-attention v2, FAIL-OPEN) Promote a belled surface to the sticky attention state.
 * Called on a bell-edge classify in EVERY outcome EXCEPT a clean, confident Haiku
 * `attention === false` — so a model error, timeout, out-of-tokens, unparseable reply,
 * or an omitted/uncertain verdict all land here and PROMOTE. Only an explicit "ignore"
 * suppresses (the user's "only an explicit filter can ignore a bell"). The GUI clears
 * attention on focus; `set_attention` is idempotent. Self-isolating: a tool failure is
 * logged, never thrown into the sweep.
 */
async function bellPromote(deps: LoopDeps, surface: Surface, reason: string): Promise<void> {
  try {
    await deps.client.setAttention(surface.id, true, reason);
    log(`surface ${surface.id}: bell promoted -> attention needed (${reason})`);
  } catch (err) {
    errlog(
      `surface ${surface.id}: set_attention failed: ${
        err instanceof Error ? err.message : String(err)
      }`,
    );
  }
}

/**
 * Edge-triggered "needs you" promotion for one surface. Compares `alert` (the tag for
 * THIS read, or undefined) against the last-seen tag and, on a rising/changed edge,
 * sets the surface's STICKY attention state via `set_attention` (the always-loud
 * Tier-2 signal — title marker, dock, push, dashboard float — that is EXEMPT from the
 * `agent-manager-bell-filter` tone-down, so a rate-limit halt stays loud even with the
 * filter on). On the clearing edge it sets attention OFF so a recovered surface
 * un-promotes (it also clears on focus GUI-side). Records the tag so a held alert
 * never re-fires; rolls back on failure so a later sweep retries. Catches its OWN
 * errors so it never escapes into summarizeOne's flow.
 *
 * NOTE (review fix / slice 5): this used to call `signal_attention` (a one-shot
 * `.ghosttyBellDidRing`), which the tone-down filter SILENCED — defeating the whole
 * point of the watchdog when the filter was on. Routing through `set_attention`
 * (the sticky attention tier) is the unification the design called for.
 */
async function maybeSignalAlert(
  deps: LoopDeps,
  surface: Surface,
  alert: string | undefined,
): Promise<void> {
  const edge = alertEdge(deps.alertBySession.get(surface.id), alert);
  if (edge === "ring") {
    // Record FIRST so a slow set_attention can't double-fire from an overlapping
    // sweep; roll back below if the call fails so the edge is retried.
    deps.alertBySession.set(surface.id, alert as string);
    recordDiag("alert", {
      surface: surface.id,
      tag: alert as string,
      edge: "ring",
      decision: "promote",
    });
    try {
      await deps.client.setAttention(surface.id, true, alertReason(alert as string));
      log(`surface ${surface.id}: alert "${alert}" -> promoted (attention)`);
    } catch (err) {
      deps.alertBySession.delete(surface.id);
      errlog(
        `surface ${surface.id}: set_attention failed: ${
          err instanceof Error ? err.message : String(err)
        }`,
      );
    }
  } else if (edge === "clear") {
    deps.alertBySession.delete(surface.id);
    recordDiag("alert", { surface: surface.id, edge: "clear", decision: "unpromote" });
    // Best-effort un-promote on recovery (also cleared on focus GUI-side).
    try {
      await deps.client.setAttention(surface.id, false);
    } catch (err) {
      errlog(
        `surface ${surface.id}: set_attention(off) failed: ${
          err instanceof Error ? err.message : String(err)
        }`,
      );
    }
  }
}

/**
 * (bell-attention v2) PREEMPTIVE bell classify — the latency fix.
 *
 * A bell used to wake the classify via `runSweepCoalesced()`, which COALESCES: if a
 * continuous batch sweep was already in flight (and with many agents that takes tens of
 * seconds — each summary cold-spawns the `claude` CLI), the bell's forced pass didn't run
 * until that whole batch drained. So a real "needs you" promotion landed ~tens of seconds
 * late — after the user had already focused the pane, at which point the focus guard
 * (correctly) suppressed it. Net: the alert was silently swallowed.
 *
 * This runs the ONE rung surface's forced classify IMMEDIATELY, in parallel with any
 * in-flight batch, bounded by the SHARED concurrency budget (so it can never exceed
 * `maxConcurrent` — at saturation it defers to the sweep instead). It deliberately relaxes
 * the non-overlap invariant for the BELL PATH ONLY; the continuous pass is untouched.
 *
 * Falls back to the old enqueue+coalesce path (`pendingBellIds` + `wakeSweep`) whenever it
 * can't act now — list failure, the surface raced away, or the budget is full — so a bell
 * is NEVER lost. Returns nothing; self-contained error handling (summarizeOne never throws;
 * listSurfaces is guarded). Exported for testing.
 */
export async function classifyBellNow(
  deps: LoopDeps,
  id: string,
  wakeSweep: () => void,
): Promise<void> {
  const enqueue = (): void => {
    deps.pendingBellIds.add(id);
    wakeSweep();
  };

  let surface: Surface | undefined;
  try {
    surface = (await deps.client.listSurfaces()).find((s) => s.id === id);
  } catch (err) {
    errlog(`bell fast-path list failed: ${err instanceof Error ? err.message : String(err)}`);
    enqueue();
    return;
  }
  // Raced away (closed) or not yet visible in the list — let a later sweep retry/handle it.
  if (!surface) {
    enqueue();
    return;
  }
  // Same gate as the in-sweep forced pass (runSweep): a bell forces past DEBOUNCE but NEVER
  // past the not-agent/hidden gate — we don't promote a non-agent or hidden surface.
  const pre = preGate(surface, deps.lastBySession.get(surface.id), deps.now(), deps.cfg);
  if (!(pre.pass || pre.reason === "debounce")) return;
  // Respect the shared budget. If the batch is already at max concurrency, defer to the
  // coalesced sweep rather than exceed maxConcurrent (which would worsen rate-limits).
  if (!deps.budget.tryAcquire()) {
    enqueue();
    return;
  }
  // Claim the debounce clock NOW so a continuous sweep that starts during our (~15s) call
  // sees this surface as freshly attempted and skips it — no double classify. summarizeOne
  // overwrites this with the real summary on completion; bellRang bypasses debounce, so the
  // claim does not block our own classify.
  const prev = deps.lastBySession.get(surface.id);
  deps.lastBySession.set(surface.id, {
    signals: prev?.signals ?? "",
    tail: prev?.tail ?? "",
    atMs: deps.now(),
    summary: prev?.summary ?? "",
  });
  await summarizeOne(surface, deps, { bellRang: true }); // releases the budget slot in finally
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
  for (const id of [...deps.alertBySession.keys()]) {
    if (!liveIds.has(id)) deps.alertBySession.delete(id);
  }

  // (bell-attention) Decide which surfaces get a FORCED classify this sweep (bellRang).
  // Only when the feature is on — otherwise the sweep is byte-identical to before.
  const forcedBell = new Set<string>();
  if (deps.bellFilter) {
    // PRIMARY: surfaces the bell-reactive loop saw ring via wait_for_event(bell). The GUI
    // posts .ghosttyBellDidRing on EVERY ring regardless of the visual bell-features, so
    // this is the only signal that works in the recommended `bell-features = system,audio`
    // config (where list_surfaces.bell is never armed). Drain it (one-shot per ring).
    for (const id of deps.pendingBellIds) forcedBell.add(id);
    deps.pendingBellIds.clear();
    // BACKSTOP: rising-edge of list_surfaces.bell — catches a ring the event loop missed
    // (e.g. during an MCP reconnect) BUT only when bell-features armed the visual bell
    // (title/border), so it can't be the primary. We compute edges against the PREVIOUS
    // seen state, then refresh the map (and prune dead surfaces).
    for (const s of surfaces) {
      if (bellRoseEdge(deps.bellSeenBySession.get(s.id), s.bell === true)) {
        forcedBell.add(s.id);
        log(`surface ${s.id}: bell rising edge -> force classify (agent=${isAgentSurface(s, deps.cfg)})`);
      }
      deps.bellSeenBySession.set(s.id, s.bell === true);
    }
    for (const id of [...deps.bellSeenBySession.keys()]) {
      if (!liveIds.has(id)) deps.bellSeenBySession.delete(id);
    }
  }

  // (bell-attention) FORCED (bell) pass — ALWAYS runs when a surface rang, INDEPENDENT of
  // the continuous summarizer (`summarizerEnabled`) and EXEMPT from the rate-limit backoff
  // cooldown below. Rationale (the headline of this design): the continuous summarizer's
  // per-poll Haiku calls are EXPENSIVE so they are gated by `agent-manager`; a per-bell
  // classify is RARE, urgent, and FAIL-OPEN (a failed/errored classify PROMOTES), so it
  // must always get its one classify — even with agent-manager OFF (queue-only / bell-only)
  // or while the account is backed off. A bell forces past the DEBOUNCE gate but NEVER past
  // the not-agent/hidden gate. These run sequentially (forced surfaces are few) and are NOT
  // fed into the backoff aggregator (which governs the CONTINUOUS poll cadence only).
  if (forcedBell.size > 0) {
    for (const surface of surfaces) {
      if (!forcedBell.has(surface.id)) continue;
      const pre = preGate(surface, deps.lastBySession.get(surface.id), deps.now(), deps.cfg);
      if (!(pre.pass || pre.reason === "debounce")) continue; // not-agent/hidden: never promote
      if (!deps.budget.tryAcquire()) break;
      await summarizeOne(surface, deps, { bellRang: true });
    }
  }

  // CONTINUOUS summarizer pass — ONLY when agent-manager is enabled. With it OFF (queue-only
  // or bell-only mode) the expensive per-poll Haiku calls never happen; only the cheap
  // per-bell pass above ran. This is the load-bearing decoupling: agent-manager gates the
  // continuous cost, bell-filter gates the cheap promotion, independently.
  if (!deps.summarizerEnabled) return;

  // Cheap pre-gate: the due (changed / non-debounced) NON-forced agents. Forced surfaces
  // were handled above, so EXCLUDE them here (no double-classify).
  const candidates = surfaces.filter(
    (s) =>
      !forcedBell.has(s.id) &&
      preGate(s, deps.lastBySession.get(s.id), deps.now(), deps.cfg).pass,
  );

  // RATE-LIMIT BACKOFF (account-wide): while the summarizer's own calls keep failing,
  // slow WAY down and make at most ONE probe call per window until one succeeds (the
  // limit reset). `failureStreak === 0` is the normal path.
  const bo = deps.summarizerBackoff;
  if (bo.failureStreak > 0) {
    if (deps.now() < bo.nextProbeMs) return; // still cooling down — no model calls
    // PROBE: try candidates sequentially until ONE makes a real model call (not a gate-skip).
    let probed: SummarizeResult | null = null;
    for (const surface of candidates) {
      if (!deps.budget.tryAcquire()) break;
      const r = await summarizeOne(surface, deps);
      if (r !== "skip") { probed = r; break; }
    }
    if (probed === "ok") {
      log(`rate-limit backoff cleared after ${bo.failureStreak} failure(s); resuming`);
      // (diagnostics) The classifier's own account recovered — bells stop fail-opening.
      recordDiag("backoff", { edge: "clear", afterFailures: bo.failureStreak });
      bo.failureStreak = 0;
      bo.nextProbeMs = 0;
    } else if (probed === "fail") {
      bo.failureStreak += 1;
      const delay = backoffDelayMs(bo.failureStreak, deps.cfg.debounceMs, deps.cfg.rateLimitBackoffMaxMs);
      bo.nextProbeMs = deps.now() + delay;
      log(`rate-limit backoff: probe failed (streak ${bo.failureStreak}); next probe in ${Math.round(delay / 1000)}s`);
      recordDiag("backoff", {
        edge: "probe_fail",
        streak: bo.failureStreak,
        nextProbeInS: Math.round(delay / 1000),
      });
    }
    // probed === null ⇒ no real call this sweep (all gate-skipped); leave the backoff
    // untouched and retry on the next sweep.
    return;
  }

  // NORMAL path: fire due (non-forced) surfaces concurrently (bounded by the budget =
  // per-sweep batch cap).
  const fired: Array<Promise<SummarizeResult>> = [];
  for (const surface of candidates) {
    if (!deps.budget.tryAcquire()) break; // budget exhausted this sweep
    fired.push(summarizeOne(surface, deps));
  }

  const results = await Promise.all(fired);
  // ENTER backoff iff this sweep made calls and EVERY one failed (a success anywhere
  // means the account is healthy ⇒ stay normal). A success resets; otherwise arm the
  // first backoff window so the next sweep probes instead of firing the whole batch.
  if (results.includes("ok")) {
    bo.failureStreak = 0;
    bo.nextProbeMs = 0;
  } else if (results.includes("fail")) {
    bo.failureStreak += 1;
    const delay = backoffDelayMs(bo.failureStreak, deps.cfg.debounceMs, deps.cfg.rateLimitBackoffMaxMs);
    bo.nextProbeMs = deps.now() + delay;
    log(`rate-limit backoff engaged: ${results.filter((r) => r === "fail").length} call(s) failed; next probe in ${Math.round(delay / 1000)}s`);
    // (diagnostics) The classifier's own account is throttled ⇒ from here, bell
    // classifies fail-open (verdict:error) into "fake" promotions until it clears.
    recordDiag("backoff", {
      edge: "engage",
      streak: bo.failureStreak,
      failed: results.filter((r) => r === "fail").length,
      nextProbeInS: Math.round(delay / 1000),
    });
  }
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
  // Tee console output to a durable rotating file FIRST, so every log below (incl. the
  // queue engine's run/prune/command lines) is diagnosable after the fact — the Swift
  // controller pipes stdout to an unread pipe and discards stderr, so without this there
  // is no trail (see logfile.ts).
  installFileLogger();
  // (usage/budget tracking) Bound the Haiku-usage log on startup: drop entries
  // older than 14 days so the append-only file can't grow without limit. Recent
  // data (what "last N hours" queries need) is always kept. Best-effort.
  trimUsageLog(14, Date.now());
  const url = process.env.GHOSTTY_MCP_URL ?? "http://127.0.0.1:8765/mcp";
  const token = process.env.GHOSTTY_MCP_TOKEN;

  // Which INDEPENDENT loops to run. The controller launches the sidecar when EITHER
  // feature is on, then arms each loop via its own env flag (see parseLoopEnablement).
  const { summarizer: summarizerEnabled, queue: queueEnabled } =
    parseLoopEnablement(process.env);

  const home = homedir();
  // Optional config overlay (see config.ts): debounce / fuzzy change threshold /
  // hidden-skip / tail windows, tunable in ~/.config/ghostty-ramon/agent-manager/
  // config.json WITHOUT a rebuild (restart the sidecar to apply). Absent ⇒ defaults.
  const { cfg, loaded: cfgLoaded } = loadConfig(home, undefined, errlog);
  if (cfgLoaded) {
    log(
      `loaded summarizer config: debounce=${cfg.debounceMs}ms ` +
        `changeRatio=${cfg.changeRatioThreshold} skipHidden=${cfg.skipHidden} ` +
        `idleSkip=${cfg.idleSkipSeconds}s`,
    );
  }
  const client = new McpClient({ url, token });

  // (bell-attention) The GUI sets GHOSTTY_BELL_FILTER=1 from `agent-manager-bell-filter`
  // when the per-bell promotion feature is on. INDEPENDENT of the summarizer — a bell still
  // promotes (cheap, per-bell, fail-open) when the continuous summarizer is off.
  const bellFilter = process.env.GHOSTTY_BELL_FILTER === "1";

  // Optional ACCOUNT routing (see account.ts). Default ⇒ inherit the ambient Claude Code
  // auth (works with no claude-accounts installed). When set, the model calls bill against
  // the configured account's CLAUDE_CONFIG_DIR. Relevant to ANY Haiku classify — the
  // continuous summarizer AND the per-bell promotion — so it is resolved when EITHER is on
  // (skip it only in pure queue-only mode, which makes no Haiku calls).
  let summarizerConfigDir: string | undefined;
  if (summarizerEnabled || bellFilter) {
    const accountSpec = readAccountSpec(home);
    summarizerConfigDir = resolveAccountDir(accountSpec, home) ?? undefined;
    if (accountSpec && accountSpec.trim() && summarizerConfigDir === undefined) {
      errlog(
        `summarizer account "${accountSpec.trim()}" did not resolve to a directory; using default auth`,
      );
    } else if (summarizerConfigDir) {
      log(`summarizer billing routed to CLAUDE_CONFIG_DIR=${summarizerConfigDir}`);
    }
  }

  // (warm-base) Fork-per-call Haiku reuse — DEFAULT OFF (GHOSTTY_WARMBASE=1). When on
  // AND a Haiku-making feature is armed (summarizer or bell-filter), keep ONE system-only
  // base session per (configDir, systemHash) and fork it per call; every warm-mechanism
  // failure cold-falls-back. Constructed only when enabled; off ⇒ defaultSummarize is
  // wired two-arg as before (byte-identical cold behavior, no projectDir, no sweep).
  let warmBase: WarmBase | undefined;
  if (shouldEnableWarmBase(process.env, summarizerEnabled, bellFilter)) {
    // FLOOR: construction is fully guarded by buildWarmBase (extracted + unit-tested).
    // It runs BEFORE the queue is wired, so an unguarded throw here would kill the
    // whole sidecar at startup merely because GHOSTTY_WARMBASE=1 — buildWarmBase
    // guarantees ANY failure (dynamic SDK import / sweep) leaves warmBase=undefined
    // so the COLD path (the floor) + the QUEUE (zero Haiku calls) still come up.
    // Per-INSTANCE parent (Release vs ReleaseLocal differ by MCP URL port) + a
    // per-LAUNCH run subdir keyed on THIS sidecar's pid (ROUND-2 resolution #2), so
    // neither a coexisting instance NOR an overlapping relaunch can sweep THIS
    // launch's live base. The startup dead-pid sweep reaps only sibling run dirs
    // whose owning pid is dead.
    const instanceKey = warmbaseInstanceKey(url);
    const instanceDir = warmbaseInstanceDir(home, instanceKey);
    const selfRunDirName = warmbaseRunDirName(process.pid);
    warmBase = await buildWarmBase(
      {
        projectDir: warmbaseProjectDir(home, instanceKey, process.pid),
        model: SUMMARIZER_MODEL,
        // SET-ONCE account binding: the single sidecar-wide account used for BOTH
        // summarizer and bell-classify (ROUND-2 resolution #1).
        configDir: summarizerConfigDir,
        claudePath: resolveClaudePath(),
        // Sweep BOTH ambient (~/.claude) and the routed account dir so an account-dir
        // base/fork orphaned by a prior run is reaped, not just ~/.claude leftovers.
        sweepConfigDirs: [undefined, summarizerConfigDir],
        ensureDir: (dir) => {
          try {
            mkdirSync(dir, { recursive: true });
          } catch {
            /* best-effort */
          }
        },
        // Reap sibling run dirs whose owning sidecar pid is dead (pure plan + fs).
        sweepDeadRunDirs: () => {
          let entries: string[] = [];
          try {
            entries = readdirSync(instanceDir);
          } catch {
            return 0; // parent absent on first launch ⇒ nothing to reap
          }
          const dead = planDeadRunDirs(entries, selfRunDirName, (pid) => {
            try {
              process.kill(pid, 0); // signal 0 = liveness probe; throws ESRCH if dead
              return true;
            } catch (e) {
              // EPERM ⇒ alive but not ours; ESRCH ⇒ dead. Only ESRCH means reap.
              return (e as NodeJS.ErrnoException)?.code !== "ESRCH";
            }
          });
          let n = 0;
          for (const name of dead) {
            try {
              rmSync(join(instanceDir, name), { recursive: true, force: true });
              n++;
            } catch {
              /* best-effort */
            }
          }
          return n;
        },
        log,
        errlog,
      },
      loadForkSeam,
    );
  }

  const deps: LoopDeps = {
    client,
    overrides: makeOverrideLoader(),
    cfg,
    budget: new ConcurrencyBudget(cfg.maxConcurrent),
    now: () => Date.now(),
    summarize: makeSummarizeFn(defaultSummarize, warmBase),
    lastBySession: new Map<string, LastSummary>(),
    alertBySession: new Map<string, string>(),
    summarizerEnabled,
    bellFilter,
    bellSeenBySession: new Map<string, boolean>(),
    pendingBellIds: new Set<string>(),
    summarizerBackoff: { failureStreak: 0, nextProbeMs: 0 },
    summarizerConfigDir,
  };
  if (bellFilter) log("bell-attention: bell promotion ENABLED");

  // The AGENT QUEUE SUPERVISOR. ENABLE GATE: only when `agent-queue` is on (the Swift
  // controller sets GHOSTTY_AGENT_QUEUE=1 + GHOSTTY_AGENT_QUEUE_TEMPLATES_DIRS (the full
  // default-first search path, newline-joined) + GHOSTTY_AGENT_QUEUE_MAX_TOTAL from the fork
  // config keys). Absent ⇒ the queue stays a no-op; this is INDEPENDENT of the summarizer
  // (either can run alone).
  if (queueEnabled) {
    // (shared templates §1/§6.2) The effective template SEARCH PATH: the plural env (default-first,
    // deduped by the GUI) split on "\n"; back-compat singular GHOSTTY_AGENT_QUEUE_TEMPLATES_DIR as
    // a one-element list; else [defaultTemplatesDir()]. First-in-search-order wins on a basename clash.
    const searchPath = parseTemplatesDirs(process.env);
    const stateDir = defaultStateDir();
    // agent-queue-max-total: an OPTIONAL fleet-wide cap. A positive value caps the
    // total agents across ALL runs; 0 / absent / invalid ⇒ UNLIMITED (Infinity), so
    // the fleet is bounded only by each run's own concurrency/maxItems/grid. (The GUI
    // forwards the config value, defaulting to 0 = unlimited.)
    const maxTotal =
      parsePositiveInt(process.env.GHOSTTY_AGENT_QUEUE_MAX_TOTAL, 0) || Infinity;
    // (hero) agent-queue-hero-max: the FLEET-WIDE ceiling on live HEROES across ALL runs,
    // ORTHOGONAL to maxTotal/concurrency/maxItems (HERO-AGENTS.md § Slot accounting). Default 2.
    // ⚠️ INVERSION vs maxTotal: for HEROES `0` means DISABLED (no new hero dispatches — a
    // discipline limit, not a resource one), NOT unlimited. So an EXPLICIT "0" must survive as 0
    // (`parsePositiveInt` would clamp 0 back to the default), while an absent/blank/invalid env
    // falls back to the default 2. `parseNonNegativeInt` honors 0.
    const heroMax = parseNonNegativeInt(process.env.GHOSTTY_AGENT_QUEUE_HERO_MAX, 2);

    // ON-DEMAND run lifecycle (§8a): runs are NOT auto-started from every template.
    // Build a DYNAMIC registry, REHYDRATE any previously-started runs from the persisted
    // active-runs set (so a started queue + its in-flight items survive a sidecar restart
    // with no re-dispatch — §9), and DRAIN GUI→sidecar `start/pause/stop/abort` commands
    // each sweep. A template merely existing on disk does NOT auto-run — only a
    // persisted/started run, or one a `start` command arms.
    const registry: RunRegistry = new Map();
    // Key restored runs by their `runName` IDENTITY — the SAME key `start` uses — so
    // control commands (set_max_items/pause/stop/…) resolve against a rehydrated run, and
    // parallel scoped runs of one template don't collide on the bare template name.
    registerRehydratedRuns(registry, rehydrateActiveRuns(searchPath, stateDir));
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
      factory: makeFileRunFactory(searchPath, stateDir),
      takeCommands: () => client.takeQueueCommands(),
      persistActiveRuns: (records: ActiveRunRecord[]) =>
        persistActiveRunsToIO(activeRunsIO, records),
      maxTotal,
      // (hero) the fleet-wide hero ceiling (0 = disabled; see the parse above).
      heroMax,
      pendingGraceMs: DEFAULT_PENDING_GRACE_MS,
      // (adopt) The on-demand Haiku key-inference seam for an `infer_key` queue command. Reads
      // the surface, calls Haiku with a bespoke "extract the issue key" prompt (warm-base aware
      // via the shared `deps.summarize`), and writes the result back as the `queueKeySuggested`
      // annotation so the GUI adopt modal prefills. BEST-EFFORT: any failure (Haiku unavailable
      // / sidecar disabled / unparseable) writes the `""` sentinel so the modal always drops its
      // spinner. Usage is tagged with the THIRD feature `issue-key-infer` (alongside
      // summarizer/bell-classify) — broken out by get_haiku_usage automatically.
      inferKey: (surfaceUUID: string, runName: string): Promise<void> => {
        const usageAccount = summarizerConfigDir ? basename(summarizerConfigDir) : "ambient";
        return runInferKeyWithDeps(surfaceUUID, runName, {
          readSurface: (id) => client.readSurface(id),
          setAnnotation: (id, ann) => client.setAnnotation(id, ann),
          // The shared, warm-base-aware summarize seam (cast through the structural `unknown`
          // onUsage the infer deps declare; the real callback receives the SDK HaikuUsage).
          summarize: (req) =>
            deps.summarize({
              ...req,
              onUsage: req.onUsage as ((u: HaikuUsage) => void) | undefined,
            }),
          candidates: (name) => collectCandidateKeys(registry, name),
          tail: (text) => lastLines(text, cfg.promptTailLines),
          configDir: summarizerConfigDir,
          recordUsage: (u, durationMs) =>
            recordUsage({
              ...(u as HaikuUsage),
              feature: "issue-key-infer",
              account: usageAccount,
              durationMs,
            }),
          now: () => Date.now(),
          errlog,
        });
      },
    };
    log(
      `queue: supervisor armed (on-demand); ${registry.size} run(s) rehydrated; ` +
        `templatesDirs=[${searchPath.join(", ")}]; maxTotal=${maxTotal}; heroMax=${heroMax}`,
    );
  }

  log(
    `sidecar started; MCP=${url} summarizer=${summarizerEnabled} ` +
      `queue=${deps.queue !== undefined} bellFilter=${bellFilter} ` +
      `warmBase=${warmBase !== undefined} (poll ${POLL_INTERVAL_MS}ms)`,
  );

  // The controller's gate guarantees at least one of the THREE loops is armed, but guard
  // anyway: with nothing to run (no summarizer, no queue, AND no bell promotion) return so
  // the process exits cleanly rather than idle forever holding the MCP connection.
  if (!summarizerEnabled && deps.queue === undefined && !bellFilter) {
    errlog("neither summarizer, queue, nor bell-filter is enabled; nothing to do — exiting");
    return;
  }

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

  // (orphan guard) Watch for the parent GUI dying. The controller's `teardown()` is
  // best-effort — it never runs on a GUI crash / SIGKILL, and can lose the race on a clean
  // quit — so a sidecar can be orphaned (reparented), keep polling, and then silently resume
  // reporting to the NEXT GUI that rebinds the same loopback MCP port. That split-brain is
  // what made the Agent Queue health row alternate between two diverged snapshots. Tie our
  // life to the parent's: once reparented, exit. `.unref()` so the timer alone never keeps an
  // otherwise-idle process alive.
  const parentPid = parseParentPid(process.env.GHOSTTY_PARENT_PID);
  const parentWatch = setInterval(() => {
    if (shouldExitForParentDeath(process.ppid, parentPid)) {
      log(`parent GUI gone (ppid now ${process.ppid}, expected ${parentPid ?? "?"}); exiting`);
      shutdown("parent-death");
    }
  }, PARENT_WATCH_INTERVAL_MS);
  parentWatch.unref();

  // (bell-attention v2 slice 4) Both the 5s timer and the bell-reactive long-poll run
  // sweeps through this COALESCED runner, so a bell event can wake an immediate classify
  // without ever overlapping the periodic sweep (which would race the shared bell-edge /
  // alert bookkeeping in `deps`). The sweep itself does all the work; the reactive loop
  // only wakes it.
  const runSweepCoalesced = makeCoalescedRunner(async () => {
    try {
      await runSweep(deps);
    } catch (err) {
      // runSweep already catches its own errors, but belt-and-suspenders so the
      // loop can never die from an unexpected throw.
      errlog(`sweep error: ${err instanceof Error ? err.message : String(err)}`);
    }
  }, () => stopped);

  // Self-pacing loop: run a sweep, then schedule the next POLL_INTERVAL_MS after
  // it settles (no overlap). setTimeout (not setInterval) avoids piling sweeps
  // when a sweep runs long.
  const tick = async (): Promise<void> => {
    if (stopped) return;
    await runSweepCoalesced();
    if (!stopped) timer = setTimeout(() => void tick(), POLL_INTERVAL_MS);
  };

  // (bell-attention v2 slice 4) BELL-REACTIVE loop: long-poll wait_for_event(bell) and
  // wake an immediate classify so a promotion lands in ~1-2s instead of up to
  // POLL_INTERVAL_MS (sound-only until then). The 5s `tick` stays as the backstop (it
  // also drives summaries + catches any missed event). Only armed when bell promotion is
  // enabled (`bellFilter`); without it there is no attention tier to promote into. The
  // loop NEVER exits on error (fail-open: a recovered MCP re-arms after a short backoff).
  const bellReactiveLoop = async (): Promise<void> => {
    while (!stopped) {
      let ev: { id: string; type: string } | null;
      try {
        ev = await deps.client.waitForEvent({ types: ["bell"], timeoutMs: BELL_WAIT_MS });
      } catch (err) {
        errlog(`bell wait failed: ${err instanceof Error ? err.message : String(err)}`);
        await sleep(BELL_WAIT_RETRY_MS);
        continue;
      }
      if (stopped) return;
      if (ev) {
        // PREEMPTIVE classify: run the rung surface's forced classify NOW, in parallel with
        // any in-flight continuous batch (bounded by the shared budget), instead of coalescing
        // behind it — so a real promotion lands in ~1 model-call instead of after the whole
        // batch drains. classifyBellNow falls back to the enqueue+coalesce path (pendingBellIds
        // + runSweepCoalesced) when it can't act now, so a bell is never lost. Detached so the
        // loop keeps long-polling for the next bell; it owns its errors but .catch belt-and-
        // suspenders against an unexpected reject in a detached promise.
        log(`bell event on ${ev.id} -> preemptive classify`);
        void classifyBellNow(deps, ev.id, runSweepCoalesced).catch((err) =>
          errlog(`bell fast-path failed: ${err instanceof Error ? err.message : String(err)}`),
        );
      }
      // ev === null ⇒ park timeout; just loop and re-park.
    }
  };

  // INDEPENDENT queue loop (ramon fork / Agent Queue): the deterministic supervisor
  // runs on its OWN self-paced timer, NOT inside `tick`/`runSweep`. This decouples the
  // latency-sensitive queue (dispatch/track/close) from the slow LLM summarizer pass —
  // with many agents a single `runSweep` can take tens of seconds, which would otherwise
  // starve the queue. Only armed when a queue is configured. Same non-overlapping
  // self-pace as `tick`.
  // (Agent Queue latency) Coalesced queue-sweep runner shared by the 5s `queueTick` timer AND
  // the queue-reactive wake below, so the two NEVER overlap (both mutate the shared run store):
  // a trigger arriving mid-sweep sets the coalescer's re-run flag instead of starting a second
  // concurrent sweep. This makes the reactive wake safe to add alongside the self-paced timer.
  const runQueueSweepCoalesced = makeCoalescedRunner(
    async () => {
      await runQueueSweepSafe(deps); // self-isolating; no-op when no queue configured
    },
    () => stopped,
  );
  const queueTick = async (): Promise<void> => {
    if (stopped) return;
    await runQueueSweepCoalesced();
    if (!stopped) queueTimer = setTimeout(() => void queueTick(), QUEUE_POLL_INTERVAL_MS);
  };

  // (Agent Queue latency) QUEUE-REACTIVE loop: long-poll wait_for_event(queue_command) and wake
  // an immediate supervisor sweep so a dashboard adopt/promote/pause/stop lands in ~1 round-trip
  // instead of waiting out the in-flight sweep + the QUEUE_POLL_INTERVAL_MS gap. The 5s queueTick
  // stays as the BACKSTOP (and catches any event missed while a sweep was mid-flight). Only armed
  // when a queue is configured + the server supports wait_for_event. NEVER exits on error
  // (fail-open: a recovered MCP re-arms after a short backoff). The sweep is DETACHED + coalesced
  // (shared with queueTick), so the loop re-parks IMMEDIATELY and a command enqueued DURING a sweep
  // is caught on the next park (or the server's 0.5s event-ring coalesce) — never overlapping the
  // timer sweep, never lost.
  const queueReactiveLoop = async (): Promise<void> => {
    while (!stopped) {
      let ev: { id: string; type: string } | null;
      try {
        ev = await deps.client.waitForEvent({ types: ["queue_command"], timeoutMs: QUEUE_WAIT_MS });
      } catch (err) {
        errlog(`queue-command wait failed: ${err instanceof Error ? err.message : String(err)}`);
        await sleep(QUEUE_WAIT_RETRY_MS);
        continue;
      }
      if (stopped) return;
      if (ev) {
        log("queue command event -> immediate sweep");
        void runQueueSweepCoalesced().catch((err) =>
          errlog(`queue reactive sweep failed: ${err instanceof Error ? err.message : String(err)}`),
        );
        // ANTI-SPIN: wait past the GUI's coalesce window before re-parking so this same event
        // can't immediately re-resolve the next `wait_for_event` (see QUEUE_REACTIVE_MIN_INTERVAL_MS).
        // Without this the loop spins at hundreds of wakes/sec for the whole 0.5s window — an
        // event storm that saturates the MCP server and beachballs the GUI.
        await sleep(QUEUE_REACTIVE_MIN_INTERVAL_MS);
      }
      // ev === null ⇒ park timeout; just loop and re-park.
    }
  };

  // Start the INDEPENDENT queue loop FIRST, so it is never delayed (or blocked
  // forever) by the slow — or occasionally hanging — first summarizer sweep in
  // `tick`. Each loop runs only when its feature is armed; whichever are on run
  // concurrently on the event loop, and their pending timers keep the process alive.
  if (deps.queue !== undefined) void queueTick();
  // (Agent Queue latency) Arm the queue-reactive command wake alongside the timer, so a GUI
  // adopt/promote/pause/stop drains in ~1 round-trip instead of on the next 5s tick. Independent
  // of the summarizer/bell loops; needs only a queue + the wait_for_event capability.
  if (deps.queue !== undefined && typeof deps.client.waitForEvent === "function") {
    log("agent-queue: event-driven command wake ENABLED (wait_for_event)");
    void queueReactiveLoop();
  }
  // (bell-attention) The bell-reactive loop is INDEPENDENT of the continuous summarizer:
  // it runs whenever bell promotion is on (+ the waitForEvent capability exists), so a bell
  // still promotes (cheap, per-bell, fail-open) even with agent-manager OFF (queue-only or
  // bell-only mode). The classify it wakes runs ONLY the forced surface — `runSweep` gates
  // the expensive continuous pass on `summarizerEnabled`.
  if (deps.bellFilter && typeof deps.client.waitForEvent === "function") {
    log("bell-attention: event-driven classify ENABLED (wait_for_event)");
    void bellReactiveLoop();
  }
  // The 5s CONTINUOUS summarizer poll runs ONLY when agent-manager is enabled (the expensive
  // path). `await` it so main() stays alive on the summarizer's timer; when it's off, the
  // queue and/or bell-reactive loops keep the process alive via their own pending work.
  if (summarizerEnabled) await tick();
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

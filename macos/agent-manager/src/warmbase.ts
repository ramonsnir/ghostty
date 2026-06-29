// (ramon fork / Agent Manager) Warm-base fork-per-call reuse for Haiku calls.
//
// The cost win (measured; see AGENT-MANAGER-WARMBASE-DESIGN.md): every cold
// `claude` spawn re-CREATES a ~25-32k-token prompt-cache entry ($2/MTok),
// ~79% of the bill. Instead we keep ONE *system-only base session* per
// `(configDir, systemHash)`, and for each summarize/classify call:
//   forkSession(baseId) -> query({resume: forkId}) -> read result -> deleteSession(forkId)
// The fork READS the base's already-cached system prefix ($0.10/MTok) instead of
// re-creating it. Isolation is STRUCTURAL: each fork branches from the system-only
// base, so it sees ONLY its own surface — which is why bell-classify is safe here.
//
// DEFAULT OFF (`GHOSTTY_WARMBASE=1` turns it on). The COLD path is the FLOOR: every
// warm-MECHANISM failure (base-create / fork / resume-base-gone / timeout) degrades
// to today's cold one-shot for THAT surface via `WarmBaseUnavailable`, which model.ts
// catches. A genuine model error/result is rethrown PLAIN so model.ts does NOT
// cold-retry (no double-call, no double-cost).
//
// Loaded LAZILY (dynamic import) the SAME way model.ts loads the SDK — so the module
// loads with no node_modules and esbuild inlines the SDK JS into dist/.

import type * as ClaudeAgentSDK from "@anthropic-ai/claude-agent-sdk";
import type { HaikuUsage } from "./usage.js";

import { join } from "node:path";
import { createHash } from "node:crypto";

/** The query() function signature we depend on — injectable for tests. */
export type QueryFn = typeof ClaudeAgentSDK.query;

/**
 * The SDK session subset we depend on, injectable for tests. `dir` is REQUIRED on
 * OUR calls (we always pin `projectDir`) even though the SDK types it OPTIONAL — so
 * this is its OWN interface, NOT `typeof sdk.forkSession` (a `typeof` alias would
 * reject our required-`dir` callers). `loadForkSeam` casts the real SDK fns in.
 */
export interface ForkSeam {
  query: QueryFn;
  forkSession: (
    id: string,
    opts: { dir: string; title?: string },
  ) => Promise<{ sessionId: string }>;
  deleteSession: (id: string, opts: { dir: string }) => Promise<void>;
  listSessions: (opts: {
    dir: string;
  }) => Promise<
    Array<{ sessionId: string; summary?: string; customTitle?: string }>
  >;
}

/**
 * Lazy real-SDK seam — the SAME dynamic import as model.ts so the module loads
 * with no node_modules and esbuild bundles all four fns into dist/.
 */
export async function loadForkSeam(): Promise<ForkSeam> {
  const sdk = await import("@anthropic-ai/claude-agent-sdk");
  return {
    query: sdk.query,
    forkSession: sdk.forkSession as ForkSeam["forkSession"],
    deleteSession: sdk.deleteSession as ForkSeam["deleteSession"],
    listSessions: sdk.listSessions as ForkSeam["listSessions"],
  };
}

/** Tags every fork WE create (the GC-sweep match key). */
export const FORK_TITLE_PREFIX = "ghostty-am-fork:";
/**
 * Tags every system-only BASE WE create. Bases are large (~25-32k-token system
 * prefix) and were previously NEVER reaped — so every sidecar/GUI relaunch minted
 * fresh ones and orphaned the prior process's base `.jsonl` files under projectDir
 * permanently (an unbounded disk leak). A new process can NOT reuse a prior
 * in-memory base id anyway (the cache is process-local), so the startup sweep
 * deletes ALL prior bases too — symmetric with fork GC (design gotcha #2).
 */
export const BASE_TITLE_PREFIX = "ghostty-am-base:";
/** Per-call fork+resume deadline; on overrun the call cold-falls-back. */
export const WARMBASE_CALL_TIMEOUT_MS = 30_000;
/**
 * Base-CREATE deadline. FLOOR-critical: `createBase` runs a full SDK `query()`
 * warmup that can HANG. Because the base future is single-flight CACHED and every
 * surface joins it via `await baseFut`, a hung create with NO deadline would wedge
 * the entire summarizer loop PERMANENTLY (strictly worse than today's per-call
 * cold floor). On overrun we abort the warmup query and reject so the in-flight
 * `run()` maps it to `WarmBaseUnavailable('base-create')` (cold-fallback) AND the
 * rejected future self-evicts from the `bases` map (so the NEXT call re-attempts a
 * FRESH base rather than re-joining the dead one). Generous vs the per-call
 * deadline because a cold cache-CREATE warmup is the slow leg.
 */
export const WARMBASE_BASE_CREATE_TIMEOUT_MS = 60_000;

/**
 * The per-INSTANCE PARENT directory: `<…>/agent-manager/warmbase[-<instanceKey>]`.
 * Sibling per-LAUNCH run dirs live UNDER this dir, and the startup dead-pid sweep
 * (see `planDeadRunDirs`) operates over its entries. PURE.
 *
 * CONCURRENT-PROCESS SWEEP STOMP MITIGATION (ROUND-2 resolution #2): a Release and a
 * ReleaseLocal sidecar coexist (different MCP/web-monitor ports). When an
 * `instanceKey` is supplied (a STABLE per-instance discriminator — a hash of the
 * MCP URL, which differs by port between Release/ReleaseLocal yet is the SAME across
 * restarts of one instance), each instance gets its OWN `warmbase-<instanceKey>`
 * parent, so the two instances never share a parent and one can never sweep the
 * other's run dirs. Omitted ⇒ the legacy shared `warmbase` parent (byte-identical
 * for the single-instance/back-compat case + tests).
 */
export function warmbaseInstanceDir(home: string, instanceKey?: string): string {
  const leaf =
    instanceKey && instanceKey.trim()
      ? `warmbase-${instanceKey.trim()}`
      : "warmbase";
  return join(home, ".config", "ghostty-ramon", "agent-manager", leaf);
}

/** The per-launch run-dir basename for a pid/run-id: `run-<runId>`. PURE. */
export function warmbaseRunDirName(runId: string | number): string {
  return `run-${runId}`;
}

/**
 * The actual app-owned cwd pinned on EVERY query (base-create AND per-call resume)
 * so the SDK's projectKey (derived from session cwd) is deterministic and EQUALS
 * the dir the GC sweep lists/deletes from (LOCKED #2: write-location ==
 * sweep-location). PURE.
 *
 * PER-LAUNCH ISOLATION (ROUND-2 resolution #2): when `runId` (this sidecar's pid /
 * a run-id) is given, the cwd is a per-LAUNCH subdir `<instanceDir>/run-<runId>`, so
 * each LAUNCH has its OWN projectKey namespace — even two launches of the SAME
 * instance (e.g. a brief overlap during a relaunch) can't see or sweep each other's
 * live base. The startup dead-pid sweep then reaps only sibling run dirs whose pid
 * is dead (`planDeadRunDirs`), bounding disk without ever touching a live peer.
 * `runId` OMITTED ⇒ the instance dir itself (byte-identical legacy/back-compat for
 * existing callers + the warmbase unit tests, which pin `/proj`).
 */
export function warmbaseProjectDir(
  home: string,
  instanceKey?: string,
  runId?: string | number,
): string {
  const dir = warmbaseInstanceDir(home, instanceKey);
  return runId !== undefined && `${runId}`.trim() !== ""
    ? join(dir, warmbaseRunDirName(`${runId}`.trim()))
    : dir;
}

/**
 * Stable 12-hex-char instance discriminator from a per-instance string (the MCP URL,
 * whose port differs between the Release and ReleaseLocal sidecars but is stable
 * across restarts of one instance). Used to give each coexisting instance its OWN
 * warmbase store subtree (see `warmbaseInstanceDir`). Empty/whitespace ⇒ undefined
 * (the shared legacy dir). PURE.
 */
export function warmbaseInstanceKey(seed: string | undefined): string | undefined {
  if (!seed || !seed.trim()) return undefined;
  return createHash("sha256").update(seed.trim()).digest("hex").slice(0, 12);
}

/**
 * PURE planner for the per-launch dead-pid run-dir sweep (ROUND-2 resolution #2):
 * given the sibling entry names under the instance dir, THIS launch's own run-dir
 * name (NEVER removed — it's live), and a liveness predicate over a pid, return the
 * names of run dirs to remove. A dir is removed ONLY if it matches `run-<pid>` with
 * a numeric pid AND `isAlive(pid)` is false — i.e. its owning sidecar is dead. Any
 * non-`run-*` entry (and the legacy non-run-dir store, which has no pid) is left
 * untouched, so an unrelated file or a back-compat shared base is never deleted.
 * "Removes only stale run dirs whose pid is dead."
 */
export function planDeadRunDirs(
  entries: ReadonlyArray<string>,
  selfRunDirName: string,
  isAlive: (pid: number) => boolean,
): string[] {
  const out: string[] = [];
  for (const name of entries) {
    if (name === selfRunDirName) continue; // never sweep our own live run dir
    const m = /^run-(\d+)$/.exec(name);
    if (!m) continue; // not a pid-tagged run dir ⇒ leave alone
    const pid = Number(m[1]);
    if (!Number.isInteger(pid) || pid <= 0) continue;
    if (!isAlive(pid)) out.push(name);
  }
  return out;
}

/**
 * Stable 16-hex-char hash of the system prefix — part of the cache key so a changed
 * system prompt (an edited summarizer.md override) lazily creates a FRESH base,
 * keeping warm behavior identical to the cold per-call `overrides.load()`. PURE.
 */
export function systemHash(system: string): string {
  return createHash("sha256").update(system).digest("hex").slice(0, 16);
}

/**
 * cacheKey = `${configDir ?? "ambient"}:${model}:${systemHash(system)}`. PURE.
 *
 * The `model` IS part of the key (ROUND-2 resolution #3 — "fold model into the
 * cache key"). The base's server-side prompt-prefix cache is keyed by
 * (account, MODEL, system-prefix): it is WRITTEN by the warmup model and READ
 * back ($0.10/MTok) only when the per-call resume uses the SAME model. If two
 * different models ever shared one base (e.g. a Sonnet summarizer beside a Haiku
 * bell-classify under the same (configDir, system)), a resume under the OTHER
 * model would silently re-CREATE the prefix ($2/MTok cacheWrite, no error) and
 * defeat the entire win — a latent landmine. Keying on the model removes it:
 * each (account, model, system) gets its OWN base, so the cacheRead win always
 * holds and adding a second model is automatically safe. Today the wiring still
 * passes the single SUMMARIZER_MODEL to BOTH the warmup and every resume, so in
 * practice there is exactly one base per (configDir, system); this just makes the
 * mechanism robust to that ever changing.
 */
export function warmbaseCacheKey(
  configDir: string | undefined,
  model: string,
  system: string,
): string {
  return `${configDir ?? "ambient"}:${model}:${systemHash(system)}`;
}

/**
 * Run `fn` with `process.env.CLAUDE_CONFIG_DIR` bound to `configDir` (or with the
 * key DELETED when `configDir` is undefined = ambient), restoring the prior value
 * (or deleting it if it was unset) on EVERY exit — resolve OR reject.
 *
 * ⚠️ SUPERSEDED for the PER-CALL path by the SET-ONCE binding (ROUND-2 resolution
 * #1, see {@link WarmBase}'s constructor). The original LOCKED #4a design wrapped
 * EVERY `run()` body in this temporary env mutation; that is now GONE because
 * `process.env.CLAUDE_CONFIG_DIR` is set ONCE at WarmBase construction and never
 * mutated per-call (race-free; no overlapping-region hazard between concurrent
 * forks). `run()` instead GUARDS that `req.configDir` equals the constructed
 * configDir and cold-falls-back if it ever differs, so the constant binding is
 * never wrong for a call we actually serve.
 *
 * This wrapper SURVIVES for ONE narrow, NON-per-call use: the one-time STARTUP
 * SWEEP (`sweepOrphanForks`), which may need to reap orphans left under a
 * DIFFERENT root than the bound account (e.g. ambient `~/.claude` leftovers from a
 * prior run that did NOT use account routing, in addition to the bound account's
 * own orphans). The sweep runs BEFORE any per-call work, so its temporary
 * per-root binding cannot race a concurrent fork. It restores even on reject.
 *
 * WHY a binding is needed at all (the account-routed store blocker): the
 * in-process SDK session store fns `forkSession`/`deleteSession`/`listSessions`
 * take NO env option and resolve their store root from
 * `process.env.CLAUDE_CONFIG_DIR ?? ~/.claude` AT CALL TIME. A base written under
 * `<account>/projects/<key>` is invisible to a fork/list/delete reading
 * `~/.claude`: fork MISSES (feature silently no-ops to the cold floor) and the
 * account-dir base + leaked forks are NEVER reaped. The set-once constructor
 * binding closes this for the per-call path; this wrapper closes it for the
 * cross-root startup sweep.
 */
export async function withConfigDirEnv<T>(
  configDir: string | undefined,
  fn: () => Promise<T>,
): Promise<T> {
  const had = Object.prototype.hasOwnProperty.call(
    process.env,
    "CLAUDE_CONFIG_DIR",
  );
  const prev = process.env.CLAUDE_CONFIG_DIR;
  if (configDir === undefined) {
    delete process.env.CLAUDE_CONFIG_DIR;
  } else {
    process.env.CLAUDE_CONFIG_DIR = configDir;
  }
  try {
    return await fn();
  } finally {
    if (had) {
      process.env.CLAUDE_CONFIG_DIR = prev as string;
    } else {
      delete process.env.CLAUDE_CONFIG_DIR;
    }
  }
}

/** Default OFF. `GHOSTTY_WARMBASE=1` turns it on. PURE over its injected env. */
export function warmbaseEnabled(
  env: Record<string, string | undefined> = process.env,
): boolean {
  return env.GHOSTTY_WARMBASE === "1";
}

/** Haiku-4.5 $/MTok; cacheWrite is the 1h-TTL rate per the design. */
export const HAIKU_RATES = {
  input: 1,
  output: 5,
  cacheWrite: 2,
  cacheRead: 0.1,
};

/**
 * PURE per-call cost from token buckets (LOCKED #1 — NEVER trust `total_cost_usd`,
 * which is cumulative-per-session). Used for BOTH warm and cold so savings are
 * directly comparable in `get_haiku_usage`, and immune to the cumulative-vs-per-turn
 * question.
 */
export function costFromUsage(u: {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheCreationTokens: number;
}): number {
  return (
    (u.inputTokens * HAIKU_RATES.input +
      u.outputTokens * HAIKU_RATES.output +
      u.cacheCreationTokens * HAIKU_RATES.cacheWrite +
      u.cacheReadTokens * HAIKU_RATES.cacheRead) /
    1_000_000
  );
}

/**
 * Thrown by `WarmBase.run` ONLY for warm-MECHANISM failures (base-create / fork /
 * resume-base-gone / timeout). model.ts catches it and falls back to the cold
 * one-shot. A genuine model outcome (error-subtype result / no-result) OR a real
 * model/transport throw is rethrown as a PLAIN Error so the caller does NOT
 * cold-retry (a retry would re-hit the same model error + DOUBLE the cost).
 */
export class WarmBaseUnavailable extends Error {
  constructor(
    public readonly kind:
      | "base-create"
      | "fork"
      | "resume"
      | "timeout"
      | "config-mismatch",
    cause?: unknown,
  ) {
    super(
      `warm-base unavailable: ${kind}${
        cause instanceof Error ? `: ${cause.message}` : ""
      }`,
    );
    this.name = "WarmBaseUnavailable";
  }
}

/**
 * PURE predicate: a resume error whose message says the cached base file is
 * missing/corrupt -> invalidate + cold-fallback as kind "resume". Deliberately
 * does NOT match plain "rate limit"/"overloaded" transport messages, so a genuine
 * model error is rethrown plain (no self-heal, no cold double-call).
 */
export function looksLikeBaseGone(e: unknown): boolean {
  const msg = e instanceof Error ? e.message : String(e);
  // FALSE-POSITIVE GUARD: a genuine quota/transport model error that happens to
  // contain "session"/"resume" (e.g. "session limit reached", "resume your
  // subscription") must NOT be misread as base-gone, or we needlessly recreate the
  // base + cold-fall-back. The floor is preserved either way (cold-fallback), but a
  // narrower match avoids needless base churn. Require a "missing"-shaped phrase
  // ALONGSIDE the session/resume keyword, OR an unambiguous filesystem signal.
  if (/\b(limit|quota|overloaded|rate.?limit|subscription|expired)\b/i.test(msg)) {
    return false;
  }
  return (
    /ENOENT|no such file/i.test(msg) ||
    /\b(not found|missing|does not exist|cannot find|could not (?:find|resume|load))\b/i.test(
      msg,
    ) ||
    /\b(corrupt|invalid)\b.*\b(session|resume)\b/i.test(msg) ||
    /\b(session|resume)\b.*\b(corrupt|invalid|not found|missing|gone)\b/i.test(msg)
  );
}

export interface WarmBaseDeps {
  seam: ForkSeam;
  /** From `warmbaseProjectDir(home)` — pinned as cwd on every query + the GC dir. */
  projectDir: string;
  /** SUMMARIZER_MODEL — the model for the base's warmup query. */
  model: string;
  /**
   * The SINGLE sidecar-wide account this WarmBase is BOUND to (ROUND-2 resolution
   * #1). When provided, the constructor sets `process.env.CLAUDE_CONFIG_DIR` to it
   * EXACTLY ONCE so every SDK op (base-create / fork / resume / delete / list)
   * resolves the SAME account store — race-free, no per-call env mutation. `run()`
   * GUARDS that each `req.configDir` equals this value and cold-falls-back if it
   * ever differs (never corrupt the global binding). OMITTED ⇒ ambient (no binding
   * set; back-compat for the single-account/no-routing case + most unit tests).
   * Equals `index.ts`'s `summarizerConfigDir`, used for BOTH summarizer AND
   * bell-classify (verified single sidecar-wide account).
   */
  configDir?: string;
  /** resolveClaudePath(), pinned at construct. */
  claudePath?: string;
  /** Default WARMBASE_CALL_TIMEOUT_MS. */
  timeoutMs?: number;
  /** Base-create deadline; default WARMBASE_BASE_CREATE_TIMEOUT_MS. */
  baseTimeoutMs?: number;
  /** Debug log seam (fallback-rate visibility); never affects control flow. */
  log?: (m: string) => void;
}

export interface WarmRunRequest {
  system: string;
  user: string;
  model: string;
  /**
   * CLAUDE_CONFIG_DIR (account binding); OMITTED ⇒ ambient. MUST equal the
   * `configDir` the WarmBase was CONSTRUCTED with — the account store is bound ONCE
   * at construction and never re-bound (ROUND-2 resolution #1). `run()` guards this:
   * a differing value cold-falls-back (`WarmBaseUnavailable("config-mismatch")`).
   */
  configDir?: string;
  /** costUsd is token-bucket; mode is set to "warm". */
  onUsage?: (u: HaikuUsage) => void;
}

export class WarmBase {
  /** cacheKey -> Promise<baseId>, single-flight. */
  private bases = new Map<string, Promise<string>>();

  /**
   * ROUND-2 resolution #1 (the account/store-binding BLOCKER fix): bind the SINGLE
   * sidecar-wide account to `process.env.CLAUDE_CONFIG_DIR` EXACTLY ONCE, here at
   * construction, and NEVER mutate it per-call. The SDK resolves its session-store
   * ROOT from `process.env.CLAUDE_CONFIG_DIR` AT CALL TIME and takes NO env option
   * on the store fns (`forkSession`/`deleteSession`/`listSessions`), so this one
   * binding is what makes base-create, fork, resume, delete, and the startup sweep
   * ALL resolve the SAME account store. Doing it once (vs. the superseded LOCKED
   * #4a per-call `withConfigDirEnv` wrapper) is RACE-FREE: there is no window where
   * one in-flight fork sees a different account than another. `run()` enforces the
   * single-account assumption with a guard (a differing `req.configDir` cold-falls-
   * back) so the constant binding is never wrong for a served call. When
   * `configDir` is omitted (ambient / no routing) we set NOTHING — the SDK uses its
   * default `~/.claude`, exactly as before.
   */
  constructor(private readonly d: WarmBaseDeps) {
    if (d.configDir !== undefined) {
      process.env.CLAUDE_CONFIG_DIR = d.configDir;
    }
  }

  /**
   * Lazy create + single-flight + self-heal-on-create-failure. A failed-create
   * future is evicted (identity-guarded) so a later call re-attempts createBase.
   */
  private baseFor(cacheKey: string, system: string): Promise<string> {
    const existing = this.bases.get(cacheKey);
    if (existing) return existing;
    const fut = this.createBase(system);
    this.bases.set(cacheKey, fut);
    // Evict a failed-create future, but only if it is still the cached one (a
    // concurrent re-base under the same key must not be clobbered).
    fut.catch(() => {
      if (this.bases.get(cacheKey) === fut) this.bases.delete(cacheKey);
    });
    return fut;
  }

  /**
   * ONE warmup query that establishes the system-only base; returns its session id.
   *
   * EFFICACY-CRITICAL: we DRAIN to the `type:"result"` message before returning,
   * rather than returning early on the `type:"system"` init (which is emitted at
   * STREAM START, before the warmup turn's API round-trip completes). The whole
   * point of the base is that the server has WRITTEN the ~25-32k-token system-prefix
   * prompt cache, so that the per-call fork+resume reads it ($0.10/MTok) instead of
   * re-creating it ($2/MTok). The `finally` aborts the controller on EVERY exit
   * path; returning on the early init message would very likely cancel the warmup
   * request BEFORE the server persists the cache, so the base would not actually be
   * pre-warmed (the design's measured $0.0035/call assumes a COMPLETED warmup turn).
   * We still CAPTURE the session_id from whichever message carries it first (init or
   * result), but only RETURN once the result message arrives — i.e. once the
   * round-trip that warms the cache has finished. Account-bound via the SET-ONCE
   * `process.env.CLAUDE_CONFIG_DIR` (constructor) PLUS the redundant per-query
   * `options.env` leg. Does NOT call onUsage (the warmup cost is amortized).
   */
  private async createBase(system: string): Promise<string> {
    // ACCOUNT-ROUTED STORE BINDING (ROUND-2 resolution #1): the warmup query
    // persists the base's session `.jsonl` in-process under the store ROOT the SDK
    // reads from `process.env.CLAUDE_CONFIG_DIR` AT CALL TIME. That root is already
    // bound ONCE in the constructor to `this.d.configDir`, so the base lands under
    // the SAME `<account>` root the later fork/list/delete read from — NO per-call
    // env mutation here (race-free). We still pass the redundant per-query
    // `options.env` (harmless) so the spawned `claude` subprocess also bills the
    // right account.
    // FLOOR: the warmup query gets its OWN AbortController + deadline. Without it a
    // HUNG create would never settle, and since this future is single-flight cached
    // and every surface joins it via `await baseFut`, the whole summarizer loop would
    // wedge permanently. On overrun we abort the query and throw, which rejects this
    // future -> run() maps it to WarmBaseUnavailable('base-create') (cold-fallback)
    // AND baseFor's `.catch` self-evicts the rejected future so the NEXT call
    // re-attempts a fresh base instead of re-joining the dead one.
    const ac = new AbortController();
    let timedOut = false;
    const timer = setTimeout(() => {
      timedOut = true;
      ac.abort();
    }, this.d.baseTimeoutMs ?? WARMBASE_BASE_CREATE_TIMEOUT_MS);
    try {
      const q = this.d.seam.query({
        prompt: '{"ok":true}',
        options: {
          tools: [],
          maxTurns: 1,
          model: this.d.model,
          systemPrompt: system,
          cwd: this.d.projectDir,
          // Tag the base so the startup sweep can reap orphaned bases from prior
          // processes (a new process can't reuse a prior in-memory base id anyway).
          title: BASE_TITLE_PREFIX + systemHash(system),
          abortController: ac,
          ...(this.d.claudePath
            ? { pathToClaudeCodeExecutable: this.d.claudePath }
            : {}),
          ...(this.d.configDir
            ? { env: { ...process.env, CLAUDE_CONFIG_DIR: this.d.configDir } }
            : {}),
        },
      } as Parameters<QueryFn>[0]);

      let sessionId: string | undefined;
      for await (const message of q as AsyncIterable<unknown>) {
        const m = message as { type?: string; session_id?: string };
        // Capture the session_id from whichever message carries it first (the init
        // `system` message typically does; otherwise the `result`).
        if (
          (m.type === "system" || m.type === "result") &&
          typeof m.session_id === "string" &&
          m.session_id !== "" &&
          sessionId === undefined
        ) {
          sessionId = m.session_id;
        }
        // RETURN only once the warmup turn's `result` arrives — by then the API
        // round-trip has completed and the server has WRITTEN the system-prefix
        // prompt cache, so the very next fork+resume reads it (cacheRead) rather
        // than re-creating it (cacheWrite). Returning on the earlier init message
        // would let the `finally` abort the request mid-flight, leaving the base
        // un-warmed (the bug this drain-to-result closes).
        if (m.type === "result") {
          if (sessionId !== undefined) return sessionId;
          throw new Error("warm-base: base create result carried no session_id");
        }
      }
      throw new Error("warm-base: base create yielded no result message");
    } catch (e) {
      if (timedOut) {
        throw new Error(
          `warm-base: base create timed out after ${
            this.d.baseTimeoutMs ?? WARMBASE_BASE_CREATE_TIMEOUT_MS
          }ms`,
        );
      }
      throw e;
    } finally {
      clearTimeout(timer);
      ac.abort(); // release a still-iterating generator on any exit path
    }
  }

  /**
   * The per-call public API: fork -> resume -> delete, with cold fallback. THE
   * CATCH-ORDERING FIX is here — `timedOut` is set ONLY by the timer callback, so it
   * is true IFF the deadline fired (never as a side effect of our own cleanup abort),
   * which keeps the three error classes (timeout / resume-base-gone / genuine-model)
   * independently reachable.
   */
  async run(req: WarmRunRequest): Promise<string> {
    // SINGLE-ACCOUNT GUARD (ROUND-2 resolution #1): the account store is bound ONCE
    // at construction to `this.d.configDir`; we NEVER re-bind per-call. If a call
    // ever arrives for a DIFFERENT account, serving it would silently route through
    // the wrong store (or force a per-call env mutation we deliberately removed), so
    // we cold-fall-back instead — the floor is preserved and the constant binding is
    // never wrong for a served call. Today the sidecar uses a single account for
    // BOTH summarizer and bell-classify (verified), so this guard never trips in
    // practice; it is the assertion that makes the set-once binding sound.
    if (req.configDir !== this.d.configDir) {
      throw new WarmBaseUnavailable("config-mismatch");
    }

    const cacheKey = warmbaseCacheKey(req.configDir, req.model, req.system);
    const baseFut = this.baseFor(cacheKey, req.system);

    let baseId: string;
    try {
      baseId = await baseFut;
    } catch (e) {
      // The failed base future already self-evicted via baseFor's .catch.
      throw new WarmBaseUnavailable("base-create", e);
    }

    // No per-call env mutation: `process.env.CLAUDE_CONFIG_DIR` is already bound to
    // the single account (constructor), so the fork/resume/delete below all resolve
    // the SAME store as the base-create that wrote `baseId`. (The query legs still
    // carry the redundant per-query `options.env` for the spawned subprocess.)
    return this.forkResumeGC(req, cacheKey, baseId, baseFut);
  }

  /**
   * fork -> resume -> delete for ONE call. THE CATCH-ORDERING FIX is here — `timedOut`
   * is set ONLY by the timer callback, so it is true IFF the deadline fired (never as
   * a side effect of our own cleanup abort), which keeps the three error classes
   * (timeout / resume-base-gone / genuine-model) independently reachable.
   */
  private async forkResumeGC(
    req: WarmRunRequest,
    cacheKey: string,
    baseId: string,
    baseFut: Promise<string>,
  ): Promise<string> {
    let forkId: string;
    try {
      forkId = (
        await this.d.seam.forkSession(baseId, {
          dir: this.d.projectDir,
          title: FORK_TITLE_PREFIX + cacheKey,
        })
      ).sessionId;
    } catch (e) {
      this.invalidate(cacheKey, baseFut);
      throw new WarmBaseUnavailable("fork", e);
    }

    const ac = new AbortController();
    let timedOut = false; // captured BEFORE any abort
    const timer = setTimeout(() => {
      timedOut = true;
      ac.abort();
    }, this.d.timeoutMs ?? WARMBASE_CALL_TIMEOUT_MS);
    try {
      const q = this.d.seam.query({
        prompt: req.user,
        options: {
          tools: [],
          maxTurns: 3,
          model: req.model,
          // RE-SEND the system prompt on the resumed turn. `resume` does NOT replay the
          // base session's systemPrompt into the API request (verified live: omitting it
          // sent only the user message — in≈1.2k, cacheRead=0 — so the model ran WITHOUT
          // its contract and every reply was unparseable). Passing the SAME system the
          // base was created with both (a) gives the model its role/contract and (b)
          // matches the base's cached prefix so it's a cache READ ($0.10/MTok), not a
          // re-CREATE — which is the entire cost win. (An isolated probe masked this bug
          // because it spread systemPrompt into the resume; the module had dropped it.)
          systemPrompt: req.system,
          resume: forkId,
          cwd: this.d.projectDir,
          abortController: ac,
          ...(this.d.claudePath
            ? { pathToClaudeCodeExecutable: this.d.claudePath }
            : {}),
          ...(this.d.configDir
            ? { env: { ...process.env, CLAUDE_CONFIG_DIR: this.d.configDir } }
            : {}),
        },
      } as Parameters<QueryFn>[0]);
      return await this.drainResult(q, req.model, req.onUsage);
    } catch (e) {
      // ORDERING FIX: decide the CLASS from state captured BEFORE abort. `timedOut`
      // is set ONLY by the timer callback, so it is true IFF the deadline fired.
      if (timedOut) {
        throw new WarmBaseUnavailable("timeout", e); // genuine deadline -> cold-fallback
      }
      ac.abort(); // cleanup on the NON-timeout error path too (LOCKED #4b)
      if (looksLikeBaseGone(e)) {
        this.invalidate(cacheKey, baseFut); // self-heal: drop the dead base
        throw new WarmBaseUnavailable("resume", e); // base-gone -> cold-fallback
      }
      throw e; // GENUINE model/transport error -> rethrow PLAIN (NOT WarmBaseUnavailable)
    } finally {
      clearTimeout(timer);
      try {
        await this.d.seam.deleteSession(forkId, { dir: this.d.projectDir });
      } catch (err) {
        this.d.log?.(
          `fork GC failed for ${forkId}: ${
            err instanceof Error ? err.message : String(err)
          }`,
        );
      }
    }
  }

  /**
   * Iterate the result stream. SAME result-narrowing as model.ts: on a success
   * result read usage (defensively) -> onUsage with token-bucket cost + mode "warm",
   * then return the text. An error-subtype result / no-result throws a PLAIN Error
   * (NOT WarmBaseUnavailable) so model.ts does NOT cold-retry.
   */
  private async drainResult(
    q: ReturnType<QueryFn>,
    model: string,
    onUsage?: (u: HaikuUsage) => void,
  ): Promise<string> {
    for await (const message of q as AsyncIterable<unknown>) {
      const msg = message as {
        type?: string;
        subtype?: string;
        result?: string;
        errors?: unknown;
        usage?: {
          input_tokens?: number;
          output_tokens?: number;
          cache_read_input_tokens?: number;
          cache_creation_input_tokens?: number;
        };
      };
      if (msg.type === "result") {
        if (msg.subtype === "success") {
          if (onUsage) {
            const u = msg.usage ?? {};
            const buckets = {
              inputTokens: u.input_tokens ?? 0,
              outputTokens: u.output_tokens ?? 0,
              cacheReadTokens: u.cache_read_input_tokens ?? 0,
              cacheCreationTokens: u.cache_creation_input_tokens ?? 0,
            };
            onUsage({
              model,
              ...buckets,
              costUsd: costFromUsage(buckets),
              mode: "warm",
            });
          }
          return msg.result ?? "";
        }
        const errs =
          Array.isArray(msg.errors) && msg.errors.length
            ? (msg.errors as string[]).join("; ")
            : "";
        throw new Error(
          `warm-base: query ended subtype=${msg.subtype}${errs ? `: ${errs}` : ""}`,
        );
      }
    }
    throw new Error("warm-base: query produced no result message");
  }

  /**
   * Future-identity-aware eviction (LOCKED #3): evict the cached base ONLY if it is
   * still the SAME future the failing call branched from, so a concurrent re-base
   * under the same key is never clobbered by a stale failure.
   */
  private invalidate(cacheKey: string, fut: Promise<string>): void {
    if (this.bases.get(cacheKey) === fut) this.bases.delete(cacheKey);
  }

  /**
   * Startup GC of OUR sessions only (LOCKED #2: same dir they were created in).
   * For EACH account configDir, lists sessions under projectDir and deletes any
   * whose title (surfacing as customTitle/summary) starts with FORK_TITLE_PREFIX
   * **or** BASE_TITLE_PREFIX. Best-effort; returns the total count for the startup log.
   *
   * Bases ARE swept here (closing the base-file disk leak): a fresh process can NOT
   * reuse a prior process's in-memory base id, so any base on disk is necessarily an
   * orphan from a prior sidecar/GUI run — and bases are large (~25-32k tokens), so
   * leaving them would grow projectDir without bound across relaunches. This process
   * will lazily mint its own fresh base on first call. Symmetric with fork GC.
   *
   * ACCOUNT-ROUTED STORE BINDING (blocker fix): like the per-call fork/delete, the
   * in-process `listSessions`/`deleteSession` resolve their store ROOT from
   * `process.env.CLAUDE_CONFIG_DIR` at call time and take only `dir` (the projectKey,
   * NOT the config root). A base written under `<account>` is invisible to a sweep
   * reading `~/.claude`, so the account-dir base/forks would NEVER be reaped. We
   * therefore scan EACH provided configDir under its own bound env (restored even on
   * reject via `withConfigDirEnv`). Distinct configDirs are deduped; `undefined`
   * (ambient `~/.claude`) is always included so a run that later turns OFF account
   * routing still reaps the ambient leftovers. `configDirs` defaults to `[undefined]`
   * (ambient only) so existing callers/tests are byte-identical.
   */
  async sweepOrphanForks(
    configDirs: ReadonlyArray<string | undefined> = [undefined],
  ): Promise<number> {
    // Dedupe while preserving the ambient-first intent (a Set over the raw values;
    // `undefined` and a real dir are distinct keys, exactly the store roots we scan).
    const seen = new Set<string | undefined>();
    let n = 0;
    for (const configDir of configDirs) {
      if (seen.has(configDir)) continue;
      seen.add(configDir);
      n += await withConfigDirEnv(configDir, () => this.sweepOneRoot());
    }
    return n;
  }

  /** Sweep OUR tagged sessions under projectDir for the CURRENTLY-bound store root. */
  private async sweepOneRoot(): Promise<number> {
    const sessions = await this.d.seam.listSessions({ dir: this.d.projectDir });
    let n = 0;
    for (const s of sessions) {
      const title = s.customTitle ?? s.summary ?? "";
      if (
        title.startsWith(FORK_TITLE_PREFIX) ||
        title.startsWith(BASE_TITLE_PREFIX)
      ) {
        try {
          await this.d.seam.deleteSession(s.sessionId, {
            dir: this.d.projectDir,
          });
          n++;
        } catch {
          /* best-effort */
        }
      }
    }
    return n;
  }
}

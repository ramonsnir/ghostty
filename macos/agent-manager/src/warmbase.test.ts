// Unit tests for the warm-base fork-per-call mechanism. Everything runs over a
// MOCKED ForkSeam (an in-memory session map keyed by dir + a fake async-generator
// query like model.test.ts's fakeQuery) so NO real `claude` is ever spawned. The
// catch-ordering fix (timeout vs resume-base-gone vs genuine-model-error) is
// exercised directly via configurable per-call query behaviors. Run via `npm test`.

import test from "node:test";
import assert from "node:assert/strict";

import {
  WarmBase,
  WarmBaseUnavailable,
  warmbaseEnabled,
  systemHash,
  warmbaseCacheKey,
  warmbaseProjectDir,
  warmbaseInstanceDir,
  warmbaseInstanceKey,
  warmbaseRunDirName,
  planDeadRunDirs,
  withConfigDirEnv,
  costFromUsage,
  looksLikeBaseGone,
  FORK_TITLE_PREFIX,
  BASE_TITLE_PREFIX,
  type ForkSeam,
  type WarmBaseDeps,
} from "./warmbase.js";
import type { HaikuUsage } from "./usage.js";

// --- pure helpers -----------------------------------------------------------

test("warmbaseEnabled: only '1' enables", () => {
  assert.equal(warmbaseEnabled({ GHOSTTY_WARMBASE: "1" }), true);
  assert.equal(warmbaseEnabled({}), false);
  assert.equal(warmbaseEnabled({ GHOSTTY_WARMBASE: "0" }), false);
  assert.equal(warmbaseEnabled({ GHOSTTY_WARMBASE: "true" }), false);
});

test("systemHash: deterministic, 16 hex chars, collision-distinct", () => {
  const a = systemHash("system A");
  assert.equal(a.length, 16);
  assert.match(a, /^[0-9a-f]{16}$/);
  assert.equal(systemHash("system A"), a); // stable
  assert.notEqual(systemHash("system B"), a); // different input => different
});

test("warmbaseCacheKey: ambient vs dir prefix; model + system both factor into the key", () => {
  assert.equal(
    warmbaseCacheKey(undefined, "claude-haiku-4-5", "S"),
    `ambient:claude-haiku-4-5:${systemHash("S")}`,
  );
  assert.equal(
    warmbaseCacheKey("/acct", "claude-haiku-4-5", "S"),
    `/acct:claude-haiku-4-5:${systemHash("S")}`,
  );
  // System change changes the key (same configDir + model).
  assert.notEqual(
    warmbaseCacheKey("/acct", "claude-haiku-4-5", "S1"),
    warmbaseCacheKey("/acct", "claude-haiku-4-5", "S2"),
  );
});

test("warmbaseProjectDir: joins the fixed app-owned path", () => {
  assert.equal(
    warmbaseProjectDir("/Users/x"),
    "/Users/x/.config/ghostty-ramon/agent-manager/warmbase",
  );
});

test("warmbaseProjectDir: a per-instance key isolates the store subdir (concurrent-sweep-stomp mitigation)", () => {
  // No key ⇒ byte-identical legacy dir (back-compat for single instance + existing tests).
  assert.equal(
    warmbaseProjectDir("/Users/x", undefined),
    "/Users/x/.config/ghostty-ramon/agent-manager/warmbase",
  );
  assert.equal(
    warmbaseProjectDir("/Users/x", "   "),
    "/Users/x/.config/ghostty-ramon/agent-manager/warmbase",
  );
  // A key ⇒ its OWN subdir, so a coexisting instance never sweeps THIS one's store.
  assert.equal(
    warmbaseProjectDir("/Users/x", "abc123"),
    "/Users/x/.config/ghostty-ramon/agent-manager/warmbase-abc123",
  );
  // Different instances (different MCP URL/port ⇒ different key) ⇒ different dirs.
  assert.notEqual(
    warmbaseProjectDir("/Users/x", warmbaseInstanceKey("http://127.0.0.1:8765/mcp")),
    warmbaseProjectDir("/Users/x", warmbaseInstanceKey("http://127.0.0.1:8766/mcp")),
  );
});

// PER-LAUNCH run-dir isolation (ROUND-2 resolution #2): a runId (the sidecar pid)
// gives this LAUNCH its OWN `<instanceDir>/run-<pid>` cwd, so even an overlapping
// relaunch of the SAME instance can't see/sweep this launch's live base. The
// instanceDir is the PARENT the dead-pid sweep scans.
test("warmbaseInstanceDir / warmbaseProjectDir(runId): per-launch run subdir; back-compat without runId", () => {
  // instanceDir == the legacy projectDir for the no-runId case.
  assert.equal(
    warmbaseInstanceDir("/Users/x", "abc123"),
    "/Users/x/.config/ghostty-ramon/agent-manager/warmbase-abc123",
  );
  assert.equal(
    warmbaseInstanceDir("/Users/x"),
    "/Users/x/.config/ghostty-ramon/agent-manager/warmbase",
  );
  // BACK-COMPAT: warmbaseProjectDir with NO runId is byte-identical to the instanceDir.
  assert.equal(
    warmbaseProjectDir("/Users/x", "abc123"),
    warmbaseInstanceDir("/Users/x", "abc123"),
  );
  assert.equal(warmbaseProjectDir("/Users/x"), warmbaseInstanceDir("/Users/x"));
  // A runId ⇒ a per-launch `run-<runId>` leaf under the instance dir.
  assert.equal(
    warmbaseProjectDir("/Users/x", "abc123", 4242),
    "/Users/x/.config/ghostty-ramon/agent-manager/warmbase-abc123/run-4242",
  );
  // Empty/blank runId ⇒ falls back to the instance dir (no empty run leaf).
  assert.equal(
    warmbaseProjectDir("/Users/x", "abc123", "   "),
    warmbaseInstanceDir("/Users/x", "abc123"),
  );
  assert.equal(warmbaseRunDirName(4242), "run-4242");
});

// PURE dead-pid run-dir planner (ROUND-2 resolution #2): the startup sweep removes
// ONLY sibling `run-<pid>` dirs whose owning pid is dead; never this launch's own
// run dir, never a live peer, never a non-run-dir entry.
test("planDeadRunDirs: reaps only dead-pid run dirs; spares self, live peers, and non-run entries", () => {
  const alive = new Set([100, 200]); // 100 = self's owner, 200 = a live peer
  const isAlive = (pid: number) => alive.has(pid);
  const entries = [
    "run-100", // self (excluded explicitly below)
    "run-200", // live peer ⇒ spared
    "run-300", // dead ⇒ reaped
    "run-400", // dead ⇒ reaped
    "warmbase", // legacy non-run store ⇒ spared
    "notes.txt", // unrelated file ⇒ spared
    "run-abc", // non-numeric ⇒ spared
    "run--5", // non-positive / malformed ⇒ spared
  ];
  const dead = planDeadRunDirs(entries, "run-100", isAlive);
  assert.deepEqual(dead.sort(), ["run-300", "run-400"]);
  // Self is never reaped even if its pid is reported dead.
  assert.deepEqual(
    planDeadRunDirs(["run-999"], "run-999", () => false),
    [],
  );
});

test("warmbaseInstanceKey: stable 12-hex from a seed; empty ⇒ undefined", () => {
  const k = warmbaseInstanceKey("http://127.0.0.1:8765/mcp");
  assert.match(k!, /^[0-9a-f]{12}$/);
  assert.equal(warmbaseInstanceKey("http://127.0.0.1:8765/mcp"), k); // stable
  assert.notEqual(warmbaseInstanceKey("http://127.0.0.1:8766/mcp"), k); // port differs
  assert.equal(warmbaseInstanceKey(undefined), undefined);
  assert.equal(warmbaseInstanceKey(""), undefined);
  assert.equal(warmbaseInstanceKey("   "), undefined);
});

// MODEL-CACHE-KEY (ROUND-2 resolution #3): the model IS folded into the key, so two
// models under the SAME (configDir, system) get DISTINCT bases — removing the latent
// "two models share one base whose prefix-cache was written under the warmup model →
// silent re-CREATE" landmine. Pin that a model change changes the key (and is stable
// for a fixed model).
test("warmbaseCacheKey: the model is part of the key (distinct models ⇒ distinct bases)", () => {
  assert.notEqual(
    warmbaseCacheKey("/acct", "claude-haiku-4-5", "SYS"),
    warmbaseCacheKey("/acct", "claude-sonnet-4-5", "SYS"),
  );
  // Stable for a fixed (configDir, model, system).
  assert.equal(
    warmbaseCacheKey("/acct", "claude-haiku-4-5", "SYS"),
    warmbaseCacheKey("/acct", "claude-haiku-4-5", "SYS"),
  );
});

// withConfigDirEnv (LOCKED #4a): binds process.env.CLAUDE_CONFIG_DIR for the region
// and RESTORES the prior value (or deletes it if unset) on EVERY exit — resolve AND
// reject. This is the non-query store-binding mechanism (the query legs use per-query
// options.env instead). A leak here would cross-route a later unrelated store call.
test("withConfigDirEnv: sets the env inside fn, restores prior value on resolve", async () => {
  process.env.CLAUDE_CONFIG_DIR = "/prior";
  try {
    let seen: string | undefined;
    const out = await withConfigDirEnv("/acct", async () => {
      seen = process.env.CLAUDE_CONFIG_DIR;
      return 42;
    });
    assert.equal(out, 42);
    assert.equal(seen, "/acct");
    assert.equal(process.env.CLAUDE_CONFIG_DIR, "/prior"); // restored
  } finally {
    delete process.env.CLAUDE_CONFIG_DIR;
  }
});

test("withConfigDirEnv: restores the prior value even when fn REJECTS (LOCKED #4a)", async () => {
  process.env.CLAUDE_CONFIG_DIR = "/prior";
  try {
    await assert.rejects(
      () =>
        withConfigDirEnv("/acct", async () => {
          assert.equal(process.env.CLAUDE_CONFIG_DIR, "/acct");
          throw new Error("boom");
        }),
      /boom/,
    );
    assert.equal(process.env.CLAUDE_CONFIG_DIR, "/prior"); // restored on reject
  } finally {
    delete process.env.CLAUDE_CONFIG_DIR;
  }
});

test("withConfigDirEnv: configDir=undefined DELETES the env inside fn; restores absence after", async () => {
  // Prior unset.
  delete process.env.CLAUDE_CONFIG_DIR;
  let presentInside = true;
  await withConfigDirEnv(undefined, async () => {
    presentInside = Object.prototype.hasOwnProperty.call(
      process.env,
      "CLAUDE_CONFIG_DIR",
    );
  });
  assert.equal(presentInside, false); // ambient ⇒ deleted inside
  assert.equal(
    Object.prototype.hasOwnProperty.call(process.env, "CLAUDE_CONFIG_DIR"),
    false,
    "still absent after (was unset before)",
  );

  // Prior SET + ambient region ⇒ deleted inside, restored after.
  process.env.CLAUDE_CONFIG_DIR = "/prior";
  try {
    let insideHad = true;
    await withConfigDirEnv(undefined, async () => {
      insideHad = Object.prototype.hasOwnProperty.call(
        process.env,
        "CLAUDE_CONFIG_DIR",
      );
    });
    assert.equal(insideHad, false);
    assert.equal(process.env.CLAUDE_CONFIG_DIR, "/prior"); // restored
  } finally {
    delete process.env.CLAUDE_CONFIG_DIR;
  }
});

test("costFromUsage: exact rate math + the $2 cacheWrite vs $0.10 cacheRead split", () => {
  // cacheRead-dominated case (matches the cold-path test):
  assert.ok(
    Math.abs(
      costFromUsage({
        inputTokens: 10,
        outputTokens: 141,
        cacheReadTokens: 25736,
        cacheCreationTokens: 0,
      }) - 0.0032886,
    ) < 1e-9,
  );
  // 1M cacheCreation @ $2 vs 1M cacheRead @ $0.10 proves the split:
  assert.equal(
    costFromUsage({
      inputTokens: 0,
      outputTokens: 0,
      cacheReadTokens: 0,
      cacheCreationTokens: 1_000_000,
    }),
    2,
  );
  assert.equal(
    costFromUsage({
      inputTokens: 0,
      outputTokens: 0,
      cacheReadTokens: 1_000_000,
      cacheCreationTokens: 0,
    }),
    0.1,
  );
  assert.equal(
    costFromUsage({
      inputTokens: 0,
      outputTokens: 0,
      cacheReadTokens: 0,
      cacheCreationTokens: 0,
    }),
    0,
  );
});

test("looksLikeBaseGone: base-gone shapes true; plain transport errors false", () => {
  assert.equal(looksLikeBaseGone(new Error("session not found")), true);
  assert.equal(looksLikeBaseGone(new Error("could not resume")), true);
  assert.equal(looksLikeBaseGone(new Error("ENOENT: no such file")), true);
  assert.equal(looksLikeBaseGone(new Error("rate limit exceeded")), false);
  assert.equal(looksLikeBaseGone(new Error("overloaded")), false);
});

test("looksLikeBaseGone: FALSE-POSITIVE GUARD — quota/limit messages with 'session'/'resume' are NOT base-gone", () => {
  // These contain the bare 'session'/'resume' keyword but are genuine model/quota
  // errors — must NOT trigger a needless base recreate.
  assert.equal(looksLikeBaseGone(new Error("session limit reached")), false);
  assert.equal(
    looksLikeBaseGone(new Error("please resume your subscription")),
    false,
  );
  assert.equal(looksLikeBaseGone(new Error("rate-limit on this session")), false);
  // Still classifies genuine base-gone shapes correctly:
  assert.equal(looksLikeBaseGone(new Error("session file is corrupt")), true);
  assert.equal(looksLikeBaseGone(new Error("could not find session abc")), true);
});

// --- mocked ForkSeam --------------------------------------------------------

interface FakeSession {
  sessionId: string;
  customTitle?: string;
  summary?: string;
}

/** Describes what a per-call resume query should do. */
type QueryBehavior =
  | {
      kind: "success";
      result: string;
      usage?: Record<string, number>;
      /** Top-level cumulative-per-session cost the SDK reports — drainResult MUST
       *  ignore it (LOCKED #1) in favor of token-bucket cost. */
      totalCostUsd?: number;
    }
  | { kind: "errorResult"; subtype: string; errors?: string[] }
  | { kind: "noResult" }
  | { kind: "throw"; message: string }
  | { kind: "hang" }; // never settles until aborted

interface MockSeamOptions {
  /** session_id messages the base-create query yields (per createBase call). */
  baseSessionIds?: string[];
  /** base-create throws (overrides baseSessionIds). */
  baseThrows?: boolean;
  /** base-create yields no session_id. */
  baseNoSessionId?: boolean;
  /** base-create HANGS (never yields a session_id) until aborted by the deadline. */
  baseHang?: boolean;
  /** forkSession throws. */
  forkThrows?: boolean;
  /** deleteSession throws (GC path). */
  deleteThrows?: boolean;
  /** Sequence of behaviors for successive resume (per-call) queries. */
  resumeBehaviors?: QueryBehavior[];
  /**
   * STRICT store realism (opt-in): forkSession THROWS unless a tagged base exists
   * under the SAME (effectiveConfigDir, dir) store key it reads — modeling the real
   * SDK, where a fork can't find a base written under a different CLAUDE_CONFIG_DIR
   * root. The account-routed-store regression test turns this on to PROVE the fork
   * misses when the configDir binding is dropped. Off by default so tests that inject
   * a base id directly into the cache (e.g. the invalidate-future-identity race) are
   * unaffected.
   */
  strictStore?: boolean;
}

interface MockSeam extends ForkSeam {
  // Observability:
  createCalls: number;
  forkCalls: Array<{ baseId: string; dir: string; title?: string }>;
  resumeCalls: Array<{ resume: string; cwd?: string; options: any }>;
  deleted: string[];
  /** Records the effective CLAUDE_CONFIG_DIR seen at each store-fn call time (mirrors
   *  the real SDK reading process.env at call time): fork/delete/list. */
  storeConfigDirs: { fork: Array<string | undefined>; delete: Array<string | undefined>; list: Array<string | undefined> };
  /**
   * Sessions keyed by (effectiveConfigDir, dir) — the REAL SDK resolves its store
   * ROOT from process.env.CLAUDE_CONFIG_DIR at call time, and `dir` is only the
   * projectKey WITHIN that root. So a base written while CLAUDE_CONFIG_DIR=ACCOUNT_A
   * is INVISIBLE to a fork/list/delete reading ambient (~/.claude) — this is the
   * account-routed-store blocker. The composite key models exactly that: an ambient
   * call (no CLAUDE_CONFIG_DIR) keys on the bare `dir` (back-compat), an account call
   * keys on `${configDir}${dir}`.
   */
  sessionsByDir: Map<string, FakeSession[]>;
}

/** Effective store key — mirrors the SDK's `process.env.CLAUDE_CONFIG_DIR ?? ~/.claude`
 *  resolution AT CALL TIME. Ambient ⇒ bare `dir` (keeps existing ambient tests valid). */
const STORE_KEY_SEP = "::"; // separator joining the configDir root with the projectKey
function effectiveStoreKey(dir: string): string {
  const cfg = process.env.CLAUDE_CONFIG_DIR;
  return cfg ? `${cfg}${STORE_KEY_SEP}${dir}` : dir;
}

function makeMockSeam(opts: MockSeamOptions = {}): MockSeam {
  const baseIds = opts.baseSessionIds ?? ["base-1", "base-2", "base-3"];
  let forkCounter = 0;
  const sessionsByDir = new Map<string, FakeSession[]>();

  const seam: MockSeam = {
    createCalls: 0,
    forkCalls: [],
    resumeCalls: [],
    deleted: [],
    storeConfigDirs: { fork: [], delete: [], list: [] },
    sessionsByDir,

    // A single query() handles BOTH base-create (has systemPrompt, no resume) and
    // the per-call resume (has options.resume). We branch on options.resume.
    query: ((params: any) => {
      const options = params.options ?? {};
      if (options.resume !== undefined) {
        // Per-call resume query.
        const idx = seam.resumeCalls.length;
        seam.resumeCalls.push({
          resume: options.resume,
          cwd: options.cwd,
          options,
        });
        const behavior: QueryBehavior =
          opts.resumeBehaviors?.[idx] ?? { kind: "success", result: "ok" };
        return makeResumeGenerator(behavior, options.abortController);
      }
      // base-create query.
      const callIdx = seam.createCalls;
      seam.createCalls += 1;
      const baseDir = options.cwd as string | undefined;
      const baseTitle = options.title as string | undefined;
      const baseAc = options.abortController as AbortController | undefined;
      // Capture the effective store key AT CALL TIME (createBase binds the global env
      // around the warmup, so a base must land under the account root just like a real
      // SDK write). Snapshot it now (the generator runs later, after env restore).
      const baseStoreKey = baseDir ? effectiveStoreKey(baseDir) : undefined;
      return (async function* () {
        if (opts.baseThrows) throw new Error("base create boom");
        if (opts.baseHang) {
          // Never yields a session_id; settles only when aborted (the deadline path).
          await new Promise<void>((resolve) => {
            if (baseAc?.signal.aborted) return resolve();
            baseAc?.signal.addEventListener("abort", () => resolve());
          });
          // After abort, end WITHOUT a session_id (as a killed warmup would).
          return;
        }
        if (opts.baseNoSessionId) {
          yield { type: "assistant", message: {} };
          return;
        }
        const sid = baseIds[callIdx] ?? `base-fallback-${callIdx}`;
        // Register the base session under its (configDir, dir) key + tagged title so
        // the startup sweep can find+reap it ONLY under the SAME store root.
        if (baseStoreKey) {
          const list = sessionsByDir.get(baseStoreKey) ?? [];
          list.push({ sessionId: sid, customTitle: baseTitle });
          sessionsByDir.set(baseStoreKey, list);
        }
        // Yield the session_id off a system init message (the common case).
        yield { type: "system", subtype: "init", session_id: sid };
        yield { type: "result", subtype: "success", result: "ack", session_id: sid };
      })();
    }) as unknown as ForkSeam["query"],

    forkSession: async (id: string, o: { dir: string; title?: string }) => {
      seam.forkCalls.push({ baseId: id, dir: o.dir, title: o.title });
      seam.storeConfigDirs.fork.push(process.env.CLAUDE_CONFIG_DIR);
      if (opts.forkThrows) throw new Error("fork boom");
      const key = effectiveStoreKey(o.dir);
      const here = sessionsByDir.get(key) ?? [];
      if (opts.strictStore) {
        // A fork branches from a base under the SAME store root; if the base isn't
        // there (configDir mismatch — the blocker), a REAL SDK fork would fail. Model
        // that: the fork only succeeds if the base exists under this key.
        if (!here.some((s) => s.sessionId === id)) {
          throw new Error(`fork: base ${id} not found under this store root`);
        }
      }
      const forkId = `fork-${++forkCounter}`;
      here.push({ sessionId: forkId, customTitle: o.title });
      sessionsByDir.set(key, here);
      return { sessionId: forkId };
    },

    deleteSession: async (id: string, o: { dir: string }) => {
      seam.deleted.push(id);
      seam.storeConfigDirs.delete.push(process.env.CLAUDE_CONFIG_DIR);
      if (opts.deleteThrows) throw new Error("delete boom");
      const key = effectiveStoreKey(o.dir);
      const list = sessionsByDir.get(key);
      if (list) sessionsByDir.set(key, list.filter((s) => s.sessionId !== id));
    },

    listSessions: async (o: { dir: string }) => {
      seam.storeConfigDirs.list.push(process.env.CLAUDE_CONFIG_DIR);
      return (sessionsByDir.get(effectiveStoreKey(o.dir)) ?? []).map((s) => ({ ...s }));
    },
  };
  return seam;
}

function makeResumeGenerator(
  behavior: QueryBehavior,
  ac?: AbortController,
): AsyncGenerator<unknown> {
  return (async function* () {
    switch (behavior.kind) {
      case "success":
        yield {
          type: "result",
          subtype: "success",
          result: behavior.result,
          usage: behavior.usage,
          // A bogus cumulative-per-session cost the SDK can report; drainResult
          // must IGNORE it (its destructured msg shape has no total_cost_usd field).
          total_cost_usd: behavior.totalCostUsd,
        };
        return;
      case "errorResult":
        yield {
          type: "result",
          subtype: behavior.subtype,
          errors: behavior.errors,
        };
        return;
      case "noResult":
        yield { type: "assistant", message: {} };
        return;
      case "throw":
        throw new Error(behavior.message);
      case "hang":
        // Resolve only when aborted, then throw an abort-shaped (non-base-gone) error.
        await new Promise<void>((resolve) => {
          if (ac?.signal.aborted) return resolve();
          ac?.signal.addEventListener("abort", () => resolve());
        });
        throw new Error("aborted");
    }
  })();
}

function makeWarmBase(
  seam: MockSeam,
  extra: Partial<WarmBaseDeps> = {},
): WarmBase {
  const deps: WarmBaseDeps = {
    seam,
    projectDir: "/proj",
    model: "claude-haiku-4-5",
    ...extra,
  };
  // TEST HYGIENE for the SET-ONCE binding (ROUND-2 #1): the WarmBase constructor
  // sets process.env.CLAUDE_CONFIG_DIR exactly when `configDir` is defined and
  // touches NOTHING when ambient. Because these tests share one process, a prior
  // account-bound construction could leave the env set and contaminate a later
  // ambient test (whose mocked store reads process.env at call time). So mirror the
  // real binding deterministically here: DELETE the env for ambient builds, restoring
  // the clean ambient baseline before the constructor runs. (Production keeps the
  // "ambient ⇒ don't touch" semantics; this delete is harness-only cleanup.)
  if (deps.configDir === undefined) delete process.env.CLAUDE_CONFIG_DIR;
  return new WarmBase(deps);
}

const req = (over: Partial<{ system: string; user: string; model: string; configDir?: string; onUsage?: (u: HaikuUsage) => void }> = {}) => ({
  system: "SYS",
  user: "USR",
  model: "claude-haiku-4-5",
  ...over,
});

// --- baseFor / createBase ---------------------------------------------------

test("baseFor single-flight: two concurrent runs under one key create the base ONCE", async () => {
  const seam = makeMockSeam();
  const wb = makeWarmBase(seam);
  const [a, b] = await Promise.all([wb.run(req()), wb.run(req())]);
  assert.equal(a, "ok");
  assert.equal(b, "ok");
  assert.equal(seam.createCalls, 1); // single-flight: ONE warmup
  // Both forks branched from the SAME baseId.
  assert.equal(seam.forkCalls.length, 2);
  assert.equal(seam.forkCalls[0].baseId, "base-1");
  assert.equal(seam.forkCalls[1].baseId, "base-1");
});

test("createBase: captures session_id off a type:'result' when no system message precedes", async () => {
  const seam = makeMockSeam();
  // Override the base-create query to yield ONLY a result message (no system init).
  seam.query = ((params: any) => {
    const options = params.options ?? {};
    if (options.resume !== undefined) {
      seam.resumeCalls.push({ resume: options.resume, cwd: options.cwd, options });
      return makeResumeGenerator({ kind: "success", result: "ok" });
    }
    seam.createCalls += 1;
    return (async function* () {
      yield { type: "assistant", message: {} }; // no session_id
      yield { type: "result", subtype: "success", session_id: "from-result" };
    })();
  }) as unknown as ForkSeam["query"];
  const wb = makeWarmBase(seam);
  await wb.run(req());
  assert.equal(seam.forkCalls[0].baseId, "from-result");
});

// EFFICACY: createBase must DRAIN to the result before returning — it must NOT return
// on the early `type:"system"` init message (emitted at stream START, before the warmup
// round-trip completes and the server WRITES the prompt cache). If it returned early, the
// `finally` would abort the request mid-flight and the base would NOT be pre-warmed (the
// design's $0.0035/call assumes a COMPLETED warmup). We model a stream that yields ONLY
// the init message and then ends with NO result: createBase must FAIL (no result), proving
// it did not short-circuit on the init message.
test("createBase: does NOT return on the init message alone — a stream with no result FAILS (drains to result)", async () => {
  const seam = makeMockSeam();
  seam.query = ((params: any) => {
    const options = params.options ?? {};
    if (options.resume !== undefined) {
      seam.resumeCalls.push({ resume: options.resume, cwd: options.cwd, options });
      return makeResumeGenerator({ kind: "success", result: "ok" });
    }
    seam.createCalls += 1;
    return (async function* () {
      // Init carries the session_id, but the warmup turn never produces a result —
      // so the cache-write round-trip did NOT complete. createBase must not accept it.
      yield { type: "system", subtype: "init", session_id: "early-init" };
    })();
  }) as unknown as ForkSeam["query"];
  const wb = makeWarmBase(seam);
  await assert.rejects(
    () => wb.run(req()),
    (e: unknown) =>
      e instanceof WarmBaseUnavailable && e.kind === "base-create",
  );
  // The fork was never attempted because no base completed.
  assert.equal(seam.forkCalls.length, 0);
});

test("createBase: no session_id => base-create fails, future evicted, next run re-attempts", async () => {
  const seam = makeMockSeam({ baseNoSessionId: true });
  const wb = makeWarmBase(seam);
  await assert.rejects(
    () => wb.run(req()),
    (e: unknown) =>
      e instanceof WarmBaseUnavailable && e.kind === "base-create",
  );
  assert.equal(seam.createCalls, 1);
  // The failed future was evicted: a second run re-attempts createBase.
  await assert.rejects(() => wb.run(req()));
  assert.equal(seam.createCalls, 2);
});

// FLOOR: the dangerous path the 597-test suite was blind to. A base-create that
// HANGS (never yields a session_id and never settles) must NOT wedge the loop: its
// OWN deadline aborts the warmup -> run() rejects WarmBaseUnavailable('base-create')
// (cold-fallback), the fork is NEVER attempted, AND the rejected base future
// self-evicts so a LATER run RE-ATTEMPTS createBase rather than re-joining the dead
// promise.
test("FLOOR hung base-create: deadline => WarmBaseUnavailable('base-create'), no fork, later run re-attempts", async () => {
  const seam = makeMockSeam({ baseHang: true });
  const wb = makeWarmBase(seam, { baseTimeoutMs: 5 });
  await assert.rejects(
    () => wb.run(req()),
    (e: unknown) =>
      e instanceof WarmBaseUnavailable && e.kind === "base-create",
  );
  assert.equal(seam.createCalls, 1);
  // The fork was NEVER attempted (we never got a baseId).
  assert.equal(seam.forkCalls.length, 0);
  assert.deepEqual(seam.deleted, []);
  // The hung+rejected base future self-evicted: a later run re-attempts createBase
  // (and would re-join the dead promise forever if eviction were broken).
  const seam2 = seam; // same seam, baseHang still true on the SECOND attempt
  await assert.rejects(() => wb.run(req()));
  assert.equal(seam2.createCalls, 2);
});

test("account binding (BOTH create AND resume): configDir => env.CLAUDE_CONFIG_DIR set + process.env preserved + global env bound; absent => env undefined", async () => {
  process.env.__WB_TEST__ = "preserved";
  const priorCfg = process.env.CLAUDE_CONFIG_DIR;
  try {
    // With configDir — the WarmBase is CONSTRUCTED bound to the same account (the
    // set-once binding, ROUND-2 #1) and the call's configDir matches the guard.
    {
      const seam = makeMockSeam();
      const captured: any[] = [];
      const origQuery = seam.query;
      seam.query = ((params: any) => {
        if (params.options?.resume === undefined) captured.push(params.options);
        return (origQuery as any)(params);
      }) as unknown as ForkSeam["query"];
      const wb = makeWarmBase(seam, { configDir: "/acct/dir" });
      // SET-ONCE: the constructor bound the global env to the account.
      assert.equal(process.env.CLAUDE_CONFIG_DIR, "/acct/dir");
      await wb.run(req({ configDir: "/acct/dir" }));
      // CREATE path account binding (redundant per-query env leg, preserved).
      assert.equal(captured[0].env.CLAUDE_CONFIG_DIR, "/acct/dir");
      assert.equal(captured[0].env.__WB_TEST__, "preserved");
      // RESUME path account binding — the leg billing/auth actually rides. A regression
      // dropping `env` from the resume query would silently misroute across accounts and
      // break the structural isolation, with NOTHING else asserting it.
      assert.equal(
        seam.resumeCalls[0].options.env.CLAUDE_CONFIG_DIR,
        "/acct/dir",
      );
      assert.equal(seam.resumeCalls[0].options.env.__WB_TEST__, "preserved");
    }
    // Without configDir.
    {
      const seam = makeMockSeam();
      const captured: any[] = [];
      const origQuery = seam.query;
      seam.query = ((params: any) => {
        if (params.options?.resume === undefined) captured.push(params.options);
        return (origQuery as any)(params);
      }) as unknown as ForkSeam["query"];
      const wb = makeWarmBase(seam); // ambient ⇒ constructor binds NOTHING
      await wb.run(req());
      assert.equal(captured[0].env, undefined);
      // RESUME path: ambient ⇒ no env override (symmetric with the create path).
      assert.equal(seam.resumeCalls[0].options.env, undefined);
    }
  } finally {
    delete process.env.__WB_TEST__;
    if (priorCfg === undefined) delete process.env.CLAUDE_CONFIG_DIR;
    else process.env.CLAUDE_CONFIG_DIR = priorCfg;
  }
});

// SINGLE-ACCOUNT GUARD (ROUND-2 resolution #1): the account store is bound ONCE at
// construction; a call for a DIFFERENT account is NEVER served warm (it would route
// through the wrong store), it cold-falls-back via WarmBaseUnavailable. This is the
// assertion that makes the set-once binding sound. Also prove the converse: a matching
// (or ambient==ambient) configDir is served warm.
test("run guard: req.configDir != the constructed configDir => cold-fallback (config-mismatch); matching => served", async () => {
  const priorCfg = process.env.CLAUDE_CONFIG_DIR;
  try {
    // Built bound to ACCOUNT_A; a call for a DIFFERENT account must NOT be served.
    {
      const seam = makeMockSeam();
      const wb = makeWarmBase(seam, { configDir: "/acct/A" });
      await assert.rejects(
        () => wb.run(req({ configDir: "/acct/B" })),
        (e: unknown) =>
          e instanceof WarmBaseUnavailable && e.kind === "config-mismatch",
      );
      // The guard short-circuits BEFORE any base-create / fork (no store work).
      assert.equal(seam.createCalls, 0);
      assert.equal(seam.forkCalls.length, 0);
      // A matching call IS served warm.
      const out = await wb.run(req({ configDir: "/acct/A" }));
      assert.equal(out, "ok");
      assert.equal(seam.createCalls, 1);
    }
    // Built ambient; an account-routed call must NOT be served (undefined != "/x").
    {
      const seam = makeMockSeam();
      const wb = makeWarmBase(seam); // ambient
      await assert.rejects(
        () => wb.run(req({ configDir: "/x" })),
        (e: unknown) =>
          e instanceof WarmBaseUnavailable && e.kind === "config-mismatch",
      );
      assert.equal(seam.createCalls, 0);
    }
  } finally {
    if (priorCfg === undefined) delete process.env.CLAUDE_CONFIG_DIR;
    else process.env.CLAUDE_CONFIG_DIR = priorCfg;
  }
});

// --- account-routed store binding (THE BLOCKER) -----------------------------
//
// The fork/list/delete store fns take NO env option; the SDK resolves the store ROOT
// from process.env.CLAUDE_CONFIG_DIR AT CALL TIME. So under account routing the base
// (written under <account>) must be forked/listed/deleted under the SAME root, or the
// fork MISSES (cold floor, no cost win) and the account-dir base/forks NEVER get reaped
// (the disk leak gotcha #2 reopened). The mock models the real SDK: a base written
// while CLAUDE_CONFIG_DIR=ACCOUNT_A is invisible to a call reading any other root, and
// (strictStore) a fork from a base not present under the read root THROWS.

test("BLOCKER account-routed store (SET-ONCE binding): create/fork/resume/delete + sweep ALL align under ACCOUNT_A with NO per-call env mutation", async () => {
  const ACCOUNT_A = "/accounts/A/.claude";
  const priorCfg = process.env.CLAUDE_CONFIG_DIR;
  try {
    const seam = makeMockSeam({
      strictStore: true, // a fork from a base under the WRONG root throws (proves binding)
      resumeBehaviors: [{ kind: "success", result: "routed-ok" }],
    });
    // SET-ONCE (ROUND-2 #1): the WarmBase is CONSTRUCTED bound to ACCOUNT_A; the
    // constructor sets process.env.CLAUDE_CONFIG_DIR exactly once. There is NO
    // per-call withConfigDirEnv anymore — the mock's store fns read process.env at
    // call time and must STILL see ACCOUNT_A on every leg.
    const wb = makeWarmBase(seam, { configDir: ACCOUNT_A });
    assert.equal(
      process.env.CLAUDE_CONFIG_DIR,
      ACCOUNT_A,
      "constructor bound the global env once",
    );

    // (a) The fork is FOUND (base was written under ACCOUNT_A and the fork reads ACCOUNT_A).
    const out = await wb.run(req({ configDir: ACCOUNT_A }));
    assert.equal(out, "routed-ok");

    // Every store fn saw CLAUDE_CONFIG_DIR === ACCOUNT_A at call time — via the
    // constant binding, NOT a per-call wrapper.
    assert.deepEqual(seam.storeConfigDirs.fork, [ACCOUNT_A]);
    assert.deepEqual(seam.storeConfigDirs.delete, [ACCOUNT_A]);
    assert.deepEqual(seam.deleted, ["fork-1"]);

    // The base landed under ACCOUNT_A's store key (NOT ambient).
    const ambient = seam.sessionsByDir.get("/proj") ?? [];
    assert.equal(ambient.length, 0, "nothing written to the ambient store root");
    const acctKey = `${ACCOUNT_A}${STORE_KEY_SEP}/proj`;
    const underAccount = seam.sessionsByDir.get(acctKey) ?? [];
    assert.equal(
      underAccount.filter((s) => (s.customTitle ?? "").startsWith(BASE_TITLE_PREFIX))
        .length,
      1,
      "the base lives under the account root",
    );

    // (b)+(c) A later sweep over [ambient, ACCOUNT_A] LISTS + DELETES the base under
    // ACCOUNT_A (the disk-leak close on the account path). It must bind to ACCOUNT_A.
    const n = await wb.sweepOrphanForks([undefined, ACCOUNT_A]);
    assert.equal(n, 1, "the orphaned account-dir base is reaped");
    assert.ok(
      seam.storeConfigDirs.list.includes(ACCOUNT_A),
      "the sweep listed under ACCOUNT_A",
    );
    assert.equal((seam.sessionsByDir.get(acctKey) ?? []).length, 0, "base reaped");
    // The startup sweep's temporary per-root binding RESTORED the constant binding.
    assert.equal(process.env.CLAUDE_CONFIG_DIR, ACCOUNT_A, "binding restored after sweep");
  } finally {
    if (priorCfg === undefined) delete process.env.CLAUDE_CONFIG_DIR;
    else process.env.CLAUDE_CONFIG_DIR = priorCfg;
  }
});

test("BLOCKER proof: an UNBOUND store op MISSES (base under ACCOUNT_A invisible to an ambient fork/sweep)", async () => {
  // This is the negative control — it demonstrates the failure the binding prevents.
  // We write a base under ACCOUNT_A, then attempt a fork/list under AMBIENT (no env):
  // strictStore makes the fork throw (base-not-found), and the ambient sweep finds
  // NOTHING — exactly the silent no-op + disk leak the blocker describes. Here the
  // WarmBase is built AMBIENT (no configDir ⇒ no binding), so the store reads ~/.claude.
  const ACCOUNT_A = "/accounts/A/.claude";
  const seam = makeMockSeam({ strictStore: true });
  // Seed a tagged base under ACCOUNT_A's store key directly.
  seam.sessionsByDir.set(`${ACCOUNT_A}${STORE_KEY_SEP}/proj`, [
    { sessionId: "base-A", customTitle: BASE_TITLE_PREFIX + "h" },
  ]);
  const wb = makeWarmBase(seam); // ambient ⇒ constructor binds NOTHING

  // Ambient fork (no CLAUDE_CONFIG_DIR) can't see base-A → throws → WarmBaseUnavailable.
  // (We inject base-A as run()'s base future; the ambient req matches the ambient
  // binding so the guard passes, but the UNBOUND fork reads ~/.claude and misses it.)
  const internal = wb as unknown as { bases: Map<string, Promise<string>> };
  internal.bases.set(warmbaseCacheKey(undefined, "claude-haiku-4-5", "SYS"), Promise.resolve("base-A"));
  await assert.rejects(
    () => wb.run(req()), // ambient req — fork reads ~/.claude, misses base-A
    (e: unknown) => e instanceof WarmBaseUnavailable && e.kind === "fork",
  );

  // An ambient-only sweep finds NOTHING (the account-dir base leaks).
  const n = await wb.sweepOrphanForks([undefined]);
  assert.equal(n, 0, "ambient sweep can't see the account-dir base — it would leak");
  assert.equal(
    (seam.sessionsByDir.get(`${ACCOUNT_A}${STORE_KEY_SEP}/proj`) ?? []).length,
    1,
    "base still on disk under ACCOUNT_A",
  );
});

// --- run happy path ---------------------------------------------------------

test("run happy path: fork -> resume -> delete, with the right params", async () => {
  const seam = makeMockSeam({
    resumeBehaviors: [{ kind: "success", result: "the answer" }],
  });
  const wb = makeWarmBase(seam);
  const cacheKey = warmbaseCacheKey(undefined, "claude-haiku-4-5", "SYS");
  const out = await wb.run(req());
  assert.equal(out, "the answer");
  // fork called with the project dir + our titled prefix.
  assert.deepEqual(seam.forkCalls[0], {
    baseId: "base-1",
    dir: "/proj",
    title: FORK_TITLE_PREFIX + cacheKey,
  });
  // resume query carried resume===forkId, cwd, abortController, and — CRITICALLY — the
  // SAME systemPrompt the base was created with. `resume` does NOT replay the base's
  // system into the request, so omitting it ran the model hollow (unparseable replies,
  // cacheRead=0); re-sending it restores the contract AND the cache READ. Regression
  // guard for that live bug.
  const r = seam.resumeCalls[0];
  assert.equal(r.resume, "fork-1");
  assert.equal(r.cwd, "/proj");
  assert.ok(r.options.abortController instanceof AbortController);
  assert.equal(r.options.systemPrompt, "SYS");
  // LOAD-BEARING SAFETY KNOBS (symmetric with the cold path, model.test.ts:187-188):
  // tools:[] disables ALL built-ins (a regression dropping it would silently ARM
  // Bash/Read/Edit inside every warm-base fork), and maxTurns:3 is the headroom over
  // the error_max_turns failure. Assert both so neither can silently regress.
  assert.deepEqual(r.options.tools, []);
  assert.equal(r.options.maxTurns, 3);
  // ambient (no configDir) ⇒ no env override on the resume query.
  assert.equal(r.options.env, undefined);
  // fork deleted in finally.
  assert.deepEqual(seam.deleted, ["fork-1"]);
});

test("run onUsage warm tagging: token buckets + token-bucket cost + mode 'warm'; a bogus total_cost_usd is IGNORED", async () => {
  const seam = makeMockSeam({
    resumeBehaviors: [
      {
        kind: "success",
        result: "ok",
        usage: {
          input_tokens: 10,
          output_tokens: 141,
          cache_read_input_tokens: 25736,
          cache_creation_input_tokens: 0,
        },
        // SYMMETRIC with the cold-path guard (model.test.ts): a bogus cumulative
        // total_cost_usd on the result message must NOT become the recorded cost —
        // the warm path is the design's flagged cumulative-per-session gotcha (#1).
        totalCostUsd: 999,
      },
    ],
  });
  const wb = makeWarmBase(seam);
  let seen: HaikuUsage | undefined;
  await wb.run(req({ onUsage: (u) => (seen = u) }));
  const { costUsd, ...rest } = seen as HaikuUsage;
  assert.deepEqual(rest, {
    model: "claude-haiku-4-5",
    inputTokens: 10,
    outputTokens: 141,
    cacheReadTokens: 25736,
    cacheCreationTokens: 0,
    mode: "warm",
  });
  // The token-bucket cost, NOT the bogus 999 total_cost_usd.
  assert.ok(Math.abs(costUsd - 0.0032886) < 1e-9, `cost ${costUsd}`);
  assert.notEqual(costUsd, 999);
});

// --- cold-fallback classes (WarmBaseUnavailable) ----------------------------

test("COLD-FALLBACK base-create: createBase throws => WarmBaseUnavailable('base-create')", async () => {
  const seam = makeMockSeam({ baseThrows: true });
  const wb = makeWarmBase(seam);
  await assert.rejects(
    () => wb.run(req()),
    (e: unknown) =>
      e instanceof WarmBaseUnavailable && e.kind === "base-create",
  );
});

test("COLD-FALLBACK fork: forkSession throws => kind 'fork' + base invalidated (re-create next run)", async () => {
  const seam = makeMockSeam({ forkThrows: true });
  const wb = makeWarmBase(seam);
  await assert.rejects(
    () => wb.run(req()),
    (e: unknown) => e instanceof WarmBaseUnavailable && e.kind === "fork",
  );
  assert.equal(seam.createCalls, 1);
  // invalidate ran: the next run re-creates the base.
  await assert.rejects(() => wb.run(req()));
  assert.equal(seam.createCalls, 2);
});

test("COLD-FALLBACK timeout: a hanging query + tiny timeout => kind 'timeout'", async () => {
  const seam = makeMockSeam({ resumeBehaviors: [{ kind: "hang" }] });
  const wb = makeWarmBase(seam, { timeoutMs: 5 });
  await assert.rejects(
    () => wb.run(req()),
    (e: unknown) => e instanceof WarmBaseUnavailable && e.kind === "timeout",
  );
  // Even a timed-out call GC's its fork.
  assert.deepEqual(seam.deleted, ["fork-1"]);
});

test("COLD-FALLBACK resume base-gone (NON-timeout): kind 'resume' + invalidate (proves ordering fix)", async () => {
  const seam = makeMockSeam({
    // run #1: base-gone error (NOT a timeout). run #2 succeeds — proving the base was
    // re-created (invalidate dropped the dead one).
    resumeBehaviors: [
      { kind: "throw", message: "session not found" },
      { kind: "success", result: "recovered" },
    ],
  });
  const wb = makeWarmBase(seam, { timeoutMs: 60_000 }); // timer must NOT fire
  await assert.rejects(
    () => wb.run(req()),
    (e: unknown) => e instanceof WarmBaseUnavailable && e.kind === "resume",
  );
  assert.equal(seam.createCalls, 1);
  // invalidate ran: the base was dropped, so the next run RE-CREATES it (createCalls
  // climbs to 2) instead of reusing the dead one.
  const out = await wb.run(req());
  assert.equal(out, "recovered");
  assert.equal(seam.createCalls, 2);
});

test("NOT cold-fallback (genuine model throw): plain Error, NOT WarmBaseUnavailable, base STAYS cached (proves blocker #4)", async () => {
  const seam = makeMockSeam({
    resumeBehaviors: [
      { kind: "throw", message: "overloaded" }, // first run
      { kind: "success", result: "ok" }, // second run reuses the SAME base
    ],
  });
  const wb = makeWarmBase(seam, { timeoutMs: 60_000 });
  await assert.rejects(
    () => wb.run(req()),
    (e: unknown) =>
      e instanceof Error &&
      !(e instanceof WarmBaseUnavailable) &&
      /overloaded/.test(e.message),
  );
  assert.equal(seam.createCalls, 1);
  // invalidate did NOT run: the base is still cached, so a second run does NOT re-create.
  await wb.run(req());
  assert.equal(seam.createCalls, 1);
});

// LOCKED #4b: the resume catch path must call ac.abort() on a NON-timeout, NON-
// base-gone error subtype too — not only on the timeout path. We capture the
// AbortController the resume query is handed, throw a plain (genuine model) error
// from a generator that FIRST observed the signal, and assert the signal ends up
// aborted after run() rejects. (If the cleanup ac.abort() at the non-timeout path
// were removed, the signal would NOT be aborted.)
test("LOCKED #4b non-timeout abort: a plain-error resume path still calls ac.abort() (signal.aborted === true)", async () => {
  const seam = makeMockSeam();
  let capturedAc: AbortController | undefined;
  seam.query = ((params: any) => {
    const options = params.options ?? {};
    if (options.resume !== undefined) {
      capturedAc = options.abortController as AbortController;
      seam.resumeCalls.push({ resume: options.resume, cwd: options.cwd, options });
      return (async function* () {
        // A genuine (non-base-gone, non-timeout) model error.
        throw new Error("overloaded");
      })();
    }
    const sid = seam.createCalls++ === 0 ? "base-1" : "base-x";
    return (async function* () {
      const list = seam.sessionsByDir.get(options.cwd) ?? [];
      list.push({ sessionId: sid, customTitle: options.title });
      seam.sessionsByDir.set(options.cwd, list);
      yield { type: "system", subtype: "init", session_id: sid };
      // createBase now DRAINS to the result (so the warmup round-trip completes and
      // warms the cache) before returning — the mock must yield it.
      yield { type: "result", subtype: "success", session_id: sid };
    })();
  }) as unknown as ForkSeam["query"];
  const wb = makeWarmBase(seam, { timeoutMs: 60_000 }); // timer must NOT fire
  await assert.rejects(
    () => wb.run(req()),
    (e: unknown) =>
      e instanceof Error &&
      !(e instanceof WarmBaseUnavailable) &&
      /overloaded/.test(e.message),
  );
  // The non-timeout error path ran ac.abort() (the LOCKED #4b cleanup).
  assert.ok(capturedAc, "resume query received an AbortController");
  assert.equal(capturedAc!.signal.aborted, true);
});

test("NOT cold-fallback (error-subtype result): plain Error naming subtype; fork still deleted", async () => {
  const seam = makeMockSeam({
    resumeBehaviors: [
      { kind: "errorResult", subtype: "error_max_turns", errors: ["boom"] },
    ],
  });
  const wb = makeWarmBase(seam);
  await assert.rejects(
    () => wb.run(req()),
    (e: unknown) =>
      e instanceof Error &&
      !(e instanceof WarmBaseUnavailable) &&
      /error_max_turns/.test(e.message) &&
      /boom/.test(e.message),
  );
  assert.deepEqual(seam.deleted, ["fork-1"]);
});

test("NOT cold-fallback (no result message): plain Error /no result/; fork still deleted", async () => {
  const seam = makeMockSeam({ resumeBehaviors: [{ kind: "noResult" }] });
  const wb = makeWarmBase(seam);
  await assert.rejects(
    () => wb.run(req()),
    (e: unknown) =>
      e instanceof Error &&
      !(e instanceof WarmBaseUnavailable) &&
      /no result/.test(e.message),
  );
  assert.deepEqual(seam.deleted, ["fork-1"]);
});

// --- GC behavior ------------------------------------------------------------

test("GC in finally on every path: success / base-gone / plain error / timeout all delete the fork", async () => {
  // success
  {
    const seam = makeMockSeam({ resumeBehaviors: [{ kind: "success", result: "ok" }] });
    await makeWarmBase(seam).run(req());
    assert.deepEqual(seam.deleted, ["fork-1"]);
  }
  // base-gone
  {
    const seam = makeMockSeam({ resumeBehaviors: [{ kind: "throw", message: "session not found" }] });
    await assert.rejects(() => makeWarmBase(seam, { timeoutMs: 60_000 }).run(req()));
    assert.deepEqual(seam.deleted, ["fork-1"]);
  }
  // plain error
  {
    const seam = makeMockSeam({ resumeBehaviors: [{ kind: "throw", message: "overloaded" }] });
    await assert.rejects(() => makeWarmBase(seam, { timeoutMs: 60_000 }).run(req()));
    assert.deepEqual(seam.deleted, ["fork-1"]);
  }
  // timeout
  {
    const seam = makeMockSeam({ resumeBehaviors: [{ kind: "hang" }] });
    await assert.rejects(() => makeWarmBase(seam, { timeoutMs: 5 }).run(req()));
    assert.deepEqual(seam.deleted, ["fork-1"]);
  }
});

test("GC swallows deleteSession failure: run still returns the success result + logs", async () => {
  const seam = makeMockSeam({
    deleteThrows: true,
    resumeBehaviors: [{ kind: "success", result: "ok" }],
  });
  const logs: string[] = [];
  const wb = makeWarmBase(seam, { log: (m) => logs.push(m) });
  const out = await wb.run(req()); // delete throws inside finally, swallowed
  assert.equal(out, "ok");
  assert.ok(logs.some((m) => /fork GC failed/.test(m)));
});

// --- sweepOrphanForks (write-location == sweep-location) --------------------

test("sweepOrphanForks: deletes ONLY our prefixed forks under projectDir, returns the count", async () => {
  const seam = makeMockSeam();
  // Seed under projectDir: two of OUR forks + one unrelated session.
  seam.sessionsByDir.set("/proj", [
    { sessionId: "f1", customTitle: FORK_TITLE_PREFIX + "k1" },
    { sessionId: "f2", summary: FORK_TITLE_PREFIX + "k2" },
    { sessionId: "other", customTitle: "some real session" },
  ]);
  // A fork under a DIFFERENT dir must be untouched.
  seam.sessionsByDir.set("/elsewhere", [
    { sessionId: "x1", customTitle: FORK_TITLE_PREFIX + "kX" },
  ]);
  const wb = makeWarmBase(seam);
  const n = await wb.sweepOrphanForks();
  assert.equal(n, 2);
  assert.deepEqual(
    (seam.sessionsByDir.get("/proj") ?? []).map((s) => s.sessionId),
    ["other"],
  );
  assert.deepEqual(
    (seam.sessionsByDir.get("/elsewhere") ?? []).map((s) => s.sessionId),
    ["x1"],
  );
});

test("sweepOrphanForks: a fork created via run() is then listed+deleted by a later sweep under the SAME dir", async () => {
  // No deleteSession in run()'s finally for this one — simulate a crash by making the
  // per-call delete a no-op so the fork persists, then sweep finds it.
  const seam = makeMockSeam({ resumeBehaviors: [{ kind: "success", result: "ok" }] });
  // Make the run()-time delete NOT remove the session (simulate orphan-after-crash).
  seam.deleteSession = async (id: string) => {
    seam.deleted.push(id);
    // intentionally do NOT remove from sessionsByDir
  };
  const wb = makeWarmBase(seam);
  await wb.run(req());
  // The fork is still listed under /proj (the base is also registered now — filter
  // to forks so this stays a FORK round-trip assertion).
  const forksAfterRun = (seam.sessionsByDir.get("/proj") ?? []).filter((s) =>
    (s.customTitle ?? s.summary ?? "").startsWith(FORK_TITLE_PREFIX),
  );
  assert.equal(forksAfterRun.length, 1);
  // Restore a real delete for the sweep, then sweep removes the orphaned fork (and
  // the base — both are OUR tagged sessions).
  seam.deleteSession = async (id: string, o: { dir: string }) => {
    seam.deleted.push(id);
    const list = seam.sessionsByDir.get(o.dir);
    if (list) seam.sessionsByDir.set(o.dir, list.filter((s) => s.sessionId !== id));
  };
  const n = await wb.sweepOrphanForks();
  assert.equal(n, 2); // the orphaned fork + the base
  assert.equal((seam.sessionsByDir.get("/proj") ?? []).length, 0);
});

// --- base-file disk leak / restart sweep ------------------------------------
//
// Closes the base-leak: bases are tagged BASE_TITLE_PREFIX at create time and the
// startup sweep reaps ANY prior base (a new process can't reuse a prior in-memory
// base id, so any base on disk is an orphan). Without this, every relaunch orphans
// a ~25-32k-token base file forever.
test("base tagging + sweep: a created base carries BASE_TITLE_PREFIX and is reaped by a later startup sweep", async () => {
  const seam = makeMockSeam();
  const wb = makeWarmBase(seam);
  await wb.run(req());
  // The base was registered under projectDir with the BASE_TITLE_PREFIX tag.
  const bases = (seam.sessionsByDir.get("/proj") ?? []).filter((s) =>
    (s.customTitle ?? s.summary ?? "").startsWith(BASE_TITLE_PREFIX),
  );
  assert.equal(bases.length, 1, "exactly one tagged base on disk");
  // The fork was already deleted in run()'s finally, leaving only the base.
  // A FRESH process's startup sweep (modeled by a new WarmBase over the same dir)
  // reaps the orphaned base.
  const wb2 = makeWarmBase(seam);
  const n = await wb2.sweepOrphanForks();
  assert.equal(n, 1); // the orphaned base
  assert.equal(
    (seam.sessionsByDir.get("/proj") ?? []).filter((s) =>
      (s.customTitle ?? s.summary ?? "").startsWith(BASE_TITLE_PREFIX),
    ).length,
    0,
    "base reaped",
  );
});

test("sweep reaps BOTH forks and bases under projectDir; leaves unrelated sessions", async () => {
  const seam = makeMockSeam();
  seam.sessionsByDir.set("/proj", [
    { sessionId: "fork-a", customTitle: FORK_TITLE_PREFIX + "k" },
    { sessionId: "base-a", customTitle: BASE_TITLE_PREFIX + "h" },
    { sessionId: "real", customTitle: "a real user session" },
  ]);
  const wb = makeWarmBase(seam);
  const n = await wb.sweepOrphanForks();
  assert.equal(n, 2);
  assert.deepEqual(
    (seam.sessionsByDir.get("/proj") ?? []).map((s) => s.sessionId),
    ["real"],
  );
});

// --- changed system => new base ---------------------------------------------

test("changed system => new base: system A then B (same configDir) => TWO distinct bases", async () => {
  const priorCfg = process.env.CLAUDE_CONFIG_DIR;
  try {
    const seam = makeMockSeam({
      baseSessionIds: ["base-A", "base-B"],
      resumeBehaviors: [
        { kind: "success", result: "a" },
        { kind: "success", result: "b" },
      ],
    });
    const wb = makeWarmBase(seam, { configDir: "/acct" }); // bound once to /acct
    await wb.run(req({ system: "system A", configDir: "/acct" }));
    await wb.run(req({ system: "system B", configDir: "/acct" }));
    assert.equal(seam.createCalls, 2); // a changed override prefix => fresh base
    assert.equal(seam.forkCalls[0].baseId, "base-A");
    assert.equal(seam.forkCalls[1].baseId, "base-B");
  } finally {
    if (priorCfg === undefined) delete process.env.CLAUDE_CONFIG_DIR;
    else process.env.CLAUDE_CONFIG_DIR = priorCfg;
  }
});

test("same system reused: a second run under the same key does NOT re-create the base", async () => {
  const seam = makeMockSeam({
    resumeBehaviors: [
      { kind: "success", result: "a" },
      { kind: "success", result: "b" },
    ],
  });
  const wb = makeWarmBase(seam);
  await wb.run(req());
  await wb.run(req());
  assert.equal(seam.createCalls, 1);
  assert.equal(seam.forkCalls.length, 2);
});

// --- invalidate future-identity (LOCKED #3) ---------------------------------
//
// The guard: a stale failure under a cacheKey must evict the base ONLY if the
// cached future is STILL the one the failing call branched from — so a concurrent
// re-base under the same key is never clobbered. We construct the race directly:
//   - run #1 base-creates base-old; its fork resolves; its resume parks, then errors
//     base-gone LATE -> run #1 calls invalidate(key, base-old-future).
//   - BEFORE that late failure, base-old's future is REPLACED in the map by base-new
//     (a concurrent re-base under the same key). run #1's invalidate must be a no-op
//     because the cached future is now base-new's, not base-old's.
// Observable consequence: base-new survives — a follow-up run reuses base-new and
// does NOT trigger a third createBase.
test("invalidate future-identity: a stale base-gone failure does NOT clobber a newer base under the same key", async () => {
  const seam = makeMockSeam();
  let releaseResume1: (() => void) | undefined;
  let resumeIdx = 0;

  seam.query = ((params: any) => {
    const options = params.options ?? {};
    if (options.resume !== undefined) {
      const idx = resumeIdx++;
      seam.resumeCalls.push({ resume: options.resume, cwd: options.cwd, options });
      if (idx === 0) {
        // run #1's resume: park until released, then base-gone error.
        return (async function* () {
          await new Promise<void>((r) => (releaseResume1 = r));
          throw new Error("session not found");
        })();
      }
      return makeResumeGenerator({ kind: "success", result: "ok" });
    }
    const sid = seam.createCalls++ === 0 ? "base-old" : "base-new";
    return (async function* () {
      yield { type: "system", subtype: "init", session_id: sid };
      // createBase drains to the result before returning (cache-warm completion).
      yield { type: "result", subtype: "success", session_id: sid };
    })();
  }) as unknown as ForkSeam["query"];

  const wb = makeWarmBase(seam, { timeoutMs: 60_000 });
  const key = warmbaseCacheKey(undefined, "claude-haiku-4-5", "SYS");

  // run #1: base-old created + forked; its resume now parks.
  const p1 = wb.run(req());
  await new Promise((r) => setTimeout(r, 10));
  assert.equal(seam.forkCalls.at(-1)?.baseId, "base-old");

  // Concurrent re-base: replace the cached future under the SAME key with base-new.
  // (Reaching into the private map by name-mangled access — this simulates a
  // concurrent re-base having already happened by the time run #1's late failure
  // fires.) We do it via a fresh internal Map entry, mirroring what a real
  // re-base would leave behind.
  const internal = wb as unknown as { bases: Map<string, Promise<string>> };
  internal.bases.set(key, Promise.resolve("base-new"));

  // run #1's late base-gone failure -> invalidate(key, base-old-future). The guard
  // sees the cached future is now base-new's, so it is a NO-OP (base-new survives).
  releaseResume1?.();
  await assert.rejects(
    () => p1,
    (e: unknown) => e instanceof WarmBaseUnavailable && e.kind === "resume",
  );

  // base-new survived the stale invalidate: a follow-up run REUSES the injected
  // base-new (forks from it) and does NOT create a fresh base. Only base-old was ever
  // created through the query (createCalls === 1); base-new was injected directly to
  // simulate the concurrent re-base. If the guard were broken, base-new would have
  // been evicted and this run would have triggered a 2nd createBase.
  const out = await wb.run(req());
  assert.equal(out, "ok");
  assert.equal(seam.createCalls, 1);
  assert.equal(seam.forkCalls.at(-1)?.baseId, "base-new");
});

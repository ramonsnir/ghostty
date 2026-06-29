# Design (VALIDATED): fork-per-call `claude` reuse for Agent Manager Haiku calls

Status: **IMPLEMENTED + reviewed on the `warmbase` worktree; 625 unit tests green; mechanism
re-confirmed by real e2e (ambient).** Plan gate (round 1) and review gate (round 2) both did
their job — review caught a production-breaking account-store blocker, now fixed (round-2
resolutions below). DOCS DONE: AGENT-MANAGER.md ("Warm-base fork-per-call reuse" subsection) + the CLAUDE.md Agent
Manager bullet now describe what was built.

REAL-CLAUDE EVIDENCE: fork+resume on a NON-default `CLAUDE_CONFIG_DIR` (this session's pool dir)
gave **$0.0035/call + clean isolation** (cache win confirmed on the account path). GC is
unit-tested (`deleteSession` in `finally` on every path + `sweepOrphanForks` write==sweep). A
clean live-module GC-delta run was blocked by this session's pinned pool-instance dir going
degraded after the account switch (base-create → `WarmBaseUnavailable("base-create")`, which in
the sidecar = cold-fallback — the floor held). NOTE: a grep-for-`ghostty-am-fork:` "leak" check
was a FALSE ALARM — it matched agent/session TRANSCRIPTS discussing the source string, not real
fork session files.

PENDING before merge: (a) the user's merge decision; (b) one confirmatory live-module GC-delta +
cache-win run via the ACTUAL running sidecar (the realistic env) on a healthy account — confirm
fork files are created+deleted under the bound store and per-feature cost drops in
`get_haiku_usage`. Do NOT merge to `ramon-fork` until (a).

## The mechanism (measured, `claude-haiku-4-5`, thinking disabled)

Every Haiku call today is a cold `claude` spawn that re-writes a ~25–32k-token prompt-cache
**CREATION** entry (`$2/MTok`) — ~79% of the bill (`cacheRead≈0` in prod). The fix:

1. Maintain ONE **base session** per account that holds ONLY the system prefix (system
   prompt + one trivial warmup turn). Its server-side prompt cache holds the ~25k system
   block.
2. For each summary/classify call: `forkSession(baseId)` → a throwaway branch → run the
   surface turn via `query({ options: { resume: forkId } })` → read the result → delete the
   fork file.

Measured per-call (fork+resume vs cold):

| | cache-CREATE | cache-READ | cost/call | isolation | latency |
|---|---|---|---|---|---|
| cold spawn (today) | 25,398 | 40,895 | $0.0561 | n/a | 8.2 s |
| **fork+resume** | **~50** | 33,051 | **$0.0035** | **clean by construction** | 6.6–7.5 s |

- **~94% cheaper per call** ($0.056 → $0.0035): the fork READS the base's cached system
  prefix instead of re-CREATING it.
- **Zero contamination, structurally**: each fork branches from the system-only base, so it
  sees ONLY its own surface (verified: fork A had no trace of fork B's surface and vice
  versa). This is why **bell-classify is safe to include** — no cross-surface leakage can
  bias a fail-open promotion.
- **Concurrency is free**: each fork+resume is an independent process → run as many in
  parallel as the existing `ConcurrencyBudget` allows. **No resident pool, nothing to
  wedge, no accumulation.**
- Latency ≈ cold (still spawns a process per call); this design optimizes COST, not latency.

## Architecture

```
summarize(req)                                   // model.ts, behind the existing seam
  ├─ if warm-base enabled:
  │     baseId = baseFor(req.account)            // lazily create + cache per account
  │     forkId = await forkSession(baseId)
  │     try {  result = query({ prompt: surface, options: { resume: forkId, ...opts } })  }
  │     finally { deleteSession(forkId) }         // GC the throwaway fork file
  │     └─ on ANY error (fork/resume/parse/timeout/rate-limit) → COLD FALLBACK
  └─ else → COLD one-shot query()   (today's path, unchanged)
```

### Components

- **`BaseSession` keeper** (new, e.g. `src/warmbase.ts`):
  - `baseFor(account): Promise<string>` — returns a valid base session id for the account,
    creating it lazily (a `query()` with the system prompt + a trivial `{"ok":true}` turn,
    bound to the account's `CLAUDE_CONFIG_DIR`). Cache the id in-memory keyed by account.
  - **Keep-warm**: the base's server-side cache has a ~5-min TTL. During active periods the
    ~0.5–1/min call rate keeps it warm naturally. After idle, the next fork pays a one-time
    re-warm (the resume re-creates ~25k, then forks read again). OPTIONAL: a low-rate timer
    that re-touches the base every ~4 min while the feature is active — decide in spec
    (probably skip; the occasional re-warm is cheap and a timer adds complexity).
  - **Self-heal**: if `forkSession`/`resume` fails because the base is gone/corrupt, drop the
    cached id, recreate lazily, and cold-fallback the in-flight call.
- **Fork GC**: every fork creates a `<uuid>.jsonl` under `CLAUDE_CONFIG_DIR/projects/...`.
  Delete each fork after use (`deleteSession(forkId)`), in a `finally`. Also a best-effort
  sweep on startup for orphaned forks from a crash (decide tagging scheme in spec — e.g.
  fork `title` prefix so we only GC OUR forks).
- **Config gate**: a new flag (env from the Swift controller + a sidecar default) so we ship
  DARK, measure in prod, then flip on. Default OFF initially. Name TBD in spec
  (e.g. `GHOSTTY_WARMBASE=1`).

## Correctness / safety rules (non-negotiable)

- **Cold path is the floor.** The warm-base path is a cost optimization layered over the
  existing cold `summarize()`. EVERY failure mode (fork error, resume error, unparseable
  reply, timeout, rate-limit, base recreate failure) degrades to a cold one-shot for that
  surface. The feature can never be worse than today.
- **Per-call deadline.** A fork+resume that hangs must time out and cold-fallback; never
  block the loop.
- **Account binding.** Base session + its forks run with the SAME `CLAUDE_CONFIG_DIR` as the
  call routes to (summarizer account vs bell-classify account). One base per account.
- **Both features use it** (summarizer + bell-classify), since isolation is structural.

## Known gotchas the implementation MUST handle

1. **`total_cost_usd` is CUMULATIVE per session.** The current `onUsage` reads it as
   per-call. A fork+resume query runs ONE turn, so its result's `total_cost_usd` is that
   turn's cost (the base's cost isn't recharged) — verify this empirically and, to be safe,
   prefer per-turn token-bucket costing or delta logic. Tag usage records `warm` vs `cold`
   so `get_haiku_usage` can show the savings. (`src/usage.ts`, `src/model.ts onUsage`.)
2. **Fork file disk growth** — must `deleteSession` per call + startup sweep.
3. **nvm/PATH in non-login shells** — build/test must `unset -f node npm npx` and prepend the
   nvm node bin (see release-local.sh self-heal) or use an absolute node path.
4. **SDK is loaded lazily** in `model.ts` (dist ships SDK-inlined, no node_modules for
   colleagues). `forkSession`/`deleteSession`/`resume` must come through the SAME lazy
   import path and be bundled by esbuild — confirm they're in the SDK's public exports
   (`forkSession` and `deleteSession` are exported; resume is a `query` option).
5. **Base recreate races** — concurrent calls that both find no base must not create N
   bases; single-flight the base creation per account.

## Test plan

- **Unit (mocked SDK `queryFn`/fork/delete seams, deterministic, no real claude):**
  base lazy-create + single-flight; fork→resume→delete happy path; cold-fallback on each
  error class (fork throws, resume error subtype, timeout, parse fail); account binding;
  usage tagged warm/cold + correct per-call cost; GC called in finally even on error;
  config gate OFF ⇒ byte-identical cold path.
- **Real e2e (run by the human / a verify step, real claude calls):** confirm
  cost/call ≈ $0.0035, isolation clean across distinct surfaces, fallback fires on an
  induced fork error, fork files are deleted. (Run-by-human; the workflow's gate is the
  unit suite + review.)

## LOCKED DECISIONS (from the plan-gate review — do NOT re-litigate; implement exactly)

These were raised as blockers/required-changes by the adversarial plan critic and are now
SETTLED. The plan/implementation must satisfy them; reviewers verify them, not re-debate.

1. **Costing = token-bucket ONLY (never trust `total_cost_usd`).** Compute per-call cost from
   `result.usage` token buckets × Haiku-4.5 rates (`input $1`, `output $5`, `cacheWrite $2`
   (1h), `cacheRead $0.10` per MTok) in a pure `costFromUsage(usage)`. This is immune to the
   cumulative-vs-per-turn `total_cost_usd` question (design gotcha #1), so the cost floor is
   safe-by-default. Do NOT ship an `asis` default that trusts `total_cost_usd`; if kept at
   all it is a debug-only mode, never the default. Usage records still tag `warm`/`cold`.
2. **Pin `options.cwd = projectDir` on EVERY query (base-create AND per-call resume).** Use a
   single fixed, app-owned `projectDir` so the SDK's projectKey (derived from session cwd,
   `sdk.d.ts:1299`) is deterministic and EQUALS the dir the GC sweep lists/deletes from. Pass
   the SAME `{ dir: projectDir }` to `forkSession`/`deleteSession`/`listSessions`. REQUIRED
   test: a fork created via `forkSession({dir})` is returned by `listSessions({dir})` and
   removed by `deleteSession({dir})` under the SAME dir — i.e. **write-location ==
   sweep-location** (mocked ForkSeam over an in-memory session map keyed by dir).
3. **`invalidate()` is future-identity-aware.** On a fork/resume failure, capture the base
   future the call branched from and evict the cached base ONLY if `bases.get(cacheKey) ===
   thatFuture`, so a concurrent re-base under the same key is never clobbered by a stale
   failure (mirror `baseFor`'s eviction guard).
4. **Required failure-path tests (in addition to the §"Test plan" list):** (a) the
   `withConfigDirEnv` wrapper restores (or deletes) `CLAUDE_CONFIG_DIR` even when `fn()`
   REJECTS, not only on the happy interleave; (b) the resume catch path calls `ac.abort()` on
   a NON-timeout error subtype too (not just on the timeout path / GC-on-error).

## ROUND-2 RESOLUTIONS (from the review gate — LOCKED; supersede where noted)

The review caught a real blocker + majors. These are the SETTLED resolutions to apply to the
existing worktree code:

1. **(BLOCKER) Account/store binding = set `CLAUDE_CONFIG_DIR` ONCE globally.** All warm-base
   calls share ONE sidecar-wide account (`summarizerConfigDir`, set once at startup in
   `index.ts`, used for BOTH summarizer and bell-classify — verified). So at `WarmBase`
   construction, IF a configDir is provided, set `process.env.CLAUDE_CONFIG_DIR = configDir`
   exactly once and NEVER mutate it per-call. Then every SDK op — base-create query,
   `forkSession`, resume query, `deleteSession`, `listSessions`/sweep — resolves the SAME
   account store (the SDK reads `process.env.CLAUDE_CONFIG_DIR` at call time). This is race-
   free (no per-call mutation) and **supersedes LOCKED #4a's `withConfigDirEnv` wrapper** (no
   longer needed). Keep `options.env` on the query legs too (harmless redundancy).
   - **Guard**: `run()` asserts the incoming `req.configDir` equals the one `WarmBase` was
     built with; if it EVER differs, **fall back to cold** for that call (never corrupt the
     global binding). Document loudly that warm-base assumes a single sidecar-wide account.
   - **Regression test**: mock `ForkSeam` keyed by `(effectiveConfigDir, dir)` where
     `effectiveConfigDir` reads `process.env.CLAUDE_CONFIG_DIR` at call time (mirrors the real
     SDK). Prove a fork created under ACCOUNT_A is found/listed/deleted under ACCOUNT_A, and
     that an unbound store op (wrong/empty env) MISSES — i.e. the blocker is caught.
2. **(major) Concurrent-process sweep stomp → per-instance `projectDir`.** Release and
   ReleaseLocal sidecars coexist and shared one `projectDir`, so one's sweep could delete the
   other's live base. Give `projectDir` a per-LAUNCH unique segment (bundle-id if available +
   this sidecar's pid / a run-id) and set `options.cwd = projectDir` on every query (per
   LOCKED #2), so each instance has its own projectKey namespace and `listSessions`/sweep see
   ONLY this instance's sessions. Startup sweep removes only stale run dirs whose pid is dead.
3. **(major) Fold `model` into `warmbaseCacheKey`** → key the base on
   `(configDir, model, systemHash)`. Removes the latent "two models share one base whose
   prefix-cache was written under the warmup model → silent re-CREATE" landmine.
4. **(major) Assert resume-query safety flags in the happy-path test** —
   `assert.deepEqual(opts.tools, [])` + `assert.equal(opts.maxTurns, 3)` so a regression that
   drops `tools:[]` (arming Bash/Read/Edit inside every fork) is caught (cold path already
   asserts both).
5. **(note) Document the binding mechanism** — query legs bind via `options.env`; store ops +
   queries are ALSO covered by the constant global `CLAUDE_CONFIG_DIR`; explain why the #4a
   per-call wrapper is superseded by the set-once approach.

## Wiring (expected touch points)

`macos/agent-manager/src/warmbase.ts` (new), `src/model.ts` (route through warm-base +
usage capture fix), `src/index.ts` (pass account; nothing structural), `src/usage.ts`
(warm/cold tag), config/env gate (sidecar + later `AgentManagerController.swift`), tests
alongside, then `AGENT-MANAGER.md` + `CLAUDE.md`. Build dist; GUI relaunch only; NO host
change.

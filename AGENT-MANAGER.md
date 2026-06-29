# Agent Manager (fork-only)

A **Haiku status summarizer** layered on the [Agent Dashboard](AGENT-DASHBOARD.md):
each agent tile shows a live, one-line **semantic** status instead of just the raw
working/waiting chip — optimized for *which agent needs you* and *what each is doing*:

- `Waiting: httpOnly cookie or localStorage for the JWT refresh token?`
- `Implementing the counties API timeout fix — tests passing`
- `Reviewing the diff before committing`
- `Idle — task done`

It is **off by default**, macOS-only, **read-only** (it never types into a session —
it only annotates the tile), and bills through your existing Claude Code auth (no API
key). Its Haiku traffic can optionally be routed to a **separate account** so it never
drains your main quota (see *Account routing* below).

## Attention bells (the promoter for Bell Attention v2)

> When `agent-manager-bell-filter = true`, the summarizer is also the **classifier** that
> powers the two-tier [**Bell Attention**](BELL-ATTENTION.md) feature: every bell wakes a
> Haiku classify, and a *notable* bell is **promoted** to the "needs you" tier
> (`attention-features`) while an incidental one stays the quiet raw bell (`bell-features`).
> It is **fail-open** — only a confident "ignore" suppresses; anything uncertain promotes.
> See **[BELL-ATTENTION.md](BELL-ATTENTION.md)** for the tiers, the effect vocabulary, the
> per-effect routing, and the config (incl. the `no-*` dial-down gotcha). The rate-limit
> watchdog below is one special case of the same mechanism, driven by an `alert` tag.


The summarizer also doubles as an **attention watchdog**: when a session hits the
Claude **usage/rate-limit prompt** — the interactive *"Stop and wait for limit to
reset / Ask your admin for more usage"* screen that silently halts the agent without
ringing a bell — the sidecar **rings the bell for that surface** (via the MCP
`signal_attention` tool). That fans out exactly like a real terminal bell: the 🔔 tab
title, the Agent Dashboard aggregate, the web monitor, and a phone push all light up,
so you notice even when you've stepped away.

**Haiku is the sole classifier — there is no text/regex match.** The summary call
already reads the screen every time it runs; it now also returns an optional `alert`
tag in its structured output, and it is told to judge the **current, live** state at
the bottom of the screen — so it sets `rate_limited` only while the agent is *actually
halted on that prompt right now*, and drops it the moment the agent resumes (even if the
old prompt text is still scrolled up in view). The loop rings on the **rising edge** of
that tag and clears when Haiku reports no alert — so:

- It **rings once** when the prompt appears and won't nag every 5s while it sits there.
- **Recovery un-rings correctly** — as soon as Haiku reclassifies the live screen, the
  bell re-arms. Stale text scrolled up in history never (re-)fires it, because the
  decision isn't a substring match.
- **Hidden tiles are still covered.** A tile you've hidden in the dashboard (the
  long-running, stepped-away agents this is *for*) is summarized on a slower cadence
  (`hiddenDebounceMs`, default 10 min) rather than skipped — so a hidden agent's
  rate-limit prompt still rings, within that window. (`skipHidden: true` opts out and
  silences hidden tiles entirely — see *Tuning cost*.)

Why no regex backstop: a regex matches the text *anywhere* in the viewport and can't
tell a live prompt from one scrolled up in history — so it would both miss recovery and
*falsely re-ring* after recovery. Letting Haiku own the whole decision is what fixes
both. To recognize a new condition, just teach the summarizer prompt a new `alert` tag
(`macos/agent-manager/src/prompts.ts`) — no code change.

> **One caveat — route the summarizer to a separate account.** Because the watchdog is
> the summarizer's own Haiku call, if that call bills to *the same account that just got
> rate-limited*, it fails too and the **first** detection can't fire (a held alert still
> stays armed; only the initial ring is at risk). Point the summarizer at a different
> account via **[Account routing](#account-routing-optional--bill-the-summarizer-to-a-separate-account)**
> so the watchdog survives the very limit it is watching for. This is the recommended
> setup.

## How it works (one paragraph)

A small **TypeScript sidecar** (`macos/agent-manager/`, built with the Claude Agent
SDK) runs alongside the GUI. Every ~5s it asks the in-app **MCP server** for the live
surfaces, picks the ones the dashboard has detected as agents, reads each one's
viewport, makes a single **Haiku** call to summarize it, and writes the one-liner back
onto the tile via the MCP `set_surface_annotation` tool. The summary call uses no tools
and the SDK authenticates the same way the `claude` CLI does — so there is **no API key
in Ghostty** and usage is billed to your normal plan. (A second, independent loop in the
same sidecar drives the [Agent Queue](AGENT-QUEUE.md) when it is configured — that is a
deterministic, LLM-free dispatcher and is unrelated to the summarizer. The two share one
sidecar but run **independently**: the sidecar launches when **either** `agent-manager` or
`agent-queue` is on, so you can run the queue with `agent-manager = false` and the
summarizer — the only thing here that spends Haiku — stays completely silent.)

## Requirements

1. **pty-host + Agent Dashboard** enabled (the summarizer annotates dashboard tiles):
   `pty-host = …` and `agent-dashboard = true` already in your fork config.
2. **MCP server** enabled — the sidecar's only transport: `mcp-listen = 127.0.0.1:8765`
   plus an `mcp-token` (in `~/.config/ghostty-ramon/local`). On a **fork install** these are
   auto-provisioned on first launch, so this is already satisfied.
3. **node** on your login shell `PATH` (the GUI probes `command -v node`), or set
   `agent-manager-node-path` explicitly.
4. **`claude` on your login-shell `PATH`** (the GUI probes `command -v claude`) — the
   summarizer drives your installed `claude` CLI for its Haiku calls (billed to your own
   Claude subscription). If `claude` isn't found, the summarizer self-disables per-surface;
   the Agent Queue is unaffected.
5. **The sidecar** — bundled inside a **fork install** at
   `…/Ghostty (ramon).app/Contents/Resources/agent-manager` (no action needed). In a **repo
   clone** (dev), build it once: `cd ~/git/ghostty/macos/agent-manager && npm ci && npm run build`.
6. **Claude Code hooks** (the same ones the Agent Dashboard uses — see
   `AGENT-DASHBOARD.md`) for the *best* summaries: they feed your latest prompt and the
   working/waiting state, which make the one-liners specific. Without them the summarizer
   falls back to the on-screen text alone and reads thinner.

## Enable

Add to `~/.config/ghostty-ramon/config` (fork-only keys — keep them here, not in the
shared `~/.config/ghostty/config`):

```
agent-manager = true
# optional, only if `node` isn't on your login-shell PATH:
# agent-manager-node-path = /usr/local/bin/node
```

Quit + relaunch the fork. On launch the app checks the gate (enabled + MCP configured +
node resolvable); if any is missing it stays **silently dormant** (one info log, the
dashboard is unaffected). Otherwise it spawns + supervises the sidecar.

## Account routing (optional — bill the summarizer to a separate account)

The summarizer polls continuously, so on a busy fleet its Haiku calls can eat into the
account you also code with. You can route them to a **different** account instead.

By default there is **no routing** — the summarizer inherits whatever Claude Code auth
is ambient (it works fine on a machine with no multi-account setup at all). To route it,
write an account spec to:

```
~/.config/ghostty-ramon/agent-manager/account
```

The value is one of:

- a **bare account name** (e.g. `dev`) — resolved to `~/.claude-accounts/<name>`, the
  convention used by a `claude-accounts`/`claude-pool` setup; or
- an **absolute or `~`-relative path** — used directly as the account's `CLAUDE_CONFIG_DIR`.

The summarizer's model calls then run with that `CLAUDE_CONFIG_DIR` (HOME/PATH/OAuth are
otherwise preserved), so they bill against that account. If the spec doesn't resolve to a
real directory, it's ignored and the summarizer falls back to the ambient auth (a warning
is logged). The `GHOSTTY_AGENT_MANAGER_ACCOUNT` environment variable, if set, takes
precedence over the file.

This is a **sidecar-side** setting: change the file and restart the sidecar (the GUI
respawns it; no app relaunch needed for the value to take effect on the next spawn).

## Tuning the prompt (no rebuild)

The summarizer takes an optional override file, appended to the built-in prompt and
reloaded on change (it cannot change the output format or grant any capability — the call
runs with no tools):

```
~/.config/ghostty-ramon/agent-manager/summarizer.md   # the status one-liner
```

e.g. "Prefer the file/feature name over the verb; flag failing tests."

## Tuning cost (no rebuild)

The summarizer decides *when* to call Haiku with a few gates you can tune in an optional
JSON file (sibling of `summarizer.md`), so you can dial usage down without a rebuild —
**restart the sidecar to apply** (kill the `node` child, or quit + relaunch the fork; the
GUI respawns it):

```
~/.config/ghostty-ramon/agent-manager/config.json
```

```jsonc
{
  "debounceMs": 120000,           // min ms between calls per session (default 120000 = 2 min)
  "hiddenDebounceMs": 600000,     // min ms between calls for a HIDDEN tile (default 600000 = 10 min)
  "changeRatioThreshold": 0.2,    // 0..1 — fraction of the screen tail that must differ
                                  //   to count as a real change (default 0.2; 0 = any diff)
  "skipHidden": false,            // true = NEVER summarize a hidden tile (default false: see below)
  "idleSkipSeconds": 45,          // unchanged + idle this long => skip (default 45)
  "maxConcurrent": 10,            // also the per-sweep batch cap
  "rateLimitBackoffMaxMs": 600000 // cap on the auto-backoff when YOUR account is limited
}
```

Unknown / out-of-range keys are ignored (the default is kept), and an absent or malformed
file just uses the defaults. What each lever buys you:

- **`hiddenDebounceMs` / `skipHidden`** — by default a tile you've **hidden** in the
  dashboard is still summarized, just **rarely** (every `hiddenDebounceMs`, default 10 min)
  rather than every `debounceMs`. This keeps the **rate-limit watchdog alive on hidden
  agents** — the long-running, stepped-away ones it exists for — at a fraction of the cost.
  Set **`skipHidden: true`** to opt back into the old behavior (a hidden tile costs nothing
  and is never summarized — but its rate-limit prompt then never rings). Raise
  `hiddenDebounceMs` to make hidden tiles even cheaper.
- **`changeRatioThreshold`** — the screen is compared *fuzzily*: spinner glyphs and
  elapsed-time/token counters are normalized out, and a session only re-summarizes when
  more than this fraction of its recent lines actually change. A higher value = fewer
  calls (and slightly staler summaries); a lower value = fresher (and more calls).
- **`debounceMs`** — the hard floor between calls for one (visible) session. Raise it to cut
  the rate across the board.
- A **waiting/idle** agent whose footer is merely animating is skipped regardless — its
  summary wouldn't change anyway.

### Auto-backoff when the summarizer's own account is rate-limited

If the account the summarizer bills to runs out of usage, its calls fail (no usable
summary comes back). Rather than keep hammering the limited account every debounce
window, the loop **automatically backs off**: after a sweep where every call fails it
waits, doubling the wait each time (`debounceMs`, then ×2, ×4, …) up to
`rateLimitBackoffMaxMs` (default 10 min). While backed off it makes **at most one probe
call per window**; the first call that **succeeds** (i.e. the limit reset) snaps it back
to full cadence. So a depleted account is poked roughly once every 10 minutes instead of
constantly, and recovery is automatic — no intervention. (You can still route the
summarizer to a fresh account via the `account` file above to keep summaries flowing
while the other account recovers.) Set `rateLimitBackoffMaxMs` lower if you want it to
re-probe more often, or to `0` to effectively disable the backoff.

## Verifying / troubleshooting

- Console.app → filter subsystem = your bundle id, category = `agent-manager`. Expect
  `Agent Manager sidecar started` and a per-surface `surface <uuid>: "<summary>"` line.
  If account routing is active you'll also see `summarizer billing routed to CLAUDE_CONFIG_DIR=…`.
- **Dormant?** The one info log says why (`agent-manager is off` / `mcp-listen is not
  set` / `mcp-token is not set` / `node could not be resolved`).
- **No summaries on tiles?** Confirm the dashboard shows the agent as a tile at all
  (detection is shared); confirm the sidecar is built (`macos/agent-manager/dist/index.js`
  exists); confirm `mcp-listen`/`mcp-token` are set.
- **Summaries look generic?** That's the no-hooks fallback (viewport-only). Install the
  Claude Code hooks so your prompt + working/waiting state reach the summarizer.

## Haiku usage / budget tracking

Every Haiku call the Agent Manager makes is recorded so you can answer **"how much did each
feature spend over the last N hours"** — and it **survives GUI/sidecar restarts** (the log
is an on-disk file; the sidecar restarts with the GUI but totals stay cumulative).

- **What's tracked:** one entry per call with tokens (input / output / cache-read /
  cache-creation), the SDK's reported `costUsd`, the **feature** that triggered it, and the
  billed **account**. The two features are `summarizer` (the continuous per-tile status pass)
  and `bell-classify` (the Bell Attention per-bell promotion). All Haiku traffic funnels
  through one place, so every feature is covered automatically.
- **Where:** `~/Library/Logs/ghostty-ramon-haiku-usage.jsonl` (one JSON object per line).
  **On by default** whenever the sidecar runs; turn it off with the fork-only config key
  **`agent-manager-usage-tracking = false`** in `~/.config/ghostty-ramon/config` (a GUI
  relaunch applies the change). Entries older than 14 days are pruned on sidecar startup, so
  the file can't grow without bound.
- **How to ask:** the **`get_haiku_usage` MCP tool** (`{hours?}`, default 3) returns a grand
  total plus per-feature and per-account breakdowns — so an agent (or you, via the MCP
  server) can just ask "usage by feature over the last 3 hours." It's a pure file read and
  never spends a Haiku call itself.
- **Reading the numbers:** cost is the SDK's `total_cost_usd` summed per call (verified
  non-zero on pool auth). It is usually dominated by **cache-creation** tokens on a *cold*
  call (the system prompt is cached) and is cheap on subsequent **cache-read** calls — so a
  burst of cold classifies costs more than the call count alone suggests. The per-account
  breakdown pairs naturally with *Account routing* above to see which account a feature drains.

```sh
# quick peek without the MCP tool — per-feature cost in the last 3h (jq):
jq -rs --arg since "$(date -u -v-3H +%Y-%m-%dT%H:%M:%S)" '
  map(select(.ts >= $since)) | group_by(.feature)
  | map({feature: .[0].feature, calls: length, costUsd: (map(.costUsd) | add)})' \
  ~/Library/Logs/ghostty-ramon-haiku-usage.jsonl
```

(You can also just hand the file to Claude and ask in plain English.)

## Cost & privacy

Each summary is one Haiku call, gated by a per-session debounce (~2 min; ~10 min for a
hidden tile), a fuzzy change-detector (animation-proof), and an idle-skip, with a small
concurrency cap — so a wall of idle/unchanged sessions costs nearly nothing. See *Tuning cost*
above to dial it further. The session's recent on-screen text is sent to the model for
summarization; hide the tile (or disable the feature) for any session you don't want
summarized. Use *Account routing* above to keep this traffic off your primary account.

## Implementation notes (for agents touching the code)

These are the load-bearing dev-internals for an agent working on this feature. (The
sections above are user-facing config/usage; this is the architecture, the gotchas, and
the wiring/test ledger.)

### Architecture: warm TS Agent SDK sidecar (brain) + MCP server (hands)

A warm **TypeScript Agent SDK sidecar is the brain; the MCP server is its hands.**
`claude -p` was rejected (cold-boots the CLI per call). Instead a persistent TS program
(`macos/agent-manager/`, `@anthropic-ai/claude-agent-sdk`, NOT in `Ghostty.xcodeproj`,
built with `npm ci && npm run build`) keeps warm and drives Ghostty's existing **MCP
server** as a tool provider. **Billing rides Claude Code's own auth** (subscription/pool
creds the SDK reads on disk) — **NO Anthropic API key in Ghostty** (verified: a bare
`query()` with no `ANTHROPIC_API_KEY`/`CLAUDE_CODE_OAUTH_TOKEN` succeeds via the pool).

### Deterministic loop, single-shot LLM (NOT agentic)

`src/index.ts` polls `list_surfaces` every 5s, applies PURE gates (`src/summarizer.ts`:
`isAgentSurface`/`shouldSummarize`/change-detection/debounce/skip-idle/`ConcurrencyBudget`),
`read_surface`s the viewport, composes a prompt (baked base `src/prompts.ts` + the
`~/.config/ghostty-ramon/agent-manager/summarizer.md` override, mtime-cached), makes ONE
Haiku call (`src/model.ts`: `tools:[]`, `maxTurns:3`, NO `mcpServers` — the summary call
touches no tools), parses strict JSON, and writes `set_surface_annotation`. MCP I/O is a
dependency-free fetch JSON-RPC client (`src/mcp.ts`) — no MCP-client dep; tests are
Node's built-in `node --test`.

### Cost controls — hidden-throttle + animation-proof fuzzy change + quiescent-skip + config

The "Haiku burns my usage" fix. Four levers cut the call rate; the dominant sink was a
quiescent (`waiting`/`idle`) agent whose ANIMATED footer (spinner / "esc to interrupt" /
elapsed-time counter) flipped the old exact-hash `fingerprint` every poll, so it
re-summarized every debounce window forever.

**(1) Throttle (not skip) hidden tiles — so the rate-limit watchdog survives hiding:**
the dashboard's `hidden` set is exposed through `list_surfaces` (Swift:
`HookSnapshotEntry.hidden` unioned from `model.hidden` → `MCPLayout.SurfaceRow.hidden`,
emitted only when true; TS: `Surface.hidden`). A hidden tile is summarized on a MUCH
LARGER per-session debounce (`hiddenDebounceMs`, default 600000 = 10 min) via the pure
`effectiveDebounceMs(surface, cfg)` = `surface.hidden ? max(debounceMs, hiddenDebounceMs)
: debounceMs`, consulted by the debounce clause of BOTH `preGate` and `shouldSummarize`.
**`skipHidden` defaults FALSE** — it's the explicit opt-out for zero-cost behavior (when
true, both gates still short-circuit `{reason:"hidden"}` and skip the `read_surface`
entirely). **Why the flip:** the rate-limit attention bell (below) has Haiku as its SOLE
classifier, so a fully-skipped hidden tile NEVER rings — and hidden tiles are exactly the
long-running, stepped-away agents the watchdog is for. Throttling instead of skipping
keeps the watchdog alive on them within `hiddenDebounceMs` at a fraction of the
visible-tile cost.

**(2) Fuzzy change detection (replaces the binary `fingerprint`):** `LastSummary` now
stores `signals` (exact hash of the AUTHORITATIVE hook tuple
agentState|lastPrompt|lastTool — any diff = change) + `tail` (the NORMALIZED change-tail
kept as TEXT). `changeTail` strips spinner glyphs (Braille U+2800–28FF + dot/bar
spinners) and collapses digit-runs→`#` and whitespace via `normalizeChangeLine`, so an
animated footer normalizes to a STABLE string; `tailChangeRatio` is the Jaccard distance
over the NON-BLANK line MULTISETS (scroll-tolerant), and the screen counts as CHANGED only
when `ratio > cfg.changeRatioThreshold` (default 0.2).

**(3) Quiescent-skip:** an unchanged `waiting`/`idle` agent (`isQuiescent`) is skipped
REGARDLESS of `idleSeconds` (its summary won't change); a non-quiescent unchanged surface
keeps the old idle-seconds skip / else re-summarizes so a `working` agent's phase still
tracks.

**(4) Config overlay (`src/config.ts`, no rebuild):**
`~/.config/ghostty-ramon/agent-manager/config.json` (pure `parseConfig` overlay on
`DEFAULT_CONFIG` over an injected `readFile`, restart-to-apply, malformed/unknown keys
ignored) tunes `debounceMs` (default **120000** = 2 min), `hiddenDebounceMs` (default
**600000** = 10 min), `changeRatioThreshold`, `skipHidden` (default **false**),
`idleSkipSeconds`, `maxConcurrent`, `agentProcessNames`.

The change-detection pure helpers are
`changeSignals`/`changeTail`/`tailChangeRatio`/`isQuiescent`/`normalizeChangeLine`/
`lineMultiset` (all tested). Wiring: Swift — `AgentDashboardController.swift`
(`HookSnapshotEntry.hidden`), `MCPLayout.swift` (`SurfaceRow.hidden` + JSON emit); sidecar
— `mcp.ts` (`Surface.hidden`), `summarizer.ts` (config fields + `LastSummary` shape + the
new pure helpers + `shouldSummarize`/`preGate`), `config.ts` (NEW), `index.ts`
(`loadConfig` in `main`, record `signals`/`tail`). Tests: Swift `MCPServerTests`
(`surfacesJSONDataEmitsHiddenWhenTrue` + omit-when-false), `AgentDashboardTests`
(`hookSnapshot` hidden bit); sidecar `summarizer.test.ts` (change-detection +
quiescent/hidden truth table + `effectiveDebounceMs` + hidden-throttle/skip cases),
`config.test.ts` (NEW + `hiddenDebounceMs` parse), `index.test.ts` (record shape; backoff
windows now reference `cfg.debounceMs`). **GUI relaunch (for the `hidden` field) + rebuilt
sidecar `dist` + sidecar restart; no host/Zig change.**

### Rate-limit auto-backoff (sidecar-only)

When the summarizer's OWN account is rate-limited, slow way down until one call succeeds
(the limit resets). When the summarizer bills to a depleted account, its `summarize()`
calls fail (throw) or return an unusable/unparseable reply — and without this it would
keep firing one call per surface per `debounceMs`, hammering the limited account. An
ACCOUNT-WIDE adaptive backoff (`LoopDeps.summarizerBackoff = {failureStreak,
nextProbeMs}`, pure `backoffDelayMs(streak, base, max) = min(max, base·2^(streak-1))`,
default cap `cfg.rateLimitBackoffMaxMs` 600000) governs `runSweep`: `summarizeOne` now
returns `"ok"|"fail"|"skip"` ("ok" = a model call parsed = account healthy; "fail" = threw
OR unparseable; "skip" = gate not-due, no call). NORMAL sweep fires the due batch
concurrently and aggregates — ANY "ok" resets the streak to 0; else if any "fail",
streak++ and arm `nextProbeMs`. BACKED-OFF sweep (streak>0): if `now < nextProbeMs` return
with ZERO calls; once the window elapses, probe candidates SEQUENTIALLY until ONE makes a
real call (not a gate-skip, so a leading quiescent tile can't waste the probe) — "ok"
clears the backoff + logs "resuming", "fail" extends it. So a depleted account is poked
~once per 10 min (one probe), and the first success snaps back to full cadence — fully
automatic. Unparseable counts as "fail" deliberately (a rate-limit message often renders
as un-parseable text, not an exception, so "until one SUCCEEDS" means "until one returns a
real summary"). Wiring: sidecar ONLY — `summarizer.ts` (`rateLimitBackoffMaxMs` cfg +
`backoffDelayMs`), `config.ts` (parse the key), `index.ts` (`summarizerBackoff` on
`LoopDeps` + `SummarizeResult` return + `runSweep` gate/probe/aggregate + `main` init).
Tests: `summarizer.test.ts` (`backoffDelayMs`), `config.test.ts` (parse), `index.test.ts`
(`backoff:` group — engage-on-all-fail, success-keeps-0, cooldown-no-calls,
one-probe-recovers, failed-probe-extends, unparseable-is-fail). **Rebuilt sidecar `dist` +
sidecar restart only; no GUI/host/Zig change.**

### Warm-base fork-per-call reuse — the cache-CREATION cost fix (default OFF: `GHOSTTY_WARMBASE=1`)

**The big cost lever.** Every Haiku call is a fresh `claude` spawn that re-writes a
~25–32k-token prompt-cache CREATION entry (`$2/MTok`) — ~79% of the bill (`cacheRead≈0` in
prod). `src/warmbase.ts` removes that: keep ONE **system-only base session** per
`(configDir, model, systemHash)` and, per call, `forkSession(base)` → run the surface turn
via `query({ resume: forkId })` → `deleteSession(forkId)`. The fork READS the base's cached
system prefix instead of re-creating it. **Measured: $0.0561 → $0.0035/call (~94% cheaper),
isolation clean by construction** (each fork branches from the system-only base, never from
another surface — so it is safe for BOTH the summarizer AND the fail-open bell-classify).

Load-bearing facts (all unit-tested; `model.test.ts`/`warmbase.test.ts`/`index.test.ts`):

- **The cold path is the FLOOR.** `model.ts` routes through `WarmBase.run()` only when a
  `WarmBase` is wired; a warm-MECHANISM failure throws `WarmBaseUnavailable` (kinds:
  `base-create`/`fork`/`resume`/`timeout`/`config-mismatch`) → model.ts falls back to today's
  cold one-shot for THAT surface. A GENUINE model error/result is rethrown PLAIN so model.ts
  does NOT cold-retry (no double-charge). Gate OFF ⇒ `summarize()` is wired two-arg, the cold
  path is control-flow identical. So warm-base can never be worse than cold.
- **Account/store binding = set `CLAUDE_CONFIG_DIR` ONCE at construction** (the BLOCKER the
  review caught): the SDK's in-process store fns (`forkSession`/`deleteSession`/`listSessions`)
  take NO env arg and resolve their store root from `process.env.CLAUDE_CONFIG_DIR` at call
  time. The whole sidecar uses ONE account (`summarizerConfigDir`, both features), so the
  constructor binds it once — race-free — and every op (base-create, fork, resume, delete,
  sweep) resolves the SAME account store. `run()` GUARDS that each `req.configDir` equals the
  bound one and cold-falls-back (`config-mismatch`) if it ever differs, so the constant
  binding is never wrong for a served call. (Per-call env mutation was rejected as racy.)
- **Token-bucket costing, NEVER `total_cost_usd`** (`costFromUsage` × `HAIKU_RATES`): the SDK's
  `total_cost_usd` is cumulative-per-session, so warm/cold both price from `usage` token
  buckets, immune to the cumulative question and directly comparable; usage records are tagged
  `mode:"warm"|"cold"` for `get_haiku_usage`.
- **Fork GC**: `deleteSession(forkId)` in a `finally` on EVERY path (success/throw/timeout) +
  a startup `sweepOrphanForks` that reaps only sibling `run-<pid>` dirs whose owning pid is
  dead. **Per-instance + per-launch `projectDir`** (instance key from the MCP URL port +
  `process.pid`, pinned as `options.cwd` on every query) so coexisting Release/ReleaseLocal
  sidecars — or an overlapping relaunch — can never sweep each other's live base.
- **Timeout** via an `AbortController` + a `timedOut` flag set ONLY in the timer callback and
  checked FIRST in `catch`, so a genuine deadline → `timeout`/cold-fallback while a real model
  error is classified correctly. Resume query keeps `tools:[]` + `maxTurns:3` (no tool-arming
  inside a fork) and NO `systemPrompt` (inherited from the base via resume).
- **`buildWarmBase` fully guards construction** (dynamic SDK import + startup sweep): ANY
  failure leaves `warmBase=undefined` so the cold floor + the (Haiku-free) queue still come up
  even with `GHOSTTY_WARMBASE=1`.

Wiring: `src/warmbase.ts` (new), `src/model.ts` (route + token-bucket usage), `src/index.ts`
(gate `shouldEnableWarmBase` + `buildWarmBase` + per-instance dirs), `src/usage.ts`
(`mode?:"warm"|"cold"` tag). **Rebuilt sidecar `dist` + sidecar restart only; no GUI/host/Zig
change.** Status / open verification: see `AGENT-MANAGER-WARMBASE-DESIGN.md` (real-claude
cache+isolation confirmed; GC unit-tested; live-module GC-delta to confirm via the running
sidecar before relying on it).

### Agent DETECTION is via `agentKind`, NOT `processName` (load-bearing gotcha)

Under the `claude-pool` wrapper the surface's foreground process is `bash` (and even bare,
`claude` reports its versioned-binary basename e.g. `2.1.185`), so a `processName ∈
{claude,codex}` check NEVER matches a real agent. The Agent Dashboard already detects
agents via a foreground-pid **subtree walk**; Phase 0 exposes that result as
`list_surfaces.agentKind` (`AgentDashboardModel.agents` → `HookSnapshotEntry.agentKind` →
`MCPLayout.SurfaceRow.agentKind` → JSON → `Surface.agentKind`), and `isAgentSurface` keys
off it (then `agentState`, then `processName`). This also keeps the summarizer's notion of
"agent" identical to the dashboard's tiles.

### Rich summaries need the Claude hooks

The strongest inputs — the user's `lastPrompt` and `agentState` (working/waiting) — arrive
via the same Agent-Dashboard `/agent-state` hooks (so they only populate on the build the
hooks POST to, i.e. the **installed Release** on the default MCP port, NOT a dev `+1/+2`
port). Without them the summarizer falls back to the viewport tail alone and reads thin
("Idle — repo ready"); with them it reads rich. Prompt is tunable live via the override
file (no rebuild).

### SELF-DISABLE (hard requirement, unit-tested)

`AgentManagerController.start()` runs the §8 gate `sidecarShouldStart(managerEnabled,
queueEnabled, mcpListen, mcpToken, nodePath)` off-main: unless **at least one feature**
(`agent-manager` OR `agent-queue`) is on AND `mcp-listen`+`mcp-token` are set AND `node`
resolves (config `agent-manager-node-path`, else a login-shell `command -v node` probe —
GUI apps don't inherit `PATH`), it stays fully dormant with EXACTLY ONE info log; the
dashboard is unaffected. The sidecar is spawned/supervised via `Process` (lazy, bounded
restart backoff — both pure + tested), torn down on quit, run with
`GHOSTTY_AGENT_MANAGER=1` so its own model activity can't recurse through the agent-state
hook.

### Shared-sidecar / independent features (the agent-manager↔agent-queue untangle)

The summarizer (agent-manager) and the queue supervisor (agent-queue) are TWO independent
loops that share ONE sidecar process. The launch gate (`sidecarShouldStart`,
EITHER-feature OR) starts the sidecar when either is enabled; which loops actually RUN
inside it is decided SEPARATELY by per-feature env flags, so each works with the other off
— in particular `agent-queue = true` + `agent-manager = false` runs the queue with the
(Haiku-billing) summarizer fully silent (the reason the untangle exists). Pure helpers
`AgentManagerController.applySummarizerEnv(into:enabled:)` (→ `GHOSTTY_SUMMARIZER`) and the
existing `applyAgentQueueEnv` (→ `GHOSTTY_AGENT_QUEUE`) arm the two; sidecar
`parseLoopEnablement(env)` reads them in `index.ts main()` and gates the `tick`/`queueTick`
loops.

**BACK-COMPAT asymmetry:** `GHOSTTY_SUMMARIZER` is set EXPLICITLY both ways (`1`/`0`, NOT
stripped when off) and the sidecar treats an ABSENT flag as ON — because the summarizer
used to be unconditional, so an OLD GUI that respawns a NEW `dist` mid-upgrade keeps
summarizing; only this new GUI's explicit `0` (agent-manager off) disables it. The queue
stays opt-in (`1` only; absent ⇒ off). No new config key (reuses `agent-manager` +
`agent-queue`), no Zig/host change. Wiring: `AgentManagerController.swift`
(`sidecarShouldStart`/`sidecarDisabledReason` replacing the old
`agentManagerShouldStart`/`disabledReason`, `applySummarizerEnv`, `start()` OR-gate,
`childEnvironment`); sidecar `index.ts` (`parseLoopEnablement` + loop gating). Tests:
`AgentManagerControllerTests`
(`shouldStartWhenQueueOnlyPresent`/`shouldNotStartWhenBothDisabled`/truth-table/
`summarizerEnv*`), sidecar `index.test.ts` (`loops:` group). **GUI relaunch + rebuilt
sidecar `dist`; no host/Zig change.**

### Read-only; ZERO autonomous send, ZERO host/Zig protocol change — wiring + tests

The only Zig change is two additive default-off config keys. Wiring: core —
`src/config/Config.zig` (`agent-manager`/`agent-manager-node-path` + parse test); macOS —
`macos/Sources/Features/AgentManager/AgentManagerController.swift`,
`macos/Sources/Features/MCP/MCPAnnotation.swift` (`set_surface_annotation` tool + pure
`AgentAnnotationPayload.fromArguments` + main-hop handler posting
`.ghosttyAgentAnnotationDidChange`), `MCPLayout.swift`/`MCPTools.swift` (`agentKind` +
`list_surfaces` enrichment), `AgentDashboardController.swift` (`HookSnapshotEntry.agentKind`
+ `annotations` store + observer) + `AgentPreviewTile.swift` (renders the summary),
`Ghostty.Config.swift` (`agentManagerEnabled`/`agentManagerNodePath`), `AppDelegate.swift`
(off-main start), `project.pbxproj` (iOS exclusion); sidecar — `macos/agent-manager/*`.
Tests: `macos/Tests/AgentManager/AgentManagerControllerTests.swift` (self-disable truth
table + backoff + URL), `macos/Tests/MCP/MCPAnnotationTests.swift`, the `agentKind`
`surfacesJSONData` cases in `macos/Tests/MCP/MCPServerTests.swift`, the `agent-manager` Zig
config test, and the sidecar's `node --test` suite (`npm test` in `macos/agent-manager`).
**GUI relaunch only** to enable (no host restart). For Ramon's dev tree the sidecar runs
from `macos/agent-manager/dist` via the `#filePath` fallback in `resolveSidecarDir()`
(build it with `npm ci && npm run build`).

Note on the annotation contract: `AgentAnnotation` / the `set_surface_annotation` tool
carry ONLY `summary`/`phase`/`needsUser` + the Agent Queue tags
(`queueKey`/`queueName`/`queueUrl`); the partial-MERGE behavior stays because the Queue
uses it. The only autonomous send path is the `send_text`/`send_key` MCP tools (used by
the Queue's exit prelude). **Do NOT rebuild a reply-suggestion feature** — a previous
Approve/Edit/Dismiss-on-`waiting`-tiles pass was removed end-to-end as
low-value/quota-draining.

### COLLEAGUE / DMG distribution — BOTH the QUEUE and the Haiku SUMMARIZER work

Both release paths (`dist/macos/release-local.sh` step 3b +
`.github/workflows/fork-release.yml`) build the sidecar and copy **`dist/` + `package.json`
ONLY** into `Contents/Resources/agent-manager` — the path `resolveSidecarDir()` prefers
over the dev `#filePath`. **`node_modules` is deliberately NOT bundled** (~271MB and it
ships a ~215MB native `claude` Mach-O — in `@anthropic-ai/claude-agent-sdk-darwin-arm64` —
that would break notarization), so the bundle is pure-JS data — notarization-safe, no extra
signing (the app seal covers `Resources/`).

**The summarizer is NO LONGER dev-only** (this supersedes the old "needs un-bundled
`node_modules`" note). The release `npm run build` is now `tsc` + **esbuild**
(`esbuild.config.mjs`): after `tsc` emits `dist/`, esbuild RE-bundles `dist/index.js` into a
single self-contained ESM file with **the Claude Agent SDK's JavaScript inlined** (a few MB,
minified) — so the summarizer's lazy `import("@anthropic-ai/claude-agent-sdk")` resolves from
the bundle with `node_modules` absent. The native platform package is marked **external** so
esbuild never drags a Mach-O in (a size guard + Mach-O-magic check in the config FAIL the
build if one ever sneaks in). The trick that makes shipping NO native binary OK: the SDK's
`query()` does not make HTTP itself — it SPAWNS the `claude` CLI — and `model.ts` points it at
the **colleague's ALREADY-INSTALLED `claude`** via the SDK's `pathToClaudeCodeExecutable`
option (`resolveClaudePath(env)` reads `GHOSTTY_CLAUDE_PATH`, falling back to a bare `claude`
on the SDK's own PATH lookup when unset). `AgentManagerController` resolves `claude` via the
generalized `probeExecutableViaLoginShell` (shared with the `node` probe) and sets
`GHOSTTY_CLAUDE_PATH` in the sidecar env (pure, tested `applyClaudePathEnv`).

> **The probe is ROBUST to the GUI's pristine launchd PATH.** A GUI app does NOT inherit your
> terminal PATH, and a plain login shell (`zsh -l`) sources `.zprofile`/`.zshenv` but **NOT**
> `.zshrc` — so an install whose PATH entry lives in `.zshrc` (the common `~/.local/bin/claude`
> from the official native installer, or nvm's `node`) was **silently missed**, disabling the
> summarizer + rate-limit watchdog on a colleague's Mac even though `claude` worked fine in
> their terminal. (Same root cause as the MCP auto-registration miss — see CLAUDE.md.) Fixed:
> `probeExecutableViaLoginShell` now checks **well-known absolute locations FIRST** (pure
> `wellKnownExecutablePaths`: `~/.local/bin`, `~/.claude/local` for claude, Homebrew, nix — no
> subprocess, immune to PATH), then falls back to a LOGIN shell and an INTERACTIVE login shell
> `command -v` (`-lc` → `-ilc`; `-i` sources `.zshrc`). A printf marker isolates the path from
> `.zshrc` banner noise; stdin=/dev/null so a prompt EOFs instead of hanging.

**RUNTIME PREREQS on the colleague's Mac: `node` on PATH (for any sidecar feature) AND
`claude` on PATH (for the summarizer + the rate-limit watchdog).** The §8 launch gate is
UNCHANGED — it does NOT consider `claude`, so `claude`'s absence NEVER blocks the sidecar:
the Agent Queue still runs; only the summarizer self-disables PER-SURFACE (a summary call with
no resolvable `claude` throws → the per-surface error path skips it). So for a colleague with
both `node` + `claude` installed (plus the usual opt-in: `agent-queue`/`agent-manager` on, MCP
configured, the agent-state hooks, a template) **both the queue AND the Haiku tile summaries +
the rate-limit attention watchdog work, billed to their own Claude subscription**. Three
remaining load-bearing facts: (1) the Agent Queue engine has ZERO npm deps (Node built-ins +
global `fetch`); (2) `model.ts` still uses a TYPE-ONLY import + a LAZY `await import()` so the
pre-bundle entry carries no static SDK import (esbuild inlines the real JS at release); (3)
`package.json` is bundled so node treats `dist/*.js` as ESM (`"type":"module"`). Both release
scripts add sanity greps (the SDK JS is inlined — a "Claude Code executable" marker present —
and NO bare `@anthropic-ai` import survived bundling). Wiring: `model.ts` (`resolveClaudePath`
+ `pathToClaudeCodeExecutable`), `esbuild.config.mjs` (NEW), `package.json` (`build` =
tsc+esbuild, esbuild devDep), `AgentManagerController.swift` (`applyClaudePathEnv` +
`resolveClaudePath`/`probeExecutableViaLoginShell`/`wellKnownExecutablePaths` +
`GHOSTTY_CLAUDE_PATH` in `childEnvironment`), `dist/macos/release-local.sh` (step 3b),
`.github/workflows/fork-release.yml`
("Build + bundle agent-manager sidecar (dist only; SDK JS inlined)"). Tests:
`AgentManagerControllerTests` (`applyClaudePathEnv`, `wellKnownClaudePaths*`/`wellKnownNodePaths*`),
`model.test.ts` (`resolveClaudePath`).

### Account routing (optional) — dev internals

By default the summarizer inherits the ambient Claude Code auth (works with NO
multi-account setup); set a spec in `~/.config/ghostty-ramon/agent-manager/account`
(sibling of `summarizer.md`) OR the `GHOSTTY_AGENT_MANAGER_ACCOUNT` env (env wins) to route
its Haiku calls to a specific account. The spec is a bare account NAME →
`~/.claude-accounts/<name>` (the `claude-accounts` convention) or an absolute/`~` PATH used
directly as `CLAUDE_CONFIG_DIR`; a spec that doesn't resolve to a real dir is ignored (warn
+ inherit, so a stale name never breaks anyone). The resolver (`src/account.ts`:
`readAccountSpec`/`resolveAccountDir`, PURE over an injected fs seam + `account.test.ts`)
feeds `LoopDeps.summarizerConfigDir`, which `summarizeOne` threads into the model call;
`model.ts summarize()` then passes `env:{...process.env, CLAUDE_CONFIG_DIR}` (spread so
HOME/PATH/OAuth survive — only the config dir is re-pointed). SIDECAR-only: edit the file +
restart the sidecar (the GUI respawns it; no app relaunch).

### Attention bell on rate-limit (fork-only, sidecar-only, ZERO Swift/Zig/host change)

The summarizer doubles as an attention watchdog: when a session hits the Claude
usage/rate-limit BLOCKING prompt ("Stop and wait for limit to reset / Ask your admin for
more usage" — which halts the agent WITHOUT ringing a terminal bell), the sidecar rings the
bell via the EXISTING MCP `signalAttention` tool (`client.signalAttention`, already used by
the Queue's leave-and-bell) — fanning out to the 🔔 tab title, dashboard aggregate, web
monitor, and push, all off the one `.ghosttyBellDidRing` post. **No new MCP tool / no Swift
/ no host work** — the bell path already existed; this just triggers it.

**HAIKU IS THE SOLE CLASSIFIER — NO regex/text match (deliberate, see below).** An
extensible `alert?: string` field was added to the Haiku STRUCTURED OUTPUT contract
(`src/prompts.ts`, parsed in `parseSummary` → `ParsedSummary.alert`, lower-cased/trimmed);
the prompt tells Haiku to judge the CURRENT/LIVE state at the BOTTOM of the screen and set
`"rate_limited"` only while the agent is actually halted on that prompt right now — NOT when
the same text merely sits scrolled-up in history.

**Why no deterministic regex backstop (deliberate — do NOT add one):** a regex matches the
text ANYWHERE in the viewport, so it (a) can't detect RECOVERY (the prompt scrolls up but
stays in view → would never clear) and (b) on the idle-skip/model-fail paths would re-scan
and FALSELY RE-RING after Haiku had already cleared it. Only a whole-screen classifier can
tell "live prompt" from "scrolled-up history". The alert state therefore changes ONLY when
a Haiku call SUCCEEDS + parses: `maybeSignalAlert(parsed.alert)` runs on the due path only;
idle-skip / parse-fail / model-throw branches LEAVE the alert state untouched (a held alert
stays armed, nothing rings or clears without a fresh classify).

EDGE-TRIGGERED via a per-surface `alertBySession: Map<id,tag>` on `LoopDeps` (pure
`alertEdge(prev,current)` → ring/clear/none): rings ONCE on a rising/changed edge, clears
when Haiku reports no alert (this is how recovery un-rings, immune to scrolled-up text),
re-arms after; cleaned up alongside `lastBySession` for dead surfaces; a failed
`signalAttention` rolls the record back so a later sweep retries.

**HONEST COST of pure-Haiku:** if the summarizer's OWN account is the rate-limited one, its
calls fail and the FIRST detection can't fire (a held alert still stays armed; only the
initial ring is at risk) — mitigate by routing the summarizer to a SEPARATE account (the
existing Account-routing feature; the recommended watchdog setup). Detection still lands on
the change-edge: the prompt appearing changes the screen → `shouldSummarize` returns
`changed` (beats idle-skip) → Haiku runs → rings; latency ≈ debounce + a sweep (~5–15s).

NOTE: this rate-limit watchdog is now ONE case of the general **Bell Attention v2** two-tier
promotion mechanism (see `BELL-ATTENTION.md`) — the same fail-open classify +
`set_attention`, here driven by a dedicated `alert` tag rather than a bell edge.

Wiring: sidecar ONLY — `prompts.ts` (contract + `alert` rule), `summarizer.ts`
(`ParsedSummary.alert` + `parseSummary` parse + `ALERT_RATE_LIMITED` + pure `alertEdge`),
`index.ts` (`LoopDeps.alertBySession` + `maybeSignalAlert` edge handler on the success
branch only + `alertReason` + dead-id prune + main init). Tests: `summarizer.test.ts`
(`alertEdge` + `parseSummary` alert parsing) + `index.test.ts` (`bell:` group — ring-once,
held-no-rering-under-idle-skip, recovery-clears, scrolled-up-text-inert,
model-failure-leaves-untouched, model-alert-rings-regardless-of-text, changed-tag-rerings,
failed-ring rollback, non-agent never rung, dead-id prune). **Rebuilt sidecar `dist` + a
sidecar restart (kill the node child or relaunch the GUI) is enough; no host/Zig change, no
GUI relaunch needed for the GUI itself.**

### Haiku usage / budget tracking (sidecar records, Swift MCP tool queries)

All Haiku traffic funnels through ONE chokepoint — `model.ts` `summarize()` — so usage is
captured there and tagged by the caller, covering every feature with one sink. The SDK
SUCCESS result carries `usage` (input/output/cache tokens) + `total_cost_usd` (verified
non-zero on pool auth: a cold call ~5¢, dominated by ~25.7k cache-CREATION tokens; a warm
call is cents on cache READS). Load-bearing details:

- **Capture**: `summarize()` gained an optional `onUsage` callback (model.ts), called with a
  `HaikuUsage` read off the success message BEFORE returning (never on an error result).
  model.ts's import of `HaikuUsage` is **type-only** so `dist/model.js` keeps its
  no-`node_modules` lazy-load property.
- **Tag + record**: the single `index.ts` call site passes `onUsage` that stamps
  `feature` (`bellRang ? "bell-classify" : "summarizer"`) + `account` (basename of
  `summarizerConfigDir`, else `"ambient"`) and calls `recordUsage` (usage.ts). The
  `SummarizeFn` type was widened with the same optional `onUsage`.
- **Persistence + retention**: `usage.ts` appends one JSONL line per call to
  `~/Library/Logs/ghostty-ramon-haiku-usage.jsonl` (best-effort, never throws — mirrors
  diag.ts). `trimUsageLog(14, Date.now())` runs once at sidecar startup (`main()`), dropping
  entries older than 14 days. Survives restarts because it's a file (the sidecar dies/respawns
  with the GUI; totals are cumulative).
- **Config toggle (first-class)**: the Zig bool `agent-manager-usage-tracking` (default
  **true**) gates it. `AgentManagerController.childEnvironment` forwards the resolved value to
  the sidecar EXPLICITLY both ways — `GHOSTTY_HAIKU_USAGE = "1"/"0"` — so the config wins over
  the sidecar's default-on; `usage.ts usageEnabled()` returns `GHOSTTY_HAIKU_USAGE !== "0"`
  (so a bare `"0"` disables; unset still defaults on for a manual sidecar run). A GUI relaunch
  re-spawns the sidecar with the new env. Adding the key is a Zig/lib change (rebuild
  lib+xcframework+GUI) but **GUI-relaunch only — no host restart** (the host ignores the key).
- **Query (Swift)**: the `get_haiku_usage` MCP tool (`MCPTools.dispatch`, `hours` arg
  clamped to [1 min, 30 days], default 3) calls the PURE `MCPUsage.aggregate(lines:sinceIso:)`
  which filters `ts >= sinceIso` (lexicographic — `MCPUsage.isoString` emits the SAME
  fractional-seconds `…Z` format as JS `toISOString`, so the string compare is correct) and
  sums into total + byFeature + byAccount (each cost-sorted). Pure file read, no main-thread
  hop. Added to the iOS-exclusion `membershipExceptions` in `project.pbxproj` like the other
  MCP files.

Wiring: sidecar — `agent-manager/src/usage.ts` (new), `model.ts` (`onUsage` + extraction),
`index.ts` (tag at the call site + `SummarizeFn` + startup trim). core — `Config.zig`
(`agent-manager-usage-tracking` bool, default true, + parse test). macOS —
`Ghostty.Config.swift` (`agentManagerUsageTracking` getter), `AgentManagerController.swift`
(`GHOSTTY_HAIKU_USAGE` forward), `Features/MCP/MCPUsage.swift` (new), `MCPTools.swift`
(schema + dispatch), `project.pbxproj`. Tests: `Config.zig`
(`agent-manager-usage-tracking`), `usage.test.ts`
(`formatUsageLine`/`trimUsageText`/`usageEnabled`),
`model.test.ts` (`onUsage` paths), `MCPUsageTests.swift` (aggregate/cutoff/junk/empty/ISO),
`MCPServerTests.swift` (`toolsListHasAllTools` count 22). **Rebuilt sidecar `dist` (records)
+ a GUI relaunch (the Swift tool); no host/Zig change.**

# Agent Queue — implementation notes, part 3: operational hardening

The load-bearing facts for an agent working on the Agent Queue Supervisor code (part 3 of 3):
provider-call throttling, per-scope run identity, restart-survival (+ the schedules impl), and the
cloud-hosts split (per-queue `host` → multi-host load balancing). Engine / dispatch / config / adopt
internals are in
**`AGENT-QUEUE-INTERNALS.md`**; layout / dashboard / live-controls in **`AGENT-QUEUE-INTERNALS-UI.md`**.
User-facing behavior is in **`AGENT-QUEUE.md`**. The local design + review ledger is
`scratchpad/agent-queue-design.md` (paths in the iteration worktree).

### Provider-call throttling — honor `intervals.listMs`/`statusMs`

- **PROVIDER-CALL THROTTLING — honor `intervals.listMs`/`statusMs` (the real "5s too frequent" fix).** The
  sweep stays at the 5s `QUEUE_POLL_INTERVAL_MS` base cadence (reconcile / close / command-drain / §11
  report run EVERY sweep), but PROVIDER calls are throttled to the template's `intervals` — hit at most once
  per `listMs` (`list`) and once per `statusMs` (`status`). Previously both knobs were DEAD (`fetchListResult`
  + `probeStatus` ran every sweep). Engine: two non-persisted `QueueRun.lastListAtMs`/`lastStatusAtMs` (init
  `NEGATIVE_INFINITY` ⇒ first sweep always fetches, no `now===0` collision). `dispatchCandidates` skips the
  whole list fetch+dispatch and returns 0 when `nowMs - lastListAtMs < intervals.listMs` — the §11 report
  (fired AFTER dispatch) reads the CACHED `lastListItems`/`lastListOk`, so counts stay live. The window is
  consumed on the ATTEMPT (set before the fetch), so even a FAILED list waits a full interval — a hard cap of
  one `list` per `listMs`. `advanceStates` gates the per-agent `status` probe on `statusDue = nowMs -
  lastStatusAtMs >= statusMs` (decided once per batch); when not due, `statusTerminal` stays undefined so no
  status-driven completion that sweep (idle-anchor fold + close-gate still run — completion delayed at most
  `statusMs`, never lost). The status window is consumed ONLY if a probe fired (`probed` flag), so a due
  sweep with no live SPAWNED/RUNNING agent doesn't burn the interval. ⚠️ A `set_max_items` bump / `resume`
  re-enables dispatch, but the NEW dispatch lands on the next list-DUE sweep (≤`listMs`), not the next 5s
  sweep — the dashboard cap/phase still updates INSTANTLY (optimistic + fast-confirm above); only the spawn
  waits. **Default `{listMs:60000, statusMs:30000}`.** Wiring: `runner.ts`
  (`QueueRun.lastListAtMs`/`lastStatusAtMs` + init + list gate in `dispatchCandidates` + status gate in
  `advanceStates`), `templates.ts` (`TEMPLATE_DEFAULTS.intervals` → 60000/30000). Tests: `runner.test.ts`
  (list throttled + throttled-sweep-still-reports-from-cache + status throttled + due-sweep-no-agent-doesn't-burn;
  the shared `tmpl()` fixture sets `intervals:{0,0}` = throttle-off so existing every-sweep tests are
  preserved), `templates.test.ts` (default 60000/30000). **Sidecar-only — rebuilt `dist` + sidecar respawn
  (GUI relaunch); no host/Zig/GUI-Swift change.**

### PER-SCOPE RUN IDENTITY

- **PER-SCOPE RUN IDENTITY — one template, parallel runs per project/milestone (palette shows the template
  `name`).** Three coupled changes so a generic template is re-usable in parallel for different env-param
  scopes:
  - **(1) Palette shows the template `name`, not the filename.** The picker lists each template by its JSON
    `name`, sorted by display name. The START command + `templateParams`/`templateProbe` still key off the
    BASENAME. `QueuePalette.discoverTemplates` returns `[QueueTemplateEntry]` (`basename` + `displayName`, via
    `templateDisplayName`, basename fallback); option + param-form titles use `displayName`;
    `QueueParamPrompt` gained `displayName`.
  - **(2) A run's live IDENTITY is `runName` = `template.name` + its non-empty ENV-param VALUES, " ·
    "-joined** (maxItems params excluded — tuning, not scope; e.g. "ExampleOS · Acme · v2.0"). `runName`
    REPLACES `template.name` everywhere identity flows: annotation `queueName` (dispatchOne +
    restampAnnotation), the §11 report, the `activeRunRecords` name, and the reconcile `projectLiveSurfaces`
    filter — so two scoped runs are shown + controlled independently. Pure `runDisplayName(template, values)`
    in `templates.ts`.
  - **(3) Dedup is per-SCOPE, so different scopes run IN PARALLEL (separate tabs).** `applyCommand` dedups on
    (basename + `identityScope`) where `identityScope` = `runIdentityScope(template, values)` = the resolved
    provider env (sorted `name=value`, pure). Same = idempotent no-op; DIFFERENT = a second run keyed by its
    `runName`. The per-run STATE FILE gets a scope-hash suffix (`<basename>.<slug>.state.json` via
    `scopeSlug(runIdentityScope(...))`); rehydration recomputes the same path. Separate tabs are automatic —
    each run starts empty so its first `splitPlan` returns `firstTab`.
  - **(3a) State-file MIGRATION across the rename (bug fix).** The scope-suffix renamed the state file
    (`example.state.json` → `example.<slug>.state.json`), so a run IN FLIGHT across the upgrade rehydrated
    under the NEW path, found no file, and **reset `lifetimeDispatched` to 0** (also lost the live maxItems
    edit + re-adopted agents as orphans). Fix: `rehydrateActiveRuns` RENAMES a surviving bare
    `<basename>.state.json` to the scoped path (pure `shouldMigrateLegacyState(scoped, legacy, scopedExists,
    legacyExists)` — migrate only when scoped absent, legacy exists, paths differ; best-effort). Done ONLY on
    rehydrate — a FRESH `start` must NOT adopt a stale bare file. Wiring: `wiring.ts`; test: `wiring.test.ts`
    (`shouldMigrateLegacyState`).
  - **(3b) REHYDRATION must key the registry by `runName`, NOT `template.name` (bug fix).** The `start` path
    keys by `run.runName`, but `index.ts` populated a RESTORED run with `registry.set(run.template.name, run)`
    — so a scoped run was keyed by the bare name while control commands target its `runName`, giving
    `registry.get(cmd.run)`→undefined → silent "unknown run" no-op (the "maxItems does nothing after restart"
    bug), and two parallel scoped runs COLLIDE. Fix: a shared `registerRehydratedRuns(registry, runs)` in
    `commands.ts` keys by `run.runName`; `index.ts` calls it. Tests: `commands.test.ts` (keyed-by-runName +
    `set_max_items` resolves after rehydrate + two parallel scoped runs coexist).
  `makeQueueRun` computes `runName`/`identityScope` from (template + params); a `runName` collision from a
  DIFFERENT identity is rejected (no clobber). Wiring: sidecar `templates.ts`
  (`runDisplayName`/`runIdentityScope`/`scopeSlug`), `runner.ts` (`QueueRun.runName`/`.identityScope` +
  identity usages), `commands.ts` (scope-aware dedup + key-by-`runName`), `wiring.ts` (`runStatePath`
  scope-suffixed state file, factory + rehydrate); macOS `QueuePalette.swift` (`QueueTemplateEntry` +
  `templateDisplayName` + `discoverTemplates` return type + `QueueParamPrompt.displayName` + option/form
  titles). Tests: sidecar `templates.test.ts` (`runDisplayName`/`runIdentityScope`/`scopeSlug`),
  `commands.test.ts` (parallel different-scope start + same-scope no-op + factory-consulted-on-restart); Swift
  `QueuePaletteTests` (`discoverUsesJSONNameForDisplayAndSort`, `templateDisplayNameFallsBackToBasename`).
  **GUI relaunch + rebuilt sidecar `dist`; no host/Zig change.**

### Restart-survival hardening

- **RESTART-SURVIVAL HARDENING.** A started run + its in-flight items survive a sidecar/GUI restart without
  the queue vanishing or its splits detaching. (Removing `quitWhenEmpty` is part of this: a transient
  SUCCESSFUL-but-INCOMPLETE post-restart `list_surfaces` must not self-remove a live run.) Two sidecar-only
  safeguards:
  - **(A) PREMATURE-PRUNE FIX — reconcile-start grace.** `reconcile` takes an optional `reconcileStartedMs`
    (default `-Infinity` = no grace); a finalized record's session-gone prune is shielded for `pendingGraceMs`
    (30s) after the LATER of its `sinceMs` AND the run's first reconcile in the current process
    (`run.reconcileStartedMs`, stamped once per process; a restart re-stamps). So a long-lived RUNNING record
    survives a transient/incomplete post-restart list for a full grace window. Conservative — can only DELAY a
    prune, never cause a duplicate. Wiring: `store.ts reconcile` (param + `Math.max(sinceMs,
    reconcileStartedMs)` gate), `runner.ts` (`QueueRun.reconcileStartedMs` stamp). Tests: `store.test.ts`
    (shield within grace / prune past grace / default-arg = no-grace).
  - **(B) PERSISTENT SIDECAR LOG.** The Swift controller pipes the sidecar's stdout to an UNREAD pipe +
    stderr to `nullDevice`, so the engine's logs had no durable trail. `src/logfile.ts` tees
    `console.{log,info,warn,error}` to a ROTATING file `~/Library/Logs/ghostty-ramon-agent-manager.log`
    (append, rotate at ~5MB → `.1`); best-effort (any fs error falls back to console, never throws);
    installed first thing in `index.ts main()`. Pure `formatLogLine`/`defaultLogPath` unit-tested
    (`logfile.test.ts`). **Sidecar-only — rebuilt `dist` + sidecar restart; no host/Zig/GUI-Swift change.**

- **Schedules (recurring scan agents).** A per-queue array of cron-scheduled scan agents (user doc:
  `AGENT-QUEUE.md` → "Schedules"). NO config key + NO new MCP tool + NO Zig/host change — GUI relaunch +
  rebuilt sidecar `dist`. Cadence is PURE (`queue/schedule.ts`): a vendored 5-field cron parser
  (`parseCron`/`nextAfter`/`prevBefore`, LOCAL time) + `computeNextStart(cron, state)` implementing the
  completion-anchored **half-of-local-gap skip, CAPPED at 12h** (`A > C + min((A − prevFiring)/2,
  MAX_SKIP_REST_MS=12h)`, strictly greater; never-ran uses the arm anchor with NO skip). The cap stops a
  weekend-inflated cron gap (Fri→Mon = 72h ⇒ uncapped half 36h) from cancelling a firing a completion already
  cleared by ≥12h; short cadences are unaffected. `nextRunAt` in the report is this post-skip value, so the
  dashboard "next in …" never shows a to-be-skipped firing. `scheduleSweep` (`runner.ts`, called every sweep
  from `runOne`) arms/prunes cadence state, tracks liveness via **two signals** (the `scheduleId` annotation
  echoed by `list_surfaces` OR the persisted `activeSessionID` matched against live surfaces —
  `liveSurfaceFor(id)`), detects completion only when gone by BOTH (→ `lastCompletionAt = now`,
  `activeSessionID = undefined`), re-adopts a live scan after restart, auto-closes an EXITED split (when
  `closeOnComplete`), and dispatches a due/run-now schedule via `dispatchSchedule` (grid-packed). The prose
  reaches the agent as `GHOSTTY_SCHEDULE_PROMPT` (+ a single-quoted command PREFIX for the pty-host backend,
  like `GHOSTTY_ITEM_*`), ALONGSIDE `GHOSTTY_SCHEDULE_ID`/`_NAME` and the run's resolved param env
  (`resolveParamsEnv` — scoping the scan to the run's project/milestone); the agent's `command`/launcher
  CONSUMES it (`claude "$GHOSTTY_SCHEDULE_PROMPT"`) rather than us typing it (a fresh raw-mode TUI drops
  pre-first-input typing). Dispatch BYPASSES concurrency/maxItems/max-total caps (NOT in `run.active`) but
  still packs the grid. **Grid-slot placement is shared:** `gridOccupancy(run)` merges `run.active` +
  `run.scheduleActive` into one `{occupied, slotUUID}` view used by `dispatchOne`, `dispatchSchedule`, AND
  `packRun` — so a work item can't land on a schedule's slot and over-crowd its tab past `cols*rows` (the
  2026-07-03 "7th split in a full 3×2 tab" regression; `dispatchOne` used to scan only `run.active`).
  `dispatchOne`'s slot search is widened by `run.scheduleActive.size`; the restart **re-adopt** branch
  RESERVES the lowest free slot for a survivor (was `gridSlot -1` = invisible to occupancy, the other half of
  the regression). A scheduled split carries a `queueName` + `schedule`/`scheduleId` annotation but **no
  `queueKey`**, so the work-item `reconcile` leaves it alone. Single-flight is structural (`run.scheduleActive`,
  keyed by schedule id, rebuilt each sweep via `liveSurfaceFor`). Cadence + pause persist
  (`StoreFile.schedules`, `{armedAt, lastCompletionAt?, paused?, activeSessionID?}`) + rehydrate. **Restart
  re-adoption fix:** a GUI restart wipes the in-memory annotation, so a still-open scan returns with no
  `scheduleId` → naively read as completed → re-anchor + duplicate risk. So `dispatchSchedule` persists the
  spawn's stable host `sessionID` in `ScheduleState.activeSessionID` (backfilled each sweep since a fresh
  spawn's id attaches asynchronously), and `scheduleSweep` re-adopts by matching it, then **re-stamps the
  wiped annotation** (`setAnnotation` `queueName`/`schedule`/`scheduleId`); cleared on real completion. **⚠️
  Wire contract (both sides must match — the `coerceQueueCommands` lesson):** template
  `schedules[]` is a validation chokepoint (`templates.ts validateSchedules` whitelists the fields + parses
  the cron; the loader resolves `promptFile`→`prompt`); commands
  `pause_schedule`/`resume_schedule`/`run_schedule_now`/`pause_all_schedules` carrying `{run, scheduleId?}`
  are in `coerceQueueCommands` `QUEUE_ACTIONS` (mcp.ts) — omission SILENTLY DROPS them; `list_surfaces` emits
  `scheduleId` (the reconcile-visibility chokepoint, `MCPLayout.surfacesJSONData`); the status report carries
  a `schedules[]` array (`{id,name,paused,running,nextRunAt?,lastCompletionAt?}`) for the dashboard lane.
  Wiring: sidecar `queue/schedule.ts` (NEW), `queue/types.ts` (`ScheduleSpec` + `QueueTemplate.schedules`),
  `queue/templates.ts` (`validateSchedules` + promptFile), `queue/store.ts` (`StoreFile.schedules`),
  `queue/runner.ts` (`scheduleSweep`/`dispatchSchedule` + `persistRun` + rehydrate), `queue/commands.ts` (4
  actions + `scheduleId`), `queue/status.ts` (`ScheduleStatus`), `mcp.ts` (`coerceQueueCommands` +
  `scheduleId` + report wire); macOS `MCPAnnotation.swift`/`AgentStateBridge.swift`
  (`queueSchedule`/`scheduleId`), `MCPTools.swift`, `MCPLayout.swift` (`SurfaceRow.scheduleId`),
  `AgentDashboardController.swift` (`pauseSchedule`/`resumeSchedule`/`runScheduleNow`/`pauseAllSchedules`),
  `QueueCommandBridge.swift` (4 `Action` cases + `QueueStatus.ScheduleStatus`), `AgentPreviewTile.swift` (teal
  glyph), `AgentDashboardView.swift` (Schedules lane). Tests: sidecar `schedule.test.ts` (cron + skip
  matrix), `templates.test.ts`, `store.test.ts` (`activeSessionID` round-trip), `commands.test.ts` (4
  actions), `runner.test.ts` (dispatch / single-flight / completion / auto-close / **restart
  re-adopt-by-sessionID + re-stamp**), `mcp.test.ts`, `status.test.ts`; Swift `MCPAnnotationTests`,
  `MCPServerTests` (`scheduleId` emit), `QueuePaletteTests`.

### Per-queue `host` — provider-laptop / agent-cloud split (cloud-hosts Phase 4, user doc: "Running a queue's agents on a remote host")

- **`host` / `agentWorkdir` / `remoteTemplateDir` on the template** (`queue/types.ts` `QueueTemplate`,
  all OPTIONAL; `host` defaults `"local"` at every read via `?? "local"`). ⚠️ `validateTemplate`
  (`queue/templates.ts`) MUST whitelist all three or the loader silently drops them (the
  `validateProviderList`/`coerceQueueCommands` lesson) — `host` via
  `optNonEmptyStringOrDefault(rec.host, "local", …)`, `agentWorkdir`/`remoteTemplateDir` via
  `optNonEmptyString` (host-relative absolute paths, NOT `~`-expanded).
- **Provider stays laptop-side; only the agent split is remoted.** `dispatchOne`/`dispatchSchedule`
  compute `isRemote = t.host !== "local"` and, when remote, use `agentWorkdir` (else `workdir`) for
  the agent split's `cwd`, `remoteTemplateDir` (else `run.templateDir`) for `GHOSTTY_QUEUE_TEMPLATE_DIR`,
  and pass `host: t.host` to `spawnSplitCommand`. `queueProviderEnv` / the provider `cwd` are UNCHANGED.
- **`{templateDir}` DIVERGENCE (O2).** `substituteTemplateDir(t, providerDir, agentDir = providerDir)`
  takes TWO dirs: the four provider/param sites substitute `providerDir` (the LAPTOP `dirname(path)`),
  `agent.command` substitutes `agentDir`. `wiring.ts loadTemplateAtPath` passes `agentDir =
  remoteTemplateDir` iff `isRemote` (else the laptop dir — byte-identical to before).
- **`host` reaches the GUI as `spawn_split_command`'s optional `host` arg — NO new tool, count STAYS
  26.** `McpClient.spawnSplitCommand` (`mcp.ts`) carries `host` only when non-empty + non-`"local"`.
  `MCPTools.swift` adds the `host` schema; `MCPLayout.newSplitCommand` gains `host:` + the pure
  `resolveHostSpawn` (nil/`"local"` ⇒ local; a registry name ⇒ `.remote(name)` sets `config.hostName`;
  an UNKNOWN name ⇒ `.unresolvable`, spawn FAILS — never a local fallback, D4). A remote spawn mints a
  nonce + `export GHOSTTY_SURFACE_NONCE=…` `initial_input` prefix + registers `RemoteAgentIdentity`
  (D6 — see `AGENT-DASHBOARD.md` / `MCP-SERVER.md`).
- **Cross-host identity — the `(host, sessionID)` PAIR (Q2/Q3, OQ8).** The wire `Surface.sessionID` is
  the COMPOSITE STRING `"<host>:<id>"` (`MCPLayout.surfacesJSONData`); the sidecar parses it with
  `parseSessionKey` and keys on `sessionKey(host, id)` (`queue/types.ts`) in BOTH `reconcile`'s
  `liveBySession`/`claimedSessions` (`queue/store.ts`) and `scheduleSweep`'s `bySession` re-adopt
  (`queue/runner.ts`) — so two boxes can each mint session id 5 without a false match, and a schedule
  re-adopts THIS box's scan. `Assignment.hostName` + `ScheduleState.hostName` persist the DISPATCH host
  (from `template.host`, NOT the numeric spawn reply); `store.ts` keeps them only when non-`"local"` so
  a local record serializes byte-identically (a pre-migration record with no `hostName` reads back as
  `"local"`). Tests: `types.test.ts` (`parseSessionKey`/`sessionKey` incl. legacy bare number → local),
  `store.test.ts` (two-host-same-id no false match + local back-compat), `runner.test.ts` (remote
  work-item dispatch host/cwd/templateDir + remote schedule pair-keyed re-adopt vs local decoy + local
  no-host byte-identical), `templates.test.ts` (two-dir substitute), Zig
  `pty-remote-project-directory parse`. **GUI relaunch + lib/xcframework + rebuilt sidecar `dist`; the
  Linux `/proc` arm needs a Linux `ghostty-host` rebuild for cloud-agent NAMES (macOS host untouched).**

### Multi-host load balancing — a weighted host POOL (cloud-hosts Phase 5)

The scalar `host` becomes an OPTIONAL weighted **`hosts[]`** pool, and the supervisor spreads a queue's
agents across it by **weighted-least-loaded** placement. **Sidecar + GUI-lib only — NO host / protocol /
wire change:** placement is chosen from the ALREADY-persisted per-agent host (`Assignment.hostName`, Phase 4)
and delivered through the EXISTING `spawn_split_command` `host` arg; the only new wire field is an ADDITIVE
`hosts[]` array on the already-forwarded `report_queue_status`.

- **The pure selector** lives in `queue/hostpool.ts` (NEW): `HostSpec {name, weight?, maxConcurrent,
  maxItems?}` + `HostLoad {active, lifetime}` + `normalizeHostPool(t)` (scalar/omitted `host` → a single
  `+Infinity`-cap entry; `hosts[]` → those entries, weight defaulted to 1) + `selectHost(pool, load,
  {exclude?})` → `argmin(active / (maxConcurrent × weight))` over free-slot candidates, STRICT `<` tie-break
  in DECLARATION ORDER (a function of ONLY pool order + the load map — so a post-restart sweep re-derives
  identical placements, **no persisted cursor**). A `+Infinity`-cap entry (scalar back-compat) scores 0 and
  always wins its singleton. `null` ⇒ no host has a free slot ⇒ the item WAITS. `maxItems` per-host is honored
  by the selector (forward-compat) but the runner passes `lifetime = 0` in v1 (**v1 = concurrency-only**;
  per-host lifetime needs a persisted counter, deferred to v1.1).
- **Fleet-wide occupancy** — `totalActiveOnHostRegistry(registry): Map<string, HostLoad>` (`runner.ts`,
  modeled on `totalHeroActiveRegistry`) folds EVERY run's `active` (`occupiesSlot`) + `scheduleActive` by
  `hostName ?? "local"` (every physical pane). Seeded ONCE per sweep into a mutable `hostActive` map +
  INCREMENTED at each synchronous seat (`bumpHostLoad`), so **within-sweep greedy** placement (dispatch N sees
  N−1) never overshoots `maxConcurrent`.
- **dispatchOne (the sibling PLACEMENT gate, AFTER the count gates):**
  `selectHost(normalizeHostPool(t), hostActive, {exclude: activeHostCooldown(run, now)})` replaces
  `templateHost = t.host`; `null` ⇒ return false BEFORE any seat/latch/counter mutation (mirrors the `slot ===
  null` early return), so a full pool never over-burns `maxItems` or double-dispatches. The chosen host flows
  to the record (`hostName`) + the spawn `host` arg.
- **Down-host degrade (the #1 risk — a DOWN box looks emptiest to least-loaded):** on a spawn THROW,
  `dispatchOne`'s rollback also `unbumpHostLoad`s + puts the host on a bounded **`run.hostCooldown`**
  (`DEFAULT_HOST_COOLDOWN_MS` ≈2 min; `selectHost` excludes cooling hosts), so the item fails OVER next sweep.
  A remote deferred-dial to a down box "succeeds" with session-0 → the `no-pty-host` reconcile prune is now
  **host-scoped** (`runOne`): a `local` session-0 still self-disables the whole run (§2), but a REMOTE one
  cools the host + releases the burned slot + frees the item WITHOUT disabling the run.
- **`hostCapacity` attribution (`status.ts`, the gate↔attribution mirror):** a new `"hostCapacity"`
  `BlockReason`, pushed by `blockReasonsFor` ONLY when the item cleared its OTHER pool gates (nothing else
  pushed) AND `anyHostHasFreeSlot === false`. `reportQueueStatus` feeds `anyHostHasFreeSlot` from the SAME
  `selectHost` + `totalActiveOnHostRegistry` the dispatcher uses (so the mirror can't drift) + a per-host
  `hosts[]` (`{name, active, maxConcurrent|null}`) echoed to the report and forwarded in `mcp.ts`.
- **Heroes + schedules** pick a host by the SAME `selectHost` (both count against `maxConcurrent`); a hero's
  promotion never re-places (never blocks), and a schedule DEFERS a sweep (no block reason) when every host is
  full.
- **Back-compat:** a scalar/local queue normalizes to one `+Infinity`-cap entry → `selectHost` always returns
  it, `anyHostHasFreeSlot` always true, no `host` arg — byte-identical. `hosts[]` is whitelisted in
  `validateTemplate` via the new pure `validateHostPool` (name req, `maxConcurrent` positive int, `weight >
  0`, `maxItems` positive int, name-dedup) — omission would silently drop the pool (the
  `validateProviderList`/`coerceQueueCommands` chokepoint lesson).

Wiring: `queue/hostpool.ts` (NEW: `HostSpec`/`HostLoad`/`normalizeHostPool`/`selectHost`), `queue/types.ts`
(`QueueTemplate.hosts?` + `"hostCapacity"` BlockReason), `queue/templates.ts` (`validateHostPool`),
`queue/runner.ts` (`totalActiveOnHostRegistry`/`bumpHostLoad`/`unbumpHostLoad`/`activeHostCooldown` +
`run.hostCooldown` + `hostActive` threading + dispatchOne/dispatchSchedule selectHost + host-scoped
no-pty-host prune), `queue/status.ts` (`HostStatus` + `anyHostHasFreeSlot` + `hostCapacity` push), `mcp.ts`
(`report_queue_status` `hosts`). Tests: `queue/hostpool.test.ts` (NEW — weighting / cap-skip / all-full→null /
greedy / tie-break determinism / scalar back-compat / cooldown-skip / maxItems-exhaustion),
`queue/templates.test.ts` (`validateHostPool`), `queue/status.test.ts` (`hostCapacity` + `hosts` echo),
`queue/runner.test.ts` (greedy spread / full-pool WAIT / fleet-wide cap across two queues / down-host
fail-over + cooldown / remote session-0 cools + no self-disable / local session-0 self-disables / scalar
byte-identical / `totalActiveOnHostRegistry` fold), `mcp.test.ts`. Full design: **`CLOUD-QUEUE-BALANCING.md`**.

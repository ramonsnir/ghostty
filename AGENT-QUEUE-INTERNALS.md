# Agent Queue — implementation notes, part 1: engine, dispatch, config & adopt

The load-bearing facts for an agent working on the Agent Queue Supervisor code (part 1 of 3).
User-facing behavior is in **`AGENT-QUEUE.md`**; layout / dashboard / live-controls internals are in
**`AGENT-QUEUE-INTERNALS-UI.md`**; operational hardening (throttling, run identity, restart, multi-host) in
**`AGENT-QUEUE-INTERNALS-OPS.md`**. The local design + review ledger is `scratchpad/agent-queue-design.md`
(paths in the iteration worktree).

### Command latency: push-wake + parallel status probes (why adopt/promote used to feel slow)

A dashboard command (adopt / promote / demote / release / set_keep / pause / stop / …) is DELIVERED
by polling, not push: the GUI appends it to a FIFO drained by the MCP `take_queue_commands` tool at
the START of a supervisor sweep. Three fixes cut the felt 30–90s delay:

1. **Push-wake (was: up to a full in-flight sweep + the 5s poll gap).** The queue loop
   (`index.ts queueTick`) is self-paced (`QUEUE_POLL_INTERVAL_MS = 5000`, armed after a sweep
   settles) and a command is only drained at a sweep's start. FIX: a **queue-command push-wake**
   mirroring the bell-reactive loop. A surface-less `MCPEventBus.EventType.queueCommand` (wire value
   `queue_command`, sentinel id `queueCommandSentinelID`) is emitted by
   `MCPServer.enqueueQueueCommand` AFTER the FIFO append (`bus.recordQueueCommand()`); the sidecar's
   `queueReactiveLoop` long-polls `wait_for_event(types:["queue_command"])` and fires a **detached,
   coalesced** sweep so a command drains in ~1 round-trip. `queueTick` and the reactive loop share
   ONE `makeCoalescedRunner(runQueueSweepSafe)` so timer and wake never overlap (both mutate the run
   store) — a mid-sweep trigger just sets the coalescer's re-run flag. The 5s timer stays as the
   BACKSTOP; the server's 0.5s event-ring coalesce catches a command enqueued in the sliver between
   the old waiter resolving and the loop re-parking. Gated on a configured queue + `wait_for_event`;
   NEVER exits on error (fail-open, re-arms after a short backoff). The tool's type whitelist
   (`MCPTools.dispatch` `knownTypes` + the schema enum) gained `queue_command`.
   **⚠️ ANTI-SPIN (fixed 2026-07-03).** That 0.5s event-ring coalesce could turn the reactive loop
   into an event STORM: `MCPEventBus.register` resolves a `wait_for_event` IMMEDIATELY if a matching
   event is within the 0.5s window, and the loop re-parks with no await — so ONE `recordQueueCommand`
   re-resolved the re-parks hundreds of times/sec (~471 wakes/sec observed), saturating the MCP
   serial queue until other tool calls timed out at 15s → the GUI BEACHBALLED. (The bell loop is
   immune: its slow Haiku classify spaces re-parks past the window.) Surfaced when a **Schedule**
   run-now landed during a spin. FIX: the loop sleeps `QUEUE_REACTIVE_MIN_INTERVAL_MS` (750ms, > the
   0.5s window) after each wake before re-parking, so the consumed event ages out. A command landing
   during the sleep is drained ≤750ms later (FIFO holds it + 5s backstop). Wiring: `index.ts`.

2. **Parallel provider `status` probes.** `advanceStates` probed each active agent's `status`
   one-`await`-at-a-time; each is bounded by `DEFAULT_PROVIDER_TIMEOUT_MS` (5s), so N agents made one
   sweep ~N×5s. FIX: due probes for a run fire CONCURRENTLY via `Promise.all` (into a `statusByKey`
   map); the anchor-fold + `nextState` stamping stay SEQUENTIAL over the same `activeList` (they
   mutate `run`) — only the I/O is parallelized, so ordering/determinism and throttle/window-burn
   semantics (`probed`, `statusDue`, no-live-agent-doesn't-burn) are unchanged. A per-probe rejection
   guard keeps one throw from failing the batch (`probeStatus` swallows exec failures → `{terminal:false}`).

3. **Adopt fold-in is SAME-SWEEP.** `runAdopt` runs BEFORE `list_surfaces` in a sweep, but the
   queueKey/queueName annotation used to reach the dashboard model via TWO async main-thread hops
   (`set_surface_annotation` posted via `main.async` + a Combine `receive(on: main)` sink), landing a
   main-thread turn AFTER the same-sweep `list_surfaces` snapshot → fold-in waited for a later sweep.
   FIX: deliver the annotation SYNCHRONOUSLY on main — `MCPServer.applyAnnotation` posts the
   notification INSIDE its `main.sync` block, and `subscribeAnnotation` DROPS `receive(on: main)` so
   the observer's `model.applyAnnotation` runs inline with the post. The `await`ed
   `set_surface_annotation` now returns only after the model holds the tag, so the SAME sweep's
   `list_surfaces`/`hookSnapshot()` sees it. INVARIANT: this notification is posted ONLY by
   `applyAnnotation` (always on main); do NOT post it off-main. (Promote had no such round — its
   hero-pool accounting is authoritative in the in-memory `run.hero` set, settled same-sweep.)

Wiring: `MCPEventBus.swift` (`queueCommand` type + `queueCommandSentinelID` + `recordQueueCommand`),
`MCPQueueCommands.swift` (`enqueueQueueCommand` fires the wake), `MCPTools.swift` (`queue_command`
whitelist + schema), `macos/agent-manager/src/index.ts` (`QUEUE_WAIT_MS`/`QUEUE_WAIT_RETRY_MS` +
`runQueueSweepCoalesced` + `queueReactiveLoop` + arm), `queue/runner.ts` (`advanceStates` parallel
batch), `MCPAnnotation.swift` (`applyAnnotation` synchronous `main.sync` post),
`AgentDashboardController.swift` (`subscribeAnnotation` drops `receive(on:)`). Tests:
`runner.test.ts` (`advanceStates … CONCURRENTLY`), `MCPServerTests.swift`
(`dispatchWaitForEventQueueCommandType`, `dispatchWaitForEventUnknownTypeRejected`,
`queueCommandEventTypeWireValueAndSentinel`). **GUI relaunch + rebuilt sidecar `dist`; no Zig/lib/host
change** (pure Swift + TS).

### `agent-queue-max-total` — optional fleet cap, default 0 = UNLIMITED (and the getter bug)

- **`agent-queue-max-total` defaults to `0` = UNLIMITED** (was `8`) — an OPTIONAL fleet-wide ceiling
  across ALL runs; unset/`0` means a queue is bounded only by its own `concurrency`/`maxItems`/grid.
  Threading: `Config.zig` (`u32 = 0`) → `Ghostty.Config.swift agentQueueMaxTotal` getter →
  `AgentManagerController.applyAgentQueueEnv` forwards `GHOSTTY_AGENT_QUEUE_MAX_TOTAL` (decimal,
  `"0"` when unlimited) → `index.ts` `parsePositiveInt(env, 0) || Infinity` → `QueueDeps.maxTotal`
  (`Infinity` ⇒ `globalRemaining` is `Infinity`; `ConcurrencyBudget(Infinity)` always grants).
- **⚠️ GETTER BUG (fixed 2026-06-29) — the value was NEVER read.** The Swift getter declared
  `var v: UInt32?` and passed `&v` to `ghostty_config_get`. The C side writes the raw u32 bytes but
  knows nothing about Swift's Optional tag, so `v` always read back `nil` and the getter ALWAYS
  returned its hardcoded `defaultValue` (8) — the global cap was permanently pinned at 8, ignoring
  the config file AND any per-queue `concurrency` above 8. Fix: a NON-optional `var v: UInt32 =
  defaultValue` + `_ = ghostty_config_get(...)`. **Any new numeric config getter MUST use a
  non-optional var for the same reason.**
- Wiring: `Config.zig` (field default + doc + `agent-queue: parse and default` test),
  `Ghostty.Config.swift` (`agentQueueMaxTotal`), `index.ts` (`0`/absent ⇒ `Infinity`). Tests:
  `runner.test.ts` (`maxTotal = Infinity … imposes no fleet cap`). **GUI relaunch + rebuilt
  lib/xcframework (Zig default changed) + rebuilt sidecar `dist`; no host restart.**

### Shared templates — search-list `agent-queue-templates-dir` + `{templateDir}` (user doc: "Sharing queue templates across a repo")

- **`agent-queue-templates-dir` became a `RepeatableString` search LIST** (was scalar
  `?[:0]const u8`), modeled on `project-directory`. No new C plumbing: reuses the
  `ghostty_config_string_list_s` bridge (`RepeatableString.list_c`), so the macOS getter is a
  string-list read like `projectDirectories`.
- **Search path is GUI-authoritative** (§1 of `SHARED-QUEUES-SPEC.md`). macOS computes `[default] +
  configured`, `expandingTildeInPath` + `standardizingPath` each, drops empties, dedups by
  standardized path (order-preserving). ONE implementation, not two "kept-in-sync" copies:
  `AgentManagerController.effectiveTemplateSearchPath(configured:defaultDir:)` is authoritative, and
  `QueuePaletteView.effectiveSearchDirs(configured:)` DELEGATES to it (guarded by the differential
  test `effectiveSearchDirsMatchesControllerTwin`). The default-dir constant is mirrored as
  `AgentManagerController.defaultTemplatesDir` / `QueuePaletteView.defaultTemplatesDir` and must match
  the sidecar's `defaultTemplatesDir()`.
- **GUI→sidecar env is the PLURAL `GHOSTTY_AGENT_QUEUE_TEMPLATES_DIRS`** = the full search path,
  tilde-expanded macOS-side, newline-joined. The legacy singular `GHOSTTY_AGENT_QUEUE_TEMPLATES_DIR`
  is STRIPPED when enabled and both stripped when disabled. `parseTemplatesDirs(env)` splits the
  plural on `"\n"` (drops blanks), falls back to the singular as a one-element list, else
  `[defaultTemplatesDir()]`; consumes the list VERBATIM (does NOT re-canonicalize — the GUI already deduped).
- **First-wins basename resolution.** `resolveTemplatePath(searchPath, basename)` returns the first
  `join(dir, basename+".json")` that exists; the palette's `discoverTemplates(dirs:)` merges per-dir
  results by basename with first-in-order wins, tags each kept entry's `sourceDir`, and flags
  `hasDuplicate` (drives the "· from <dir>" badge). Per-dir `discoverTemplates(dir:)` unchanged;
  params/probe resolve against `entry.sourceDir`.
- **`{templateDir}` substitution** is a PURE TS helper `substituteTemplateDir(t, dir)` in
  `queue/templates.ts` (`TEMPLATE_DIR_TOKEN = "{templateDir}"`), a **substring** replace (all
  occurrences) in the five contract sites (`provider.list`/`status`/`graph.command`, `agent.command`,
  param `valuesCommand`) — **NOT** `provider.claim.command` (deliberate). Runs in
  `loadTemplateAtPath(path)` AFTER load/validate + `workdir` `~`-expansion, with `dir = dirname(path)`
  (no trailing slash). `loadTemplateByName(searchPath, basename)` is a `resolveTemplatePath` →
  `loadTemplateAtPath` wrapper.
- **`GHOSTTY_QUEUE_TEMPLATE_DIR` env** rides `run.templateDir` (= `dirname(run.templatePath)`, set by
  `makeQueueRun`; `""` for test runs → key omitted). Provider exec: `queueProviderEnv(run)` overlays
  it onto `resolveParamsEnv(...)` at ALL FIVE exec sites (the status-probe batch is a `const env`
  binding, enumerated explicitly). Agent split: injected on BOTH delivery paths — the `env` field
  (`.exec`) AND a `GHOSTTY_QUEUE_TEMPLATE_DIR=<quoted> ` command prefix (`.client`, whose spawn `env`
  is dropped — same dual-delivery as `GHOSTTY_ITEM_*`), via `shellSingleQuote`.
- **Palette exec-path parity (the SECOND exec path).** The start-form's live `list` PREVIEW and each
  `valuesCommand` SUGGESTION probe run provider argv GUI-side (`QueueParamProber` →
  `QueueProviderProbe.run`), independent of the sidecar loader, so the palette substitutes
  `{templateDir}` and exports `GHOSTTY_QUEUE_TEMPLATE_DIR` ITSELF (else a shared-repo template's
  sibling-script preview/suggestions silently break though the real run works).
  `QueuePaletteView.substituteTemplateDir(_:dir:)` (pure, mirrors the TS substring semantics) is
  applied to `templateProbe`'s `list.command` and `templateParams`' `valuesCommand`, using the SAME
  resolved dir (`expandingTildeInPath` of `entry.sourceDir`) threaded via
  `QueueTemplateProbe.templateDir` / `QueueParamPrompt.templateDir` into `QueueParamProber`.
- **Rehydration determinism.** `ActiveRunRecord.templatePath?` persists the RESOLVED abs path;
  `activeRunRecords` writes it (omitted when empty), `parseActiveRuns` carries it (non-empty only),
  `serializeActiveRuns` round-trips it. `rehydrateActiveRuns` prefers `rec.templatePath` when it still
  exists (so a later-added shadowing dir cannot re-point a running queue), else falls back to
  first-wins `resolveTemplatePath`, else drops the run.
- **State stays out of shared repos.** `defaultStateDir()` is hardcoded to `~/.config/…/queues/.state`,
  INDEPENDENT of the templates search path (a hygiene invariant, no code change).
- Wiring: core `src/config/Config.zig` (`@"agent-queue-templates-dir": RepeatableString`); macOS
  `Ghostty.Config.swift` (`agentQueueTemplatesDirs`), `MCPKnowledge.swift` (joins the list for
  `get_effective_config`), `AgentManagerController.swift` (`effectiveTemplateSearchPath` +
  `defaultTemplatesDir` + plural-env emit/strip in `applyAgentQueueEnv`), `QueuePalette.swift`
  (`effectiveSearchDirs` + multi-dir `discoverTemplates` + `QueueTemplateEntry.sourceDir`/`hasDuplicate`
  + `substituteTemplateDir`/`templateDirToken` + `QueueTemplateProbe.templateDir`/
  `QueueParamPrompt.templateDir` + `QueueParamProber` overlay), `TerminalView.swift`; sidecar
  `queue/templates.ts` (`TEMPLATE_DIR_TOKEN`/`substituteTemplateDir`), `queue/wiring.ts`
  (`parseTemplatesDirs`/`resolveTemplatePath`/`loadTemplateAtPath` +
  `makeFileRunFactory`/`rehydrateActiveRuns` take a `searchPath`), `queue/runner.ts`, `queue/store.ts`
  (`ActiveRunRecord.templatePath`), `index.ts`. Tests: Zig `agent-queue-templates-dir: RepeatableString
  parse`; sidecar `templates.test.ts` (substitute sites + claim-not-touched + `{key}` untouched),
  `wiring.test.ts` (first-wins + path threading + rehydrate determinism), `store.test.ts`,
  `runner.test.ts` (`GHOSTTY_QUEUE_TEMPLATE_DIR` in provider + agent env + prefix); Swift
  `QueuePaletteTests.swift` (`discoverTemplates(dirs:)` first-wins + `hasDuplicate`/`sourceDir` +
  `effectiveSearchDirs` + `substituteTemplateDir`), `AgentManagerControllerTests.swift`
  (`GHOSTTY_AGENT_QUEUE_TEMPLATES_DIRS` build/dedup + legacy/disabled strip). **GUI relaunch + rebuilt
  lib/xcframework (Zig field changed) + rebuilt sidecar `dist`; no host restart / no protocol / C-API change.**

### `agent-queue-hero-max` + the HERO pool (concurrency cap off the grid, `maxItems` shared)

- **`agent-queue-hero-max` (`u32`, default `2`, fork-only) is the fleet-wide CONCURRENCY cap** on live
  HERO agents across ALL runs. Heroes run OFF the grid — no per-queue `concurrency` slot, not counted
  against `agent-queue-max-total`. **⚠️ NOTE the inversion vs `max-total`:** `0` here means hero
  concurrency **DISABLED** (hero-marked items wait on the `heroSlots` gate), whereas
  `agent-queue-max-total = 0` means UNLIMITED. **`maxItems` is NOT bypassed — it caps heroes too.**
  Threading: `Config.zig` (`u32 = 2` + doc + parse test) → `Ghostty.Config.swift agentQueueHeroMax`
  (**non-optional read**, like the `agentQueueMaxTotal` getter-bug fix) →
  `AgentManagerController.applyAgentQueueEnv` forwards `GHOSTTY_AGENT_QUEUE_HERO_MAX` → `index.ts` →
  `QueueDeps.heroMax`.
- **Two-pool accounting, ONE shared lifetime counter (`runner.ts`/`supervisor.ts`).**
  `dispatchCandidates` → `selectCandidates` splits the actionable list by `item.hero`. The regular pool
  is gated by `remainingSlots(effConcurrency, activeRegular, globalRegularRemaining)` (counting ONLY
  non-hero actives for concurrency) PLUS the `maxItems` budget. The hero pool is gated by `heroRemaining
  = heroMax − heroActiveGlobal` (`totalHeroActiveRegistry` counts heroes across ALL runs; fleet-wide)
  PLUS the SAME `maxItems` budget. **`maxItems` is spent by a SINGLE total `run.lifetimeDispatched`
  counter (regular + hero)** — so the lifetime cap applies to heroes too. Within a sweep heroes are
  picked first, then regulars get `maxItemsRemaining − heroCandidates.length`. **A single counter makes
  promote/demote counter-NEUTRAL** (no separate hero counter, no reconcile double-count): an item counts
  once, forever, regardless of pool — so promotion can neither refund a `maxItems` slot (the shipped
  over-launch bug) nor double-count. The reconcile floor raises `lifetimeDispatched` to the whole live
  fleet (`regularOccupancy + heroOccupancy`).
- **`effectiveHero(run, key) = run.hero.has(key)`** is the AUTHORITATIVE run-level classification (PURE;
  `heroRecord(run)` snapshots for persist). Re-stamped onto each reconciled `Assignment.hero` at the top
  of every sweep. The `hero` set is persisted (`StoreFile.hero`) + rehydrated on first reconcile
  (`loadHero`) + cleared on abort — mirroring the `keep`/`dispatched` machinery.
- **`promote`/`demote` commands (`commands.ts`, shaped like `adopt` — `{run, surfaceUUID, key?}`).** The
  reducer does the PURE part only: `promote` = `run.hero.add(key)` + `run.keepDirty.add(key)` (keep +
  hero ride ONE annotation restamp); `demote` = `run.hero.delete(key)` + the same mark. Both return a new
  `ApplyResult.kind` (`"promoted"`/`"demoted"`) NOT in `applyCommands`'s `changed` whitelist (hero
  membership lives in the PER-RUN store). **⭐ Both are whitelisted in `mcp.ts coerceQueueCommands`
  (`QUEUE_ACTIONS`) — omission SILENTLY drops the GUI emit** (the chokepoint that bit `adopt` twice).
- **Promotion NEVER blocks (design decision #2).** `promote` mutates a RUNNING assignment, so it can
  push `heroActiveGlobal` past `heroMax`; the hero gate then yields `heroRemaining ≤ 0` and no NEW heroes
  dispatch until it drains. The reducer never consults the cap.
- **Physical side effects in the post-`applyCommands` loop (`runPromote`/`runDemote`, like `runAdopt`).**
  `runPromote` **ejects** the split into its own new tab via `move_split_to_new_tab` (grid slot reassigned
  to a `-1` ejected sentinel so the packer + next dispatch ignore it) + re-stamps the hero annotation.
  `runDemote` drops the hero annotation AND **re-packs the split via the shared
  `planGridMoveForRun`/`moveExistingIntoRunGrid`** (see "Placing a MOVED split" below) — so it lands in
  the tab holding the run's lowest free slot (full grid → fresh tab), NOT always tab 0, and its `gridSlot`
  is reset. It passes its own surface as `excludeUUID` so its current slot (a reconcile-adopted hero can
  be seated at `0`, not `-1`) isn't counted. Side effects are best-effort (a failed eject/move is logged;
  the run-level set is authoritative).
- **HERO dispatch opens its OWN tab (`dispatchOne`).** A hero-classified dispatch SKIPS `splitPlan`
  (`const sp = isHero ? undefined : splitPlan(...)`) and spawns with the same `firstTab` +
  `windowAnchorUUID` shape an overflow tab uses (single terminal, anchored on a live pane), so a hero
  never lands in the grid.
- **Keep-forces-hero close gate.** At the `runner.ts` call site the stamped `keep` (passed as `ctx.keep`)
  is `effectiveKeep(run, a.key) || effectiveHero(run, a.key)` — so a hero is ALWAYS `keep === true` (held
  in DONE_PENDING, never force-closed), INDEPENDENT of `keepOnComplete` / the 📌 pin. `nextState` in
  `supervisor.ts` has NO hero logic — it consumes the generic `keep` bool, reusing the existing keep gate.
- **Status report + backlog block-reasons (`status.ts` + `QueueBacklogCanvas.swift`).** `QueueStatusReport`
  gains fleet-wide `heroMax` + `heroActive` (echoed on EVERY run's report), and each WAITING `next[]`
  `QueueItemRef` gains optional `blockReasons: BlockReason[]` (`"maxItems" | "queueConcurrency" |
  "globalConcurrency" | "heroSlots"`). The pure builder attributes reasons from per-run gate ROOM inputs
  (`regularConcurrencyRemaining`/`regularGlobalRemaining`/`regularMaxItemsRemaining` for a regular,
  `heroMax − heroActive` for a hero; blocking when room ≤ 0); omitted when nothing blocks;
  dependency-blocked is intentionally NOT a reason. Swift `QueueStatus`/`QueueStatusPayload.fromArguments`
  parse `heroMax`/`heroActive` (default 0) and thread them through every `withX()` copy helper.
  **Heroes marked independent of block state:** each `QueueItemRef` carries `hero?` (from `heroKeys` =
  promoted `run.hero` ∪ active hero assignments ∪ `list` `heroField`), and each `GraphNode` carries `hero`
  (`refreshGraph` OR's provider-graph `hero` + `heroField` + `run.hero`). `QueueBacklogCanvas` renders a
  purple `star.circle.fill` + border on any hero node; the health dropdowns show a `star.fill` per hero row
  (`AgentDashboardView`). The whole-card tooltip (`QueueBacklogReasons.tooltipLines`, pure + SwiftUI-free)
  lists each blocking gate.
- **Web-push (`WebMonitorPush.swift`).** A hero surface's push uses `PushKind.hero` (payload `"kind":"hero"`,
  distinct glyph, via the pure `pushTitle`/`pushPayload` seams). The verdict rides the EXISTING
  `.ghosttyAgentNeedsAttention` path: `AgentDashboardController.postNeedsAttention` reads the stored
  `queueHero` annotation and adds `AgentStateUserInfoKey.hero`; `WebPushManager`'s observer calls `onHero`
  when true, else `onAttention`. No new delivery mechanism.
- **The surface annotation is the GUI's view of hero-ness.** `set_surface_annotation` gains a `hero` Bool
  (`MCPAnnotation.swift`/`MCPTools.swift`); Swift `AgentAnnotation` gains `queueHero` (mirrors `queueKeep`,
  partial-merge). `list_surfaces` emits `hero: true` on a hero row (`MCPLayout.SurfaceRow.hero` +
  `surfacesJSONData`) — the **reconcile-visibility chokepoint** (same class as the `queueKey` echo adopt
  relies on). The tab marker is a per-tab `surfaceIsHero: Bool` on `TerminalWindow` (parallel to
  `surfaceIsZoomed`) driving a hero-glyph accessory (parallel to `ResetZoomAccessoryView`), set by
  `TerminalController` from a `heroSurfaceIDs` set (fed by the annotation-change notification) intersected
  with the tab's tree — a hero tab is single-terminal so it can never be zoomed (accessories never collide).
- **NO new MCP tool — count stays 26** (`promote`/`demote` ride `take_queue_commands`; `hero` rides
  `set_surface_annotation`). **NO host/Zig protocol change** beyond the one additive default-on key
  `agent-queue-hero-max` (the fork-only agent-queue keys are now 4: `agent-queue`,
  `agent-queue-templates-dir`, `agent-queue-max-total` (default-off) + default-on `agent-queue-hero-max`).
- **Wiring.** Core: `Config.zig` (`agent-queue-hero-max`), `Ghostty.Config.swift` (`agentQueueHeroMax`),
  `AgentManagerController.swift` (`GHOSTTY_AGENT_QUEUE_HERO_MAX`). Sidecar: `queue/types.ts`
  (`WorkItem.hero`, `Assignment.hero`, `ProviderListSpec.heroField`, `BlockReason`), `queue/provider.ts`
  (parse `heroField`), **`queue/templates.ts` (`validateProviderList` MUST carry `heroField` — omitting
  it silently drops it on load; the `coerceQueueCommands` chokepoint lesson, fixed 2026-07-02)**,
  `queue/runner.ts` (two-pool accounting + `QueueRun.hero` + `effectiveHero`/`heroRecord` +
  `runPromote`/`runDemote` + own-tab dispatch + keep-forces-hero stamp + rehydrate/persist),
  `queue/supervisor.ts` (`selectCandidates` split + `nextState`), `queue/commands.ts`
  (`promote`/`demote` reducer + `ApplyResult`), `queue/status.ts` (`heroMax`/`heroActive` +
  `blockReasons` + `hero`), `queue/store.ts` (`StoreFile.hero`), `mcp.ts` (`coerceQueueCommands`
  `promote`/`demote`; `Annotation.hero`/`setAnnotation`; `list_surfaces` hero read-back), `index.ts`
  (`heroMax` + fleet-wide hero-active bookkeeping). macOS: `QueueCommandBridge.swift`
  (`.promote`/`.demote` + `QueueStatus.heroMax`/`heroActive` + `QueueStatus.Item.blockReasons`),
  `MCPAnnotation.swift`/`MCPTools.swift` (`hero` parse + schema), `AgentStateBridge.swift`
  (`AgentAnnotation.queueHero`), `MCPLayout.swift` (`SurfaceRow.hero`), `AgentDashboardController.swift`
  (`promoteToHero`/`demoteFromHero` + `HookSnapshotEntry.queueHero` + `postNeedsAttention` hero
  userInfo), `AgentPreviewTile.swift`/`AgentDashboardView.swift` (Promote/Demote + hero tile),
  `QueueBacklogCanvas.swift` (`QueueBacklogReasons`), `TerminalWindow.swift`/
  `TitlebarTabsVenturaTerminalWindow.swift`/`TerminalController.swift` (`surfaceIsHero` + accessory),
  `WebMonitorPush.swift` (`PushKind.hero` + `onHero` + `pushTitle`/`pushPayload`). Tests: Zig
  `agent-queue-hero-max` parse/default; sidecar two-pool accounting / promotion-over-cap-never-blocks +
  drain / demote re-enters pool / keep-forces-hero / `heroField` parse / `promote`/`demote` coerce /
  `blockReasons` + `heroMax`/`heroActive` report / persist+rehydrate; Swift `QueueCommandBridge`,
  `MCPAnnotation`, `SurfaceRow`→`surfacesJSONData` hero emit, `surfaceIsHero`→accessory. **GUI relaunch
  + rebuilt lib/xcframework (Zig default changed) + rebuilt sidecar `dist`; no host restart.** Full
  design + the locked wire contract: **`HERO-AGENTS.md`**.

### Generic by design + the provider contract (injection seam)

- **GENERIC by design — the #1 requirement.** Ghostty/sidecar link NO tracker (Linear/GitHub/Jira) code.
  The source is a **command-based provider** the template defines: `list` (prints actionable items as
  JSON; expected to already exclude blocked/claimed/done — NO dependency graph in v1), `status {key}`
  (prints `{"state":…}`; terminal iff in `doneStates`), optional `claim`. Item fields reach the PROVIDER
  as argv (`{key}`) and the AGENT as `GHOSTTY_ITEM_*` env vars — NEVER string-spliced into a shell line
  (the one injection seam, closed). Completion is **status-only** (idleness alone never completes).

### Engine architecture

- **Engine = a deterministic, independent loop in the existing TS sidecar** (`macos/agent-manager/`,
  `src/queue/{types,provider,grid,templates,store,supervisor,runner,wiring,commands}.ts`) — NO LLM in the
  control path (the summarizer pass is orthogonal, on its own timer). It has its OWN `ConcurrencyBudget`
  (a slow LLM pass must never deny it a slot). Pure core (`selectCandidates`/`nextState`/grid/reconcile/
  applyCommand) is `node --test`-tested.

### Hard deps + self-disable

- **HARD DEPS, self-disables silently otherwise (§2):** pty-host (detection `agentKind` + STABLE session
  ids — `sessionID==0` without it) AND the Claude agent-state hooks (the close-gate keys off hook-driven
  `agentState==idle` held `closeStableSeconds`; `idleSeconds` is deliberately NOT a fallback — a
  repainting TUI never idles by it). Hooks post to the INSTALLED RELEASE port, so real queues run there,
  not a dev `+1/+2` build. **Codex can dispatch/preview but CANNOT auto-close in v1** (no hooks).

### No-duplicates guarantee

- **No-duplicates guarantee, robust WITHOUT `claim`** (§7/§9): synchronous pre-`await` active-set insert
  (within-tick), durable sidecar store keyed by `sessionID` + reconcile-each-sweep (cross-tick/restart),
  cooldown (re-dispatch of a just-finished key). `claim` is a latency optimization only. Resilience is
  first-class: a started queue + its in-flight items survive a sidecar OR GUI restart with NO re-dispatch
  and NO orphaning — the **first sweep is dispatch-suppressed until reconcile runs**, crash-safe dispatch
  ordering (pending record → spawn → annotate → finalize), orphan adoption, finalized-record prune
  grace-gated against a one-sweep `list_surfaces` lag. (These three — the lag grace, orphan grid-slot
  reclamation, and the `sessionID:0` self-disable — were the adversarial-review blockers; all fixed +
  regression-tested.)

### DISPATCH LATCH (§7.1)

- **DISPATCH LATCH (§7.1) — block re-dispatch ENTIRELY until the item leaves the list and returns.** The
  ~2-min `cooldown` is NOT enough alone: the dispatch→claim gap is HUMAN-GATED (the agent waits for the
  user's go-ahead before `/todo claim`, which moves the item off the queried state), so a split KILLED in
  that window leaves the item STILL in the `list` — and the cooldown would expire and re-grab it (and a
  restart drops the cooldown map → immediate re-grab). So every dispatched key joins a PERSISTED
  `dispatched` latch (`QueueRun.dispatched`, in the per-run store); `selectCandidates` suppresses any
  latched key OUTRIGHT (not time-cooled). The latch is RE-ARMED (cleared) only when a SUCCESSFUL `list` no
  longer reports the key (it left the actionable set); a FAILED list never re-arms (no false re-enable on
  a transient error). So re-dispatch requires a real **status round-trip**. Consequence: a crashed
  (EXITED) agent whose item stays listed is NOT auto-retried — it needs the round-trip too. Latched at
  dispatch intent (rolled back only if the spawn fails), persisted on every store write, rehydrated on the
  first reconcile, cleared on `abort`. Wiring: `store.ts` (`StoreFile.dispatched` +
  `serializeStore`/`parseDispatched`/`loadDispatched` + `persistStore` 4th arg), `supervisor.ts`
  (`selectCandidates` `dispatched` param), `runner.ts` (`QueueRun.dispatched` + latch add/rollback in
  `dispatchOne` + re-arm in `dispatchCandidates` + rehydrate). Tests: `store.test.ts` (round-trips +
  tolerance), `supervisor.test.ts` (latch skip + re-arm), `runner.test.ts` (kill-before-claim NOT
  re-dispatched w/o a round-trip, crashed-EXITED cooled-then-latched, latch persists across restart).

### RELEASE held items — the in-place latch escape (§7.1)

- **RELEASE — clear the latch WITHOUT a tracker round-trip.** The §7.1 latch is deliberately sticky, which
  leaves a real dead-end: an agent that crashed/exited OR was killed before claiming leaves its item in the
  `list` forever-suppressed, "in limbo." A `release` command is the escape.
  - **HELD set:** `status.ts queueStatusReport` derives `held`/`heldCount` = `listItems ∩ latchedKeys ∩
    ¬activeKeys` (runner passes `run.dispatched` as `latchedKeys` and `new Set(run.active.keys())` as
    `activeKeys`). A latched key NOT in the current list is omitted (the re-arm will clear it); a latched
    key still ACTIVE (running, or EXITED with its split open) is omitted (tracked, not stuck).
  - **`release{run, key?}`** (`commands.ts`, whitelisted in `mcp.ts coerceQueueCommands`, reusing the
    optional `key` field): with a `key`, clears `run.dispatched.delete(key)` + `run.cooldown.delete(key)`;
    with NO key, clears every HELD item (latched ∩ listed ∩ ¬active). PURE (mutates only per-run state);
    persisted by the run's next reconcile sweep (like `set_keep`, so `applyCommands` does NOT count
    `release` as an active-runs change). Once cleared, the next `dispatchCandidates` (≤`listMs`)
    re-dispatches fresh.
  - **GUI:** `QueueStatus` gains `held`/`heldCount` (parsed by `QueueStatusPayload`, forwarded by `mcp.ts
    reportQueueStatus`, declared in the `report_queue_status` schema — `additionalProperties:false`, so the
    fields MUST be declared). `QueueCommand.Action.release` (lowercase wire value).
    `AgentDashboardController.releaseQueueItem(run:key:)` posts the command + optimistically drops the
    key(s) via `QueueStatus.withHeld`. `OriginSectionHeader` renders the orange `N held` chip → `heldPopover`
    (per-item **Release** + **Release all**), shown only when `heldCount > 0`. Wiring: sidecar
    `status.ts`/`runner.ts`/`commands.ts`/`mcp.ts`; Swift `QueueCommandBridge.swift` (action +
    `held`/`heldCount` + `withHeld` + parse), `MCPTools.swift` (schema), `AgentDashboardController.swift`,
    `AgentDashboardView.swift` (`N held` chip + `heldPopover`). Tests: sidecar `status.test.ts`
    (held derivation/dedup/cap/empty), `commands.test.ts` (release single + bulk + tolerant + unknown-run
    no-op + not-counted), `mcp.test.ts` (coerce release w/ optional key; `reportQueueStatus` forwards
    held); Swift `MCPServerTests` (`queueCommandReleaseSerializes*`, `queueStatusPayloadParsesHeld*`,
    `queueStatusWithHeld*`). **GUI relaunch + rebuilt sidecar `dist`; no host/Zig change.**

### Adopting a free split into a queue (the `adopt` + `infer_key` commands)

> **Scripted adopt (no click): the `adopt_split` MCP tool.** The same `adopt` command can be enqueued from
> a script via `adopt_split{run, key, surfaceUUID, url?}` (MCP-SERVER.md) — a script otherwise has NO way to
> enqueue a queue control command (the GUI *posts* `.ghosttyQueueCommand`, the sidecar only *drains* via
> `take_queue_commands`). Same FIFO/reducer/~1-round-trip wake; the sidecar stays authoritative for
> latch/dedup. **Main use case: the local-queue / cloud-agent split** — leave the template dispatching
> LOCALLY (`host` absent/`"local"`), launch the agents on a box with `spawn_split_command` + `host`, then
> `adopt_split` them in. Adopt is host-agnostic: `runAdopt` has no host gate and reconcile DERIVES the host
> from the live row's composite `sessionID`, so an adopted remote split records `Assignment.hostName =
> <box>`. ⚠️ Launch through `spawn_split_command` (NOT the `new_split_on_host` keybind): the cross-host
> correlation nonce is minted only on the MCP spawn path, and without it the box's hook can't report
> working/waiting state, so the queue can never see the agent go idle and will not auto-close it.

- **WHAT** — a dashboard tile **Adopt…** button (on a non-queue CLI-agent tile) pulls a human-created split
  into a running queue so the queue tracks it like a dispatched item: MOVES the split into the run's grid
  tab, LATCHES the key, follows `keepOnComplete`, fires `claim`, and lets reconcile's existing
  orphan-adoption fold the annotated surface in. Title preview is a LOCAL `report_queue_graph` node lookup;
  the key field is prefilled by an on-demand Haiku call.
- **⭐ The coercer gate (the chokepoint, `mcp.ts coerceQueueCommands`, NOT index.ts).** Two new actions
  `adopt` + `infer_key` added to `QUEUE_ACTIONS`, and the coercer body carries two new string fields
  `surfaceUUID` + `url`. WITHOUT this the GUI's emitted commands are SILENTLY DROPPED before the reducer.
  (Guarded by `mcp.test.ts coerceCarriesAdoptFields` / `coerceKeepsInferKey`.)
- **The latch-at-adoption crux (`commands.ts`).** `applyCommand`'s `case "adopt"` does the PURE part only —
  the LATCH + dedup. It validates run/key/surfaceUUID, then `adoptDecision(run, key)` (extracted +
  unit-tested): **`"reject-duplicate"`** when `run.active.has(key)` (the GUI offers "jump to the running
  one"), else **`"latch"`** ⇒ `run.dispatched.add(key)` **BEFORE any `await`**, so even if the sweep is
  interrupted between latch and move, `selectCandidates` already suppresses the key. Returns
  `ApplyResult.kind` `"adopted"`, NOT in `applyCommands`'s `changed` whitelist (the latch lives in the
  per-run store).
- **`infer_key` resolved control flow.** It IS whitelisted (else the coercer drops it) and flows through
  `applyCommand` as an EXPLICIT `case "infer_key": return {kind:"noop"}` (named, mutates nothing). The real
  Haiku work runs in the sweep's post-`applyCommands` side-effect loop.
- **Runner side effects (`runner.ts runAdopt`).** After `applyCommands` + persist + the report loop,
  `runQueueSweep` re-iterates the drained `commands`: `adopt` → `runAdopt`, `infer_key` → `runInferKey`.
  `runAdopt`: re-checks dedup against LIVE `run.active`; places the split via **shared `planGridMoveForRun`
  + `moveExistingIntoRunGrid`** (below) — the SAME `gridOccupancy`→`lowestFreeSlot`→`splitPlan` contract
  `dispatchOne` uses, so it lands in the tab with the run's lowest free slot (NOT always tab 0), and a FULL
  grid **ejects into its own overflow tab** (`move_split_to_new_tab`). If the run has NO seated pane it does
  NOT move (the adopted split becomes the seed). **On a BALANCED-split MOVE failure it ROLLS BACK the latch**
  (`run.dispatched.delete(key)` + persist); the overflow eject is best-effort and never rolls back. Then it
  stamps the annotation (`queueKey`/`queueName`/`queueUrl` + `keep = effectiveKeep(run, key)` — FOLLOWS the
  template, NOT forced true), fires `claim`, and persists the latch. It NEVER writes `run.active` (reconcile
  is its sole owner) and never spawns, so the adopted pane occupies a concurrency slot WITHOUT bumping
  `lifetimeDispatched`.
- **Placing a MOVED split — shared `planGridMoveForRun` / `moveExistingIntoRunGrid` (adopt + demote).**
  Moving an EXISTING split into a run's grid (a human-adopted surface, or a demoted hero re-entering) must
  make the SAME slot→tab decision `dispatchOne` makes, or it over-packs. **The bug this fixed:** both paths
  formerly anchored on the run's *lowest slot* (always TAB 0) and relied on `move_surface_into_tab`'s
  `maxCols`/`maxRows` caps to "overflow" — but the GUI's `largestLeafSplit` cap has a defensive fallback
  that STILL over-packs a full tab (it assumes the caller already spilled to a new tab, which `dispatchOne`
  does via `splitPlan` but adopt/demote did not). So adopting/demoting into a full tab 0 added a 7th pane to
  a full 3×2 tab. Fix: the pure `planGridMoveForRun(run, excludeUUID?)` runs the dispatch contract —
  `gridOccupancy(run, excludeUUID)` → `lowestFreeSlot` (cap = `effectiveConcurrency + scheduleActive.size`,
  `?? occupied.size` for over-capacity overflow) → `splitPlan` — returning `null` (no seated pane → leave
  the source as the seed), `{newTab:true, slot}` (all tabs full → eject), or `{newTab:false, anchorUUID,
  slot}` (balanced-split into the tab HOLDING the free slot, so `largestLeafSplit` never hits its over-pack
  fallback). The async `moveExistingIntoRunGrid` executes it: balanced → `moveSurfaceIntoTab` (throws on
  failure — the caller decides fatality); newTab → the hero-promote `move_split_to_new_tab` eject
  (best-effort, never throws). `excludeUUID` drops the MOVING pane from occupancy — REQUIRED for demote,
  where a hero adopted via reconcile carries a real `gridSlot` (0), not the promote sentinel `-1`, so
  `gridOccupancy`'s `gridSlot >= 0` filter wouldn't skip it. Wiring: `queue/runner.ts`
  (`planGridMoveForRun`/`moveExistingIntoRunGrid` + `gridOccupancy` `excludeUUID`; `runAdopt`/`runDemote`
  route through it). Tests: `runner.test.ts` (`runAdopt: anchors on the tab that has a FREE slot…`,
  `runAdopt: a FULL grid overflows into a new tab (eject)…`, `hero: DEMOTE re-packs … across MULTIPLE tabs…`).
- **Reuse of reconcile's orphan-adoption (NOT a parallel path).** `store.ts reconcile` already folds a live
  surface carrying `queueKey`+`queueName` with no matching record into the run as a RUNNING assignment
  (fresh `sinceMs`, lowest-free grid slot). So "adopt" = stamp the annotation + add the latch; the NEXT
  reconcile absorbs it. **PRECONDITION (relied upon + documented):** the adopted surface MUST have a
  NON-ZERO `sessionID` — reconcile skips `sessionID === 0` ("can't be persistence-keyed → not adoptable").
  A human pty-host split always has a real session, and the Adopt button is gated behind the pty-host HARD
  DEP, so a 0-session target is unreachable through the UI. We add NO 0-session fallback.
- **⭐ SECOND chokepoint — `list_surfaces` MUST echo the queue tags (shipped + fixed 2026-06-30).**
  reconcile reads `queueName`/`queueKey` off the `list_surfaces` ROWS (`store.ts` keys orphan-adoption on
  `r.queueName`/`r.queueKey`). `MCPLayout.surfacesJSONData` originally emitted `notes`/`agentKind`/etc. but
  NOT the queue tags, so reconcile was BLIND to every adopted surface → it was annotated + grouped in the
  dashboard (which reads its OWN `annotations` model) but NEVER folded into `run.active` → `N running` never
  incremented AND the supervisor never status-polled / auto-closed it. Fix: the tags flow `annotation` →
  `HookSnapshotEntry` (`queueKey`/`queueName`/`queueUrl`) → `MCPLayout.SurfaceRow` → `surfacesJSONData`
  (emit when non-nil). Tested by `MCPServerTests.surfacesJSONDataEmitsQueueTagsWhenPresentOmitsWhenNil`.
  (Distinct from the FIRST chokepoint — the `coerceQueueCommands` whitelist carries the command INTO the
  sidecar; this one carries the annotation BACK.)
- **Haiku key inference seam (`queue/infer.ts` + index.ts).** PURE, SDK-free helpers:
  `composeInferPrompt(viewportTail, candidateKeys)` (hint block OMITTED when no candidates),
  `parseInferredKey(raw)` (trim/strip fences+quotes, first non-empty line, first token, reject >64-char
  junk → key | null), `collectCandidateKeys(registry, runName)` (graph ∪ list keys, deduped). The impure
  DRIVER `runInferKeyWithDeps(surfaceUUID, runName, deps)` (also in `infer.ts`, model `summarize`
  INJECTED — never imported, so the queue module keeps its no-npm-deps property): read surface → tail →
  compose → `summarize` (warm-base aware, `isUsable = parseInferredKey !== null`) → write the inferred key
  (or `""`) as the `queueKeySuggested` annotation. **BEST-EFFORT: ANY failure writes the `""` sentinel** so
  the GUI modal drops its spinner. Wired in index.ts as `deps.queue.inferKey`, tagging usage
  `feature:"issue-key-infer"` (the third Haiku feature — see `AGENT-MANAGER.md`).
- **The `queueKeySuggested` annotation sentinel (`mcp.ts`).** New optional `Annotation` field forwarded by
  `setAnnotation` even when `""` (`!== undefined`, NOT truthiness): NON-EMPTY = the inferred key; `""` =
  "tried, found nothing" (ALWAYS written on the infer path); ABSENT = "no suggestion yet". The
  `set_surface_annotation` schema gains the field (additive — **no new tool, count stays 26**). The GUI
  clears any stale value DIRECTLY at modal open (not via the never-nils `merging`).
- **Wiring (sidecar):** `mcp.ts` (⭐ `coerceQueueCommands` whitelist + `surfaceUUID`/`url` carry +
  `queueKeySuggested` `Annotation`/`setAnnotation`), `queue/commands.ts` (`adopt` latch/dedup +
  `adoptDecision` + `infer_key` no-op + `ApplyResult` `"adopted"`), `queue/runner.ts` (`runAdopt` +
  `runInferKey` + `deps.inferKey` seam + sweep side-effect loop), `queue/infer.ts` (NEW), `index.ts`
  (`deps.queue.inferKey` + `issue-key-infer` usage tag). **Tests:** `mcp.test.ts` (coerce adopt/infer_key +
  carried fields + unknown-action-still-dropped + `queueKeySuggested` incl. `""`), `commands.test.ts`
  (`adoptDecision`, latch, reject-duplicate, missing-args, `infer_key` no-op, not-an-active-run-change),
  `runner.test.ts` (runAdopt moves/annotates/claims/persists, move-failure rollback, no-anchor seed,
  adopt+reconcile fold, 0-session not-folded, infer_key dispatch + no-seam no-op), `infer.test.ts`
  (parse/compose/candidates + `runInferKeyWithDeps` writes key / `""` / `""`-on-error). **GUI relaunch +
  rebuilt sidecar `dist`; no host/Zig change.**
- **Wiring (macOS / Swift):** `QueueCommandBridge.swift` (`QueueCommand.Action` `.adopt` + `.inferKey` +
  `surfaceUUID`/`url` stored props emitted by `jsonObject` ONLY when non-nil+non-empty — the matched pair
  to the ⭐ `mcp.ts` coercer carry, BOTH must land); `AgentStateBridge.swift`
  (`AgentAnnotation.queueKeySuggested: String?` 3-state sentinel added to `init` + `merging` (`other ??
  self`); the PURE `clearingSuggestion()` nils ONLY it — the deliberate bypass for `merging`'s never-nils
  asymmetry); `MCPAnnotation.swift`/`MCPTools.swift` (parser reads `queueKeySuggested` **keeping `""`**,
  NOT trimmed-to-nil, + at-least-one-field guard; schema property additive — **NO new tool,
  `toolsListHasAllTools` count stays 26**); `AgentDashboardController.swift` (`adoptSplit(id:run:key:url:)`
  posts `.adopt`, NO optimistic flip; `requestInferKey(id:run:)` clears via `clearingSuggestion()` NOT
  `merging`, early-returns on empty run; `runNamesForAdopt()` empty⇒disabled/single⇒auto-select;
  `graphNodeForAdopt(run:key:)` LOCAL `QueueGraph.nodes` lookup; `activeKeysForRun(_:)`; `jumpToKey(run:key:)`);
  `AgentPreviewTile.swift` (the hover **Adopt…** button gated `!isQueueOwned && entry.agent != nil`,
  disabled when no run, + the `.sheet` modal: picker auto-hidden for one run; key `TextField` w/ "inferring…"
  spinner bound to `queueKeySuggested` + ~8s `.task(id:)` timeout; graph-local title preview/off-board note;
  duplicate guard + "Jump to the running one"; KEEP-pin footnote); `AgentDashboardView.swift` (passes the 7
  closures). **Tests (Swift):** `QueuePaletteTests.swift` (`adoptJSONObjectShape`/`adoptJSONObjectOmitsEmptyURL`/
  `inferKeyJSONObjectShape`), `MCPAnnotationTests.swift` (`parseQueueKeySuggestedAloneAndEmptyKept`,
  `merging{Preserves,Overlays}QueueKeySuggested`, `clearingSuggestionNilsItAndPreservesRest`),
  `MCPServerTests.swift` (`toolsListHasAllTools` count stays 26). The single-parameter `.onChange(of:)` form
  is used throughout (deployment target macOS 13; the two-param form needs macOS 14).

### On-demand command channel + `take_queue_commands` (§8a)

- **ON-DEMAND lifecycle via a GUI→sidecar COMMAND CHANNEL** (§8a) — the sidecar is the MCP CLIENT so the GUI
  can't push; commands are DRAINED. `MCPServer` holds a thread-safe FIFO (enqueued on its serial queue via a
  `.ghosttyQueueCommand` observer the palette/dashboard post to; `QueueCommandBridge.swift`/
  `MCPQueueCommands.swift`), drained by the MCP tool **`take_queue_commands`**. The sidecar applies
  start/pause/stop(drain)/abort/resume (`commands.ts applyCommand`), persists the active-run SET
  (`active-runs.json`) + rehydrates on restart. **A template merely on disk does NOT auto-run** (replaced
  Phase-1 `loadRuns(all)`) — only a started/persisted run.

### START-TIME PARAMS + maxItems override (§8b)

- **START-TIME PARAMS (§8b) — prompt for project/milestone/maxItems/etc. at start, don't hard-code.** A
  template can declare `params: [{name, target?, env?, label?, default?, required?}]`; on start the
  QueuePalette PROMPTS for each (pre-filled with `default`), and each answer is delivered per its `target`.
  **`target` (default `"env"`)** picks delivery: an `"env"` param is injected into the PROVIDER command env
  under `param.env` (so ONE generic template is re-pointed per run); a **`"maxItems"`** param instead sets
  the RUN's lifetime dispatch cap (overriding the template `maxItems`). An env param scopes "what to work on"
  and is delivered ONLY to the provider, NOT the agent; a maxItems param reaches NEITHER (it tunes the
  engine). Env resolution is `answer ?? default ?? omit` (`resolveParamsEnv`, pure); a REQUIRED param with
  no answer+no default REJECTS the start (`missingRequiredParams`, enforced in the factory + the Start button
  disabled). The maxItems override (`resolveMaxItemsOverride`, pure): blank/garbage → `undefined` (template
  `maxItems`); `"0"`/`"unlimited"`/`"none"`/`"inf"`/`"∞"` → unlimited (`maxItemsRemaining` is Infinity; the
  global cap+grid+concurrency still bound it); a positive integer → that cap. Validation: `target` must be
  `"env"`|`"maxItems"`; an env param needs a valid `env`; AT MOST ONE maxItems param. Params persist in the
  active-runs record (`params` map) so a restart re-applies scope AND maxItems. A template with no params
  starts directly. **The Swift palette is UNCHANGED** — its `templateParams` parser reads
  name/label/default/required and is `env`/`target`-agnostic, so the maxItems param prompts like any other
  with no GUI change. Wiring: sidecar ONLY — `types.ts` (`QueueParam.target`/`QueueParamTarget`, `env` now
  optional), `templates.ts` (`validateParams` target + `resolveParamsEnv` skips non-env + `resolveMaxItemsOverride`),
  `runner.ts` (`dispatchCandidates` applies the override). The env-param plumbing (`runner.ts` `QueueRun.params`,
  `commands.ts`, `store.ts`, `mcp.ts`, `wiring.ts`, `QueueCommandBridge.swift`, `QueuePalette.swift`) is
  unchanged — the maxItems answer rides the existing `params` map. Tests: `templates.test.ts` (target validate
  + `resolveParamsEnv` skip + `resolveMaxItemsOverride` cases), `runner.test.ts` (override CAPS a sweep below
  list size + `"0"` unlimited dispatches PAST the template cap), plus existing `commands`/`store`/`mcp` and
  Swift `QueuePaletteTests`. **A rebuilt sidecar `dist` is enough (the GUI respawns it); no GUI relaunch /
  host / Zig change.**

### Start-form live preview + value suggestions (§8b UX)

- **START-FORM LIVE PREVIEW + VALUE SUGGESTIONS (§8b UX, GUI-only, no sidecar/host/Zig change).** Two
  GUI-SIDE probes run the template's provider commands directly (via `Process`, off-main, debounced ~0.35s,
  generation-guarded so stale results are discarded):
  - **Live `list` PREVIEW** — once all REQUIRED fields are filled, runs `provider.list.command` with the
    current values as provider env and shows "N items would be queued" + a sample of titles, or "no matching
    items" (amber), or the provider's last stderr line (red). Gated on `canStart`.
  - **Per-param VALUE SUGGESTIONS** — a param may declare an OPTIONAL `valuesCommand` (argv) that prints a
    JSON array (bare strings OR `{value,label?}`); the form runs it with current values as env and shows a
    menu next to the field. Because the env carries the OTHER fields, a DEPENDENT provider works: milestones'
    `valuesCommand` reads `$LINEAR_PROJECT` and re-runs when the project field changes. Every `valuesCommand`
    re-runs on each debounced change (a failed probe keeps the prior list).
  - **The probe is the GUI running the provider, NOT the sidecar** — the sidecar is the MCP client and can't
    be queried, so the form execs the argv via `/usr/bin/env <argv>` (so a bare `python3`/`node` resolves on
    PATH) in the template `workdir`, inheriting the GUI env + the form's provider env. Mirrors the sidecar's
    `resolveParamsEnv` (`QueueProviderProbe.providerEnv`: env-target non-blank only; maxItems/blank skipped).
  - **Schema:** `QueueParam.valuesCommand?: string[]` (TS type + `validateParams` validates it as an optional
    argv even though only the GUI runs it). Wiring: sidecar — `types.ts`/`templates.ts` (`valuesCommand` +
    validation); Swift — `QueuePalette.swift` (`QueueParamSpec` gains `env`/`isMaxItems`/`valuesCommand`; new
    `QueueTemplateProbe` + `templateProbe()`; `QueueParamProber` @MainActor debounced probe;
    `QueueProviderProbe` pure `providerEnv`/`parseValues`/`previewState` + blocking `run`; `QueueParamFormView`
    adds the suggestion menus + preview footer). Linear value scripts live in the untracked config
    (`example-projects.py`, `example-milestones.py` — `[]` when no project). Tests: sidecar `templates.test.ts`
    (valuesCommand validate); Swift `QueuePaletteTests` (`templateParamsParsesTargetAndValuesCommand`,
    `templateProbe*`, `providerEnv*`, `parseValues*`, `previewState*`). **GUI relaunch to pick up (Swift
    change); the `valuesCommand` field needs no sidecar restart.**

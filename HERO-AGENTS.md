# Hero Agents (fork-only, macOS)

> **Status:** shipped. Part of the Agent Queue + Agent Dashboard subsystems — read
> `AGENT-QUEUE.md` and `AGENT-DASHBOARD.md` first; this doc only covers what a *hero*
> adds on top of a regular queue item.

## What a hero is

Most queue work is **fungible throughput**: "get this predefined task done", clean up a
discrete piece of tech debt, code a UI screen. You want many of these running hands-off,
packed into a grid, auto-closed when done.

A **hero** is the opposite kind of work: something **load-bearing** for the project that has
to be *right* — research, deep design/architecture taste, or many small details that all have
to land. The pain heroes solve is twofold: (1) they hide in the same tabs as the routine work
and are hard to find, and (2) you can only hold **one or two** in your head at a time — even
when 10 other agents are running.

So the scarce resource a hero competes for is **your attention**, not a machine slot. That one
fact drives every difference below. A hero is **not a new subsystem and not an internal
workflow** — the engine models no research/design/build phases (those are owned by the agent
definition + the issue description, exactly as for a regular item). A hero is a **per-item
property** that changes four things: *slot accounting, lifecycle, layout, and notification*.

## Model at a glance

| Dimension | Hero | Regular |
|---|---|---|
| Scarce resource | **your attention** | machine slots |
| Slot accounting | **fleet-wide `agent-queue-hero-max`** for concurrent heroes; off the per-queue `concurrency` grid + `max-total`; but **counts against the queue's `maxItems`** (shared lifetime budget) | queue `concurrency` + global `agent-queue-max-total` + per-run `maxItems` |
| Entry | provider `heroField` (queue-defined) **or** promote a running regular | `list` poll |
| Over-cap | **promotion never blocks** (may exceed); no *new* hero dispatches until it drains under | n/a |
| Reverse | **demote** hero → regular | n/a |
| Lifecycle | **keep-by-default**, never auto-closed (follow-up-PR context survives) | auto-close on done+idle |
| Layout | **own dedicated tab** (single terminal, never in the BSP grid) | tile in the shared grid tab |
| Tab marker | distinct **hero glyph** in the tab-accessory slot, visible across all tabs | none |
| Backlog waiting | distinct icon + hover tooltip listing the exact gate(s) | clock icon |
| Notification | **loud attention tier** + distinct web-push glyph | normal bell |
| Phases / artifacts | owned by agent def + issue desc (engine models nothing) | same |

## Design decisions (locked)

1. **Fleet-wide concurrency cap, off the grid, but inside `maxItems`.** `agent-queue-hero-max` is
   a **fleet-wide** ceiling on live heroes across *all* queue runs. A hero runs in its own tab, so
   it does **not** consume a per-queue `concurrency` slot and is **not** counted against
   `agent-queue-max-total` (the regular-grid fleet cap) — this is the "2–3 heroes **plus** 10 other
   agents" reading, for the *concurrent* dimension. **BUT `maxItems` (the queue's lifetime dispatch
   budget) DOES apply to heroes:** a single total `lifetimeDispatched` counter spends `maxItems`
   across BOTH pools, so a hero can't be scheduled once the queue's lifetime cap is hit (you can't
   blow past `maxItems` just because the work is load-bearing). Default `agent-queue-hero-max` **2**
   (a discipline limit). `0` disables hero *concurrency* (hero-marked items then wait on the
   hero-slot gate, visibly — see backlog).

2. **Two entry paths.** Either the provider marks an item hero up front (queue-defined
   sourcing — see the wire contract), or you **promote** a running regular agent whose scope
   turned out to be load-bearing (the analog of `adopt`, which pulls a free split *into* a
   queue). **Promotion never blocks** — it may push you *over* the cap; the only consequence is
   that no *new* heroes are pulled until live heroes drain back under the cap.

3. **Demotion exists.** `demote` flips a hero back to a regular tracked item (for when the
   scope turned out smaller than feared). Demotion reclassifies accounting, drops the marker,
   **and re-packs the split back into the run's BSP grid** — symmetric with promote's eject, so
   a promote→demote round-trip returns the split to the grid rather than stranding a plain
   regular in the hero's dedicated tab. It packs into a seated regular anchor's tab (multi-tab
   overflow honored); with no anchor (the run's only pane) there's nothing to pack into, so it
   stays put. (This re-pack was originally a non-goal; reversed once "a normal agent in a
   dedicated tab" turned out to be the stranded-demote state.)

4. **Keep-by-default.** A hero is **never** auto-closed — `effectiveKeep` is forced true for a
   hero regardless of template/📌, so it holds in `DONE_PENDING` forever. Heroes often want a
   quick follow-up PR, so keeping the window (and its context) is the point.

5. **Own dedicated tab + across-tabs marker.** Each hero lives in its own single-terminal tab,
   never in the BSP grid. It is marked by a distinct **hero glyph** rendered in the same
   tab-accessory slot the zoom button uses — which is free precisely because a single-terminal
   hero tab can never be zoomed. The zoom accessory is window-level chrome whose visibility is
   driven by a per-tab bool and shows across tabs, so a parallel `surfaceIsHero` bool gives us
   an across-tabs marker for free (confirmed: the accessory is visible on non-focused tabs).

## Wire contract (both sides match — the chokepoint)

The sidecar (TypeScript) and the GUI (Swift) share these exact names. This is the chokepoint
that made `adopt` a silent no-op twice, so it was locked before implementing and is asserted
by tests on both sides.

- **Config key:** `agent-queue-hero-max` (`u32`, default `2`, fork-only). Forwarded to the
  sidecar as env `GHOSTTY_AGENT_QUEUE_HERO_MAX` by `AgentManagerController` (same transport as
  `GHOSTTY_AGENT_QUEUE_MAX_TOTAL`).
- **Template list spec:** `heroField?: string` — a JSON field name in the `list` output whose
  truthy value marks that item a hero (mirrors the existing `keyField`/`titleField`/`urlField`).
  Sourcing is **queue-defined**: e.g. a Linear queue's `list` script computes a boolean field
  from a special label. Absent ⇒ no items are heroes from the list (promotion still works).
- **`WorkItem`:** gains `hero?: boolean` (parsed from `heroField`). **`Assignment`:** gains
  `hero: boolean` (persisted, rehydrated on restart like `keep`/`dispatched`).
- **Queue commands:** `promote` and `demote`, each carrying `{ run, surfaceUUID, key? }`
  (shaped like `adopt`). Added to the `QUEUE_ACTIONS` whitelist in `coerceQueueCommands`
  (`mcp.ts`) — **omission here silently drops the command**.
- **Surface annotation:** arg key `"hero"` (Bool) on `set_surface_annotation`; Swift model field
  `queueHero` (mirrors `queueKeep`). This is how the GUI learns a split is a hero and how the tab
  marker + tile visuals are driven.
- **`list_surfaces` JSON:** emit `hero: true` on a hero surface row (mirrors `queueKey`). This is
  the **reconcile-visibility chokepoint** — the sidecar reads hero state back off the rows, so
  `MCPLayout.surfacesJSONData` must emit it.
- **Status report:** add `heroMax: number` + `heroActive: number` (global); per-item
  `blockReasons?: BlockReason[]` on `QueueItemRef`, where
  `BlockReason ∈ {"maxItems","queueConcurrency","globalConcurrency","heroSlots"}` (dependency-
  blocked is **omitted** — the graph edges show it); and a per-item **`hero?: boolean`** on every
  `QueueItemRef` (`next`/`running`/`held`), sidecar-set from `heroKeys` (promoted `run.hero` ∪ active
  hero assignments ∪ `list` `heroField`) so the health dropdowns mark heroes. The Swift `QueueStatus`
  / `QueueStatusPayload.fromArguments` parse `heroMax`/`heroActive` (default 0 when absent) and the
  per-item `hero`.
- **Backlog graph node:** `GraphNode.hero?: boolean` (sidecar `refreshGraph` OR's a provider-set
  `hero`, a `list` `heroField` item, and a promoted `run.hero` key) ⇄ Swift `QueueGraph.Node.hero`,
  so the canvas marks **any** hero node, not just one blocked on the hero-slot gate.
- **Web-push payload:** `PushKind.hero`; payload dict gains `"kind":"hero"`; the hero
  notification title uses a distinct glyph.

## How each dimension works

### Slot accounting (sidecar)

The dispatch gate (`dispatchCandidates` → `selectCandidates`) splits the list into two pools by
`item.hero`, sharing **one total lifetime counter** `run.lifetimeDispatched` (regular + hero):

- **Regular pool** — gated by `remainingSlots(effConcurrency, activeRegular, globalRegularRemaining)`
  (`activeRegular` = non-hero slot-occupiers only; heroes run off-grid so they don't hold a regular
  concurrency slot) **plus** the shared `maxItems` budget.
- **Hero pool** — gated by `heroRemaining = heroMax − heroActiveGlobal` (fleet-wide concurrent-hero
  cap; `heroActiveGlobal` counts hero assignments **across all runs**) **plus the SAME `maxItems`
  budget** — the queue's lifetime cap applies to heroes too, so a hero can't dispatch once `maxItems`
  is hit. No per-run `concurrency` / `max-total` gate a hero.

`maxItems` is spent by the **single** `run.lifetimeDispatched` (every dispatch of either pool bumps
it). Within one sweep heroes are picked first, then regulars get the remainder, so a sweep never
dispatches more than the budget total across both pools.

`promote` flips a live assignment's `hero` bit to true (and ejects it — see layout). Because it
mutates a *running* assignment rather than dispatching, it can push `heroActiveGlobal` past `heroMax`;
the hero gate then yields `heroRemaining ≤ 0` and no new heroes dispatch until it drains.
**Promotion is counter-NEUTRAL:** the item was already counted once in `lifetimeDispatched` at its
dispatch and stays counted — so promotion neither refunds a `maxItems` slot (which would let the
queue over-launch — a real bug that was fixed) nor double-counts. Marking it a hero frees only its
regular *concurrency* slot (it leaves `regularOccupancy`). `demote` flips the bit false; the item
re-enters the regular pool for future accounting. Both are counter-neutral — a single counter means
an item counts once, forever, regardless of which pool it currently occupies.

### Lifecycle (sidecar)

In the close gate (`nextState`, `supervisor.ts`), a hero assignment is treated as
`keep === true`: on terminal provider status it holds in `DONE_PENDING` forever and is never
force-closed. This is independent of the 📌 pin and the template `keepOnComplete`/`closeOnComplete`
(a hero is always kept). The 📌 pin still works and is still shown.

### Layout & the dedicated tab (sidecar + Swift)

- **Hero dispatch** spawns the agent into its **own new tab** (single terminal), not into the
  run's grid tab — so heroes never participate in `largestLeafSplit` BSP packing.
- **Promotion** of an already-running regular split **ejects** it into its own new tab (reusing
  the `move_split_to_new_tab` / `newTab(tree:)` machinery), then annotates + reclassifies it.
- Grid packing (`largestLeafSplit`, grid caps) ignores hero surfaces entirely.

### Tab marker (Swift / AppKit)

A per-tab `surfaceIsHero: Bool` on `TerminalWindow` (parallel to `surfaceIsZoomed`,
`TerminalWindow.swift:360`) drives a hero-glyph accessory view (parallel to
`ResetZoomAccessoryView`, `TerminalWindow.swift:642`) rendered in the tab-accessory slot
(`TitlebarTabsVenturaTerminalWindow.swift:241`). `TerminalController` sets it when the surface
tree's focused/only surface carries the `queueHero` annotation (parallel to
`window.surfaceIsZoomed = to.zoomed != nil`, `TerminalController.swift:184`). A hero tab is
single-terminal so it can never be zoomed — the two accessories are mutually exclusive and never
collide. Glyph: a distinct hero SF Symbol (e.g. `star.fill`), tinted so it reads apart from the
🔔 bell title-prefix and the orange marked-pane inset.

### Backlog + dropdowns: heroes are marked everywhere (sidecar report + Swift canvas)

Heroes must read as heroes wherever a queue item is shown, **independent of whether they're
currently blocked** — not only when stuck on the hero-slot gate.

- **Backlog canvas.** Each `GraphNode` carries a `hero` flag (sidecar `refreshGraph` OR's it from
  three sources: a provider `graph` script may set `hero` directly, a `list` item with a truthy
  `heroField`, and a PROMOTED key in the run-level `hero` set). `QueueBacklogCanvas` shows the hero
  glyph (a purple `star.circle.fill`) + a purple card border on **any** hero node, alongside the
  normal running/`clock` state icon. The whole-card **`dashboardTooltip`** (see below) lists WHY a
  non-running item isn't moving, one line each: the graph's **workflow labels** (`node.labels`, e.g.
  "Inputs needed", "Design needed" — the human reason it's not actionable) followed by any
  **dispatch-gate** reason (`maxItems` / `queue concurrency` / `global concurrency` / `hero slots`),
  under a "Blocked on:" header — so a hero stuck on a hero slot is obvious and nobody wastes time
  bumping `maxItems`. (Dependency-blocked is not listed — the graph edges show it. The provider's
  `graph` script excludes the "Hero issue" label from `node.labels` since that's surfaced as the
  ★ star, not a blocked-on line.)
- **"N waiting / M running / N held" dropdowns.** Each `QueueItemRef` carries a `hero` flag (sidecar
  sets it from `heroKeys` = promoted `run.hero` ∪ active hero assignments ∪ `list` `heroField`, plus
  the assignment's own bit for running items), and every dropdown row shows a purple `star.fill` for
  a hero — so heroes stand out in the health-bar dropdowns too.

**Panel-safe tooltips (`dashboardTooltip`).** The dashboard is a **non-activating `NSPanel`**, and
AppKit `.help()` tooltips only render for the KEY window — so native tooltips never appeared on the
tile icons or backlog nodes while hovering the (non-key) panel. The `DashboardTooltip` view modifier
drives a small bubble off `.onHover` (which DOES fire in the panel — it's what reveals the tile's
hover buttons). It does NOT also set `.help()` — the backlog board is its own normal (key-able)
window where native `.help()` DOES fire, so setting both showed TWO tooltips; the popover works in
every window and is the single source. All tile-icon and backlog tooltips use it.

### Notification (Swift)

A hero surface uses the **loud attention tier** by default (an idle hero has a higher
potential-cost than an idle regular). The web-monitor push gains a `PushKind.hero` and a distinct
glyph in the notification title/payload (`"kind":"hero"`), so on your phone it's immediately clear
a *hero* is waiting, not routine work. Reuses the existing bell/attention + push plumbing; no new
delivery mechanism.

**Routing:** the hero verdict rides the EXISTING `.ghosttyAgentNeedsAttention` path — when a
surface enters `.waiting`, `AgentDashboardController.postNeedsAttention` reads the stored
`queueHero` annotation and adds `AgentStateUserInfoKey.hero: Bool` to the userInfo;
`WebPushManager`'s observer calls `onHero` (⭐, `kind:"hero"`, independent debounce) when that
flag is true, else `onAttention` (🔔). No new notification or delivery mechanism. The push title
glyph + payload `kind` are built by the pure, unit-tested `WebPushManager.pushTitle` /
`pushPayload` seams.

## Non-goals

- **No engine-modeled phases.** Research → design → build → review structure lives in the agent
  definition + issue description, not the supervisor.
- **No new push/notification transport** — reuse bell/attention + Web Push.
- ~~**Demote does not re-pack** a split into a grid.~~ **Reversed:** demote now DOES re-pack the
  split back into the run's grid (see Interaction §3) — leaving it in the hero's dedicated tab
  stranded a plain regular there.

## Implementation wiring (by layer)

**Zig core:** `src/config/Config.zig` (`agent-queue-hero-max` field + doc + cval),
`macos/Sources/Ghostty/Ghostty.Config.swift` (`agentQueueHeroMax` getter — non-optional read,
like the `agentQueueMaxTotal` fix), `AgentManagerController.swift` (`GHOSTTY_AGENT_QUEUE_HERO_MAX`
forward in `applyAgentQueueEnv`).

**Sidecar (TypeScript, `macos/agent-manager/src/`):** `queue/types.ts` (`WorkItem.hero`,
`Assignment.hero`, `heroField` on the list spec, `BlockReason`), `queue/provider.ts`
(parse `heroField`), `queue/runner.ts` + `queue/supervisor.ts` (two-pool dispatch accounting,
`heroActiveGlobal`, keep-forces-hero close gate, hero dispatch into own tab, `runPromote`/
`runDemote` side effects, persistence/rehydrate hero bit), `queue/commands.ts` (`promote`/`demote`
cases + `ApplyResult`), `queue/status.ts` (`heroMax`/`heroActive` + per-item `blockReasons`),
`mcp.ts` (`coerceQueueCommands` whitelist + carry `surfaceUUID`; `list_surfaces` hero read-back),
`index.ts` (pass hero cap + global hero-active bookkeeping).

**Swift (`macos/Sources/Features/`):** `MCP/QueueCommandBridge.swift` (`.promote`/`.demote` +
`jsonObject`), `MCP/MCPAnnotation.swift` (`hero` arg parse), the `AgentAnnotation` value type
(`queueHero` field + `merging`), `MCP/MCPLayout.swift` (`SurfaceRow.hero` + emit in
`surfacesJSONData`; hero dispatch/eject helpers), `AgentDashboard/AgentDashboardController.swift`
(`promoteToHero`/`demoteFromHero`, `HookSnapshotEntry.queueHero`, eject-to-tab),
`AgentDashboard/AgentPreviewTile.swift` + `AgentDashboardView.swift` (Promote/Demote buttons +
hero tile visual), `AgentDashboard/QueueBacklogCanvas.swift` (hero-waiting icon + tooltip),
`Terminal/Window Styles/TerminalWindow.swift` + `TitlebarTabsVenturaTerminalWindow.swift`
+ `Terminal/TerminalController.swift` (`surfaceIsHero` + hero accessory), `WebMonitor/
WebMonitorPush.swift` (`PushKind.hero` + `onHero` + pure `pushTitle`/`pushPayload` seams;
`AgentDashboardController.postNeedsAttention` adds `AgentStateUserInfoKey.hero` so the observer
routes to `onHero`).

## Tests

- **Zig:** `agent-queue-hero-max` parse/default/round-trip in `src/config/Config.zig`.
- **Sidecar:** two-pool dispatch accounting (hero concurrency off the grid; `maxItems` shared),
  promotion-over-cap-never-blocks + drain, demote re-enters regular pool, keep-forces-hero close
  gate, `heroField` parse, `promote`/`demote` `applyCommand` + coerce whitelist,
  `blockReasons`/`heroMax`/`heroActive` in the report, persistence/rehydrate of the hero bit.
- **Swift:** `QueueCommandBridge` promote/demote round-trip, `MCPAnnotation` `hero` parse +
  `AgentAnnotation.merging`, `SurfaceRow`→`surfacesJSONData` hero emit, backlog hero-waiting
  icon + tooltip reason set, and `surfaceIsHero`→accessory visibility.

## Docs to keep in sync (BLOCKING per CLAUDE.md)

`CLAUDE.md` (new Hero-agents summary bullet + `agent-queue-hero-max` in the fork-only-keys list),
`AGENT-QUEUE.md` (hero pool/accounting/commands/backlog), `AGENT-DASHBOARD.md` (hero tile visual +
promote/demote), `AGENT-MANAGER.md` (env flag forward), `WEB-MONITOR.md` (hero push glyph),
`MCP-SERVER.md` (if the tool/annotation surface changes), `example/ghostty-ramon/config` +
`ForkSetup.seedTemplate` (document `agent-queue-hero-max`; keep sanitized).

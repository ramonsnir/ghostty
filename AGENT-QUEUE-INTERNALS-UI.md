# Agent Queue — implementation notes, part 2: layout, dashboard & live controls

The load-bearing facts for an agent working on the Agent Queue Supervisor code (part 2 of 3): grid/layout
(balanced BSP + overflow + compact re-tile + `packMove`), exit/close paths, the MCP tools, dashboard
grouping + health bar + count dropdowns + backlog dependency graph, the quiescent close-gate, KEEP, and the
live maxItems/concurrency edits. Engine / dispatch / config / adopt internals are in
**`AGENT-QUEUE-INTERNALS.md`**; operational hardening (throttling, run identity, restart + schedules,
multi-host) in **`AGENT-QUEUE-INTERNALS-OPS.md`**. User-facing behavior is in **`AGENT-QUEUE.md`**. The local
design + review ledger is `scratchpad/agent-queue-design.md` (paths in the iteration worktree).

### GRID layout — balanced BSP + multi-tab overflow (§12)

- **GRID = BALANCED BSP, GUI-placed, MULTI-TAB OVERFLOW (§12).** Up to `cols×rows` panes PER TAB;
  OVERFLOWS to more tabs in the run's window when `concurrency` exceeds one tab (concurrency 9 + 3×2 grid
  = 6 in tab 1 + 3 in tab 2; 18 fills three tabs). `grid.ts` is pure OCCUPANCY ACCOUNTING: slots are ints
  in `[0, concurrency)`, slot `i` in tab `floor(i / capPerTab)` (`tabIndexForSlot`); `lowestFreeSlot`
  fills the lowest tab first (reuses a closed hole first). `splitPlan(occupied, newSlot, capPerTab)` →
  `firstTab` | `{newTab, windowAnchorSlotIndex}` (first pane of a fresh overflow tab, anchored on a live
  pane so all the run's tabs share ONE window) | `{balanced, anchorSlotIndex}` (split within the target
  slot's tab, anchored at that tab's lowest occupied slot).
- Tiling is a balanced BSP GUI-side: `spawn_split_command` `balanced:true` splits the LARGEST pane in the
  run's tab along its longer side (`SplitTree.largestLeafSplit(within: realPixelBounds)` — wider/square →
  `.right`, taller → `.down`). **Why BSP, not slot-neighbor planning:** Ghostty's binary tree RE-FLOWS
  when a pane closes (sibling absorbs the parent region), so a slot→neighbor planner diverges after any
  finish → stray extra columns/rows; BSP places from the REAL tree and self-heals across closures.
- **CRITICAL:** `largestLeafSplit` MUST use real pixel `bounds` — `spatial()`'s no-bounds fallback uses
  1×1 units where every leaf looks square → always `.right` → one row of N columns. Scoped per-TAB (each
  tab is its own `TerminalController.surfaceTree`). `cols×rows` = per-tab cap; `concurrency` = TOTAL, may
  exceed it, clamped to `cols×rows × MAX_QUEUE_TABS` (8). Template `grid.fill`/col-vs-row is IGNORED (only
  `cols*rows`). `remainingSlots` = `min(concurrency − active, global)` (grid no longer a term).
- Wiring: sidecar `grid.ts` (`tabIndexForSlot` + tab-aware `splitPlan` + `MAX_QUEUE_TABS`), `runner.ts`
  (`dispatchOne` 3-case spawn firstTab/newTab+windowAnchorUUID/balanced+targetUUID; `effectiveConcurrency`
  clamp), `supervisor.ts` (`remainingSlots`), `templates.ts` (`clampConcurrency` → `[1, cap*MAX_QUEUE_TABS]`),
  `mcp.ts` (`spawnSplitCommand` `windowAnchorUUID`); Swift `SplitTree.swift` (`largestLeafSplit(within:)`),
  `MCPLayout.swift` (balanced + `windowAnchorUUID`), `MCPTools.swift` (`spawn_split_command`
  `balanced`+`windowAnchorUUID` schema; direction required only when NOT balanced). Tests: sidecar
  `grid.test.ts` (cap/`lowestFreeSlot`/`tabIndexForSlot`/`splitPlan` firstTab/newTab-overflow/balanced),
  `runner.test.ts` (refill balanced+anchor; concurrency>grid OVERFLOWS), `supervisor.test.ts`,
  `templates.test.ts` (clamp); Swift `SplitTreeTests` (`largestLeafSplit*`: empty/single-aspect/2-col-down/
  biggest-pane/zero-bounds). **GUI relaunch + rebuilt sidecar `dist`; no host/Zig change.**

### GRID-CONSTRAINED BSP — never exceed cols columns / rows rows (§12)

- **GRID CAP (§12) — the BSP RESPECTS the template grid SHAPE, not just `cols×rows` as a pane cap.** Was
  grid-BLIND: on an ultrawide a 4th pane tiled as a 4th COLUMN even with `grid:{cols:3, rows:2}`. Now
  `grid.cols`/`grid.rows` are HARD CAPS: at `cols` columns further splits STACK into rows, at `rows` rows
  they ADD columns. Structural only, in the macOS Swift spatial layer — **no Zig/host/protocol change**.
- **Algorithm** (`SplitTree.largestLeafSplit(within:maxCols:maxRows:)`): pick the LARGEST-area leaf that
  can split WITHIN caps; prefer longer-side but force `.down` if `.right` would exceed `maxCols`, `.right`
  if `.down` would exceed `maxRows`. A leaf whose ROW BAND has `cols` columns AND COLUMN BAND has `rows`
  rows is "both-capped" and SKIPPED (walking down by area) — keeps the 3×2 ultrawide case from inserting a
  forbidden 4th column (the largest-area leaf can be both-capped). No splittable leaf ⇒ fall back to
  largest-leaf + aspect (defensive; the per-tab cap spills to a new tab first). **Band counting:** columns
  in a row band = DISTINCT `minX` (epsilon-deduped, 0.5px) among slots whose Y overlaps; rows in a column
  band = distinct `minY` among leaves whose X overlaps. Leading-edge (`minX`/`minY`) keying is robust
  because BSP leaves share exact leading edges within a row/column.
- **BACK-COMPAT byte-identical:** `maxCols`/`maxRows` ≤ 0 (or absent) short-circuit to the pure-aspect
  rule; the no-arg `largestLeafSplit(within:)` is a wrapper delegating `maxCols:0,maxRows:0`. MCP schema
  fields OPTIONAL; dispatch reads via `(NSNumber).intValue` keeping only positive (malformed → no-cap,
  never errors); sidecar sends only when positive.
- **Threading:** template `grid.cols/rows` → `runner.ts` `dispatchOne` (balanced) / `packRun` → `mcp.ts`
  `spawnSplitCommand`/`moveSurfaceIntoTab` (`maxCols?`/`maxRows?`, wired only >0) → wire OPTIONAL caps →
  `MCPTools.swift` (`positiveInt` parse) → `MCPLayout.newSplitCommand`/`moveSurfaceIntoTab` →
  `BaseTerminalController.moveSurfaceIntoThisTab` → `largestLeafSplit(within:maxCols:maxRows:)`.
  `firstTab`/`newTab` spawn branches do NOT pass caps (a fresh tab's first leaf has no grid context); the
  PACKING path DOES (packing a fragmented run must not re-introduce a 4th column). Wiring: Swift
  `SplitTree.swift`, `MCPLayout.swift`, `BaseTerminalController.swift`, `MCPTools.swift`; sidecar `mcp.ts`,
  `runner.ts`. Tests: Swift `SplitTreeTests` (`grid*`: back-compat==aspect, ultrawide 3rd/4th/5th,
  both-capped-leaf-skipped, every-leaf-capped fallback); sidecar `runner.test.ts` (balanced+pack forward
  caps), `mcp.test.ts` (positive-only), `grid.test.ts` (`gridCap == cols*rows`). **GUI relaunch + rebuilt
  sidecar `dist`; no host/Zig change.**

### COMPACT re-tile — 4 panes settle as 2×2, not 3-columns-plus-one (§12)

- **Problem.** `largestLeafSplit` places ONE pane at a time and the split tree is APPEND-ONLY. Once 3 panes
  are a row of 3, a 4th can only split a column → "3 columns, one stacked", never a 2×2. BOTH "3 → 3 columns"
  AND "4 → 2×2" is impossible without MOVING a pane — the append-only tree provably can't reach 2×2 from a
  3-column row by adding one leaf.
- **Fix — rebuild the WHOLE tab into the most compact grid on each expansion.** After a queue dispatch OR
  move (adopt / demote-repack / `packMove`) lands a pane in a grid tab, re-tile to the compact grid for its
  new count. Shapes (default 3-col cap): `2→[2]`, `3→[3]`, **`4→[2,2]`**, `5→[3,2]`, `6→[3,3]`, `7→[3,2,2]`
  (row-major, front-loaded — missing cell bottom-right). This DOES reshuffle live panes when the count
  crosses a boundary (the 4th moves the 3rd down into a new row) — the chosen tradeoff.
- **Math** (`SplitTree.compactGridRowCounts(count:maxCols:maxRows:)`, PURE): `rows = ceil(count/maxCols)`,
  balanced front-loaded (`base = count/rows`, first `count % rows` rows get `base+1`). `maxCols ≤ 0` ⇒ one
  unbounded row; `maxRows > 0` caps rows (defensive).
- **Rebuild** (`SplitTree.compactGrid(leaves:maxCols:maxRows:)`, PURE): slice ordered leaves row-major per
  the row counts, each row an equal-width left→right chain, rows stacked as equal-height bands, all via
  `equalChain` (each split's `ratio = 1/n`, first child top/left — the `SplitView`/`spatialSlots` convention;
  ⚠️ NOT the inverted Y-up `calculateViewBounds` convention). REUSES the same `SurfaceView` leaves — only
  tree position changes — so `BaseTerminalController.retile` installs via `replaceSurfaceTree` (pane never
  recreated; its `.client` mirror/PTY untouched). Leaf order preserved (`Array(tree) == input`), so re-tiling
  from `leaves()` with the new pane appended LAST is stable + idempotent.
- **Wiring / scope.** `MCPLayout.newSplitCommand` (balanced arm): capture leaf order BEFORE the split, then
  `controller.retileCompactGrid(order: before + [newView], focus: newView, …)`.
  `BaseTerminalController.moveSurfaceIntoThisTab`: `retileCompactGrid(order: existing.filter{≠source} +
  [source], focus: nil, …)`. `retileCompactGrid` NO-OPs unless a cap is set (`maxCols>0||maxRows>0`, so a
  plain user split is NEVER reshuffled), ≤1 pane, or if `order` doesn't exactly cover the tab's current
  leaves (a same-set guard so a pane can't be dropped/duplicated). **CONTRACTION (finish → auto-close) is
  intentionally LEFT to Ghostty's binary-tree reflow.** Pure Swift; **no Zig/host/protocol/sidecar
  change**. Wiring: `SplitTree.swift` (`compactGridRowCounts` + `compactGrid` + `equalChain`),
  `BaseTerminalController.swift` (`retileCompactGrid`), `MCPLayout.swift`. Tests: `SplitTreeTests`
  (`compactGrid*`: row-count spec 1–9, 4→2×2 quadrants, 5→3-over-2, row-major preserved, idempotent).
  **GUI relaunch only; no host restart.**

### Continuous packing — `packMove` (§12)

- **CONTINUOUS PACKING (§12) — consolidate fragmented tabs by MOVING panes.** Each healthy sweep (after
  close, BEFORE dispatch) compute ONE merge via pure `packMove(occupied, capPerTab)` — the HIGHEST
  non-empty tab whose panes ALL fit the free space of the LEFTMOST earlier tab — and MOVE that tab's panes
  there, closing the emptied source. One merge per sweep CONVERGES to the fewest tabs without reshuffling a
  balanced layout: `4+4` / `5+2` (cap 6) never move; `3+1+1` packs to one over two sweeps (no hard-coded
  numbers — everything derives from `capPerTab` + occupancy). The move is a FOCUS-PRESERVING cross-tab
  relocation reusing Ghostty's drag-and-drop primitive (`surfaceTree.inserting` on dest +
  `removeSurfaceNode` on source), so it never steals focus/raises a window; a moved pane's `gridSlot` is
  reassigned to the target tab's range. SAFE-DEFERS: if any source pane is unseated (no `surfaceUUID`) the
  WHOLE merge defers (never a half-move); a failed move stops the sweep. Runs only on the dispatch-eligible
  gate (armed, not disabled/paused/draining). Wiring: sidecar `grid.ts` (`packMove` + `PackMove`),
  `runner.ts` (`packRun` exported; `seatedAtSlot`; called in `runOne` before `dispatchCandidates`), `mcp.ts`
  (`moveSurfaceIntoTab`); Swift `BaseTerminalController.moveSurfaceIntoThisTab(source:balanced:)`,
  `MCPLayout.moveSurfaceIntoTab(sourceUUID:targetAnchorUUID:balanced:)`, `MCPTools.swift`
  (`move_surface_into_tab` — now 20 tools). Tests: sidecar `grid.test.ts` (`packMove`: 3+1+1 merge / 4+4 +
  5+2 no-reshuffle / full-tab-skip / hole reuse / multi-pane), `runner.test.ts` (`packRun` moves + reassigns
  slot / single+balanced no-op / defers-when-unseated), `mcp.test.ts`; Swift `MCPServerTests`
  (`toolsListHasAllTools` now 20). **GUI relaunch + rebuilt sidecar `dist`; no host/Zig change.**

### Exit forms (template knob)

- **Exit forms (template knob):** `agent.exit` supports a TYPED exit (`{text:"/quit"}` → send_text + Enter;
  `submit:false` skips Enter) AND/OR control `{keys:[…]}` — DEFAULT `["ctrl-d"]`. ⚠️ NOTE the hyphen form:
  the MCP `send_key` tool only recognizes hyphenated names (`ctrl-d`/`ctrl-c`/`enter`/…) — a
  non-hyphenated `"ctrl_d"` silently no-ops. Claude Code swallows Ctrl-D, so use `{text:"/quit"}`. The close
  sequence is sendText/sendKey-prelude → `awaitExited` (bounded; force-closes anyway on timeout, so a
  `/quit` that leaves the launching shell alive still tears down) → forceClose. **There is no
  `quitWhenEmpty`** — a run is removed only by explicit stop/abort.

### Close path — `force_close_surface` (§10)

- **Close path (§10) — the subtle one:** `close_surface`/`request_close` HONORS `confirm-close-surface` and
  would pop a modal for a live agent. So the supervisor sends the template `agent.exit` prelude then calls
  **`force_close_surface`**, which routes a LAST/ONLY-pane (tree-root) close to the confirm-FREE
  `closeTabImmediately()`/`closeWindowImmediately()` (NOT `closeTab`/`closeWindow`, which re-check
  `needsConfirmQuit`) — `TerminalController.closeSurface` override. `onAgentExit: leave-and-bell` keeps a
  crashed split for review + rings the bell everywhere via **`signal_attention`** (posts
  `.ghosttyBellDidRing` with the SurfaceView as `object`, so the dashboard aggregate + web monitor + push
  all fire), and FREES the slot (no deadlock).

### New MCP tools (the engine's "hands")

- **New MCP tools (Swift, the engine's "hands"):** `spawn_split_command` (opens the run's first tab or
  splits a target surface running a command, returns `{id, sessionId}` — `MCPLayout.newSplitCommand` reads
  the leaf's UUID + `ghostty_surface_session_id` back as VALUE types on the main hop),
  `force_close_surface`, `signal_attention`, `take_queue_commands`, plus `sessionID` on `list_surfaces`
  rows and queue annotation fields (`queueKey`/`queueName`/`queueUrl`, partial-merge). No host/Zig protocol
  change — only 4 additive config keys (`agent-queue`, `agent-queue-templates-dir`, `agent-queue-max-total`
  — default-off — plus default-*on* `agent-queue-hero-max`, see `AGENT-QUEUE-INTERNALS.md`) + the
  `start_agent_queue` action.

### Dashboard — grouping / filtering / controls (§11)

- **Dashboard** (§11): tiles **grouped by origin** (queue name, or `(other)`), per-tile origin **marker**, a
  top **filter bar** (include/exclude origins, persisted; VIEW-only — an excluded ringing/waiting agent
  still alerts), per-queue Pause/Stop/Abort header buttons (post `.ghosttyQueueCommand`). Start via
  `start_agent_queue` (+ `:template-name`) → `QueuePalette` (mirrors `ProjectPalette`) → a `start` command.
  Feature-wide wiring (see each section below for specifics): sidecar `src/queue/*`; Swift `Features/MCP/*`
  (`MCPLayout`/`MCPTools`/`MCPServer`/`MCPAnnotation`/`MCPQueueCommands`/`QueueCommandBridge`),
  `AgentDashboard/*` (`AgentDashboardController`/`View`/`PreviewTile`/`AgentStateBridge`),
  `Command Palette/QueuePalette.swift`, `Terminal/{TerminalController,BaseTerminalController,TerminalView}.swift`,
  `Ghostty/{Ghostty.App,Ghostty.Config}.swift`; core `src/config/Config.zig` + `src/input/{Binding,command}.zig`
  + `src/apprt/action.zig` + `src/Surface.zig`. Tests: sidecar `node --test` (337+), Swift
  `MCPServerTests`/`MCPAnnotationTests`/`AgentDashboardTests`/`QueuePaletteTests`, Zig `agent-queue` config +
  `start_agent_queue` binding. **GUI relaunch + rebuilt sidecar `dist`; no host restart.**

### Per-tile CLOSE button (wedged-slot escape hatch)

- **Per-tile CLOSE button (GUI-only, queue tiles only) — the wedged-slot escape hatch.** On hover each tile
  shows the existing **Hide** (`eye.slash`; view-only, split keeps running) and, ONLY on a **queue-owned**
  tile (carrying a `queueName` annotation), a red **`xmark.octagon`** Close that **force-closes** the split
  (ends the agent + frees the slot; the surface vanishing lets the next sweep reconcile + prune). Routes
  through the confirm-FREE `MCPLayout.forceClose` (same path as auto-close), so it works on a live agent
  without the `confirm-close-surface` modal — gated behind a confirmation dialog (no undo). The manual
  remedy when auto-close is wedged (e.g. a stuck-`working` hook). Wiring: `AgentPreviewTile.swift`
  (`isQueueOwned` = `entry.annotation?.queueName` non-empty + `onClose` + `confirmationDialog`),
  `AgentDashboardController.swift` (`AgentDashboardModel.closeSurface(_:)` → `MCPLayout.forceClose`),
  `AgentDashboardView.swift` (`onClose:`). Tests: `AgentDashboardTests` (`capDraft*` neighborhood; the
  button + gating are SwiftUI, not unit-tested). **GUI-only, GUI relaunch; no sidecar/host/Zig change.**

### QUEUE HEALTH bar (§11)

- **QUEUE HEALTH bar (§11, sidecar→GUI push).** Each running queue's health shows in its section header —
  even before any split spawns and even when every tile is hidden/filtered (the "scary blank at start" +
  "all hidden" fixes). The supervisor PUSHES a snapshot EVERY 5s sweep (incl. the dispatch-suppressed arm
  sweep) via **`report_queue_status`**: `{queueName, present, phase, queued, listOk, active, dispatched,
  maxItems|null, next:[{key,title?}]}`. Header = a phase chip (starting/running/paused/draining/disabled) +
  `QueueHealthFormat.healthText` ("N waiting · M running · dispatched/cap", ∞=unlimited so a reached
  `maxItems` like `1/1` is obvious) + "next: KEY,…". **`present:false`** (on drain/abort/quit) clears the
  section. Show-with-no-tiles: `AgentDashboardModel.groupByOrigin` gained a `presentQueues` param injecting
  an EMPTY section for a present queue with no visible entries; `sections` passes the (filter-minus)
  `queueStatuses` keys; `content` falls through to the sectioned list whenever `queueStatuses` is non-empty.
  ⚠️ The ~170s "one item then a delay" was NOT serialization — the engine dispatches up to
  min(concurrency, grid, maxTotal, maxItemsRemaining) per sweep; the gap was the 2nd item only becoming
  actionable in the `list` later. Sidecar wiring: `status.ts` (pure `queueStatusReport` +
  `QueueStatusReport`), `runner.ts` (`lastListItems`/`lastListOk` cache + `effectiveMaxItemsCap` +
  `reportQueueStatus`/`reportRunGone` each sweep, single funnel so the report ALWAYS fires), `mcp.ts`.
  Swift: `QueueCommandBridge.swift` (`QueueStatus` + `QueueStatusPayload.fromArguments` +
  `.ghosttyQueueStatusDidChange` + `MCPServer.applyQueueStatus`), `MCPTools.swift` (schema + dispatch),
  `AgentDashboardController.swift` (`queueStatuses` @Published + `applyQueueStatus` + `subscribeQueueStatus`
  + `groupByOrigin(presentQueues:)` + `sections`), `AgentDashboardView.swift` (`OriginSectionHeader` +
  `QueueHealthFormat` + `content` fall-through). Tests: sidecar `status.test.ts` + `mcp.test.ts` +
  `runner.test.ts` (sweep reports starting→counts); Swift `MCPServerTests` (`queueStatusPayload*`,
  `toolsListHasAllTools` now 18) + `AgentDashboardTests` (`AgentQueueHealthTests`: apply/clear,
  empty-section grouping, `healthText`). **GUI relaunch + rebuilt sidecar `dist`; no host/Zig change.**

#### Clickable count DROPDOWNS

- **Clickable count DROPDOWNS (mirrors the hidden-agents popover).** The "N waiting"/"M running" counts are
  buttons opening a popover listing those items with **Linear links** (key badge · title · `Link` for
  http(s) urls; "… and N more" when the waiting list is capped). The report carries per-item DETAIL:
  `QueueStatusReport.next` items gained `url`, plus a new `running: QueueItemRef[]` (key/title/url per
  slot-occupying agent) — `runner.ts reportQueueStatus` builds `runningItems` from active assignments
  (title/url captured at dispatch) and sends `nextLimit:25`; the pure builder's `active` is now
  `runningItems.length`. Swift: `QueueStatus.Item` (was `NextItem`, +`url`, `Identifiable`) + `running:
  [Item]`, parsed by a shared `items(_:)` helper in `QueueStatusPayload`; `report_queue_status` schema gains
  `url` on next + a `running` array; `OriginSectionHeader` renders `countButton`→`itemsPopover` (`Link` via
  `itemLink`, http(s)-gated like `queueURLLink`) and `QueueHealthFormat` swapped `healthText`→`progressText`
  (just the "dispatched/cap" suffix). Tests: sidecar `status.test.ts` (next url + running echo) +
  `mcp.test.ts` (running forward); Swift `MCPServerTests` (parse url+running) + `AgentDashboardTests`
  (`progressText`, `applyKeepsNextAndRunningItems`). **GUI relaunch + rebuilt sidecar `dist`.**

#### BACKLOG DEPENDENCY GRAPH

- **BACKLOG DEPENDENCY GRAPH (the "N backlog" button → DAG canvas; sidecar→GUI push).** The button opens a
  resizable window rendering the run's WHOLE board (every state) as a left→right layered dependency graph
  (columns by blocked-by depth, "blocked by" arrows, cards colored by workflow-state category with label
  chips, green ring on running, click→jump-to-split or open the tracker URL). Needs a NEW OPTIONAL
  `provider.graph` command (sibling of `list`/`status`; absent ⇒ no button) — SEPARATE from `list` because
  `list` must stay "actionable-only" (it drives dispatch). Fetched on the SAME cadence as `list`
  (`intervals.listMs`, reusing a `lastGraphAtMs` throttle), INDEPENDENT of dispatch (runs while
  paused/draining, skipped only when `disabled`), cached on `QueueRun.lastGraph`, PUSHED via
  **`report_queue_graph`** (`{queueName,present,backlog,nodes[]}`; `present:false` on removal, alongside
  `reportRunGone`).
- `backlog` = non-terminal nodes NOT waiting/running AND NOT in-progress (`backlogCount`, pure — exclude =
  actionable-list keys ∪ active assignment keys, plus any node whose `stateType` is in
  `IN_PROGRESS_STATE_TYPES` = {`started`}). The in-progress exclusion fixes "2 backlog but only 1
  schedulable" (an In-Progress issue is non-terminal and not in the Todo `list`, so it WOULD have counted).
  Still RENDERED (blue node) — only the badge drops it; absent/unknown `stateType` still counts (safe
  default). STAYS GENERIC: `done` (terminal, excluded+dimmed) and `stateType` (color category) are
  PROVIDER-decided; `QueueBacklogColors` is a cosmetic category→color map with a neutral fallback.
- Layout `QueueBacklogLayout.assignLayers` is longest-path-from-roots, cycle-safe (`resolving` guard),
  ignores out-of-scope edges. **CROSSING REDUCTION:** `QueueBacklogLayout.orderedColumns` runs Sugiyama
  crossing-reduction (alternating down/up MEDIAN sweeps over `blockedBy`), keeping the ordering with FEWEST
  crossings (never worse than the seed; pure + deterministic, tie-break by current row); metric
  `QueueBacklogLayout.crossingCount` (adjacent-column bipartite inversions over every column pair so
  skip-layer edges count). The view **vertically centers a short column** within the tallest (`centersByKey`;
  board height unchanged, so fit-to-content sizing is unaffected). `columns` (raw, by-layer) is kept for
  geometry sizing. Canvas window is one-per-run via `QueueBacklogWindowManager` (MainActor; strong ref +
  `willClose` observer dropping window and itself — no leak/double-open). DEFAULT size is fit-to-content,
  floored + CLAMPED to the display via `QueueBacklogGeometry.preferredWindowSize(nodes)` +
  `QueueBacklogWindowManager.defaultContentSize(nodes:screen:)` (floors at `minContentSize` 480×360, clamps to
  `screen − screenMargin`; both pure + unit-tested).
- Wiring: sidecar `types.ts` (`ProviderGraphSpec`/`GraphNode`/`QueueGraph`), `provider.ts`
  (`parseGraphOutput`/`fetchGraphResult`), `status.ts` (`QueueGraphReport`/`backlogCount`), `templates.ts`
  (`validateProviderGraph`), `runner.ts` (`QueueRun.lastGraph`/`lastGraphAtMs` + `refreshGraph`/
  `reportGraphGone`), `mcp.ts` (`reportQueueGraph`); Swift `QueueCommandBridge.swift`
  (`QueueGraph`/`QueueGraphPayload`/`applyQueueGraph`), `MCPTools.swift` (`report_queue_graph` — now 19
  tools), `AgentDashboardController.swift` (`queueGraphs` + `applyQueueGraph` + `subscribeQueueGraph`),
  `AgentDashboardView.swift` (`backlogButton`), `AgentDashboard/QueueBacklogCanvas.swift` (layout + canvas +
  window mgr; iOS-excluded in `project.pbxproj`). Config (untracked, Linear-specific): `example-graph.py`
  (emits the FUTURE board — non-terminal issues + labels + blockedBy + stateType; drops "blocked by" edges to
  done blockers) + `provider.graph` in `example.json`. Tests: sidecar `provider.test.ts`, `status.test.ts`
  (`backlogCount`), `templates.test.ts`, `mcp.test.ts`, `runner.test.ts` (graph throttled + push +
  present:false-on-abort); Swift `MCPServerTests` (`queueGraphPayload*`, tool count 19), `AgentDashboardTests`
  (`QueueBacklogTests`: `assignLayers` chain/diamond/cycle/dangling + `crossingCount`/`orderedColumns`
  reduces-crossings/never-worse/deterministic). **GUI relaunch + rebuilt sidecar `dist`; no host/Zig change.**

- **`blockedLabels` — the "Blocked on:" tooltip lists only BLOCKING labels, not every label (fixed
  2026-07-08).** A node's `labels[]` is the FULL display set (pills), a MIX of gating markers and
  informational tags. `NodeCard.cardHelp` (`QueueBacklogCanvas.swift`) used to list EVERY label under
  "Blocked on:", so an informational tag read as a bogus blocking reason. Fix: a new OPTIONAL
  `GraphNode.blockedLabels?: string[]` carries the SUBSET that blocks; the tooltip uses `node.blockedLabels
  ?? node.labels`. Three-way distinction is load-bearing: **absent** ⇒ `nil`/`undefined` → fall back to
  `labels` (legacy); **present-but-empty** ⇒ `[]` → NO blocking reason; **present** ⇒ that subset.
  `parseGraphOutput` (TS) sets it only when `rec.blockedLabels` is an array; `QueueGraphPayload.fromArguments`
  (Swift) maps `nil` when absent (deliberately NOT the `[]`-defaulting `strings` helper). Provider decides
  which labels block (GENERIC, like `done`/`stateType`/`priorityLabel`); the Linear `example-graph.py` emits the
  `" needed"`-suffix labels (mirroring the `list` provider's `has_blocking_label`). Wiring: sidecar
  `types.ts` (`GraphNode.blockedLabels?`), `provider.ts` (present-only parse); Swift `QueueCommandBridge.swift`
  (`QueueGraph.Node.blockedLabels: [String]?` + absent-vs-empty parse), `QueueBacklogCanvas.swift`
  (`cardHelp`). Tests: sidecar `provider.test.ts` (`blockedLabels carried only when present…`), Swift
  `MCPServerTests` (`queueGraphPayloadBlockedLabelsAbsentVsEmptyVsPresent`). **GUI relaunch + rebuilt sidecar
  `dist`; no host/Zig change.**

#### HIGH/URGENT PRIORITY MARK on backlog nodes

- **HIGH/URGENT PRIORITY MARK on backlog nodes (generic; provider-decided).** A node can carry an OPTIONAL
  generic `priorityLabel` string; the canvas renders any node with one with a filled badge in the title row
  + a louder TINTED BORDER (2pt) (running's green border still wins; a `done` node keeps its dim, no loud
  border). STAYS GENERIC like `done`/`stateType`: the PROVIDER SCRIPT decides which items get a mark —
  Ghostty NEVER interprets the tracker's numeric `priority` int, only renders the word in `priorityLabel`.
  Color from a generic vocabulary (`QueueBacklogColors.priorityColor`: urgent/critical→red, high→orange,
  medium/med/normal→yellow, low→gray) with an ACCENT fallback so an unknown-but-non-empty label still reads
  as "marked"; nil/empty ⇒ no mark. Linear conversion in `example-graph.py` (`PRIORITY_LABELS = {1:"Urgent",
  2:"High"}`, emitted only for those). ⚠️ Do NOT use the raw `priority` int (tracker-specific footgun); for
  numeric ordering add a generic `priorityRank`, not the raw int. Wiring: sidecar `types.ts`
  (`GraphNode.priorityLabel`), `provider.ts` (keeps a non-empty string; `mcp.ts` forwards `nodes` verbatim);
  Swift `MCPTools.swift` (`report_queue_graph` node schema + `priorityLabel`), `QueueCommandBridge.swift`
  (`QueueGraph.Node.priorityLabel` + parse), `QueueBacklogCanvas.swift` (badge + tinted border +
  `QueueBacklogColors.priorityColor`). Config: `example-graph.py`. Tests: sidecar `provider.test.ts`
  (round-trip + non-empty rule); Swift `MCPServerTests` (`queueGraphPayloadParsesFullArgs`),
  `AgentDashboardTests` (`priorityColorMarksKnownAndUnknownButNotEmpty`). **GUI relaunch + rebuilt sidecar
  `dist`; no host/Zig change.**

### Close-gate fires on QUIESCENT (idle OR waiting)

- **CLOSE-GATE fires on QUIESCENT (idle OR waiting), not idle-only (sidecar-only fix).** The
  DONE_PENDING→CLOSING gate used to require `agentState==="idle"` held `closeStableSeconds`. But a finished
  Claude Code agent reliably settles in **`waiting`** (its `Stop`→idle hook is immediately overwritten by a
  `Notification` "waiting for input" nudge), so an idle-ONLY gate NEVER fired (real stuck case: EX-1446 sat
  DONE_PENDING with status=Done, agentState=waiting, forever). Fix: a pure `isQuiescent(agentState)` = `idle
  || waiting`; `supervisor.ts` `nextState` gates on `isQuiescent`, and `foldIdleAnchor` anchors on EITHER
  state AND **keeps the anchor across an idle↔waiting transition** (only `working`/`undefined` resets) — so
  the `Stop`→`Notification` flip keeps the close clock running. Status-only completion unchanged. Tests:
  `supervisor.test.ts` (close-on-waiting-held, `foldIdleAnchor` anchors-on-waiting +
  keeps-anchor-across-transition). **Sidecar-only — rebuilt `dist` + sidecar restart; no GUI/host/Zig
  change.**

### KEEP — exempt a split from auto-close (manual work after Done)

- **KEEP a split open for manual work** — a per-split toggle (dashboard **📌 pin**) + a template default
  (`keepOnComplete`) that EXEMPTS a completed split from the close gate. A kept split is HELD in
  DONE_PENDING (slot kept — same semantics as `closeOnComplete:false`), never force-closed; force-close it
  with the per-tile **Close** (`xmark.octagon`).
- **State model (mirrors the `dispatched` latch):** per-split keep is a RUN-LEVEL `QueueRun.keep: Map<key,
  boolean>` (NOT per-record — so reconcile, which rebuilds the active map every sweep, never wipes it),
  persisted in `StoreFile.keep` + rehydrated on first reconcile, cleared on abort. `effectiveKeep(run, key) =
  run.keep.get(key) ?? template.keepOnComplete`. `nextState` holds DONE_PENDING when `ctx.keep === true ||
  ctx.closeOnComplete === false` (keep suppresses BOTH the idle-hold AND the exited-short-circuit close);
  `closeOnComplete:false` stays the separate HARD never-close, `keepOnComplete:true` is the SOFT default the
  pin overrides.
- **Toggle path:** the pin posts `set_keep{run,key,keep}` (GUI→sidecar FIFO; GUI optimistically merges
  `queueKeep`). `applyCommand` set_keep sets `run.keep` + marks `run.keepDirty` (non-persisted per-sweep);
  `runOne` drains `keepDirty` → restamps the annotation immediately (belt-and-suspenders over
  `restampAnnotation`, which fires every sweep because `list_surfaces` never echoes the queueKey →
  `needsAnnotationRestamp` is always true). `set_keep` is NOT an active-runs change. The supervisor stamps
  `keep: effectiveKeep` onto the annotation (`restampAnnotation` + `dispatchOne`); the GUI reads
  `entry.annotation?.queueKeep` to draw the pin. QUEUE-tile-only (gated on `queueName`).
- Wiring: sidecar `types.ts` (`QueueTemplate.keepOnComplete`), `templates.ts`
  (`TEMPLATE_DEFAULTS.keepOnComplete` + validate), `store.ts` (`StoreFile.keep` +
  serialize/`parseKeep`/`loadKeep` + `persistStore` 5th arg), `supervisor.ts` (`NextStateContext.keep` +
  gate), `runner.ts` (`QueueRun.keep`/`keepDirty` + `effectiveKeep` + `keepRecord` + rehydrate + ctx pass +
  stamps + keepDirty drain), `commands.ts` (`set_keep` + reducer + keepDirty mark), `mcp.ts`
  (`Annotation.keep` + `setAnnotation` send + `QUEUE_ACTIONS` + `coerceQueueCommands` carry key/keep); macOS
  `QueueCommandBridge.swift` (`.setKeep` + `key`/`keep` + `jsonObject`), `AgentStateBridge.swift`
  (`AgentAnnotation.queueKeep` + merge), `MCPAnnotation.swift` (parse `keep`), `MCPTools.swift`
  (`set_surface_annotation` schema `keep`), `AgentDashboardController.swift` (`setQueueKeep` optimistic),
  `AgentDashboardView.swift` (`onKeep`), `AgentPreviewTile.swift` (`onKeep` + `isKept` + the 📌 pin). Tests:
  sidecar `supervisor.test.ts` (keep holds + suppresses exit short-circuit), `store.test.ts`,
  `commands.test.ts` (not-an-active-runs-change), `templates.test.ts`, `runner.test.ts` (pin holds + stamps +
  persists; rehydrate), `mcp.test.ts`; Swift `MCPServerTests` (`queueCommandJSONObjectSetKeep*`),
  `MCPAnnotationTests`, `AgentDashboardTests` (`setQueueKeepOptimistically*`). **GUI relaunch + rebuilt
  sidecar `dist`; no host/Zig change.**

### LIVE maxItems EDIT (§8b)

- **LIVE maxItems EDIT — change a running queue's cap from the dashboard, no restart (§8b).** A new
  `set_max_items{run,maxItems}` re-sets a LIVE run's lifetime dispatch cap without restarting it. The
  header's "dispatched/cap" suffix is **tap-to-edit** → a popover with presets (1/2/5/10/∞) + a custom
  field; the raw string is posted (the sidecar parses it, so a fat-finger never silently removes the cap).
  Bumping above `lifetimeDispatched` re-enables dispatch next sweep (`maxItemsRemaining` recomputes);
  LOWERING only stops FUTURE dispatch — running agents never killed. ⚠️ **Run-identity semantics** (UPDATED
  by per-scope-identity, below): a run is keyed by template basename + resolved scope (`identityScope`, the
  resolved provider env — see `commands.ts applyCommand`). A re-`start` with SAME basename AND scope is an
  idempotent NO-OP that ignores the second start's maxItems — so `set_max_items` is the only in-place edit;
  a DIFFERENT scope is a DISTINCT parallel run (own tab + state file).
- Engine: a mutable `QueueRun.maxItemsLive` (`undefined`=no edit, `null`=unlimited, N=cap) that
  `effectiveMaxItemsCap` consults FIRST; persisted in the active-runs record (`maxItemsLive`) so a restart
  re-applies. Shared pure `parseMaxItemsValue` (null=unlimited, N=cap, undefined=blank/garbage→ignored)
  backs both this and the start-time `resolveMaxItemsOverride`. Wiring: sidecar `templates.ts`
  (`parseMaxItemsValue`), `runner.ts` (`QueueRun.maxItemsLive` + `effectiveMaxItemsCap` + `makeQueueRun` opt
  + `activeRunRecords`), `commands.ts` (`set_max_items` + reducer + `applyCommands` change-bit), `store.ts`
  (`ActiveRunRecord.maxItemsLive` + tolerant parse), `wiring.ts` (rehydrate), `mcp.ts` (`coerceQueueCommands`
  carries `maxItems`); Swift `QueueCommandBridge.swift` (`.setMaxItems`="set_max_items" + `maxItems` +
  `jsonObject`), `AgentDashboardController.swift` (`setQueueMaxItems(run:value:)`), `AgentDashboardView.swift`
  (cap button + `capEditorPopover` + `QueueHealthFormat.capDraft`). Tests: sidecar `templates.test.ts`
  (`parseMaxItemsValue`), `commands.test.ts` (apply/unlimited/ignore-garbage/unknown-run/change-bit),
  `runner.test.ts` (live override + bump-re-enables-dispatch), `store.test.ts`, `mcp.test.ts`; Swift
  `MCPServerTests` (`queueCommandJSONObjectSetMaxItems*`), `AgentDashboardTests` (`capDraft*`). **GUI relaunch
  + rebuilt sidecar `dist`; no host/Zig change.**
- **Web monitor "+1".** The phone's Queues section reuses this path: `AgentDashboardModel.bumpQueueMaxItems`
  computes `QueueStatus.bumpedCap = max(maxItems, dispatched) + delta` from the (optimistic) status and
  calls `setQueueMaxItems` — no new command, no sidecar change (→ `WEB-MONITOR.md`, "+1 max items").

### LIVE concurrency EDIT

- **LIVE concurrency EDIT — change a running queue's max SIMULTANEOUS agents from the dashboard, no
  restart.** Mirrors live maxItems edit; `set_concurrency{run,concurrency}` (a re-`start` is a same-scope
  no-op, so this is the only in-place path). The header gets a tap-to-edit **`⇉ N` parallel chip**
  (`rectangle.split.3x1` + presets 1/2/3/4/6/9 + custom; shown once `concurrency > 0`). Engine: a mutable
  `QueueRun.concurrencyLive?: number` (`undefined`=no edit; always a positive int — NO "unlimited", an
  unbounded fan-out would spawn a pane per item). `effectiveConcurrency(run)` = `concurrencyLive ??
  template.concurrency`, CLAMPED to `[1, capPerTab*MAX_QUEUE_TABS]`. It's the run's TOTAL pane budget across
  ALL tabs — above one tab's `cols×rows` OVERFLOWS to more tabs (§12). `remainingSlots` =
  `min(effectiveConcurrency − active, global)`; `dispatchOne` allocates `lowestFreeSlot(occupied,
  effectiveConcurrency)` and `splitPlan` routes overflow to new tabs. Parsed by a pure
  `parseConcurrencyValue` (positive int only; blank/garbage/zero/negative → ignored). Persisted in the
  active-runs record (`concurrencyLive`); surfaced in the §11 report (`QueueStatusReport.concurrency` =
  effective value). GUI optimistically updates the chip (`QueueStatus.withConcurrency` +
  `parseConcurrencyOptimistic`). Lowering stops FUTURE dispatch; raising re-enables on the next list-DUE
  sweep (≤`listMs`). Wiring: sidecar `templates.ts` (`parseConcurrencyValue`), `supervisor.ts`
  (`remainingSlots` `effConcurrency` param), `runner.ts` (`QueueRun.concurrencyLive` + `effectiveConcurrency`
  clamp + dispatch gate + `reportQueueStatus`), `status.ts` (`QueueStatusReport.concurrency`), `commands.ts`
  (`set_concurrency` + reducer + change-bit), `store.ts` (`ActiveRunRecord.concurrencyLive` + tolerant
  parse), `wiring.ts` (rehydrate), `mcp.ts` (`coerceQueueCommands` + report forward); Swift
  `QueueCommandBridge.swift` (`.setConcurrency`="set_concurrency" + `concurrency` + `jsonObject`;
  `QueueStatus.concurrency` + `withConcurrency`/`parseConcurrencyOptimistic`), `MCPTools.swift`
  (`report_queue_status` schema `concurrency`), `AgentDashboardController.swift`
  (`setQueueConcurrency(run:value:)`), `AgentDashboardView.swift` (`⇉ N` chip + `concurrencyEditorPopover`).
  Tests: sidecar `templates.test.ts` (`parseConcurrencyValue`), `supervisor.test.ts`, `runner.test.ts` (clamp
  + bump-dispatches-3rd + overflow-new-tab), `commands.test.ts`, `store.test.ts`, `mcp.test.ts`,
  `status.test.ts`; Swift `MCPServerTests` (`queueCommandJSONObjectSetConcurrency*`), `AgentDashboardTests`
  (`parseConcurrencyOptimistic*` + `setQueueConcurrencyOptimistically*`). **GUI relaunch + rebuilt sidecar
  `dist`; no host/Zig change.**

### Instant command feedback

- **INSTANT command feedback (snappiness fix for ALL queue commands).** A command only reflected on the
  sidecar's NEXT health push — after the ~5s `QUEUE_POLL_INTERVAL_MS` gap AND that sweep's provider
  round-trips (since `reportQueueStatus` is the LAST step). Two-part fix: **(GUI optimistic)**
  `AgentDashboardModel.setQueueMaxItems`/`sendRunCommand` update the local `queueStatuses` entry IMMEDIATELY
  before posting — cap via `QueueStatus.parseCapOptimistic` (mirrors `parseMaxItemsValue`;
  `.none`=blank/garbage→leave as-is) + `withMaxItems`; phase via `withPhase`
  (pause→paused/resume→running/stop→draining); abort removes the section. **(Sidecar fast confirm)**
  `runQueueSweep` pushes `reportQueueStatus` for every non-aborting run IMMEDIATELY after `applyCommands` —
  BEFORE the `status`/`list` round-trips. Wiring: `QueueCommandBridge.swift`
  (`QueueStatus.withMaxItems`/`withPhase`/`parseCapOptimistic`), `AgentDashboardController.swift` (optimistic
  mutation in both posters), `runner.ts`. Tests: `AgentDashboardTests` (`parseCapOptimisticMirrorsSidecar`,
  `setQueueMaxItemsOptimisticallyUpdatesCap`, `sendRunCommandOptimisticallyUpdatesPhase`). **GUI relaunch +
  rebuilt sidecar `dist`; no host/Zig change.**


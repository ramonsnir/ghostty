# Bell Attention — two-tier, fail-open "bell vs needs-you"

Fork-only feature of **"Ghostty (ramon)"** (bundle id `com.mitchellh.ghostty-ramon`).

A terminal bell is one signal, but two very different things ring it: a *transient*
"something happened" (a build finished, a workflow launched — nothing for you to do) and
a *real* "this agent needs **you** now" (a permission prompt, a question, a rate-limit
halt). Bell Attention splits those into **two configurable tiers** and lets the Agent
Manager's Haiku classifier decide, per bell, which one you're looking at — **failing open**
so an undecided bell is always treated as real.

- **Tier 1 — `bell-features`** fires on **every** bell, immediately.
- **Tier 2 — `attention-features`** is **added** when a bell is *promoted* to "needs you".

So a promoted bell = `bell-features` ∪ `attention-features`; an ignored bell =
`bell-features` only. With the feature **off** (the default) there is only tier 1, exactly
as before.

It is **off by default**, macOS-only, and builds on the
[Agent Manager](AGENT-MANAGER.md) (the promoter), the
[Agent Dashboard](AGENT-DASHBOARD.md), and the [Web Monitor](WEB-MONITOR.md) (where the
effects land).

## The shared vocabulary

Both tiers take the same `BellFeatures` value — a comma-separated set of effect flags, each
routable to **either** tier:

| flag | effect |
|---|---|
| `system` | the system beep |
| `audio` | play `bell-audio-path` |
| `bounce` | bounce the dock icon |
| `badge` | dock-tile badge count |
| `title` | the 🔔 tab-title prefix |
| `border` | the amber surface border (+ the under-zoom badge) |
| `dashboard` | Agent Dashboard auto-unhide + float-to-top + tile mark |
| `push` | Web Push to your phone |
| `monitor` | the Web Monitor's alert indicator |
| `attention` | **back-compat alias** = `bounce` + `badge` (the old single flag) |

The **programmatic** view is always truthful and unflagged: `list_surfaces` exposes both
`bell` (a raw ring happened) and `attentionNeeded` (it was promoted), regardless of how the
effect flags are routed.

## Default routing (this is just the default — re-route freely)

Out of the box the tiers reproduce **today's** behavior (so an unconfigured fork is
unchanged). When you opt in, the suggested routing is:

| effect | default tier |
|---|---|
| `system`, `audio` | **bell** — you always want to *hear* a bell |
| `bounce`, `badge`, `title`, `border` | **attention** — only a real "needs you" should grab your eye |
| `dashboard`, `push`, `monitor` | **attention** — don't unhide / push / light up for a transient bell |

This is one opinion. Anyone can route any effect to either tier in their own config.

## How a bell gets promoted (fail-open)

When the [Agent Manager](AGENT-MANAGER.md) is running with the filter on, every bell wakes
its Haiku classifier (event-driven, so promotion lands in ~1–2s, not on the 5s poll). The
classifier reads the surface and returns an `attention` verdict, and the **non-AI code
treats every uncertain state as "promote":**

| classifier result | outcome |
|---|---|
| confident `attention: false` | **ignore** — tier 1 only (the *only* thing that suppresses) |
| `attention: true` | **promote** — add tier 2 |
| omitted / unparseable / Haiku errored / out of tokens | **promote** (fail-open) |

So only a deliberate, confident "this bell is incidental" ever quiets a bell. Anything
else — including the classifier's own account being rate-limited — stays loud. (The one
gap, a *fully crashed* sidecar, is the deferred fallback noted at the end.) The rate-limit
watchdog in [Agent Manager](AGENT-MANAGER.md) is this same mechanism with a dedicated
`alert` tag.

**The GUI never promotes on its own.** `attentionNeeded` is set *only* by the sidecar (via
the MCP `set_attention` tool); the GUI just renders the two states. A promotion clears when
you focus the surface (you've seen it) or when the sidecar reports recovery.

## Config

All keys are **fork-only** — keep them in `~/.config/ghostty-ramon/config` (an official
Ghostty sharing `~/.config/ghostty/config` would error on them). `bell-features` itself is
upstream; `bell-features-focused`, `attention-features`, and `agent-manager-bell-filter`
are the fork additions.

```ini
# Master switch: let the Agent Manager classify bells and promote the notable ones.
# (Requires agent-manager = true; see AGENT-MANAGER.md.)
agent-manager-bell-filter = true

# Tier 1 — every bell. Dial it down to "just be audible" (SEE THE GOTCHA BELOW).
bell-features = system,audio,no-attention,no-title,no-border,no-dashboard,no-push,no-monitor

# Tier 2 — added on a promotion (the loud "needs you" set).
attention-features = title,border,bounce,badge,dashboard,push,monitor

# Optional: a different tier-1 set when the ringing split is truly focused
# (focused split + key window + active app). A promotion has no focused variant —
# focusing a surface clears its attention.
bell-features-focused = system,no-attention,no-title
```

### ⚠️ Gotcha: the value is **additive over defaults**, not "reset to listed"

The `BellFeatures` flag list is parsed **on top of the type defaults** — `attention` and
`title` start **on**, every other flag starts **off** — and your value only flips the flags
you name. It does **not** zero the set first. So:

- `bell-features = system,audio` does **NOT** silence the loud bell — `attention` (dock
  bounce+badge) and `title` (🔔) **stay on**.
- To actually dial tier 1 down you must **negate explicitly** with `no-`:
  `bell-features = system,audio,no-attention,no-title,no-border,no-dashboard,no-push,no-monitor`.

(This matches upstream's `name` / `no-name` convention for every other packed-flag key.)

## On your phone (Web Monitor)

The [Web Monitor](WEB-MONITOR.md) shows the two states **distinctly**: a raw bell as 🔔 and
a promoted "needs you" as ⏳, each routed by whether `monitor` is on its tier. Each has its
**own** clear button, so from your phone you can acknowledge a promotion without clearing
(or being confused by) a separate raw bell — and vice-versa.

## Requirements

1. `agent-manager-bell-filter = true` — the master switch.
2. The **Agent Manager sidecar must be able to run**: `mcp-listen` + `mcp-token` set and
   `node` on PATH (see [AGENT-MANAGER.md](AGENT-MANAGER.md)). **You do NOT need the continuous
   summarizer** (`agent-manager`) on — the sidecar launches for bell-filter alone, and a bell
   classify is a cheap *per-bell* Haiku call, decoupled from the expensive continuous polling
   that `agent-manager` gates. (So bell-promotion works in every combination: agent-manager
   on or off, agent-queue on or off.)
3. Your chosen `bell-features` / `attention-features` routing (remember the `no-` gotcha).
4. *Recommended:* route the sidecar's Haiku to a **separate account** (AGENT-MANAGER.md →
   Account routing) so a bell classify survives the very rate-limit it might be reporting.

With the filter **off**, none of this engages and a bell behaves exactly as it does today.

> **Cost note.** The continuous summarizer (`agent-manager`) makes Haiku calls on a timer
> for every agent tile — that's the expensive part, so it's separately toggleable. Bell
> promotion only classifies *on a bell* (rare), so it's cheap enough to leave on even with
> the summarizer off.

## Known limitation (deliberately not built)

**Crashed-sidecar fallback.** If you dial `bell-features` down to sound-only and the Agent
Manager sidecar is *fully down* (not merely rate-limited — it self-restarts), a bell during
that window is audible but its attention-tier visuals won't fire until the sidecar is back.
Under the recommended routing `system`/`audio` stay on tier 1, so a real bell is never
*silent*; the visual fallback is an open design choice (see
`scratchpad/bell-attention-v2-design.md`). The other "down" cases are already covered:
disabled ⇒ tier 1 stays loud; out-of-tokens ⇒ the sidecar still promotes (fail-open).

## Implementation notes (for agents touching the code)

The load-bearing facts for an agent touching this code. (User-facing config/usage is
above; this section is the dev/internal nuance.)

### Two tiers over one shared `BellFeatures` vocabulary

`bell-features` fires on EVERY bell (immediately); `attention-features` (fork-only key) is
ADDED when a bell is PROMOTED. Promoted bell = `bell-features ∪ attention-features`; ignored
bell = `bell-features` only; filter OFF ⇒ `bell-features` only (today). The expanded
vocabulary (`BellFeatures` packed struct, bits 0–9): `system,audio,attention,title,border,
bounce,badge,dashboard,push,monitor`. **`attention` is a BACK-COMPAT alias** the dock
consumers treat as `bounce`+`badge`. **`agent-manager-bell-filter` (bool, default false)** is
the master switch (delivered to the sidecar as `GHOSTTY_BELL_FILTER=1`).

### Decoupled from the continuous summarizer (works in ALL agent-manager combinations)

Since ramon-fork made `agent-manager` (the EXPENSIVE per-poll summarizer) optional, bell
promotion — a CHEAP per-bell, fail-open classify — must work independently. So:

1. The Swift `sidecarShouldStart` gate launches the sidecar when agent-manager OR agent-queue
   OR `bell-filter` is on (`bellFilterEnabled` added, default false).
2. `LoopDeps.summarizerEnabled` (from `GHOSTTY_SUMMARIZER`) gates ONLY the continuous pass —
   `runSweep` ALWAYS runs the FORCED (bell) pass (sequential, fail-open, EXEMPT from the
   rate-limit backoff cooldown) but runs the continuous due-agent pass + backoff ONLY when
   `summarizerEnabled`.
3. `main()` arms `bellReactiveLoop` whenever `bellFilter` (NOT nested under summarizer), and
   `await tick()` (the 5s poll) only when `summarizerEnabled`; the process-exit guard requires
   all THREE off.

So bell-only mode (summarizer off, bell-filter on): a bell classifies ONLY the rung surface
(one cheap call), the due agents are never polled. Account-routing is resolved when
`summarizerEnabled || bellFilter` (a bell classify also bills the routed account). Tests:
sidecar `summarizer OFF + bell-filter ON ⇒ a bell promotes but due agents are NOT polled` (+
the no-bell no-op), Swift `shouldStartWhenBellFilterOnly`.

### PARSE IS ADDITIVE over the TYPE field defaults, NOT reset-to-listed (load-bearing gotcha)

`parsePackedStruct` does `var result: T = .{}` — so `BellFeatures{}` starts `attention`+`title`
TRUE, the rest FALSE, then the listed flags are OR'd on (or cleared with a `no-` prefix). So
`bell-features = system,audio` does NOT dial the bell tier down — `attention`(bounce+badge) and
`title`(🔔) STAY ON; the real dial-down needs explicit `no-attention,no-title,…` (a
`bell-features=system,audio` `Config.zig` test asserts `attention`/`title` stay true, plus a
`no-*` case). DEFAULTS reproduce today: `bell-features` field default adds
`dashboard,push,monitor=true` (which were ungated/always-on pre-v2) atop the type defaults
`attention,title`; `attention-features` default is the loud set.

### FAIL-OPEN decision (sidecar)

On a bell, the Agent Manager classifies and PROMOTES (`set_attention(true)`) unless it got a
CONFIDENT parsed `attention === false`. A strict three-valued `coerceAttention`
(`summarizer.ts`) maps only canonical true/false; an unrecognized value (e.g. `"maybe"`) ⇒
`undefined` ⇒ `attention !== false` ⇒ PROMOTE (do NOT use the lax `coerceBool` here —
`"maybe"`→false→suppress is a fail-open bug). Thrown / unparseable / omitted all promote. Only
a confident `false` suppresses.

### PROMOTION DOES NOT DEPEND ON `view.bell` (do not make it depend on `view.bell`)

`Ghostty.App.ringBell` posts `.ghosttyBellDidRing` UNCONDITIONALLY on every ring → the MCP
event bus records a `.bell` event → the sidecar's `bellReactiveLoop` long-polls
`wait_for_event(bell)` and records `ev.id` into `LoopDeps.pendingBellIds`, drained into
`forcedBell` each sweep as the PRIMARY trigger. The `list_surfaces.bell` rising-edge
(`bellRoseEdge`) is only a BACKSTOP. This is load-bearing because in the RECOMMENDED
`bell-features = system,audio,no-…` config the GUI never arms `view.bell` (its arming gate
still requires `.title`/`.border` — UNCHANGED, so it can't regress the focused-suppression that
`bell-features-focused = …no-title` relies on), so `list_surfaces.bell` stays false and the
backstop alone would never promote. Event-driven ⇒ promotion lands in ~1–2s;
`makeCoalescedRunner` keeps the bell-reactive wake from overlapping the 5s summarizer sweep.
`bellReactiveLoop` never exits on error (fail-open: backoff + re-park).

### Per-tier consumer routing

Every consumer renders `(bell && bell-features.<flag>) || (attentionNeeded &&
attention-features.<flag>)`:

- AppDelegate `playBellEffects` (system→beep, audio→sound, bounce|attention→
  requestUserAttention) on bell-features for `ghosttyBellDidRing` / attention-features for
  `ghosttyAttentionDidChange`, + two-tier `setDockBadge` (badge|attention) + web-push policy
  (`server.push.bellPush`/`attnPush`).
- BaseTerminalController `computeTitle` (title) + `DerivedConfig` snapshots both sets.
- SurfaceView `BellBorderOverlay` + TerminalView `showHiddenBellBadge` (border, gated on EITHER
  tier).
- AgentDashboardModel `bellDashboard`/`attnDashboard` (applyBells unhide iff bellDashboard,
  applyAttention iff attnDashboard, `needsAttention`/`sorted` float per tier).
- WebMonitorServer `attnIndicator` + `monitorBell`/`monitorAttn`.

### GUI NEVER auto-sets `attentionNeeded` (principle #3)

It is set ONLY by the sidecar via the MCP `set_attention` tool → `.ghosttyAttentionDidChange`
(filtered by surfaceID; SurfaceView `attentionNeeded` @Published). It CLEARS independently of
the raw `bell`: on focus (`focusDidChange` clears both), `resetBell()` clears only `bell`
(web-monitor bell button), `resetAttention()` clears only attention (web-monitor `/attention`
button, P5). `list_surfaces` carries BOTH `bell` + `attentionNeeded` truthfully (no flag —
principle F).

### Cross-language `BellFeatures` bit-ABI (Zig packed struct ⇄ Swift OptionSet rawValue)

`ghostty_config_get` hands the struct to Swift as a raw int reinterpreted by FIXED bit
position. Pinned BOTH ways — a Zig `@bitCast` test (`system`=bit0 … `monitor`=bit9) +
`ConfigTests.bellFeaturesBitPositionsMatchZig`. A field reorder / bit typo would silently
misroute every effect; it now fails a test.

### Web monitor (P5)

`/api/surfaces` rows carry `bell`, `attentionNeeded`, and a monitor-tier-routed
`attnIndicator = (bell && monitorBell) || (attentionNeeded && monitorAttn)`; the page shows 🔔
(raw) vs ⏳ (promoted) distinctly, each with its own clear button (`POST
/api/surface/{uuid}/{bell,attention}`).

### DEFERRED (the one open design decision, NOT built): §78 crashed-sidecar GUI fallback

When the filter is on + the sidecar is fully DOWN, attention-tier visuals don't fire (sound
stays bell-tier, so a bell is never silent). Needs either a principle-#3 exception or
per-consumer health wiring; flagged in `scratchpad/bell-attention-v2-design.md`.

### History / billing / account-routing

The promoter's history/billing/account-routing live in the Agent Manager — see the Agent
Manager bullet's "Attention bell on rate-limit" (the rate-limit watchdog is this same
mechanism with an `alert` tag) and `AGENT-MANAGER.md`.

### Wiring

- **core** — `src/config/Config.zig` (`BellFeatures` vocabulary + `attention-features` +
  `agent-manager-bell-filter` + parse/bit-ABI tests).
- **macOS** — `Ghostty.Config.swift` (`attentionFeatures` getter + the OptionSet flags),
  `AppDelegate.swift`, `BaseTerminalController.swift`, `Surface
  View/{SurfaceView,SurfaceView_AppKit}.swift`, `Terminal/TerminalView.swift`,
  `AgentDashboard/AgentDashboardController.swift`, `WebMonitor/{WebMonitorServer,WebMonitorPush}.swift`,
  `MCP/{MCPAnnotation,MCPLayout}.swift` (`set_attention` + `attentionNeeded` row).
- **sidecar** — `macos/agent-manager/src/{index,summarizer,mcp,prompts}.ts` (`coerceAttention`,
  `pendingBellIds`/`bellReactiveLoop`, `makeCoalescedRunner`, `waitForEvent`/`parseWaitForEvent`).

### Tests

- sidecar `node --test` (fail-open + `parseWaitForEvent` + coalesce + event-driven promote).
- Swift `ConfigTests`/`WebMonitorServerTests`/`AgentDashboardTests`.
- Zig `attention-features` + `BellFeatures bit positions`.

**GUI relaunch + rebuilt sidecar `dist`; no host change.**

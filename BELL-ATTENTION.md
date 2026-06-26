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

When the [Agent Manager](AGENT-MANAGER.md) is running with the filter on, every bell **on a
surface you're not looking at** wakes its Haiku classifier (event-driven, so promotion lands
in ~1–2s, not on the 5s poll). The classifier reads the surface and returns an `attention`
verdict, and the **non-AI code treats every uncertain state as "promote":**

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

**What the classifier is told to treat as incidental (`attention: false`).** The decisive
question in the summarizer prompt (`prompts.ts`) is *"is the user being asked to ACT right
now?"* — judged from the live bottom of the screen. Explicitly incidental → `false`: a
background task just started; **a long-running workflow / review / pipeline / test / build
the user kicked off that is still progressing or just finished a stage, where they are
merely awaiting its completion** (the agent may even report `waiting` — it is waiting on its
own sub-tasks, not on the human); a sub-step finished; a routine notification. Loud only
when the screen *actually* awaits the user (a question / approval / choice / error, or a
workflow that has **stopped** and now needs them). This is the prompt-side complement to the
focus guards: the orchestration case (a supervisor "waiting" on its sub-agents) is one a
structural `agentState` gate can't tell from human-waiting, but the classifier can read it
off the screen. Naming the case lets the model emit a *confident* `false` instead of
omitting (which fails open to loud).

**The GUI never promotes on its own.** `attentionNeeded` is set *only* by the sidecar (via
the MCP `set_attention` tool); the GUI just renders the two states. A promotion clears when
you focus the surface (you've seen it) or when the sidecar reports recovery.

### Focus never raises attention (no bell from a split you're looking at)

You don't need to be summoned to a split you're already focused on, so a **truly focused**
surface (focused split + key window + active app — the same `bellIsFocused` rule
`bell-features-focused` uses) never gets promoted, by two independent guards:

1. **Don't even classify.** A bell on a focused surface is **not surfaced as a `.bell`
   event** to the sidecar, so the Haiku classifier never even runs for it — no spend, no
   promotion. (The tier-1 `bell-features-focused` effects still fire normally.) Focus is
   read live at *ring* time, the freshest truth.
2. **Don't raise late, either.** A `set_attention(true)` that arrives **while** the surface
   is focused is ignored GUI-side (a *clear* always applies). This is the mechanism-agnostic
   backstop for the **delayed-promotion race** that otherwise made "random bells from a
   healthy session": a bell classify (~1–2s) or the poll-driven **rate-limit watchdog** (up
   to 5s, 10 min for hidden tiles) could land a late promotion *after* `focusDidChange`
   already cleared attention, re-lighting a split you're actively watching. Guard 1 stops
   most bell promotions at the source; guard 2 also covers the watchdog (which bypasses the
   bell event entirely) and the race where focus lands mid-classify.

## Diagnostics (`bell-diagnostics`) — "why did it fire / why didn't it?"

Set `bell-diagnostics = true` and **both** the GUI and the sidecar append a structured
JSONL trace of the whole lifecycle to **`~/Library/Logs/ghostty-ramon-bell-diagnostics.jsonl`**.
Off by default; turn it on while investigating, then turn it back off (the file grows
append-only). A GUI relaunch is needed to pick up the change (it also forwards the flag to
the sidecar as `GHOSTTY_BELL_DIAG=1`).

One JSON object per line, `{ts, src, ev, …}` (`src` is `"gui"` or `"sidecar"`):

| `ev` | `src` | fields | what it tells you |
|---|---|---|---|
| `ring` | gui | `surface, title, focused` | a bell rang. `focused:true` ⇒ it was NOT classified/promoted (focus guard) |
| `classify` | sidecar | `surface, verdict, decision, reason, durationMs` (+ `error, errorKind` on errors) | what Haiku decided for a bell. `verdict`∈`true/false/omitted/unparseable/error`; `decision`∈`promote/ignore`. **`durationMs` = the Haiku call's wall-clock time** (the model portion of the delay). On `verdict:error` the real `error` message shows whether it was a fail-open *caused by the classifier's own rate-limit* |
| `alert` | sidecar | `surface, tag, edge, decision` | the rate-limit **watchdog** (a "fake" bell synthesized from a rate-limit prompt on the agent's screen). `edge:ring` (e.g. `tag:rate_limited`) / `edge:clear` |
| `backoff` | sidecar | `edge, streak, failed, nextProbeInS` / `afterFailures` | the **classifier's OWN account** is rate-limited. `edge:engage` ⇒ from here every bell fail-opens into a "fake" promotion (`verdict:error`) until `edge:clear`. `probe_fail` extends it |
| `attention` | gui | `surface, title, on, focused, applied, reason` | a `set_attention` landed. `applied:false` ⇒ suppressed because you were focused |
| `clear` | gui | `surface, title, cause, hadBell, hadAttention` | focusing the surface dismissed a pending bell/attention |

**Answering the usual questions** (`jq` over the file):
- *Why did it just fire?* — the latest `attention` with `on:true, applied:true`; its `reason`
  is the sidecar's verdict, and the preceding `classify`/`alert` for the same `surface` shows
  whether it was a real bell promotion or the rate-limit watchdog.
- *Why DIDN'T it fire an hour ago?* — find the `ring` at that time; then either there's a
  `classify` with `decision:ignore` (Haiku said incidental), or the `ring` was `focused:true`
  (focus guard, never classified), or there's no `classify` at all (sidecar down/slow).
- *Average delay* — two numbers: the per-surface gap from a `ring` to its following
  `attention` (`applied:true`) is the **user-perceived** ring→visuals delay; the `classify`
  event's `durationMs` is the **Haiku-call** portion of it (the rest is poll/queue latency).
- *"Fake" bells from rate limits* — two distinct cases, both visible: (a) the **watchdog**
  synthesizing attention from a rate-limit prompt on the *agent's* screen ⇒ an `alert` event
  with `tag:rate_limited`; (b) a promotion that fired only because the **classifier's own
  account** was throttled ⇒ a `classify` with `verdict:error` whose `error` names the rate
  limit, almost always inside a `backoff edge:engage`…`edge:clear` window. If you're seeing
  spurious bells, scan for `backoff edge:engage` — everything promoted in that window is a
  fail-open artifact, not a real "needs you".

```sh
# last 20 events, human-ish:
tail -20 ~/Library/Logs/ghostty-ramon-bell-diagnostics.jsonl | jq -c '{ts,src,ev,surface,reason,verdict,decision,focused,applied}'
# average ring→attention delay (seconds), naive pairing per surface:
jq -rs '... ' ~/Library/Logs/ghostty-ramon-bell-diagnostics.jsonl   # (or just ask Claude to analyze the file)
```

(You can also just hand the file to Claude and ask in plain English.)

## Config

All keys are **fork-only** — keep them in `~/.config/ghostty-ramon/config` (an official
Ghostty sharing `~/.config/ghostty/config` would error on them). `bell-features` itself is
upstream; `bell-features-focused`, `attention-features`, `agent-manager-bell-filter`, and
`bell-diagnostics` are the fork additions.

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

### Focus suppresses promotion (two guards — `bellIsFocused`)

A truly focused surface is never promoted, so a bell on a split you're looking at can't
re-light attention (the "random bell from a healthy session" race). Two independent guards,
both keyed on the existing `SurfaceView.bellIsFocused` (focused split + `isKeyWindow` +
`NSApp.isActive`), read on `.main` at the relevant instant:

1. **`MCPEventBus.start`'s bell observer** skips `record(.bell)` when `view.bellIsFocused` —
   so a focused bell never becomes a `.bell` event, the sidecar's `bellReactiveLoop` never
   sees it, and **no Haiku classify is spent**. Focus is read at RING time (freshest), not
   the sidecar's polled `surface.focused`. The `.bell` event's only consumer is the
   bell-reactive promotion loop; tier-1 effects come from `ghosttyBellDidRing` (separate
   `NotificationCenter` observers in SurfaceView/AppDelegate/WebMonitorPush), so suppressing
   the event does NOT dim tier-1 `bell-features-focused`.
2. **`SurfaceView.ghosttyAttentionDidChange`** ignores an incoming `set_attention(true)` when
   `bellIsFocused` (a *clear*, `on == false`, always applies). Mechanism-agnostic backstop
   for the async race (focus lands between classify-start and the notification) AND for the
   poll-driven rate-limit watchdog, which bypasses the bell event so guard 1 can't catch it.

Not unit-tested: `bellIsFocused` depends on live `NSApp`/window state (like
`bellFeaturesForCurrentFocus` itself, also untested) — verified by build + the existing
MCP/WebMonitor/Config suites staying green.

### Diagnostics trace (`bell-diagnostics`)

`bell-diagnostics` (Zig bool, default false) makes the GUI + sidecar append a shared JSONL
lifecycle trace to `~/Library/Logs/ghostty-ramon-bell-diagnostics.jsonl`. GUI side: a pure-
Foundation `BellDiagnostics` appender (no AppKit types, so no Xcode target exclusion; O_APPEND
fd on a background queue so GUI + sidecar lines interleave atomically). Three GUI events:
`ring` (AppDelegate `ghosttyBellDidRing`, with `bellIsFocused`), `attention` (SurfaceView
`ghosttyAttentionDidChange`, with `reason` + `applied = !(on && bellIsFocused)`), `clear`
(SurfaceView `focusDidChange`, read prior `bell`/`attentionNeeded` BEFORE clearing). Each call
site gates on `config.bellDiagnostics` so a disabled feature does zero work — there is NO
global enabled flag (avoids config-reload state). Sidecar side: `diag.ts` (`recordDiag`, gated
by `GHOSTTY_BELL_DIAG=1`, forwarded by `AgentManagerController.childEnvironment` when
`bellDiagnostics`), emitting `classify` (verdict/decision at each bell-classify outcome:
clean true/false/omitted, unparseable, error) + `alert` edges in `maybeSignalAlert` +
`backoff` edges (engage/clear/probe_fail) in `runSweep`'s rate-limit aggregator. The
user-perceived delay is measured GUI-side (`ring`→`attention`, so NO ring-timestamp
threading); the `classify` event ALSO carries `durationMs` (timed around the `summarize()`
call via `modelStartedAt`/`durMs()`, valid in the catch too so a failed call's time is
captured) and, on `verdict:error`, the real `error`+`errorKind` so a fail-open caused by the
classifier's OWN rate-limit is distinguishable from a confident promotion — corroborated by the
`backoff edge:engage`…`clear` window around it. Pure line builders (`BellDiagnostics.line`,
`formatDiagLine`) are unit-tested; the fs append is best-effort and untested by design.

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
  `agent-manager-bell-filter` + `bell-diagnostics` + parse/bit-ABI tests).
- **macOS** — `Ghostty.Config.swift` (`attentionFeatures` getter + the OptionSet flags),
  `AppDelegate.swift`, `BaseTerminalController.swift`, `Surface
  View/{SurfaceView,SurfaceView_AppKit}.swift`, `Terminal/TerminalView.swift`,
  `AgentDashboard/AgentDashboardController.swift`, `WebMonitor/{WebMonitorServer,WebMonitorPush}.swift`,
  `MCP/{MCPAnnotation,MCPLayout}.swift` (`set_attention` + `attentionNeeded` row),
  `MCP/MCPEventBus.swift` (focus guard 1 — skip `.bell` for a focused surface) +
  `Surface View/SurfaceView_AppKit.swift` `ghosttyAttentionDidChange` (focus guard 2),
  `Features/BellDiagnostics/BellDiagnostics.swift` (new, pure-Foundation JSONL appender) +
  the `ring`/`attention`/`clear` call sites (`AppDelegate.swift`, `SurfaceView_AppKit.swift`)
  + `AgentManager/AgentManagerController.swift` (`GHOSTTY_BELL_DIAG` env).
- **sidecar (diagnostics)** — `macos/agent-manager/src/diag.ts` (`recordDiag`/`formatDiagLine`)
  + `index.ts` (`classify`/`alert` records). Tests: `diag.test.ts`,
  `macos/Tests/BellDiagnostics/BellDiagnosticsTests.swift`.
- **sidecar** — `macos/agent-manager/src/{index,summarizer,mcp,prompts}.ts` (`coerceAttention`,
  `pendingBellIds`/`bellReactiveLoop`, `makeCoalescedRunner`, `waitForEvent`/`parseWaitForEvent`).

### Tests

- sidecar `node --test` (fail-open + `parseWaitForEvent` + coalesce + event-driven promote).
- Swift `ConfigTests`/`WebMonitorServerTests`/`AgentDashboardTests`.
- Zig `attention-features` + `BellFeatures bit positions`.

**GUI relaunch + rebuilt sidecar `dist`; no host change.**

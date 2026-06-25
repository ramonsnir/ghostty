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

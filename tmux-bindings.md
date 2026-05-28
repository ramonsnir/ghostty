# Tmux-shaped keybindings for Ghostty — design notes

Scratch notes for a personal Ghostty fork. Goal: give Ghostty a "tmux-mode"
keybinding layer — same muscle memory, no actual tmux. This doc captures the
current theory + mapping, the gaps that drive fork work, and what the next
iteration looks like once each gap is closed.

Companion notes: [`NOTES-split-tab-reorg.md`](NOTES-split-tab-reorg.md) covers
the underlying split/tab reorg work, several capabilities of which unlock
gaps listed below.

Baseline reference: the user's old Linux tmux config (prefix `C-a`, send-prefix
`a`, project launchers, sync-panes, etc.), now ported to
`~/.config/tmux/tmux.conf` on this machine.

---

## Theory: Ghostty already has the primitives

Ghostty 1.3 ships three features that make a "tmux mode" expressible in pure
config — no new actions needed for the prefix layer itself:

1. **Key sequences** — `keybind = ctrl+a>c=new_tab` means "press C-a, then c".
   Atomic, one-shot, one binding per action. This *is* tmux's prefix model.
2. **Key tables** — named modal binding sets, entered via
   `activate_key_table[_once]:name`. Not needed for basic prefix work, but
   they're the natural home for sustained modes (resize mode, copy mode).
3. **`text:` / `csi:` / `esc:` actions** — inject arbitrary bytes into the
   PTY. This is how we rebuild `bind a send-prefix` so the shell's C-a
   beginning-of-line is recoverable as `C-a a`.

**Decision: use key sequences (`ctrl+a>…`) for the prefix layer.** Reserve
key tables for genuinely modal extensions later (see "Future").

### Concept mapping

| tmux            | Ghostty                               |
|-----------------|---------------------------------------|
| window          | **tab**                               |
| pane            | **split**                             |
| session         | — (no group-of-tabs container)        |
| prefix (`C-a`)  | `ctrl+a>…` key sequence               |
| copy mode       | — (selection exists, no modal motions)|

---

## What ports today (Ghostty 1.3, no fork changes)

| Old tmux bind                         | Ghostty bind                                       |
|---------------------------------------|----------------------------------------------------|
| `prefix C-a`, `bind a send-prefix`    | `ctrl+a>a=text:\x01` (literal C-a to shell)        |
| `bind C-a last-window`                | `ctrl+a>ctrl+a=last_tab`                           |
| `bind r source-file …`                | `ctrl+a>r=reload_config`                           |
| `bind < rename-window`                | `ctrl+a><=prompt_tab_title` (popup vs status line) |
| `bind '"' split-window` (vertical)    | `ctrl+a>-=new_split:down` (see "`"` key" caveat)   |
| `bind % split-window -h`              | `ctrl+a>\=new_split:right` (or `>%=`)              |
| `bind Up/Down/Left/Right select-pane` | `ctrl+a>arrow_*=goto_split:*`                      |
| `bind -n C-S-Left/Right swap-window`  | `ctrl+shift+arrow_left=move_tab:-1` / `…right=…:1` |
| (bonus, not in old config) `prefix z` | `ctrl+a>z=toggle_split_zoom`                       |

Things that **only partially** port:

| Old tmux bind         | Closest Ghostty bind            | Semantic gap                                                                              |
|-----------------------|---------------------------------|-------------------------------------------------------------------------------------------|
| `bind m/M` mouse on/off | `ctrl+a>m=toggle_mouse_reporting` | Ghostty's toggle controls whether mouse events reach the PTY (vim etc.), **not** whether clicks select text. Click-to-select is always on in Ghostty. Different semantics, same key — acceptable. |

---

## Gaps — these drive fork work

Each gap is a missing capability in Ghostty that prevents a faithful port of a
bind the user actually used. Listed in rough order of value/effort.

### G1. No "move split into another tab" (tmux `join-pane`) — ✅ shipped

- Tmux flow: `prefix q` mark a pane, switch tabs, `prefix j` pull it in;
  or `prefix J <n>` push current pane to window N.
- Shipped (see CLAUDE.md "Functional changes"):
  - `move_split_to_new_tab` (the `prefix !` analog) — eject focused pane.
  - `mark_split` / `clear_split_mark` / `pull_marked_split:<dir>` — the
    full mark-and-pull workflow (`prefix q` + `prefix j`). Works
    cross-tab and cross-window; source tab auto-closes when emptied.
    Mark toggles on re-press, so a single keybind handles both set and
    unset. (This is also G4; the original "do not port" call was based
    on a misreading of `prefix j`.)
  - **Visible mark feedback**: the marked pane gets a 3pt orange
    inset border. Cross-window safe (observers share `Ghostty.App`),
    auto-clears on pull/toggle/close.
  - `merge_tabs:{next,previous}_{horizontal,vertical}` — the adjacent-tab
    variant, no mark required.
  - `swap_split:{previous,next,up,down,left,right}` — exchange the
    focused pane with another in the same tab (tmux `swap-pane -U/-D`
    and the spatial variants). Tree structure and ratios preserved.
    Repeated `:next` walks the focused content to the bottom-right
    corner in N-1 presses.
- **Shelved**: `move_split_to_tab:<n>` (push current pane to tab N with a
  numeric prompt). Coverage from mark-and-pull + adjacent merge is
  considered enough.

### G2. No "broadcast input to all splits" (tmux `synchronize-panes`) — dropped

- Dropped on review: not used in years. If it ever returns, the design
  would still be a per-tab broadcast flag + hook in the input encoder,
  with a visible border tint as the indicator.

### G3. No "open a project in a new tab" command-prompt (tmux `bind h ~/git/…`)

Split into two sub-features after debate:

- **G3b — single-key shortcuts to specific projects** — ✅ shipped.
  `new_tab` now accepts an optional `working_directory`:
  `keybind = ctrl+a>g=new_tab:~/git/ghostty`. `~/` is expanded apprt-side.
  Covers the everyday case of opening the same handful of projects.
- **G3a — generic prompted launcher** (tmux `bind h command-prompt`) —
  postponed. Would need (1) a generic prompt-with-substitution action,
  (2) optional tab-completion against a configured base dir, on top of
  the `working_directory` parameter we already have. Big scope for a
  feature that may not pull its weight once G3b is in everyday use.

### G4. No "mark + join" for splits (tmux `prefix q/Q` + `j`) — ✅ shipped (with G1)

Reversed the original "do not port" call. The mark-pane mechanism is the
*source-selection* half of `prefix j`; without it, "pull the marked pane"
has no meaning. See G1 for the shipped form.

### G5. No "repeatable" prefix-bound keys (tmux `bind -r`) — 🚧 next

Originally framed as "modal resize mode" and shelved on the grounds
that OS-level key auto-repeat (while a modifier is held) covered the
common case. That framing was wrong. The actual missing capability is
tmux's **`-r` (repeatable) flag** on a binding: after the first
`prefix L`, the next ~500ms accepts bare `L`/`H`/`J`/`K` (separate
keystrokes, not held) and treats each as another repeat of the same
class of action *without re-issuing the prefix*. So `prefix L L L L`
grows the split four times.

This is a different mechanism from OS key-repeat:

  * OS key-repeat: hold the key down, the keyboard driver synthesises
    repeated presses. Works fine for single bindings, but doesn't help
    when the binding is behind a key sequence (the prefix is consumed
    on the first press, so subsequent OS-repeated `L` events just go
    to the terminal as `L`).
  * tmux `-r`: separate physical presses, with a short timeout. The
    prefix layer stays "armed" for repeatable bindings at the same
    sequence depth for the duration of the timeout, then drops back to
    normal handling. Any non-matching key, or timeout expiry, ends
    the repeat window.

**Design sketch (next iteration):**

  * New keybind flag prefix `repeatable:` alongside the existing
    `unconsumed:`, `performable:`, `global:`, `all:`. Stored on
    `Binding.Flags.repeatable: bool`.
  * Runtime: in `Surface.maybeHandleBinding`, when a leaf action with
    `repeatable: true` fires inside an active sequence, instead of
    clearing `sequence_set`, leave it pointing at the **parent set**
    (one level up) and arm a timer for `keybind-repeat-timeout`
    (default 500ms). On the next keypress, the normal sequence match
    runs against that same parent set:
      - if it lands on another `repeatable:` action → re-arm the timer
        and continue.
      - if it lands on a non-repeatable action → fire normally, then
        clear the sequence.
      - if no match → drop the sequence as usual (current behaviour).
    On timer expiry → clear `sequence_set`.
  * New config key `keybind-repeat-timeout` (default `500ms`) parsed
    the same way as the existing `*-timeout` durations.

**Why now:** the resize and goto_split bindings benefit immediately;
once shipped, the v1 fork config can use `ctrl+a>repeatable:shift+l=
resize_split:right,2` and friends, recovering the tmux `-rH/-rL/...`
feel verbatim.

The original "modal resize mode via key table" path stays available
as an escape hatch if `-r` turns out to be insufficient, but the
expectation is that `-r` is sufficient on its own.

### G6. No "sessions"

- tmux sessions ≈ named groups of windows with their own clients. Ghostty
  has windows but no grouping. Would require persistence + a session
  registry + cross-window goto. **Out of scope** for this iteration.

---

## Caveats / known sharp edges

- **C-a vs readline `beginning-of-line`**: pressing C-a alone arms the
  sequence; the keystroke is consumed, so the shell never sees it. The
  `ctrl+a>a=text:\x01` workaround restores it as a double-tap, matching
  tmux exactly. Upside: behavior is **uniform inside and outside tmux**.
- **No `performable:` fallback for sequences**: if you press C-a then an
  unbound key, the sequence aborts and the C-a is lost. Acceptable.
- **`"` as a key name**: unverified whether Ghostty's keybind parser
  accepts bare `"` in a sequence. The v0 baseline uses `-` and `\` for
  splits to sidestep this. TODO for the fork: confirm and document.
- **Case in sequence triggers is ignored**: `ctrl+a>q` and `ctrl+a>Q`
  resolve to the same trigger; whichever binding is parsed last wins.
  This bit us during the mark/pull smoke test (`Q` clobbered `q`). To
  bind a shift-modified key inside a sequence, **write the modifier
  explicitly**: `ctrl+a>shift+q=…`. tmux's `bind q`/`bind Q` distinction
  must therefore be translated to `>q` / `>shift+q` for Ghostty.
- **Defaults stay alive**: this layer only *adds* C-a bindings; all the
  existing `super+…` shortcuts keep working. Either muscle memory is fine.
- **Mouse-toggle semantic mismatch** (see table above) — not a bug, just a
  mismatch to flag in user docs.

---

## v0 baseline — current Ghostty `~/.config/ghostty/config` block

This is what we can run on stock Ghostty 1.3 today. It lives alongside the
user's existing config; nothing here removes a default.

```ini
# --- tmux-shaped prefix layer (Ghostty 1.3+) ---

# Prefix-prefix → last tab; literal C-a to shell
keybind = ctrl+a>ctrl+a=last_tab
keybind = ctrl+a>a=text:\x01

# Tabs (= tmux windows)
keybind = ctrl+a>c=new_tab
keybind = ctrl+a>n=next_tab
keybind = ctrl+a>p=previous_tab
keybind = ctrl+a>1=goto_tab:1
keybind = ctrl+a>2=goto_tab:2
keybind = ctrl+a>3=goto_tab:3
keybind = ctrl+a>4=goto_tab:4
keybind = ctrl+a>5=goto_tab:5
keybind = ctrl+a>6=goto_tab:6
keybind = ctrl+a>7=goto_tab:7
keybind = ctrl+a>8=goto_tab:8
keybind = ctrl+a>9=goto_tab:9
keybind = ctrl+a><=prompt_tab_title

# Splits (= tmux panes)
keybind = ctrl+a>-=new_split:down
keybind = ctrl+a>\=new_split:right
keybind = ctrl+a>%=new_split:right
keybind = ctrl+a>arrow_up=goto_split:up
keybind = ctrl+a>arrow_down=goto_split:down
keybind = ctrl+a>arrow_left=goto_split:left
keybind = ctrl+a>arrow_right=goto_split:right
keybind = ctrl+a>z=toggle_split_zoom

# Config + misc
keybind = ctrl+a>r=reload_config
keybind = ctrl+a>?=toggle_command_palette
# `ctrl+a>m=toggle_mouse_reporting` is dropped — the semantic mismatch
# vs. tmux's `set -g mouse on/off` isn't worth the muscle-memory collision.

# Swap tabs without prefix (tmux's `bind -n C-S-Left/Right swap-window`)
keybind = ctrl+shift+arrow_left=move_tab:-1
keybind = ctrl+shift+arrow_right=move_tab:1
```

---

## v1 — config now that the fork actions exist

Pure config additions that depend on fork actions. Add to
`~/.config/ghostty-ramon/config` (fork-only) so an official Ghostty never
sees these unknown actions.

```ini
# G1 + G4 — eject / mark / pull, mirroring tmux prefix !/q/Q/j.
# `mark_split` toggles, so re-pressing on the marked pane clears it.
# `shift+q` is the explicit "clear from anywhere" chord (sequence triggers
# are case-insensitive, so the uppercase form must be written as `shift+q`;
# the same applies to symbol keys like `!`, `%`, `&`, `"` that require
# shift to type — write the modifier explicitly or the trigger never matches).
keybind = ctrl+a>shift+!=move_split_to_new_tab
keybind = ctrl+a>q=mark_split
keybind = ctrl+a>shift+q=clear_split_mark
keybind = ctrl+a>j=pull_marked_split:auto

# G3b — one-key launchers for the projects under ~/git that are opened often.
# Single letters where free; `shift+n` for NoetiveOS because `n` is next_tab.
keybind = ctrl+a>g=new_tab:~/git/ghostty
keybind = ctrl+a>shift+n=new_tab:~/git/NoetiveOS
keybind = ctrl+a>i=new_tab:~/git/nil

# Swap (tmux swap-pane).
keybind = ctrl+a>shift+{=swap_split:previous
keybind = ctrl+a>shift+}=swap_split:next
```

## v2 — pending the repeater (G5)

Once `repeatable:` ships, the resize bindings can stop demanding
shift+letter for big steps and instead emit one motion per press with
a 500ms re-arm window — closer to tmux's `bind -r L resize-pane -R 5`.
Until then, the current config uses static `shift+H/J/K/L` for
10-cell steps and lowercase `h/j/k/l` for 2-cell steps without the
re-arm.

Postponed / dropped:
- **G3a** (prompted launcher) — needs a generic prompt-with-substitution
  action; revisit if G3b's one-key shortcuts don't cover the workflow.
- **G2** (broadcast input) — dropped, unused in years.
- **G5** (repeatable bindings) — 🚧 next iteration. See section above.
- **G6** (sessions) — out of scope.
- **`move_split_to_tab:<n>`** (push current pane to tab N) — shelved;
  mark-and-pull + adjacent `merge_tabs` cover the workflow.

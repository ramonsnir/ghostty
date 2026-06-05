# PTY-host `.client` — Remediation Program

Sequenced plan to take the `.client` backend from "renders + reattaches" to
"usable interactive terminal," derived from the feature audit in
`.claude/docs/ptyhost.md` (37 broken features, 3 architectural roots R1/R2/R3).
Audience: a session deciding what to fund and in what order.

## The three roots (recap)

- **R1 — unfed-local-terminal reads.** GUI code reads/writes `self.io.terminal` /
  `renderer_state.terminal` for state that only exists host-side. Each is a
  bespoke re-route (host-authoritative, or GUI-against-the-mirror).
- **R2 — ModeFrame mirror decoded-but-unconsumed.** The host ships the ~14 input
  modes; `Client.mode` is set but **no encode path reads it** (`key_encode`/
  `paste`/mouse gating still read the stale local terminal). One wiring fixes a
  whole cluster.
- **R3 — no history/scrollback on the wire.** The GridFrame Snapshot is
  viewport-only; off-screen rows are never transmitted. A **new history-bearing
  frame must be designed** before any feature needing off-screen content works.

## Honest scope

This is a **large** program — collectively comparable to (or larger than) the 27
commits already landed. `.client` today renders correctly, survives restarts, and
handles prompt-level interaction; making it a *full* terminal (TUIs, selection,
copy, accessibility, history) is the bulk of the remaining work. The phases below
are ordered by leverage-per-effort so value lands early and the expensive,
design-heavy work (R3) is reached only if the effort is deemed worth it.

---

## Phase A — DONE + smoke-validated (commit `805cbe7eb`).

Applied the host ModeFrame onto the `.client` local terminal in `handleFrame`'s
`.mode_frame` arm (under the shared mutex; `.exec` untouched). **Smoke-confirmed:**
vim arrow keys (app cursor mode), multi-line bracketed paste, and mouse reporting
(htop, `vim :set mouse=a`) all work. Residuals: (1) the alt-screen wheel→arrow
translation (needs `active_key`, deliberately not mutated — MEDIUM); (2) **latent
LOW** — the render-tick push gate (`src/host/Session.zig`) has no `mode_changed`
term, so a mode change that does NOT coincide with a cell redraw won't propagate;
in practice apps set modes alongside a redraw so it hasn't manifested, but it is
the same class as the Slice-8 cursor-push gap and should get a `mode_changed`
term if a mode-only desync is ever observed.

(historical detail of Phase A below kept for reference.)

## Phase A (detail) — Consume the ModeFrame mirror (R2). HIGHEST LEVERAGE, LOWEST EFFORT.

**One change unblocks the most.** On each `.mode_frame`, apply the decoded
`Client.mode` onto the GUI's `io.terminal.modes`/`flags` (or have the encode
paths read `Client.mode` under `.client`). The data is already on the wire
(Slice 2); only the apply/read side is missing.

Closes (all HIGH unless noted): application cursor mode (DECCKM), Kitty keyboard
flags, keypad, alt-esc/backarrow/modify_other_keys (`encodeKeyOpts` /
`key_encode.fromTerminal`); **bracketed paste** (`paste.fromTerminal`); **mouse
click/release/motion/scroll reporting** + alternate-scroll (the `isMouseReporting`
/ `mouse_event` gate); KAM (`disable_keyboard`); `mouseCaptured`/`isMouseReporting`
predicate (MED); alt-screen wheel-to-arrow (needs the mirror's `alt_screen_active`,
not local `active_key`).

**Net effect:** vim / tmux / less / htop / fzf become usable — the single biggest
step toward "TUI-usable."

**Effort:** Small–Medium. **Risk:** Medium — must apply modes without disturbing
`.exec` (gate on `.client`/mirror presence); the alt-screen/`active_key` accessor
must consult the mirror. **Verify:** unit test that under a client mirror the
encode path sees the mirrored modes; human smoke in vim (arrows, mouse, paste).

---

## Phase B1 — DONE + smoke-validated (commit `07da2b0b9`).

Host-authoritative mouse-DRAG selection + copy. **Smoke-confirmed:** click-drag
shows a highlight; ⌘C copies the selected text and pastes elsewhere. GUI forwards
`SelectionDrag`/`SelectionClear` (viewport coords); host selects on its real
terminal → highlight rides the mirror's `row.selection`; host ships
`SelectionText`; GUI copy/`hasSelection` read the cache (no sync round-trip).
`.exec` untouched. **Deferred to B2:** double-click word / triple-click line /
select-all (boundary-snap + select-all needs history/R3); rich copy formats
(plain-text only) + trailing-space trim under `.client`; URL/regex-link text;
accessibility readout. **Unverified:** right-click → Copy was routed but not
smoke-tested (user doesn't use it) — confirm in B2.

## Phase B2 — DONE + smoke-validated (commit `4c5e080f3`).

Host-authoritative word / line / select-all selection + copy. New `selection_point`
protocol frame (GUI->host: viewport point + granularity mode word/line/all); the host
runs selectWord/selectLine/selectAll on its REAL terminal and ships the result via the
existing mirror path (row.selection highlight + `selection_text` for copy), copying
selectDrag's lock/stage/wakeup discipline. **Smoke-confirmed:** double-click word,
triple-click line, and **select-all + ⌘C yielding the full buffer INCLUDING scrollback**
(the select-all-copy-without-R3 result: host selectAll + selectionString span history;
only the cross-scrollback visual HIGHLIGHT is viewport-limited / R3-deferred). Opus
plan+impl, main-loop tests, independent Opus review (exec-unchanged / lock-safety /
protocol all clean).

**Deferred (explicitly, not silently):** right-click→Copy (B1 routed it but it is
non-functional — DE-PRIORITIZED by the user, low value); `copy_url`/regex-link
selection text; `search_selection` seed; selection autoscroll; rich-copy (HTML/VT
color) metadata; deep-press word select; cross-scrollback selection HIGHLIGHT (R3).

(historical detail of Phase B2 below kept for reference.)

## Phase B2 (detail) — Selection tail, host-authoritative (R1; select-all needs R3).

Make selection a host-driven operation: GUI gesture machinery stays GUI-side but
forwards intent (drag coords, click-count for word/line, select-all) to the host;
the host runs `select()` / `selectionString` / `ScreenFormatter` over its real
screen (with real colors/palette) and ships (a) per-row selection ranges in the
GridFrame mirror (highlight) and (b) selection text via the existing
`clipboard_write` SurfaceEvent (copy).

Closes: drag-select, double/triple-click word/line/output select, **copy** (all
formats + `copy_on_select` + VT/HTML color metadata), `read_selection`/
`has_selection` + the Copy-menu enablement, `copy_url`/regex-link text,
`search_selection` seed, selection autoscroll, deep-press word select.

**Depends on R3 for:** true **select-all** and any selection spanning scrollback
(the visible-viewport selection works without R3).

**Effort:** Medium–High (new GUI→host selection protocol + host handlers + GridFrame
selection already exists from Slice 3b's highlight plumbing). **Risk:** Medium
(gesture→pin mapping across the wire; latency feel). **Verify:** host unit test
(select range → row.selection + selectionString); human smoke (drag, ⌘C).

---

## Phase C — History / scrollback transport (R3). VERDICT: SKIP (not worth it for this usage).

> **A post-A/B/D Opus audit concluded Phase C is not worth funding for this user.**
> Its headline payoffs are already delivered WITHOUT it: reattach-scrollback works
> (push-gate + resizeCols fixes, `e4a8e0927`+`040cb33ca`) and select-all COPY spans
> the full scrollback (B2, `4c5e080f3`). What C still uniquely buys — cross-scrollback
> selection HIGHLIGHT, `write_screen` history dumps, accessibility read-over-history,
> and smooth scrollback PAGING — is not load-bearing for interactive shells, TUIs
> (which own their own scrollback), or CLI agents, while its cost/blast-radius is the
> highest remaining (new history frame + host paging + backpressure + breaking the
> viewport-only invariant everything else assumes). Build C ONLY if a future need for
> true scrollback paging or accessibility-over-history arises. Details below kept for
> that day.

(original Phase C plan retained below for reference.)

## Phase C (detail) — History / scrollback transport (R3). DESIGN-HEAVY; deepest root.

Design a new frame to carry off-viewport rows (history). Options: a
`ScrollbackChunk`-style lazy paging frame (range request → rows), and/or a
bulk-history frame on attach. This is the one genuinely *new protocol* piece.

Closes / enables: `read_text` over history (VoiceOver line/word reads),
`write_screen` (`.history`/full `.screen` dumps), **true select-all** + copy across
history, proper scrollback **paging** (smooth scroll, select+copy across history —
the long-deferred §4.7).

> **The "2nd reattach scrollback-loss on all tabs" bug is RESOLVED — and it was
> NOT R3.** Reproduce-first (as this doc urged) showed it was the suspected
> "reattach-resize reflow," not history transport. It was two independent
> mechanisms: **(1)** the render-tick push gate suppressed the post-reattach
> scroll's `GridFrame` when the scrolled rows matched a stale `prev_snapshot`
> (`pushFullFrames` doesn't update it) — fixed by a `viewport_dirty` force-push
> (`e4a8e0927`); and **(2)** the GUI's post-reattach resize-flood drove a
> shrink-cols+shrink-rows resize whose old cursor `y` exceeded the new row count,
> underflowing `PageList.resizeCols` (`self.rows - c.y - 1`) and crashing the
> WHOLE host — taking down every session (the "all tabs frozen" symptom) — fixed
> by saturating subtraction (`040cb33ca`). Both toggle-proven + live-smoke
> validated (reattach is responsive and shows scrollback). Phase C is therefore
> NOT a prerequisite for reattach scrollback; it remains required only for the
> history-spanning operations listed above.

**Effort:** High (protocol design + host paging + GUI mirror extension beyond
viewport + memory bounds). **Risk:** High (bandwidth/backpressure, the viewport-only
invariant that everything else assumes). **Verify:** host paging tests + the
reattach-scrollback reproduce-first test + human smoke (scroll deep into history,
select across it, reattach keeps it).

---

## Phase D — The R1 tail (assorted local-terminal reads). Lower severity, many small fixes.

Mostly small host-forwards or mirror-reads, each independent:

- **Terminal Reset** + **Clear screen/scrollback (⌘K)** — DONE + smoke-validated
  (commit `97b0dc4d9`). Both forward to the host (new `clear_screen` +`reset`
  frames) and run on its real terminal, mirroring the scrollViewport pattern;
  `.exec` byte-for-byte unchanged. ⌘K reproduces upstream's #905 at-prompt
  heuristic exactly (first press scroll-preserves the screen into scrollback, a
  second press wipes — confirmed `history=true atPrompt=true` reaches the host).
  Reset force-pushes the post-reset GridFrame+ModeFrame (a modes-only reset
  doesn't dirty cells — Opus-review catch, same push-gate class as Slice 8). One
  pre-existing residual: Surface's ⌘K alt-screen guard reads the empty `.client`
  mirror (always `.primary`), so ⌘K on the alt-screen forwards instead of
  returning unconsumed; the host correctly no-ops it, so the only effect is a
  swallowed ⌘K there — a proper fix consults the mirrored mode. Deferred.
- **Cursor-click-to-move at prompt** (incl. kitty click_events / OSC133) — forward
  to host.
- **`cursorIsAtPrompt`** → drives `confirm_close_surface` — DONE + smoke-validated
  (commit `51883807d`). The host computes `cursorIsAtPrompt()` on its REAL terminal
  and pushes an authoritative `at_prompt` bit (pushed on flip + seeded on attach);
  the GUI caches it (lock-free atomic) and `needsConfirmQuit` reads it under
  `.client`. Validated in `confirm-close-surface = true` mode: idle prompt closes
  silently (`at_prompt=true → confirm=false`), a running command prompts
  (`at_prompt=false → confirm=true`). NOTE: only matters for the `= true` mode;
  `= always` (the user's `~/.config/ghostty/config`) confirms unconditionally by
  design and never reaches the at-prompt check.
- **IME candidate-panel anchor** (`imePoint` reads local cursor at origin) — use the
  mirror cursor coords.
- **accessibility viewport rect** (`read_text`/`dumpText` geometry) — derive from
  mirror geometry, not local pages.
- **Quick Look / Look Up word**, **live OS color-scheme DSR (mode 2031)**,
  mouse-shape restore cosmetics, `modsChanged` link-refresh waste — low.

**Effort:** Medium in aggregate (many small items). **Risk:** Low each.

---

## Cross-cutting notes

- **Host side is unbuilt for B/C/D.** The audit assessed the GUI side only; each
  host-authoritative fix needs a matching host StreamHandler/Server handler
  (select, reset, clear, at-prompt bit, history paging). Budget host work per phase.
- **`.exec` must stay byte-for-byte** through all phases (gate every change on
  `.client`/mirror presence).
- **Reproduce-first for the bugs** — the pattern that has reliably found real
  mechanisms here (it pinned the 2nd reattach-scrollback bug to a push-gate +
  a `resizeCols` underflow crash, NOT R3 — see Phase C; `e4a8e0927`+`040cb33ca`).
- **Suggested order:** A (cheap, unblocks TUIs) → B (selection/copy, the most
  user-noticed) → decide on C (history) since it's the costliest and gates the
  rest of B/D's history-dependent parts → D tail as polish. Re-smoke after A and B.

## Decision framing

If the goal is "a daily-driver hosted terminal," Phases A+B+C are effectively
required and represent substantial further investment. If the goal is "reattach a
shell session across GUI restarts" (the original headline), **Phase A alone**
(plus the existing render/reattach/resize work) gets close to a usable
shell-and-TUI experience, with selection/copy (B) as the next most-felt gap; C is
only needed for history-spanning operations.

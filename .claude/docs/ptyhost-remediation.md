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

## Phase A — Consume the ModeFrame mirror (R2). HIGHEST LEVERAGE, LOWEST EFFORT.

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

## Phase B — Selection + copy, host-authoritative (R1; partial R3 dependency).

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

## Phase C — History / scrollback transport (R3). DESIGN-HEAVY; deepest root.

Design a new frame to carry off-viewport rows (history). Options: a
`ScrollbackChunk`-style lazy paging frame (range request → rows), and/or a
bulk-history frame on attach. This is the one genuinely *new protocol* piece.

Closes / enables: `read_text` over history (VoiceOver line/word reads),
`write_screen` (`.history`/full `.screen` dumps), **true select-all** + copy across
history, proper scrollback **paging** (smooth scroll, select+copy across history —
the long-deferred §4.7), and **likely the "2nd reattach scrollback-loss on all
tabs" bug** (REPRODUCE-FIRST to confirm it's R3 vs a reattach-resize reflow before
building).

**Effort:** High (protocol design + host paging + GUI mirror extension beyond
viewport + memory bounds). **Risk:** High (bandwidth/backpressure, the viewport-only
invariant that everything else assumes). **Verify:** host paging tests + the
reattach-scrollback reproduce-first test + human smoke (scroll deep into history,
select across it, reattach keeps it).

---

## Phase D — The R1 tail (assorted local-terminal reads). Lower severity, many small fixes.

Mostly small host-forwards or mirror-reads, each independent:

- **Terminal Reset** + **Clear screen/scrollback (⌘K)** — currently act on the
  empty local terminal / early-return on a stale gate; must reach the host shell
  (forward a reset/clear action; clear must repaint). (MED-HIGH user impact —
  arguably promote above D if ⌘K is common for you.)
- **Cursor-click-to-move at prompt** (incl. kitty click_events / OSC133) — forward
  to host.
- **`cursorIsAtPrompt`** → drives `confirm_close_surface` (always prompts) — needs
  a host-supplied at-prompt bit.
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
- **Reproduce-first for the bugs** (the 2nd reattach-scrollback especially) — the
  pattern that has reliably found real mechanisms here.
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

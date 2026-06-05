# PTY-host — remaining work & decisions

Forward-looking backlog for the `.client` backend. Current state (what works /
durability / goal status) is in `.claude/docs/ptyhost.md`; this file is only the
**open work and the decisions made about it**.

The original audit found ~37 `.client` gaps rooted in three causes — **R1** (GUI
reads the unfed local terminal), **R2** (host mode-mirror not consumed), **R3** (no
history on the wire). R2 is fully closed; R1 is closed except the small items below;
R3 is intentionally not built (see Phase C).

## Decision: Phase C (history transport) — NOT funded

A history-bearing frame (off-viewport rows: paging request → rows, and/or a bulk
history dump on attach) is the one genuinely new protocol piece left. **Decided
against for this usage.** Its headline payoffs are already delivered without it:
reattach restores scrollback, and select-all **copies** the full buffer including
scrollback (the host owns it). What C *uniquely* adds — cross-scrollback selection
*highlight*, `write_screen` history dumps, accessibility read-over-history, and
smooth local scrollback *paging* — is not load-bearing for interactive shells, TUIs
(which own their own scrollback), or CLI agents, while its cost and blast radius are
the highest of anything remaining (new frame + host paging + backpressure + breaking
the viewport-only invariant the rest of the system assumes). Build it only if a real
need for true scrollback paging or accessibility-over-history arises.

## Open: durability / "well" hardening (highest value if pursued)

These are not crashes, but they are the sharpest remaining edges against the goal
(don't lose / can't-get-back-to running work). Both are cheap relative to their value.

- **Silent fresh-spawn on an unknown `session_id`.** On reattach, if the persisted id
  no longer maps to a live session, the GUI spawns a blank shell with no signal
  (`Server.zig` handleAttach "degrade to spawn-fresh"); a lost session looks identical
  to a new one. Options: surface it (a distinct visual/log so the user knows reattach
  missed), and/or list/recover orphaned host sessions.
- **Restorable-state versioning** (macOS state-restoration schema; *not* the host
  protocol version). Already tolerant: `version = 8` but `minimumVersion = 5`, and
  newer fields are optional / `decodeIfPresent`, so older schemas (v5–8) load and
  missing newer fields default to nil. Keep future changes **additive + optional** and
  `minimumVersion` low. A chained "decode-at-version → migrate-up" mechanism is only
  needed for a **non-additive** change (rename/retype/remove a required field), which
  hasn't happened — add the migration seam when such a change is actually required, not
  speculatively.
- **Host lifecycle is manual / unguarded.** No launchd supervision, no SIGTERM/graceful
  shutdown, no per-identity socket namespacing, no orphan GC, and no panic isolation
  (one panic anywhere in the upstream emulator the host runs takes down all sessions).
  Host crash/kill/reboot loses every session by design — this is the single point of
  failure the GUI-restart goal trades against. A supervised, restart-tolerant host is
  the largest possible future investment.

## Open: low-impact feature gaps (R1/R3; optional polish)

All low-to-near-zero impact for this usage (shells/TUIs/agents; no IME/CJK, VoiceOver,
right-click copy). Listed roughly by felt impact:

- **Alt-screen wheel→arrow translation** (R2 residual): wheel in less/man/vim without
  mouse mode sends no synthetic arrows. The mirror deliberately doesn't apply
  `alt_screen_active`; the wheel path reads the stale local `active_key`. Apps that
  request real mouse reporting already work.
- **Cursor-click-to-move at the prompt** (R1): clicking to reposition the readline
  cursor no-ops. Needs a host click→prompt-move forward (mirrors the clear/reset
  host-forward pattern).
- **Selection autoscroll past the viewport edge** (R1/R3): drag-select beyond the top/
  bottom edge doesn't grow into scrollback. Fold into host-authoritative selection.
- **regex-link / copy_url text extraction; `search_selection` seed** (R1): regex links
  are detected but their text is pulled from the empty local terminal. OSC8 links are
  fine (host-computed).
- **`write_screen` history dump; `read_text`/accessibility over history** (R3): need
  off-viewport rows — gated on Phase C (not funded).
- **IME preedit anchor; Quick Look / Look Up word** (R1): near-zero (no IME/CJK).
- **Live OS color-scheme DSR (mode 2031); right-click→Copy** (R1/R2): near-zero /
  de-prioritized by the user.
- **⌘K on the alt-screen** (cosmetic): forwarded instead of returning unconsumed; the
  host no-ops it, so only the keybind is swallowed.

## Working method for these

Each item is small and independent; the proven pattern is main-loop reproduce-first
test → implement gated on `.client` (`.exec` byte-for-byte) → full host/client/Screen/
Terminal suites → a single foreground Opus review → live smoke. Keep the host tiny and
its protocol additive (a host rebuild kills live sessions).

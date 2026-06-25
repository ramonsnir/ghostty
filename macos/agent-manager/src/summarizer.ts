// (ramon fork / Agent Manager) Phase-1 summarizer pure core. ALL functions here
// are PURE (no I/O, no clock-of-their-own) and unit-tested: the deterministic TS
// control loop in index.ts calls them to decide WHEN to summarize and HOW to
// build the prompt, and to PARSE the model's reply. Keeping these pure is the A+
// gate's load-bearing property — the skip/debounce/budget truth table and the
// tolerant JSON parse are tested directly, not through the SDK.

import type { Surface } from "./mcp.js";
import { composeSystemPrompt } from "./prompt.js";

/** The agent kinds we summarize. A surface is an "agent surface" if it carries an
 *  agentState OR a known agent processName — i.e. the dashboard detected an agent.
 *  Tunable via cfg.agentProcessNames. */
export interface SummarizerConfig {
  /** Min ms between model calls for one session. Default 30000. */
  debounceMs: number;
  /** If the change-tail is unchanged AND idleSeconds >= this, skip. Default 45.
   *  (A quiescent waiting/idle agent is skipped on an unchanged tail regardless of
   *  this — see `shouldSummarize`; this only governs a non-quiescent surface whose
   *  state we can't otherwise prove is settled.) */
  idleSkipSeconds: number;
  /** Max concurrent in-flight model calls across all sessions. Doubles as the
   *  per-sweep BATCH cap (the sweep fires up to this many due surfaces then breaks),
   *  so it bounds how many tiles refresh per poll. Default 10 — large enough that a
   *  typical multi-agent fleet is fully covered each sweep (small fleets never come
   *  close to the cap). */
  maxConcurrent: number;
  /** How many trailing viewport lines feed the CHANGE-DETECTION tail. Kept tight
   *  (default 20) so the change-tail flips promptly on real activity. */
  fingerprintTailLines: number;
  /** How many trailing viewport lines feed the model PROMPT. Larger than the
   *  change-detection window (default 40) so the summary has enough context to name
   *  the task/phase — a TUI's last few lines are often just the input box. */
  promptTailLines: number;
  /** Fuzzy change threshold (0..1): the screen counts as CHANGED only when the
   *  fraction of differing change-tail lines EXCEEDS this. A small animation (a
   *  spinner / elapsed-time counter on one footer line) stays below it and does NOT
   *  trigger a re-summary. Default 0.2 (> ~20% of the tail lines must differ). Set 0
   *  to treat ANY difference as a change (the old binary behavior). */
  changeRatioThreshold: number;
  /** When true (default), the summarizer SKIPS surfaces the user has HIDDEN in the
   *  Agent Dashboard — no Haiku call for a decluttered tile. */
  skipHidden: boolean;
  /** Cap (ms) on the adaptive RATE-LIMIT BACKOFF: when the summarizer's OWN model
   *  calls keep failing (its account is rate-limited / returns no usable summary), the
   *  loop backs off exponentially — `debounceMs * 2^(streak-1)` — up to this cap, and
   *  while backed off makes at most ONE probe call per window until one SUCCEEDS (the
   *  limit reset), then snaps back to normal. Default 600000 (10 min). */
  rateLimitBackoffMaxMs: number;
  /** Process names that mark an agent surface even without agentState. */
  agentProcessNames: string[];
}

export const DEFAULT_CONFIG: SummarizerConfig = {
  debounceMs: 30000,
  idleSkipSeconds: 45,
  maxConcurrent: 10,
  fingerprintTailLines: 20,
  promptTailLines: 40,
  changeRatioThreshold: 0.2,
  skipHidden: true,
  rateLimitBackoffMaxMs: 600000,
  agentProcessNames: ["claude", "codex"],
};

/**
 * The adaptive rate-limit backoff delay (ms) for a given consecutive-failure
 * `streak`: exponential `baseMs * 2^(streak-1)`, capped at `maxMs`. PURE. A streak of
 * 0 (or less) returns 0 (normal cadence). The streak is clamped before the shift so a
 * large streak can't overflow. With base=30s, cap=10min: 30s, 60s, 120s, 240s, 480s,
 * 600s, 600s, … — so within a few failed sweeps the summarizer probes only ~once per
 * 10 min until a call succeeds (the account's limit resets).
 */
export function backoffDelayMs(streak: number, baseMs: number, maxMs: number): number {
  if (streak <= 0) return 0;
  const shift = Math.min(streak - 1, 30); // guard 2^huge
  return Math.min(maxMs, baseMs * 2 ** shift);
}

/** A point-in-time view of one surface, enriched with its viewport text. */
export interface SurfaceSnapshot {
  surface: Surface;
  /** Viewport text from read_surface, or "" when not yet read. */
  viewport: string;
}

/** The record the loop keeps per session from the last successful summary. The
 *  change-detector compares `signals` (an exact hash of the hook tuple) and `tail`
 *  (the NORMALIZED change-tail, kept as text so a FUZZY ratio can be computed) — see
 *  `shouldSummarize`. */
export interface LastSummary {
  /** Exact hash of the hook signals (agentState | lastPrompt | lastTool) at the last
   *  call. Any difference is a meaningful change (those are authoritative). */
  signals: string;
  /** The NORMALIZED change-tail (spinner glyphs stripped, digit-runs collapsed) from
   *  the last call — compared fuzzily against the current tail via `tailChangeRatio`. */
  tail: string;
  atMs: number;
  summary: string;
}

/** The context handed to the model for one summary call. */
export interface SummaryContext {
  title: string;
  pwd: string;
  agentState?: string;
  lastPrompt?: string;
  lastTool?: string;
  /** The summarizer's own previous summary (round-tripped via list_surfaces.notes
   *  or the loop's LastSummary), for continuity. */
  previousSummary?: string;
  idleSeconds?: number;
  viewportTail: string;
}

/** The parsed, validated model output. */
export interface ParsedSummary {
  summary: string;
  phase?: string;
  needsUser?: boolean;
  /** An optional ATTENTION tag (e.g. "rate_limited") the model emits when the
   *  screen shows an unresolved condition that should ring the user. The loop
   *  edge-triggers signal_attention on it. Lower-cased + trimmed; omitted when
   *  the model emits no usable tag. */
  alert?: string;
}

/** The alert tag for the Claude usage/rate-limit blocking prompt. Used by both
 *  the deterministic `detectAlert` and the model's `alert` field. */
export const ALERT_RATE_LIMITED = "rate_limited";

/** Max length of a summary; longer is truncated (the contract says <= 80, we are
 *  tolerant up to 120 then hard-truncate). */
export const SUMMARY_MAX_LEN = 120;

/**
 * Decide whether a surface is an agent surface worth summarizing at all. PURE.
 * Exited surfaces are never agents. Otherwise true when ANY of:
 *   - `agentKind` is set — the dashboard's AUTHORITATIVE subtree-walk detection
 *     (the primary, reliable signal: it finds the real `claude`/`codex` even when
 *     the foreground process is a wrapper like the claude-pool `bash`);
 *   - `agentState` is set — a Claude Code hook has reported for this surface;
 *   - `processName` matches the agent list — a last-resort fallback for a bare
 *     agent run without the dashboard detector or hooks (rarely the deciding
 *     factor in the pool setup, where the foreground is `bash`).
 */
export function isAgentSurface(s: Surface, cfg: SummarizerConfig): boolean {
  if (s.exited) return false;
  if (typeof s.agentKind === "string" && s.agentKind.length > 0) return true;
  if (typeof s.agentState === "string" && s.agentState.length > 0) return true;
  if (typeof s.processName === "string") {
    return cfg.agentProcessNames.includes(s.processName);
  }
  return false;
}

/** True for an agent whose hook state is QUIESCENT — waiting for the user or idle
 *  (done with its turn). A quiescent agent's summary won't change on its own, so an
 *  unchanged change-tail means there's nothing new to say even if the footer is still
 *  animating (spinner / "esc to interrupt" / elapsed timer). PURE. undefined => not
 *  quiescent (no hook signal — fall through to the idle-seconds skip instead). */
export function isQuiescent(agentState: string | undefined): boolean {
  return agentState === "waiting" || agentState === "idle";
}

/** Exact hash of the AUTHORITATIVE hook signals (agentState | lastPrompt | lastTool).
 *  Any difference here is a meaningful change — the user submitted a new prompt, a new
 *  tool fired, or the lifecycle state flipped — and always re-summarizes. PURE. */
export function changeSignals(s: Surface): string {
  return fnv1a(
    [s.agentState ?? "", s.lastPrompt ?? "", s.lastTool ?? ""].join(" "),
  );
}

/** The NORMALIZED change-detection tail: the last ~N viewport lines with volatile
 *  animation neutralized (spinner glyphs stripped, digit-runs collapsed, whitespace
 *  collapsed) so a spinner / elapsed-time counter doesn't read as a change. PURE.
 *  Kept as TEXT (not a hash) so `tailChangeRatio` can compare it fuzzily. */
export function changeTail(viewport: string, cfg: SummarizerConfig): string {
  return lastLines(viewport, cfg.fingerprintTailLines)
    .split("\n")
    .map(normalizeChangeLine)
    .join("\n");
}

/**
 * Fuzzy dissimilarity (0..1) between two normalized change-tails, computed as the
 * Jaccard distance over their NON-BLANK line MULTISETS: 1 - |intersection| / |union|.
 * PURE. 0 = identical line content (order/scroll-tolerant), 1 = nothing in common.
 * Two empty tails are identical (0). Using a multiset (not positional compare) means a
 * single new line scrolling in barely moves the ratio, while a screen of fresh output
 * pushes it high — exactly the "small change vs real change" distinction we want.
 */
export function tailChangeRatio(prevTail: string, curTail: string): number {
  const a = lineMultiset(prevTail);
  const b = lineMultiset(curTail);
  let inter = 0;
  let union = 0;
  const keys = new Set<string>([...a.keys(), ...b.keys()]);
  for (const k of keys) {
    const ca = a.get(k) ?? 0;
    const cb = b.get(k) ?? 0;
    inter += Math.min(ca, cb);
    union += Math.max(ca, cb);
  }
  return union === 0 ? 0 : 1 - inter / union;
}

/**
 * The skip/due decision. PURE. Rules (each tested), in order:
 *   - not an agent surface              -> {due:false, reason:"not-agent"}
 *   - hidden (and cfg.skipHidden)       -> {due:false, reason:"hidden"}
 *   - within debounceMs of last call    -> {due:false, reason:"debounce"}
 *   - first time for this session       -> {due:true,  reason:"first"}
 *   - hook signals changed              -> {due:true,  reason:"changed-signal"}
 *   - change-tail ratio > threshold     -> {due:true,  reason:"changed"}
 *   - else unchanged + quiescent        -> {due:false, reason:"quiescent-unchanged"}
 *   - else unchanged + provably idle    -> {due:false, reason:"idle-unchanged"}
 *   - else unchanged, non-quiescent     -> {due:true,  reason:"unchanged-not-idle"}
 *
 * The headline cost fix is the QUIESCENT skip combined with the FUZZY ratio: a
 * waiting/idle agent whose footer is merely animating (spinner / timer) is no longer
 * re-summarized every debounce window — its tail compares EQUAL under the ratio, and a
 * quiescent agent has nothing new to say. A non-quiescent unchanged surface still
 * re-summarizes (old behavior) so a working agent's phase keeps tracking. Debounce is
 * checked BEFORE change detection so a just-summarized session never re-fires.
 */
export function shouldSummarize(
  s: SurfaceSnapshot,
  last: LastSummary | undefined,
  nowMs: number,
  cfg: SummarizerConfig,
): { due: boolean; reason: string } {
  if (!isAgentSurface(s.surface, cfg)) {
    return { due: false, reason: "not-agent" };
  }

  if (cfg.skipHidden && s.surface.hidden === true) {
    return { due: false, reason: "hidden" };
  }

  if (last && nowMs - last.atMs < cfg.debounceMs) {
    return { due: false, reason: "debounce" };
  }

  if (last === undefined) return { due: true, reason: "first" };

  if (changeSignals(s.surface) !== last.signals) {
    return { due: true, reason: "changed-signal" };
  }

  const ratio = tailChangeRatio(last.tail, changeTail(s.viewport, cfg));
  if (ratio > cfg.changeRatioThreshold) {
    return { due: true, reason: "changed" };
  }

  // Unchanged (no meaningful signal change, tail within the fuzzy threshold).
  if (isQuiescent(s.surface.agentState)) {
    return { due: false, reason: "quiescent-unchanged" };
  }
  const idle = s.surface.idleSeconds;
  if (typeof idle === "number" && idle >= cfg.idleSkipSeconds) {
    return { due: false, reason: "idle-unchanged" };
  }
  // Unchanged but neither quiescent nor provably idle: re-summarize (a working agent
  // whose tail happens to sit below the ratio this tick — debounce already passed).
  return { due: true, reason: "unchanged-not-idle" };
}

/**
 * Cheap pre-gate using ONLY list_surfaces row fields (no viewport read). PURE.
 * Lets the sweep skip non-agent / hidden / debounced surfaces WITHOUT a read_surface
 * round-trip; the full `shouldSummarize` (which needs the viewport for the fuzzy tail)
 * runs after the read. Returns:
 *   - not an agent surface           -> {pass:false, reason:"not-agent"}
 *   - hidden (and cfg.skipHidden)    -> {pass:false, reason:"hidden"}
 *   - within debounceMs of last call -> {pass:false, reason:"debounce"}
 *   - otherwise                      -> {pass:true,  reason:"candidate"}
 * Mirrors the row-only clauses of shouldSummarize so the two never disagree (and the
 * hidden skip here AVOIDS the read_surface entirely for a hidden tile).
 */
export function preGate(
  s: Surface,
  last: LastSummary | undefined,
  nowMs: number,
  cfg: SummarizerConfig,
): { pass: boolean; reason: string } {
  if (!isAgentSurface(s, cfg)) return { pass: false, reason: "not-agent" };
  if (cfg.skipHidden && s.hidden === true) return { pass: false, reason: "hidden" };
  if (last && nowMs - last.atMs < cfg.debounceMs) {
    return { pass: false, reason: "debounce" };
  }
  return { pass: true, reason: "candidate" };
}

/** Build the SummaryContext fed to the model from a snapshot + its prior summary. */
export function buildContext(
  s: SurfaceSnapshot,
  previousSummary: string | undefined,
  cfg: SummarizerConfig,
): SummaryContext {
  return {
    title: s.surface.title,
    pwd: s.surface.pwd,
    agentState: s.surface.agentState,
    lastPrompt: s.surface.lastPrompt,
    lastTool: s.surface.lastTool,
    previousSummary,
    idleSeconds: s.surface.idleSeconds,
    viewportTail: lastLines(s.viewport, cfg.promptTailLines),
  };
}

/**
 * Serialize a SummaryContext into the user-prompt text for the single-shot call.
 * PURE. Omits unknown fields so the model is not fed empty signals.
 */
export function serializeContext(ctx: SummaryContext): string {
  // Actionable signals first (state + the user's request drive the lead of the
  // summary), then identity/context, then the raw output for the phase.
  const lines: string[] = [];
  if (ctx.agentState) lines.push(`Agent state: ${ctx.agentState}`);
  if (ctx.lastPrompt) lines.push(`User request: ${ctx.lastPrompt}`);
  if (ctx.lastTool) lines.push(`Last tool: ${ctx.lastTool}`);
  lines.push(`Session title: ${ctx.title || "(untitled)"}`);
  if (ctx.pwd) lines.push(`Directory: ${ctx.pwd}`);
  if (typeof ctx.idleSeconds === "number") {
    lines.push(`Idle seconds: ${ctx.idleSeconds.toFixed(1)}`);
  }
  if (ctx.previousSummary) {
    lines.push(`Your previous summary: ${ctx.previousSummary}`);
  }
  lines.push("");
  lines.push("Recent terminal output (most recent last):");
  lines.push(ctx.viewportTail || "(no output)");
  return lines.join("\n");
}

/**
 * Compose the full prompt pair for a call. PURE. Convenience wrapper around
 * composeSystemPrompt + serializeContext so the loop has one entry point.
 */
export function composePrompt(
  base: string,
  override: string | null,
  ctx: SummaryContext,
): { system: string; user: string } {
  return {
    system: composeSystemPrompt(base, override),
    user: serializeContext(ctx),
  };
}

/**
 * Tolerant parser for the model's reply. PURE. Strips markdown code fences,
 * then walks EVERY balanced top-level JSON object in the text (in order) and
 * returns the FIRST that parses to a non-array object carrying a non-empty
 * string `summary`. This tolerates a preamble/reasoning object before the answer
 * object, prose with stray `{...}` braces before the real JSON, and trailing
 * junk. `summary` is trimmed + truncated to SUMMARY_MAX_LEN by CODE POINT (so a
 * multibyte char is never split into a lone surrogate); `needsUser` is coerced
 * to a boolean; `phase` is kept only when a non-empty string. Returns null when
 * no usable summary can be recovered from any candidate object.
 */
export function parseSummary(modelText: string): ParsedSummary | null {
  if (typeof modelText !== "string") return null;
  const cleaned = stripFences(modelText);

  for (const objText of eachJsonObject(cleaned)) {
    let obj: unknown;
    try {
      obj = JSON.parse(objText);
    } catch {
      continue; // not valid JSON (e.g. a prose `{...}`); try the next object
    }
    if (obj === null || typeof obj !== "object" || Array.isArray(obj)) continue;

    const rec = obj as Record<string, unknown>;
    const rawSummary = rec.summary;
    if (typeof rawSummary !== "string") continue; // summary-less; try the next
    const summary = rawSummary.trim();
    if (summary.length === 0) continue;

    const result: ParsedSummary = { summary: truncateCodePoints(summary, SUMMARY_MAX_LEN) };

    if (typeof rec.phase === "string") {
      const phase = rec.phase.trim();
      if (phase.length > 0) result.phase = phase;
    }
    if ("needsUser" in rec) {
      result.needsUser = coerceBool(rec.needsUser);
    }
    if (typeof rec.alert === "string") {
      const alert = rec.alert.trim().toLowerCase();
      if (alert.length > 0) result.alert = alert;
    }
    return result;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Attention edge (ramon fork) — the rate-limit / "needs you" bell. The CLASSIFY
// decision is the model's (the `alert` field of parseSummary): Haiku judges the
// CURRENT, live state from the whole screen, so it can tell an ACTIVE blocking
// prompt from the same text merely scrolled up in history (which a regex never
// could — that was the recovery / false-positive trap). This module only owns
// the EDGE bookkeeping below so the loop rings once on a rising edge and re-arms
// when the model says the condition has cleared.
// ---------------------------------------------------------------------------

/**
 * Decide the edge action for an alert tag given the previously-seen tag for the
 * same surface. PURE. Returns:
 *   - "ring"  when a (different/new) alert is present that wasn't the last one
 *             — the loop should signal_attention AND record `current`.
 *   - "clear" when the alert went away (was present, now none) — record undefined.
 *   - "none"  when nothing changed (same tag held, or still no alert).
 * Edge-triggering keeps a stuck prompt from re-ringing every sweep, while a
 * screen change (the user acting) clears it and re-arms the next occurrence.
 */
export function alertEdge(
  prev: string | undefined,
  current: string | undefined,
): "ring" | "clear" | "none" {
  if (current) return current === prev ? "none" : "ring";
  return prev ? "clear" : "none";
}

/** A simple concurrency budget: a counter capped at maxConcurrent. Not pure
 *  state but a trivial, testable value type. */
export class ConcurrencyBudget {
  private inFlight = 0;
  constructor(private readonly max: number) {}
  /** Try to acquire a slot; returns true on success. */
  tryAcquire(): boolean {
    if (this.inFlight >= this.max) return false;
    this.inFlight++;
    return true;
  }
  /** Release a slot. */
  release(): void {
    if (this.inFlight > 0) this.inFlight--;
  }
  get active(): number {
    return this.inFlight;
  }
}

// ---------------------------------------------------------------------------
// Pure helpers (also exported for direct unit testing).
// ---------------------------------------------------------------------------

/** Return the last `n` lines of `text` (trailing newline tolerant). */
export function lastLines(text: string, n: number): string {
  if (!text) return "";
  const lines = text.split("\n");
  // Drop a single trailing empty line from a terminal newline so the "last 20"
  // are 20 real lines, not 19 + blank.
  if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop();
  return lines.slice(Math.max(0, lines.length - n)).join("\n");
}

/** Spinner / progress glyphs that animate on a TUI footer without meaning a real
 *  change. Includes the Braille range (U+2800–U+28FF, the common spinner alphabet),
 *  the dot/circle spinners, and the ASCII `|/-\\` bar. Used by `normalizeChangeLine`. */
const SPINNER_GLYPHS = /[⠀-⣿◐◓◑◒◴◷◶◵⠿✶✻✽✳·]/g;

/** Normalize ONE viewport line for fuzzy change detection: drop spinner glyphs,
 *  collapse digit runs to a single `#` (so an incrementing elapsed-time / token
 *  counter doesn't read as a change), and collapse whitespace. PURE. The point is
 *  that an idle agent's animated footer line normalizes to a STABLE string across
 *  ticks, so its change-tail compares equal. */
export function normalizeChangeLine(line: string): string {
  return line
    .replace(SPINNER_GLYPHS, "")
    .replace(/\d+/g, "#")
    .replace(/\s+/g, " ")
    .trim();
}

/** Multiset (line -> count) of the NON-BLANK lines of a (already-normalized) tail.
 *  PURE. Blank lines are dropped so trailing/interior blank churn doesn't dominate
 *  the Jaccard ratio. */
export function lineMultiset(tail: string): Map<string, number> {
  const m = new Map<string, number>();
  for (const raw of tail.split("\n")) {
    const line = raw.trim();
    if (line.length === 0) continue;
    m.set(line, (m.get(line) ?? 0) + 1);
  }
  return m;
}

/** FNV-1a 32-bit hash as an 8-char hex string. Dependency-free + deterministic. */
export function fnv1a(input: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < input.length; i++) {
    h ^= input.charCodeAt(i);
    // 32-bit FNV prime multiply via shifts to stay in 32-bit range.
    h = (h + ((h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24))) >>> 0;
  }
  return h.toString(16).padStart(8, "0");
}

/** Coerce common truthy/falsey JSON values to a boolean. */
export function coerceBool(v: unknown): boolean {
  if (typeof v === "boolean") return v;
  if (typeof v === "number") return v !== 0;
  if (typeof v === "string") {
    const s = v.trim().toLowerCase();
    return s === "true" || s === "yes" || s === "1";
  }
  return false;
}

/** Strip leading/trailing markdown code fences (```json ... ``` or ``` ... ```). */
export function stripFences(text: string): string {
  let t = text.trim();
  // Remove a leading fence line.
  const fenceStart = /^```[a-zA-Z]*\s*\n?/;
  if (fenceStart.test(t)) {
    t = t.replace(fenceStart, "");
    // Remove a trailing closing fence.
    t = t.replace(/\n?```\s*$/, "");
  }
  return t.trim();
}

/** Truncate `s` to at most `maxCodePoints` Unicode code points (NOT UTF-16 code
 *  units), so a surrogate pair (emoji / astral char) at the boundary is never
 *  split into a lone surrogate that would ship as ill-formed UTF-16. PURE. */
export function truncateCodePoints(s: string, maxCodePoints: number): string {
  const cps = Array.from(s); // iterates by code point, keeping surrogate pairs whole
  if (cps.length <= maxCodePoints) return s;
  return cps.slice(0, maxCodePoints).join("");
}

/**
 * Yield EVERY balanced top-level JSON object substring in `text`, in order,
 * respecting strings and escapes so braces inside string values don't fool the
 * brace counter. After a balanced object is yielded, scanning resumes AFTER it
 * (top-level only — nested objects are part of their parent, not yielded
 * separately). A `{` that never closes is ignored (no partial yield). PURE.
 */
export function* eachJsonObject(text: string): Generator<string> {
  let i = 0;
  while (i < text.length) {
    const start = text.indexOf("{", i);
    if (start < 0) return;
    let depth = 0;
    let inString = false;
    let escaped = false;
    let closed = -1;
    for (let j = start; j < text.length; j++) {
      const ch = text[j];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch === "\\") {
          escaped = true;
        } else if (ch === '"') {
          inString = false;
        }
        continue;
      }
      if (ch === '"') {
        inString = true;
      } else if (ch === "{") {
        depth++;
      } else if (ch === "}") {
        depth--;
        if (depth === 0) {
          closed = j;
          break;
        }
      }
    }
    if (closed < 0) return; // unclosed `{` — no further balanced objects
    yield text.slice(start, closed + 1);
    i = closed + 1;
  }
}

/**
 * Find the FIRST balanced JSON object substring in `text` (the first one
 * `eachJsonObject` yields), or null if none is found. PURE. Retained for
 * direct unit testing of the balance/escape scanner.
 */
export function extractFirstJsonObject(text: string): string | null {
  for (const obj of eachJsonObject(text)) return obj;
  return null;
}

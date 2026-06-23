// (ramon fork / Agent Manager) Phase-2 MANAGER: a per-session reply SUGGESTER.
// SUGGEST-ONLY — it emits ONE proposed reply (text) that the dashboard shows for
// the user to Approve/Edit/Dismiss; it NEVER sends input and has NO send tools.
//
// ARCHITECTURE (locked, mirrors the Phase-1 summarizer EXACTLY): a deterministic
// TS control loop drives a SINGLE-SHOT, NON-AGENTIC Opus call. Persistent per-
// session memory was considered (the SDK's `resume`/`sessionId` IS available in
// v0.3.185 — see model.ts notes), but Phase 2 takes the SINGLE-SHOT-WITH-
// ACCUMULATED-CONTEXT fallback the Map recommended: lowest-risk, stateless, no
// per-agent process lifecycle, and it reuses the proven `summarize`-style injected
// `QueryFn` shape. The "memory" is fed in the prompt by the loop each call (the
// session GOALS = userNotes + recent prompts, the prior suggestion, the screen).
// If multi-turn memory is later required, upgrade to `options.resume` with a
// per-surface persisted UUID — the smallest delta.
//
// ALL pure decision/format/parse helpers live here and are unit-tested: WHEN to
// suggest (waiting-only + debounce + unchanged-skip), HOW to assemble the goals +
// prompt, and the tolerant JSON parse of the model's reply.

import type { Surface } from "./mcp.js";
import { composeSystemPrompt } from "./prompt.js";
import {
  DEFAULT_CONFIG,
  eachJsonObject,
  fingerprint as summarizerFingerprint,
  fnv1a,
  lastLines,
  stripFences,
  truncateCodePoints,
} from "./summarizer.js";
import type { SummarizerConfig, SurfaceSnapshot } from "./summarizer.js";

/** The default manager model. Free-form string (no SDK enum), per the Map. */
export const MANAGER_MODEL = "claude-opus-4-8";

/** Max length of a suggestion; longer is hard-truncated by code point. A reply is
 *  a short line the user would type, so this is generous. */
export const SUGGESTION_MAX_LEN = 600;

export interface ManagerConfig {
  /** Min ms between manager calls for one session. Default 20000 (>= the spec's
   *  ~20s manager debounce; deliberately slower than the summarizer's 12s — Opus
   *  is dearer and a waiting agent isn't urgent-by-the-second). */
  debounceMs: number;
  /** How many trailing viewport lines feed the manager PROMPT (the agent's "what
   *  am I blocked on" screen). Default 60 — a bit more than the summarizer's 40 so
   *  the question + its options are captured. */
  promptTailLines: number;
  /** How many trailing viewport lines feed the CHANGE-DETECTION fingerprint.
   *  Default 30. */
  fingerprintTailLines: number;
  /** Max concurrent in-flight manager calls. The manager has its OWN budget
   *  (NOT shared with the summarizer) so a busy summarizer can never starve it —
   *  the bug where, with ≥summarizer-cap due summaries every sweep, the manager
   *  pass got zero slots and never proposed. Default 4. */
  maxConcurrent: number;
  /** SUPPRESS floor: a parsed suggestion whose confidence is BELOW this is treated
   *  as an abstain — NOT written, so the tile shows nothing (the prompt already asks
   *  the model to abstain via an empty suggestion when it would only pad; this is the
   *  code backstop for when it pads anyway with a low self-rating). Default 0.35;
   *  the tile's own dim threshold (0.5) then de-emphasizes the 0.35-0.5 band that IS
   *  shown. Set to 0 to disable suppression (show everything the model returns). */
  suppressBelow: number;
}

export const DEFAULT_MANAGER_CONFIG: ManagerConfig = {
  debounceMs: 20000,
  promptTailLines: 60,
  fingerprintTailLines: 30,
  maxConcurrent: 4,
  suppressBelow: 0.35,
};

/** A point-in-time view of one surface, enriched with its viewport text. */
export interface ManagerSnapshot {
  surface: Surface;
  /** Viewport text from read_surface, or "" when not yet read. */
  viewport: string;
}

/** Default confidence used when the model omits the field or emits an invalid
 *  value. Mid-scale (NOT dimmed by the tile's default threshold). */
export const DEFAULT_CONFIDENCE = 0.5;

/** The record the loop keeps per session from the last suggestion attempt.
 *  `fingerprint` is the manager's own debounce fingerprint (goals + tail); it
 *  doubles as `lastSuggestFingerprint`. `suppressedFingerprint` (Phase 2.1) is the
 *  summarizer-style fingerprint at which the user DISMISSED the suggestion — while
 *  the current summarizer-style fingerprint equals it, the manager skips
 *  re-suggesting; null = not suppressed. */
export interface LastSuggestion {
  fingerprint: string;
  atMs: number;
  suggestion: string;
  suppressedFingerprint?: string | null;
}

/** The parsed, validated manager output. */
export interface ParsedSuggestion {
  suggestion: string;
  /** The manager's HONEST 0..1 self-rating of goal-advancement. ALWAYS populated
   *  (defaulted to DEFAULT_CONFIDENCE when absent/invalid) + clamped to [0,1]. */
  confidence: number;
  rationale?: string;
}

/** The context handed to the model for one suggestion call. */
export interface SuggestionContext {
  title: string;
  pwd: string;
  /** The assembled session goals (userNotes strongest, then recent prompts). */
  goals: string;
  /** The previous suggestion (for continuity / to avoid repeating), if any. */
  previousSuggestion?: string;
  viewportTail: string;
}

/**
 * Assemble the session GOALS string the manager honors. PURE. The user's
 * per-session NOTE is the STRONGEST signal (listed first, labeled), then the most
 * recent user prompt. Empty when neither is present (the manager then proposes a
 * conservative reply and says so). `lastPrompt` is the only prompt the dashboard
 * surfaces today; the param is an array so a future multi-prompt feed slots in.
 */
export function assembleGoals(
  userNotes: string | undefined,
  recentPrompts: Array<string | undefined>,
): string {
  const lines: string[] = [];
  const note = userNotes?.trim();
  if (note) lines.push(`User's note for this session (TOP PRIORITY): ${note}`);
  const prompts = recentPrompts
    .map((p) => p?.trim())
    .filter((p): p is string => !!p);
  for (const p of prompts) lines.push(`Recent user request: ${p}`);
  return lines.join("\n");
}

/**
 * Stable fingerprint of the suggestion-relevant state: the goals + the last ~N
 * viewport lines. PURE. A change means "the situation moved, re-suggest once
 * debounce passes". Reuses the summarizer's FNV-1a.
 */
export function fingerprint(
  s: ManagerSnapshot,
  goals: string,
  cfg: ManagerConfig,
): string {
  const tail = lastLines(s.viewport, cfg.fingerprintTailLines);
  return fnv1a([goals, tail].join(" "));
}

/**
 * The "meaningful change" fingerprint for DISMISS-SUPPRESSION. PURE. Deliberately
 * reuses the SUMMARIZER's fingerprint (agentState | lastPrompt | lastTool + viewport
 * tail) — NOT the manager's own debounce fingerprint (goals + tail) — so "the
 * situation meaningfully changed" matches the summarizer's notion exactly (per the
 * Phase-2.1 contract). A `ManagerSnapshot` is structurally a `SurfaceSnapshot`
 * (`{surface, viewport}`); the tail window comes from the shared SummarizerConfig
 * (`DEFAULT_CONFIG` by default) so both layers hash the same lines.
 */
export function dismissFingerprint(
  s: ManagerSnapshot,
  summarizerCfg: SummarizerConfig = DEFAULT_CONFIG,
): string {
  return summarizerFingerprint(s as SurfaceSnapshot, summarizerCfg);
}

/**
 * The suggest/skip decision. PURE. Rules (each tested), evaluated in order:
 *   - exited                         -> {due:false, reason:"exited"}
 *   - agent NOT waiting              -> {due:false, reason:"not-waiting"}
 *   - within debounceMs of last call -> {due:false, reason:"debounce"}
 *   - (Phase 2.1) DISMISS-SUPPRESSION — evaluated for a DISMISSED surface BEFORE the
 *     manager `unchanged` gate, so the suppression arms AT DISMISS TIME (when the
 *     screen+goals are stable, which is the NORMAL `waiting` case) rather than being
 *     short-circuited by `unchanged`. The arm value, the unchanged compare, and the
 *     changed compare ALL live in the SUMMARIZER fingerprint space
 *     (`dismissFingerprint` = agentState|lastPrompt|lastTool + viewport tail) — NOT
 *     the manager debounce fingerprint (`last.fingerprint` = goals + tail), which is
 *     a DIFFERENT hash space and must NEVER be used to arm (mixing the two would make
 *     `armed === dfp` never match, re-firing a dismissed suggestion every sweep):
 *       * dismissed + suppression NOT yet armed -> ARM it: return
 *         {due:false, reason:"dismissed-arm", suppressedFingerprint:dfp} where
 *         `dfp = dismissFingerprint(s)` is the CURRENT summarizer fingerprint (the
 *         dismissed screen). The caller persists it.
 *       * dismissed + the summarizer-style fingerprint UNCHANGED vs. the armed value
 *         -> {due:false, reason:"dismissed-unchanged"}.
 *       * dismissed + the summarizer-style fingerprint CHANGED vs. the arm
 *         -> {due:true, reason:"dismissed-changed", suppressedFingerprint:null}
 *         (a SINGLE meaningful change re-suggests + clears suppression).
 *   - (not dismissed) fingerprint unchanged since the last suggestion
 *                                    -> {due:false, reason:"unchanged"}
 *   - otherwise                      -> {due:true, reason:"first"|"changed",
 *                                        suppressedFingerprint:null}.
 *
 * Manager fires ONLY for a `waiting` agent (NOT working/idle), per the spec — a
 * suggestion is meaningless mid-work. `unchanged` skip avoids re-proposing the
 * SAME reply for the SAME screen (the user may simply not have acted yet).
 *
 * `suppressedFingerprint` in the return is the value the caller should PERSIST onto
 * the session's LastSuggestion: undefined ⇒ leave as-is; a string ⇒ arm to it; null
 * ⇒ clear. `last.suppressedFingerprint` carries the currently-armed value in.
 */
export function shouldSuggest(
  s: ManagerSnapshot,
  goals: string,
  last: LastSuggestion | undefined,
  nowMs: number,
  cfg: ManagerConfig,
  summarizerCfg: SummarizerConfig = DEFAULT_CONFIG,
): { due: boolean; reason: string; suppressedFingerprint?: string | null } {
  if (s.surface.exited) return { due: false, reason: "exited" };
  if (s.surface.agentState !== "waiting") {
    return { due: false, reason: "not-waiting" };
  }
  if (last && nowMs - last.atMs < cfg.debounceMs) {
    return { due: false, reason: "debounce" };
  }

  // (Phase 2.1) Dismiss-suppression. `undefined` suggestionDismissed reads as false
  // (a pre-upgrade host omits the field). Evaluated BEFORE the manager `unchanged`
  // gate: in the normal `waiting` flow the screen + goals are stable, so `unchanged`
  // would short-circuit and the arm would never be set at dismiss time. The compare
  // uses the SUMMARIZER's fingerprint (the contract's "meaningful change" = the
  // summarizer's notion) and is independent of the manager debounce fingerprint.
  const dismissed = s.surface.suggestionDismissed === true;
  if (dismissed) {
    const armed = last?.suppressedFingerprint ?? null;
    // The suppression fingerprint is the SUMMARIZER's (screen + agentState/prompt/
    // tool, NO goals); the arm value and BOTH compares MUST live in this same space.
    const dfp = dismissFingerprint(s, summarizerCfg);
    if (armed === null) {
      // Arm suppression at the current summarizer fingerprint (the dismissed screen).
      return { due: false, reason: "dismissed-arm", suppressedFingerprint: dfp };
    }
    if (armed === dfp) {
      return { due: false, reason: "dismissed-unchanged" };
    }
    // A SINGLE meaningful change since the dismissal -> allow + clear suppression.
    return { due: true, reason: "dismissed-changed", suppressedFingerprint: null };
  }

  // Not dismissed: behaves as before. Coarse `unchanged` skip avoids re-proposing the
  // same reply for the same (goals + screen) state; also clears any stale arm.
  const fp = fingerprint(s, goals, cfg);
  if (last !== undefined && last.fingerprint === fp) {
    return { due: false, reason: "unchanged" };
  }
  return {
    due: true,
    reason: last === undefined ? "first" : "changed",
    suppressedFingerprint: null,
  };
}

/** Build the SuggestionContext fed to the model from a snapshot + goals + prior. */
export function buildContext(
  s: ManagerSnapshot,
  goals: string,
  previousSuggestion: string | undefined,
  cfg: ManagerConfig,
): SuggestionContext {
  return {
    title: s.surface.title,
    pwd: s.surface.pwd,
    goals,
    previousSuggestion,
    viewportTail: lastLines(s.viewport, cfg.promptTailLines),
  };
}

/**
 * Serialize a SuggestionContext into the user-prompt text for the single-shot
 * call. PURE. Goals lead (they drive the answer), then the needs-input context,
 * then the screen. Omits unknown fields.
 */
export function serializeContext(ctx: SuggestionContext): string {
  const lines: string[] = [];
  lines.push("SESSION GOALS (honor these when choosing the reply):");
  lines.push(ctx.goals || "(no explicit goals captured — propose a conservative reply and say so)");
  lines.push("");
  lines.push(`Session title: ${ctx.title || "(untitled)"}`);
  if (ctx.pwd) lines.push(`Directory: ${ctx.pwd}`);
  if (ctx.previousSuggestion) {
    lines.push(`Your previous suggestion (avoid repeating verbatim if stale): ${ctx.previousSuggestion}`);
  }
  lines.push("");
  lines.push("The agent is WAITING. Its current screen (most recent last):");
  lines.push(ctx.viewportTail || "(no output)");
  return lines.join("\n");
}

/** Compose the full prompt pair for a manager call. PURE. */
export function composePrompt(
  base: string,
  override: string | null,
  ctx: SuggestionContext,
): { system: string; user: string } {
  return {
    system: composeSystemPrompt(base, override),
    user: serializeContext(ctx),
  };
}

/**
 * Tolerant parser for the manager's reply. PURE. Mirrors summarizer.parseSummary:
 * strips fences, walks EVERY balanced top-level JSON object, and returns the FIRST
 * carrying a non-empty string `suggestion`. `suggestion` is trimmed + truncated by
 * CODE POINT; `rationale` kept only when a non-empty string; `confidence` is parsed
 * + CLAMPED to [0,1], defaulting to DEFAULT_CONFIDENCE when absent/non-number/NaN.
 * Returns null when no usable suggestion is found.
 */
export function parseSuggestion(modelText: string): ParsedSuggestion | null {
  if (typeof modelText !== "string") return null;
  const cleaned = stripFences(modelText);

  for (const objText of eachJsonObject(cleaned)) {
    let obj: unknown;
    try {
      obj = JSON.parse(objText);
    } catch {
      continue;
    }
    if (obj === null || typeof obj !== "object" || Array.isArray(obj)) continue;

    const rec = obj as Record<string, unknown>;
    const raw = rec.suggestion;
    if (typeof raw !== "string") continue;
    const suggestion = raw.trim();
    if (suggestion.length === 0) continue;

    const result: ParsedSuggestion = {
      suggestion: truncateCodePoints(suggestion, SUGGESTION_MAX_LEN),
      confidence: clampConfidence(rec.confidence),
    };
    if (typeof rec.rationale === "string") {
      const r = rec.rationale.trim();
      if (r.length > 0) result.rationale = r;
    }
    return result;
  }
  return null;
}

/**
 * PURE: coerce a model-supplied `confidence` to a number in [0,1], defaulting to
 * DEFAULT_CONFIDENCE when it is absent, not a finite number, or otherwise invalid.
 * Out-of-range finite numbers are CLAMPED (e.g. 1.7 -> 1, -0.2 -> 0).
 */
export function clampConfidence(raw: unknown): number {
  if (typeof raw !== "number" || !Number.isFinite(raw)) return DEFAULT_CONFIDENCE;
  return Math.max(0, Math.min(1, raw));
}

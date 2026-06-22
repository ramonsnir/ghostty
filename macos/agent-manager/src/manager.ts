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
  eachJsonObject,
  fnv1a,
  lastLines,
  stripFences,
  truncateCodePoints,
} from "./summarizer.js";

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
}

export const DEFAULT_MANAGER_CONFIG: ManagerConfig = {
  debounceMs: 20000,
  promptTailLines: 60,
  fingerprintTailLines: 30,
};

/** A point-in-time view of one surface, enriched with its viewport text. */
export interface ManagerSnapshot {
  surface: Surface;
  /** Viewport text from read_surface, or "" when not yet read. */
  viewport: string;
}

/** The record the loop keeps per session from the last suggestion attempt. */
export interface LastSuggestion {
  fingerprint: string;
  atMs: number;
  suggestion: string;
}

/** The parsed, validated manager output. */
export interface ParsedSuggestion {
  suggestion: string;
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
 * The suggest/skip decision. PURE. Rules (each tested):
 *   - agent NOT waiting              -> {due:false, reason:"not-waiting"}
 *   - exited                         -> {due:false, reason:"exited"}
 *   - within debounceMs of last call -> {due:false, reason:"debounce"}
 *   - fingerprint unchanged since the last suggestion -> {due:false, reason:"unchanged"}
 *   - otherwise                      -> {due:true,  reason:"first"|"changed"}
 *
 * Manager fires ONLY for a `waiting` agent (NOT working/idle), per the spec — a
 * suggestion is meaningless mid-work. `unchanged` skip avoids re-proposing the
 * SAME reply for the SAME screen (the user may simply not have acted yet).
 */
export function shouldSuggest(
  s: ManagerSnapshot,
  goals: string,
  last: LastSuggestion | undefined,
  nowMs: number,
  cfg: ManagerConfig,
): { due: boolean; reason: string } {
  if (s.surface.exited) return { due: false, reason: "exited" };
  if (s.surface.agentState !== "waiting") {
    return { due: false, reason: "not-waiting" };
  }
  if (last && nowMs - last.atMs < cfg.debounceMs) {
    return { due: false, reason: "debounce" };
  }
  const fp = fingerprint(s, goals, cfg);
  if (last !== undefined && last.fingerprint === fp) {
    return { due: false, reason: "unchanged" };
  }
  return { due: true, reason: last === undefined ? "first" : "changed" };
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
 * CODE POINT; `rationale` kept only when a non-empty string. Returns null when no
 * usable suggestion is found.
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
    };
    if (typeof rec.rationale === "string") {
      const r = rec.rationale.trim();
      if (r.length > 0) result.rationale = r;
    }
    return result;
  }
  return null;
}

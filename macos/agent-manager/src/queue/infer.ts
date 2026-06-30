// (ramon fork / Agent Queue — adopt) PURE, SDK-free helpers for the on-demand Haiku
// "extract the issue key" inference that prefills the adopt modal's key field. The impure
// driver (`runInferKey`) lives in runner.ts and is wired to `deps.inferKey` in index.ts (so
// the queue module never imports model.ts / the Agent SDK — the "queue needs no npm deps"
// property). These three helpers are unit-tested in `infer.test.ts`.

import type { RunRegistry } from "./commands.js";
import type { Annotation, SurfaceScreen } from "../mcp.js";

/**
 * Build the bespoke "extract a single work-item KEY from a terminal screen" prompt for the
 * adopt-modal inference. PURE. `viewportTail` is the tail of the surface's screen (the human's
 * agent session); `candidateKeys` is an OPTIONAL accuracy boost — the run's known keys (graph
 * + last list). When `candidateKeys` is empty (e.g. an empty `run`, §1.6/§3.5) the hint block
 * is OMITTED entirely — the prompt still works on the viewport alone. The model may still
 * return a key not in the list (the human asserts it).
 */
export function composeInferPrompt(
  viewportTail: string,
  candidateKeys: string[],
): { system: string; user: string } {
  const system =
    "You extract a single work-item / issue KEY from a terminal screen running a coding " +
    "agent. Output ONLY the key (e.g. ENG-1234, #4567, a ticket id), or an empty line if " +
    "none is visible. No prose, no JSON, no quotes.";
  let user = "Terminal screen (most recent lines):\n" + viewportTail;
  if (candidateKeys.length > 0) {
    user +=
      "\n\nKnown keys for this queue (prefer one of these if it matches what's on screen):\n" +
      candidateKeys.map((k) => `- ${k}`).join("\n");
  }
  return { system, user };
}

/**
 * Parse a raw Haiku reply into a single key, or `null` when empty/unusable. PURE + TOLERANT:
 * strips code fences / surrounding quotes, takes the FIRST non-empty line, and if that line
 * carries interior whitespace takes its FIRST token (the model sometimes echoes "ENG-1 — the
 * login bug"). Rejects obvious junk (length > 64 after trimming). Exported for unit testing.
 */
export function parseInferredKey(raw: string): string | null {
  if (typeof raw !== "string") return null;
  // Strip a fenced block (```...```) down to its inner text, then split into lines.
  const unfenced = raw.replace(/```[a-zA-Z0-9]*\n?/g, "").replace(/```/g, "");
  const lines = unfenced.split("\n");
  for (const rawLine of lines) {
    let line = rawLine.trim();
    if (line.length === 0) continue;
    // Strip surrounding quotes/backticks.
    line = line.replace(/^["'`]+/, "").replace(/["'`]+$/, "").trim();
    if (line.length === 0) continue;
    // Interior whitespace ⇒ take the first token (the bare key).
    const firstToken = line.split(/\s+/)[0] ?? "";
    const key = firstToken.trim();
    if (key.length === 0) continue;
    if (key.length > 64) return null; // obvious junk (a sentence with no spaces / a blob)
    return key;
  }
  return null;
}

/**
 * Collect the candidate keys for a run's inference hint — the union of its last graph node keys
 * and its last `list` item keys, deduped (insertion order). PURE. Returns `[]` when `runName`
 * is empty/absent or the run is unknown (the empty-run multi-pick case, §1.6). Exported for
 * unit testing.
 */
export function collectCandidateKeys(registry: RunRegistry, runName: string): string[] {
  if (runName.length === 0) return [];
  const run = registry.get(runName);
  if (run === undefined) return [];
  const seen = new Set<string>();
  const out: string[] = [];
  for (const n of run.lastGraph?.nodes ?? []) {
    if (typeof n.key === "string" && n.key.length > 0 && !seen.has(n.key)) {
      seen.add(n.key);
      out.push(n.key);
    }
  }
  for (const i of run.lastListItems ?? []) {
    if (typeof i.key === "string" && i.key.length > 0 && !seen.has(i.key)) {
      seen.add(i.key);
      out.push(i.key);
    }
  }
  return out;
}

/** The seams `runInferKey` needs — kept SDK-free (the `summarize` fn is INJECTED, NOT imported
 *  from model.ts, preserving the "queue needs no npm deps" property). Production wires these in
 *  index.ts from the McpClient + the shared `deps.summarize`; tests inject fakes. */
export interface InferKeyDeps {
  readSurface: (surfaceUUID: string) => Promise<SurfaceScreen>;
  setAnnotation: (surfaceUUID: string, ann: Annotation) => Promise<void>;
  /** The model call (warm-base aware via the shared seam). `isUsable` mirrors the summarizer. */
  summarize: (req: {
    system: string;
    user: string;
    configDir?: string;
    onUsage?: (usage: unknown) => void;
    isUsable?: (raw: string) => boolean;
  }) => Promise<string>;
  /** The candidate-key vocabulary for the run (= `collectCandidateKeys(registry, runName)`). */
  candidates: (runName: string) => string[];
  /** Tail the surface text to N lines (= summarizer `lastLines(text, cfg.promptTailLines)`). */
  tail: (text: string) => string;
  /** Account routing for the model call + usage tag. */
  configDir?: string;
  /** Record one Haiku usage line (the SDK usage + the feature/account/durationMs tag). The
   *  feature is ALWAYS "issue-key-infer" — the caller need not pass it. */
  recordUsage: (usage: unknown, durationMs: number) => void;
  now: () => number;
  errlog: (m: string) => void;
}

/**
 * (adopt) Drive ONE on-demand Haiku key inference: read the surface → bespoke prompt → Haiku →
 * parse → write the `queueKeySuggested` annotation so the GUI adopt modal prefills. BEST-EFFORT:
 * ANY failure (read / model / parse) ALWAYS writes the `""` sentinel so the modal drops its
 * spinner (the §1.3 "inferred nothing" negative, distinct from absent = "still inferring").
 * Impure only through the injected `deps` (so it is unit-testable with fakes); imports NO SDK.
 */
export async function runInferKeyWithDeps(
  surfaceUUID: string,
  runName: string,
  deps: InferKeyDeps,
): Promise<void> {
  const started = deps.now();
  try {
    const screen = await deps.readSurface(surfaceUUID);
    const tail = deps.tail(screen.text);
    const { system, user } = composeInferPrompt(tail, deps.candidates(runName));
    const raw = await deps.summarize({
      system,
      user,
      configDir: deps.configDir,
      onUsage: (u) => deps.recordUsage(u, deps.now() - started),
      isUsable: (r) => parseInferredKey(r) !== null,
    });
    const key = parseInferredKey(raw);
    await deps.setAnnotation(surfaceUUID, { queueKeySuggested: key ?? "" });
  } catch (err) {
    deps.errlog(`infer_key ${surfaceUUID}: ${err instanceof Error ? err.message : String(err)}`);
    try {
      await deps.setAnnotation(surfaceUUID, { queueKeySuggested: "" });
    } catch {
      /* best-effort */
    }
  }
}

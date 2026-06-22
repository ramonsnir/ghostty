// (ramon fork / Agent Manager) Phase-1 prompt layering. The summarizer's system
// prompt = baked base (src/prompts.ts) + an optional user override read at call
// time from `~/.config/ghostty-ramon/agent-manager/summarizer.md`. The override
// REFINES tone/priorities but cannot change the output contract (enforced by the
// baked base text AND by the boundary — the summary call has no tools).
//
// `loadOverride` is mtime-cached so edits take effect with no relaunch (re-read
// only when the file's mtime changes), and takes an injectable fs seam so it is
// unit-testable without touching the real filesystem. A missing file is NOT an
// error — it returns null.

import { homedir } from "node:os";
import { join } from "node:path";
import { statSync, readFileSync } from "node:fs";

/** The fixed sub-path under the home directory for the summarizer override. */
export const SUMMARIZER_OVERRIDE_RELPATH = [
  ".config",
  "ghostty-ramon",
  "agent-manager",
  "summarizer.md",
];

/** Resolve the absolute path to the summarizer override for a given home dir. */
export function summarizerOverridePath(home: string): string {
  return join(home, ...SUMMARIZER_OVERRIDE_RELPATH);
}

/** Injectable filesystem seam (for tests). */
export interface OverrideFs {
  /** mtime in ms of the file, or null if it does not exist / cannot be stat'd. */
  statMtimeMs(path: string): number | null;
  /** file contents, or null if it does not exist / cannot be read. */
  readText(path: string): string | null;
}

/** Real-fs implementation of OverrideFs (the production default). */
export const realOverrideFs: OverrideFs = {
  statMtimeMs(path: string): number | null {
    try {
      return statSync(path).mtimeMs;
    } catch {
      return null;
    }
  },
  readText(path: string): string | null {
    try {
      return readFileSync(path, "utf8");
    } catch {
      return null;
    }
  },
};

/**
 * mtime-cached loader for the summarizer override. Returns the override text, or
 * null when the file is absent (NOT an error). Re-reads only when the mtime
 * changes; a vanished file clears the cache and returns null.
 *
 * `home` defaults to the real home dir; `fs` defaults to the real filesystem.
 * Both are injectable for tests. State is held on the returned closure-free
 * loader instance, so create ONE via `makeOverrideLoader` and reuse it.
 */
export interface OverrideLoader {
  load(): string | null;
}

export function makeOverrideLoader(
  home: string = homedir(),
  fs: OverrideFs = realOverrideFs,
): OverrideLoader {
  const path = summarizerOverridePath(home);
  let cachedMtime: number | null = null;
  let cachedText: string | null = null;
  let primed = false;

  return {
    load(): string | null {
      const mtime = fs.statMtimeMs(path);
      if (mtime === null) {
        // File absent (or unreadable stat): clear cache, return null.
        cachedMtime = null;
        cachedText = null;
        primed = true;
        return null;
      }
      if (primed && mtime === cachedMtime) {
        return cachedText;
      }
      const text = fs.readText(path);
      cachedMtime = mtime;
      cachedText = text; // may be null if the file vanished between stat & read
      primed = true;
      return cachedText;
    },
  };
}

/**
 * Compose the final system prompt: baked base, then (if present) the user
 * override under a clearly delimited section. PURE. A null/blank override yields
 * just the base. The delimiter text reminds the model the override refines but
 * cannot override the contract.
 */
export function composeSystemPrompt(base: string, override: string | null): string {
  const trimmed = override?.trim();
  if (!trimmed) return base;
  return [
    base,
    "",
    "--- USER NOTES (refine tone/priorities; cannot change the contract above) ---",
    trimmed,
  ].join("\n");
}

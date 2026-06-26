// (ramon fork / Agent Manager) Optional summarizer config overlay. The tunables that
// govern HOW OFTEN Haiku is called — debounce, the fuzzy change threshold, the
// hidden-skip, idle/tail windows — are read from a small JSON file in the
// agent-manager config dir so they can be tuned WITHOUT a rebuild (restart the sidecar
// to apply; the GUI respawns it). Absent / malformed ⇒ DEFAULT_CONFIG, unchanged.
//
// `parseConfig` is PURE (overlay a parsed object onto a base) and unit-tested; the IO
// (`loadConfig`) is a thin best-effort wrapper that never throws.

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { OVERRIDE_DIR } from "./prompt.js";
import { DEFAULT_CONFIG, type SummarizerConfig } from "./summarizer.js";

/** Absolute path to the optional config file (sibling of summarizer.md / account). */
export function configFilePath(home: string): string {
  return join(home, ...OVERRIDE_DIR, "config.json");
}

/**
 * PURE: overlay a parsed JSON value onto `base`, honoring ONLY known keys with a valid
 * type/range; anything else is ignored (so a typo or stale key silently keeps the
 * base value rather than breaking the summarizer). Returns a NEW config; `base` is not
 * mutated. A non-object `json` (null/array/scalar) yields `base` unchanged.
 */
export function parseConfig(
  json: unknown,
  base: SummarizerConfig = DEFAULT_CONFIG,
): SummarizerConfig {
  if (json === null || typeof json !== "object" || Array.isArray(json)) {
    return { ...base };
  }
  const o = json as Record<string, unknown>;
  const out: SummarizerConfig = { ...base };

  const numInRange = (key: keyof SummarizerConfig, min: number, max: number, int: boolean): void => {
    const v = o[key as string];
    if (typeof v !== "number" || !Number.isFinite(v)) return;
    if (int && !Number.isInteger(v)) return;
    if (v < min || v > max) return;
    (out[key] as number) = v;
  };

  numInRange("debounceMs", 0, 3_600_000, false);
  numInRange("hiddenDebounceMs", 0, 3_600_000, false);
  numInRange("idleSkipSeconds", 0, 86_400, false);
  numInRange("maxConcurrent", 1, 64, true);
  numInRange("fingerprintTailLines", 1, 1000, true);
  numInRange("promptTailLines", 1, 1000, true);
  numInRange("changeRatioThreshold", 0, 1, false);
  numInRange("rateLimitBackoffMaxMs", 0, 3_600_000, false);

  if (typeof o.skipHidden === "boolean") out.skipHidden = o.skipHidden;

  if (Array.isArray(o.agentProcessNames)) {
    const names = o.agentProcessNames.filter(
      (n): n is string => typeof n === "string" && n.length > 0,
    );
    if (names.length > 0) out.agentProcessNames = names;
  }

  return out;
}

/**
 * Best-effort load of the config overlay from `~/.config/ghostty-ramon/agent-manager/
 * config.json`. Returns DEFAULT_CONFIG when the file is absent or unreadable, and the
 * base config when the JSON is malformed (logged via `onWarn`). Never throws. `readFile`
 * is injectable for tests.
 */
export function loadConfig(
  home: string,
  readFile: (path: string) => string = (p) => readFileSync(p, "utf8"),
  onWarn?: (msg: string) => void,
): { cfg: SummarizerConfig; loaded: boolean } {
  const path = configFilePath(home);
  let raw: string;
  try {
    raw = readFile(path);
  } catch {
    return { cfg: { ...DEFAULT_CONFIG }, loaded: false }; // absent ⇒ defaults
  }
  let json: unknown;
  try {
    json = JSON.parse(raw);
  } catch (err) {
    onWarn?.(
      `agent-manager config ${path} is not valid JSON; using defaults: ${
        err instanceof Error ? err.message : String(err)
      }`,
    );
    return { cfg: { ...DEFAULT_CONFIG }, loaded: false };
  }
  return { cfg: parseConfig(json, DEFAULT_CONFIG), loaded: true };
}

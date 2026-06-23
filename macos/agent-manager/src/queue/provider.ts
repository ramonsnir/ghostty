// (ramon fork / Agent Queue Supervisor) Provider — the GENERICITY BOUNDARY (§5/§13).
//
// A provider is an external COMMAND the template defines (argv array, JSON over
// stdout). This module is PURE except for `runProvider`, whose process-spawn is an
// INJECTABLE SEAM (`exec`) so tests never spawn a child. NOTHING here knows about
// Linear / Git / issue keys: it only renders argv, maps fields by name, and parses
// JSON tolerantly.
//
// SAFETY (§13, the #1 requirement): item fields reach the agent command as ENV VARS
// (`buildItemEnv` → GHOSTTY_ITEM_*), NEVER spliced into a shell line. Provider
// commands are argv ARRAYS; the only substitution is replacing a literal "{key}"
// ARGV ELEMENT with the key (element replace, never a shell splice) — so a title
// full of quotes/$/backticks/newlines can never become shell metacharacters.

import type {
  ProviderListSpec,
  ProviderStatusSpec,
  WorkItem,
} from "./types.js";

/** Default tight timeout for any single provider command (§5/§13). */
export const DEFAULT_PROVIDER_TIMEOUT_MS = 5000;

/** The placeholder argv element substituted with the work-item key. */
export const KEY_PLACEHOLDER = "{key}";

/** Defense-in-depth caps on the GHOSTTY_ITEM_* env a (hostile/odd) provider can emit
 *  (§13). The values are inert env DATA (never shell text — the core defense holds via
 *  argv arrays + env vars), and total provider stdout is already bounded by the exec
 *  `maxBuffer`; these are belt-and-suspenders so a multi-megabyte `title` or hundreds of
 *  `meta` fields can't bloat the spawned split's environment. Over-long values are
 *  TRUNCATED (not dropped — the agent still sees the leading content); excess meta
 *  entries beyond the count cap are dropped (taken in object key order). */
export const MAX_ENV_VALUE_LEN = 8192;
export const MAX_META_ENTRIES = 64;

// ---------------------------------------------------------------------------
// PURE: argv rendering + env-var building.
// ---------------------------------------------------------------------------

/**
 * Render a provider argv by replacing every element EQUAL TO "{key}" with `key`.
 * PURE. This is an ELEMENT replace (the command is an array, run without a shell),
 * NOT a string splice — so the key, however adversarial, becomes exactly one argv
 * element and can never inject shell syntax. Elements that merely CONTAIN "{key}"
 * as a substring are left untouched (we only swap a whole placeholder element), so
 * there is no partial-interpolation surface either.
 */
export function renderArgv(command: string[], key: string): string[] {
  return command.map((el) => (el === KEY_PLACEHOLDER ? key : el));
}

/**
 * Build the GHOSTTY_ITEM_* environment for an agent launch (§13). PURE. The KEY is
 * always present; title/url are added only when defined; each `meta` entry becomes
 * GHOSTTY_ITEM_META_<UPPER_KEY>. Values are passed through VERBATIM as env values —
 * the OS keeps them as opaque bytes, so quotes / $ / backticks / newlines are inert
 * (this is the whole point: they are data, not shell text).
 *
 * Meta keys are upper-cased and any character outside [A-Z0-9_] is replaced with
 * `_` so the result is a valid env-var name; a leading digit is prefixed with `_`.
 * A meta key that collides with a reserved field (KEY/TITLE/URL) is still namespaced
 * under META_ so it can never clobber the canonical vars.
 *
 * Defense-in-depth (§13): every value is TRUNCATED to `MAX_ENV_VALUE_LEN` and at most
 * `MAX_META_ENTRIES` meta fields are kept (taken in object key order) — so a hostile
 * provider can't bloat the spawned split's environment with a multi-megabyte value or
 * hundreds of meta vars. The values stay inert env DATA either way.
 *
 * NOTE: two distinct meta keys can sanitize to the SAME env name (e.g. `team-name` and
 * `team.name` both → `..._TEAM_NAME`); on a collision the later entry (in object key
 * order) wins (last-write). This is a benign last-write-wins among the provider's OWN
 * fields — both remain namespaced under `GHOSTTY_ITEM_META_` and stay inert env DATA, so
 * it can never clobber the canonical KEY/TITLE/URL vars nor become an injection vector.
 */
export function buildItemEnv(item: WorkItem): Record<string, string> {
  const env: Record<string, string> = { GHOSTTY_ITEM_KEY: clampEnvValue(item.key) };
  if (item.title !== undefined) env.GHOSTTY_ITEM_TITLE = clampEnvValue(item.title);
  if (item.url !== undefined) env.GHOSTTY_ITEM_URL = clampEnvValue(item.url);
  if (item.meta) {
    let kept = 0;
    for (const [k, v] of Object.entries(item.meta)) {
      if (kept >= MAX_META_ENTRIES) break; // cap the meta-field COUNT
      const name = `GHOSTTY_ITEM_META_${sanitizeEnvSuffix(k)}`;
      env[name] = clampEnvValue(v);
      kept += 1;
    }
  }
  return env;
}

/** Truncate an env VALUE to `MAX_ENV_VALUE_LEN` chars (defense-in-depth, §13). PURE. */
export function clampEnvValue(value: string): string {
  return value.length > MAX_ENV_VALUE_LEN ? value.slice(0, MAX_ENV_VALUE_LEN) : value;
}

/** Sanitize an arbitrary meta key into a valid env-var name suffix. PURE. */
export function sanitizeEnvSuffix(key: string): string {
  let s = key.toUpperCase().replace(/[^A-Z0-9_]/g, "_");
  if (s.length === 0) s = "_";
  if (/^[0-9]/.test(s)) s = `_${s}`;
  return s;
}

// ---------------------------------------------------------------------------
// PURE: tolerant JSON parsing of provider output.
// ---------------------------------------------------------------------------

/**
 * Parse the `list` provider stdout into WorkItems. PURE + TOLERANT. Expects a JSON
 * ARRAY of objects; maps `keyField`/`titleField`/`urlField` → WorkItem. Items with
 * no usable (non-empty string) key are DROPPED (never dispatched). Any unmapped
 * scalar/string fields on each object are collected into `meta` (so a template can
 * surface extra fields to the agent without a code change). Unparseable / non-array
 * / wrong-shaped stdout yields `[]` (the caller skips the tick — never throws).
 */
export function parseListOutput(
  stdout: string,
  fields: Pick<ProviderListSpec, "keyField" | "titleField" | "urlField">,
): WorkItem[] {
  let parsed: unknown;
  try {
    parsed = JSON.parse(stdout);
  } catch {
    return [];
  }
  if (!Array.isArray(parsed)) return [];

  const out: WorkItem[] = [];
  for (const raw of parsed) {
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) continue;
    const rec = raw as Record<string, unknown>;

    const key = asString(rec[fields.keyField]);
    if (key === undefined || key.length === 0) continue; // drop keyless items

    const item: WorkItem = { key };
    if (fields.titleField !== undefined) {
      const t = asString(rec[fields.titleField]);
      if (t !== undefined) item.title = t;
    }
    if (fields.urlField !== undefined) {
      const u = asString(rec[fields.urlField]);
      if (u !== undefined) item.url = u;
    }

    // Collect any OTHER string/number/bool fields as meta (excluding the mapped
    // fields), so a template's extra columns reach the agent as env vars.
    const reserved = new Set(
      [fields.keyField, fields.titleField, fields.urlField].filter(
        (f): f is string => typeof f === "string",
      ),
    );
    const meta: Record<string, string> = {};
    for (const [k, v] of Object.entries(rec)) {
      if (reserved.has(k)) continue;
      const s = asScalarString(v);
      if (s !== undefined) meta[k] = s;
    }
    if (Object.keys(meta).length > 0) item.meta = meta;

    out.push(item);
  }
  return out;
}

/**
 * Parse the `status` provider stdout into a terminal flag. PURE + TOLERANT. Expects
 * `{"state":"..."}`; terminal iff `state ∈ doneStates`. Bad / empty / missing /
 * non-string `state` ⇒ `{terminal:false}` ("unknown, not terminal") so a split is
 * NEVER closed on a flaky probe (§13, no false positives). Matching is case- and
 * whitespace-insensitive so a provider's casing/padding doesn't cause a miss.
 */
export function parseStatusOutput(
  stdout: string,
  doneStates: string[],
): { terminal: boolean } {
  let parsed: unknown;
  try {
    parsed = JSON.parse(stdout);
  } catch {
    return { terminal: false };
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    return { terminal: false };
  }
  const state = (parsed as Record<string, unknown>).state;
  if (typeof state !== "string") return { terminal: false };
  const norm = state.trim().toLowerCase();
  if (norm.length === 0) return { terminal: false };
  const done = doneStates.some((d) => d.trim().toLowerCase() === norm);
  return { terminal: done };
}

// ---------------------------------------------------------------------------
// runProvider — the ONLY non-pure function (process spawn via an injected seam).
// ---------------------------------------------------------------------------

/** Result of a single command execution (the seam's return shape). */
export interface ExecResult {
  code: number;
  stdout: string;
  stderr: string;
}

/** Options passed to the exec seam (and to runProvider). */
export interface ExecOptions {
  timeoutMs?: number;
  /** Extra env merged onto the sanitized base env (e.g. GHOSTTY_ITEM_*). */
  env?: Record<string, string>;
  /** Working directory for the command. */
  cwd?: string;
}

/** The injectable process-runner seam. Tests pass a fake; production passes the
 *  node:child_process implementation. It must NEVER reject for a non-zero exit —
 *  it resolves with the code so runProvider can decide. */
export type Exec = (argv: string[], opts: ExecOptions) => Promise<ExecResult>;

/** Outcome of a provider run: either parsed output, or a "skip"/"unknown" sentinel
 *  on any failure (non-zero exit, timeout, empty argv). NEVER throws into the loop. */
export type ProviderRunResult =
  | { ok: true; result: ExecResult }
  | { ok: false; reason: string };

/**
 * Run a provider COMMAND via the injected `exec` seam with a tight default timeout
 * and a sanitized/merged env. Returns a `{ok:false, reason}` sentinel on ANY
 * failure (empty argv, exec rejection, non-zero exit) — it NEVER throws into the
 * control loop (§13). The caller maps `ok:false` to "skip the tick" (list) or
 * "unknown, not terminal" (status). Parsing is the caller's job (via the pure
 * `parseListOutput`/`parseStatusOutput`) so this stays generic.
 */
export async function runProvider(
  argv: string[],
  exec: Exec,
  opts: ExecOptions = {},
): Promise<ProviderRunResult> {
  if (!Array.isArray(argv) || argv.length === 0) {
    return { ok: false, reason: "empty-command" };
  }
  const timeoutMs = opts.timeoutMs ?? DEFAULT_PROVIDER_TIMEOUT_MS;
  let res: ExecResult;
  try {
    res = await exec(argv, { ...opts, timeoutMs });
  } catch (err) {
    return {
      ok: false,
      reason: `exec-failed: ${err instanceof Error ? err.message : String(err)}`,
    };
  }
  if (res.code !== 0) {
    return { ok: false, reason: `nonzero-exit: ${res.code}` };
  }
  return { ok: true, result: res };
}

/** Convenience: render the status argv, run it, and parse — all in one. PURE over
 *  its injected `exec`. Returns "unknown, not terminal" on any failure. */
export async function probeStatus(
  spec: ProviderStatusSpec,
  key: string,
  exec: Exec,
  opts: ExecOptions = {},
): Promise<{ terminal: boolean }> {
  const argv = renderArgv(spec.command, key);
  const run = await runProvider(argv, exec, opts);
  if (!run.ok) return { terminal: false };
  return parseStatusOutput(run.result.stdout, spec.doneStates);
}

/** Convenience: run the list command and parse — all in one. PURE over its
 *  injected `exec`. Returns `[]` (skip the tick) on any failure. */
export async function fetchList(
  spec: ProviderListSpec,
  exec: Exec,
  opts: ExecOptions = {},
): Promise<WorkItem[]> {
  return (await fetchListResult(spec, exec, opts)).items;
}

/**
 * Like `fetchList` but distinguishes a SUCCESSFUL empty list from a FAILED/skip one:
 * `ok` is true only when the provider exited cleanly and its output parsed. The
 * quit-when-empty logic (§8a) needs this — a flaky/non-zero `list` returns
 * `{ok:false, items:[]}` (treated as "skip", never "the queue is empty") so a transient
 * provider failure can never tear a run down. PURE-ish (only the injected exec).
 */
export async function fetchListResult(
  spec: ProviderListSpec,
  exec: Exec,
  opts: ExecOptions = {},
): Promise<{ ok: boolean; items: WorkItem[] }> {
  const run = await runProvider(spec.command, exec, opts);
  if (!run.ok) return { ok: false, items: [] };
  return { ok: true, items: parseListOutput(run.result.stdout, spec) };
}

// ---------------------------------------------------------------------------
// Pure helpers.
// ---------------------------------------------------------------------------

/** Coerce a value to a string only when it IS a string. PURE. */
function asString(v: unknown): string | undefined {
  return typeof v === "string" ? v : undefined;
}

/** Coerce a scalar (string/number/boolean) to a string for meta. PURE. Objects /
 *  arrays / null / undefined yield undefined (not stuffed into meta). */
function asScalarString(v: unknown): string | undefined {
  if (typeof v === "string") return v;
  if (typeof v === "number" && Number.isFinite(v)) return String(v);
  if (typeof v === "boolean") return String(v);
  return undefined;
}

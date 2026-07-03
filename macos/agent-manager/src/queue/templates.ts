// (ramon fork / Agent Queue Supervisor) Queue TEMPLATE loader + validator (§5).
//
// A queue template is user-authored JSON (team policy) under
// `~/.config/ghostty-ramon/agent-manager/queues/<name>.json`. This module provides:
//   - `validateTemplate(obj)` — a PURE validator that turns arbitrary parsed JSON
//     into a typed QueueTemplate or a list of errors (required fields, sane grid,
//     concurrency clamped to the grid cap). No I/O, no clock — fully unit-testable.
//   - `makeTemplateLoader(path)` — a thin, mtime-cached file wrapper over the pure
//     validator (mirrors prompt.ts's override loader), with an injectable fs seam.
//
// NOTHING here is queue-content aware; it only checks shape + ranges.

import { statSync, readFileSync } from "node:fs";
import { dirname, resolve as resolvePath } from "node:path";

import { gridCap, MAX_QUEUE_TABS } from "./grid.js";
import { CronParseError, parseCron } from "./schedule.js";
import type {
  AgentSpec,
  GridFill,
  GridSpec,
  IntervalsSpec,
  OnAgentExit,
  ProviderClaimSpec,
  ProviderGraphSpec,
  ProviderListSpec,
  ProviderSpec,
  ProviderStatusSpec,
  QueueParam,
  QueueParamTarget,
  QueueTemplate,
  ScheduleSpec,
} from "./types.js";

/** The directory (under the agent-manager override dir) holding queue templates. */
export const QUEUES_DIR = [".config", "ghostty-ramon", "agent-manager", "queues"];

/** Defaults applied when an optional template field is omitted (§5). */
export const TEMPLATE_DEFAULTS = {
  concurrency: 1,
  maxItems: 100,
  grid: { cols: 3, rows: 3, fill: "columns" as GridFill },
  intervals: { listMs: 60000, statusMs: 30000 },
  onAgentExit: "leave-and-bell" as OnAgentExit,
  closeOnComplete: true,
  // (keep) default false: a completed split auto-closes unless the per-split pin (or this
  // template knob) opts it into being kept open for manual work.
  keepOnComplete: false,
  closeStableSeconds: 5,
};

/** The outcome of validation: a typed template, or a list of human-readable errors. */
export type ValidateResult =
  | { ok: true; template: QueueTemplate; errors: [] }
  | { ok: false; template?: undefined; errors: string[] };

/**
 * Validate arbitrary parsed JSON into a QueueTemplate. PURE. Required fields are
 * `name`, `workdir`, `agent.command`, and the `provider.list`/`provider.status`
 * commands + `provider.list.keyField` / `provider.status.doneStates`. Everything
 * else falls back to TEMPLATE_DEFAULTS. The grid must be sane (positive integer
 * cols/rows, known fill); `concurrency` is CLAMPED to [1, gridCap * MAX_QUEUE_TABS]
 * (it may exceed ONE grid — panes overflow to more tabs, §12). Returns
 * `{ok:false, errors}` listing EVERY problem found (not just the first) so a user
 * fixing their JSON sees all issues at once.
 */
export function validateTemplate(obj: unknown): ValidateResult {
  const errors: string[] = [];

  if (obj === null || typeof obj !== "object" || Array.isArray(obj)) {
    return { ok: false, errors: ["template must be a JSON object"] };
  }
  const rec = obj as Record<string, unknown>;

  const name = reqNonEmptyString(rec.name, "name", errors);
  const workdir = reqNonEmptyString(rec.workdir, "workdir", errors);

  const agent = validateAgent(rec.agent, errors);
  const grid = validateGrid(rec.grid, errors);
  const intervals = validateIntervals(rec.intervals, errors);
  const provider = validateProvider(rec.provider, errors);

  const cap = grid ? gridCap(grid.cols, grid.rows) : 0;
  const concurrency = clampConcurrency(rec.concurrency, cap, errors);
  const maxItems = posIntOrDefault(
    rec.maxItems,
    TEMPLATE_DEFAULTS.maxItems,
    "maxItems",
    errors,
  );
  const closeStableSeconds = nonNegNumberOrDefault(
    rec.closeStableSeconds,
    TEMPLATE_DEFAULTS.closeStableSeconds,
    "closeStableSeconds",
    errors,
  );
  const onAgentExit = validateOnAgentExit(rec.onAgentExit, errors);
  const closeOnComplete = boolOrDefault(
    rec.closeOnComplete,
    TEMPLATE_DEFAULTS.closeOnComplete,
  );
  // (keep) the per-queue default for keeping a completed split open (per-split pin overrides).
  const keepOnComplete = boolOrDefault(
    rec.keepOnComplete,
    TEMPLATE_DEFAULTS.keepOnComplete,
  );
  // NOTE: `quitWhenEmpty` was removed (see types.ts) — a `quitWhenEmpty` key in template
  // JSON is now silently ignored, never parsed.
  const params = validateParams(rec.params, errors);
  // (schedules) The recurring scan agents. Validated for shape + a parseable cron; the
  // `promptFile` field is RESOLVED to `prompt` later, in the file loader (which knows the
  // template's directory) — validateTemplate stays pure/no-I/O.
  const schedules = validateSchedules(rec.schedules, errors);

  if (
    errors.length > 0 ||
    name === undefined ||
    workdir === undefined ||
    agent === undefined ||
    grid === undefined ||
    intervals === undefined ||
    provider === undefined ||
    concurrency === undefined
  ) {
    return { ok: false, errors };
  }

  const template: QueueTemplate = {
    name,
    workdir,
    agent,
    concurrency,
    maxItems,
    grid,
    intervals,
    provider,
    onAgentExit,
    closeOnComplete,
    keepOnComplete,
    closeStableSeconds,
    params,
    schedules,
  };
  return { ok: true, template, errors: [] };
}

/**
 * Validate the optional `schedules` array (see ScheduleSpec / queue/schedule.ts). PURE.
 * Each entry needs a non-empty `id` (unique across the array — the single-flight key), a
 * parseable 5-field `cron`, and EXACTLY ONE of `prompt` (inline) / `promptFile` (a path
 * resolved later by the loader). `name`/`command` are optional non-empty strings;
 * `closeOnComplete` defaults true. Pushes an error per problem (all surfaced at once) and
 * still returns the specs it could build; validateTemplate bails on any error. Absent ⇒
 * []. This is the chokepoint that whitelists schedule fields (the `validateProviderList`
 * lesson) — a field not carried here is silently dropped from the runtime template.
 */
function validateSchedules(v: unknown, errors: string[]): ScheduleSpec[] {
  if (v === undefined) return [];
  if (!Array.isArray(v)) {
    errors.push("schedules must be an array");
    return [];
  }
  const out: ScheduleSpec[] = [];
  const seenIds = new Set<string>();
  v.forEach((raw, i) => {
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
      errors.push(`schedules[${i}] must be an object`);
      return;
    }
    const r = raw as Record<string, unknown>;
    const id = reqNonEmptyString(r.id, `schedules[${i}].id`, errors);
    const cron = reqNonEmptyString(r.cron, `schedules[${i}].cron`, errors);
    if (cron !== undefined) {
      try {
        parseCron(cron);
      } catch (err) {
        errors.push(
          `schedules[${i}].cron is invalid: ${err instanceof CronParseError ? err.message : String(err)}`,
        );
      }
    }
    if (id !== undefined) {
      if (seenIds.has(id)) errors.push(`schedules[${i}].id "${id}" is duplicated`);
      seenIds.add(id);
    }
    // Exactly one of prompt / promptFile.
    const hasPrompt = typeof r.prompt === "string" && r.prompt.trim().length > 0;
    const hasPromptFile = typeof r.promptFile === "string" && r.promptFile.trim().length > 0;
    if (hasPrompt && hasPromptFile) {
      errors.push(`schedules[${i}] must set only ONE of prompt / promptFile`);
    } else if (!hasPrompt && !hasPromptFile) {
      errors.push(`schedules[${i}] must set prompt or promptFile`);
    }
    let command: string | undefined;
    if (r.command !== undefined) {
      command = reqNonEmptyString(r.command, `schedules[${i}].command`, errors);
    }
    let name: string | undefined;
    if (r.name !== undefined) {
      name = reqNonEmptyString(r.name, `schedules[${i}].name`, errors);
    }
    const closeOnComplete = boolOrDefault(r.closeOnComplete, true);
    if (id === undefined || cron === undefined) return;
    const spec: ScheduleSpec = { id, cron, closeOnComplete };
    if (name !== undefined) spec.name = name;
    if (command !== undefined) spec.command = command;
    if (hasPrompt) spec.prompt = (r.prompt as string).trim();
    if (hasPromptFile) spec.promptFile = (r.promptFile as string).trim();
    out.push(spec);
  });
  return out;
}

// ---------------------------------------------------------------------------
// mtime-cached file loader (the only I/O; mirrors prompt.ts).
// ---------------------------------------------------------------------------

/** Injectable filesystem seam (for tests). Same shape as prompt.ts's OverrideFs. */
export interface TemplateFs {
  statMtimeMs(path: string): number | null;
  readText(path: string): string | null;
}

/** Real-fs implementation (the production default). */
export const realTemplateFs: TemplateFs = {
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

/** A loaded template result from the file loader. */
export type LoadResult =
  | { ok: true; template: QueueTemplate; errors: [] }
  | { ok: false; template?: undefined; errors: string[] };

export interface TemplateLoader {
  /** Load + validate the template at the loader's path. mtime-cached: a successful
   *  validation is reused until the file's mtime changes. A missing file yields a
   *  single "not found" error (NOT a throw). */
  load(): LoadResult;
}

/**
 * mtime-cached loader for a single template file. A thin wrapper over the PURE
 * `validateTemplate` + `JSON.parse`. Re-reads/re-validates only when the mtime
 * changes; a vanished file clears the cache and returns a not-found error.
 */
export function makeTemplateLoader(
  path: string,
  fs: TemplateFs = realTemplateFs,
): TemplateLoader {
  let cachedMtime: number | null = null;
  let cachedResult: LoadResult | null = null;

  return {
    load(): LoadResult {
      const mtime = fs.statMtimeMs(path);
      if (mtime === null) {
        cachedMtime = null;
        cachedResult = null;
        return { ok: false, errors: [`template not found: ${path}`] };
      }
      if (cachedResult !== null && mtime === cachedMtime) {
        return cachedResult;
      }
      const text = fs.readText(path);
      cachedMtime = mtime;
      if (text === null) {
        cachedResult = { ok: false, errors: [`template unreadable: ${path}`] };
        return cachedResult;
      }
      let parsed: unknown;
      try {
        parsed = JSON.parse(text);
      } catch (err) {
        cachedResult = {
          ok: false,
          errors: [
            `template is not valid JSON: ${err instanceof Error ? err.message : String(err)}`,
          ],
        };
        return cachedResult;
      }
      const v = validateTemplate(parsed);
      if (!v.ok) {
        cachedResult = { ok: false, errors: v.errors };
        return cachedResult;
      }
      // (schedules) Resolve each schedule's `promptFile` (relative to THIS template's
      // directory) into `prompt`, now that we have the path + fs seam. A promptFile that
      // can't be read / is empty fails the load (so a broken schedule never dispatches a
      // hollow scan). Inline `prompt` schedules are already resolved.
      const baseDir = dirname(path);
      const promptErrors: string[] = [];
      for (const s of v.template.schedules) {
        if (s.prompt !== undefined || s.promptFile === undefined) continue;
        const p = resolvePath(baseDir, s.promptFile);
        const txt = fs.readText(p);
        if (txt === null || txt.trim().length === 0) {
          promptErrors.push(`schedule "${s.id}" promptFile unreadable/empty: ${p}`);
        } else {
          s.prompt = txt;
        }
      }
      cachedResult =
        promptErrors.length > 0
          ? { ok: false, errors: promptErrors }
          : { ok: true, template: v.template, errors: [] };
      return cachedResult;
    },
  };
}

// ---------------------------------------------------------------------------
// Pure field validators / coercers.
// ---------------------------------------------------------------------------

function reqNonEmptyString(
  v: unknown,
  field: string,
  errors: string[],
): string | undefined {
  if (typeof v !== "string" || v.trim().length === 0) {
    errors.push(`${field} must be a non-empty string`);
    return undefined;
  }
  return v;
}

function validateAgent(v: unknown, errors: string[]): AgentSpec | undefined {
  if (v === null || typeof v !== "object" || Array.isArray(v)) {
    errors.push("agent must be an object with a `command`");
    return undefined;
  }
  const rec = v as Record<string, unknown>;
  const command = reqNonEmptyString(rec.command, "agent.command", errors);
  if (command === undefined) return undefined;

  const agent: AgentSpec = { command };
  if (rec.exit !== undefined) {
    const exit = rec.exit;
    if (exit === null || typeof exit !== "object" || Array.isArray(exit)) {
      errors.push("agent.exit must be an object with `text` and/or a `keys` array");
    } else {
      const e = exit as Record<string, unknown>;
      const spec: { text?: string; submit?: boolean; keys?: string[] } = {};
      let any = false;
      if (e.text !== undefined) {
        if (typeof e.text !== "string" || e.text.length === 0) {
          errors.push("agent.exit.text must be a non-empty string");
        } else {
          spec.text = e.text;
          any = true;
        }
      }
      if (e.submit !== undefined) {
        if (typeof e.submit !== "boolean") {
          errors.push("agent.exit.submit must be a boolean");
        } else {
          spec.submit = e.submit;
        }
      }
      if (e.keys !== undefined) {
        if (!isStringArray(e.keys) || e.keys.length === 0) {
          errors.push("agent.exit.keys must be a non-empty array of strings");
        } else {
          spec.keys = e.keys;
          any = true;
        }
      }
      // Require at least one of text/keys (a bare {} or {submit} is meaningless).
      if (!any && e.text === undefined && e.keys === undefined) {
        errors.push("agent.exit must set `text` and/or `keys`");
      }
      if (any) agent.exit = spec;
    }
  }
  return agent;
}

function validateGrid(v: unknown, errors: string[]): GridSpec | undefined {
  if (v === undefined) return { ...TEMPLATE_DEFAULTS.grid };
  if (v === null || typeof v !== "object" || Array.isArray(v)) {
    errors.push("grid must be an object {cols,rows,fill}");
    return undefined;
  }
  const rec = v as Record<string, unknown>;
  const cols = posInt(rec.cols, "grid.cols", errors);
  const rows = posInt(rec.rows, "grid.rows", errors);
  let fill: GridFill = TEMPLATE_DEFAULTS.grid.fill;
  if (rec.fill !== undefined) {
    if (rec.fill === "columns" || rec.fill === "rows") {
      fill = rec.fill;
    } else {
      errors.push('grid.fill must be "columns" or "rows"');
    }
  }
  if (cols === undefined || rows === undefined) return undefined;
  return { cols, rows, fill };
}

function validateIntervals(v: unknown, errors: string[]): IntervalsSpec | undefined {
  if (v === undefined) return { ...TEMPLATE_DEFAULTS.intervals };
  if (v === null || typeof v !== "object" || Array.isArray(v)) {
    errors.push("intervals must be an object {listMs,statusMs}");
    return undefined;
  }
  const rec = v as Record<string, unknown>;
  const listMs = posIntOrDefault(
    rec.listMs,
    TEMPLATE_DEFAULTS.intervals.listMs,
    "intervals.listMs",
    errors,
  );
  const statusMs = posIntOrDefault(
    rec.statusMs,
    TEMPLATE_DEFAULTS.intervals.statusMs,
    "intervals.statusMs",
    errors,
  );
  return { listMs, statusMs };
}

function validateProvider(v: unknown, errors: string[]): ProviderSpec | undefined {
  if (v === null || typeof v !== "object" || Array.isArray(v)) {
    errors.push("provider must be an object with `list` and `status`");
    return undefined;
  }
  const rec = v as Record<string, unknown>;
  const list = validateProviderList(rec.list, errors);
  const status = validateProviderStatus(rec.status, errors);
  const claim = validateProviderClaim(rec.claim, errors);
  const graph = validateProviderGraph(rec.graph, errors);
  if (list === undefined || status === undefined) return undefined;
  const provider: ProviderSpec = { list, status };
  if (claim !== undefined) provider.claim = claim;
  if (graph !== undefined) provider.graph = graph;
  return provider;
}

/** Validate the OPTIONAL `provider.graph` (backlog board source). Absent ⇒ undefined (no
 *  backlog button). Same shape as `claim`: `{command: string[]}`. A malformed graph is an
 *  error (so a typo'd template fails loudly) rather than silently dropping the feature. */
function validateProviderGraph(
  v: unknown,
  errors: string[],
): ProviderGraphSpec | undefined {
  if (v === undefined) return undefined;
  if (v === null || typeof v !== "object" || Array.isArray(v)) {
    errors.push("provider.graph must be an object {command}");
    return undefined;
  }
  const command = reqCommand(
    (v as Record<string, unknown>).command,
    "provider.graph.command",
    errors,
  );
  if (command === undefined) return undefined;
  return { command };
}

function validateProviderList(
  v: unknown,
  errors: string[],
): ProviderListSpec | undefined {
  if (v === null || typeof v !== "object" || Array.isArray(v)) {
    errors.push("provider.list must be an object {command,keyField}");
    return undefined;
  }
  const rec = v as Record<string, unknown>;
  const command = reqCommand(rec.command, "provider.list.command", errors);
  const keyField = reqNonEmptyString(
    rec.keyField,
    "provider.list.keyField",
    errors,
  );
  const titleField = optString(rec.titleField, "provider.list.titleField", errors);
  const urlField = optString(rec.urlField, "provider.list.urlField", errors);
  // (hero) The list-spec `heroField` names the JSON field whose truthy value marks a hero.
  // MUST be carried here — omitting it silently drops heroField on template load, so the live
  // `parseListOutput` never sets `WorkItem.hero` and list-marked heroes go UNmarked everywhere
  // that reads the list (waiting/held dropdowns, hero-pool dispatch). Mirrors keyField/… above.
  const heroField = optString(rec.heroField, "provider.list.heroField", errors);
  if (command === undefined || keyField === undefined) return undefined;
  const spec: ProviderListSpec = { command, keyField };
  if (titleField !== undefined) spec.titleField = titleField;
  if (urlField !== undefined) spec.urlField = urlField;
  if (heroField !== undefined) spec.heroField = heroField;
  return spec;
}

function validateProviderStatus(
  v: unknown,
  errors: string[],
): ProviderStatusSpec | undefined {
  if (v === null || typeof v !== "object" || Array.isArray(v)) {
    errors.push("provider.status must be an object {command,doneStates}");
    return undefined;
  }
  const rec = v as Record<string, unknown>;
  const command = reqCommand(rec.command, "provider.status.command", errors);
  let doneStates: string[] | undefined;
  if (!isStringArray(rec.doneStates) || rec.doneStates.length === 0) {
    errors.push("provider.status.doneStates must be a non-empty array of strings");
  } else {
    doneStates = rec.doneStates;
  }
  if (command === undefined || doneStates === undefined) return undefined;
  return { command, doneStates };
}

function validateProviderClaim(
  v: unknown,
  errors: string[],
): ProviderClaimSpec | undefined {
  if (v === undefined) return undefined;
  if (v === null || typeof v !== "object" || Array.isArray(v)) {
    errors.push("provider.claim must be an object {command}");
    return undefined;
  }
  const command = reqCommand(
    (v as Record<string, unknown>).command,
    "provider.claim.command",
    errors,
  );
  if (command === undefined) return undefined;
  return { command };
}

function validateOnAgentExit(v: unknown, errors: string[]): OnAgentExit {
  if (v === undefined) return TEMPLATE_DEFAULTS.onAgentExit;
  if (v === "leave-and-bell") return v;
  errors.push('onAgentExit must be "leave-and-bell"');
  return TEMPLATE_DEFAULTS.onAgentExit;
}

/** A param's effective target (defaults to "env" when unset). PURE. */
function paramTarget(p: QueueParam): QueueParamTarget {
  return p.target ?? "env";
}

/**
 * (§8b) Resolve the template's declared params + the user's answers into the ENV map handed
 * to the provider commands. PURE. For each declared ENV param, the value is `values[name]`
 * when present, else the param's `default`, else "" — and it is exported under `param.env`.
 * An empty value is omitted so the provider's own env-file fallback can apply. Non-"env"
 * params (e.g. "maxItems") are SKIPPED — they never reach the provider env. Undeclared keys
 * in `values` are ignored (only declared params flow through).
 */
export function resolveParamsEnv(
  template: QueueTemplate,
  values: Record<string, string> = {},
): Record<string, string> {
  const out: Record<string, string> = {};
  for (const p of template.params) {
    if (paramTarget(p) !== "env") continue; // only env-target params go to the provider
    const v = values[p.name] ?? p.default ?? "";
    if (v.length > 0 && p.env !== undefined) out[p.env] = v;
  }
  return out;
}

/**
 * (parallel runs) The run's DISPLAY name = the template `name` plus each non-empty
 * ENV-param VALUE (in declared order), joined with " · ". So the SAME template pointed at
 * different scopes yields distinct, human-readable run names — e.g. a "ExampleOS" template
 * started for project "Acme" / milestone "v2.0" reads "ExampleOS · Acme · v2.0". maxItems
 * params (engine tuning, not scope) are excluded; a template with no env params (or all
 * blank) just yields `template.name` (the prior behavior). PURE. This name is the run's
 * IDENTITY everywhere downstream (dashboard origin, annotation queueName, health report,
 * active-run record) so two scoped runs of one template show + are controlled separately.
 */
export function runDisplayName(
  template: QueueTemplate,
  values: Record<string, string> = {},
): string {
  const parts: string[] = [];
  for (const p of template.params) {
    if (paramTarget(p) !== "env") continue; // maxItems tunes the engine, not the scope name
    const v = (values[p.name] ?? p.default ?? "").trim();
    if (v.length > 0) parts.push(v);
  }
  return parts.length === 0 ? template.name : `${template.name} · ${parts.join(" · ")}`;
}

/**
 * (parallel runs) A canonical, order-INDEPENDENT identity for a run's SCOPE: the resolved
 * provider env (env-param `name=value`) sorted + space-joined. Two `start`s with the same
 * template AND the same resolved scope share this string (an idempotent re-start no-op);
 * different scopes differ, so they run in PARALLEL. Built from `resolveParamsEnv` so the
 * identity is exactly what the provider commands are scoped by. PURE.
 */
export function runIdentityScope(
  template: QueueTemplate,
  values: Record<string, string> = {},
): string {
  const env = resolveParamsEnv(template, values);
  return Object.keys(env)
    .sort()
    .map((k) => `${k}=${env[k]}`)
    .join(" ");
}

/**
 * (parallel runs) A short, filename-safe slug of a run's identity scope, so parallel runs
 * of ONE template get DISTINCT per-run state files on disk instead of clobbering each other.
 * An EMPTY scope → "" (the caller then uses the bare basename, byte-compatible with the
 * pre-parallel single-run state file). A non-empty scope → an FNV-1a 32-bit hash in base36
 * (deterministic + collision-resistant enough for a handful of concurrent scopes). PURE.
 */
export function scopeSlug(scope: string): string {
  if (scope.length === 0) return "";
  let h = 0x811c9dc5;
  for (let i = 0; i < scope.length; i++) {
    h ^= scope.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return (h >>> 0).toString(36);
}

/** Tokens (case-insensitive) a maxItems answer may use to mean "no cap". */
const MAXITEMS_UNLIMITED_TOKENS = new Set(["0", "unlimited", "none", "inf", "infinity", "∞"]);

/**
 * Parse a raw maxItems VALUE string. PURE. SHARED by the start-time param resolution
 * (`resolveMaxItemsOverride`) and the live `set_max_items` command (the dashboard cap
 * control). Returns:
 *   - `null` for an explicit "unlimited" token ("0"/"unlimited"/"none"/"inf"/"∞") — NO cap.
 *   - a positive integer N for an explicit numeric cap.
 *   - `undefined` for blank or garbage — the CALLER decides the fallback (start-time uses
 *     the template default; the live command IGNORES it / keeps the current cap). Garbage
 *     never silently means "spawn forever".
 */
export function parseMaxItemsValue(raw: string): number | null | undefined {
  const s = raw.trim().toLowerCase();
  if (s === "") return undefined;
  if (MAXITEMS_UNLIMITED_TOKENS.has(s)) return null; // explicit unlimited
  const n = Number(s);
  if (Number.isInteger(n) && n > 0) return n; // explicit positive cap
  return undefined; // garbage
}

/**
 * Parse a raw CONCURRENCY value string (the live `set_concurrency` dashboard control). PURE.
 * Unlike maxItems there is NO "unlimited" — concurrency is always a finite positive count of
 * simultaneous agents (an unbounded fan-out would spawn a pane per actionable item). Returns:
 *   - a positive integer N for an explicit numeric value.
 *   - `undefined` for blank or garbage (incl. 0 / negatives / non-integers) — the caller
 *     IGNORES it (keeps the current concurrency), so a fat-finger never silently changes it.
 */
export function parseConcurrencyValue(raw: string): number | undefined {
  const s = raw.trim();
  if (s === "") return undefined;
  const n = Number(s);
  if (Number.isInteger(n) && n > 0) return n;
  return undefined; // blank / garbage / non-positive
}

/**
 * (§8b) Resolve the run's maxItems OVERRIDE from a "maxItems"-target param's answer. PURE.
 * Returns:
 *   - `undefined` when the template declares no maxItems param, OR the answer is blank, OR
 *     the answer is garbage (non-integer) — the caller then uses the template's `maxItems`
 *     (a safe finite default; garbage never silently means "spawn forever").
 *   - `0` for an explicit "unlimited" answer ("0"/"unlimited"/"none"/"inf"/"∞") — the caller
 *     treats 0 as NO lifetime cap.
 *   - a positive integer N for an explicit numeric cap.
 * Only the FIRST maxItems-target param is honored (the validator already rejects a second).
 */
export function resolveMaxItemsOverride(
  template: QueueTemplate,
  values: Record<string, string> = {},
): number | undefined {
  const p = template.params.find((q) => paramTarget(q) === "maxItems");
  if (p === undefined) return undefined;
  const parsed = parseMaxItemsValue(values[p.name] ?? p.default ?? "");
  if (parsed === undefined) return undefined; // blank/garbage → template default
  return parsed === null ? 0 : parsed; // null (unlimited) → 0 (the override's unlimited sentinel)
}

/**
 * (§8b) The names of REQUIRED params left empty (no provided value AND no default). PURE.
 * A non-empty result means the start must be REJECTED (the factory logs + returns null).
 */
export function missingRequiredParams(
  template: QueueTemplate,
  values: Record<string, string> = {},
): string[] {
  const missing: string[] = [];
  for (const p of template.params) {
    if (p.required !== true) continue;
    const v = values[p.name] ?? p.default ?? "";
    if (v.length === 0) missing.push(p.name);
  }
  return missing;
}

/** A valid POSIX env-var name: a letter/underscore then letters/digits/underscores. */
const ENV_NAME_RE = /^[A-Za-z_][A-Za-z0-9_]*$/;

/**
 * Validate the optional START-TIME `params` (§8b). PURE. Absent ⇒ `[]` (no prompt — the
 * prior behavior). Each entry needs a non-empty `name`; `target` is "env" (default) or
 * "maxItems". An "env"-target param needs an `env` that is a valid env-var name (the value
 * is exported under it to the provider); a "maxItems"-target param ignores `env` and there
 * may be AT MOST ONE (a second is rejected). `label`/`default` are optional strings;
 * `required` an optional bool. A malformed entry pushes an error (so the start fails loudly
 * rather than silently dropping a param). Duplicate `name`s or `env`s are rejected (an
 * ambiguous prompt / clobbered env).
 */
function validateParams(v: unknown, errors: string[]): QueueParam[] {
  if (v === undefined) return [];
  if (!Array.isArray(v)) {
    errors.push("params must be an array of {name,target?,env?,label?,default?,required?}");
    return [];
  }
  const out: QueueParam[] = [];
  const names = new Set<string>();
  const envs = new Set<string>();
  let sawMaxItems = false;
  for (const raw of v) {
    if (raw === null || typeof raw !== "object" || Array.isArray(raw)) {
      errors.push("each param must be an object {name,…}");
      continue;
    }
    const r = raw as Record<string, unknown>;
    const name = r.name;
    if (typeof name !== "string" || name.length === 0) {
      errors.push("param.name must be a non-empty string");
      continue;
    }
    let target: QueueParamTarget = "env";
    if (r.target !== undefined) {
      if (r.target === "env" || r.target === "maxItems") {
        target = r.target;
      } else {
        errors.push(`param "${name}": target must be "env" or "maxItems"`);
        continue;
      }
    }
    const env = r.env;
    if (target === "env") {
      if (typeof env !== "string" || !ENV_NAME_RE.test(env)) {
        errors.push(`param "${name}": env must be a valid env-var name (got ${JSON.stringify(env)})`);
        continue;
      }
    } else {
      // maxItems target: env is ignored; at most one such param.
      if (sawMaxItems) {
        errors.push(`param "${name}": only one "maxItems" param is allowed`);
        continue;
      }
    }
    if (names.has(name)) {
      errors.push(`duplicate param name "${name}"`);
      continue;
    }
    if (target === "env" && typeof env === "string" && envs.has(env)) {
      errors.push(`duplicate param env "${env}"`);
      continue;
    }
    if (r.label !== undefined && typeof r.label !== "string") {
      errors.push(`param "${name}": label must be a string`);
      continue;
    }
    if (r.default !== undefined && typeof r.default !== "string") {
      errors.push(`param "${name}": default must be a string`);
      continue;
    }
    if (r.required !== undefined && typeof r.required !== "boolean") {
      errors.push(`param "${name}": required must be a boolean`);
      continue;
    }
    // Optional value-suggestion provider (GUI-only): a non-empty argv. Validated here
    // (so a malformed one fails the template loudly) even though only the GUI runs it.
    let valuesCommand: string[] | undefined;
    if (r.valuesCommand !== undefined) {
      const vc = reqCommand(r.valuesCommand, `param "${name}": valuesCommand`, errors);
      if (vc === undefined) continue;
      valuesCommand = vc;
    }
    names.add(name);
    const p: QueueParam = { name };
    if (target !== "env") p.target = target;
    if (target === "env" && typeof env === "string") {
      envs.add(env);
      p.env = env;
    }
    if (typeof r.label === "string") p.label = r.label;
    if (typeof r.default === "string") p.default = r.default;
    if (r.required === true) p.required = true;
    if (valuesCommand !== undefined) p.valuesCommand = valuesCommand;
    if (target === "maxItems") sawMaxItems = true;
    out.push(p);
  }
  return out;
}

/** A command must be a non-empty array of non-empty strings (argv). PURE. */
function reqCommand(
  v: unknown,
  field: string,
  errors: string[],
): string[] | undefined {
  if (!Array.isArray(v) || v.length === 0) {
    errors.push(`${field} must be a non-empty array of strings`);
    return undefined;
  }
  if (!v.every((e) => typeof e === "string" && e.length > 0)) {
    errors.push(`${field} elements must be non-empty strings`);
    return undefined;
  }
  return v as string[];
}

function clampConcurrency(
  v: unknown,
  cap: number,
  errors: string[],
): number | undefined {
  let n: number;
  if (v === undefined) {
    n = TEMPLATE_DEFAULTS.concurrency;
  } else if (typeof v === "number" && Number.isInteger(v) && v >= 1) {
    n = v;
  } else {
    errors.push("concurrency must be a positive integer");
    return undefined;
  }
  // Clamp to `cols*rows * MAX_QUEUE_TABS` — concurrency MAY exceed ONE grid (panes overflow
  // to additional tabs, §12), but not beyond the multi-tab ceiling (a fat-fingered value
  // can't open hundreds of tabs). `cap` is the per-tab cols*rows.
  if (cap > 0 && n > cap * MAX_QUEUE_TABS) n = cap * MAX_QUEUE_TABS;
  return n;
}

function posInt(v: unknown, field: string, errors: string[]): number | undefined {
  if (typeof v === "number" && Number.isInteger(v) && v >= 1) return v;
  errors.push(`${field} must be a positive integer`);
  return undefined;
}

function posIntOrDefault(
  v: unknown,
  def: number,
  field: string,
  errors: string[],
): number {
  if (v === undefined) return def;
  if (typeof v === "number" && Number.isInteger(v) && v >= 1) return v;
  errors.push(`${field} must be a positive integer`);
  return def;
}

function nonNegNumberOrDefault(
  v: unknown,
  def: number,
  field: string,
  errors: string[],
): number {
  if (v === undefined) return def;
  if (typeof v === "number" && Number.isFinite(v) && v >= 0) return v;
  errors.push(`${field} must be a non-negative number`);
  return def;
}

function optString(
  v: unknown,
  field: string,
  errors: string[],
): string | undefined {
  if (v === undefined) return undefined;
  if (typeof v === "string" && v.length > 0) return v;
  errors.push(`${field} must be a non-empty string when present`);
  return undefined;
}

function boolOrDefault(v: unknown, def: boolean): boolean {
  return typeof v === "boolean" ? v : def;
}

function isStringArray(v: unknown): v is string[] {
  return Array.isArray(v) && v.every((e) => typeof e === "string");
}

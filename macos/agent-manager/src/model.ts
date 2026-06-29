// (ramon fork / Agent Manager) Single-shot model call. Wraps the Agent SDK
// `query()` for ONE non-agentic Haiku summary: NO mcpServers (the summary touches
// no tools — it is handed the screen text and returns prose), tools:[] (disables
// ALL built-ins — the load-bearing safety knob), maxTurns:3 (headroom — see below),
// model "claude-haiku-4-5". The final text is read off the RESULT message's
// `.result` field (narrow subtype:"success" first).
//
// Auth/billing ride the Claude Code CLI's own OAuth. By default we do NOT pass
// options.env, so the spawned `claude` inherits process.env (OAuth creds + HOME/
// PATH + GHOSTTY_AGENT_MANAGER) and bills the ambient account. When `req.configDir`
// is set (see account.ts), we pass env = {...process.env, CLAUDE_CONFIG_DIR} —
// spreading process.env so HOME/PATH/OAuth are PRESERVED and only the config dir is
// overridden — which routes auth/billing to that specific account.
//
// COLLEAGUE / DMG note (the big one): the SDK's `query()` does NOT make HTTP itself
// — it SPAWNS the native `claude` CLI (a ~215MB arm64 binary shipped inside the SDK's
// `@anthropic-ai/claude-agent-sdk-darwin-arm64` platform package). We do NOT bundle
// that binary (notarization hazard + huge). Instead we bundle ONLY the SDK's JS (via
// esbuild, see `npm run build`) and point the SDK at the colleague's ALREADY-INSTALLED
// `claude` via `pathToClaudeCodeExecutable` — resolved from `GHOSTTY_CLAUDE_PATH` (set
// by the Swift controller after a login-shell `command -v claude` probe), falling back
// to a bare `claude` (PATH resolution by the SDK's spawn). If the SDK JS can't load
// (no bundle) OR no `claude` is resolvable, `summarize()` THROWS, so the per-surface
// error path skips it (the summarizer self-disables per-surface; the Agent QUEUE, which
// makes NO Haiku calls, is unaffected). See CLAUDE.md / AGENT-MANAGER.md (Agent Manager).
//
// Returns the RAW assistant text for summarizer.parseSummary to validate. THROWS
// on a spawn-time failure or an error-subtype result so the loop catches + logs
// + continues (one bad call never stops the loop).

// TYPE-ONLY import: fully erased at compile, so the pre-bundle `model.js` carries NO
// static `import`/`require` of the SDK. The real `query` is loaded LAZILY (dynamic
// import) only when `summarize()` actually runs. The release build then RE-bundles the
// SDK's JS into `dist/` via esbuild (NO native binary), so the dynamic import resolves
// from the bundle with `node_modules` absent (a colleague's DMG ships dist-only). The
// Agent Queue needs NO npm deps and is unaffected either way. See the COLLEAGUE/DMG
// note above + CLAUDE.md (Agent Manager).
import type * as ClaudeAgentSDK from "@anthropic-ai/claude-agent-sdk";
// TYPE-ONLY: erased at compile, so dist/model.js gains NO runtime require of
// usage.ts — preserves the "loads with no node_modules" property.
import type { HaikuUsage } from "./usage.js";
// WarmBase is a CLASS used as a TYPE on the seam param; WarmBaseUnavailable is the
// cold-fallback signal we instanceof-check; costFromUsage is the shared token-bucket
// cost (LOCKED #1). These are value imports (warmbase.ts itself loads the SDK lazily,
// so importing it does NOT pull the SDK in at module load).
import {
  WarmBaseUnavailable,
  costFromUsage,
  type WarmBase,
} from "./warmbase.js";

/** The default summarizer model. Free-form string (no SDK enum). */
export const SUMMARIZER_MODEL = "claude-haiku-4-5";

/**
 * Resolve the path to the `claude` CLI the SDK should spawn. PURE over its `env`
 * argument so it is unit-testable. `GHOSTTY_CLAUDE_PATH` (set by the Swift controller
 * from a login-shell `command -v claude` probe) WINS when non-empty after trimming;
 * otherwise returns `undefined`, which tells `summarize()` to omit
 * `pathToClaudeCodeExecutable` so the SDK falls back to resolving a bare `claude` on
 * its own PATH. (We never resolve to a 215MB bundled binary — colleagues use their
 * already-installed `claude`.)
 */
export function resolveClaudePath(
  env: Record<string, string | undefined> = process.env,
): string | undefined {
  const p = env.GHOSTTY_CLAUDE_PATH;
  if (p !== undefined && p.trim() !== "") return p.trim();
  return undefined;
}

export interface SummarizeRequest {
  system: string;
  user: string;
  /** Optional model override; defaults to SUMMARIZER_MODEL. */
  model?: string;
  /** Optional CLAUDE_CONFIG_DIR for the spawned `claude` — routes auth/billing to
   *  a specific account (see account.ts). OMITTED ⇒ inherit the ambient auth. */
  configDir?: string;
  /** Optional usage sink. Called with the token/cost usage read off the SDK
   *  SUCCESS result message, BEFORE the text is returned. The caller tags it with
   *  the feature/account and records it (see usage.ts). Not called on an error
   *  result (no usage to report). */
  onUsage?: (usage: HaikuUsage) => void;
}

/** The query() function signature we depend on — injectable for tests. */
export type QueryFn = typeof ClaudeAgentSDK.query;

/**
 * Run a single-shot summary call and return the raw assistant text. THROWS on
 * an error-subtype result or a spawn-time failure. `queryFn` is injectable (tests
 * pass a fake); when omitted, the real SDK `query` is loaded via a LAZY dynamic
 * import — so the module loads with no `node_modules` and only a real summary call
 * pulls the SDK in (a missing SDK throws here → the loop logs + skips).
 */
export async function summarize(
  req: SummarizeRequest,
  queryFn?: QueryFn,
  warm?: WarmBase,
): Promise<string> {
  // WARM-BASE path (cost optimization, layered over the cold floor). When a WarmBase
  // is wired in, try the fork-per-call reuse. On a warm-MECHANISM failure
  // (WarmBaseUnavailable) fall THROUGH to today's cold one-shot for THIS call. On a
  // GENUINE model error/result (a plain Error) RETHROW — same as cold would surface
  // it, so the loop logs+skips and we do NOT make a second (cold) call (no double-cost).
  if (warm) {
    try {
      return await warm.run({
        system: req.system,
        user: req.user,
        model: req.model ?? SUMMARIZER_MODEL,
        configDir: req.configDir,
        onUsage: req.onUsage,
      });
    } catch (e) {
      if (!(e instanceof WarmBaseUnavailable)) throw e; // genuine error -> no cold retry
      // COLD FALLBACK (the floor): warm mechanism unavailable for this call.
      console.error(
        `agent-manager: warm-base fell back to cold (${e.kind}): ${e.message}`,
      );
      // fall through to the cold path below
    }
  }

  const runQuery =
    queryFn ?? (await import("@anthropic-ai/claude-agent-sdk")).query;
  // The colleague's already-installed `claude` (so we don't ship the 215MB native
  // binary). Omitted when unresolved ⇒ the SDK resolves a bare `claude` on PATH itself.
  const claudePath = resolveClaudePath();
  const q = runQuery({
    prompt: req.user,
    options: {
      // No mcpServers — the summary call needs no Ghostty tools.
      tools: [], // disables ALL built-in tools (Bash/Read/Edit/…)
      maxTurns: 3, // headroom: maxTurns:1 frequently returns subtype=error_max_turns
      // (the SDK doesn't always settle a clean result in 1 turn even with tools:[]).
      // With tools:[] there is no tool loop, so the model still produces ONE text answer;
      // the higher ceiling just lets the query reach a success result instead of erroring.
      model: req.model ?? SUMMARIZER_MODEL,
      systemPrompt: req.system,
      // Point the SDK at the system `claude` (NOT the un-bundled 215MB native binary).
      // Omitted when unresolved so the SDK falls back to its own bare-`claude` lookup.
      ...(claudePath ? { pathToClaudeCodeExecutable: claudePath } : {}),
      // env: by default OMITTED so the spawned claude inherits process.env (OAuth
      // creds + HOME/PATH + GHOSTTY_AGENT_MANAGER). When a configDir is set we pass
      // {...process.env, CLAUDE_CONFIG_DIR} — spreading so we PRESERVE the rest of
      // the env (HOME/PATH/OAuth) and only re-point the config dir to the account.
      ...(req.configDir
        ? { env: { ...process.env, CLAUDE_CONFIG_DIR: req.configDir } }
        : {}),
    },
  });

  for await (const message of q) {
    if (message.type === "result") {
      if (message.subtype === "success") {
        // Report token/cost usage off the SUCCESS result before returning. The
        // SDK result carries `usage` (input/output/cache tokens). Read defensively
        // (?? 0) so a shape change can never throw into the loop. COST is now a
        // TOKEN-BUCKET estimate via costFromUsage (LOCKED #1) — NOT the SDK's
        // cumulative-per-session `total_cost_usd` — so warm and cold are directly
        // comparable in get_haiku_usage; tagged mode:"cold".
        //
        // ⚠️ DEPLOY DISCONTINUITY (cost REPORTING only, NOT control flow): even with
        // the warm-base gate OFF, this cold path is now control-flow IDENTICAL to
        // before BUT the recorded `costUsd` shifts — it used to be the SDK's
        // `total_cost_usd`, it is now `costFromUsage(buckets)`. So every cold call's
        // logged cost number changes at the deploy that lands this. This is INERT
        // (the number is reporting in get_haiku_usage, not a decision), but flag it
        // so a one-time discontinuity in the prod cost history isn't mistaken for a
        // regression.
        if (req.onUsage) {
          const m = message as unknown as {
            usage?: {
              input_tokens?: number;
              output_tokens?: number;
              cache_read_input_tokens?: number;
              cache_creation_input_tokens?: number;
            };
          };
          const u = m.usage ?? {};
          const buckets = {
            inputTokens: u.input_tokens ?? 0,
            outputTokens: u.output_tokens ?? 0,
            cacheReadTokens: u.cache_read_input_tokens ?? 0,
            cacheCreationTokens: u.cache_creation_input_tokens ?? 0,
          };
          req.onUsage({
            model: req.model ?? SUMMARIZER_MODEL,
            ...buckets,
            costUsd: costFromUsage(buckets),
            mode: "cold",
          });
        }
        return message.result;
      }
      // Error subtypes have no .result; surface them so the loop logs + skips.
      const errs =
        "errors" in message && Array.isArray((message as { errors?: unknown }).errors)
          ? ((message as { errors: string[] }).errors).join("; ")
          : "";
      throw new Error(
        `summarize: query ended subtype=${message.subtype}${errs ? `: ${errs}` : ""}`,
      );
    }
  }
  throw new Error("summarize: query produced no result message");
}

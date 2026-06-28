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
// Returns the RAW assistant text for summarizer.parseSummary to validate. THROWS
// on a spawn-time failure or an error-subtype result so the loop catches + logs
// + continues (one bad call never stops the loop).

// TYPE-ONLY import: fully erased at compile, so `dist/model.js` carries NO static
// `import`/`require` of the SDK. The real `query` is loaded LAZILY (dynamic import)
// only when `summarize()` actually runs — so the sidecar (and the Agent Queue, which
// needs NO npm deps) loads and runs even when `node_modules` is absent, e.g. a
// colleague's DMG that bundles only `dist/`. A summary attempt with no SDK present
// throws → the per-surface error path skips it (the summarizer self-disables; the
// queue is unaffected). See the COLLEAGUE/DMG note in CLAUDE.md (Agent Manager).
import type * as ClaudeAgentSDK from "@anthropic-ai/claude-agent-sdk";
// TYPE-ONLY: erased at compile, so dist/model.js gains NO runtime require of
// usage.ts — preserves the "loads with no node_modules" property.
import type { HaikuUsage } from "./usage.js";

/** The default summarizer model. Free-form string (no SDK enum). */
export const SUMMARIZER_MODEL = "claude-haiku-4-5";

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
): Promise<string> {
  const runQuery =
    queryFn ?? (await import("@anthropic-ai/claude-agent-sdk")).query;
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
        // SDK result carries `usage` (input/output/cache tokens) + `total_cost_usd`
        // (verified non-zero on pool auth). Read defensively (?? 0) so a shape
        // change can never throw into the loop.
        if (req.onUsage) {
          const m = message as unknown as {
            usage?: {
              input_tokens?: number;
              output_tokens?: number;
              cache_read_input_tokens?: number;
              cache_creation_input_tokens?: number;
            };
            total_cost_usd?: number;
          };
          const u = m.usage ?? {};
          req.onUsage({
            model: req.model ?? SUMMARIZER_MODEL,
            inputTokens: u.input_tokens ?? 0,
            outputTokens: u.output_tokens ?? 0,
            cacheReadTokens: u.cache_read_input_tokens ?? 0,
            cacheCreationTokens: u.cache_creation_input_tokens ?? 0,
            costUsd: m.total_cost_usd ?? 0,
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

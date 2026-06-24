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

import { query } from "@anthropic-ai/claude-agent-sdk";

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
}

/** The query() function signature we depend on — injectable for tests. */
export type QueryFn = typeof query;

/**
 * Run a single-shot summary call and return the raw assistant text. THROWS on
 * an error-subtype result or a spawn-time failure. `queryFn` defaults to the
 * real SDK `query` but is injectable so the loop logic can be exercised without
 * spawning the CLI.
 */
export async function summarize(
  req: SummarizeRequest,
  queryFn: QueryFn = query,
): Promise<string> {
  const q = queryFn({
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

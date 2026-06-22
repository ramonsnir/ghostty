// (ramon fork / Agent Manager) Phase-1 single-shot model call. Wraps the Agent
// SDK `query()` for ONE non-agentic Haiku summary: NO mcpServers (the summary
// touches no tools — it is handed the screen text and returns prose), tools:[]
// (disables ALL built-ins — the load-bearing safety knob), maxTurns:1 (true
// single shot), model "claude-haiku-4-5". The final text is read off the RESULT
// message's `.result` field (narrow subtype:"success" first). Auth/billing ride
// the Claude Code CLI's own OAuth — we do NOT pass options.env (omitting it lets
// the spawned `claude` inherit process.env incl. HOME/PATH + GHOSTTY_AGENT_MANAGER).
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
      maxTurns: 1, // one model turn, no tool loop
      model: req.model ?? SUMMARIZER_MODEL,
      systemPrompt: req.system,
      // NOTE: options.env is intentionally OMITTED so the spawned claude inherits
      // process.env (OAuth creds + HOME/PATH + GHOSTTY_AGENT_MANAGER). Setting it
      // would REPLACE the env and break auth.
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

// (ramon fork / Agent Manager Phase 2) The manager's single-shot call. IDENTICAL
// shape to `summarize` (no mcpServers, tools:[], maxTurns:1, read `.result` off the
// success result) — the manager is just as non-agentic and SUGGEST-ONLY: it emits
// text and structurally CANNOT send (no tools to call). The only difference is the
// default model (Opus). Reuses the SAME injectable `QueryFn` seam.

export interface SuggestRequest {
  system: string;
  user: string;
  /** Optional model override; the caller passes the manager model. */
  model: string;
}

/**
 * Run a single-shot suggestion call and return the raw assistant text. THROWS on
 * an error-subtype result or a spawn-time failure. `queryFn` defaults to the real
 * SDK `query` but is injectable so the manager loop can be tested without spawning.
 */
export async function suggest(
  req: SuggestRequest,
  queryFn: QueryFn = query,
): Promise<string> {
  // Delegate to summarize: same options, the model passed through. (summarize's
  // model param defaults only when undefined, so an explicit model wins.)
  return summarize({ system: req.system, user: req.user, model: req.model }, queryFn);
}

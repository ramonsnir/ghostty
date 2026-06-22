# Agent Manager sidecar (Phase 1 — summarizer)

The TypeScript "brain" for the fork-only **Agent Manager**. A standalone Node
program (built with `npm`/`tsc`; **not** part of `Ghostty.xcodeproj`, sibling to
`macos/mcp-shim/`). Phase 1 is the **status summarizer**: a deterministic TS
control loop that polls Ghostty's in-GUI MCP server for live surfaces, applies
pure debounce/skip-idle/budget gates, reads each due agent surface's viewport,
makes a SINGLE-SHOT Haiku call, and writes a one-line `summary` back via
`set_surface_annotation`. The dashboard tile shows that summary.

**Phase 1 is READ-ONLY.** No autonomous send (no `send_text`/`send_key`/
`perform_action`), no manager/coordinator logic, no suggestions. The summarizer
writes ONLY `summary` (+ optional `phase`/`needsUser`).

## Architecture (deterministic loop, single-shot LLM)

- `src/mcp.ts` — a tiny **dependency-free** JSON-RPC client over global `fetch`
  (NOT an MCP-client library). Parses Ghostty's double-encoded tool-result
  envelope (`result.content[0].text` is a JSON STRING). Typed wrappers:
  `listSurfaces()`, `readSurface(id)`, `setAnnotation(id, ann)`. Every failure
  throws `McpError` the loop catches — the sidecar never crashes on a transient
  MCP error.
- `src/summarizer.ts` — the PURE core (all unit-tested): `preGate`,
  `shouldSummarize` (skip/due truth table), `fingerprint` (FNV-1a over
  agentState/lastPrompt/lastTool + last ~20 viewport lines), `parseSummary`
  (tolerant JSON repair), `composePrompt`/`serializeContext`/`buildContext`, and
  the `ConcurrencyBudget`.
- `src/prompts.ts` — the BAKED base system prompt (role + strict output
  contract + read-only safety posture).
- `src/prompt.ts` — `composeSystemPrompt` + `makeOverrideLoader` (mtime-cached
  loader of `~/.config/ghostty-ramon/agent-manager/summarizer.md`, injectable fs
  seam; missing file → null, not an error).
- `src/model.ts` — the single-shot SDK call: NO `mcpServers`, `tools: []`,
  `maxTurns: 1`, model `claude-haiku-4-5`, custom `systemPrompt`. Reads the final
  text off the result message's `.result`. Auth/billing ride the Claude Code
  CLI's own OAuth (we never set `options.env`).
- `src/index.ts` — the loop: every `POLL_INTERVAL` (5s) `listSurfaces()` → pre-gate
  → for due surfaces read viewport → full gate → `summarize()` → `parseSummary()`
  → `setAnnotation()`; records `LastSummary` per surface. Per-surface errors are
  logged and skipped; clean shutdown on SIGTERM/SIGINT.

## Env (set by the Swift `AgentManagerController`)

- `GHOSTTY_MCP_URL` — MCP server URL (default `http://127.0.0.1:8765/mcp`).
- `GHOSTTY_MCP_TOKEN` — shared secret, sent as `X-Ghostty-Token` (optional).
- `GHOSTTY_AGENT_MANAGER=1` — set by the controller (and inherited by the
  `claude` subprocess the SDK spawns); makes
  `example/claude-hooks/ghostty-agent-state.sh` early-exit so the summarizer's own
  model activity never loops back through the hook (no recursion / phantom tiles).

## Build / run / test

```sh
npm install        # needs network for @anthropic-ai/claude-agent-sdk + @types/node
npm run build      # tsc -> dist/
npm start          # node dist/index.js (the loop)
npm run typecheck  # tsc --noEmit  ← gate
npm test           # tsc + node --test "dist/**/*.test.js"  ← gate (built-in runner)
```

`npm run typecheck` and `npm test` are the A+ gates. Tests use Node's BUILT-IN
test runner (`node --test`) — no vitest/jest. In production the sidecar is spawned
+ supervised by the Swift controller; it runs the loop until SIGTERM on app quit.

## Growth path (Phases 2+, NOT in Phase 1)

- `options.resume: <session_id>` + `Query.streamInput()` for warm per-`sessionID`
  manager memory (Opus manager).
- Per-session notes + suggestion in the tile (Approve/Edit/Dismiss); **Swift**
  sends on approve. The sidecar still has no send capability.
- Phase 3: the gated `agent_manager_respond` MCP tool with all §7 guardrails.
- The coordinator pass over all sessions grouped by `cwd`.

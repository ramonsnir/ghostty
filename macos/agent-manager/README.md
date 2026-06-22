# Agent Manager sidecar (Phase 0)

The TypeScript "brain" for the fork-only **Agent Manager**. A standalone Node
program (built with `npm`/`tsc`; **not** part of `Ghostty.xcodeproj`, sibling to
`macos/mcp-shim/`). Phase 0 is a **skeleton that proves the round-trip only**:
connect to Ghostty's in-GUI MCP server, list surfaces, write one placeholder
annotation back via `set_surface_annotation`, then **idle**. The dashboard tile
showing that summary is the proof. No summarizer / manager / coordinator logic and
no autonomous send yet — those are later phases.

## Env (set by the Swift `AgentManagerController`)

- `GHOSTTY_MCP_URL` — MCP server URL (default `http://127.0.0.1:8765/mcp`).
- `GHOSTTY_MCP_TOKEN` — shared secret, sent as `X-Ghostty-Token` (optional).
- `GHOSTTY_AGENT_MANAGER=1` — set by the controller in the sidecar's environment
  (and inherited by any `claude` the sidecar spawns); makes
  `example/claude-hooks/ghostty-agent-state.sh` early-exit, so the manager's own
  agent activity never loops back through the hook and re-POSTs agent-state (no hook
  recursion / phantom tiles). In the Phase-0 skeleton the sidecar only calls the
  list/annotate MCP tools and spawns no `claude`, so the guard is a no-op today —
  it is wired now so the guarantee holds the moment the sidecar gains its own
  agent-spawning capability (Phase 1+).

## Build / run

```sh
npm install        # needs network for @anthropic-ai/claude-agent-sdk + @types/node
npm run build      # tsc -> dist/index.js
npm start          # node dist/index.js
npm run typecheck  # tsc --noEmit  ← the A+/CI gate
```

`npm run typecheck` is the gate. `npm install` needs network for the SDK dep and
may be unavailable in CI; `skipLibCheck` keeps **our** code's typecheck honest even
so. In production the sidecar is spawned + supervised by the Swift controller (not
launched by hand): it runs `node dist/index.js` with the env above. After the proof
the sidecar **idles** (it does not exit) — the controller treats a process that
exits before its `restartHealthyRunInterval` (30s) as a crash and would respawn it
in a backoff loop, so idling past that window is what makes the run count as
**healthy**. The controller terminates the process on app quit.

## Growth path (Phases 1+, NOT in Phase 0)

- `options.resume: <session_id>` + `Query.streamInput()` for warm per-`sessionID`
  manager memory.
- Model overrides via `agent-manager-*-model` config keys.
- The summarizer / manager / coordinator agents and the gated respond tool.
- A `wait_for_event` `agent_state` kind (fires on a hook agent-state transition):
  DELIBERATELY DEFERRED from Phase 0 (a SECONDARY contract item; the round-trip
  does not depend on it). See the `EventType` TODO in `MCPEventBus.swift`.

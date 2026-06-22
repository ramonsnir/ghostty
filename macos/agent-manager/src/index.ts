// (ramon fork / Agent Manager) Phase-0 sidecar SKELETON. Standalone Node/TS
// program (built with npm/tsc; NOT in Ghostty.xcodeproj). Its only job in Phase 0
// is to PROVE the round-trip: connect to Ghostty's in-GUI MCP server as an HTTP
// MCP provider, list the live surfaces, write ONE placeholder annotation back via
// `set_surface_annotation`, then exit. The tile changing to show the annotation
// summary is the proof. There is NO summarizer / manager / coordinator logic, no
// autonomous send — that is later phases.
//
// Config (env, set by the Swift AgentManagerController; mirrors macos/mcp-shim):
//   GHOSTTY_MCP_URL      MCP server URL (default http://127.0.0.1:8765/mcp)
//   GHOSTTY_MCP_TOKEN    shared secret, sent as the X-Ghostty-Token header (opt.)
//   GHOSTTY_AGENT_MANAGER=1  set by the controller (and inherited by any `claude`
//                            the sidecar spawns) so the agent-state hook early-exits
//                            and the manager's own agent activity never loops back
//                            through the hook (no recursion). Phase-0 no-op: this
//                            skeleton only calls list/annotate MCP tools and spawns
//                            no `claude` — wired now for Phase 1+.
//
// Build/run: `npm install && npm run build && npm start`. The CI/A+ gate is
// `npm run typecheck` (tsc --noEmit). After the proof the sidecar IDLES (it does
// NOT exit) — per the Phase-0 contract ("then idle") and because the controller
// treats a process that exits before `restartHealthyRunInterval` (30s) as a crash
// and would respawn it in a backoff loop. Idling keeps it alive past that window
// (counted HEALTHY) until the controller terminates it on app quit.

import { query } from "@anthropic-ai/claude-agent-sdk";

const url = process.env.GHOSTTY_MCP_URL ?? "http://127.0.0.1:8765/mcp";
const token = process.env.GHOSTTY_MCP_TOKEN;

// The token can't be sent on the bootstrap, so it rides the X-Ghostty-Token
// header on every MCP request. Omit the header entirely in open-server mode.
const headers: Record<string, string> = {};
if (token) headers["X-Ghostty-Token"] = token;

// The SDK lists Ghostty's MCP server as an external HTTP provider. The server
// name "ghostty" makes the tools surface to the model as `mcp__ghostty__<tool>`.
const mcpServers = {
  ghostty: {
    type: "http" as const,
    url,
    ...(Object.keys(headers).length > 0 ? { headers } : {}),
  },
};

const systemPrompt = [
  "You are the Ghostty Agent Manager connecting for the first time.",
  "Call list_surfaces. If there are no surfaces, stop.",
  'Otherwise take the FIRST surface\'s "id" and call set_surface_annotation with',
  'that id and summary set to "Agent Manager connected". Then stop.',
].join(" ");

async function main(): Promise<void> {
  const q = query({
    prompt: "Connect and prove the round-trip, then stop.",
    options: {
      mcpServers,
      // SAFETY (defense-in-depth — the property the design demands: the boundary,
      // not the model, enforces what can run). `bypassPermissions` removes the
      // approval gate, so we must REMOVE the dangerous tools, not merely
      // auto-approve a subset:
      //   - `tools: []` disables ALL built-in tools (Bash/Write/Edit/…), so even if
      //     the model emitted a tool_use for one it would not exist to be bypassed;
      //   - `allowedTools` then auto-approves ONLY the two MCP tools the proof needs
      //     (allowedTools merely auto-approves — it does NOT remove built-ins, hence
      //     `tools: []` above);
      //   - `disallowedTools` belt-and-suspenders names the dangerous built-ins so
      //     they are blocked even via any harness-internal direct path.
      // Net: no host shell/FS execution is reachable; the only acts available are
      // the list + annotate MCP tools (neither sends to a surface).
      tools: [],
      allowedTools: [
        "mcp__ghostty__list_surfaces",
        "mcp__ghostty__set_surface_annotation",
      ],
      disallowedTools: [
        "Bash", "Write", "Edit", "NotebookEdit", "WebFetch", "WebSearch",
      ],
      // Unattended sidecar (no TTY) — a permission prompt would hang it.
      // `bypassPermissions` requires this companion flag (SDK runtime check); it is
      // now harmless because `tools: []` leaves no dangerous tool to bypass.
      permissionMode: "bypassPermissions",
      allowDangerouslySkipPermissions: true,
      // One bounded fire: list -> annotate -> done.
      maxTurns: 6,
      model: "claude-haiku-4-5",
      systemPrompt,
    },
  });

  for await (const message of q) {
    if (message.type === "result") {
      if (message.subtype === "success") {
        console.log(`agent-manager: round-trip OK (turns=${message.num_turns})`);
      } else {
        console.error(`agent-manager: query ended with subtype=${message.subtype}`);
      }
      break;
    }
  }
}

main()
  .then(() => {
    // Phase 0: after the proof, IDLE forever rather than exit. The controller
    // would treat an early exit(0) as a crash (ran < 30s) and respawn us in a
    // backoff loop; staying alive is both the contract's "then idle" and what
    // makes the controller count this as a healthy run. Teardown happens when
    // the controller terminates the process on app quit. The never-resolving
    // promise parks the event loop without busy-waiting.
    console.log("agent-manager: idle (Phase 0 skeleton); awaiting termination");
    return new Promise<never>(() => {});
  })
  .catch((err) => {
    console.error("agent-manager: fatal", err);
    process.exit(1);
  });

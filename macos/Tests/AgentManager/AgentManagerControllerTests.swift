import Foundation
import Testing
@testable import Ghostty

/// Unit tests for the PURE units of the Agent Manager controller: the §8
/// self-disable gate (full truth table, incl. the no-MCP cases), its
/// human-readable refusal reason, the bounded restart backoff, and the
/// MCP-URL builder. No `Process`, no AppKit, no live sidecar.
struct AgentManagerControllerTests {

    // MARK: - agentManagerShouldStart (the §8 SELF-DISABLE gate)

    /// The only TRUE case: everything present.
    @Test func shouldStartWhenAllPresent() {
        #expect(AgentManagerController.agentManagerShouldStart(
            enabled: true,
            mcpListen: "127.0.0.1:8765",
            mcpToken: "secret-token",
            nodePath: "/usr/local/bin/node") == true)
    }

    /// Disabled master switch ⇒ never starts, regardless of MCP/node.
    @Test func shouldNotStartWhenDisabled() {
        #expect(AgentManagerController.agentManagerShouldStart(
            enabled: false,
            mcpListen: "127.0.0.1:8765",
            mcpToken: "secret-token",
            nodePath: "/usr/local/bin/node") == false)
    }

    /// No MCP bind address (nil OR empty) ⇒ no transport ⇒ dormant. THE explicit
    /// "no MCP" case the contract calls out.
    @Test func shouldNotStartWithoutMCPListen() {
        for listen in [nil, ""] as [String?] {
            #expect(AgentManagerController.agentManagerShouldStart(
                enabled: true, mcpListen: listen, mcpToken: "tok",
                nodePath: "/usr/local/bin/node") == false)
        }
    }

    /// No MCP token (nil OR empty) ⇒ sidecar can't authenticate ⇒ dormant.
    @Test func shouldNotStartWithoutMCPToken() {
        #expect(AgentManagerController.agentManagerShouldStart(
            enabled: true, mcpListen: "127.0.0.1:8765", mcpToken: nil,
            nodePath: "/usr/local/bin/node") == false)
        #expect(AgentManagerController.agentManagerShouldStart(
            enabled: true, mcpListen: "127.0.0.1:8765", mcpToken: "",
            nodePath: "/usr/local/bin/node") == false)
    }

    /// No node path (nil OR empty) ⇒ nothing to launch ⇒ dormant.
    @Test func shouldNotStartWithoutNode() {
        #expect(AgentManagerController.agentManagerShouldStart(
            enabled: true, mcpListen: "127.0.0.1:8765", mcpToken: "tok",
            nodePath: nil) == false)
        #expect(AgentManagerController.agentManagerShouldStart(
            enabled: true, mcpListen: "127.0.0.1:8765", mcpToken: "tok",
            nodePath: "") == false)
    }

    /// Exhaustive truth table: only `1111` is true.
    @Test func shouldStartTruthTable() {
        let listen = "127.0.0.1:8765"
        let token = "tok"
        let node = "/usr/local/bin/node"
        for e in [false, true] {
            for l in [false, true] {
                for t in [false, true] {
                    for n in [false, true] {
                        let got = AgentManagerController.agentManagerShouldStart(
                            enabled: e,
                            mcpListen: l ? listen : "",
                            mcpToken: t ? token : "",
                            nodePath: n ? node : "")
                        #expect(got == (e && l && t && n))
                    }
                }
            }
        }
    }

    // MARK: - disabledReason (the one info line)

    @Test func disabledReasonOrdersByFirstFailure() {
        #expect(AgentManagerController.disabledReason(
            enabled: false, mcpListen: "x:1", mcpToken: "t", nodePath: "/n")
            == "agent-manager is off")
        #expect(AgentManagerController.disabledReason(
            enabled: true, mcpListen: "", mcpToken: "t", nodePath: "/n")
            == "mcp-listen is not set")
        #expect(AgentManagerController.disabledReason(
            enabled: true, mcpListen: "x:1", mcpToken: "", nodePath: "/n")
            == "mcp-token is not set")
        #expect(AgentManagerController.disabledReason(
            enabled: true, mcpListen: "x:1", mcpToken: "t", nodePath: nil)
            == "node could not be resolved")
        // All present ⇒ the gate would have allowed start; the reason is "unknown"
        // (never actually surfaced in that case).
        #expect(AgentManagerController.disabledReason(
            enabled: true, mcpListen: "x:1", mcpToken: "t", nodePath: "/n")
            == "unknown")
    }

    // MARK: - restartDelay (bounded exponential backoff)

    @Test func restartDelayExponentialThenClamped() {
        #expect(AgentManagerController.restartDelay(forAttempt: 1) == 1)
        #expect(AgentManagerController.restartDelay(forAttempt: 2) == 2)
        #expect(AgentManagerController.restartDelay(forAttempt: 3) == 4)
        #expect(AgentManagerController.restartDelay(forAttempt: 4) == 8)
        #expect(AgentManagerController.restartDelay(forAttempt: 5) == 16)
        // Clamp at restartDelayMax (30): 2^5 == 32 would exceed it.
        #expect(AgentManagerController.restartDelay(forAttempt: 6) == 30)
        #expect(AgentManagerController.restartDelay(forAttempt: 100) == 30)
    }

    @Test func restartDelayNonPositiveAttemptIsBase() {
        #expect(AgentManagerController.restartDelay(forAttempt: 0)
            == AgentManagerController.restartDelayBase)
        #expect(AgentManagerController.restartDelay(forAttempt: -5)
            == AgentManagerController.restartDelayBase)
    }

    // MARK: - mcpURL

    @Test func mcpURLBuildsFromListenAndOffset() {
        #expect(AgentManagerController.mcpURL(listen: "127.0.0.1:8765", offset: 0)
            == "http://127.0.0.1:8765/mcp")
        // Per-identity offset shifts the port (ReleaseLocal +1 / Debug +2).
        #expect(AgentManagerController.mcpURL(listen: "127.0.0.1:8765", offset: 1)
            == "http://127.0.0.1:8766/mcp")
        #expect(AgentManagerController.mcpURL(listen: "127.0.0.1:8765", offset: 2)
            == "http://127.0.0.1:8767/mcp")
    }

    @Test func mcpURLRewritesWildcardHostToLoopback() {
        // The sidecar always connects locally; a wildcard bind host is not a
        // reachable client host, so it is rewritten to loopback.
        #expect(AgentManagerController.mcpURL(listen: "0.0.0.0:8765", offset: 0)
            == "http://127.0.0.1:8765/mcp")
        #expect(AgentManagerController.mcpURL(listen: "*:8765", offset: 0)
            == "http://127.0.0.1:8765/mcp")
    }

    @Test func mcpURLBracketsIPv6() {
        #expect(AgentManagerController.mcpURL(listen: "[::1]:8765", offset: 0)
            == "http://[::1]:8765/mcp")
    }

    @Test func mcpURLFallsBackOnUnparseable() {
        #expect(AgentManagerController.mcpURL(listen: "garbage", offset: 0)
            == "http://127.0.0.1:8765/mcp")
    }

    @Test func mcpURLFallbackAppliesOffset() {
        // An unparseable spec still keeps the per-identity offset so a non-Release
        // sidecar targets its OWN MCP port (8766/8767), never the Release port.
        #expect(AgentManagerController.mcpURL(listen: "garbage", offset: 1)
            == "http://127.0.0.1:8766/mcp")
        #expect(AgentManagerController.mcpURL(listen: "garbage", offset: 2)
            == "http://127.0.0.1:8767/mcp")
    }

    // MARK: - applyAgentQueueEnv (the §8a/§15 GUI→sidecar queue arming)

    /// Disabled ⇒ env is unchanged AND any inherited queue keys are stripped, so a
    /// disabled supervisor can never arm the sidecar's pass 3.
    @Test func agentQueueEnvDisabledStripsKeys() {
        let base = [
            "PATH": "/usr/bin",
            "GHOSTTY_AGENT_QUEUE": "1",                 // stray inherited value
            "GHOSTTY_AGENT_QUEUE_TEMPLATES_DIR": "/x",
            "GHOSTTY_AGENT_QUEUE_MAX_TOTAL": "99",
        ]
        let out = AgentManagerController.applyAgentQueueEnv(
            into: base, enabled: false, templatesDir: "/should/not/appear", maxTotal: 8)
        #expect(out["PATH"] == "/usr/bin")
        #expect(out["GHOSTTY_AGENT_QUEUE"] == nil)
        #expect(out["GHOSTTY_AGENT_QUEUE_TEMPLATES_DIR"] == nil)
        #expect(out["GHOSTTY_AGENT_QUEUE_MAX_TOTAL"] == nil)
    }

    /// Enabled ⇒ arms the master enable + the fleet cap; an ABSOLUTE templates dir is
    /// plumbed unchanged (so the palette + sidecar loader can't desync).
    @Test func agentQueueEnvEnabledSetsAllThree() {
        let out = AgentManagerController.applyAgentQueueEnv(
            into: ["PATH": "/usr/bin"],
            enabled: true,
            templatesDir: "/Users/me/.config/ghostty-ramon/agent-manager/queues",
            maxTotal: 12)
        #expect(out["GHOSTTY_AGENT_QUEUE"] == "1")
        #expect(out["GHOSTTY_AGENT_QUEUE_MAX_TOTAL"] == "12")
        #expect(out["GHOSTTY_AGENT_QUEUE_TEMPLATES_DIR"]
            == "/Users/me/.config/ghostty-ramon/agent-manager/queues")
        #expect(out["PATH"] == "/usr/bin")  // untouched
    }

    /// Enabled with a `~`-prefixed templates dir ⇒ the dir is TILDE-EXPANDED to an
    /// absolute path (matching the palette's `discoverTemplates`, which does the same),
    /// so the palette LISTS and the sidecar READS the identical dir. (Regression for the
    /// templates-dir tilde desync: the sidecar does no `~` expansion of its own.)
    @Test func agentQueueEnvEnabledExpandsTilde() {
        let out = AgentManagerController.applyAgentQueueEnv(
            into: [:],
            enabled: true,
            templatesDir: "~/git/queues",
            maxTotal: 8)
        let expected = ("~/git/queues" as NSString).expandingTildeInPath
        #expect(out["GHOSTTY_AGENT_QUEUE_TEMPLATES_DIR"] == expected)
        // It must actually have expanded (no leading `~` survives).
        #expect(!(out["GHOSTTY_AGENT_QUEUE_TEMPLATES_DIR"]?.hasPrefix("~") ?? true))
    }

    /// Enabled with NO templates dir (nil OR empty) ⇒ the master enable + cap are set
    /// but the dir key is ABSENT so the sidecar uses its built-in default (which
    /// matches the palette's default discovery dir).
    @Test func agentQueueEnvEnabledWithoutDirOmitsDirKey() {
        for dir in [nil, ""] as [String?] {
            let out = AgentManagerController.applyAgentQueueEnv(
                into: ["GHOSTTY_AGENT_QUEUE_TEMPLATES_DIR": "/stale"],
                enabled: true, templatesDir: dir, maxTotal: 8)
            #expect(out["GHOSTTY_AGENT_QUEUE"] == "1")
            #expect(out["GHOSTTY_AGENT_QUEUE_MAX_TOTAL"] == "8")
            // A stale inherited dir must NOT survive — the sidecar default wins.
            #expect(out["GHOSTTY_AGENT_QUEUE_TEMPLATES_DIR"] == nil)
        }
    }
}

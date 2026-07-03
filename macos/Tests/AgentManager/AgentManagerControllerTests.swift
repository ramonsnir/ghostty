import Foundation
import Testing
@testable import Ghostty

/// Unit tests for the PURE units of the Agent Manager controller: the §8
/// self-disable gate (full truth table, incl. the no-MCP cases), its
/// human-readable refusal reason, the bounded restart backoff, and the
/// MCP-URL builder. No `Process`, no AppKit, no live sidecar.
struct AgentManagerControllerTests {

    // MARK: - sidecarShouldStart (the §8 SELF-DISABLE gate, EITHER-feature)

    /// Manager alone present ⇒ starts (the shared sidecar runs the summarizer).
    @Test func shouldStartWhenManagerPresent() {
        #expect(AgentManagerController.sidecarShouldStart(
            managerEnabled: true, queueEnabled: false,
            mcpListen: "127.0.0.1:8765",
            mcpToken: "secret-token",
            nodePath: "/usr/local/bin/node") == true)
    }

    /// Queue alone present ⇒ ALSO starts (the independence requirement: the shared
    /// sidecar launches for the queue with the summarizer off).
    @Test func shouldStartWhenQueueOnlyPresent() {
        #expect(AgentManagerController.sidecarShouldStart(
            managerEnabled: false, queueEnabled: true,
            mcpListen: "127.0.0.1:8765",
            mcpToken: "secret-token",
            nodePath: "/usr/local/bin/node") == true)
    }

    /// (bell-attention) Bell-filter alone ⇒ ALSO starts — per-bell promotion is cheap
    /// (per-bell, fail-open) so it runs the sidecar on its own with the summarizer off.
    @Test func shouldStartWhenBellFilterOnly() {
        #expect(AgentManagerController.sidecarShouldStart(
            managerEnabled: false, queueEnabled: false, bellFilterEnabled: true,
            mcpListen: "127.0.0.1:8765",
            mcpToken: "secret-token",
            nodePath: "/usr/local/bin/node") == true)
    }

    /// ALL THREE features off ⇒ never starts, regardless of MCP/node.
    @Test func shouldNotStartWhenAllDisabled() {
        #expect(AgentManagerController.sidecarShouldStart(
            managerEnabled: false, queueEnabled: false, bellFilterEnabled: false,
            mcpListen: "127.0.0.1:8765",
            mcpToken: "secret-token",
            nodePath: "/usr/local/bin/node") == false)
    }

    /// No MCP bind address (nil OR empty) ⇒ no transport ⇒ dormant even with a
    /// feature on. THE explicit "no MCP" case the contract calls out.
    @Test func shouldNotStartWithoutMCPListen() {
        for listen in [nil, ""] as [String?] {
            #expect(AgentManagerController.sidecarShouldStart(
                managerEnabled: true, queueEnabled: false, mcpListen: listen,
                mcpToken: "tok", nodePath: "/usr/local/bin/node") == false)
        }
    }

    /// No MCP token (nil OR empty) ⇒ sidecar can't authenticate ⇒ dormant.
    @Test func shouldNotStartWithoutMCPToken() {
        #expect(AgentManagerController.sidecarShouldStart(
            managerEnabled: true, queueEnabled: false, mcpListen: "127.0.0.1:8765",
            mcpToken: nil, nodePath: "/usr/local/bin/node") == false)
        #expect(AgentManagerController.sidecarShouldStart(
            managerEnabled: false, queueEnabled: true, mcpListen: "127.0.0.1:8765",
            mcpToken: "", nodePath: "/usr/local/bin/node") == false)
    }

    /// No node path (nil OR empty) ⇒ nothing to launch ⇒ dormant.
    @Test func shouldNotStartWithoutNode() {
        #expect(AgentManagerController.sidecarShouldStart(
            managerEnabled: true, queueEnabled: false, mcpListen: "127.0.0.1:8765",
            mcpToken: "tok", nodePath: nil) == false)
        #expect(AgentManagerController.sidecarShouldStart(
            managerEnabled: false, queueEnabled: true, mcpListen: "127.0.0.1:8765",
            mcpToken: "tok", nodePath: "") == false)
    }

    /// Exhaustive truth table: starts iff (manager OR queue) AND listen AND token AND node.
    @Test func shouldStartTruthTable() {
        let listen = "127.0.0.1:8765"
        let token = "tok"
        let node = "/usr/local/bin/node"
        for m in [false, true] {
            for q in [false, true] {
                for l in [false, true] {
                    for t in [false, true] {
                        for n in [false, true] {
                            let got = AgentManagerController.sidecarShouldStart(
                                managerEnabled: m, queueEnabled: q,
                                mcpListen: l ? listen : "",
                                mcpToken: t ? token : "",
                                nodePath: n ? node : "")
                            #expect(got == ((m || q) && l && t && n))
                        }
                    }
                }
            }
        }
    }

    // MARK: - sidecarDisabledReason (the one info line)

    @Test func disabledReasonOrdersByFirstFailure() {
        #expect(AgentManagerController.sidecarDisabledReason(
            managerEnabled: false, queueEnabled: false, mcpListen: "x:1", mcpToken: "t", nodePath: "/n")
            == "agent-manager, agent-queue, and agent-manager-bell-filter are all off")
        // Bell-filter alone flips the "all off" reason to a transport/node check (it's a
        // valid launch trigger), proving the gate now considers it.
        #expect(AgentManagerController.sidecarDisabledReason(
            managerEnabled: false, queueEnabled: false, bellFilterEnabled: true,
            mcpListen: "", mcpToken: "t", nodePath: "/n")
            == "mcp-listen is not set")
        // A feature ON but MCP missing reports the transport failure, not "both off".
        #expect(AgentManagerController.sidecarDisabledReason(
            managerEnabled: true, queueEnabled: false, mcpListen: "", mcpToken: "t", nodePath: "/n")
            == "mcp-listen is not set")
        #expect(AgentManagerController.sidecarDisabledReason(
            managerEnabled: false, queueEnabled: true, mcpListen: "x:1", mcpToken: "", nodePath: "/n")
            == "mcp-token is not set")
        #expect(AgentManagerController.sidecarDisabledReason(
            managerEnabled: true, queueEnabled: true, mcpListen: "x:1", mcpToken: "t", nodePath: nil)
            == "node could not be resolved")
        // All present ⇒ the gate would have allowed start; the reason is "unknown"
        // (never actually surfaced in that case).
        #expect(AgentManagerController.sidecarDisabledReason(
            managerEnabled: true, queueEnabled: false, mcpListen: "x:1", mcpToken: "t", nodePath: "/n")
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

    // MARK: - applyAgentQueueEnv (the §8a/§15 · shared-templates GUI→sidecar queue arming)

    /// Disabled ⇒ env is unchanged AND any inherited queue keys are stripped — including
    /// BOTH the plural `GHOSTTY_AGENT_QUEUE_TEMPLATES_DIRS` and the legacy singular
    /// `GHOSTTY_AGENT_QUEUE_TEMPLATES_DIR` — so a disabled supervisor can never arm pass 3.
    @Test func agentQueueEnvDisabledStripsKeys() {
        let base = [
            "PATH": "/usr/bin",
            "GHOSTTY_AGENT_QUEUE": "1",                       // stray inherited value
            "GHOSTTY_AGENT_QUEUE_TEMPLATES_DIRS": "/x\n/y",  // stray plural
            "GHOSTTY_AGENT_QUEUE_TEMPLATES_DIR": "/x",        // stray legacy singular
            "GHOSTTY_AGENT_QUEUE_MAX_TOTAL": "99",
            "GHOSTTY_AGENT_QUEUE_HERO_MAX": "7",             // stray inherited value
        ]
        let out = AgentManagerController.applyAgentQueueEnv(
            into: base, enabled: false, templatesDirs: ["/should/not/appear"],
            defaultDir: "/def", maxTotal: 8, heroMax: 2)
        #expect(out["PATH"] == "/usr/bin")
        #expect(out["GHOSTTY_AGENT_QUEUE"] == nil)
        #expect(out["GHOSTTY_AGENT_QUEUE_TEMPLATES_DIRS"] == nil)
        #expect(out["GHOSTTY_AGENT_QUEUE_TEMPLATES_DIR"] == nil)
        #expect(out["GHOSTTY_AGENT_QUEUE_MAX_TOTAL"] == nil)
        #expect(out["GHOSTTY_AGENT_QUEUE_HERO_MAX"] == nil)
    }

    /// Enabled ⇒ arms the master enable + the fleet caps; the DIRS key is the effective
    /// SEARCH PATH (default dir FIRST, then each configured dir), `\n`-joined; the legacy
    /// singular is stripped (so the palette + sidecar loader can't desync).
    @Test func agentQueueEnvEnabledSetsSearchPath() {
        let out = AgentManagerController.applyAgentQueueEnv(
            into: ["PATH": "/usr/bin", "GHOSTTY_AGENT_QUEUE_TEMPLATES_DIR": "/stale"],
            enabled: true,
            templatesDirs: ["/repo/queues"],
            defaultDir: "/def/queues",
            maxTotal: 12,
            heroMax: 3)
        #expect(out["GHOSTTY_AGENT_QUEUE"] == "1")
        #expect(out["GHOSTTY_AGENT_QUEUE_MAX_TOTAL"] == "12")
        #expect(out["GHOSTTY_AGENT_QUEUE_HERO_MAX"] == "3")
        #expect(out["GHOSTTY_AGENT_QUEUE_TEMPLATES_DIRS"] == "/def/queues\n/repo/queues")
        #expect(out["GHOSTTY_AGENT_QUEUE_TEMPLATES_DIR"] == nil)  // legacy stripped
        #expect(out["PATH"] == "/usr/bin")  // untouched
    }

    /// The hero cap is forwarded verbatim, INCLUDING `0` (which disables hero
    /// dispatch) — it must be an explicit "0", never absent. The DIRS key is always
    /// set (the default dir is never empty), even with NO configured dirs.
    @Test func agentQueueEnvForwardsHeroMaxIncludingZero() {
        let out = AgentManagerController.applyAgentQueueEnv(
            into: [:], enabled: true, templatesDirs: [], defaultDir: "/def",
            maxTotal: 0, heroMax: 0)
        #expect(out["GHOSTTY_AGENT_QUEUE_HERO_MAX"] == "0")
        #expect(out["GHOSTTY_AGENT_QUEUE_TEMPLATES_DIRS"] == "/def")
    }

    /// A `~`-prefixed configured dir is TILDE-EXPANDED (no leading `~` survives); an
    /// already-absolute dir passes through; the default is always FIRST. (Regression for
    /// the templates-dir tilde desync: the sidecar does no `~` expansion of its own.)
    @Test func agentQueueEnvExpandsTilde() {
        let out = AgentManagerController.applyAgentQueueEnv(
            into: [:],
            enabled: true,
            templatesDirs: ["~/git/queues", "/abs/queues"],
            defaultDir: "~/.config/ghostty-ramon/agent-manager/queues",
            maxTotal: 8, heroMax: 2)
        let def = (("~/.config/ghostty-ramon/agent-manager/queues" as NSString)
            .expandingTildeInPath as NSString).standardizingPath
        let cfg = (("~/git/queues" as NSString).expandingTildeInPath as NSString).standardizingPath
        let dirs = out["GHOSTTY_AGENT_QUEUE_TEMPLATES_DIRS"]?
            .split(separator: "\n").map(String.init)
        #expect(dirs == [def, cfg, "/abs/queues"])
        // No leading `~` survives anywhere in the joined value.
        #expect(!(out["GHOSTTY_AGENT_QUEUE_TEMPLATES_DIRS"]?.contains("~") ?? true))
    }

    /// A configured dir EQUAL to the default is DEDUPED (default-first wins; it appears
    /// once), and configured order is otherwise preserved.
    @Test func agentQueueEnvDedupsDefault() {
        let out = AgentManagerController.applyAgentQueueEnv(
            into: [:], enabled: true,
            templatesDirs: ["/def/queues", "/repo/queues"],
            defaultDir: "/def/queues",
            maxTotal: 8, heroMax: 2)
        #expect(out["GHOSTTY_AGENT_QUEUE_TEMPLATES_DIRS"] == "/def/queues\n/repo/queues")
    }

    // MARK: - effectiveTemplateSearchPath (pure §1)

    /// The default dir is prepended FIRST, configured order is preserved, and an
    /// equivalent/repeated path is deduped (first occurrence wins).
    @Test func effectiveTemplateSearchPathOrderAndDedup() {
        let path = AgentManagerController.effectiveTemplateSearchPath(
            configured: ["/a", "/b", "/a", "/def"], defaultDir: "/def")
        #expect(path == ["/def", "/a", "/b"])
    }

    // MARK: - applySummarizerEnv (the independent summarizer arming)

    /// Enabled ⇒ sets GHOSTTY_SUMMARIZER=1 and leaves other keys untouched.
    @Test func summarizerEnvEnabledSetsFlag() {
        let out = AgentManagerController.applySummarizerEnv(
            into: ["PATH": "/usr/bin"], enabled: true)
        #expect(out["GHOSTTY_SUMMARIZER"] == "1")
        #expect(out["PATH"] == "/usr/bin")
    }

    /// Disabled ⇒ the flag is set to an EXPLICIT "0" (overriding any stray inherited
    /// "1"), so the queue can run with the summarizer's Haiku calls fully silent.
    /// Explicit (not stripped) so the sidecar can distinguish "off" from a legacy
    /// ABSENT flag (which it treats as on for back-compat).
    @Test func summarizerEnvDisabledSetsZero() {
        let out = AgentManagerController.applySummarizerEnv(
            into: ["PATH": "/usr/bin", "GHOSTTY_SUMMARIZER": "1"], enabled: false)
        #expect(out["GHOSTTY_SUMMARIZER"] == "0")
        #expect(out["PATH"] == "/usr/bin")
    }

    // MARK: - applyClaudePathEnv (colleague: route the summarizer at the system claude)

    /// A resolved path ⇒ GHOSTTY_CLAUDE_PATH is set (the sidecar passes it as the SDK's
    /// pathToClaudeCodeExecutable), other keys untouched.
    @Test func claudePathEnvSetWhenResolved() {
        let out = AgentManagerController.applyClaudePathEnv(
            into: ["PATH": "/usr/bin"], claudePath: "/opt/homebrew/bin/claude")
        #expect(out["GHOSTTY_CLAUDE_PATH"] == "/opt/homebrew/bin/claude")
        #expect(out["PATH"] == "/usr/bin")
    }

    /// nil ⇒ the key is REMOVED (so the sidecar falls back to a bare `claude` on PATH;
    /// failing that, the summarizer self-disables per-surface). A stray inherited value
    /// must not leak through — the controller is the sole authority on this path.
    @Test func claudePathEnvRemovedWhenNil() {
        let out = AgentManagerController.applyClaudePathEnv(
            into: ["PATH": "/usr/bin", "GHOSTTY_CLAUDE_PATH": "/stale/claude"], claudePath: nil)
        #expect(out["GHOSTTY_CLAUDE_PATH"] == nil)
        #expect(out["PATH"] == "/usr/bin")
    }

    /// An empty string is treated like nil (removed) — never set an empty exe path.
    @Test func claudePathEnvRemovedWhenEmpty() {
        let out = AgentManagerController.applyClaudePathEnv(
            into: ["GHOSTTY_CLAUDE_PATH": "/stale/claude"], claudePath: "")
        #expect(out["GHOSTTY_CLAUDE_PATH"] == nil)
    }

    // MARK: - applyParentPidEnv (orphan guard: tie the sidecar's life to the GUI's)

    /// A positive pid ⇒ GHOSTTY_PARENT_PID is set (the sidecar's watchdog exits when its
    /// live ppid no longer matches), other keys untouched.
    @Test func parentPidEnvSetWhenPositive() {
        let out = AgentManagerController.applyParentPidEnv(into: ["PATH": "/usr/bin"], pid: 17774)
        #expect(out["GHOSTTY_PARENT_PID"] == "17774")
        #expect(out["PATH"] == "/usr/bin")
    }

    /// A non-positive pid ⇒ the key is REMOVED (the sidecar falls back to its reparent-to-1
    /// heuristic); a stray inherited value must not leak through.
    @Test func parentPidEnvRemovedWhenNonPositive() {
        let out = AgentManagerController.applyParentPidEnv(
            into: ["GHOSTTY_PARENT_PID": "999"], pid: 0)
        #expect(out["GHOSTTY_PARENT_PID"] == nil)
    }

    // MARK: - wellKnownExecutablePaths (robust resolution vs the GUI's pristine PATH)

    /// `claude` candidates lead with the official native installer location (the spot a
    /// colleague machine had when the login-shell probe whiffed) and include the older
    /// local layout + Homebrew.
    @Test func wellKnownClaudePathsCoverCommonInstalls() {
        let paths = AgentManagerController.wellKnownExecutablePaths(for: "claude", home: "/Users/c")
        #expect(paths.first == "/Users/c/.local/bin/claude")
        #expect(paths.contains("/Users/c/.claude/local/claude"))
        #expect(paths.contains("/opt/homebrew/bin/claude"))
        #expect(paths.contains("/usr/local/bin/claude"))
    }

    /// `node` gets the generic locations (no claude-only `.claude/local` entry); nvm's
    /// versioned path is intentionally absent — the interactive `-il` shell covers it.
    @Test func wellKnownNodePathsAreGeneric() {
        let paths = AgentManagerController.wellKnownExecutablePaths(for: "node", home: "/Users/c")
        #expect(paths.first == "/Users/c/.local/bin/node")
        #expect(paths.contains("/opt/homebrew/bin/node"))
        #expect(!paths.contains { $0.contains(".claude/local") })
    }
}

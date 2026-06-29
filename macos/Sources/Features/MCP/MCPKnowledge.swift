// (ramon fork) MCP "knowledge" tools — read-only DISCOVERY + EXPLANATION of the
// fork's config keys and features, so an agent driving the fork can answer
// "what can I configure?" and "is feature X on, and how do I enable it?" without
// the human scrolling the command palette.
//
// FOUR tools, all read-only (no surface/AppKit mutation):
//   1. get_effective_config  — current values + isDefault for a curated key set
//                              (PURE Swift over the typed Ghostty.Config getters;
//                              isDefault = compared against a fresh default config).
//   2. docs_for_feature      — a curated FeatureDoc table; `enabled`/`requires`
//                              are computed LIVE from the config with the REAL
//                              precondition predicates.
//   3. describe_config_key   — one key's doc + fork-only flag + type/default/
//                              current value (Zig: ghostty_config_describe_key).
//   4. list_config_keys      — every key's name + one-line summary + fork flag
//                              (Zig: ghostty_config_key_count / _key_at).
//
// Live config reads hop to main (the GUI's Ghostty.Config is main-isolated) and
// return ONLY value types across the hop — the WebMonitor/MCP threading rule.

import Foundation
import AppKit
import GhosttyKit

enum MCPKnowledge {
    // MARK: - Live config access (main)

    /// The app's live config, read on MAIN. nil if the app delegate / config is
    /// not available (headless tests).
    static func liveConfig() -> Ghostty.Config? {
        (NSApp.delegate as? AppDelegate)?.ghostty.config
    }

    // MARK: - 1. get_effective_config

    /// One config entry: key + current value (string form) + whether it equals
    /// the built-in default. PURE value type.
    struct ConfigEntry {
        let key: String
        let value: String
        let isDefault: Bool
    }

    /// A curated read closure for a key: returns its current value as a string
    /// given a Ghostty.Config. Kept as a maintained table (the typed C getter
    /// needs per-key type knowledge) covering EVERY fork-only key plus the
    /// high-signal upstream keys a colleague is most likely to ask about.
    typealias ValueReader = (Ghostty.Config) -> String

    /// The curated key → reader table. The ORDER here is the stable listing order.
    /// MUST include all fork-only keys (see CLAUDE.md "Fork-only config keys").
    static let readers: [(key: String, read: ValueReader)] = [
        // --- fork-only keys (the whole point: discover the fork features) ---
        ("project-directory", { $0.projectDirectories.joined(separator: ",") }),
        ("bell-features-focused", { describeBellFeatures($0.bellFeaturesFocused) }),
        ("attention-features", { describeBellFeatures($0.attentionFeatures) }),
        ("agent-manager-bell-filter", { String($0.agentManagerBellFilter) }),
        ("bell-diagnostics", { String($0.bellDiagnostics) }),
        ("web-monitor-listen", { $0.webMonitorListen }),
        ("web-monitor-token", { redact($0.webMonitorToken) }),
        ("mcp-listen", { $0.mcpListen }),
        ("mcp-token", { redact($0.mcpToken) }),
        ("agent-dashboard", { String($0.agentDashboard) }),
        ("agent-dashboard-commands", { $0.agentDashboardCommands.joined(separator: ",") }),
        ("agent-dashboard-pin", { String($0.agentDashboardPin) }),
        ("agent-manager", { String($0.agentManagerEnabled) }),
        ("agent-manager-node-path", { $0.agentManagerNodePath ?? "" }),
        ("agent-manager-usage-tracking", { String($0.agentManagerUsageTracking) }),
        ("agent-queue", { String($0.agentQueueEnabled) }),
        ("agent-queue-templates-dir", { $0.agentQueueTemplatesDir ?? "" }),
        ("agent-queue-max-total", { String($0.agentQueueMaxTotal) }),
        ("pty-host", { $0.ptyHost ?? "" }),
        // --- high-signal upstream keys ---
        ("bell-features", { describeBellFeatures($0.bellFeatures) }),
        ("background-opacity", { String($0.backgroundOpacity) }),
        ("macos-icon", { $0.macosIcon.rawValue }),
        ("auto-update", { $0.autoUpdate?.rawValue ?? "" }),
        ("auto-update-channel", { $0.autoUpdateChannel.rawValue }),
        ("maximize", { String($0.maximize) }),
        ("initial-window", { String($0.initialWindow) }),
    ]

    /// Compute the effective-config entries. `changedOnly` keeps only keys whose
    /// current value differs from the built-in default. `keys`, when non-empty,
    /// restricts to those exact keys. PURE given the two configs.
    static func entries(
        live: Ghostty.Config,
        defaults: Ghostty.Config,
        changedOnly: Bool,
        keys: Set<String>?
    ) -> [ConfigEntry] {
        var out: [ConfigEntry] = []
        for (key, read) in readers {
            if let keys, !keys.contains(key) { continue }
            let value = read(live)
            let isDefault = (value == read(defaults))
            if changedOnly && isDefault { continue }
            out.append(ConfigEntry(key: key, value: value, isDefault: isDefault))
        }
        return out
    }

    /// Stringify a BellFeatures OptionSet (the enabled flag names, sorted). Used
    /// only for display in get_effective_config; "" when no flags are set.
    static func describeBellFeatures(_ f: Ghostty.Config.BellFeatures) -> String {
        let all: [(String, Ghostty.Config.BellFeatures)] = [
            ("system", .system), ("audio", .audio), ("attention", .attention),
            ("title", .title), ("border", .border), ("bounce", .bounce),
            ("badge", .badge), ("dashboard", .dashboard), ("push", .push),
            ("monitor", .monitor),
        ]
        return all.filter { f.contains($0.1) }.map { $0.0 }.joined(separator: ",")
    }

    /// Redact a secret value to a non-leaking marker (set/unset only) — a token is
    /// a shell-execution credential and must never echo through an MCP read.
    static func redact(_ value: String) -> String {
        value.isEmpty ? "" : "<set>"
    }

    // MARK: - 2. docs_for_feature

    /// One feature's curated documentation + LIVE enable/requirement status.
    struct FeatureDoc {
        let name: String
        let summary: String
        let configKeys: [String]
        let enableSteps: [String]
        /// Unmet preconditions, computed LIVE (empty ⇒ all satisfied).
        let requires: [String]
        /// Whether the feature is effectively ON right now (its master flag set
        /// AND all preconditions satisfied).
        let enabled: Bool
        let docPath: String
    }

    /// The canonical feature ids docs_for_feature accepts.
    static let featureIDs = [
        "agent-dashboard", "agent-manager", "agent-queue",
        "web-monitor", "mcp", "project-selector", "splits",
    ]

    /// Static (config-independent) facts about a feature. The live `enabled`/
    /// `requires` are layered on in `featureDoc(_:pre:)`.
    private struct FeatureSpec {
        let name: String
        let summary: String
        let configKeys: [String]
        let enableSteps: [String]
        let docPath: String
    }

    private static let specs: [String: FeatureSpec] = [
        "agent-dashboard": FeatureSpec(
            name: "Agent Dashboard",
            summary: "A sidebar panel with a live preview of every split running a CLI agent (Claude/Codex) across all tabs and windows; click a tile to jump to it.",
            configKeys: ["agent-dashboard", "agent-dashboard-commands", "agent-dashboard-pin"],
            enableSteps: [
                "Set agent-dashboard = true in ~/.config/ghostty-ramon/config.",
                "Relaunch Ghostty (the panel is read at launch); or invoke the toggle_agent_dashboard action / command palette entry.",
                "Live previews require the pty-host backend; agent detection requires a host new enough to push the foreground pid.",
            ],
            docPath: "AGENT-DASHBOARD.md"),
        "agent-manager": FeatureSpec(
            name: "Agent Manager",
            summary: "A Haiku status summarizer that annotates each Agent Dashboard tile with a live one-line semantic status. Read-only; never types into a session.",
            configKeys: ["agent-manager", "agent-manager-node-path", "mcp-listen", "mcp-token"],
            enableSteps: [
                "Set agent-manager = true in ~/.config/ghostty-ramon/config.",
                "Set mcp-listen and mcp-token (the sidecar drives the MCP server).",
                "Ensure node resolves (set agent-manager-node-path to an absolute node path if a bare `node` is not on the GUI's PATH).",
                "Build the sidecar dist and relaunch Ghostty.",
            ],
            docPath: "AGENT-MANAGER.md"),
        "agent-queue": FeatureSpec(
            name: "Agent Queue Supervisor",
            summary: "Turns the dashboard into an active supervisor: from a JSON template it opens a tab of splits, launches one CLI agent per work item, caps concurrency, and tracks each to completion.",
            configKeys: ["agent-queue", "agent-queue-templates-dir", "agent-queue-max-total", "mcp-listen", "mcp-token"],
            enableSteps: [
                "Set agent-queue = true in ~/.config/ghostty-ramon/config.",
                "Set mcp-listen and mcp-token (the supervisor drives the MCP server).",
                "Ensure node resolves (the shared sidecar runs the engine).",
                "Author a queue template and install the Claude agent-state hooks (required for auto-close).",
                "Start a run via the start_agent_queue action / command palette.",
            ],
            docPath: "AGENT-QUEUE.md"),
        "web-monitor": FeatureSpec(
            name: "Web Monitor",
            summary: "A GUI-embedded HTTP server to list/render/control live surfaces from a phone over Tailscale, with a bell→Web-Push notifier. Phone workflows only.",
            configKeys: ["web-monitor-listen", "web-monitor-token"],
            enableSteps: [
                "Set web-monitor-listen = addr:port in ~/.config/ghostty-ramon/local (this Mac's Tailscale IP).",
                "Optionally set web-monitor-token (open on a private tailnet if empty).",
                "Relaunch Ghostty. For Web Push, front it with `tailscale serve` (HTTPS) — see WEB-MONITOR.md.",
            ],
            docPath: "WEB-MONITOR.md"),
        "mcp": FeatureSpec(
            name: "MCP Server",
            summary: "A GUI-embedded MCP server (HTTP JSON-RPC + the ghostty-mcp stdio shim) giving an orchestrating agent tools to control the fork and watch/respond to sessions.",
            configKeys: ["mcp-listen", "mcp-token"],
            enableSteps: [
                "Set mcp-listen = 127.0.0.1:8765 in ~/.config/ghostty-ramon/config.",
                "ALWAYS set mcp-token (a shell-execution credential) in ~/.config/ghostty-ramon/local.",
                "Relaunch Ghostty, then register: claude mcp add ghostty -- \"$HOME/.local/bin/ghostty-mcp\".",
            ],
            docPath: "MCP-SERVER.md"),
        "project-selector": FeatureSpec(
            name: "Project Selector",
            summary: "A fuzzy palette of project directories (toggle_project_selector / ctrl+a>f); picking one opens it in a new tab from app defaults.",
            configKeys: ["project-directory"],
            enableSteps: [
                "Set one or more project-directory base dirs in ~/.config/ghostty-ramon/config.",
                "Bind toggle_project_selector (e.g. keybind = ctrl+a>f=toggle_project_selector) or use the \"Open Project…\" command palette entry.",
            ],
            docPath: "CLAUDE.md"),
        "splits": FeatureSpec(
            name: "Split / Tab Reorganization",
            summary: "The fork's tmux-style split/tab actions: flip_split, toggle_split_direction, move_split_to_new_tab, merge_tabs, mark/pull/swap_split, goto_last_surface, repeatable bindings, and directional goto_split wraparound.",
            configKeys: [],
            enableSteps: [
                "Always available — no config key. Bind the actions in ~/.config/ghostty-ramon/config or run them from the command palette.",
            ],
            docPath: "CLAUDE.md"),
    ]

    /// Build the live FeatureDoc for a feature id. `requires`/`enabled` are
    /// computed from the config with the REAL precondition predicates. PURE given
    /// the precondition snapshot.
    static func featureDoc(_ id: String, pre: Preconditions) -> FeatureDoc? {
        guard let spec = specs[id] else { return nil }
        let (requires, enabled) = status(id, pre: pre)
        return FeatureDoc(
            name: spec.name, summary: spec.summary,
            configKeys: spec.configKeys, enableSteps: spec.enableSteps,
            requires: requires, enabled: enabled, docPath: spec.docPath)
    }

    /// The config-derived inputs the precondition predicates need. Captured on
    /// main, then `status(...)` is PURE over them (unit-testable).
    struct Preconditions {
        let agentDashboard: Bool
        let agentManager: Bool
        let agentQueue: Bool
        let mcpListen: String
        let mcpToken: String
        let webMonitorListen: String
        let projectDirectories: [String]
        /// Whether a node binary resolves (config path set OR a probe succeeded).
        /// Supplied by the caller — `status` does not probe.
        let nodeResolvable: Bool

        static func from(_ c: Ghostty.Config, nodeResolvable: Bool) -> Preconditions {
            Preconditions(
                agentDashboard: c.agentDashboard,
                agentManager: c.agentManagerEnabled,
                agentQueue: c.agentQueueEnabled,
                mcpListen: c.mcpListen,
                mcpToken: c.mcpToken,
                webMonitorListen: c.webMonitorListen,
                projectDirectories: c.projectDirectories,
                nodeResolvable: nodeResolvable)
        }
    }

    /// Compute (unmetRequirements, enabled) for a feature. PURE. The predicates
    /// MIRROR the real runtime gates (e.g. the Agent Manager sidecar's
    /// sidecarShouldStart: feature flag on AND mcp-listen+mcp-token set AND node
    /// resolvable).
    static func status(_ id: String, pre: Preconditions) -> (requires: [String], enabled: Bool) {
        switch id {
        case "agent-dashboard":
            // Needs the master flag on. (pty-host / host-version are runtime/host
            // facts not in config; documented in enableSteps, not asserted here.)
            let req = pre.agentDashboard ? [] : ["agent-dashboard = true"]
            return (req, pre.agentDashboard)

        case "agent-manager", "agent-queue":
            // Mirror AgentManagerController.sidecarShouldStart: the feature flag on
            // AND mcp-listen + mcp-token set AND node resolvable.
            let flagOn = (id == "agent-manager") ? pre.agentManager : pre.agentQueue
            var req: [String] = []
            if !flagOn { req.append("\(id) = true") }
            if pre.mcpListen.isEmpty { req.append("mcp-listen set") }
            if pre.mcpToken.isEmpty { req.append("mcp-token set") }
            if !pre.nodeResolvable { req.append("node on PATH (or agent-manager-node-path)") }
            return (req, req.isEmpty)

        case "mcp":
            // mcp-listen must be set; token is recommended but the server runs open
            // without one, so it is not a hard requirement.
            let req = pre.mcpListen.isEmpty ? ["mcp-listen set"] : []
            return (req, !pre.mcpListen.isEmpty)

        case "web-monitor":
            let req = pre.webMonitorListen.isEmpty ? ["web-monitor-listen set"] : []
            return (req, !pre.webMonitorListen.isEmpty)

        case "project-selector":
            let req = pre.projectDirectories.isEmpty ? ["project-directory set"] : []
            return (req, !pre.projectDirectories.isEmpty)

        case "splits":
            // Always available (no config gate).
            return ([], true)

        default:
            return ([], false)
        }
    }
}

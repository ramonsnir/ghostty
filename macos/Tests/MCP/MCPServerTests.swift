import Foundation
import Testing
import GhosttyKit
@testable import Ghostty

/// Unit tests for the pure / value units of the fork-only MCP server. They cover
/// listen parsing, the native-keycode keySpecs table, scroll clamping, the pure
/// route decision (Host guard / token gate / backoff / method+path), the copied
/// HTTP request parser, the JSON-RPC parse + envelope layer, the tool schemas +
/// dispatch, the surfaces JSON shaping, the Host-header guard, and constant-time
/// token comparison. No live server, no AppKit.
struct MCPServerTests {

    // MARK: - parseListen

    @Test func parseListenValid() {
        let p = MCPServer.parseListen("127.0.0.1:8765")
        #expect(p?.host == "127.0.0.1")
        #expect(p?.port == 8765)
    }

    @Test func parseListenIPv6Brackets() {
        let p = MCPServer.parseListen("[::1]:8765")
        #expect(p?.host == "::1")
        #expect(p?.port == 8765)
    }

    @Test func parseListenRejectsNoColon() {
        #expect(MCPServer.parseListen("127.0.0.1") == nil)
    }

    @Test func parseListenRejectsBadPort() {
        #expect(MCPServer.parseListen("127.0.0.1:abc") == nil)
        #expect(MCPServer.parseListen("127.0.0.1:99999") == nil)
    }

    // MARK: - per-identity port offset

    @Test func portOffsetByBundleID() {
        // Release (canonical id) keeps the configured port.
        #expect(MCPServer.portOffset(forBundleID: "com.mitchellh.ghostty-ramon") == 0)
        // Dev builds shift up so they coexist with Release.
        #expect(MCPServer.portOffset(forBundleID: "com.mitchellh.ghostty-ramon.local") == 1)
        #expect(MCPServer.portOffset(forBundleID: "com.mitchellh.ghostty-ramon.debug") == 2)
        // Unknown / missing bundle id ⇒ no shift.
        #expect(MCPServer.portOffset(forBundleID: nil) == 0)
        #expect(MCPServer.portOffset(forBundleID: "com.example.other") == 0)
    }

    @Test func applyPortOffsetShifts() {
        let base = MCPServer.parseListen("127.0.0.1:8765")
        #expect(MCPServer.applyPortOffset(base, offset: 0)?.port == 8765)
        #expect(MCPServer.applyPortOffset(base, offset: 1)?.port == 8766)
        #expect(MCPServer.applyPortOffset(base, offset: 2)?.port == 8767)
        // Host is preserved.
        #expect(MCPServer.applyPortOffset(base, offset: 1)?.host == "127.0.0.1")
    }

    @Test func applyPortOffsetEdgeCases() {
        // Nothing to parse ⇒ nil through.
        #expect(MCPServer.applyPortOffset(nil, offset: 1) == nil)
        // Overflow near the ceiling ⇒ original kept, never wrapped.
        let high = MCPServer.parseListen("127.0.0.1:65535")
        #expect(MCPServer.applyPortOffset(high, offset: 1)?.port == 65535)
        #expect(MCPServer.applyPortOffset(high, offset: 2)?.port == 65535)
    }

    // MARK: - keySpecs(forKey:)

    @Test func keySpecsForKeyNamedKeys() {
        #expect(MCPInput.keySpecs(forKey: "enter") == [MCPInput.KeySpec(keycode: 36)])
        #expect(MCPInput.keySpecs(forKey: "esc") == [MCPInput.KeySpec(keycode: 53)])
        #expect(MCPInput.keySpecs(forKey: "escape") == [MCPInput.KeySpec(keycode: 53)])
        // The schema enum uses `escape`; it must equal the `esc` alias.
        #expect(MCPInput.keySpecs(forKey: "escape") == MCPInput.keySpecs(forKey: "esc"))
        #expect(MCPInput.keySpecs(forKey: "tab") == [MCPInput.KeySpec(keycode: 48)])
        #expect(MCPInput.keySpecs(forKey: "backspace") == [MCPInput.KeySpec(keycode: 51)])
        #expect(MCPInput.keySpecs(forKey: "up") == [MCPInput.KeySpec(keycode: 126)])
        #expect(MCPInput.keySpecs(forKey: "down") == [MCPInput.KeySpec(keycode: 125)])
        #expect(MCPInput.keySpecs(forKey: "left") == [MCPInput.KeySpec(keycode: 123)])
        #expect(MCPInput.keySpecs(forKey: "right") == [MCPInput.KeySpec(keycode: 124)])
        #expect(MCPInput.keySpecs(forKey: "ctrl-c") == [MCPInput.KeySpec(
            keycode: 8, mods: GHOSTTY_MODS_CTRL, unshiftedCodepoint: UInt32(UnicodeScalar("c").value))])
        #expect(MCPInput.keySpecs(forKey: "ctrl-u") == [MCPInput.KeySpec(
            keycode: 32, mods: GHOSTTY_MODS_CTRL, unshiftedCodepoint: UInt32(UnicodeScalar("u").value))])
        // ctrl-d: the Agent Queue's default exit key (§10) — must resolve (keycode 2 = 'd').
        #expect(MCPInput.keySpecs(forKey: "ctrl-d") == [MCPInput.KeySpec(
            keycode: 2, mods: GHOSTTY_MODS_CTRL, unshiftedCodepoint: UInt32(UnicodeScalar("d").value))])
    }

    @Test func keySpecsForKeyYNSpace() {
        // y/n/space ride the text path (keycode 0, text-bearing).
        let y = MCPInput.keySpecs(forKey: "y")
        #expect(y?.count == 1)
        #expect(y?.first?.keycode == 0)
        #expect(y?.first?.text == "y")

        let n = MCPInput.keySpecs(forKey: "n")
        #expect(n?.first?.text == "n")
        #expect(n?.first?.keycode == 0)

        let sp = MCPInput.keySpecs(forKey: "space")
        #expect(sp?.first?.text == " ")
        #expect(sp?.first?.keycode == 0)
    }

    @Test func keySpecsForKeyUnknownNil() {
        #expect(MCPInput.keySpecs(forKey: "f13") == nil)
        #expect(MCPInput.keySpecs(forKey: "") == nil)
    }

    // MARK: - keySpecs(forText:)

    @Test func keySpecsForTextCoalescesRun() {
        // A printable run is ONE text spec.
        let one = MCPInput.keySpecs(forText: "hello world")
        #expect(one.count == 1)
        #expect(one.first?.text == "hello world")
        #expect(one.first?.keycode == 0)

        // Embedded newline splits into a Return (keycode 36).
        let split = MCPInput.keySpecs(forText: "ab\ncd")
        #expect(split.count == 3)
        #expect(split[0].text == "ab")
        #expect(split[1].keycode == 36)
        #expect(split[1].text == nil)
        #expect(split[2].text == "cd")

        // Trailing newline -> trailing Return.
        let trailing = MCPInput.keySpecs(forText: "go\n")
        #expect(trailing.count == 2)
        #expect(trailing[0].text == "go")
        #expect(trailing[1].keycode == 36)
    }

    // MARK: - singleLine (queue spawn_split_command flattens its launch command)

    @Test func singleLineCollapsesAllNewlines() {
        // Interior \n -> space (NOT a Return); \r\n and \r too; leading/trailing trimmed.
        #expect(MCPInput.singleLine("ab\ncd") == "ab cd")
        #expect(MCPInput.singleLine("a\r\nb\rc") == "a b c")
        #expect(MCPInput.singleLine("  hi  ") == "hi")
        #expect(MCPInput.singleLine("\n\nx\n\n") == "x")
        #expect(MCPInput.singleLine("plain") == "plain")
    }

    // MARK: - scrollDeltaClamped

    @Test func scrollDeltaClampedZeroNil() {
        #expect(MCPInput.scrollDeltaClamped(0) == nil)
    }

    @Test func scrollDeltaClampedClampsRange() {
        #expect(MCPInput.scrollDeltaClamped(100) == 30)
        #expect(MCPInput.scrollDeltaClamped(-100) == -30)
        #expect(MCPInput.scrollDeltaClamped(5) == 5)
    }

    @Test func scrollDeltaClampedPreservesSign() {
        // Positive stays positive (= scroll back/up; no inversion).
        #expect((MCPInput.scrollDeltaClamped(3) ?? 0) > 0)
        #expect((MCPInput.scrollDeltaClamped(-3) ?? 0) < 0)
    }

    // MARK: - decideRoute

    private func decide(
        method: String = "POST",
        path: String = "/mcp",
        headers: [String: String] = [:],
        host: String = "127.0.0.1",
        port: UInt16 = 8765,
        token: String = "",
        failures: Int = 0
    ) -> MCPServer.RouteDecision {
        MCPServer.decideRoute(
            method: method, path: path, headers: headers,
            configuredHost: host, configuredPort: port,
            token: token, peerFailureCount: failures)
    }

    @Test func decideRouteForbiddenHost() {
        #expect(decide(headers: ["host": "evil.example.com:8765"]) == .forbiddenHost)
    }

    @Test func decideRouteOpenModeNoToken() {
        // Empty token, POST /mcp -> .mcp (no auth).
        #expect(decide(token: "") == .mcp)
    }

    @Test func decideRouteTokenRequiredHeader() {
        let token = "supersecrettoken1234"
        // Missing header -> unauthorized.
        #expect(decide(token: token) == .unauthorized)
        // Wrong header -> unauthorized.
        #expect(decide(headers: ["x-ghostty-token": "wrong"], token: token) == .unauthorized)
        // Correct header -> mcp.
        #expect(decide(headers: ["x-ghostty-token": token], token: token) == .mcp)
        // A query ?token= does NOT authorize (decideRoute has no query input;
        // confirm header-only by leaving the header out).
        #expect(decide(path: "/mcp", token: token) == .unauthorized)
    }

    @Test func decideRouteThrottledAtThreshold() {
        let token = "supersecrettoken1234"
        #expect(decide(headers: ["x-ghostty-token": token], token: token,
                       failures: MCPServer.failedAuthThreshold) == .throttled)
    }

    @Test func decideRouteMethodNotAllowed() {
        #expect(decide(method: "GET", path: "/mcp") == .methodNotAllowed)
    }

    @Test func decideRouteNotFound() {
        #expect(decide(method: "POST", path: "/other") == .notFound)
        #expect(decide(method: "GET", path: "/") == .notFound)
    }

    // MARK: - RequestParser

    private func crlf(_ s: String) -> Data { Data(s.replacingOccurrences(of: "\n", with: "\r\n").utf8) }

    @Test func requestParserCompletePost() {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        let raw = "POST /mcp HTTP/1.1\nHost: 127.0.0.1:8765\nContent-Type: application/json\nContent-Length: \(body.utf8.count)\n\n" + body
        switch MCPServer.RequestParser.parse(crlf(raw), maxRequestBytes: MCPServer.maxRequestBytes) {
        case .complete(let req):
            #expect(req.method == "POST")
            #expect(req.path == "/mcp")
            #expect(String(data: req.body, encoding: .utf8) == body)
        default:
            Issue.record("expected .complete")
        }
    }

    @Test func requestParserNeedMore() {
        // Header terminator present but body not fully arrived.
        let raw = "POST /mcp HTTP/1.1\nContent-Length: 100\n\nshort"
        switch MCPServer.RequestParser.parse(crlf(raw), maxRequestBytes: MCPServer.maxRequestBytes) {
        case .needMore: break
        default: Issue.record("expected .needMore")
        }
    }

    @Test func requestParserBadContentLength() {
        let raw = "POST /mcp HTTP/1.1\nContent-Length: -5\n\n"
        switch MCPServer.RequestParser.parse(crlf(raw), maxRequestBytes: MCPServer.maxRequestBytes) {
        case .badRequest: break
        default: Issue.record("expected .badRequest")
        }
    }

    @Test func requestParserChunkedRejected() {
        let raw = "POST /mcp HTTP/1.1\nTransfer-Encoding: chunked\n\n"
        switch MCPServer.RequestParser.parse(crlf(raw), maxRequestBytes: MCPServer.maxRequestBytes) {
        case .lengthRequired: break
        default: Issue.record("expected .lengthRequired")
        }
    }

    @Test func requestParserTooLarge() {
        let big = Data(repeating: 0x41, count: MCPServer.maxRequestBytes + 1)
        switch MCPServer.RequestParser.parse(big, maxRequestBytes: MCPServer.maxRequestBytes) {
        case .tooLarge: break
        default: Issue.record("expected .tooLarge")
        }
    }

    // MARK: - parseRPC

    @Test func parseRPCParseError() {
        switch MCPServer.parseRPC(Data("not json".utf8)) {
        case .parseError: break
        default: Issue.record("expected .parseError")
        }
    }

    @Test func parseRPCInvalidRequest() {
        // JSON object missing "method".
        switch MCPServer.parseRPC(Data(#"{"jsonrpc":"2.0","id":1}"#.utf8)) {
        case .invalid: break
        default: Issue.record("expected .invalid")
        }
    }

    @Test func parseRPCNotification() {
        switch MCPServer.parseRPC(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)) {
        case .notification(let method, _):
            #expect(method == "notifications/initialized")
        default:
            Issue.record("expected .notification")
        }
    }

    @Test func parseRPCRequestEchoesId() {
        // String id preserved as a string through resultEnvelope.
        switch MCPServer.parseRPC(Data(#"{"jsonrpc":"2.0","id":"abc","method":"x"}"#.utf8)) {
        case .request(let id, _, _):
            let env = MCPServer.resultEnvelope(id: id, result: ["ok": true])
            let obj = try! JSONSerialization.jsonObject(with: env) as! [String: Any]
            #expect(obj["id"] as? String == "abc")
        default:
            Issue.record("expected .request")
        }

        // Number id preserved as a number.
        switch MCPServer.parseRPC(Data(#"{"jsonrpc":"2.0","id":7,"method":"x"}"#.utf8)) {
        case .request(let id, _, _):
            let env = MCPServer.resultEnvelope(id: id, result: ["ok": true])
            let obj = try! JSONSerialization.jsonObject(with: env) as! [String: Any]
            #expect((obj["id"] as? NSNumber)?.intValue == 7)
        default:
            Issue.record("expected .request")
        }

        // null id preserved as null.
        switch MCPServer.parseRPC(Data(#"{"jsonrpc":"2.0","id":null,"method":"x"}"#.utf8)) {
        case .request(let id, _, _):
            let env = MCPServer.resultEnvelope(id: id, result: ["ok": true])
            let obj = try! JSONSerialization.jsonObject(with: env) as! [String: Any]
            #expect(obj["id"] is NSNull)
        default:
            Issue.record("expected .request")
        }
    }

    @Test func errorEnvelopeParseErrorIdNull() {
        let env = MCPServer.errorEnvelope(id: NSNull(), code: -32700, message: "Parse error")
        let obj = try! JSONSerialization.jsonObject(with: env) as! [String: Any]
        #expect(obj["id"] is NSNull)
        let err = obj["error"] as! [String: Any]
        #expect((err["code"] as? NSNumber)?.intValue == -32700)
    }

    @Test func errorEnvelopeInvalidIdNull() {
        let env = MCPServer.errorEnvelope(id: NSNull(), code: -32600, message: "Invalid Request")
        let obj = try! JSONSerialization.jsonObject(with: env) as! [String: Any]
        #expect(obj["id"] is NSNull)
        let err = obj["error"] as! [String: Any]
        #expect((err["code"] as? NSNumber)?.intValue == -32600)
    }

    // MARK: - tools/list schema

    @Test func toolsListHasAllTools() {
        let tools = MCPTools.toolsListResult["tools"] as! [[String: Any]]
        let names = Set(tools.compactMap { $0["name"] as? String })
        let expected: Set<String> = [
            "list_surfaces", "read_surface", "get_layout", "send_text", "send_key",
            "scroll", "wait_for_event", "watch_for_pattern", "focus_surface",
            "new_tab", "close_surface", "perform_action", "set_surface_annotation",
            // Bell Attention: promote a bell to the sticky attention state.
            "set_attention",
            // Agent Queue (§8): the supervisor's "hands".
            "spawn_split_command", "force_close_surface", "signal_attention",
            "take_queue_commands", "report_queue_status", "report_queue_graph",
            "move_surface_into_tab",
            // MCP knowledge: read-only config/feature discovery + explanation.
            "get_effective_config", "docs_for_feature",
            "describe_config_key", "list_config_keys",
            // Agent Manager: Haiku usage/budget query.
            "get_haiku_usage",
        ]
        // (adopt) The "Adopt a free split into a queue" feature added NO MCP tool: the
        // adopt/infer_key queue commands ride the existing `take_queue_commands` tool, and
        // the `queueKeySuggested` annotation field rides the existing
        // `set_surface_annotation` tool — so the registered tool count stays 26.
        #expect(names == expected)
        #expect(tools.count == 26)
        for tool in tools {
            let schema = tool["inputSchema"] as! [String: Any]
            #expect(schema["type"] as? String == "object")
            #expect(schema["additionalProperties"] as? Bool == false)
        }
    }

    @Test func toolsListSchemaRequiredFields() {
        let tools = MCPTools.toolsListResult["tools"] as! [[String: Any]]
        func schema(_ name: String) -> [String: Any] {
            (tools.first { $0["name"] as? String == name }!["inputSchema"] as! [String: Any])
        }
        func required(_ name: String) -> [String] {
            (schema(name)["required"] as? [String]) ?? []
        }
        #expect(required("read_surface").contains("id"))
        #expect(Set(required("send_text")) == ["id", "text"])
        #expect(Set(required("send_key")) == ["id", "key"])
        #expect(Set(required("scroll")) == ["id", "dy"])
        #expect(required("focus_surface") == ["id"])
        #expect(required("close_surface") == ["id"])
        #expect(Set(required("perform_action")) == ["id", "action"])

        // send_key enum matches §3.2.
        let props = schema("send_key")["properties"] as! [String: Any]
        let keyEnum = Set(((props["key"] as! [String: Any])["enum"] as! [String]))
        #expect(keyEnum == ["enter", "escape", "tab", "backspace", "up", "down", "left", "right", "y", "n", "space", "ctrl-c", "ctrl-u"])
    }

    // The list_surfaces description must keep documenting the new optional
    // per-row fields AND their honesty caveats (host-restart for processName/
    // command, the coarse idleSeconds semantics) so a future schema edit cannot
    // silently drop the prose the agent reads to interpret the rows.
    @Test func toolsListSurfacesDescriptionDocumentsNewFields() {
        let tools = MCPTools.toolsListResult["tools"] as! [[String: Any]]
        let desc = tools.first { $0["name"] as? String == "list_surfaces" }!["description"] as! String
        #expect(desc.contains("processName"))
        #expect(desc.contains("command"))
        #expect(desc.contains("idleSeconds"))
        // The host-restart caveat for processName/command.
        #expect(desc.contains("pty-host"))
        #expect(desc.contains("host is restarted"))
        // The coarse idleSeconds "repaints while working" nuance.
        #expect(desc.contains("repaint"))
    }

    // MARK: - initialize

    @Test func initializeResultShape() {
        let r = MCPServer.initializeResult
        #expect(r["protocolVersion"] as? String == "2024-11-05")
        let caps = r["capabilities"] as! [String: Any]
        let tools = caps["tools"] as! [String: Any]
        #expect(tools["listChanged"] as? Bool == false)
        let info = r["serverInfo"] as! [String: Any]
        #expect(info["name"] as? String == "ghostty-mcp")
    }

    // MARK: - surfacesJSONData

    @Test func surfacesJSONDataShape() {
        let row = MCPLayout.SurfaceRow(
            id: "ABC", title: "vim", pwd: "/tmp",
            window: 0, tab: 1, tabTitle: "T",
            splitIndex: 2, splitCount: 3,
            focused: true, bell: false, attentionNeeded: false, exited: false, atPrompt: true,
            processName: "bash", command: "bash claude-pool", idleSeconds: 0.0,
            agentState: "working", lastPrompt: "do it", lastTool: "Bash",
            notes: "Implementing fix", agentKind: "claude", hidden: false, sessionID: 4242)
        let out = MCPLayout.surfacesJSONData([row])
        #expect(out.count == 1)
        let d = out[0]
        #expect(d["id"] as? String == "ABC")
        #expect(d["title"] as? String == "vim")
        #expect(d["pwd"] as? String == "/tmp")
        #expect(d["window"] as? Int == 0)
        #expect(d["tab"] as? Int == 1)
        #expect(d["tabTitle"] as? String == "T")
        #expect(d["splitIndex"] as? Int == 2)
        #expect(d["splitCount"] as? Int == 3)
        #expect(d["focused"] as? Bool == true)
        #expect(d["bell"] as? Bool == false)
        #expect(d["attentionNeeded"] as? Bool == false)
        #expect(d["exited"] as? Bool == false)
        #expect(d["atPrompt"] as? Bool == true)
        #expect(d["processName"] as? String == "bash")
        #expect(d["command"] as? String == "bash claude-pool")
        #expect(d["idleSeconds"] as? Double == 0.0)
        #expect(d["agentState"] as? String == "working")
        #expect(d["lastPrompt"] as? String == "do it")
        #expect(d["lastTool"] as? String == "Bash")
        #expect(d["notes"] as? String == "Implementing fix")
        // fork / Agent Manager: the detector's agent kind rides through (the
        // foreground process is the `bash` pool wrapper, NOT "claude" — agentKind
        // is the reliable signal the summarizer uses).
        #expect(d["agentKind"] as? String == "claude")
        // fork / Agent Queue (§8.4): sessionID is a PLAIN integer, always present.
        #expect((d["sessionID"] as? NSNumber)?.uint64Value == 4242)
        // fork / Agent Manager: hidden is OMITTED when false (not hidden).
        #expect(d["hidden"] == nil)
    }

    // fork / Agent Manager: a hidden tile emits `hidden:true` so the summarizer skips it.
    @Test func surfacesJSONDataEmitsHiddenWhenTrue() {
        let row = MCPLayout.SurfaceRow(
            id: "ABC", title: "claude", pwd: "/tmp",
            window: 0, tab: 1, tabTitle: "T",
            splitIndex: 0, splitCount: 1,
            focused: false, bell: false, attentionNeeded: false, exited: false, atPrompt: true,
            processName: nil, command: nil, idleSeconds: nil,
            agentState: "waiting", lastPrompt: nil, lastTool: nil, notes: nil,
            agentKind: "claude", hidden: true, sessionID: 7)
        let d = MCPLayout.surfacesJSONData([row])[0]
        #expect(d["hidden"] as? Bool == true)
    }

    // fork: the three optional fields are OMITTED (not null/empty) when unknown.
    @Test func surfacesJSONDataOmitsNilProcessFields() {
        let row = MCPLayout.SurfaceRow(
            id: "ABC", title: "vim", pwd: "/tmp",
            window: 0, tab: 1, tabTitle: "T",
            splitIndex: 2, splitCount: 3,
            focused: true, bell: false, attentionNeeded: false, exited: false, atPrompt: true,
            processName: nil, command: nil, idleSeconds: nil,
            agentState: nil, lastPrompt: nil, lastTool: nil, notes: nil,
            agentKind: nil, hidden: false, sessionID: 0)
        let d = MCPLayout.surfacesJSONData([row])[0]
        #expect(d["processName"] == nil)
        #expect(d["command"] == nil)
        #expect(d["idleSeconds"] == nil)
        // fork / Agent Manager: agent-* fields are omitted (not null) when unknown.
        #expect(d["agentState"] == nil)
        #expect(d["lastPrompt"] == nil)
        #expect(d["lastTool"] == nil)
        #expect(d["notes"] == nil)
        #expect(d["agentKind"] == nil)
        #expect(d["hidden"] == nil)
        // The always-present fields are unaffected.
        #expect(d["id"] as? String == "ABC")
        #expect(d["atPrompt"] as? Bool == true)
        // fork / Agent Queue (§8.4): sessionID is a plain integer, ALWAYS present —
        // 0 here (no host session). The supervisor self-disables on a 0.
        #expect((d["sessionID"] as? NSNumber)?.uint64Value == 0)
    }

    // fork / Agent Queue (adopt): the queue tags MUST be emitted when present, so the
    // supervisor's reconcile orphan-adoption can read queueName/queueKey back off
    // list_surfaces and fold an ADOPTED surface into run.active (counted + tracked).
    // Omitted (not null) on a non-queue surface — honest absence.
    @Test func surfacesJSONDataEmitsQueueTagsWhenPresentOmitsWhenNil() {
        let tagged = MCPLayout.SurfaceRow(
            id: "ABC", title: "claude", pwd: "/tmp",
            window: 0, tab: 1, tabTitle: "T",
            splitIndex: 0, splitCount: 1,
            focused: false, bell: false, attentionNeeded: false, exited: false, atPrompt: true,
            processName: nil, command: nil, idleSeconds: nil,
            agentState: "working", lastPrompt: nil, lastTool: nil, notes: nil,
            agentKind: "claude", hidden: false, sessionID: 7,
            queueKey: "EX-1859", queueName: "Acme · Pilot",
            queueUrl: "https://example.com/EX-1859")
        let d = MCPLayout.surfacesJSONData([tagged])[0]
        #expect(d["queueKey"] as? String == "EX-1859")
        #expect(d["queueName"] as? String == "Acme · Pilot")
        #expect(d["queueUrl"] as? String == "https://example.com/EX-1859")

        let plain = MCPLayout.SurfaceRow(
            id: "DEF", title: "vim", pwd: "/tmp",
            window: 0, tab: 0, tabTitle: "T",
            splitIndex: 0, splitCount: 1,
            focused: false, bell: false, attentionNeeded: false, exited: false, atPrompt: true,
            processName: nil, command: nil, idleSeconds: nil,
            agentState: nil, lastPrompt: nil, lastTool: nil, notes: nil,
            agentKind: nil, hidden: false, sessionID: 0)
        let pd = MCPLayout.surfacesJSONData([plain])[0]
        #expect(pd["queueKey"] == nil)
        #expect(pd["queueName"] == nil)
        #expect(pd["queueUrl"] == nil)
        // fork / Hero Agents: a non-hero row omits `hero` (default false ⇒ absent).
        #expect(pd["hero"] == nil)
    }

    // fork / Hero Agents: a hero surface MUST emit `hero:true` so the supervisor's
    // reconcile reads the hero state back off list_surfaces (the reconcile-visibility
    // chokepoint, mirroring queueKey). Omitted (not null/false) on a non-hero surface.
    @Test func surfacesJSONDataEmitsHeroWhenTrueOmitsWhenFalse() {
        let hero = MCPLayout.SurfaceRow(
            id: "ABC", title: "claude", pwd: "/tmp",
            window: 0, tab: 1, tabTitle: "T",
            splitIndex: 0, splitCount: 1,
            focused: false, bell: false, attentionNeeded: false, exited: false, atPrompt: true,
            processName: nil, command: nil, idleSeconds: nil,
            agentState: "working", lastPrompt: nil, lastTool: nil, notes: nil,
            agentKind: "claude", hidden: false, sessionID: 7,
            queueKey: "EX-1859", queueName: "Acme · Pilot",
            queueUrl: "https://example.com/EX-1859", hero: true)
        let hd = MCPLayout.surfacesJSONData([hero])[0]
        #expect(hd["hero"] as? Bool == true)

        let regular = MCPLayout.SurfaceRow(
            id: "DEF", title: "claude", pwd: "/tmp",
            window: 0, tab: 0, tabTitle: "T",
            splitIndex: 0, splitCount: 1,
            focused: false, bell: false, attentionNeeded: false, exited: false, atPrompt: true,
            processName: nil, command: nil, idleSeconds: nil,
            agentState: "working", lastPrompt: nil, lastTool: nil, notes: nil,
            agentKind: "claude", hidden: false, sessionID: 8,
            queueKey: "EX-2", queueName: "Acme · Pilot", queueUrl: nil, hero: false)
        let rd = MCPLayout.surfacesJSONData([regular])[0]
        #expect(rd["hero"] == nil)
    }

    // fork / Agent Queue Schedules: a scheduled scan-agent surface MUST emit `scheduleId`
    // (with queueName) so the supervisor reads its scheduled runs back off list_surfaces
    // (the reconcile-visibility chokepoint, mirroring queueKey). Omitted on a normal row.
    @Test func surfacesJSONDataEmitsScheduleIdWhenPresentOmitsWhenNil() {
        let sched = MCPLayout.SurfaceRow(
            id: "ABC", title: "claude", pwd: "/tmp",
            window: 0, tab: 1, tabTitle: "T",
            splitIndex: 0, splitCount: 1,
            focused: false, bell: false, attentionNeeded: false, exited: false, atPrompt: true,
            processName: nil, command: nil, idleSeconds: nil,
            agentState: "working", lastPrompt: nil, lastTool: nil, notes: nil,
            agentKind: "claude", hidden: false, sessionID: 7,
            queueKey: nil, queueName: "Acme · Pilot", queueUrl: nil,
            hero: false, scheduleId: "doc-drift")
        let sd = MCPLayout.surfacesJSONData([sched])[0]
        #expect(sd["scheduleId"] as? String == "doc-drift")
        #expect(sd["queueName"] as? String == "Acme · Pilot")
        #expect(sd["queueKey"] == nil) // a schedule is not a work item

        let plain = MCPLayout.SurfaceRow(
            id: "DEF", title: "vim", pwd: "/tmp",
            window: 0, tab: 0, tabTitle: "T",
            splitIndex: 0, splitCount: 1,
            focused: false, bell: false, attentionNeeded: false, exited: false, atPrompt: true,
            processName: nil, command: nil, idleSeconds: nil,
            agentState: nil, lastPrompt: nil, lastTool: nil, notes: nil,
            agentKind: nil, hidden: false, sessionID: 0)
        #expect(MCPLayout.surfacesJSONData([plain])[0]["scheduleId"] == nil)
    }

    // MARK: - dispatch (AppKit-free paths only)

    @Test func dispatchUnknownToolError() {
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        switch MCPTools.dispatch(name: "nope", arguments: [:], server: server) {
        case .methodNotFound: break
        default: Issue.record("expected .methodNotFound")
        }
    }

    @Test func dispatchSendKeyUnknownKey() {
        // Resolves the (unknown) key BEFORE any main hop -> .toolError.
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        let uuid = UUID().uuidString
        switch MCPTools.dispatch(name: "send_key", arguments: ["id": uuid, "key": "f13"], server: server) {
        case .toolError(let msg):
            #expect(msg.contains("unknown key"))
        default:
            Issue.record("expected .toolError for unknown key")
        }
    }

    @Test func dispatchSendKeyMissingIdInvalidParams() {
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        switch MCPTools.dispatch(name: "send_key", arguments: ["key": "enter"], server: server) {
        case .invalidParams: break
        default: Issue.record("expected .invalidParams")
        }
    }

    // (ramon fork / Bell Attention) set_attention pre-hop guards.
    @Test func dispatchSetAttentionMissingIdInvalidParams() {
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        switch MCPTools.dispatch(name: "set_attention", arguments: ["on": true], server: server) {
        case .invalidParams: break
        default: Issue.record("expected .invalidParams for missing id")
        }
    }

    @Test func dispatchSetAttentionMissingOnInvalidParams() {
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        switch MCPTools.dispatch(name: "set_attention", arguments: ["id": UUID().uuidString], server: server) {
        case .invalidParams: break
        default: Issue.record("expected .invalidParams for missing on")
        }
    }

    // Every tool's AppKit-FREE pre-hop guard: a missing/invalid id (and the other
    // synchronous validations) must fail fast with .invalidParams / .toolError
    // BEFORE any DispatchQueue.main.sync hop. (The send_key missing-id test above
    // proves these guards are reachable off the main thread.)

    @Test func dispatchReadSurfaceMissingIdInvalidParams() {
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        switch MCPTools.dispatch(name: "read_surface", arguments: [:], server: server) {
        case .invalidParams: break
        default: Issue.record("expected .invalidParams")
        }
        // Garbage (non-UUID) id is also .invalidParams (uuidArg returns nil).
        switch MCPTools.dispatch(name: "read_surface", arguments: ["id": "not-a-uuid"], server: server) {
        case .invalidParams: break
        default: Issue.record("expected .invalidParams for garbage id")
        }
    }

    @Test func dispatchReadSurfaceViewportOnlyIgnoresModeArg() {
        // read_surface is viewport-only: there is no `mode` parameter (a
        // "scrollback" read would be a lie under the pty-host viewport-only
        // mirror). A valid id with a stray `mode` arg must therefore NOT be
        // rejected as invalidParams — the arg is ignored and the call proceeds
        // to the main hop, which returns .toolError for an unresolvable id in
        // the headless test environment.
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        for mode in ["viewport", "scrollback", "full", "scrollbck"] {
            let a: [String: Any] = ["id": UUID().uuidString, "mode": mode]
            switch MCPTools.dispatch(name: "read_surface", arguments: a, server: server) {
            case .invalidParams: Issue.record("stray mode \(mode) must not be invalidParams (viewport-only)")
            default: break
            }
        }
    }

    @Test func dispatchSendTextMissingIdInvalidParams() {
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        switch MCPTools.dispatch(name: "send_text", arguments: ["text": "hi"], server: server) {
        case .invalidParams: break
        default: Issue.record("expected .invalidParams")
        }
    }

    @Test func dispatchSendTextMissingTextInvalidParams() {
        // Valid id but no text -> .invalidParams (before any main hop).
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        switch MCPTools.dispatch(name: "send_text", arguments: ["id": UUID().uuidString], server: server) {
        case .invalidParams(let msg):
            #expect(msg.contains("text"))
        default:
            Issue.record("expected .invalidParams for missing text")
        }
    }

    @Test func dispatchScrollMissingIdInvalidParams() {
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        switch MCPTools.dispatch(name: "scroll", arguments: ["dy": 3], server: server) {
        case .invalidParams: break
        default: Issue.record("expected .invalidParams")
        }
    }

    @Test func dispatchScrollMissingDyInvalidParams() {
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        switch MCPTools.dispatch(name: "scroll", arguments: ["id": UUID().uuidString], server: server) {
        case .invalidParams(let msg):
            #expect(msg.contains("dy"))
        default:
            Issue.record("expected .invalidParams for missing dy")
        }
    }

    @Test func dispatchScrollZeroDyToolError() {
        // A present-but-zero dy is a valid argument shape but a no-op -> .toolError.
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        switch MCPTools.dispatch(name: "scroll", arguments: ["id": UUID().uuidString, "dy": 0], server: server) {
        case .toolError(let msg):
            #expect(msg.contains("non-zero"))
        default:
            Issue.record("expected .toolError for zero dy")
        }
    }

    @Test func dispatchFocusSurfaceMissingIdInvalidParams() {
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        switch MCPTools.dispatch(name: "focus_surface", arguments: [:], server: server) {
        case .invalidParams: break
        default: Issue.record("expected .invalidParams")
        }
    }

    @Test func dispatchCloseSurfaceMissingIdInvalidParams() {
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        switch MCPTools.dispatch(name: "close_surface", arguments: [:], server: server) {
        case .invalidParams: break
        default: Issue.record("expected .invalidParams")
        }
    }

    @Test func dispatchPerformActionMissingIdInvalidParams() {
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        switch MCPTools.dispatch(name: "perform_action", arguments: ["action": "mark_split"], server: server) {
        case .invalidParams: break
        default: Issue.record("expected .invalidParams")
        }
    }

    @Test func dispatchPerformActionEmptyActionInvalidParams() {
        // Valid id but an empty action string -> .invalidParams (before main hop).
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        let args: [String: Any] = ["id": UUID().uuidString, "action": ""]
        switch MCPTools.dispatch(name: "perform_action", arguments: args, server: server) {
        case .invalidParams(let msg):
            #expect(msg.contains("action"))
        default:
            Issue.record("expected .invalidParams for empty action")
        }
    }

    @Test func dispatchWatchPatternMissingIdInvalidParams() {
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        switch MCPTools.dispatch(name: "watch_for_pattern", arguments: ["regex": "x"], server: server) {
        case .invalidParams: break
        default: Issue.record("expected .invalidParams")
        }
    }

    @Test func dispatchWatchPatternEmptyRegexInvalidParams() {
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        let args: [String: Any] = ["id": UUID().uuidString, "regex": ""]
        switch MCPTools.dispatch(name: "watch_for_pattern", arguments: args, server: server) {
        case .invalidParams(let msg):
            #expect(msg.contains("regex"))
        default:
            Issue.record("expected .invalidParams for empty regex")
        }
    }

    @Test func dispatchWaitForEventParks() {
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        switch MCPTools.dispatch(name: "wait_for_event", arguments: ["timeoutMs": 5000], server: server) {
        case .waitForEvent(let spec):
            #expect(spec.timeoutMs == 5000)
            #expect(spec.ids.isEmpty)
            #expect(spec.types.isEmpty)
        default:
            Issue.record("expected .waitForEvent")
        }
    }

    @Test func dispatchWaitForEventKnownTypesPark() {
        // All-known types still parks with the types preserved.
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        let args: [String: Any] = ["filter": ["types": ["bell", "exited", "prompt"]]]
        switch MCPTools.dispatch(name: "wait_for_event", arguments: args, server: server) {
        case .waitForEvent(let spec):
            #expect(spec.types == ["bell", "exited", "prompt"])
        default:
            Issue.record("expected .waitForEvent")
        }
    }

    // (ramon fork / Agent Queue latency) The queue-command wake type is an accepted
    // wait_for_event filter type, so the sidecar's queue-reactive long-poll can park on it.
    @Test func dispatchWaitForEventQueueCommandType() {
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        let args: [String: Any] = ["filter": ["types": ["queue_command"]]]
        switch MCPTools.dispatch(name: "wait_for_event", arguments: args, server: server) {
        case .waitForEvent(let spec):
            #expect(spec.types == ["queue_command"])
        default:
            Issue.record("expected .waitForEvent for queue_command")
        }
    }

    // (ramon fork / Bell Attention v2 dismissal-abort) The bell-dismissal wake type is an
    // accepted wait_for_event filter type, so the sidecar's bell-dismiss loop can park on it
    // and cancel/abort an in-flight classify when the user focuses+dismisses a bell.
    @Test func dispatchWaitForEventBellDismissedType() {
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        let args: [String: Any] = ["filter": ["types": ["bell_dismissed"]]]
        switch MCPTools.dispatch(name: "wait_for_event", arguments: args, server: server) {
        case .waitForEvent(let spec):
            #expect(spec.types == ["bell_dismissed"])
        default:
            Issue.record("expected .waitForEvent for bell_dismissed")
        }
    }

    // An unknown filter type still fails fast (guards the whitelist that the wake type joined).
    @Test func dispatchWaitForEventUnknownTypeRejected() {
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        let args: [String: Any] = ["filter": ["types": ["not_a_real_event"]]]
        switch MCPTools.dispatch(name: "wait_for_event", arguments: args, server: server) {
        case .invalidParams: break
        default: Issue.record("expected .invalidParams for an unknown event type")
        }
    }

    // The wake event's wire value is the snake_case `queue_command` (what the tool whitelist and
    // the sidecar's `types:["queue_command"]` long-poll match), and a surface-less wake carrying
    // the sentinel id matches a waiter with an EMPTY ids filter (match any).
    @Test func queueCommandEventTypeWireValueAndSentinel() {
        #expect(MCPEventBus.EventType.queueCommand.rawValue == "queue_command")
        let sentinel = MCPEventBus.queueCommandSentinelID.uuidString
        #expect(MCPEventBus.eventMatches(ids: [], types: ["queue_command"],
                                         eventId: sentinel, eventType: "queue_command"))
        // A bell waiter must NOT be woken by a queue-command event.
        #expect(!MCPEventBus.eventMatches(ids: [], types: ["bell"],
                                          eventId: sentinel, eventType: "queue_command"))
    }

    @Test func eventMatchesPure() {
        let upper = UUID().uuidString          // Foundation: uppercase
        let lower = upper.lowercased()
        // Empty filters match anything.
        #expect(MCPEventBus.eventMatches(ids: [], types: [], eventId: upper, eventType: "bell"))
        // Type filter (exact).
        #expect(MCPEventBus.eventMatches(ids: [], types: ["bell"], eventId: upper, eventType: "bell"))
        #expect(!MCPEventBus.eventMatches(ids: [], types: ["bell"], eventId: upper, eventType: "exited"))
        // Id filter matches the uppercase event id.
        #expect(MCPEventBus.eventMatches(ids: [upper], types: [], eventId: upper, eventType: "bell"))
        // Id filter is CASE-INSENSITIVE: a lowercase client-supplied id still
        // matches the uppercase event id (the prior bug: it silently never fired).
        #expect(MCPEventBus.eventMatches(ids: [lower], types: [], eventId: upper, eventType: "bell"))
        // A non-matching id does not match.
        #expect(!MCPEventBus.eventMatches(ids: [UUID().uuidString], types: [], eventId: upper, eventType: "bell"))
        // Both must hold.
        #expect(MCPEventBus.eventMatches(ids: [lower], types: ["bell"], eventId: upper, eventType: "bell"))
        #expect(!MCPEventBus.eventMatches(ids: [lower], types: ["exited"], eventId: upper, eventType: "bell"))
    }

    @Test func dispatchWaitForEventUnknownTypeInvalidParams() {
        // A typo'd event type fails fast rather than timing out after 30s.
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        let args: [String: Any] = ["filter": ["types": ["bell", "bogus"]]]
        switch MCPTools.dispatch(name: "wait_for_event", arguments: args, server: server) {
        case .invalidParams(let msg):
            #expect(msg.contains("bogus"))
        default:
            Issue.record("expected .invalidParams for unknown event type")
        }
    }

    // MARK: - timeout clamping

    @Test func clampTimeoutMsPure() {
        // Within bounds: unchanged.
        #expect(MCPEventBus.clampTimeoutMs(5_000) == 5_000)
        #expect(MCPEventBus.clampTimeoutMs(MCPEventBus.timeoutFloorMs) == MCPEventBus.timeoutFloorMs)
        #expect(MCPEventBus.clampTimeoutMs(MCPEventBus.timeoutCeilingMs) == MCPEventBus.timeoutCeilingMs)
        // Above ceiling: clamped down (the 24h-park starvation case).
        #expect(MCPEventBus.clampTimeoutMs(86_400_000) == MCPEventBus.timeoutCeilingMs)
        // Below floor (incl. zero and negative): clamped up.
        #expect(MCPEventBus.clampTimeoutMs(0) == MCPEventBus.timeoutFloorMs)
        #expect(MCPEventBus.clampTimeoutMs(-1) == MCPEventBus.timeoutFloorMs)
        #expect(MCPEventBus.clampTimeoutMs(10) == MCPEventBus.timeoutFloorMs)
        // Non-finite (NaN / +inf / -inf) collapses to the in-range default.
        #expect(MCPEventBus.clampTimeoutMs(.nan) == 30_000)
        #expect(MCPEventBus.clampTimeoutMs(.infinity) == 30_000)
        #expect(MCPEventBus.clampTimeoutMs(-.infinity) == 30_000)
    }

    @Test func clampCeilingBelowShimTimeout() {
        // The server ceiling MUST stay strictly below the shim's 180s URLSession
        // timeout so the shim never reports a spurious transport error while the
        // server still holds a waiter parked.
        #expect(MCPEventBus.timeoutCeilingMs < 180_000)
        #expect(MCPEventBus.timeoutFloorMs > 0)
        #expect(MCPEventBus.timeoutFloorMs < MCPEventBus.timeoutCeilingMs)
    }

    @Test func dispatchWaitForEventClampsHugeTimeout() {
        // A degenerate huge timeoutMs would park a connection (idle-watchdog
        // exempt) up to the 32-conn cap = starvation. It must be clamped.
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        switch MCPTools.dispatch(name: "wait_for_event", arguments: ["timeoutMs": 86_400_000], server: server) {
        case .waitForEvent(let spec):
            #expect(spec.timeoutMs == MCPEventBus.timeoutCeilingMs)
        default:
            Issue.record("expected .waitForEvent with clamped timeout")
        }
    }

    @Test func dispatchWaitForEventClampsZeroTimeout() {
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        switch MCPTools.dispatch(name: "wait_for_event", arguments: ["timeoutMs": 0], server: server) {
        case .waitForEvent(let spec):
            #expect(spec.timeoutMs == MCPEventBus.timeoutFloorMs)
        default:
            Issue.record("expected .waitForEvent with clamped timeout")
        }
    }

    @Test func dispatchWatchPatternClampsHugeTimeout() {
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        let args: [String: Any] = ["id": UUID().uuidString, "regex": "x", "timeoutMs": 86_400_000]
        switch MCPTools.dispatch(name: "watch_for_pattern", arguments: args, server: server) {
        case .watchPattern(let spec):
            #expect(spec.timeoutMs == MCPEventBus.timeoutCeilingMs)
        default:
            Issue.record("expected .watchPattern with clamped timeout")
        }
    }

    @Test func dispatchWatchPatternInvalidRegexToolError() {
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        let args: [String: Any] = ["id": UUID().uuidString, "regex": "([unclosed"]
        switch MCPTools.dispatch(name: "watch_for_pattern", arguments: args, server: server) {
        case .toolError(let msg):
            #expect(msg.contains("invalid regex"))
        default:
            Issue.record("expected .toolError for invalid regex")
        }
    }

    // MARK: - HTTPResponse.empty

    @Test func httpResponseEmptyBody() {
        let r = MCPServer.HTTPResponse.empty(202, "Accepted")
        #expect(r.body == Data())
        #expect(r.statusCode == 202)
        #expect(r.reason == "Accepted")
    }

    // MARK: - Host-header guard

    @Test func hostHeaderAllowedLoopback() {
        #expect(MCPServer.hostHeaderAllowed("localhost:8765", configuredHost: "127.0.0.1", configuredPort: 8765))
        #expect(MCPServer.hostHeaderAllowed("127.0.0.1:8765", configuredHost: "100.1.2.3", configuredPort: 8765))
    }

    @Test func hostHeaderAllowedExactMatch() {
        #expect(MCPServer.hostHeaderAllowed("100.1.2.3:8765", configuredHost: "100.1.2.3", configuredPort: 8765))
    }

    @Test func hostHeaderRejectsOther() {
        #expect(!MCPServer.hostHeaderAllowed("evil.example.com:8765", configuredHost: "127.0.0.1", configuredPort: 8765))
        // Wrong port rejected.
        #expect(!MCPServer.hostHeaderAllowed("127.0.0.1:9999", configuredHost: "127.0.0.1", configuredPort: 8765))
    }

    // MARK: - tokensMatch (constant-time)

    @Test func tokensMatchConstantTime() {
        #expect(MCPServer.tokensMatch("abc123", "abc123"))
        #expect(!MCPServer.tokensMatch("abc123", "abc124"))
        #expect(!MCPServer.tokensMatch("abc", "abcd"))  // length mismatch
        #expect(!MCPServer.tokensMatch("", "x"))
        #expect(MCPServer.tokensMatch("", ""))
    }

    // MARK: - tokenAcceptable (startup token-strength gate)

    @Test func tokenAcceptableLengthFloor() {
        #expect(!MCPServer.tokenAcceptable("short"))
        #expect(!MCPServer.tokenAcceptable(String(repeating: "x", count: MCPServer.minTokenLength - 1)))
        #expect(MCPServer.tokenAcceptable(String(repeating: "x", count: MCPServer.minTokenLength)))
    }

    // MARK: - get_layout split serializer (nodeJSON direction mapping)

    // nodeJSON's .leaf branch and full recursion need a real SurfaceView (a live
    // ghostty surface) which is not constructible in a unit test. The only
    // non-trivial branch logic — the split direction -> string mapping — was
    // extracted into the pure, ViewType-independent `directionString` helper and
    // is asserted here. This is the mapping every .split node in get_layout's tree
    // emits.
    @Test func nodeJSONDirectionString() {
        #expect(MCPLayout.directionString(.horizontal) == "horizontal")
        #expect(MCPLayout.directionString(.vertical) == "vertical")
    }

    // MARK: - tools/call result shaping (toolContent / toolTextContent)

    @Test func toolTextContentShape() {
        let r = MCPServer.toolTextContent("hello", isError: true)
        let content = r["content"] as! [[String: Any]]
        #expect(content.count == 1)
        #expect(content[0]["type"] as? String == "text")
        #expect(content[0]["text"] as? String == "hello")
        #expect(r["isError"] as? Bool == true)
    }

    @Test func toolContentJSONEncodesPayload() {
        let r = MCPServer.toolContent(["ok": true], isError: false)
        #expect(r["isError"] as? Bool == false)
        let content = r["content"] as! [[String: Any]]
        let text = content[0]["text"] as! String
        // The text block is the JSON-encoded payload.
        let decoded = try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        #expect(decoded["ok"] as? Bool == true)
    }

    // MARK: - uuidArg

    @Test func uuidArgValidAndInvalid() {
        let u = UUID()
        #expect(MCPTools.uuidArg(["id": u.uuidString]) == u)
        #expect(MCPTools.uuidArg(["id": "not-a-uuid"]) == nil)
        #expect(MCPTools.uuidArg([:]) == nil)
        #expect(MCPTools.uuidArg(["id": 123]) == nil)  // non-string
    }

    // MARK: - Agent Queue: newDirection (split direction mapping)

    @Test func newDirectionMapping() {
        #expect(MCPLayout.newDirection("right") == .right)
        #expect(MCPLayout.newDirection("left") == .left)
        #expect(MCPLayout.newDirection("down") == .down)
        #expect(MCPLayout.newDirection("up") == .up)
        #expect(MCPLayout.newDirection("diagonal") == nil)
        #expect(MCPLayout.newDirection(nil) == nil)
        #expect(MCPLayout.newDirection("") == nil)
    }

    // MARK: - Agent Queue: QueueCommand value type + jsonObject

    @Test func queueCommandJSONObjectStartCarriesTemplate() {
        let cmd = QueueCommand(action: .start, template: "backlog")
        let d = cmd.jsonObject
        #expect(d["action"] as? String == "start")
        #expect(d["template"] as? String == "backlog")
        // run is nil ⇒ omitted.
        #expect(d["run"] == nil)
    }

    @Test func queueCommandJSONObjectFlagCarriesRun() {
        for (action, expected) in [(QueueCommand.Action.pause, "pause"),
                                   (.resume, "resume"), (.stop, "stop"), (.abort, "abort")] {
            let d = QueueCommand(action: action, run: "my-team backlog").jsonObject
            #expect(d["action"] as? String == expected)
            #expect(d["run"] as? String == "my-team backlog")
            #expect(d["template"] == nil)
        }
    }

    @Test func queueCommandJSONObjectOmitsEmptyStrings() {
        // Empty strings are omitted (mirrors the sidecar's tolerant coerce, which
        // only keeps non-empty strings).
        let d = QueueCommand(action: .start, template: "", run: "").jsonObject
        #expect(d["action"] as? String == "start")
        #expect(d["template"] == nil)
        #expect(d["run"] == nil)
    }

    @Test func queueCommandJSONObjectSetMaxItemsCarriesRunAndValue() {
        // setMaxItems serializes to the snake_case action the sidecar whitelists, and
        // carries the run name + the raw maxItems value string.
        let d = QueueCommand(action: .setMaxItems, run: "ExampleOS", maxItems: "10").jsonObject
        #expect(d["action"] as? String == "set_max_items")
        #expect(d["run"] as? String == "ExampleOS")
        #expect(d["maxItems"] as? String == "10")
        #expect(d["template"] == nil)
        // An empty value is omitted (the sidecar would ignore it anyway).
        let empty = QueueCommand(action: .setMaxItems, run: "Q", maxItems: "").jsonObject
        #expect(empty["maxItems"] == nil)
    }

    @Test func queueCommandJSONObjectSetConcurrencyCarriesRunAndValue() {
        // setConcurrency serializes to the snake_case action the sidecar whitelists, and
        // carries the run name + the raw concurrency value string.
        let d = QueueCommand(action: .setConcurrency, run: "ExampleOS", concurrency: "9").jsonObject
        #expect(d["action"] as? String == "set_concurrency")
        #expect(d["run"] as? String == "ExampleOS")
        #expect(d["concurrency"] as? String == "9")
        #expect(d["template"] == nil)
        #expect(d["maxItems"] == nil)
        // An empty value is omitted (the sidecar would ignore it anyway).
        let empty = QueueCommand(action: .setConcurrency, run: "Q", concurrency: "").jsonObject
        #expect(empty["concurrency"] == nil)
    }

    @Test func queueCommandJSONObjectSetKeepCarriesRunKeyAndBool() {
        // setKeep serializes to the snake_case action the sidecar whitelists, carrying the
        // run name, the work-item key, and the keep verdict as a REAL boolean (a string
        // "true" would be dropped by the sidecar's coerce).
        let on = QueueCommand(action: .setKeep, run: "ExampleOS", key: "EX-1", keep: true).jsonObject
        #expect(on["action"] as? String == "set_keep")
        #expect(on["run"] as? String == "ExampleOS")
        #expect(on["key"] as? String == "EX-1")
        #expect(on["keep"] as? Bool == true)
        #expect(on["template"] == nil)
        // false is still PRESENT (it's a real toggle value, not "absent").
        let off = QueueCommand(action: .setKeep, run: "Q", key: "K-2", keep: false).jsonObject
        #expect(off["keep"] as? Bool == false)
        // An empty key is omitted; a nil keep is omitted.
        let bare = QueueCommand(action: .setKeep, run: "Q", key: "").jsonObject
        #expect(bare["key"] == nil)
        #expect(bare["keep"] == nil)
    }

    @Test func queueCommandReleaseSerializesWithOptionalKey() {
        // (release) release serializes to the lowercase action the sidecar whitelists, carrying
        // the run and — for a SINGLE item — its key.
        let one = QueueCommand(action: .release, run: "ExampleOS", key: "EX-1").jsonObject
        #expect(one["action"] as? String == "release")
        #expect(one["run"] as? String == "ExampleOS")
        #expect(one["key"] as? String == "EX-1")
        #expect(one["keep"] == nil)
        // A bulk release (no key) omits the key — the sidecar treats that as "release all held".
        let all = QueueCommand(action: .release, run: "ExampleOS").jsonObject
        #expect(all["action"] as? String == "release")
        #expect(all["run"] as? String == "ExampleOS")
        #expect(all["key"] == nil)
    }

    // MARK: - Agent Queue: report_queue_status payload parsing (§11 health)

    @Test func queueStatusPayloadParsesFullArgs() {
        let p = QueueStatusPayload.fromArguments([
            "queueName": "ExampleOS", "present": true, "phase": "running",
            "queued": 7, "listOk": true, "active": 2, "dispatched": 2, "maxItems": 3,
            "concurrency": 9,
            "next": [["key": "EX-1", "title": "Fix seed", "url": "https://linear.app/x/EX-1", "hero": true],
                     ["key": "EX-2"]],
            "running": [["key": "EX-9", "title": "Running", "url": "https://linear.app/x/EX-9", "hero": true]],
        ])
        let s = p?.status
        #expect(s?.queueName == "ExampleOS")
        #expect(s?.present == true)
        #expect(s?.phase == "running")
        #expect(s?.queued == 7)
        #expect(s?.active == 2)
        #expect(s?.maxItems == 3)
        #expect(s?.concurrency == 9)
        #expect(s?.next.count == 2)
        #expect(s?.next.first?.key == "EX-1")
        #expect(s?.next.first?.title == "Fix seed")
        #expect(s?.next.first?.url == "https://linear.app/x/EX-1")
        #expect(s?.next.last?.title == nil)
        #expect(s?.next.last?.url == nil)
        #expect(s?.next.first?.hero == true)   // (hero) marked on the waiting dropdown
        #expect(s?.next.last?.hero == false)   // absent hero → false
        #expect(s?.running.first?.key == "EX-9")
        #expect(s?.running.first?.url == "https://linear.app/x/EX-9")
        #expect(s?.running.first?.hero == true) // (hero) marked on the running dropdown
    }

    @Test func queueStatusPayloadParsesHeld() {
        // (release) heldCount is the exact count; held is the (capped) item list.
        let s = QueueStatusPayload.fromArguments([
            "queueName": "ExampleOS",
            "heldCount": 3,
            "held": [["key": "EX-4", "title": "Held", "url": "https://linear.app/x/EX-4", "hero": true],
                     ["key": "EX-5"]],
        ])?.status
        #expect(s?.heldCount == 3)
        #expect(s?.held.count == 2)
        #expect(s?.held.first?.key == "EX-4")
        #expect(s?.held.first?.title == "Held")
        #expect(s?.held.last?.title == nil)
        #expect(s?.held.first?.hero == true)   // (hero) marked on the held dropdown
        #expect(s?.held.last?.hero == false)
    }

    @Test func queueStatusPayloadHeldDefaultsAndCountFallback() {
        // Absent held ⇒ [] and heldCount 0.
        let none = QueueStatusPayload.fromArguments(["queueName": "Q"])?.status
        #expect(none?.held.isEmpty == true)
        #expect(none?.heldCount == 0)
        // heldCount falls back to the held list's length when the sidecar omits the count.
        let fallback = QueueStatusPayload.fromArguments([
            "queueName": "Q", "held": [["key": "A"], ["key": "B"]],
        ])?.status
        #expect(fallback?.heldCount == 2)
    }

    @Test func queueStatusWithHeldDropsReleasedItems() {
        // (release) optimistic-edit helper: withHeld replaces the held set + recomputes the count.
        let s = QueueStatusPayload.fromArguments([
            "queueName": "Q", "heldCount": 2,
            "held": [["key": "A"], ["key": "B"]],
        ])!.status
        let afterOne = s.withHeld(s.held.filter { $0.key != "A" })
        #expect(afterOne.held.map(\.key) == ["B"])
        #expect(afterOne.heldCount == 1)
        let afterAll = s.withHeld([])
        #expect(afterAll.held.isEmpty)
        #expect(afterAll.heldCount == 0)
    }

    @Test func queueStatusPayloadRejectsMissingName() {
        #expect(QueueStatusPayload.fromArguments(["queued": 3]) == nil)
        #expect(QueueStatusPayload.fromArguments(["queueName": "  "]) == nil)
    }

    @Test func queueStatusPayloadDefaultsAndUnlimited() {
        // present defaults true; maxItems absent ⇒ nil (unlimited); next absent ⇒ [].
        let s = QueueStatusPayload.fromArguments(["queueName": "Q"])?.status
        #expect(s?.present == true)
        #expect(s?.maxItems == nil)
        #expect(s?.concurrency == 0) // absent ⇒ 0 (unknown)
        #expect(s?.next.isEmpty == true)
        #expect(s?.running.isEmpty == true)
        // present:false round-trips (the "run gone" report).
        let gone = QueueStatusPayload.fromArguments(["queueName": "Q", "present": false])?.status
        #expect(gone?.present == false)
    }

    // MARK: - Agent Queue: report_queue_graph payload parsing (backlog graph)

    @Test func queueGraphPayloadParsesFullArgs() {
        let p = QueueGraphPayload.fromArguments([
            "queueName": "ExampleOS", "present": true, "backlog": 7,
            "nodes": [
                ["key": "EX-1", "title": "do x", "url": "https://t/EX-1",
                 "state": "In Progress", "stateType": "started", "done": false,
                 "labels": ["Design needed", "Customer"], "blockedBy": ["EX-9"],
                 "priorityLabel": "High", "hero": true],
                ["key": "EX-2", "done": true],
            ],
        ])
        let g = p?.graph
        #expect(g?.queueName == "ExampleOS")
        #expect(g?.present == true)
        #expect(g?.backlog == 7)
        #expect(g?.nodes.count == 2)
        let n = g?.nodes.first
        #expect(n?.key == "EX-1")
        #expect(n?.title == "do x")
        #expect(n?.state == "In Progress")
        #expect(n?.stateType == "started")
        #expect(n?.done == false)
        #expect(n?.labels == ["Design needed", "Customer"])
        #expect(n?.blockedBy == ["EX-9"])
        #expect(n?.priorityLabel == "High")
        #expect(n?.hero == true)
        // Second node: done true, missing arrays default [], no priority mark, hero defaults false.
        #expect(g?.nodes.last?.done == true)
        #expect(g?.nodes.last?.labels.isEmpty == true)
        #expect(g?.nodes.last?.blockedBy.isEmpty == true)
        #expect(g?.nodes.last?.priorityLabel == nil)
        #expect(g?.nodes.last?.hero == false)
    }

    @Test func queueGraphPayloadRejectsMissingNameAndDropsKeylessNodes() {
        #expect(QueueGraphPayload.fromArguments(["backlog": 3]) == nil)
        #expect(QueueGraphPayload.fromArguments(["queueName": "  "]) == nil)
        // A node with no/blank key is dropped (mirrors the sidecar parse).
        let g = QueueGraphPayload.fromArguments([
            "queueName": "Q", "nodes": [["key": ""], ["title": "no key"], ["key": "A-2"]],
        ])?.graph
        #expect(g?.nodes.count == 1)
        #expect(g?.nodes.first?.key == "A-2")
    }

    @Test func queueGraphPayloadDefaultsAndGone() {
        // present defaults true; backlog absent ⇒ 0; nodes absent ⇒ [].
        let g = QueueGraphPayload.fromArguments(["queueName": "Q"])?.graph
        #expect(g?.present == true)
        #expect(g?.backlog == 0)
        #expect(g?.nodes.isEmpty == true)
        // present:false round-trips (the "run gone" graph report).
        let gone = QueueGraphPayload.fromArguments(["queueName": "Q", "present": false])?.graph
        #expect(gone?.present == false)
    }

    // MARK: - Agent Queue: take_queue_commands envelope shaping

    @Test func queueCommandsJSONDataEnvelope() {
        let cmds = [
            QueueCommand(action: .start, template: "backlog"),
            QueueCommand(action: .pause, run: "backlog name"),
        ]
        let env = MCPServer.queueCommandsJSONData(cmds)
        let arr = env["commands"] as! [[String: Any]]
        #expect(arr.count == 2)
        #expect(arr[0]["action"] as? String == "start")
        #expect(arr[0]["template"] as? String == "backlog")
        #expect(arr[1]["action"] as? String == "pause")
        #expect(arr[1]["run"] as? String == "backlog name")
        // The whole envelope round-trips through JSONSerialization (the wire path).
        let data = try! JSONSerialization.data(withJSONObject: env)
        let back = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect((back["commands"] as! [[String: Any]]).count == 2)
    }

    @Test func queueCommandsJSONDataEmpty() {
        let env = MCPServer.queueCommandsJSONData([])
        #expect((env["commands"] as! [[String: Any]]).isEmpty)
    }

    // MARK: - Agent Queue: tool schemas registered

    @Test func agentQueueToolsRegistered() {
        let names = Set(MCPTools.toolSchemas.compactMap { $0["name"] as? String })
        #expect(names.contains("spawn_split_command"))
        #expect(names.contains("force_close_surface"))
        #expect(names.contains("signal_attention"))
        #expect(names.contains("take_queue_commands"))
    }

    // MARK: - Agent Queue: dispatch validation (AppKit-free paths)

    @Test func dispatchSpawnSplitMissingCommand() {
        // command is required; missing ⇒ invalidParams, no main hop.
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        let outcome = MCPTools.dispatch(name: "spawn_split_command", arguments: [:], server: server)
        guard case .invalidParams = outcome else {
            Issue.record("expected invalidParams for missing command")
            return
        }
    }

    @Test func dispatchSpawnSplitNonFirstTabRequiresTarget() {
        // Not firstTab + no targetUUID ⇒ invalidParams (validated before the main hop).
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        let outcome = MCPTools.dispatch(
            name: "spawn_split_command",
            arguments: ["command": "claude", "direction": "right"],
            server: server)
        guard case .invalidParams = outcome else {
            Issue.record("expected invalidParams for missing targetUUID")
            return
        }
    }

    @Test func dispatchSpawnSplitNonFirstTabRequiresDirection() {
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        let outcome = MCPTools.dispatch(
            name: "spawn_split_command",
            arguments: ["command": "claude", "targetUUID": UUID().uuidString, "direction": "sideways"],
            server: server)
        guard case .invalidParams = outcome else {
            Issue.record("expected invalidParams for invalid direction")
            return
        }
    }

    // MARK: - MCP knowledge: tool registration + schemas

    @Test func knowledgeToolsRegistered() {
        let names = Set(MCPTools.toolSchemas.compactMap { $0["name"] as? String })
        #expect(names.contains("get_effective_config"))
        #expect(names.contains("docs_for_feature"))
        #expect(names.contains("describe_config_key"))
        #expect(names.contains("list_config_keys"))
    }

    @Test func describeConfigKeyRequiredKey() {
        let tools = MCPTools.toolSchemas
        let schema = (tools.first { $0["name"] as? String == "describe_config_key" }!["inputSchema"] as! [String: Any])
        #expect((schema["required"] as? [String]) == ["key"])
    }

    @Test func docsForFeatureEnum() {
        let tools = MCPTools.toolSchemas
        let schema = (tools.first { $0["name"] as? String == "docs_for_feature" }!["inputSchema"] as! [String: Any])
        let props = schema["properties"] as! [String: Any]
        let featureEnum = Set(((props["feature"] as! [String: Any])["enum"] as! [String]))
        #expect(featureEnum == ["agent-dashboard", "agent-manager", "agent-queue", "web-monitor", "mcp", "project-selector", "splits", "all"])
    }

    // MARK: - MCP knowledge: describe_config_key dispatch (backed by the C API)

    @Test func dispatchDescribeConfigKeyMissingKeyInvalidParams() {
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        switch MCPTools.dispatch(name: "describe_config_key", arguments: [:], server: server) {
        case .invalidParams: break
        default: Issue.record("expected .invalidParams for missing key")
        }
        // Empty key string also invalid.
        switch MCPTools.dispatch(name: "describe_config_key", arguments: ["key": ""], server: server) {
        case .invalidParams: break
        default: Issue.record("expected .invalidParams for empty key")
        }
    }

    @Test func dispatchDescribeConfigKeyKnownUpstream() {
        // Backed by the Zig ghostty_config_describe_key C export. font-size is a
        // real upstream key with a non-empty doc and forkOnly=false.
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        switch MCPTools.dispatch(name: "describe_config_key", arguments: ["key": "font-size"], server: server) {
        case .ok(let payload):
            #expect(payload["key"] as? String == "font-size")
            #expect(payload["known"] as? Bool == true)
            #expect(payload["forkOnly"] as? Bool == false)
            #expect((payload["doc"] as? String)?.isEmpty == false)
        default:
            Issue.record("expected .ok for known key")
        }
    }

    @Test func dispatchDescribeConfigKeyForkOnly() {
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        switch MCPTools.dispatch(name: "describe_config_key", arguments: ["key": "agent-dashboard"], server: server) {
        case .ok(let payload):
            #expect(payload["known"] as? Bool == true)
            #expect(payload["forkOnly"] as? Bool == true)
        default:
            Issue.record("expected .ok for fork-only key")
        }
    }

    @Test func dispatchDescribeConfigKeyUnknown() {
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        switch MCPTools.dispatch(name: "describe_config_key", arguments: ["key": "not-a-real-key"], server: server) {
        case .ok(let payload):
            #expect(payload["known"] as? Bool == false)
            #expect((payload["doc"] as? String) == "")
        default:
            Issue.record("expected .ok with known=false")
        }
    }

    // MARK: - MCP knowledge: list_config_keys dispatch (backed by the C API)

    @Test func dispatchListConfigKeysAll() {
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        switch MCPTools.dispatch(name: "list_config_keys", arguments: [:], server: server) {
        case .ok(let payload):
            let keys = payload["keys"] as! [[String: Any]]
            #expect(keys.count > 50)  // the full enum is large
            // font-size present, not fork-only.
            #expect(keys.contains { ($0["key"] as? String) == "font-size" && ($0["forkOnly"] as? Bool) == false })
        default:
            Issue.record("expected .ok")
        }
    }

    @Test func dispatchListConfigKeysForkOnlyFilter() {
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        switch MCPTools.dispatch(name: "list_config_keys", arguments: ["forkOnly": true], server: server) {
        case .ok(let payload):
            let keys = payload["keys"] as! [[String: Any]]
            #expect(!keys.isEmpty)
            // Every returned key is fork-only, and agent-dashboard is among them.
            #expect(keys.allSatisfy { ($0["forkOnly"] as? Bool) == true })
            #expect(keys.contains { ($0["key"] as? String) == "agent-dashboard" })
        default:
            Issue.record("expected .ok")
        }
    }

    @Test func dispatchListConfigKeysSubstringFilter() {
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        switch MCPTools.dispatch(name: "list_config_keys", arguments: ["filter": "AGENT"], server: server) {
        case .ok(let payload):
            let keys = payload["keys"] as! [[String: Any]]
            #expect(!keys.isEmpty)
            // Case-insensitive substring: every key contains "agent".
            #expect(keys.allSatisfy { ($0["key"] as? String)?.lowercased().contains("agent") == true })
        default:
            Issue.record("expected .ok")
        }
    }

    @Test func dispatchDocsForFeatureUnknown() {
        let server = MCPServer(listen: "127.0.0.1:8765", token: "")
        switch MCPTools.dispatch(name: "docs_for_feature", arguments: ["feature": "bogus"], server: server) {
        case .invalidParams: break
        default: Issue.record("expected .invalidParams for unknown feature")
        }
    }

    // MARK: - MCP knowledge: pure helpers

    @Test func firstLineExtractsSummary() {
        #expect(Ghostty.Config.firstLine("First line.\nSecond.") == "First line.")
        // Leading blank lines are skipped.
        #expect(Ghostty.Config.firstLine("\n\n  Real summary  \nmore") == "Real summary")
        #expect(Ghostty.Config.firstLine("") == "")
        #expect(Ghostty.Config.firstLine("\n\n") == "")
    }

    @Test func redactHidesSecrets() {
        #expect(MCPKnowledge.redact("supersecret") == "<set>")
        #expect(MCPKnowledge.redact("") == "")
    }

    @Test func describeBellFeaturesListsFlags() {
        var f = Ghostty.Config.BellFeatures()
        #expect(MCPKnowledge.describeBellFeatures(f) == "")
        f.insert(.audio); f.insert(.title)
        // Order follows the declared list (audio before title).
        #expect(MCPKnowledge.describeBellFeatures(f) == "audio,title")
    }

    // MARK: - MCP knowledge: feature status predicates (pure)

    private func pre(
        dashboard: Bool = false, manager: Bool = false, queue: Bool = false,
        mcpListen: String = "", mcpToken: String = "", webMonitor: String = "",
        projects: [String] = [], node: Bool = false, bellFilter: Bool = false
    ) -> MCPKnowledge.Preconditions {
        MCPKnowledge.Preconditions(
            agentDashboard: dashboard, agentManager: manager, agentQueue: queue,
            mcpListen: mcpListen, mcpToken: mcpToken, webMonitorListen: webMonitor,
            projectDirectories: projects, nodeResolvable: node, bellFilter: bellFilter)
    }

    @Test func featureStatusSplitsAlwaysEnabled() {
        let s = MCPKnowledge.status("splits", pre: pre())
        #expect(s.enabled)
        #expect(s.requires.isEmpty)
    }

    @Test func featureStatusAgentDashboardGate() {
        #expect(MCPKnowledge.status("agent-dashboard", pre: pre(dashboard: false)).enabled == false)
        #expect(MCPKnowledge.status("agent-dashboard", pre: pre(dashboard: true)).enabled == true)
    }

    @Test func featureStatusAgentManagerMirrorsSidecarGate() {
        // OFF: flag off ⇒ disabled, lists every unmet requirement.
        let off = MCPKnowledge.status("agent-manager", pre: pre())
        #expect(off.enabled == false)
        #expect(off.requires.contains("agent-manager = true"))
        #expect(off.requires.contains("mcp-listen set"))
        #expect(off.requires.contains("mcp-token set"))
        #expect(off.requires.contains { $0.contains("node") })
        // ON: flag on AND mcp-listen+token AND node ⇒ enabled, no unmet reqs.
        let on = MCPKnowledge.status(
            "agent-manager",
            pre: pre(manager: true, mcpListen: "127.0.0.1:8765", mcpToken: "x", node: true))
        #expect(on.enabled == true)
        #expect(on.requires.isEmpty)
        // Missing only node ⇒ still disabled with just that requirement.
        let noNode = MCPKnowledge.status(
            "agent-manager",
            pre: pre(manager: true, mcpListen: "127.0.0.1:8765", mcpToken: "x", node: false))
        #expect(noNode.enabled == false)
        #expect(noNode.requires.count == 1)
        #expect(noNode.requires.first?.contains("node") == true)
    }

    @Test func featureStatusMcpAndWebMonitorAndProjects() {
        // mcp: only mcp-listen required (token optional — server runs open).
        #expect(MCPKnowledge.status("mcp", pre: pre()).enabled == false)
        #expect(MCPKnowledge.status("mcp", pre: pre(mcpListen: "127.0.0.1:8765")).enabled == true)
        // web-monitor: listen required.
        #expect(MCPKnowledge.status("web-monitor", pre: pre()).enabled == false)
        #expect(MCPKnowledge.status("web-monitor", pre: pre(webMonitor: "1.2.3.4:8787")).enabled == true)
        // project-selector: at least one base dir.
        #expect(MCPKnowledge.status("project-selector", pre: pre()).enabled == false)
        #expect(MCPKnowledge.status("project-selector", pre: pre(projects: ["~/git"])).enabled == true)
    }

    @Test func featureDocCarriesStaticFacts() {
        let d = MCPKnowledge.featureDoc("agent-queue", pre: pre())!
        #expect(d.name == "Agent Queue Supervisor")
        #expect(d.docPath == "AGENT-QUEUE.md")
        #expect(d.configKeys.contains("agent-queue"))
        #expect(!d.enableSteps.isEmpty)
        // Unknown feature id ⇒ nil.
        #expect(MCPKnowledge.featureDoc("nope", pre: pre()) == nil)
    }

    // The bell/attention subsystem is discoverable and its status reflects the loud-tier
    // (promotion) sidecar dependency without gating the always-on tier-1 effects.
    @Test func featureStatusBellPromotionArm() {
        // Tier-1 always enabled; nothing required when bell-filter (promotion) is off.
        let off = MCPKnowledge.status("bell", pre: pre())
        #expect(off.enabled == true)
        #expect(off.requires.isEmpty)
        // With promotion armed but the sidecar unconfigured, it stays enabled (base bell)
        // yet lists what promotion needs.
        let armed = MCPKnowledge.status("bell", pre: pre(bellFilter: true))
        #expect(armed.enabled == true)
        #expect(armed.requires.contains { $0.contains("mcp-listen") })
        #expect(armed.requires.contains { $0.contains("mcp-token") })
        #expect(armed.requires.contains { $0.contains("node") })
        // Fully configured promotion ⇒ no unmet requirements.
        let ready = MCPKnowledge.status(
            "bell", pre: pre(mcpListen: "127.0.0.1:8765", mcpToken: "x", node: true, bellFilter: true))
        #expect(ready.requires.isEmpty)
        // The FeatureDoc exists and points at the bell doc.
        let d = MCPKnowledge.featureDoc("bell", pre: pre())!
        #expect(d.docPath == "BELL-ATTENTION.md")
        #expect(d.configKeys.contains("bell-features"))
        #expect(d.configKeys.contains("agent-manager-bell-filter"))
    }

    // GUARD (mirrors readersIncludeAllForkOnlyKeys for docs_for_feature): every fork-only
    // config key must be listed in SOME feature's configKeys, so a user asking
    // docs_for_feature can always find the feature a fork key belongs to. This is the drift
    // check that would have caught agent-queue-hero-max / agent-dashboard-spotlight-seconds /
    // agent-manager-usage-tracking|warm-base slipping out of the FeatureDoc table.
    @Test func featureDocsCoverAllForkOnlyKeys() {
        let p = pre()
        var covered = Set<String>()
        for id in MCPKnowledge.featureIDs {
            if let doc = MCPKnowledge.featureDoc(id, pre: p) { covered.formUnion(doc.configKeys) }
        }
        // Infrastructure keys that are NOT a per-feature knob (the backend socket), so they
        // legitimately live in no feature's configKeys.
        let infra: Set<String> = ["pty-host"]
        let forkKeys = Ghostty.Config.allConfigKeys().filter { $0.forkOnly }.map { $0.key }
        for key in forkKeys where !infra.contains(key) {
            #expect(covered.contains(key), "no docs_for_feature lists fork-only key: \(key)")
        }
    }

    // MARK: - MCP knowledge: get_effective_config entry computation (pure)

    @Test func entriesChangedOnlyFiltersDefaults() {
        // entries() is pure over two configs; construct a default config twice so
        // every reader sees identical values ⇒ all isDefault ⇒ changedOnly empties.
        let defaults = Ghostty.Config.defaultConfig()
        let live = Ghostty.Config.defaultConfig()
        let changed = MCPKnowledge.entries(live: live, defaults: defaults, changedOnly: true, keys: nil)
        #expect(changed.isEmpty)
        // changedOnly:false returns the full curated set, all isDefault=true.
        let all = MCPKnowledge.entries(live: live, defaults: defaults, changedOnly: false, keys: nil)
        #expect(all.count == MCPKnowledge.readers.count)
        #expect(all.allSatisfy { $0.isDefault })
        // keys restriction narrows the set.
        let one = MCPKnowledge.entries(
            live: live, defaults: defaults, changedOnly: false, keys: ["agent-dashboard"])
        #expect(one.count == 1)
        #expect(one.first?.key == "agent-dashboard")
    }

    @Test func readersIncludeAllForkOnlyKeys() {
        // The curated reader set MUST cover every fork-only key (the whole point of
        // the discovery tool). Cross-check against the C-API fork-only list.
        let readerKeys = Set(MCPKnowledge.readers.map { $0.key })
        let forkKeys = Ghostty.Config.allConfigKeys().filter { $0.forkOnly }.map { $0.key }
        for key in forkKeys {
            #expect(readerKeys.contains(key), "reader missing fork-only key: \(key)")
        }
    }
}

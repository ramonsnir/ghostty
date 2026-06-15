// (ramon fork) MCP JSON-RPC 2.0 layer. PURE parse + envelope construction
// (unit-tested), plus the request dispatch that hops to main for effects.
//
// Lives on `MCPServer` as an extension so it can reach `send`, `queue`, `bus`,
// and the parked-connection machinery.

import Foundation
import Network
import os

extension MCPServer {
    enum RPCParseResult {
        case parseError                                              // body not JSON          -> -32700, id: null
        case invalid                                                 // JSON but not a Request -> -32600, id: null
        case notification(method: String, params: [String: Any])    // no "id"
        case request(id: Any, method: String, params: [String: Any]) // id: String | NSNumber | NSNull
    }

    /// PURE: parse a request body into a JSON-RPC result. Unit-tested.
    static func parseRPC(_ body: Data) -> RPCParseResult {
        guard let obj = try? JSONSerialization.jsonObject(with: body) else {
            return .parseError
        }
        guard let dict = obj as? [String: Any] else {
            // Valid JSON but not an object (e.g. an array/number). Not a single
            // Request; treat as invalid. (Batches are not supported in v1.)
            return .invalid
        }
        // A JSON-RPC 2.0 Request MUST carry a string "method". We do not hard-fail
        // on a missing/wrong "jsonrpc" version (lenient), but a missing method is
        // not a Request.
        guard let method = dict["method"] as? String, !method.isEmpty else {
            return .invalid
        }
        let params = (dict["params"] as? [String: Any]) ?? [:]
        // "id" present (even null) -> a request; absent -> a notification. We echo
        // the id back by TYPE verbatim (String | NSNumber | NSNull), never coerced.
        guard dict.keys.contains("id") else {
            return .notification(method: method, params: params)
        }
        let id = dict["id"] ?? NSNull()
        return .request(id: id, method: method, params: params)
    }

    /// PURE: a successful JSON-RPC envelope. The `id` is placed straight into the
    /// dict (echoed by type). Unit-tested.
    static func resultEnvelope(id: Any, result: Any) -> Data {
        let env: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        return (try? JSONSerialization.data(withJSONObject: env))
            ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)
    }

    /// PURE: an error JSON-RPC envelope. Unit-tested.
    static func errorEnvelope(id: Any, code: Int, message: String, data: Any? = nil) -> Data {
        var err: [String: Any] = ["code": code, "message": message]
        if let data { err["data"] = data }
        let env: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": err]
        return (try? JSONSerialization.data(withJSONObject: env))
            ?? Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8)
    }

    /// Dispatch a single JSON-RPC request body. Runs on the server serial queue.
    func handleRPC(_ body: Data, on conn: NWConnection) {
        switch Self.parseRPC(body) {
        case .parseError:
            send(.json(Self.errorEnvelope(id: NSNull(), code: -32700, message: "Parse error")), on: conn)

        case .invalid:
            // Per JSON-RPC 2.0 we reply with id: null for an invalid envelope; we
            // deliberately do NOT reflect any attacker-shaped id.
            send(.json(Self.errorEnvelope(id: NSNull(), code: -32600, message: "Invalid Request")), on: conn)

        case .notification:
            // No envelope. Empty body so the shim emits nothing on stdout.
            send(.empty(202, "Accepted"), on: conn)

        case .request(let id, let method, let params):
            dispatchRequest(id: id, method: method, params: params, on: conn)
        }
    }

    private func dispatchRequest(id: Any, method: String, params: [String: Any], on conn: NWConnection) {
        switch method {
        case "initialize":
            send(.json(Self.resultEnvelope(id: id, result: Self.initializeResult)), on: conn)

        case "tools/list":
            send(.json(Self.resultEnvelope(id: id, result: MCPTools.toolsListResult)), on: conn)

        case "tools/call":
            guard let name = params["name"] as? String else {
                send(.json(Self.errorEnvelope(
                    id: id, code: -32602, message: "Invalid params", data: "missing tool name")), on: conn)
                return
            }
            let arguments = (params["arguments"] as? [String: Any]) ?? [:]
            let outcome = MCPTools.dispatch(name: name, arguments: arguments, server: self)
            switch outcome {
            case .ok(let payload):
                send(.json(Self.resultEnvelope(id: id, result: Self.toolContent(payload, isError: false))), on: conn)
            case .toolError(let msg):
                send(.json(Self.resultEnvelope(id: id, result: Self.toolTextContent(msg, isError: true))), on: conn)
            case .methodNotFound:
                send(.json(Self.errorEnvelope(
                    id: id, code: -32601, message: "Method not found", data: "unknown tool: \(name)")), on: conn)
            case .invalidParams(let reason):
                send(.json(Self.errorEnvelope(
                    id: id, code: -32602, message: "Invalid params", data: reason)), on: conn)
            case .waitForEvent(let spec):
                // PARK the connection: do not send synchronously. The bus resolves
                // it (with an event or a timeout) off the serial queue, exempt from
                // the idle watchdog.
                cancelConnectionTimer(ObjectIdentifier(conn))
                bus.register(spec: spec, conn: conn, rpcId: id, server: self)
            case .watchPattern(let spec):
                cancelConnectionTimer(ObjectIdentifier(conn))
                bus.registerPattern(spec: spec, conn: conn, rpcId: id, server: self)
            }

        case "notifications/initialized":
            // Some clients send initialized as a request; answer harmlessly.
            send(.json(Self.resultEnvelope(id: id, result: [String: Any]())), on: conn)

        default:
            send(.json(Self.errorEnvelope(
                id: id, code: -32601, message: "Method not found", data: method)), on: conn)
        }
    }

    // MARK: - initialize result (pure, testable)

    static let initializeResult: [String: Any] = [
        "protocolVersion": "2024-11-05",
        "capabilities": ["tools": ["listChanged": false]],
        "serverInfo": ["name": "ghostty-mcp", "version": "0.1.0"],
    ]

    // MARK: - tools/call result shaping (pure, testable)

    /// Shape a structured payload into the MCP `tools/call` result: a single text
    /// content block whose `text` is the JSON-encoded payload.
    static func toolContent(_ payload: [String: Any], isError: Bool) -> [String: Any] {
        let json = (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return toolTextContent(json, isError: isError)
    }

    /// Shape a plain string into the MCP `tools/call` result text content block.
    static func toolTextContent(_ text: String, isError: Bool) -> [String: Any] {
        return [
            "content": [["type": "text", "text": text]],
            "isError": isError,
        ]
    }
}

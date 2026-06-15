// (ramon fork) ghostty-mcp: a dumb stdio<->HTTP pipe so `claude mcp add ghostty
// -- ghostty-mcp` works against the in-GUI MCP server. It reads newline-delimited
// JSON-RPC from stdin, POSTs each line to the in-GUI server's `POST /mcp`, and
// writes the response back to stdout. ALL logic lives server-side; this shim
// rarely changes.
//
// Config (env):
//   GHOSTTY_MCP_URL    server URL (default http://127.0.0.1:8765/mcp)
//   GHOSTTY_MCP_TOKEN  shared secret (optional; sent as X-Ghostty-Token)
//
// Built with `swift build` (NOT part of Ghostty.xcodeproj). Foundation only,
// single-threaded / synchronous.

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

let env = ProcessInfo.processInfo.environment
let urlString = env["GHOSTTY_MCP_URL"] ?? "http://127.0.0.1:8765/mcp"
let token = env["GHOSTTY_MCP_TOKEN"]

guard let serverURL = URL(string: urlString) else {
    FileHandle.standardError.write(Data("ghostty-mcp: invalid GHOSTTY_MCP_URL: \(urlString)\n".utf8))
    exit(2)
}

let session = URLSession(configuration: .ephemeral)
let stdout = FileHandle.standardOutput

/// Best-effort: pull the JSON-RPC `id` from a request line so a transport error
/// can be reported under the same id (null if unparseable).
func requestId(from line: Data) -> Any {
    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
          let id = obj["id"] else { return NSNull() }
    return id
}

/// Write a JSON object + newline to stdout and flush.
func emit(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    stdout.write(data)
    stdout.write(Data("\n".utf8))
}

/// Forward one JSON-RPC line to the server, relaying any response to stdout.
func forward(_ line: Data) {
    var req = URLRequest(url: serverURL)
    req.httpMethod = "POST"
    // URLSession defaults to a 60s request timeout, but wait_for_event /
    // watch_for_pattern legitimately park for up to the server's 120s ceiling
    // (MCPEventBus.timeoutCeilingMs). Use 180s here so the shim NEVER fires a
    // transport timeout (and emit a spurious -32000 'unreachable') while the
    // server still holds the waiter parked. Must stay strictly ABOVE the server
    // ceiling, with headroom for the response write.
    req.timeoutInterval = 180
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let token, !token.isEmpty {
        req.setValue(token, forHTTPHeaderField: "X-Ghostty-Token")
    }
    req.httpBody = line

    let sem = DispatchSemaphore(value: 0)
    var respData: Data?
    var respStatus = 0
    var transportError: Error?

    let task = session.dataTask(with: req) { data, response, error in
        respData = data
        if let http = response as? HTTPURLResponse { respStatus = http.statusCode }
        transportError = error
        sem.signal()
    }
    task.resume()
    sem.wait()

    if transportError != nil {
        // Structured failure so the agent sees an error, not a hang.
        emit([
            "jsonrpc": "2.0",
            "id": requestId(from: line),
            "error": ["code": -32000, "message": "ghostty MCP server unreachable"],
        ])
        return
    }

    // A notification produces a 202/204 OR an empty body — write nothing.
    let body = respData ?? Data()
    if respStatus == 202 || respStatus == 204 || body.isEmpty {
        return
    }

    stdout.write(body)
    stdout.write(Data("\n".utf8))
}

// MARK: - stdin line reader (newline-delimited JSON framing)

var buffer = Data()
let newline = UInt8(0x0a)

while true {
    let chunk = FileHandle.standardInput.availableData
    if chunk.isEmpty {
        // EOF: flush any trailing line (no newline) then exit.
        if !buffer.isEmpty {
            let trimmed = buffer
            if !trimmed.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0d }) {
                forward(trimmed)
            }
        }
        break
    }
    buffer.append(chunk)

    while let idx = buffer.firstIndex(of: newline) {
        let lineData = buffer.subdata(in: buffer.startIndex..<idx)
        buffer.removeSubrange(buffer.startIndex...idx)
        // Skip blank lines.
        if lineData.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0d }) { continue }
        forward(lineData)
    }
}

exit(0)

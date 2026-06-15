# Ghostty (fork) MCP server — implementation-ready design

Status: implementation-ready. This doc is the complete spec; the implementer follows it with
no further questions. The plan at `/Users/ramon/git/ghostty/.claude/plans/mcp-server.md` holds
the rationale, this doc holds the exact shapes. All paths are absolute under the worktree
`/Users/ramon/git/ghostty-mcp-server` (where ALL writes go).

Hard constraints (restated, binding):

- **Do NOT touch the web monitor** (`macos/Sources/Features/WebMonitor/*`). COPY patterns into
  the new MCP module; never import/extend it.
- **No host/emulation changes.** No edits to `src/host/*` or `src/termio/Client.zig`. The ONLY
  Zig change is the two additive config keys in `src/config/Config.zig` + their parse test.
- Fork-only, default off. Mirror the web-monitor null-default discipline.
- New Swift module: `macos/Sources/Features/MCP/`. stdio shim: SEPARATE SPM package in
  `macos/mcp-shim/` (NOT wired into `Ghostty.xcodeproj`).

---

## 0. Source-of-truth citations (verified against the worktree at HEAD `6497b5451`)

The implementer COPIES these and must not re-derive them. Line numbers are from
`macos/Sources/Features/WebMonitor/WebMonitorServer.swift` (abbrev. WM) unless noted:

| What | Location | Note |
|---|---|---|
| `KeySpec` struct + `send`/`sendOne` | WM **862–920** | Copy verbatim. |
| `keySpecs(forKey:)` | WM **952–974** | Copy verbatim; add `escape` alias (§5). |
| `keySpecs(forText:)` | WM **985–1017** | Copy verbatim (run-coalescing + Return). |
| (do NOT copy) `keySpecs(body:contentType:)` | WM **930** | HTTP-body parser — replaced by typed args. |
| (do NOT copy) `scrollDeltaY(body:)` | WM **943** | HTTP-body parser — replaced by `scrollDeltaClamped` (§1.5). |
| `parseListen` | WM **262–273** | Copy verbatim. |
| `hostHeaderAllowed` | WM **831–851** | Copy verbatim. |
| `RequestParser` (`Request`, `Result`, `parse`) | WM **1167–1271** | Copy verbatim. |
| `HTTPResponse` enum + `send(_:on:)` | WM **1275–1334** | Copy, then **ADD `.empty` case** (§1.1). |
| `tokensMatch` (constant-time) | WM **1149–1158** | Copy verbatim. |
| `tokenAcceptable` / `minTokenLength` | WM **1137–1145** | Copy verbatim (soft warning). |
| `surface(forUUID:)` (main → view) | WM **1022** | Copy. |
| `controllerAndView(forUUID:)` (main) | WM **1029** | Copy; private instance → static internal (no instance state). |
| `revealIfZoomedAway` | WM **1048+** | Copy; used before send_key/scroll/perform_action. |
| `handle()`, cap, timers, backoff, `remoteIP` | WM **277+** | Copy threading/security scaffolding. |
| `decideRoute` shape (PURE) | WM **476–549** | Adapt to MCP route set (§4). |
| `SurfaceRow` value type | WM **1059** | Copy + add `focused`/`exited`/`atPrompt` (§1.4). |
| `surfacesJSON()` window/tab index loop | WM **1083–1117** | Reuse; window/tab ints are POSITIONAL (§1.4). |

> The two finder funcs are transposed relative to an earlier draft: `surface(forUUID:)` is at
> WM **1022**, `controllerAndView(forUUID:)` at WM **1029**. Both are pure AppKit walks over
> `TerminalController.all` with no instance state, so promoting them to `static internal func`
> for the MCP module is mechanical.

C API (verified in `include/ghostty.h`):

- `ghostty_surface_read_text(ghostty_surface_t, ghostty_selection_s, ghostty_text_s*) -> bool`
  (1213) + `ghostty_surface_free_text` (1216). The exact viewport vs screen `ghostty_selection_s`
  is in `SurfaceView_AppKit.swift` 248–287 (`GHOSTTY_POINT_VIEWPORT` / `GHOSTTY_POINT_SCREEN` +
  TOP_LEFT/BOTTOM_RIGHT). Copy that.
- `ghostty_surface_key(ghostty_surface_t, ghostty_input_key_s) -> bool` (1177).
- `ghostty_surface_mouse_scroll(ghostty_surface_t, double, double, ghostty_input_scroll_mods_t)`
  (1192).
- `ghostty_surface_needs_confirm_quit(ghostty_surface_t) -> bool` (1161).
- `ghostty_surface_process_exited(ghostty_surface_t) -> bool` (1163).
- `ghostty_surface_size(ghostty_surface_t) -> ghostty_surface_size_s` (1170) — cols/rows.
- `ghostty_surface_request_close(ghostty_surface_t)` (1198).
- `ghostty_surface_binding_action(ghostty_surface_t, const char*, uintptr_t) -> bool` (1206) —
  the keybind-action grammar runner; **this is how `perform_action` is implemented** (the fork
  verbs `flip_split`, `swap_split`, `pull_marked_split`, `merge_tabs`, etc. are all reachable,
  mode-correct, focus-relative). Swift convenience wrapper exists:
  `Ghostty.Surface.perform(action:) -> Bool` (`Ghostty.Surface.swift` 165).

Swift accessors (public on `Ghostty.SurfaceView`): `.id: UUID`, `.title: String`, `.pwd: String?`,
`.bell: Bool`, `.processExited: Bool` (143), `.needsConfirmQuit: Bool` (137),
`.cachedVisibleContents.get()` / `.cachedScreenContents.get()` (217–218), `.surface:
ghostty_surface_t?`. Bell: `Notification.Name.ghosttyBellDidRing` (`GhosttyPackage.swift` 361),
posted with `object: surfaceView` (`Ghostty.App.swift` 1259–1262). New-tab:
`Notification.ghosttyNewTab` (`GhosttyPackage.swift` 404), userInfo key
`Notification.NewSurfaceConfigKey` carrying a `SurfaceConfiguration` with `.workingDirectory` +
`.initialInput` (`Ghostty.App.swift` 909–949). Focus:
`BaseTerminalController.focusSurface(_:)` (320).

---

## 1. New files & responsibilities

All new Swift files live in `macos/Sources/Features/MCP/`, picked up by the filesystem-synchronized
Sources group (no manual `PBXBuildFile`); they only need the iOS exclusion (§11).

### 1.1 `MCPServer.swift`

`final class MCPServer` — owns the `NWListener`, the dedicated serial queue, connection
bookkeeping/timers, the token, and the JSON-RPC entrypoint. Mirrors `WebMonitorServer`'s threading
and security scaffolding.

Copied (renamed where the type is `WebMonitorServer.X`): `parseListen`, `RequestParser`,
`HTTPResponse`, `send(_:on:)`, `tokensMatch`, `tokenAcceptable`/`minTokenLength`,
`hostHeaderAllowed`, the connection-cap + idle/absolute-deadline timer machinery, `remoteIP(of:)`,
the per-peer failed-token backoff (`failedAuthThreshold`, `clearAuthFailures`, the backoff map).

**REQUIRED ADDITION to the copied `HTTPResponse` enum (fixes the prior blocker).** The verbatim
`.status(Int, String)` case emits a NON-empty body (`Data("\(c) \(r)".utf8)`, e.g. `"202 Accepted"`
with `Content-Length: 12` — WM 1310). A JSON-RPC *notification* (a request with no `id`) MUST
produce NO response payload, and the stdio shim must not emit a stray non-JSON line on stdout. Add
an empty-body case:

```swift
enum HTTPResponse {
    case html(String)
    case text(String)
    case json(Data)
    case asset(Data, String)
    case status(Int, String)
    case empty(Int, String)          // ADDED: status line only, body = Data()

    var statusCode: Int { switch self { /* … */ case .empty(let c, _): return c; /* … */ } }
    var reason: String  { switch self { /* … */ case .empty(_, let r): return r; /* … */ } }
    var contentType: String { switch self { /* … */ case .empty: return "text/plain; charset=utf-8"; /* … */ } }
    var body: Data {
        switch self {
        // …
        case .status(let c, let r): return Data("\(c) \(r)".utf8)
        case .empty: return Data()   // EXPLICITLY empty (Content-Length: 0)
        }
    }
}
```

Notifications are answered with `send(.empty(202, "Accepted"), on: conn)` → `Content-Length: 0`,
empty body. The shim (§9) treats status 202/204 **and** an empty/zero-length body as "no payload";
both conditions hold here so there is no contradiction. As written, `.status(...)` would inject a
`"202 Accepted"` line into the stdio JSON stream — `.empty(...)` is what prevents that.

Server methods:

```swift
init(listen: String, token: String)
func start()   // parseListen → NWListener on serial queue; logs a warning if token weak/empty (does NOT refuse)
func stop()    // queue.async teardown (never queue.sync from main)

private func handle(_ conn: NWConnection)            // copied: cap, timers, accumulate, parse
private func routeRequest(_ req: RequestParser.Request, on conn: NWConnection)  // thin shell (§4)
```

`routeRequest` computes `decideRoute(...)` (§4, PURE), performs failure-count mutation, and for
`.mcp` hands the body to `handleRPC` (§1.2). It is the ONLY place that touches the socket/backoff.

### 1.2 `MCPRPC.swift`

The JSON-RPC 2.0 layer: PURE parse + envelope construction (unit-tested), plus the request dispatch
that hops to main for effects.

```swift
enum RPCParseResult {
    case parseError                                       // body not JSON          → -32700, id: null
    case invalid                                          // JSON but not a Request → -32600, id: null
    case notification(method: String, params: [String: Any])      // no "id"
    case request(id: Any, method: String, params: [String: Any])  // id raw: String|NSNumber|NSNull
}

static func parseRPC(_ body: Data) -> RPCParseResult
static func resultEnvelope(id: Any, result: Any) -> Data
static func errorEnvelope(id: Any, code: Int, message: String, data: Any? = nil) -> Data
```

**Echoed `id` rules (JSON-RPC 2.0; fixes the prior major).** `id` is echoed back by TYPE verbatim —
a JSON string echoes as a string, a number as a number, `null` as `null`. It is stored as `Any`
(`String | NSNumber | NSNull`) and placed straight into the envelope dict before
`JSONSerialization` — never coerced to a string. Concretely:

- `.parseError` → `errorEnvelope(id: NSNull(), code: -32700, message: "Parse error")`. **id MUST be `null`.**
- `.invalid` → `errorEnvelope(id: NSNull(), code: -32600, message: "Invalid Request")`. **id MUST be
  `null`** even if a malformed object happened to carry an `id` (we do not reflect attacker-shaped
  ids from an invalid envelope; `null` is conformant).
- `.notification` → NO envelope; `send(.empty(202,"Accepted"))`.
- `.request` unknown method → `errorEnvelope(id: <echoed>, code: -32601, message: "Method not found")`.
- `.request` bad params → `errorEnvelope(id: <echoed>, code: -32602, message: "Invalid params",
  data: <reason>)`.
- A tool handler's application error → a *successful* JSON-RPC envelope whose `result` carries
  `isError: true` (MCP tool-error convention, §3.3), NOT a JSON-RPC `error`.

Envelope shapes: `{"jsonrpc":"2.0","id":<id>,"result":<result>}` and
`{"jsonrpc":"2.0","id":<id>,"error":{"code":<int>,"message":<string>[,"data":<any>]}}`.

`handleRPC(_ body: Data, on conn:)`:
1. `parseRPC` → switch.
2. notification → `send(.empty(202,"Accepted"))`.
3. parseError/invalid → `send(.json(errorEnvelope(id: NSNull(), …)))`.
4. request → dispatch on `method`: `initialize`, `tools/list`, `tools/call`. For `tools/call`,
   `wait_for_event`/`watch_for_pattern` PARK the connection (do not `send` synchronously — §6);
   every other call computes the result (hopping to main as needed) and
   `send(.json(resultEnvelope(...)))`.

### 1.3 `MCPTools.swift`

Tool registry + JSON schemas + dispatch table (§3).

```swift
static let toolsListResult: [String: Any]     // {"tools":[ {name,description,inputSchema}, … ]}
static func dispatch(name: String, arguments: [String: Any], server: MCPServer) -> ToolOutcome
enum ToolOutcome { case ok([String: Any]); case toolError(String); case waitForEvent(WaitSpec) }
```

`toolsListResult` is built once (schemas in §3.2). `dispatch` is the §3.3 table; it calls
`MCPLayout`/`MCPInput`/`MCPEventBus`. `wait_for_event`/`watch_for_pattern` return `.waitForEvent`
(not resolved) so `handleRPC` can park the connection.

### 1.4 `MCPLayout.swift`

`enum MCPLayout` (no instance state). Read/control verbs against
`TerminalController`/`SplitTree`/the C API. Every AppKit/surface-touching func is called inside
`DispatchQueue.main.sync` from the dispatch and returns **only value types** across the hop.

```swift
// All MUST be called on main; return value types only.
static func surface(forUUID: UUID) -> Ghostty.SurfaceView?                  // copied WM 1022
static func controllerAndView(forUUID: UUID)
    -> (controller: TerminalController, view: Ghostty.SurfaceView)?         // copied WM 1029
static func revealIfZoomedAway(_ c: TerminalController, _ v: Ghostty.SurfaceView)  // copied WM 1048

static func surfaceRows() -> [SurfaceRow]                       // list_surfaces source (main)
static func surfacesJSONData(_ rows: [SurfaceRow]) -> [[String: Any]]   // PURE (testable)
static func readText(uuid: UUID, scrollback: Bool) -> (text: String, cols: Int, rows: Int)?  // main
static func layoutTree() -> [[String: Any]]                     // get_layout windows→tabs→tree (main)
static func focus(uuid: UUID) -> Bool                           // main → focusSurface
static func close(uuid: UUID) -> Bool                           // main → ghostty_surface_request_close
static func newTab(cwd: String?, command: String?, sourceUUID: UUID?) -> Bool   // main → ghosttyNewTab
static func performAction(uuid: UUID, action: String) -> Bool   // main → focus + ghostty_surface_binding_action
```

`SurfaceRow` (copy WM 1059, add three fields):

```swift
struct SurfaceRow {
    let id: String; let title: String; let pwd: String
    let window: Int; let tab: Int; let tabTitle: String
    let splitIndex: Int; let splitCount: Int
    let focused: Bool; let bell: Bool; let exited: Bool; let atPrompt: Bool
}
```

**`window`/`tab` (and `get_layout`'s window/tab ids) are POSITIONAL, NOT stable.** They are 1-pass
encounter-order indices over `TerminalController.all` / the tab group's `windows` (exactly the
`surfacesJSON` loop at WM 1083–1117). They can change between calls as windows/tabs open and close;
the ONLY durable address is the surface `id` (UUID). The schemas (§3.2) say this explicitly.

`focused`: `view == view.window?.firstResponder`-ish — use the existing `SurfaceView.focused`
property if present, else `Ghostty.App`'s global current-surface ref. `exited`:
`view.processExited`. `atPrompt`: `!view.needsConfirmQuit` (heuristic, §8).

### 1.5 `MCPInput.swift`

`enum MCPInput`. Copied `KeySpec` + `keySpecs(forKey:)`/`keySpecs(forText:)` (WM 862–920, 952–974,
985–1017) + injection helpers. Do NOT copy `keySpecs(body:contentType:)` (WM 930) or `scrollDeltaY`
(WM 943) — those parse HTTP bodies; the MCP layer hands typed args.

```swift
struct KeySpec: Equatable { … }                       // copied WM 862
static func keySpecs(forKey: String) -> [KeySpec]?     // copied WM 952 (+ "escape" alias, §5)
static func keySpecs(forText: String) -> [KeySpec]     // copied WM 985

// PURE (testable), replaces scrollDeltaY's parsing half:
static func scrollDeltaClamped(_ dy: Double) -> Double?   // nil if 0; else max(-30, min(30, dy))

// main-thread injectors (inside DispatchQueue.main.sync):
static func sendText(uuid: UUID, text: String, submit: Bool) -> Bool
static func sendKey(uuid: UUID, key: String) -> Bool
static func scroll(uuid: UUID, dy: Double) -> Bool
```

**Scroll sign (resolves the prior minor).** WM passes its clamped `dy` DIRECTLY to
`ghostty_surface_mouse_scroll(surface, 0, dy, 0)` with NO negation (WM 680), doc "positive =
scroll back/up". `scrollDeltaClamped` preserves that sign and the MCP injector likewise passes it
directly: `ghostty_surface_mouse_scroll(surface, 0, dy, 0)`. So the tool's advertised "positive dy
= scroll back/up" matches the C call with no inversion. `scrollDeltaClamped(0) == nil` (no-op → tool
error); else clamps to `[-30, 30]`.

`sendText` builds `keySpecs(forText: text)`, then if `submit` appends one `KeySpec(keycode: 36)`
(native Return); `revealIfZoomedAway` first; each spec `.send(to:)` on main. `sendKey` builds
`keySpecs(forKey: key)` (nil → tool error "unknown key"); `revealIfZoomedAway` first.

### 1.6 `MCPEventBus.swift`

`final class MCPEventBus` — the bell/exited/prompt event source + `wait_for_event` waiter registry.
Full contract in §6 (highest-risk piece).

### 1.7 `macos/Sources/Ghostty/Ghostty.Config.swift` — getters (§2.3).
### 1.8 `macos/Sources/App/macOS/AppDelegate.swift` — start/stop (§7).
### 1.9 `src/config/Config.zig` — two keys + parse test (§2.1, §2.2).
### 1.10 `macos/Ghostty.xcodeproj/project.pbxproj` — iOS exclusion (§11).
### 1.11 `macos/Tests/MCP/MCPServerTests.swift` — tests (§10).
### 1.12 `macos/mcp-shim/Package.swift` + `Sources/ghostty-mcp/main.swift` (§9).

---

## 2. Config keys & getters (exact)

### 2.1 `src/config/Config.zig` — field declarations

Add immediately AFTER the existing `@"web-monitor-token"` decl (currently line 3186), keeping the
same `?[:0]const u8 = null` shape so `ghostty_config_get` can return a C string:

```zig
/// (ramon fork) Listen address (`addr:port`) for the embedded MCP server, an
/// in-app HTTP server that lets an orchestrating agent (e.g. Claude Code via the
/// `ghostty-mcp` stdio shim) read live terminal surfaces and control splits/tabs.
/// Empty/null (the default) DISABLES the server entirely. This is a BIND address
/// (which port/interface to listen on), NOT an access-control allowlist:
/// `NWListener` binds the PORT on all interfaces regardless of the host you give,
/// so the host here does not filter who can connect. Bind localhost (e.g.
/// `127.0.0.1:8765`) or a tailnet IP; reachability is your network's job.
/// Fork-only key — keep it in `~/.config/ghostty-ramon/config` (an official
/// Ghostty would error on it).
@"mcp-listen": ?[:0]const u8 = null,

/// (ramon fork) Optional shared secret for the MCP server, presented as the
/// `X-Ghostty-Token` header on `POST /mcp`. If EMPTY/null the server runs OPEN
/// (it logs a warning) and access control is the bound localhost/tailnet alone;
/// if SET it is fully enforced (constant-time compare) with a per-peer
/// failed-token backoff. This credential is LOAD-BEARING: a holder can spawn
/// tabs and run shell commands, so treat it as a shell-execution credential and
/// bind localhost or a tailnet only. If it leaks, ROTATE it and relaunch.
/// Fork-only key — keep it in `~/.config/ghostty-ramon/config`.
@"mcp-token": ?[:0]const u8 = null,
```

### 2.2 `src/config/Config.zig` — parse/roundtrip test

Add a NEW test immediately after `test "web-monitor: parse and default"` (ends line 11200),
mirroring it exactly:

```zig
test "mcp: parse and default" {
    const testing = std.testing;
    const alloc = testing.allocator;

    {
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        try cfg.finalize();
        try testing.expect(cfg.@"mcp-listen" == null);
        try testing.expect(cfg.@"mcp-token" == null);
    }

    {
        var cfg = try Config.default(alloc);
        defer cfg.deinit();
        var it: TestIterator = .{ .data = &.{
            "--mcp-listen=127.0.0.1:8765",
            "--mcp-token=supersecrettoken1234",
        } };
        try cfg.loadIter(alloc, &it);
        try cfg.finalize();
        try testing.expectEqualStrings("127.0.0.1:8765", cfg.@"mcp-listen".?);
        try testing.expectEqualStrings("supersecrettoken1234", cfg.@"mcp-token".?);
    }
}
```

Run: `zig build test -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=mcp`.

### 2.3 `macos/Sources/Ghostty/Ghostty.Config.swift` — getters

Add after `webMonitorToken` (ends line 252), mirroring it exactly:

```swift
// (ramon fork) MCP server listen address (addr:port); empty = disabled.
var mcpListen: String {
    guard let config = self.config else { return "" }
    var v: UnsafePointer<Int8>?
    let key = "mcp-listen"
    guard ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8))) else { return "" }
    guard let ptr = v else { return "" }
    return String(cString: ptr)
}

// (ramon fork) MCP server shared secret; empty = server runs open (logs a warning).
var mcpToken: String {
    guard let config = self.config else { return "" }
    var v: UnsafePointer<Int8>?
    let key = "mcp-token"
    guard ghostty_config_get(config, &v, key, UInt(key.lengthOfBytes(using: .utf8))) else { return "" }
    guard let ptr = v else { return "" }
    return String(cString: ptr)
}
```

---

## 3. MCP JSON-RPC surface

Transport: JSON-RPC 2.0 over `POST /mcp`, `Content-Type: application/json`, plain JSON response (no
SSE). The shim relays the agent's stdio JSON-RPC to this endpoint.

### 3.1 `initialize`

Result (echoed under the request `id`):

```json
{
  "protocolVersion": "2024-11-05",
  "capabilities": { "tools": { "listChanged": false } },
  "serverInfo": { "name": "ghostty-mcp", "version": "0.1.0" }
}
```

We advertise ONLY `tools` (`listChanged: false`; static set). The client's
`notifications/initialized` notification is accepted and answered with `.empty(202,"Accepted")`.

### 3.2 `tools/list`

Result: `{ "tools": [ … ] }`. Full schemas (every plan tool). All use `"type":"object"`,
`"additionalProperties": false`, explicit `required`. Surface address is always `id` (string UUID).

```json
{
  "tools": [
    {
      "name": "list_surfaces",
      "description": "List all live terminal surfaces (panes) with identity and layout position. Returns the stable surface id (UUID) used by every other tool. window/tab are POSITIONAL indices (encounter order), NOT stable across calls; only id is durable.",
      "inputSchema": { "type": "object", "properties": {}, "additionalProperties": false }
    },
    {
      "name": "read_surface",
      "description": "Read the text contents of a surface. mode 'viewport' (default) reads the visible screen; 'scrollback' reads the full scrollback+screen.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "id": { "type": "string", "description": "Surface UUID from list_surfaces." },
          "mode": { "type": "string", "enum": ["viewport", "scrollback"], "default": "viewport" }
        },
        "required": ["id"],
        "additionalProperties": false
      }
    },
    {
      "name": "get_layout",
      "description": "Return the window -> tab -> split-tree layout of all terminal windows. window/tab ids are POSITIONAL (encounter order), not stable across calls; surface leaves carry their durable id.",
      "inputSchema": { "type": "object", "properties": {}, "additionalProperties": false }
    },
    {
      "name": "send_text",
      "description": "Type text into a surface as real key events (NOT a paste). submit:true appends a Return to submit. Does not focus the surface.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "id": { "type": "string" },
          "text": { "type": "string" },
          "submit": { "type": "boolean", "default": false }
        },
        "required": ["id", "text"],
        "additionalProperties": false
      }
    },
    {
      "name": "send_key",
      "description": "Send a single named key (real keypress) to a surface. Useful to approve CLI-agent prompts (enter/y/n), interrupt (ctrl-c), clear a line (ctrl-u), or navigate.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "id": { "type": "string" },
          "key": {
            "type": "string",
            "enum": ["enter","escape","tab","backspace","up","down","left","right","y","n","space","ctrl-c","ctrl-u"]
          }
        },
        "required": ["id", "key"],
        "additionalProperties": false
      }
    },
    {
      "name": "scroll",
      "description": "Scroll a surface by signed wheel ticks. Positive dy scrolls back (up) toward older output; negative scrolls forward (down). Clamped to [-30, 30].",
      "inputSchema": {
        "type": "object",
        "properties": {
          "id": { "type": "string" },
          "dy": { "type": "number" }
        },
        "required": ["id", "dy"],
        "additionalProperties": false
      }
    },
    {
      "name": "wait_for_event",
      "description": "Block until a matching surface event fires or the timeout elapses. Events: 'bell' (terminal bell), 'exited' (child process exited), 'prompt' (returned to a shell prompt / awaiting confirmation — heuristic). Returns the event or null on timeout.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "filter": {
            "type": "object",
            "properties": {
              "ids": { "type": "array", "items": { "type": "string" } },
              "types": { "type": "array", "items": { "type": "string", "enum": ["bell","exited","prompt"] } }
            },
            "additionalProperties": false
          },
          "timeoutMs": { "type": "number", "default": 30000 }
        },
        "additionalProperties": false
      }
    },
    {
      "name": "watch_for_pattern",
      "description": "Poll a surface's text for a regular expression until it matches or the timeout elapses. Heuristic fallback for TUI agents that do not emit shell-prompt events.",
      "inputSchema": {
        "type": "object",
        "properties": {
          "id": { "type": "string" },
          "regex": { "type": "string" },
          "timeoutMs": { "type": "number", "default": 30000 }
        },
        "required": ["id", "regex"],
        "additionalProperties": false
      }
    },
    {
      "name": "focus_surface",
      "description": "Focus a surface: raise its window, select its tab, move keyboard focus to the pane.",
      "inputSchema": {
        "type": "object",
        "properties": { "id": { "type": "string" } },
        "required": ["id"],
        "additionalProperties": false
      }
    },
    {
      "name": "new_tab",
      "description": "Open a new terminal tab. Optional cwd sets the working directory (no '~' expansion — use an absolute path). Optional command runs as the new tab's first input in an interactive shell (it does NOT replace the shell). If a source surface id is given the tab inherits that surface's context; otherwise it opens from app defaults (a new window if none is open).",
      "inputSchema": {
        "type": "object",
        "properties": {
          "cwd": { "type": "string" },
          "command": { "type": "string" },
          "id": { "type": "string", "description": "Optional source surface UUID to inherit context from." }
        },
        "additionalProperties": false
      }
    },
    {
      "name": "close_surface",
      "description": "Request to close a surface (pane). Honors the terminal's normal close-confirmation behavior.",
      "inputSchema": {
        "type": "object",
        "properties": { "id": { "type": "string" } },
        "required": ["id"],
        "additionalProperties": false
      }
    },
    {
      "name": "perform_action",
      "description": "Run a Ghostty keybind action against a surface using the action grammar string, e.g. 'flip_split:horizontal', 'toggle_split_direction:vertical', 'swap_split:next', 'move_split_to_new_tab', 'merge_tabs:next_horizontal', 'mark_split', 'clear_split_mark', 'pull_marked_split:right', 'resize_split:down,2', 'goto_last_surface'. Relative verbs act relative to the given surface (v1 focuses it first).",
      "inputSchema": {
        "type": "object",
        "properties": {
          "id": { "type": "string" },
          "action": { "type": "string" }
        },
        "required": ["id", "action"],
        "additionalProperties": false
      }
    }
  ]
}
```

### 3.3 `tools/call` dispatch table

`tools/call` params: `{ "name": <string>, "arguments": <object> }`. The dispatch returns a
`ToolOutcome`; `handleRPC` shapes it into a JSON-RPC `result`:

- `.ok(payload)` → `result = { "content": [ { "type": "text", "text": <JSON-encoded payload> } ], "isError": false }`.
- `.toolError(msg)` → `result = { "content": [ { "type": "text", "text": <msg> } ], "isError": true }`.
- `.waitForEvent(spec)` → connection parked; on resolve a `.ok` (event or `{event:null}`) is sent (§6).

(MCP tool errors are a *successful* JSON-RPC response with `isError: true`, NOT a JSON-RPC error;
JSON-RPC `error` codes are reserved for protocol-level failures per §1.2.)

| Tool | Args | Handler | Underlying call |
|---|---|---|---|
| `list_surfaces` | — | `MCPLayout.surfaceRows()` → `surfacesJSONData` | `TerminalController.all` walk (main) → value rows |
| `read_surface` | id, mode | `MCPLayout.readText(uuid, scrollback)` | `cachedScreenContents/cachedVisibleContents.get()` + `ghostty_surface_size` (main) |
| `get_layout` | — | `MCPLayout.layoutTree()` | `TerminalController.all` + `SplitTree` walk (main) |
| `send_text` | id, text, submit | `MCPInput.sendText(uuid, text, submit)` | `keySpecs(forText:)` + optional Return → `ghostty_surface_key` (main) |
| `send_key` | id, key | `MCPInput.sendKey(uuid, key)` | `keySpecs(forKey:)` → `ghostty_surface_key` (main) |
| `scroll` | id, dy | `MCPInput.scroll(uuid, scrollDeltaClamped(dy))` | `ghostty_surface_mouse_scroll(s,0,dy,0)` (main) |
| `wait_for_event` | filter, timeoutMs | `MCPEventBus.register(...)` → park | event-bus (§6) |
| `watch_for_pattern` | id, regex, timeoutMs | `MCPEventBus.registerPattern(...)` → park | timer-polled `readText` + regex (§6.5) |
| `focus_surface` | id | `MCPLayout.focus(uuid)` | `BaseTerminalController.focusSurface(_:)` (main) |
| `new_tab` | cwd, command, id | `MCPLayout.newTab(cwd, command, sourceUUID)` | post `ghosttyNewTab` (main) |
| `close_surface` | id | `MCPLayout.close(uuid)` | `ghostty_surface_request_close` (main) |
| `perform_action` | id, action | `MCPLayout.performAction(uuid, action)` | focus-then `ghostty_surface_binding_action` (main) |

Any handler resolving a uuid and finding none → `.toolError("unknown surface id")`. `send_key`
unknown key → `.toolError("unknown key: <key>")`. `scroll` `dy == 0` → `.toolError("dy must be
non-zero")`.

**`new_tab` semantics (verified `Ghostty.App.swift` 895–949).** Post `Notification.ghosttyNewTab`.
If a source `id` resolves to a `SurfaceView`, post with `object: sourceView` and a
`SurfaceConfiguration` built from `ghostty_surface_inherited_config(sourceSurface,
GHOSTTY_SURFACE_CONTEXT_TAB)` with `cwd` overriding `.workingDirectory` and `command` (with a
trailing `\n` appended) set as `.initialInput`. If no source id (or it doesn't resolve), post with
`object: nil` and a BARE `SurfaceConfiguration` carrying only `.workingDirectory` (=cwd) and
`.initialInput` (=command\n) under `Notification.NewSurfaceConfigKey`. **Zero-window rule:** the
`object: nil` app-level notification is handled even when no terminal window is open (it opens a
new window), so `new_tab` is never a silent no-op. `cwd` is NOT tilde-expanded by the MCP server
(schema says absolute path) — matching `new_tab_command` semantics.

**`perform_action` v1 = focus-then-act (verified path exists).** On main: resolve uuid →
`(controller, view)`; `revealIfZoomedAway`; `controller.focusSurface(view)`; then
`ghostty_surface_binding_action(view.surface, action, action.utf8.count)` (or
`view.surfaceModel?.perform(action:)`). Relative verbs (`swap_split:next`, `pull_marked_split:right`,
`merge_tabs:…`) thereby act relative to the now-focused pane. `binding_action == false` (unknown/
failed) → `.toolError`. Phase 2 (anchor-parameterized, focus-preserving) is a documented follow-up,
not v1.

---

## 4. PURE `decideRoute` shape

Adapt the copied `decideRoute` (WM 476–549) to the MCP route set. PURE (no AppKit, socket, or
mutation); unit-tested.

```swift
enum RouteDecision: Equatable {
    case forbiddenHost      // 403 — Host-header / DNS-rebinding guard
    case throttled          // 429 — per-peer backoff (token mode only)
    case unauthorized       // 401 — token mismatch; bumps failure count
    case mcp                // POST /mcp — the only functional route
    case methodNotAllowed   // 405 — /mcp with a non-POST method
    case notFound           // 404 — any other path
}

static func decideRoute(
    method: String,
    path: String,
    headers: [String: String],
    configuredHost: String,
    configuredPort: UInt16,
    token: String,
    peerFailureCount: Int
) -> RouteDecision
```

Logic (mirrors WM):
1. Host-header guard: a present, non-empty `host` failing `hostHeaderAllowed(...)` → `.forbiddenHost`.
2. Token gate (ONLY when `!token.isEmpty`): `peerFailureCount >= failedAuthThreshold` →
   `.throttled`; else compare `headers["x-ghostty-token"] ?? ""` via `tokensMatch`; mismatch →
   `.unauthorized`. **No bootstrap/`?token=` path** — every MCP request carries the header (no
   browser `<script>`/`GET /` to accommodate). Empty `token` ⇒ OPEN (no token check, no backoff),
   matching WM's open-mode discipline.
3. Routing: `path == "/mcp"` → `method == "POST" ? .mcp : .methodNotAllowed`; else → `.notFound`.

`routeRequest` maps decisions to responses: `.forbiddenHost`→`.status(403,…)`,
`.throttled`→`.status(429,…)`, `.unauthorized`→`.status(401,…)` (+bump failure count),
`.methodNotAllowed`→`.status(405,…)`, `.notFound`→`.status(404,…)`, `.mcp`→`handleRPC(req.body, on:
conn)`. On `.mcp` success it clears the peer's auth failures (`clearAuthFailures`).

---

## 5. The `keySpecs` native-keycode table (copy verbatim)

Copy `KeySpec` (WM 862–920), `keySpecs(forKey:)` (WM 952–974), `keySpecs(forText:)` (WM 985–1017)
into `MCPInput.swift` UNCHANGED (one alias added below). Load-bearing rule: **`KeySpec.keycode` is
the NATIVE macOS virtual keycode** (NSEvent.keyCode space), matched by the core against
`input.keycodes` `entry.native`; `GHOSTTY_KEY_*` enum values are WRONG and silently no-op.

| key | KeySpec |
|---|---|
| `enter` | `KeySpec(keycode: 36)` |
| `esc` / `escape` | `KeySpec(keycode: 53)` |
| `tab` | `KeySpec(keycode: 48)` |
| `backspace` | `KeySpec(keycode: 51)` |
| `up` | `KeySpec(keycode: 126)` |
| `down` | `KeySpec(keycode: 125)` |
| `left` | `KeySpec(keycode: 123)` |
| `right` | `KeySpec(keycode: 124)` |
| `ctrl-c` | `KeySpec(keycode: 8, mods: GHOSTTY_MODS_CTRL, unshiftedCodepoint: 'c')` |
| `ctrl-u` | `KeySpec(keycode: 32, mods: GHOSTTY_MODS_CTRL, unshiftedCodepoint: 'u')` |
| `y` / `n` / `space` | `keySpecs(forText: "y" | "n" | " ")` (printable text path) |

The MCP `send_key` schema enum uses `escape` (not `esc`); the copied switch handles `"esc"`. **Add
one alias line** in the MCP copy: `case "escape": return [KeySpec(keycode: 53)]` (keep `"esc"`).
Printable text rides the `text` field with `keycode: 0` (`keySpecs(forText:)`); `\n`/`\r` → real
Return (keycode 36). Do NOT copy `keySpecs(body:contentType:)` or `scrollDeltaY`.

---

## 6. Event bus & `wait_for_event` (correctness-critical)

`MCPEventBus` is created once, held by `MCPServer`. Two sides: an EVENT SOURCE (main /
NotificationCenter) and a WAITER REGISTRY (mutated ONLY on the server serial queue).

### 6.1 Event source (main)

```swift
struct Event { let id: UUID; let type: EventType; let ts: Date }  // value type
enum EventType: String { case bell, exited, prompt }
```

- **bell**: observe `Notification.Name.ghosttyBellDidRing`; `notification.object as?
  Ghostty.SurfaceView` → `view.id`; emit `Event(id, .bell, now)` (verified: bell posts with
  `object: surfaceView`, `Ghostty.App.swift` 1259–1262).
- **exited**: poll-on-transition. A repeating main-queue timer (250ms) walks
  `TerminalController.all` reading `view.processExited`; emit `.exited` on a `false→true`
  transition per uuid (track last-seen in `[UUID: Bool]` on main). No host change (existing C
  accessor `ghostty_surface_process_exited`).
- **prompt**: SAME 250ms poll reads `view.needsConfirmQuit`; emit `.prompt` on a `false→true`
  transition (coarse proxy — §8).

Each emitted `Event` → `record(_:)`.

### 6.2 Coalescing ring (catches a just-fired event)

The bus keeps a fixed ring of the last N=64 events with timestamps. `record(event)` (runs on main):
1. Append to the ring (drop oldest past N).
2. Hop to the serial queue: `queue.async { self.deliver(event) }` (waiter mutation is queue-only).

`register(...)` (on the serial queue) first scans the ring for an event NEWER than (now −
coalesceWindow), coalesceWindow = 500ms, matching the filter; if found, RESOLVE immediately (so a
waiter registering microseconds after a bell still catches it). Otherwise PARK.

### 6.3 Waiter lifecycle (pinned teardown — fixes the prior major)

```swift
final class Waiter {                 // reference type so timer + closure share one instance
    let id = UUID()
    let conn: NWConnection
    let rpcId: Any                   // echoed JSON-RPC id
    let filter: (Event) -> Bool      // from {ids, types}
    var deadline: DispatchSourceTimer?   // touched ONLY on the serial queue
    var resolved = false                 // single-shot guard; touched ONLY on the serial queue
}
```

`MCPEventBus` state, mutated ONLY on the server serial queue:
- `var waiters: [Waiter]`.
- `var waitingConns: Set<ObjectIdentifier>` — parked conn keys, so `handle()` can EXEMPT them from
  the idle watchdog (§6.4).

`register(spec, conn, rpcId)` (called from `handleRPC`, already on the serial queue):
1. Build the filter from `spec.filter` (`ids` ⇒ membership on `event.id.uuidString`; `types` ⇒
   membership on `event.type.rawValue`; empty filter matches everything).
2. Coalesce-ring check (§6.2) — recent matching event ⇒ `resolve(waiter, with: event)` immediately, return.
3. Else create the `Waiter`, append to `waiters`, insert `ObjectIdentifier(conn)` into `waitingConns`.
4. Arm `deadline` = a `DispatchSourceTimer` on the serial queue firing at `now + spec.timeoutMs`
   whose handler calls `resolve(waiter, with: nil)`.

`resolve(_ waiter: Waiter, with event: Event?)` — SINGLE-SHOT, ALWAYS on the serial queue (callers
`queue.async` if not already on it). Performs ALL teardown atomically:
1. `guard !waiter.resolved else { return }` — single-shot guard (on the waiter; read/written only
   on the serial queue).
2. `waiter.resolved = true`.
3. **Cancel + nil the deadline timer**: `waiter.deadline?.cancel(); waiter.deadline = nil` (so a
   fired-after-resolve timer cannot run against a freed waiter/conn).
4. **Remove from BOTH registries**: `waiters.removeAll { $0.id == waiter.id }` AND
   `waitingConns.remove(ObjectIdentifier(waiter.conn))`.
5. Build the result: `event == nil ? {"event": null} : {"event": {id, type, ts}}` (ts as ISO-8601),
   wrap `.ok(...)`, `server.send(.json(resultEnvelope(id: waiter.rpcId, …)), on: waiter.conn)` —
   `send` self-disarms its timers and cancels the conn on completion.

`deliver(event)` (from `record` via `queue.async`): iterate a SNAPSHOT of `waiters`,
`resolve(w, with: event)` for each `w.filter(event) == true` (snapshot because `resolve` mutates
`waiters`).

Connection-drop coordination: in the copied `handle()` `stateUpdateHandler` (`.cancelled`/
`.failed`), in addition to clearing `connectionRefs`/timers, call `bus.connectionDropped(key)` →
on the serial queue, find any waiter with that conn and `resolve(w, with: nil)` (so a peer that
disconnects while parked is torn down; the single-shot guard makes a later timer/event a no-op).

### 6.4 `wait_for_event` exempt from the idle watchdog only

`handle()` arms the idle watchdog for ALL connections initially. When `handleRPC` recognizes a
`wait_for_event`/`watch_for_pattern` call and parks the connection, it CANCELS the idle timer for
that conn (`cancelConnectionTimer`) and relies on the per-waiter deadline timer. The connection-count
CAP still applies (a parked conn counts). The absolute deadline is NOT separately armed for parked
conns (the per-waiter `timeoutMs` bounds it).

### 6.5 `watch_for_pattern`

A degenerate waiter: a serial-queue repeating timer (300ms) that hops to main, reads
`MCPLayout.readText(uuid, scrollback:false).text`, tests `NSRegularExpression(pattern: regex)`; on
match `resolve(waiter, with: Event(id, .prompt, now))` shaped as `{matched:true,...}`; its deadline
resolves with `{matched:false}`. Same single-shot/teardown discipline (§6.3) — the polling timer
IS the `deadline`/work timer, cancelled inside `resolve`. Invalid regex → `.toolError("invalid
regex")` at register time (before parking). v1-optional (plan phase 4); if deferred, omit from
`tools/list`.

---

## 7. AppDelegate start/stop wiring

In `macos/Sources/App/macOS/AppDelegate.swift`, mirror the web-monitor block (236–246). Add a
stored property next to `webMonitor` (line 103):

```swift
private var mcpServer: MCPServer?
```

In `applicationDidFinishLaunching`, right after the web-monitor start block (~246):

```swift
// (ramon fork) Start the embedded MCP server if configured. Reads config only
// here (changing listen/token requires a relaunch). Runs OPEN if mcp-token is
// empty (logs a warning); a token, if set, is fully enforced.
let mcpListen = ghostty.config.mcpListen
if !mcpListen.isEmpty {
    let server = MCPServer(listen: mcpListen, token: ghostty.config.mcpToken)
    server.start()
    self.mcpServer = server
}
```

In `applicationWillTerminate` (next to `webMonitor?.stop()` at line 445):

```swift
mcpServer?.stop()
```

---

## 8. Prompt detection: `atPrompt` vs `needs_confirm_quit`

Two candidate signals for the `prompt` event type and the `list_surfaces` `atPrompt` field:

- **`needs_confirm_quit` (coarse, SHIPS in v1).** `ghostty_surface_needs_confirm_quit` (C API 1161,
  Swift `view.needsConfirmQuit` at 137) returns true when quitting would interrupt a running
  process. Its `false→true` transition is a usable proxy for "a foreground command finished and
  we're back at a prompt" — but COARSE: it conflates the shell-prompt state with quit-confirmation
  policy, can be affected by config, and is not OSC 133 prompt-start. NO host or core change; uses
  an already-exposed accessor. The `list_surfaces` `atPrompt` field uses `!view.needsConfirmQuit`
  (a weak proxy), documented as heuristic.

- **Optional GUI-only `atPrompt` (richer, DEFERRED).** The host already pushes an `at_prompt` frame
  to the GUI; a precise `prompt` event would add a Swift `atPrompt: Bool` published property on
  `SurfaceView` fed from that frame's GUI-side handler (NO host change — a new GUI property reacting
  to an action that already arrives). This is the accurate OSC 133 signal, but it touches the
  surface action-handling path and is more than the v1 budget.

**Recommendation: ship `needs_confirm_quit` in v1**, documented in the `wait_for_event` /
`watch_for_pattern` / `list_surfaces.atPrompt` descriptions as heuristic. Provide
`watch_for_pattern` as the accurate-but-manual escape hatch for TUI agents (e.g. Claude Code's "Do
you want to proceed?" prompt). Defer the precise `atPrompt` property to a phase-2 follow-up; the
`EventType.prompt` contract is unchanged, only its source upgrades, so no schema change when it
lands.

---

## 9. stdio shim (separate SPM package)

`macos/mcp-shim/` — NOT in `Ghostty.xcodeproj`; built with `swift build`. A dumb stdin↔HTTP pipe.

### 9.1 `macos/mcp-shim/Package.swift`

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ghostty-mcp",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "ghostty-mcp", path: "Sources/ghostty-mcp")
    ]
)
```

### 9.2 `macos/mcp-shim/Sources/ghostty-mcp/main.swift` (outline)

Foundation-only, single-threaded/serial:

1. Resolve the server URL: env `GHOSTTY_MCP_URL` if set, else default
   `http://127.0.0.1:8765/mcp`. Resolve the token: env `GHOSTTY_MCP_TOKEN` (optional).
2. Read stdin LINE-DELIMITED (MCP stdio framing is newline-delimited JSON). For each complete
   JSON-RPC line:
   a. `POST <url>` with `Content-Type: application/json`, body = the line, and (if token set) header
      `X-Ghostty-Token: <token>`. Use `URLSession` with a semaphore (synchronous).
   b. Inspect the response: if status is **202 or 204 OR the body is empty / `Content-Length: 0`**,
      the message was a notification — write NOTHING to stdout. Otherwise write the response body
      then `\n` to stdout and flush. (Consistent with §1.1: notifications produce `.empty(202,…)`
      ⇒ status 202 AND empty body; both checks agree.)
3. On a network error reaching the server, write a JSON-RPC error to stdout
   (`{"jsonrpc":"2.0","id":<id-if-parseable-else-null>,"error":{"code":-32000,"message":"ghostty MCP
   server unreachable"}}`) so the agent sees a structured failure, not a hang.
4. EOF on stdin → exit 0.

`claude mcp add ghostty -- ghostty-mcp` then works (set `GHOSTTY_MCP_TOKEN` in the MCP block if a
token is configured).

---

## 10. Tests — `macos/Tests/MCP/MCPServerTests.swift`

Auto-discovered by the filesystem-synchronized `GhosttyTests` group (no pbxproj edit for the test
file). All assertions on PURE functions / value types (no live server, no AppKit). Exact list:

1. `parseListenValid` / `parseListenIPv6Brackets` / `parseListenRejectsNoColon` /
   `parseListenRejectsBadPort`.
2. `keySpecsForKeyNamedKeys` — enter/esc/escape/tab/backspace/arrows/ctrl-c/ctrl-u map to the exact
   native keycodes + mods in §5; `escape` alias equals `esc`.
3. `keySpecsForKeyYNSpace` — y/n/space ride the text path (text-bearing, keycode 0).
4. `keySpecsForKeyUnknownNil` — unknown key → nil.
5. `keySpecsForTextCoalescesRun` — a printable run is ONE text spec; embedded `\n` splits into a
   Return (keycode 36); trailing `\n` → trailing Return.
6. `scrollDeltaClampedZeroNil` / `scrollDeltaClampedClampsRange` / `scrollDeltaClampedPreservesSign`
   — 0→nil; >30→30; <-30→-30; positive stays positive.
7. `decideRouteForbiddenHost` — bad Host → `.forbiddenHost`.
8. `decideRouteOpenModeNoToken` — empty token, `POST /mcp` → `.mcp` (no auth).
9. `decideRouteTokenRequiredHeader` — token set: missing/wrong header → `.unauthorized`; correct
   header → `.mcp`; a query `?token=` does NOT authorize.
10. `decideRouteThrottledAtThreshold` — `peerFailureCount >= failedAuthThreshold` → `.throttled`.
11. `decideRouteMethodNotAllowed` — `GET /mcp` → `.methodNotAllowed`.
12. `decideRouteNotFound` — `POST /other` → `.notFound`.
13. `requestParserCompletePost` / `requestParserNeedMore` / `requestParserBadContentLength` /
    `requestParserChunkedRejected` / `requestParserTooLarge` — copied parser behavior.
14. `parseRPCParseError` — non-JSON body → `.parseError`.
15. `parseRPCInvalidRequest` — JSON missing `jsonrpc`/`method` → `.invalid`.
16. `parseRPCNotification` — no `id` → `.notification`.
17. `parseRPCRequestEchoesId` — string id, number id, and `null` id preserved by TYPE through
    `resultEnvelope`/`errorEnvelope`.
18. `errorEnvelopeParseErrorIdNull` — parseError envelope carries `id: null`, code -32700.
19. `errorEnvelopeInvalidIdNull` — invalid-request envelope carries `id: null`, code -32600.
20. `toolsListHasAllTools` — `toolsListResult` contains exactly the 12 tool names with non-empty
    `inputSchema` objects (`type==object`, `additionalProperties==false`).
21. `toolsListSchemaRequiredFields` — `read_surface`/`send_text`/`send_key`/`scroll`/`focus_surface`/
    `close_surface`/`perform_action` list `id` (and the right siblings) in `required`;
    `send_key.key.enum` is the §3.2 set; `scroll` requires `dy`.
22. `initializeResultShape` — protocolVersion `"2024-11-05"`, `capabilities.tools.listChanged ==
    false`, `serverInfo.name == "ghostty-mcp"`.
23. `surfacesJSONDataShape` — `surfacesJSONData(rows)` maps `SurfaceRow`s to id/title/pwd/window/tab/
    tabTitle/splitIndex/splitCount/focused/bell/exited/atPrompt with correct types.
24. `dispatchUnknownToolError` — `dispatch` with an unknown name → method-not-found / `.toolError`
    (no crash); `dispatchSendKeyUnknownKey` → `.toolError` (resolves before any main hop).
25. `httpResponseEmptyBody` — `HTTPResponse.empty(202,"Accepted").body == Data()` and
    `statusCode == 202` (regression guard for the notification path).
26. `hostHeaderAllowedLoopback` / `hostHeaderAllowedExactMatch` / `hostHeaderRejectsOther`.
27. `tokensMatchConstantTime` — equal/unequal/length-mismatch all behave.

---

## 11. pbxproj plan (iOS exclusion)

New MCP Swift files are macOS-only (Network + AppKit), INCLUDED automatically via the
filesystem-synchronized `Sources` group (`81F82BC72E82815D001EDFA7`). The ONLY edit is to EXCLUDE
them from the iOS target, copying the WebMonitor pattern.

In `macos/Ghostty.xcodeproj/project.pbxproj`, in the iOS-target exception set
`81F82CB02E8281F5001EDFA7` (`membershipExceptions`, currently lines 118–263; the WebMonitor entries
are at 212–215), ADD these entries in the existing alpha order (between `Features/Global Keybinds/…`
at 165 and the next `Features/` block — the MCP module sorts after `Global Keybinds`, before
`QuickTerminal`):

```
"Features/MCP/MCPServer.swift",
"Features/MCP/MCPRPC.swift",
"Features/MCP/MCPTools.swift",
"Features/MCP/MCPInput.swift",
"Features/MCP/MCPLayout.swift",
"Features/MCP/MCPEventBus.swift",
```

No entry for `Tests/MCP/MCPServerTests.swift` — the `Tests` root group `A54F45F42E1F047A0046BD5C`
is synchronized for the test target and needs no exception. No entry in the *Ghostty*-target iOS
set `81F82CB12E8281F9001EDFA7` either (that set excludes macOS-only Surface/App files, not the MCP
module). The `macos/mcp-shim/` package is OUTSIDE the synchronized group and gets NO pbxproj entry.

---

## 12. Build / verify

- Zig config test (cheap, agent may run): `zig build test -Demit-macos-app=false
  -Demit-xcframework=false -Dtest-filter=mcp`.
- Rebuild lib (human/loop): `zig build -Demit-macos-app=false -Doptimize=ReleaseFast`.
- Swift tests (human/loop, minutes): `macos/build.nu --action test` or `xcodebuild …
  -only-testing:GhosttyTests/MCPServerTests test`.
- App build (human/loop): `macos/build.nu --configuration ReleaseLocal --action build`.
- Shim: `cd macos/mcp-shim && swift build`.
- Manual smoke: set `mcp-listen = 127.0.0.1:8765` (+ optional `mcp-token`) in
  `~/.config/ghostty-ramon/config`; `curl -s -X POST http://127.0.0.1:8765/mcp -H 'Content-Type:
  application/json' [-H 'X-Ghostty-Token: …'] -d
  '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'`; then `claude mcp add ghostty -- ghostty-mcp`.

> Workflow agents MUST NOT run the multi-minute Swift/app builds (watchdog). Author + statically
> verify; the Zig config test is the only cheap build to attempt.

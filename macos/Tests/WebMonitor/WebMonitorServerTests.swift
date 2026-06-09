import Foundation
import Testing
@testable import Ghostty

/// Unit tests for the pure / value units of the fork-only web monitor server.
/// These cover the security-critical request parsing (Content-Length bounds,
/// chunked rejection, header detection across partial reads), token comparison,
/// input decoding (incl. the fixed brace-leading-plaintext behavior and the new
/// arrow/Tab keys), listen-spec parsing, and the surfaces JSON shaping.
struct WebMonitorServerTests {

    // MARK: - tokenAcceptable (startup strength gate)

    @Test func tokenAcceptableEmpty() {
        #expect(!WebMonitorServer.tokenAcceptable(""))
    }

    @Test func tokenAcceptableTooShort() {
        #expect(!WebMonitorServer.tokenAcceptable("abc"))
        #expect(!WebMonitorServer.tokenAcceptable("short-token"))  // 11 chars
    }

    @Test func tokenAcceptableJustUnderMin() {
        // 15 chars: one below the minimum -> rejected.
        #expect(!WebMonitorServer.tokenAcceptable("abcdefghijklmno"))
    }

    @Test func tokenAcceptableAtMin() {
        // Exactly 16 chars -> accepted.
        #expect(WebMonitorServer.tokenAcceptable("abcdefghijklmnop"))
    }

    @Test func tokenAcceptableLongRandomish() {
        #expect(WebMonitorServer.tokenAcceptable("k7Qz9pXr2mWv8tLb4nHc"))  // 20 chars
    }

    // MARK: - tokensMatch

    @Test func tokensMatchEqual() {
        #expect(WebMonitorServer.tokensMatch("abc123", "abc123"))
    }

    @Test func tokensMatchSameLenDiffContent() {
        #expect(!WebMonitorServer.tokensMatch("abc123", "abc124"))
    }

    @Test func tokensMatchDiffLen() {
        #expect(!WebMonitorServer.tokensMatch("abc", "abcd"))
    }

    @Test func tokensMatchEmptyEmpty() {
        // Two empty strings are byte-equal. (The server separately refuses to
        // start with an empty configured token, so this never authenticates.)
        #expect(WebMonitorServer.tokensMatch("", ""))
    }

    @Test func tokensMatchMultibyteEqual() {
        #expect(WebMonitorServer.tokensMatch("tökën-✓", "tökën-✓"))
    }

    @Test func tokensMatchOffByOneByte() {
        #expect(!WebMonitorServer.tokensMatch("tökën-✓", "tökën-✗"))
    }

    // MARK: - decodeInput

    @Test func decodeInputNamedKeys() {
        func key(_ k: String) -> [UInt8]? {
            WebMonitorServer.decodeInput(
                body: Data("{\"key\":\"\(k)\"}".utf8),
                contentType: "application/json")
        }
        #expect(key("enter") == [0x0d])
        #expect(key("ctrl-c") == [0x03])
        #expect(key("esc") == [0x1b])
        #expect(key("tab") == [0x09])
        #expect(key("up") == [0x1b, 0x5b, 0x41])
        #expect(key("down") == [0x1b, 0x5b, 0x42])
        #expect(key("right") == [0x1b, 0x5b, 0x43])
        #expect(key("left") == [0x1b, 0x5b, 0x44])
        #expect(key("y") == [UInt8(ascii: "y")])
        #expect(key("n") == [UInt8(ascii: "n")])
    }

    @Test func decodeInputUnknownKey() {
        let r = WebMonitorServer.decodeInput(
            body: Data("{\"key\":\"bogus\"}".utf8),
            contentType: "application/json")
        #expect(r == nil)
    }

    @Test func decodeInputJSONContentTypeButNonJSONBody() {
        // Declared JSON but the body is not valid JSON / has no key -> nil.
        let r = WebMonitorServer.decodeInput(
            body: Data("not json".utf8),
            contentType: "application/json")
        #expect(r == nil)
    }

    @Test func decodeInputJSONWithCharsetParam() {
        // Content-Type with a parameter still counts as JSON (substring match).
        let r = WebMonitorServer.decodeInput(
            body: Data("{\"key\":\"enter\"}".utf8),
            contentType: "application/json; charset=utf-8")
        #expect(r == [0x0d])
    }

    @Test func decodeInputTextTypeWithBraceBodyNotJSON() {
        // A non-JSON content type whose body happens to be JSON-shaped must be
        // treated as raw bytes (keyed off Content-Type only, never sniffed).
        let body = Data("{\"key\":\"enter\"}".utf8)
        let r = WebMonitorServer.decodeInput(body: body, contentType: "text/plain; charset=utf-8")
        #expect(r == [UInt8](body))
    }

    @Test func decodeInputRawPlaintext() {
        let r = WebMonitorServer.decodeInput(
            body: Data("hello".utf8),
            contentType: "text/plain")
        #expect(r == [UInt8]("hello".utf8))
    }

    @Test func decodeInputEmptyPlaintext() {
        let r = WebMonitorServer.decodeInput(body: Data(), contentType: "text/plain")
        #expect(r == [])
    }

    @Test func decodeInputEmptyBodyContract() {
        // The empty-decoded-input contract that routeRequest's /input handler
        // relies on for its 400/no-op behavior. For a raw (non-JSON) content
        // type an empty body decodes to a NON-nil empty byte array (decodeInput
        // succeeds), and routeRequest's separate `!bytes.isEmpty` guard is what
        // turns that empty result into a 400 no-op (nothing is fed to the
        // surface). decodeInput does NOT itself return nil for an empty raw body.
        #expect(WebMonitorServer.decodeInput(body: Data(), contentType: "text/plain") == [])
        #expect(WebMonitorServer.decodeInput(body: Data(), contentType: "") == [])
        // An empty body declared as JSON is NOT parseable as {"key":...}, so it
        // decodes to nil (decodeInput failure) — also a 400 in routeRequest, but
        // via the `guard let bytes` branch rather than the empty-bytes branch.
        #expect(WebMonitorServer.decodeInput(body: Data(), contentType: "application/json") == nil)
    }

    @Test func decodeInputBraceLeadingPlaintextIsNotSniffed() {
        // FIXED behavior (S11): text starting with "{" but sent as text/plain
        // must round-trip verbatim, NOT be interpreted as a JSON key command.
        let body = Data("{not a command}".utf8)
        let r = WebMonitorServer.decodeInput(body: body, contentType: "text/plain")
        #expect(r == [UInt8](body))
    }

    @Test func decodeInputNoContentTypeIsRaw() {
        let body = Data("{\"key\":\"enter\"}".utf8)
        let r = WebMonitorServer.decodeInput(body: body, contentType: "")
        // No declared JSON -> raw bytes, not interpreted.
        #expect(r == [UInt8](body))
    }

    // MARK: - parseListen

    @Test func parseListenIPv4() {
        let r = WebMonitorServer.parseListen("100.1.2.3:8787")
        #expect(r?.host == "100.1.2.3")
        #expect(r?.port == 8787)
    }

    @Test func parseListenIPv6Bracketed() {
        let r = WebMonitorServer.parseListen("[::1]:8787")
        #expect(r?.host == "::1")
        #expect(r?.port == 8787)
    }

    @Test func parseListenMissingPort() {
        #expect(WebMonitorServer.parseListen("100.1.2.3") == nil)
    }

    @Test func parseListenEmptyPort() {
        #expect(WebMonitorServer.parseListen("100.1.2.3:") == nil)
    }

    @Test func parseListenNonNumericPort() {
        #expect(WebMonitorServer.parseListen("host:abc") == nil)
    }

    @Test func parseListenOutOfRangePort() {
        #expect(WebMonitorServer.parseListen("host:70000") == nil)
    }

    @Test func parseListenMissingHost() {
        #expect(WebMonitorServer.parseListen(":8787") == nil)
    }

    @Test func parseListenHostname() {
        let r = WebMonitorServer.parseListen("localhost:8787")
        #expect(r?.host == "localhost")
        #expect(r?.port == 8787)
    }

    // MARK: - RequestParser

    private static let cap = WebMonitorServer.maxRequestBytes

    @Test func requestParserNeedsMoreBeforeHeaders() {
        let r = WebMonitorServer.RequestParser.parse(Data("GET / HTTP/1.1\r\n".utf8), maxRequestBytes: Self.cap)
        if case .needMore = r {} else { Issue.record("expected needMore, got \(r)") }
    }

    @Test func requestParserSimpleGet() {
        let raw = "GET /api/surfaces HTTP/1.1\r\nHost: x\r\n\r\n"
        let r = WebMonitorServer.RequestParser.parse(Data(raw.utf8), maxRequestBytes: Self.cap)
        guard case .complete(let req) = r else { Issue.record("expected complete, got \(r)"); return }
        #expect(req.method == "GET")
        #expect(req.path == "/api/surfaces")
        #expect(req.headers["host"] == "x")
        #expect(req.body.isEmpty)
    }

    @Test func requestParserQueryPercentDecode() {
        let raw = "GET /api/surface/abc/screen?mode=scroll%20back&token=a%26b HTTP/1.1\r\n\r\n"
        let r = WebMonitorServer.RequestParser.parse(Data(raw.utf8), maxRequestBytes: Self.cap)
        guard case .complete(let req) = r else { Issue.record("expected complete"); return }
        #expect(req.path == "/api/surface/abc/screen")
        #expect(req.query["mode"] == "scroll back")
        #expect(req.query["token"] == "a&b")
    }

    @Test func requestParserContentLengthReassembly() {
        // Header arrives, but the body is short of Content-Length -> needMore;
        // once the full body arrives -> complete.
        let head = "POST /x HTTP/1.1\r\nContent-Length: 5\r\n\r\n"
        let partial = Data((head + "ab").utf8)
        let r1 = WebMonitorServer.RequestParser.parse(partial, maxRequestBytes: Self.cap)
        if case .needMore = r1 {} else { Issue.record("expected needMore, got \(r1)") }

        let full = Data((head + "abcde").utf8)
        let r2 = WebMonitorServer.RequestParser.parse(full, maxRequestBytes: Self.cap)
        guard case .complete(let req) = r2 else { Issue.record("expected complete, got \(r2)"); return }
        #expect(req.body == Data("abcde".utf8))
    }

    @Test func requestParserNegativeContentLengthIsBadRequest() {
        let raw = "POST /x HTTP/1.1\r\nContent-Length: -1\r\n\r\n"
        let r = WebMonitorServer.RequestParser.parse(Data(raw.utf8), maxRequestBytes: Self.cap)
        if case .badRequest = r {} else { Issue.record("expected badRequest, got \(r)") }
    }

    @Test func requestParserOversizedContentLengthIsBadRequest() {
        let raw = "POST /x HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n"
        let r = WebMonitorServer.RequestParser.parse(Data(raw.utf8), maxRequestBytes: Self.cap)
        if case .badRequest = r {} else { Issue.record("expected badRequest, got \(r)") }
    }

    @Test func requestParserNonNumericContentLengthIsBadRequest() {
        let raw = "POST /x HTTP/1.1\r\nContent-Length: abc\r\n\r\n"
        let r = WebMonitorServer.RequestParser.parse(Data(raw.utf8), maxRequestBytes: Self.cap)
        if case .badRequest = r {} else { Issue.record("expected badRequest, got \(r)") }
    }

    @Test func requestParserChunkedIsLengthRequired() {
        let raw = "POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
        let r = WebMonitorServer.RequestParser.parse(Data(raw.utf8), maxRequestBytes: Self.cap)
        if case .lengthRequired = r {} else { Issue.record("expected lengthRequired, got \(r)") }
    }

    @Test func requestParserNonUTF8HeaderIsBadRequest() {
        // Invalid UTF-8 byte (0xFF) inside the header block before CRLFCRLF.
        var raw = Data("GET / HTTP/1.1\r\nX-Bad: ".utf8)
        raw.append(0xFF)
        raw.append(contentsOf: "\r\n\r\n".utf8)
        let r = WebMonitorServer.RequestParser.parse(raw, maxRequestBytes: Self.cap)
        if case .badRequest = r {} else { Issue.record("expected badRequest, got \(r)") }
    }

    @Test func requestParserMissingTargetIsBadRequest() {
        let raw = "GET\r\n\r\n"
        let r = WebMonitorServer.RequestParser.parse(Data(raw.utf8), maxRequestBytes: Self.cap)
        if case .badRequest = r {} else { Issue.record("expected badRequest, got \(r)") }
    }

    @Test func requestParserTooLargeBeforeHeaderEnd() {
        // A buffer at/over the cap with no header terminator must be rejected,
        // not grown forever.
        let tiny = 16
        var raw = Data("GET /".utf8)
        while raw.count < tiny { raw.append(UInt8(ascii: "a")) }
        let r = WebMonitorServer.RequestParser.parse(raw, maxRequestBytes: tiny)
        if case .tooLarge = r {} else { Issue.record("expected tooLarge, got \(r)") }
    }

    @Test func requestParserZeroContentLengthBody() {
        let raw = "POST /x HTTP/1.1\r\nContent-Length: 0\r\n\r\n"
        let r = WebMonitorServer.RequestParser.parse(Data(raw.utf8), maxRequestBytes: Self.cap)
        guard case .complete(let req) = r else { Issue.record("expected complete"); return }
        #expect(req.body.isEmpty)
    }

    @Test func requestParserMalformedPercentPassesThrough() {
        // A bad percent-escape is left verbatim (removingPercentEncoding fails ->
        // fall back to the raw substring), never crashing.
        let raw = "GET /x?a=%zz&b=%2 HTTP/1.1\r\n\r\n"
        let r = WebMonitorServer.RequestParser.parse(Data(raw.utf8), maxRequestBytes: Self.cap)
        guard case .complete(let req) = r else { Issue.record("expected complete"); return }
        #expect(req.query["a"] == "%zz")
        #expect(req.query["b"] == "%2")
    }

    @Test func requestParserDuplicateQueryKeyLastWins() {
        let raw = "GET /x?k=1&k=2 HTTP/1.1\r\n\r\n"
        let r = WebMonitorServer.RequestParser.parse(Data(raw.utf8), maxRequestBytes: Self.cap)
        guard case .complete(let req) = r else { Issue.record("expected complete"); return }
        #expect(req.query["k"] == "2")
    }

    @Test func requestParserDuplicateHeaderLastWins() {
        // A non-Content-Length duplicate header is last-wins.
        let raw = "GET / HTTP/1.1\r\nX-Test: a\r\nX-Test: b\r\n\r\n"
        let r = WebMonitorServer.RequestParser.parse(Data(raw.utf8), maxRequestBytes: Self.cap)
        guard case .complete(let req) = r else { Issue.record("expected complete"); return }
        #expect(req.headers["x-test"] == "b")
    }

    @Test func requestParserHeaderValueWithColon() {
        // Header values may contain colons (split on the FIRST colon only).
        let raw = "GET / HTTP/1.1\r\nHost: example.com:8787\r\nX-Url: http://a/b\r\n\r\n"
        let r = WebMonitorServer.RequestParser.parse(Data(raw.utf8), maxRequestBytes: Self.cap)
        guard case .complete(let req) = r else { Issue.record("expected complete"); return }
        #expect(req.headers["host"] == "example.com:8787")
        #expect(req.headers["x-url"] == "http://a/b")
    }

    @Test func requestParserConflictingDuplicateContentLengthIsBadRequest() {
        // Request-smuggling guard: two Content-Length values that disagree.
        let raw = "POST /x HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 7\r\n\r\nabcde"
        let r = WebMonitorServer.RequestParser.parse(Data(raw.utf8), maxRequestBytes: Self.cap)
        if case .badRequest = r {} else { Issue.record("expected badRequest, got \(r)") }
    }

    @Test func requestParserDuplicateContentLengthSameValueOK() {
        // Identical duplicate Content-Length is harmless (last-wins, no conflict).
        let raw = "POST /x HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\nabcde"
        let r = WebMonitorServer.RequestParser.parse(Data(raw.utf8), maxRequestBytes: Self.cap)
        guard case .complete(let req) = r else { Issue.record("expected complete, got \(r)"); return }
        #expect(req.body == Data("abcde".utf8))
    }

    // Content-Length body-cap boundary: CL == cap allowed, CL == cap+1 rejected.
    @Test func requestParserContentLengthAtCapAllowed() {
        let smallCap = 16
        // Header + body where CL == smallCap; supply the full body so it completes.
        let bodyBytes = String(repeating: "x", count: smallCap)
        let raw = "POST /x HTTP/1.1\r\nContent-Length: \(smallCap)\r\n\r\n" + bodyBytes
        // The full buffer exceeds smallCap (headers + body), so to pin JUST the
        // CL<=cap check we use a cap large enough for the buffer but assert CL
        // itself is accepted up to maxRequestBytes via a dedicated cap value.
        let cap = raw.utf8.count
        let r = WebMonitorServer.RequestParser.parse(Data(raw.utf8), maxRequestBytes: cap)
        guard case .complete(let req) = r else { Issue.record("expected complete, got \(r)"); return }
        #expect(req.body.count == smallCap)
    }

    @Test func requestParserContentLengthOverCapRejected() {
        // When the cap is smaller than the header block itself, the overall
        // buffer-size cap preempts the Content-Length-over-cap guard: the full
        // request buffer (~40 bytes) already exceeds maxRequestBytes (16), so the
        // parser returns .tooLarge before it ever reaches the cl <= cap check.
        // The request is still rejected, just as .tooLarge rather than .badRequest.
        // The Content-Length-guard -> .badRequest path is covered separately by
        // requestParserOversizedContentLengthIsBadRequest (real large cap, huge CL).
        let smallCap = 16
        let raw = "POST /x HTTP/1.1\r\nContent-Length: \(smallCap + 1)\r\n\r\n"
        let r = WebMonitorServer.RequestParser.parse(Data(raw.utf8), maxRequestBytes: smallCap)
        if case .tooLarge = r {} else { Issue.record("expected tooLarge, got \(r)") }
    }

    // MARK: - hostHeaderAllowed (DNS-rebinding defense)

    @Test func hostHeaderExactMatch() {
        #expect(WebMonitorServer.hostHeaderAllowed(
            "100.1.2.3:8787", configuredHost: "100.1.2.3", configuredPort: 8787))
    }

    @Test func hostHeaderLoopbackOnConfiguredPort() {
        #expect(WebMonitorServer.hostHeaderAllowed(
            "localhost:8787", configuredHost: "100.1.2.3", configuredPort: 8787))
        #expect(WebMonitorServer.hostHeaderAllowed(
            "127.0.0.1:8787", configuredHost: "100.1.2.3", configuredPort: 8787))
    }

    @Test func hostHeaderIPv6Loopback() {
        #expect(WebMonitorServer.hostHeaderAllowed(
            "[::1]:8787", configuredHost: "100.1.2.3", configuredPort: 8787))
    }

    @Test func hostHeaderWrongPortRejected() {
        #expect(!WebMonitorServer.hostHeaderAllowed(
            "100.1.2.3:9999", configuredHost: "100.1.2.3", configuredPort: 8787))
    }

    @Test func hostHeaderBareDefaultsTo80() {
        // No port -> defaults to 80; rejected unless we bound 80.
        #expect(!WebMonitorServer.hostHeaderAllowed(
            "100.1.2.3", configuredHost: "100.1.2.3", configuredPort: 8787))
        #expect(WebMonitorServer.hostHeaderAllowed(
            "100.1.2.3", configuredHost: "100.1.2.3", configuredPort: 80))
    }

    @Test func hostHeaderAttackerHostnameRejected() {
        #expect(!WebMonitorServer.hostHeaderAllowed(
            "evil.example.com:8787", configuredHost: "100.1.2.3", configuredPort: 8787))
    }

    @Test func hostHeaderCaseInsensitive() {
        #expect(WebMonitorServer.hostHeaderAllowed(
            "MyHost.Tailnet:8787", configuredHost: "myhost.tailnet", configuredPort: 8787))
    }

    // MARK: - surfacesJSONData (pure shaping)

    @Test func surfacesJSONEmpty() {
        let d = WebMonitorServer.surfacesJSONData([])
        #expect(String(data: d, encoding: .utf8) == "[]")
    }

    @Test func surfacesJSONShape() throws {
        let d = WebMonitorServer.surfacesJSONData([
            (id: "id-1", title: "Title One", pwd: "/home/x"),
            (id: "id-2", title: "", pwd: ""),
        ])
        let arr = try JSONSerialization.jsonObject(with: d) as? [[String: String]]
        #expect(arr?.count == 2)
        #expect(arr?[0]["id"] == "id-1")
        #expect(arr?[0]["title"] == "Title One")
        #expect(arr?[0]["pwd"] == "/home/x")
        #expect(arr?[1]["title"] == "")
    }

    // MARK: - decideRoute (the PURE, security-load-bearing router)

    private static let host = "100.1.2.3"
    private static let port: UInt16 = 8787
    private static let tok = "s3cret"

    /// Call decideRoute with sensible defaults (good Host, good token, no
    /// failures) so individual tests override only what they exercise.
    private func decide(
        _ method: String, _ path: String,
        query: [String: String] = [:],
        headers: [String: String]? = nil,
        token presented: String = WebMonitorServerTests.tok,
        peerFailures: Int = 0
    ) -> WebMonitorServer.RouteDecision {
        var h = headers ?? ["host": "\(Self.host):\(Self.port)"]
        // Default to presenting the token via header unless the caller already
        // supplied one (in headers) or is presenting it via the query string.
        if h["x-ghostty-token"] == nil, query["token"] == nil {
            h["x-ghostty-token"] = presented
        }
        return WebMonitorServer.decideRoute(
            method: method, path: path, query: query, headers: h,
            configuredHost: Self.host, configuredPort: Self.port,
            token: Self.tok, peerFailureCount: peerFailures)
    }

    @Test func decideRouteTokenMissing() {
        let d = WebMonitorServer.decideRoute(
            method: "GET", path: "/", query: [:], headers: ["host": "\(Self.host):\(Self.port)"],
            configuredHost: Self.host, configuredPort: Self.port, token: Self.tok, peerFailureCount: 0)
        #expect(d == .unauthorized)
    }

    @Test func decideRouteWrongToken() {
        #expect(decide("GET", "/",
                       headers: ["host": "\(Self.host):\(Self.port)", "x-ghostty-token": "wrong"],
                       token: "wrong") == .unauthorized)
    }

    @Test func decideRouteBadHostForbidden() {
        let d = WebMonitorServer.decideRoute(
            method: "GET", path: "/", query: [:],
            headers: ["host": "evil.example.com:8787", "x-ghostty-token": Self.tok],
            configuredHost: Self.host, configuredPort: Self.port, token: Self.tok, peerFailureCount: 0)
        #expect(d == .forbiddenHost)
    }

    @Test func decideRouteHostCheckBeforeToken() {
        // Bad Host is rejected even with a valid token (defense ordering).
        let d = WebMonitorServer.decideRoute(
            method: "GET", path: "/", query: [:],
            headers: ["host": "evil:8787", "x-ghostty-token": Self.tok],
            configuredHost: Self.host, configuredPort: Self.port, token: Self.tok, peerFailureCount: 0)
        #expect(d == .forbiddenHost)
    }

    @Test func decideRouteThrottledBeforeToken() {
        // Once the peer is over threshold, throttle even a (would-be) valid token.
        #expect(decide("GET", "/", peerFailures: WebMonitorServer.failedAuthThreshold) == .throttled)
        #expect(decide("GET", "/", peerFailures: WebMonitorServer.failedAuthThreshold + 1) == .throttled)
    }

    @Test func decideRouteUnderThresholdNotThrottled() {
        #expect(decide("GET", "/", peerFailures: WebMonitorServer.failedAuthThreshold - 1) == .page)
    }

    @Test func unresolvedPeerNeverThrottled() {
        // routeRequest substitutes a 0 failure count for the unresolved-peer
        // sentinel (so a best-effort key collision can't 429 a legitimate
        // peer). decideRoute with a 0 count must never throttle, even when the
        // shared bucket has accumulated failures from OTHER peers. This pins
        // the testable half of that contract: 0 in ⇒ not .throttled.
        #expect(WebMonitorServer.unresolvedPeerKey == "?")
        #expect(decide("GET", "/", peerFailures: 0) != .throttled)
    }

    @Test func decideRouteMissingHostAllowed() {
        // A missing Host header (no rebinding context) is allowed; token still gates.
        let d = WebMonitorServer.decideRoute(
            method: "GET", path: "/", query: [:], headers: ["x-ghostty-token": Self.tok],
            configuredHost: Self.host, configuredPort: Self.port, token: Self.tok, peerFailureCount: 0)
        #expect(d == .page)
    }

    @Test func decideRouteEmptyHostAllowed() {
        // An EMPTY Host header (distinct from a missing one) is treated like a
        // missing Host: the `!host.isEmpty` guard short-circuits the rebinding
        // check, so it is NOT .forbiddenHost — it falls through to the normal
        // token gate and routes to .page on GET /. (No browser sends an empty
        // Host, but the parser can yield "" for `Host:` with no value.)
        let d = WebMonitorServer.decideRoute(
            method: "GET", path: "/", query: [:],
            headers: ["host": "", "x-ghostty-token": Self.tok],
            configuredHost: Self.host, configuredPort: Self.port, token: Self.tok, peerFailureCount: 0)
        #expect(d == .page)
    }

    @Test func decideRoutePage() {
        #expect(decide("GET", "/") == .page)
    }

    @Test func decideRoutePagePostIsMethodNotAllowed() {
        #expect(decide("POST", "/") == .methodNotAllowed)
    }

    @Test func decideRouteSurfacesGet() {
        #expect(decide("GET", "/api/surfaces") == .surfacesList)
    }

    @Test func decideRouteSurfacesPostMethodNotAllowed() {
        #expect(decide("POST", "/api/surfaces") == .methodNotAllowed)
    }

    @Test func decideRouteNonUUIDIsNotFound() {
        #expect(decide("GET", "/api/surface/not-a-uuid/screen") == .notFound)
    }

    @Test func decideRouteScreenViewport() {
        let id = UUID()
        #expect(decide("GET", "/api/surface/\(id.uuidString)/screen") == .screen(uuid: id, scrollback: false))
    }

    @Test func decideRouteScreenScrollback() {
        let id = UUID()
        #expect(decide("GET", "/api/surface/\(id.uuidString)/screen", query: ["mode": "scrollback"])
                == .screen(uuid: id, scrollback: true))
    }

    @Test func decideRouteScreenUnknownModeDefaultsToViewport() {
        // The screen mode is scrollback ONLY for the exact value "scrollback";
        // any unknown/junk value (or a missing one) falls back to viewport
        // (scrollback: false). `mode=garbage` must not be treated as scrollback.
        let id = UUID()
        #expect(decide("GET", "/api/surface/\(id.uuidString)/screen", query: ["mode": "garbage"])
                == .screen(uuid: id, scrollback: false))
        // An explicitly empty mode value also defaults to viewport.
        #expect(decide("GET", "/api/surface/\(id.uuidString)/screen", query: ["mode": ""])
                == .screen(uuid: id, scrollback: false))
    }

    @Test func decideRouteScreenPostMethodNotAllowed() {
        let id = UUID()
        #expect(decide("POST", "/api/surface/\(id.uuidString)/screen") == .methodNotAllowed)
    }

    @Test func decideRouteInput() {
        let id = UUID()
        #expect(decide("POST", "/api/surface/\(id.uuidString)/input") == .input(uuid: id))
    }

    @Test func decideRouteInputGetMethodNotAllowed() {
        let id = UUID()
        #expect(decide("GET", "/api/surface/\(id.uuidString)/input") == .methodNotAllowed)
    }

    @Test func decideRouteUnknownActionIsNotFound() {
        let id = UUID()
        #expect(decide("GET", "/api/surface/\(id.uuidString)/bogus") == .notFound)
    }

    @Test func decideRouteUnknownPathIsNotFound() {
        #expect(decide("DELETE", "/totally/unknown") == .notFound)
    }

    @Test func decideRouteTokenViaQueryParam() {
        // Initial page load presents the token in the query string.
        let d = WebMonitorServer.decideRoute(
            method: "GET", path: "/", query: ["token": Self.tok],
            headers: ["host": "\(Self.host):\(Self.port)"],
            configuredHost: Self.host, configuredPort: Self.port, token: Self.tok, peerFailureCount: 0)
        #expect(d == .page)
    }

    @Test func decideRouteQueryTokenRejectedOnAPI() {
        // The query token (?token=) authenticates only GET /; on /api/* routes
        // it is ignored, so presenting the token solely via query is unauthorized.
        let d = WebMonitorServer.decideRoute(
            method: "GET", path: "/api/surfaces", query: ["token": Self.tok],
            headers: ["host": "\(Self.host):\(Self.port)"],
            configuredHost: Self.host, configuredPort: Self.port, token: Self.tok, peerFailureCount: 0)
        #expect(d == .unauthorized)
    }

    @Test func decideRouteHeaderTokenAcceptedOnAPI() {
        // The X-Ghostty-Token header is the required credential for /api/* routes.
        let d = WebMonitorServer.decideRoute(
            method: "GET", path: "/api/surfaces", query: [:],
            headers: ["host": "\(Self.host):\(Self.port)", "x-ghostty-token": Self.tok],
            configuredHost: Self.host, configuredPort: Self.port, token: Self.tok, peerFailureCount: 0)
        #expect(d == .surfacesList)
    }

    @Test func decideRouteHeaderTokenAcceptedOnPage() {
        // The header token is ALSO accepted on GET / (the query token is only an
        // additional convenience there, not the sole accepted form). With no
        // query token, the header token authenticates the bootstrap page.
        let d = WebMonitorServer.decideRoute(
            method: "GET", path: "/", query: [:],
            headers: ["host": "\(Self.host):\(Self.port)", "x-ghostty-token": Self.tok],
            configuredHost: Self.host, configuredPort: Self.port, token: Self.tok, peerFailureCount: 0)
        #expect(d == .page)
    }

    @Test func decideRoutePageQueryTokenPreferredOverHeader() {
        // Precedence on GET /: `query["token"] ?? headerToken`, so a VALID query
        // token authenticates even when the header token is wrong/absent. This
        // pins the fallback ordering (query first, header as fallback) on the
        // page route, the mirror of /api/* (which ignores the query token).
        let d = WebMonitorServer.decideRoute(
            method: "GET", path: "/", query: ["token": Self.tok],
            headers: ["host": "\(Self.host):\(Self.port)", "x-ghostty-token": "wrong"],
            configuredHost: Self.host, configuredPort: Self.port, token: Self.tok, peerFailureCount: 0)
        #expect(d == .page)
    }

    @Test func decideRouteEmptyPresentedTokenUnauthorized() {
        // Neither a query token nor a header token present -> the presented token
        // is "" which never matches the (non-empty) configured token -> 401.
        let d = WebMonitorServer.decideRoute(
            method: "GET", path: "/", query: [:],
            headers: ["host": "\(Self.host):\(Self.port)"],
            configuredHost: Self.host, configuredPort: Self.port, token: Self.tok, peerFailureCount: 0)
        #expect(d == .unauthorized)
    }

    // MARK: - Embedded page: jump-to-bottom affordance

    @Test func htmlPageHasJumpToBottomButton() {
        let page = WebMonitorServer.htmlPage
        // The button element + its handler must exist so scrolled-up users can
        // re-stick to the live bottom.
        #expect(page.contains("id=\"jumpbottom\""))
        #expect(page.contains("jumpBtn"))
    }

    @Test func htmlPageJumpButtonSetsScrollToBottom() {
        let page = WebMonitorServer.htmlPage
        // The click handler jumps to the live bottom (scrollTop = scrollHeight)
        // and refreshes its own visibility.
        #expect(page.contains("jumpBtn.onclick"))
        #expect(page.contains("screenEl.scrollTop = screenEl.scrollHeight"))
        #expect(page.contains("updateJumpBtn"))
    }

    @Test func htmlPageJumpButtonStartsHidden() {
        let page = WebMonitorServer.htmlPage
        // The button is CSS-hidden by default and only shown when scrolled up,
        // so it stays unobtrusive (notably on mobile).
        #expect(page.contains("#jumpbottom { display: none;"))
        #expect(page.contains("isNearBottom"))
    }

    @Test func htmlPageHasTokenRecoveryForm() {
        let page = WebMonitorServer.htmlPage
        // A phone user whose ?token=... URL was scrubbed (replaceState) must be
        // able to re-enter the token in-page. The form + Connect button exist
        // and are CSS-hidden until the no-token / 401 state surfaces them.
        #expect(page.contains("id=\"tokeninput\""))
        #expect(page.contains("id=\"tokenconnect\""))
        #expect(page.contains("#tokenrecovery { display: none;"))
    }

    @Test func htmlPageTokenRecoveryStoresAndRestarts() {
        let page = WebMonitorServer.htmlPage
        // Connecting persists the entered token to sessionStorage and re-runs
        // the fetches via start().
        #expect(page.contains("tokenConnect.onclick"))
        #expect(page.contains("sessionStorage.setItem(\"ghostty_token\", token)"))
        #expect(page.contains("function start()"))
    }

    @Test func htmlPageTokenRecoveryShownOnNoTokenAndUnauthorized() {
        let page = WebMonitorServer.htmlPage
        // Both the no-token startup and the 401 paths route through
        // showTokenRecovery so the form is offered in every locked-out state.
        #expect(page.contains("function showTokenRecovery"))
        #expect(page.contains("showTokenRecovery(\"No token."))
        #expect(page.contains("showTokenRecovery(\"Unauthorized."))
    }

    @Test func htmlPageSessionClosedTeardownShared() {
        let page = WebMonitorServer.htmlPage
        // The session-closed teardown is factored into one helper so the poll()
        // 404 path and reportSend()'s 404 path tear down identically: clear the
        // poll timer, drop current, show the sticky "Session closed." banner,
        // and return to the list.
        #expect(page.contains("function sessionClosedTeardown()"))
        #expect(page.contains("setBanner(\"Session closed.\", false, true)"))
        // Both 404 callers route through the shared helper: the poll() 404 path
        // and reportSend()'s `r.status === 404` branch. Verify the definition plus
        // both call sites without depending on exact indentation/newlines — count
        // the occurrences (1 definition + 2 call sites = at least 3) and confirm
        // each 404 caller's context appears alongside a sessionClosedTeardown() call.
        let teardownCalls = page.components(separatedBy: "sessionClosedTeardown()").count - 1
        #expect(teardownCalls >= 3)
        // poll() 404 path: the `m === "404"` check routes through the helper.
        #expect(page.contains("m === \"404\""))
        // reportSend() 404 path: the `r.status === 404` branch routes through the helper.
        #expect(page.contains("r.status === 404") && page.contains("=== 404) { sessionClosedTeardown(); }"))
    }

    @Test func htmlPageReportSend404RunsSessionTeardown() {
        let page = WebMonitorServer.htmlPage
        // A send that gets HTTP 404 means the session is gone; reportSend must
        // run the same teardown as the poll 404 path rather than leaving a stale
        // viewer + sticky "Send failed" banner until the next poll fires.
        #expect(page.contains("else if (r && r.status === 404) { sessionClosedTeardown(); }"))
    }

    @Test func htmlPageCtrlCQuickKeyIsDestyled() {
        let page = WebMonitorServer.htmlPage
        // Ctrl-C sits beside benign keys (y/n/Esc); it gets a danger style + a
        // left gap so it is not a one-tap fat-finger neighbor.
        #expect(page.contains("<button data-key=\"ctrl-c\" class=\"danger\">Ctrl-C</button>"))
        #expect(page.contains("button.danger {"))
        #expect(page.contains("margin-left: 12px"))
    }

    @Test func htmlPageSentToastLingers() {
        let page = WebMonitorServer.htmlPage
        // The "Sent." success toast clears after ~1500ms (was 600ms) so a
        // throttled/backgrounded mobile tab does not miss the flash.
        #expect(page.contains("setBanner(\"Sent.\", true); setTimeout(function () { clearBannerIfNotError(); }, 1500);"))
        #expect(!page.contains("clearBannerIfNotError(); }, 600)"))
    }

    @Test func htmlPageDeadTapShowsNoActiveSession() {
        let page = WebMonitorServer.htmlPage
        // A quick-key / Send tapped with no current surface (dead tap after a
        // 404 teardown) shows a brief "No active session." banner instead of
        // silently returning.
        #expect(page.contains("function noActiveSession() { setBanner(\"No active session.\", false); setTimeout(clearBannerIfNotError, 1500); }"))
        #expect(page.contains("if (!current) { noActiveSession(); return; }"))
    }
}

import Foundation
import Testing
import GhosttyKit
@testable import Ghostty

/// Unit tests for the pure / value units of the fork-only web monitor server.
/// These cover the security-critical request parsing (Content-Length bounds,
/// chunked rejection, header detection across partial reads), token comparison,
/// the input -> key-event-spec mapping (real key events, not paste — incl. the
/// fixed brace-leading-plaintext behavior, ctrl-c as a real Ctrl+C, and the
/// trailing-newline -> Enter submit), listen-spec parsing, and surfaces JSON shaping.
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

    // MARK: - keySpecs (real key events, not paste)

    @Test func keySpecsNamedKeysAreRealKeyEvents() {
        // Named keys map to a single spec carrying a ghostty_input_key_e
        // keycode (NOT a pasted escape byte sequence) so Ghostty synthesizes
        // the real keypress.
        func spec(_ k: String) -> WebMonitorServer.KeySpec? {
            WebMonitorServer.keySpecs(forKey: k)?.first
        }
        // NATIVE macOS virtual keycodes (NSEvent.keyCode space), NOT GHOSTTY_KEY_*.
        #expect(spec("enter") == WebMonitorServer.KeySpec(keycode: 36))
        #expect(spec("esc") == WebMonitorServer.KeySpec(keycode: 53))
        #expect(spec("tab") == WebMonitorServer.KeySpec(keycode: 48))
        #expect(spec("backspace") == WebMonitorServer.KeySpec(keycode: 51))
        #expect(spec("up") == WebMonitorServer.KeySpec(keycode: 126))
        #expect(spec("down") == WebMonitorServer.KeySpec(keycode: 125))
        #expect(spec("left") == WebMonitorServer.KeySpec(keycode: 123))
        #expect(spec("right") == WebMonitorServer.KeySpec(keycode: 124))
    }

    @Test func keySpecsCtrlCSetsCtrlModifier() {
        // ctrl-c is a REAL Ctrl+C key event (GHOSTTY_KEY_C + ctrl modifier),
        // not a pasted 0x03 byte.
        let s = WebMonitorServer.keySpecs(forKey: "ctrl-c")
        #expect(s == [WebMonitorServer.KeySpec(keycode: 8, mods: GHOSTTY_MODS_CTRL,
                                               unshiftedCodepoint: UInt32(UnicodeScalar("c").value))])
        // ctrl-u (clear line) is a real Ctrl+U key event.
        #expect(WebMonitorServer.keySpecs(forKey: "ctrl-u")
            == [WebMonitorServer.KeySpec(keycode: 32, mods: GHOSTTY_MODS_CTRL,
                                         unshiftedCodepoint: UInt32(UnicodeScalar("u").value))])
    }

    @Test func keySpecsYNArePrintableText() {
        // y/n are just printable text: text-bearing, keycode unset (0),
        // unshiftedCodepoint = the scalar.
        #expect(WebMonitorServer.keySpecs(forKey: "y")
            == [WebMonitorServer.KeySpec(text: "y", unshiftedCodepoint: UInt32(UnicodeScalar("y").value))])
        #expect(WebMonitorServer.keySpecs(forKey: "n")
            == [WebMonitorServer.KeySpec(text: "n", unshiftedCodepoint: UInt32(UnicodeScalar("n").value))])
    }

    @Test func keySpecsUnknownKey() {
        #expect(WebMonitorServer.keySpecs(forKey: "bogus") == nil)
    }

    @Test func keySpecsForTextOnePerCharacter() {
        // Printable text -> one text-bearing spec per Character, keycode unset,
        // unshiftedCodepoint = each char's first scalar.
        let s = WebMonitorServer.keySpecs(forText: "hi")
        #expect(s == [
            WebMonitorServer.KeySpec(text: "h", unshiftedCodepoint: UInt32(UnicodeScalar("h").value)),
            WebMonitorServer.KeySpec(text: "i", unshiftedCodepoint: UInt32(UnicodeScalar("i").value)),
        ])
        // The keycode stays unset (0) for printable text.
        #expect(s.first?.keycode == 0)
        #expect(s.first?.text == "h")
    }

    @Test func keySpecsForTextEmptyIsEmptyList() {
        #expect(WebMonitorServer.keySpecs(forText: "") == [])
    }

    @Test func keySpecsEmptyKeyIsUnknown() {
        // An empty named-key string is not a known key -> nil (treated as a 400
        // by the route, NOT as empty text).
        #expect(WebMonitorServer.keySpecs(forKey: "") == nil)
    }

    @Test func keySpecsPlainLettersCarryNoModsButCtrlCDoes() {
        // Plain printable letters must carry NO modifier (mods stays at the
        // default GHOSTTY_MODS_NONE), so they type as ordinary characters.
        for spec in WebMonitorServer.keySpecs(forText: "yn") {
            #expect(spec.mods == GHOSTTY_MODS_NONE)
        }
        #expect(WebMonitorServer.keySpecs(forKey: "y")?.first?.mods == GHOSTTY_MODS_NONE)
        #expect(WebMonitorServer.keySpecs(forKey: "n")?.first?.mods == GHOSTTY_MODS_NONE)
        // Named non-modifier keys are also mods-free.
        #expect(WebMonitorServer.keySpecs(forKey: "enter")?.first?.mods == GHOSTTY_MODS_NONE)
        #expect(WebMonitorServer.keySpecs(forKey: "up")?.first?.mods == GHOSTTY_MODS_NONE)
        // ...whereas ctrl-c is the ONLY key here that carries a modifier.
        #expect(WebMonitorServer.keySpecs(forKey: "ctrl-c")?.first?.mods == GHOSTTY_MODS_CTRL)
    }

    @Test func keySpecsForTextNewlineIsRealEnter() {
        // The trailing "\n" the page appends on Send must become a REAL Enter
        // key event (so the line actually submits), NOT a dead text-bearing
        // control char. \r maps the same way.
        #expect(WebMonitorServer.keySpecs(forText: "\n") == [WebMonitorServer.KeySpec(keycode: 36)])
        #expect(WebMonitorServer.keySpecs(forText: "\r") == [WebMonitorServer.KeySpec(keycode: 36)])
        // "hi\n" -> two printable specs then an Enter.
        #expect(WebMonitorServer.keySpecs(forText: "hi\n") == [
            WebMonitorServer.KeySpec(text: "h", unshiftedCodepoint: UInt32(UnicodeScalar("h").value)),
            WebMonitorServer.KeySpec(text: "i", unshiftedCodepoint: UInt32(UnicodeScalar("i").value)),
            WebMonitorServer.KeySpec(keycode: 36),
        ])
    }

    // MARK: - keySpecs(body:contentType:) — request decode

    @Test func keySpecsBodyJSONNamedKey() {
        let r = WebMonitorServer.keySpecs(
            body: Data("{\"key\":\"enter\"}".utf8),
            contentType: "application/json")
        #expect(r == [WebMonitorServer.KeySpec(keycode: 36)])
    }

    @Test func keySpecsBodyJSONUnknownKey() {
        // Declared JSON with an unknown key -> nil (400).
        let r = WebMonitorServer.keySpecs(
            body: Data("{\"key\":\"bogus\"}".utf8),
            contentType: "application/json")
        #expect(r == nil)
    }

    @Test func keySpecsBodyJSONContentTypeButNonJSONBody() {
        // Declared JSON but the body is not valid JSON / has no key -> nil.
        let r = WebMonitorServer.keySpecs(
            body: Data("not json".utf8),
            contentType: "application/json")
        #expect(r == nil)
    }

    @Test func keySpecsBodyJSONWithCharsetParam() {
        // Content-Type with a parameter still counts as JSON (substring match).
        let r = WebMonitorServer.keySpecs(
            body: Data("{\"key\":\"enter\"}".utf8),
            contentType: "application/json; charset=utf-8")
        #expect(r == [WebMonitorServer.KeySpec(keycode: 36)])
    }

    @Test func keySpecsBodyTextTypeWithBraceBodyNotJSON() {
        // A non-JSON content type whose body happens to be JSON-shaped must be
        // treated as literal text (keyed off Content-Type only, never sniffed).
        // It becomes one printable spec per character, NOT a key command.
        let r = WebMonitorServer.keySpecs(
            body: Data("{x}".utf8),
            contentType: "text/plain; charset=utf-8")
        #expect(r == WebMonitorServer.keySpecs(forText: "{x}"))
        #expect(r?.count == 3)
    }

    @Test func keySpecsBodyRawPlaintext() {
        let r = WebMonitorServer.keySpecs(
            body: Data("hi".utf8),
            contentType: "text/plain")
        #expect(r == WebMonitorServer.keySpecs(forText: "hi"))
    }

    @Test func keySpecsBodyEmptyContract() {
        // The empty-input contract the route relies on for its 400/no-op:
        // a raw (non-JSON) empty body decodes to a NON-nil empty list, and the
        // route's `!specs.isEmpty` guard turns that into a 400.
        #expect(WebMonitorServer.keySpecs(body: Data(), contentType: "text/plain") == [])
        #expect(WebMonitorServer.keySpecs(body: Data(), contentType: "") == [])
        // An empty body declared as JSON is NOT parseable as {"key":...} -> nil
        // (400 via the guard-let branch instead).
        #expect(WebMonitorServer.keySpecs(body: Data(), contentType: "application/json") == nil)
    }

    @Test func keySpecsBodyBraceLeadingPlaintextIsNotSniffed() {
        // S11: text starting with "{" but sent as text/plain must be treated as
        // literal text, NOT interpreted as a JSON key command.
        let r = WebMonitorServer.keySpecs(
            body: Data("{not a command}".utf8),
            contentType: "text/plain")
        #expect(r == WebMonitorServer.keySpecs(forText: "{not a command}"))
    }

    @Test func keySpecsBodyNoContentTypeIsText() {
        // No declared JSON -> literal text, not interpreted.
        let r = WebMonitorServer.keySpecs(
            body: Data("{\"key\":\"enter\"}".utf8),
            contentType: "")
        #expect(r == WebMonitorServer.keySpecs(forText: "{\"key\":\"enter\"}"))
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

    @Test func hostHeaderMalformedUnbalancedBracket() {
        // "[" prefix but no closing "]" — must not trap on the missing index and
        // must reject (the leftover "[::1:8787" matches neither host nor loopback).
        #expect(!WebMonitorServer.hostHeaderAllowed(
            "[::1:8787", configuredHost: "100.1.2.3", configuredPort: 8787))
        #expect(!WebMonitorServer.hostHeaderAllowed(
            "[::1:8787", configuredHost: "::1", configuredPort: 8787))
    }

    @Test func hostHeaderMalformedStrayDoubleColon() {
        // A stray "::" in a non-bracketed host: split on the last ':' leaves a
        // garbage host "a::b" — must not trap and must reject.
        #expect(!WebMonitorServer.hostHeaderAllowed(
            "a::b:8787", configuredHost: "100.1.2.3", configuredPort: 8787))
        #expect(!WebMonitorServer.hostHeaderAllowed(
            "a::b:8787", configuredHost: "::1", configuredPort: 8787))
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

    @Test func surfacesJSONEscapesHostileChars() throws {
        // JSON-hostile: double quote, backslash, newline, and a multibyte emoji.
        // Proper escaping means the bytes round-trip back byte-identical.
        let hostileTitle = "a\"b\\c\nd\u{1F600}e"
        let hostilePwd = "/tmp/\"quoted\"\\back\nslash\u{1F4A9}"
        let d = WebMonitorServer.surfacesJSONData([
            (id: "id-1", title: hostileTitle, pwd: hostilePwd),
        ])
        let arr = try JSONSerialization.jsonObject(with: d) as? [[String: String]]
        #expect(arr?.count == 1)
        #expect(arr?[0]["title"] == hostileTitle)
        #expect(arr?[0]["pwd"] == hostilePwd)
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

    @Test func decideRouteSurfaceMissingActionIsNotFound() {
        // /api/surface/{uuid} with no trailing action component (3 comps, not 4).
        let id = UUID()
        #expect(decide("GET", "/api/surface/\(id.uuidString)") == .notFound)
    }

    @Test func decideRouteSurfaceExtraComponentIsNotFound() {
        // /api/surface/{uuid}/screen/extra has an extra trailing component (5 comps, not 4).
        let id = UUID()
        #expect(decide("GET", "/api/surface/\(id.uuidString)/screen/extra") == .notFound)
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

    @Test func decideRouteOpenWhenNoTokenConfigured() {
        // Empty configured token => OPEN: routes resolve with NO token presented
        // (access control is the tailnet alone). Host-header allowlist still applies.
        func open(_ path: String, peerFailures: Int = 0) -> WebMonitorServer.RouteDecision {
            WebMonitorServer.decideRoute(
                method: "GET", path: path, query: [:],
                headers: ["host": "\(Self.host):\(Self.port)"],
                configuredHost: Self.host, configuredPort: Self.port,
                token: "", peerFailureCount: peerFailures)
        }
        #expect(open("/") == .page)
        #expect(open("/api/surfaces") == .surfacesList)
        // Not throttled when open — the backoff only applies to a configured token.
        #expect(open("/", peerFailures: WebMonitorServer.failedAuthThreshold + 5) == .page)
        // A bad Host is still rejected even when open.
        #expect(WebMonitorServer.decideRoute(
            method: "GET", path: "/", query: [:], headers: ["host": "evil.example.com:8787"],
            configuredHost: Self.host, configuredPort: Self.port, token: "", peerFailureCount: 0) == .forbiddenHost)
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

    @Test func htmlPageTokenRecoveryShownOnUnauthorized() {
        let page = WebMonitorServer.htmlPage
        // Token auth is OPTIONAL: with no token the page proceeds (open server),
        // so there is NO no-token startup block. The recovery form is offered
        // only when a token IS required and a request comes back 401.
        #expect(page.contains("function showTokenRecovery"))
        #expect(!page.contains("showTokenRecovery(\"No token."))   // open mode: no startup gate
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

    @Test func htmlPageSendTypesTextOnlyEnterKeySubmits() {
        let page = WebMonitorServer.htmlPage
        // Send TYPES the text only — it does NOT submit. Submitting is the
        // separate, explicit Enter quick-key. So doSend just sendText(v) with no
        // Enter coupling, and no trailing newline is ever pasted.
        #expect(page.contains("sendText(v);"))
        #expect(!page.contains("withNewline"))            // Send/Enter are decoupled now
        #expect(!page.contains("rawBtn"))                 // the redundant "No Enter" button is gone
        #expect(!page.contains("v + \"\\\\n\""))          // never append a literal newline
        #expect(page.contains("sendBtn.onclick = doSend;"))
        // Return in the field types too (does NOT submit).
        #expect(page.contains("if (e.key === \"Enter\") { e.preventDefault(); doSend(); }"))
        // Submitting is the explicit Enter quick-key (sends a real Enter key event).
        #expect(page.contains("data-key=\"enter\""))
    }

    // MARK: - Static asset routes (vendored xterm.js / xterm.css)

    @Test func assetRoutesMapShape() {
        // The two vendored assets are routed with the expected resource name /
        // extension and a correct MIME type.
        let js = WebMonitorServer.assetRoutes["/xterm.js"]
        #expect(js?.name == "xterm")
        #expect(js?.ext == "js")
        #expect(js?.contentType == "application/javascript; charset=utf-8")
        let css = WebMonitorServer.assetRoutes["/xterm.css"]
        #expect(css?.name == "xterm")
        #expect(css?.ext == "css")
        #expect(css?.contentType == "text/css; charset=utf-8")
        // Nothing else is an asset route.
        #expect(WebMonitorServer.assetRoutes["/other.js"] == nil)
    }

    @Test func isBootstrapPathCoversPageAndAssets() {
        // The bootstrap set is exactly GET / plus the two asset routes; these
        // accept the ?token= query form. Everything else must NOT be bootstrap
        // (so it requires the X-Ghostty-Token header).
        #expect(WebMonitorServer.isBootstrapPath("/"))
        #expect(WebMonitorServer.isBootstrapPath("/xterm.js"))
        #expect(WebMonitorServer.isBootstrapPath("/xterm.css"))
        #expect(!WebMonitorServer.isBootstrapPath("/api/surfaces"))
        #expect(!WebMonitorServer.isBootstrapPath("/anything/else"))
    }

    @Test func decideRouteAssetJS() {
        let d = decide("GET", "/xterm.js")
        #expect(d == .asset(name: "xterm", ext: "js", contentType: "application/javascript; charset=utf-8"))
    }

    @Test func decideRouteAssetCSS() {
        let d = decide("GET", "/xterm.css")
        #expect(d == .asset(name: "xterm", ext: "css", contentType: "text/css; charset=utf-8"))
    }

    @Test func decideRouteAssetPostMethodNotAllowed() {
        #expect(decide("POST", "/xterm.js") == .methodNotAllowed)
    }

    @Test func decideRouteAssetAcceptsQueryToken() {
        // A <script>/<link> tag cannot send the X-Ghostty-Token header, so the
        // asset routes accept the token via ?token= like GET /.
        let d = WebMonitorServer.decideRoute(
            method: "GET", path: "/xterm.js", query: ["token": Self.tok],
            headers: ["host": "\(Self.host):\(Self.port)"],
            configuredHost: Self.host, configuredPort: Self.port, token: Self.tok, peerFailureCount: 0)
        #expect(d == .asset(name: "xterm", ext: "js", contentType: "application/javascript; charset=utf-8"))
    }

    @Test func decideRouteAssetAcceptsHeaderToken() {
        // The header token is also accepted on the asset routes.
        let d = WebMonitorServer.decideRoute(
            method: "GET", path: "/xterm.css", query: [:],
            headers: ["host": "\(Self.host):\(Self.port)", "x-ghostty-token": Self.tok],
            configuredHost: Self.host, configuredPort: Self.port, token: Self.tok, peerFailureCount: 0)
        #expect(d == .asset(name: "xterm", ext: "css", contentType: "text/css; charset=utf-8"))
    }

    @Test func decideRouteAssetWrongTokenUnauthorized() {
        // The token still gates the asset routes (they are not unauthenticated).
        let d = WebMonitorServer.decideRoute(
            method: "GET", path: "/xterm.js", query: ["token": "wrong"],
            headers: ["host": "\(Self.host):\(Self.port)"],
            configuredHost: Self.host, configuredPort: Self.port, token: Self.tok, peerFailureCount: 0)
        #expect(d == .unauthorized)
    }

    @Test func decideRouteAssetBadHostForbidden() {
        // The Host-header (DNS-rebinding) defense applies to the asset routes too.
        let d = WebMonitorServer.decideRoute(
            method: "GET", path: "/xterm.js", query: ["token": Self.tok],
            headers: ["host": "evil.example.com:8787"],
            configuredHost: Self.host, configuredPort: Self.port, token: Self.tok, peerFailureCount: 0)
        #expect(d == .forbiddenHost)
    }

    @Test func assetResponseMissingResourceIs404() {
        // In the unit-test bundle the vendored files are not present, so the
        // bundle lookup misses and we return a clean 404 (never a crash). This
        // pins the missing-resource fallback path.
        let r = WebMonitorServer.assetResponse(
            name: "definitely-not-a-bundled-resource", ext: "js",
            contentType: "application/javascript; charset=utf-8")
        #expect(r.statusCode == 404)
    }

    @Test func httpResponseAssetCarriesContentTypeAndBytes() {
        // The .asset response variant serves arbitrary bytes with an explicit
        // Content-Type (200 OK), distinct from text/json.
        let bytes = Data([0x2f, 0x2f, 0x20, 0x6a, 0x73])  // "// js"
        let r = WebMonitorServer.HTTPResponse.asset(bytes, "application/javascript; charset=utf-8")
        #expect(r.statusCode == 200)
        #expect(r.reason == "OK")
        #expect(r.contentType == "application/javascript; charset=utf-8")
        #expect(r.body == bytes)
    }
}

/// Unit tests for the pure framing/codec helpers of `WebMonitorHostClient`,
/// the Swift client for the `ghostty-host` length-prefixed wire protocol
/// (see `src/host/protocol.zig`). These pin the exact wire layout: BE u32
/// length prefix, LE in-frame scalars, the four frame tag values, and the
/// partial-read-tolerant `FrameReader` reassembly.
struct WebMonitorHostClientTests {

    typealias C = WebMonitorHostClient

    // MARK: - Frame tag values (FrameType enum ordinals in protocol.zig)

    @Test func frameTagValuesMatchProtocol() {
        #expect(C.FrameTag.hello.rawValue == 0)
        #expect(C.FrameTag.helloAck.rawValue == 1)
        #expect(C.FrameTag.subscribeRaw.rawValue == 31)
        #expect(C.FrameTag.rawOutput.rawValue == 32)
    }

    // MARK: - encodeFrame (BE length prefix + tag + payload)

    @Test func encodeFrameLayout() {
        let payload = Data([0xaa, 0xbb, 0xcc])
        let frame = C.encodeFrame(tag: .rawOutput, payload: payload)
        // len = 1 (tag) + 3 (payload) = 4, big-endian.
        #expect(Array(frame) == [0x00, 0x00, 0x00, 0x04, 32, 0xaa, 0xbb, 0xcc])
    }

    @Test func encodeFrameEmptyPayload() {
        let frame = C.encodeFrame(tag: .hello, payload: Data())
        // len = 1 (just the tag).
        #expect(Array(frame) == [0x00, 0x00, 0x00, 0x01, 0])
    }

    // MARK: - encodeHello

    @Test func encodeHelloLayout() {
        let frame = C.encodeHello()
        // BE len prefix (4) + tag(1) + u16 major LE + u16 minor LE + u32 id-len LE.
        // payload = [major=1 LE][minor=0 LE][id-len=0 LE] = 8 bytes; len = 9.
        #expect(Array(frame) == [
            0x00, 0x00, 0x00, 0x09,        // BE length = 9
            0,                             // tag hello
            0x01, 0x00,                    // major = 1 (LE)
            0x00, 0x00,                    // minor = 0 (LE)
            0x00, 0x00, 0x00, 0x00,        // identity_bundle_id length = 0 (LE)
        ])
    }

    // MARK: - encodeSubscribeRaw (u64 LE session_id)

    @Test func encodeSubscribeRawLayout() {
        let frame = C.encodeSubscribeRaw(0x0102030405060708)
        #expect(Array(frame) == [
            0x00, 0x00, 0x00, 0x09,        // BE length = 1 + 8
            31,                            // tag subscribe_raw
            0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01,  // u64 LE
        ])
    }

    @Test func encodeSubscribeRawZero() {
        let frame = C.encodeSubscribeRaw(0)
        #expect(Array(frame) == [0x00, 0x00, 0x00, 0x09, 31, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    // MARK: - decodeHelloAckMajor

    @Test func decodeHelloAckMajorReadsLE() {
        // major = 1 (LE), then minor + pid + epoch (we only need major).
        var p = Data()
        C.appendU16LE(&p, 1)
        C.appendU16LE(&p, 7)
        #expect(C.decodeHelloAckMajor(p) == 1)
    }

    @Test func decodeHelloAckMajorTooShortIsNil() {
        #expect(C.decodeHelloAckMajor(Data([0x01])) == nil)
        #expect(C.decodeHelloAckMajor(Data()) == nil)
    }

    // MARK: - decodeRawOutput (u64 LE session_id + [u32 LE len][bytes])

    @Test func decodeRawOutputRoundTrips() {
        var p = Data()
        C.appendU64LE(&p, 0xdeadbeef)
        let raw = Data("hello\u{1b}[31mworld".utf8)
        C.appendU32LE(&p, UInt32(raw.count))
        p.append(raw)
        let decoded = C.decodeRawOutput(p)
        #expect(decoded?.sessionID == 0xdeadbeef)
        #expect(decoded?.bytes == raw)
    }

    @Test func decodeRawOutputPreservesEmbeddedNulAndEsc() {
        // Raw PTY bytes are binary: embedded NUL (0x00) and ESC (0x1b) must
        // survive the decode verbatim (no C-string truncation at the NUL, no
        // escape-sequence mangling). Length is carried out-of-band by the u32
        // LE prefix, so the NUL is just another byte.
        var p = Data()
        C.appendU64LE(&p, 0x00ff)
        let raw = Data([0x1b, 0x5b, 0x33, 0x31, 0x6d,  // ESC [ 3 1 m
                        0x00,                            // embedded NUL
                        0x41, 0x00, 0x42,                // A NUL B
                        0x1b, 0x00])                     // ESC NUL (trailing)
        C.appendU32LE(&p, UInt32(raw.count))
        p.append(raw)
        let decoded = C.decodeRawOutput(p)
        #expect(decoded?.sessionID == 0x00ff)
        #expect(decoded?.bytes == raw)
        #expect(decoded?.bytes.count == raw.count)  // not truncated at the NUL
    }

    @Test func decodeRawOutputEmptyBytes() {
        var p = Data()
        C.appendU64LE(&p, 42)
        C.appendU32LE(&p, 0)
        let decoded = C.decodeRawOutput(p)
        #expect(decoded?.sessionID == 42)
        #expect(decoded?.bytes.isEmpty == true)
    }

    @Test func decodeRawOutputTruncatedIsNil() {
        // Claims 10 bytes but only 2 follow -> nil (not a crash/over-read).
        var p = Data()
        C.appendU64LE(&p, 1)
        C.appendU32LE(&p, 10)
        p.append(Data([0x41, 0x42]))
        #expect(C.decodeRawOutput(p) == nil)
        // Too short even for the session_id + length header.
        #expect(C.decodeRawOutput(Data([0x00, 0x01])) == nil)
    }

    // MARK: - FrameReader (partial-read reassembly)

    @Test func frameReaderYieldsCompleteFrame() throws {
        var reader = C.FrameReader()
        reader.push(C.encodeSubscribeRaw(99))
        let f = try reader.next()
        #expect(f?.tag == C.FrameTag.subscribeRaw.rawValue)
        #expect(C.readU64LE(f!.payload, at: f!.payload.startIndex) == 99)
        #expect(try reader.next() == nil)  // nothing more buffered
    }

    @Test func frameReaderPartialThenComplete() throws {
        let frame = C.encodeSubscribeRaw(7)
        var reader = C.FrameReader()
        // Feed only the first 3 bytes (less than the 4-byte length prefix).
        reader.push(frame.prefix(3))
        #expect(try reader.next() == nil)
        // Feed the rest; now a full frame is available.
        reader.push(frame.suffix(from: frame.index(frame.startIndex, offsetBy: 3)))
        let f = try reader.next()
        #expect(f?.tag == C.FrameTag.subscribeRaw.rawValue)
        #expect(C.readU64LE(f!.payload, at: f!.payload.startIndex) == 7)
    }

    @Test func frameReaderTwoFramesInOnePush() throws {
        var combined = C.encodeSubscribeRaw(1)
        combined.append(C.encodeSubscribeRaw(2))
        var reader = C.FrameReader()
        reader.push(combined)
        let f1 = try reader.next()
        let f2 = try reader.next()
        #expect(C.readU64LE(f1!.payload, at: f1!.payload.startIndex) == 1)
        #expect(C.readU64LE(f2!.payload, at: f2!.payload.startIndex) == 2)
        #expect(try reader.next() == nil)
    }

    @Test func frameReaderCompleteFramePlusTrailingPartial() throws {
        // One complete frame followed by a trailing PARTIAL frame whose 4-byte
        // length prefix is fully present but whose payload is incomplete: the
        // reader yields the complete frame, then nothing, until the remaining
        // payload bytes arrive.
        let first = C.encodeSubscribeRaw(11)
        let second = C.encodeSubscribeRaw(22)
        // Hold back the last 2 bytes of `second` (mid-payload, past its prefix).
        let cut = second.index(second.endIndex, offsetBy: -2)
        var combined = first
        combined.append(second[second.startIndex..<cut])

        var reader = C.FrameReader()
        reader.push(combined)
        let f1 = try reader.next()
        #expect(C.readU64LE(f1!.payload, at: f1!.payload.startIndex) == 11)
        // Second frame's prefix is buffered but its payload isn't complete yet.
        #expect(try reader.next() == nil)
        // Deliver the rest; the second frame now completes.
        reader.push(second[cut..<second.endIndex])
        let f2 = try reader.next()
        #expect(C.readU64LE(f2!.payload, at: f2!.payload.startIndex) == 22)
        #expect(try reader.next() == nil)
    }

    @Test func frameReaderDecodesRawOutputEndToEnd() throws {
        // Build a raw_output frame by hand and reassemble + decode it.
        let raw = Data("\u{1b}[32mok\u{1b}[0m".utf8)
        var payload = Data()
        C.appendU64LE(&payload, 5)
        C.appendU32LE(&payload, UInt32(raw.count))
        payload.append(raw)
        let frame = C.encodeFrame(tag: .rawOutput, payload: payload)

        var reader = C.FrameReader()
        // Split the frame across two pushes to exercise reassembly.
        let mid = frame.index(frame.startIndex, offsetBy: frame.count / 2)
        reader.push(frame[frame.startIndex..<mid])
        #expect(try reader.next() == nil)
        reader.push(frame[mid..<frame.endIndex])
        let f = try reader.next()
        #expect(f?.tag == C.FrameTag.rawOutput.rawValue)
        let decoded = C.decodeRawOutput(f!.payload)
        #expect(decoded?.sessionID == 5)
        #expect(decoded?.bytes == raw)
    }

    @Test func frameReaderRejectsOversizedLength() {
        var reader = C.FrameReader()
        // BE length prefix larger than maxFrameLen (64 MiB) -> throws.
        reader.push(Data([0xff, 0xff, 0xff, 0xff]))
        // do/catch (not #expect(throws:)) to avoid the @Sendable-closure
        // requirement capturing the mutable `var reader` (see SplitTreeTests).
        var threw = false
        do { _ = try reader.next() } catch { threw = true }
        #expect(threw)
    }

    @Test func frameReaderRejectsZeroLength() {
        var reader = C.FrameReader()
        // A length of 0 cannot even cover the mandatory tag byte.
        reader.push(Data([0x00, 0x00, 0x00, 0x00]))
        var threw = false
        do { _ = try reader.next() } catch { threw = true }
        #expect(threw)
    }

    // MARK: - scalar codec round-trips

    @Test func u32BERoundTrip() {
        var d = Data()
        C.appendU32BE(&d, 0x01020304)
        #expect(Array(d) == [0x01, 0x02, 0x03, 0x04])
        #expect(C.readU32BE(d, at: d.startIndex) == 0x01020304)
    }

    @Test func u64LERoundTrip() {
        var d = Data()
        C.appendU64LE(&d, 0x1122334455667788)
        #expect(Array(d) == [0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11])
        #expect(C.readU64LE(d, at: d.startIndex) == 0x1122334455667788)
    }
}

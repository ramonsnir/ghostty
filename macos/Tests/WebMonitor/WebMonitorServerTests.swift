import Foundation
import Testing
import CryptoKit
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

    @Test func keySpecsPageHomeEndAreNativeKeycodes() {
        // smartScroll sends PageUp/PageDown for alt-screen TUIs (less/man/vim)
        // that own the screen with no scrollback to wheel. These ride the native
        // macOS virtual keycode space (NSEvent.keyCode), NOT GHOSTTY_KEY_*:
        // PageUp=116, PageDown=121, Home=115, End=119.
        func spec(_ k: String) -> WebMonitorServer.KeySpec? {
            WebMonitorServer.keySpecs(forKey: k)?.first
        }
        #expect(spec("pageup") == WebMonitorServer.KeySpec(keycode: 116))
        #expect(spec("pagedown") == WebMonitorServer.KeySpec(keycode: 121))
        #expect(spec("home") == WebMonitorServer.KeySpec(keycode: 115))
        #expect(spec("end") == WebMonitorServer.KeySpec(keycode: 119))
        // Mods-free, like the other navigation keys.
        #expect(spec("pageup")?.mods == GHOSTTY_MODS_NONE)
        #expect(spec("pagedown")?.mods == GHOSTTY_MODS_NONE)
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

    @Test func keySpecsCtrlLetterIsRealCtrlKeyEvent() {
        // The desktop client needs the general ctrl-<letter> set (beyond the
        // explicit ctrl-c/ctrl-u): each maps to a Ctrl-modified key event with the
        // letter's NATIVE macOS virtual keycode (NSEvent.keyCode space) and the
        // letter's unshifted scalar.
        #expect(WebMonitorServer.keySpecs(forKey: "ctrl-d")
            == [WebMonitorServer.KeySpec(keycode: 2, mods: GHOSTTY_MODS_CTRL,
                                         unshiftedCodepoint: UInt32(UnicodeScalar("d").value))])
        // A few more letters map to their correct native keycodes (a=0, z=6, l=37).
        #expect(WebMonitorServer.keySpecs(forKey: "ctrl-a")
            == [WebMonitorServer.KeySpec(keycode: 0, mods: GHOSTTY_MODS_CTRL,
                                         unshiftedCodepoint: UInt32(UnicodeScalar("a").value))])
        #expect(WebMonitorServer.keySpecs(forKey: "ctrl-z")
            == [WebMonitorServer.KeySpec(keycode: 6, mods: GHOSTTY_MODS_CTRL,
                                         unshiftedCodepoint: UInt32(UnicodeScalar("z").value))])
        #expect(WebMonitorServer.keySpecs(forKey: "ctrl-l")
            == [WebMonitorServer.KeySpec(keycode: 37, mods: GHOSTTY_MODS_CTRL,
                                         unshiftedCodepoint: UInt32(UnicodeScalar("l").value))])
    }

    @Test func keySpecsCtrlLetterCoversAllTwentySixLetters() {
        // Exhaustive guard for the ctrl-<letter> keycode table — DESKTOP-MONITOR-DESIGN.md
        // Open Question #1 flags it as "the one place a wrong constant silently no-ops",
        // and the per-letter assertions above only sample a/d/z/l. Every a-z must map to a
        // NON-nil single spec carrying GHOSTTY_MODS_CTRL + the letter's own scalar, and the
        // 26 resulting NATIVE keycodes must be DISTINCT (a typo that duplicated or wrong-
        // valued one of the 22 unsampled letters — e.g. 'k'→'j' — would otherwise ship green).
        var keycodes: [UInt32] = []
        for c in "abcdefghijklmnopqrstuvwxyz" {
            let specs = WebMonitorServer.keySpecs(forKey: "ctrl-\(c)")
            #expect(specs != nil, "ctrl-\(c) must not be nil")
            #expect(specs?.count == 1, "ctrl-\(c) must be a single spec")
            guard let spec = specs?.first else { continue }
            #expect(spec.mods == GHOSTTY_MODS_CTRL, "ctrl-\(c) must carry ctrl")
            #expect(spec.unshiftedCodepoint == UInt32(c.unicodeScalars.first!.value),
                    "ctrl-\(c) must carry the letter's scalar")
            #expect(spec.text == nil, "ctrl-\(c) is a key event, not text")
            keycodes.append(spec.keycode)
        }
        #expect(keycodes.count == 26)
        // All 26 native keycodes are distinct (no collision / duplicated constant).
        #expect(Set(keycodes).count == 26, "ctrl-<letter> keycodes must all be distinct: \(keycodes)")
    }

    @Test func keySpecsCtrlCAndCtrlUUnchangedByGeneralRule() {
        // Regression: adding the general ctrl-<letter> rule must NOT change the
        // pre-existing ctrl-c / ctrl-u mappings (keycode 8 / 32 + ctrl + scalar).
        #expect(WebMonitorServer.keySpecs(forKey: "ctrl-c")
            == [WebMonitorServer.KeySpec(keycode: 8, mods: GHOSTTY_MODS_CTRL,
                                         unshiftedCodepoint: UInt32(UnicodeScalar("c").value))])
        #expect(WebMonitorServer.keySpecs(forKey: "ctrl-u")
            == [WebMonitorServer.KeySpec(keycode: 32, mods: GHOSTTY_MODS_CTRL,
                                         unshiftedCodepoint: UInt32(UnicodeScalar("u").value))])
    }

    @Test func keySpecsUnknownCtrlComboIsNil() {
        // A ctrl-<x> that is not a single a-z letter is unknown -> nil (a 400 at
        // the route), so bogus ctrl-combos still fail closed.
        #expect(WebMonitorServer.keySpecs(forKey: "ctrl-") == nil)
        #expect(WebMonitorServer.keySpecs(forKey: "ctrl-1") == nil)
        #expect(WebMonitorServer.keySpecs(forKey: "ctrl-cd") == nil)
        #expect(WebMonitorServer.keySpecs(forKey: "ctrl-tab") == nil)
    }

    @Test func keySpecsYNArePrintableText() {
        // y/n are just printable text: text-bearing, keycode unset (0),
        // unshiftedCodepoint = the scalar.
        #expect(WebMonitorServer.keySpecs(forKey: "y")
            == [WebMonitorServer.KeySpec(text: "y", unshiftedCodepoint: UInt32(UnicodeScalar("y").value))])
        #expect(WebMonitorServer.keySpecs(forKey: "n")
            == [WebMonitorServer.KeySpec(text: "n", unshiftedCodepoint: UInt32(UnicodeScalar("n").value))])
    }

    @Test func keySpecsSpaceIsPrintableSpace() {
        // The Space quick-key types a plain 0x20 (same byte a Space keypress
        // sends), riding the text path like y/n.
        #expect(WebMonitorServer.keySpecs(forKey: "space")
            == [WebMonitorServer.KeySpec(text: " ", unshiftedCodepoint: 0x20)])
    }

    @Test func keySpecsUnknownKey() {
        #expect(WebMonitorServer.keySpecs(forKey: "bogus") == nil)
    }

    @Test func keySpecsForTextCoalescesPrintableRun() {
        // A printable run becomes ONE multi-char text event (keycode unset), not
        // one event per character — otherwise a long message floods the 64-slot
        // IO mailbox and the middle is dropped. A multi-char run carries no single
        // scalar, so unshiftedCodepoint is 0; the text rides `text`.
        let s = WebMonitorServer.keySpecs(forText: "hi")
        #expect(s == [WebMonitorServer.KeySpec(text: "hi")])
        #expect(s.first?.keycode == 0)
        #expect(s.first?.text == "hi")
        // A long message is still a single event (the whole point of the fix).
        let long = String(repeating: "a", count: 80)
        let sl = WebMonitorServer.keySpecs(forText: long)
        #expect(sl.count == 1)
        #expect(sl.first?.text == long)
    }

    @Test func keySpecsForTextSingleCharKeepsScalar() {
        // A single-char run keeps its scalar in unshiftedCodepoint, byte-identical
        // to the pre-coalescing shape, so quick keys (y/n) are unchanged.
        #expect(WebMonitorServer.keySpecs(forText: "y") ==
            [WebMonitorServer.KeySpec(text: "y", unshiftedCodepoint: UInt32(UnicodeScalar("y").value))])
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
        // "hi\n" -> one coalesced printable run then an Enter (the newline
        // breaks the run and becomes a real Return).
        #expect(WebMonitorServer.keySpecs(forText: "hi\n") == [
            WebMonitorServer.KeySpec(text: "hi"),
            WebMonitorServer.KeySpec(keycode: 36),
        ])
        // A newline in the MIDDLE splits the run into two text events around a
        // Return (multi-line paste types each line and submits between them).
        #expect(WebMonitorServer.keySpecs(forText: "ab\ncd") == [
            WebMonitorServer.KeySpec(text: "ab"),
            WebMonitorServer.KeySpec(keycode: 36),
            WebMonitorServer.KeySpec(text: "cd"),
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
        // It is the typed text, NOT a key command — one coalesced printable run.
        let r = WebMonitorServer.keySpecs(
            body: Data("{x}".utf8),
            contentType: "text/plain; charset=utf-8")
        #expect(r == WebMonitorServer.keySpecs(forText: "{x}"))
        #expect(r == [WebMonitorServer.KeySpec(text: "{x}")])
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

    // MARK: - Per-identity loopback-port offset

    @Test func portOffsetByBundleID() {
        // Release (canonical id) keeps the configured port.
        #expect(WebMonitorServer.portOffset(forBundleID: "com.mitchellh.ghostty-ramon") == 0)
        // Dev builds shift up so they coexist with Release.
        #expect(WebMonitorServer.portOffset(forBundleID: "com.mitchellh.ghostty-ramon.local") == 1)
        #expect(WebMonitorServer.portOffset(forBundleID: "com.mitchellh.ghostty-ramon.debug") == 2)
        // Unknown / missing bundle id ⇒ no shift.
        #expect(WebMonitorServer.portOffset(forBundleID: nil) == 0)
        #expect(WebMonitorServer.portOffset(forBundleID: "com.example.other") == 0)
    }

    @Test func applyPortOffsetShifts() {
        let base = WebMonitorServer.parseListen("127.0.0.1:18787")
        #expect(WebMonitorServer.applyPortOffset(base, offset: 0)?.port == 18787)
        #expect(WebMonitorServer.applyPortOffset(base, offset: 1)?.port == 18788)
        #expect(WebMonitorServer.applyPortOffset(base, offset: 2)?.port == 18789)
        // Host is preserved.
        #expect(WebMonitorServer.applyPortOffset(base, offset: 1)?.host == "127.0.0.1")
    }

    @Test func applyPortOffsetEdgeCases() {
        // Nothing to parse ⇒ nil through.
        #expect(WebMonitorServer.applyPortOffset(nil, offset: 1) == nil)
        // Overflow near the ceiling ⇒ original kept, never wrapped.
        let high = WebMonitorServer.parseListen("127.0.0.1:65535")
        #expect(WebMonitorServer.applyPortOffset(high, offset: 1)?.port == 65535)
        #expect(WebMonitorServer.applyPortOffset(high, offset: 2)?.port == 65535)
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

    @Test func hostHeaderTailscaleServeMagicDNSAllowed() {
        // tailscale serve forwards the original `<machine>.<tailnet>.ts.net:<external>`
        // Host (external port != our internal bind port), so it must be accepted
        // regardless of the configured (loopback) host/port.
        #expect(WebMonitorServer.hostHeaderAllowed(
            "ramons-macbook-pro-1.tailf8e7e3.ts.net:8787",
            configuredHost: "127.0.0.1", configuredPort: 18787))
        // Case-insensitive, and the default-443 (no explicit port) form.
        #expect(WebMonitorServer.hostHeaderAllowed(
            "Machine.Tailnet.TS.NET", configuredHost: "127.0.0.1", configuredPort: 18787))
        // A look-alike that only ends with the suffix as a different TLD is rejected.
        #expect(!WebMonitorServer.hostHeaderAllowed(
            "evil-ts.net:8787", configuredHost: "127.0.0.1", configuredPort: 18787))
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

    /// Decode the `{agentDashboard, surfaces}` envelope to its surfaces array.
    private func surfacesArray(_ d: Data) throws -> [[String: Any]]? {
        let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any]
        return obj?["surfaces"] as? [[String: Any]]
    }

    @Test func surfacesJSONEmpty() throws {
        let d = WebMonitorServer.surfacesJSONData([], agentDashboard: false)
        let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any]
        #expect(obj?["agentDashboard"] as? Bool == false)
        #expect((obj?["surfaces"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test func surfacesJSONShape() throws {
        let d = WebMonitorServer.surfacesJSONData([
            .init(id: "id-1", title: "Title One", pwd: "/home/x",
                  window: 0, tab: 0, tabTitle: "Tab A", splitIndex: 0, splitCount: 2,
                  bell: false, attentionNeeded: false, isAgent: false, hidden: false),
            .init(id: "id-2", title: "", pwd: "",
                  window: 0, tab: 0, tabTitle: "Tab A", splitIndex: 1, splitCount: 2,
                  bell: true, attentionNeeded: false, isAgent: false, hidden: false),
        ], agentDashboard: true)
        let arr = try surfacesArray(d)
        #expect(arr?.count == 2)
        #expect(arr?[0]["id"] as? String == "id-1")
        #expect(arr?[0]["title"] as? String == "Title One")
        #expect(arr?[0]["pwd"] as? String == "/home/x")
        #expect(arr?[0]["bell"] as? Bool == false)
        #expect(arr?[1]["title"] as? String == "")
        #expect(arr?[1]["bell"] as? Bool == true)
    }

    // (Hero Agents) The row's `hero` flag is emitted so the page can purple-star a hero split
    // and drive the "Focus on heroes" filter.
    @Test func surfacesJSONEmitsHero() throws {
        let d = WebMonitorServer.surfacesJSONData([
            .init(id: "h-1", title: "Hero", pwd: "", window: 0, tab: 0, tabTitle: "T",
                  splitIndex: 0, splitCount: 1, bell: false, attentionNeeded: false,
                  isAgent: true, hidden: false, hero: true),
            .init(id: "r-1", title: "Regular", pwd: "", window: 0, tab: 0, tabTitle: "T",
                  splitIndex: 0, splitCount: 1, bell: false, attentionNeeded: false,
                  isAgent: true, hidden: false),
        ], agentDashboard: true)
        let arr = try surfacesArray(d)
        #expect(arr?[0]["hero"] as? Bool == true)
        #expect(arr?[1]["hero"] as? Bool == false)  // default when omitted
    }

    // (Bell Attention v2) Each row carries the raw bell + attentionNeeded (truthful)
    // and a monitor-tier-routed `attnIndicator` = (bell && monitorBell) ||
    // (attentionNeeded && monitorAttn). Default flags (both true) ⇒ bell || attention.
    @Test func surfacesJSONCarriesAttentionAndIndicatorDefault() throws {
        let d = WebMonitorServer.surfacesJSONData([
            .init(id: "bell", title: "b", pwd: "", window: 0, tab: 0, tabTitle: "",
                  splitIndex: 0, splitCount: 1, bell: true, attentionNeeded: false,
                  isAgent: false, hidden: false),
            .init(id: "attn", title: "a", pwd: "", window: 0, tab: 0, tabTitle: "",
                  splitIndex: 0, splitCount: 1, bell: false, attentionNeeded: true,
                  isAgent: false, hidden: false),
            .init(id: "none", title: "n", pwd: "", window: 0, tab: 0, tabTitle: "",
                  splitIndex: 0, splitCount: 1, bell: false, attentionNeeded: false,
                  isAgent: false, hidden: false),
        ], agentDashboard: false)
        let arr = try surfacesArray(d)
        #expect(arr?[0]["attentionNeeded"] as? Bool == false)
        #expect(arr?[0]["attnIndicator"] as? Bool == true)   // raw bell
        #expect(arr?[1]["attentionNeeded"] as? Bool == true)
        #expect(arr?[1]["attnIndicator"] as? Bool == true)   // promotion
        #expect(arr?[2]["attnIndicator"] as? Bool == false)  // neither
    }

    // monitor OFF the bell tier: a raw bell no longer lights the indicator, but a
    // promotion (monitorAttn on) still does.
    @Test func surfacesJSONIndicatorRoutedByMonitorFlags() throws {
        let rows: [WebMonitorServer.SurfaceRow] = [
            .init(id: "bell", title: "b", pwd: "", window: 0, tab: 0, tabTitle: "",
                  splitIndex: 0, splitCount: 1, bell: true, attentionNeeded: false,
                  isAgent: false, hidden: false),
            .init(id: "attn", title: "a", pwd: "", window: 0, tab: 0, tabTitle: "",
                  splitIndex: 0, splitCount: 1, bell: false, attentionNeeded: true,
                  isAgent: false, hidden: false),
        ]
        let d = WebMonitorServer.surfacesJSONData(
            rows, agentDashboard: false, monitorBell: false, monitorAttn: true)
        let arr = try surfacesArray(d)
        #expect(arr?[0]["attnIndicator"] as? Bool == false)  // raw bell suppressed
        #expect(arr?[1]["attnIndicator"] as? Bool == true)   // promotion still shows
    }

    @Test func surfacesJSONCarriesLayout() throws {
        // The grouping fields (window/tab/tabTitle/splitIndex/splitCount) let the
        // phone list show how panes are organized on the Mac.
        let d = WebMonitorServer.surfacesJSONData([
            .init(id: "a", title: "A", pwd: "", window: 1, tab: 2,
                  tabTitle: "Editor", splitIndex: 0, splitCount: 3,
                  bell: false, attentionNeeded: false, isAgent: false, hidden: false),
        ], agentDashboard: false)
        let arr = try surfacesArray(d)
        #expect(arr?[0]["window"] as? Int == 1)
        #expect(arr?[0]["tab"] as? Int == 2)
        #expect(arr?[0]["tabTitle"] as? String == "Editor")
        #expect(arr?[0]["splitIndex"] as? Int == 0)
        #expect(arr?[0]["splitCount"] as? Int == 3)
    }

    @Test func surfacesJSONEscapesHostileChars() throws {
        // JSON-hostile: double quote, backslash, newline, and a multibyte emoji.
        // Proper escaping means the bytes round-trip back byte-identical.
        let hostileTitle = "a\"b\\c\nd\u{1F600}e"
        let hostilePwd = "/tmp/\"quoted\"\\back\nslash\u{1F4A9}"
        let d = WebMonitorServer.surfacesJSONData([
            .init(id: "id-1", title: hostileTitle, pwd: hostilePwd,
                  window: 0, tab: 0, tabTitle: "", splitIndex: 0, splitCount: 1,
                  bell: false, attentionNeeded: false, isAgent: false, hidden: false),
        ], agentDashboard: false)
        let arr = try surfacesArray(d)
        #expect(arr?.count == 1)
        #expect(arr?[0]["title"] as? String == hostileTitle)
        #expect(arr?[0]["pwd"] as? String == hostilePwd)
    }

    @Test func surfacesJSONCarriesAgentDashboardFlag() throws {
        // The top-level flag tells the page whether the agent/hidden filters are
        // usable (the Agent Dashboard is running).
        let on = try JSONSerialization.jsonObject(
            with: WebMonitorServer.surfacesJSONData([], agentDashboard: true)) as? [String: Any]
        #expect(on?["agentDashboard"] as? Bool == true)
        let off = try JSONSerialization.jsonObject(
            with: WebMonitorServer.surfacesJSONData([], agentDashboard: false)) as? [String: Any]
        #expect(off?["agentDashboard"] as? Bool == false)
    }

    @Test func surfacesJSONCarriesAgentAndHiddenFlags() throws {
        // Per-row agent/hidden flags drive the page's "agents only" / "hide hidden"
        // filters; they're emitted unconditionally as plain bools.
        let d = WebMonitorServer.surfacesJSONData([
            .init(id: "agent-shown", title: "claude", pwd: "", window: 0, tab: 0,
                  tabTitle: "", splitIndex: 0, splitCount: 1,
                  bell: false, attentionNeeded: false, isAgent: true, hidden: false),
            .init(id: "agent-hidden", title: "codex", pwd: "", window: 0, tab: 0,
                  tabTitle: "", splitIndex: 0, splitCount: 1,
                  bell: false, attentionNeeded: false, isAgent: true, hidden: true),
            .init(id: "plain", title: "zsh", pwd: "", window: 0, tab: 0,
                  tabTitle: "", splitIndex: 0, splitCount: 1,
                  bell: false, attentionNeeded: false, isAgent: false, hidden: false),
        ], agentDashboard: true)
        let arr = try surfacesArray(d)
        #expect(arr?.count == 3)
        #expect(arr?[0]["isAgent"] as? Bool == true)
        #expect(arr?[0]["hidden"] as? Bool == false)
        #expect(arr?[1]["isAgent"] as? Bool == true)
        #expect(arr?[1]["hidden"] as? Bool == true)
        #expect(arr?[2]["isAgent"] as? Bool == false)
        #expect(arr?[2]["hidden"] as? Bool == false)
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

    // MARK: - Unified page: responsive + capability-adaptive markers
    //
    // Stage 1 unified the phone + desktop clients into ONE responsive page served
    // at GET "/"; the /desktop route + desktopHtmlPage are gone. These guard the
    // features the single page now carries for BOTH form factors. (The phone-only
    // guards further down — bell/token/scroll/etc. — still apply to this same page.)

    @Test func htmlPageHasResponsiveSidebar() {
        // The persistent split-picker sidebar + the flex viewer, driven by a #app
        // `data-view` state machine with an 860px breakpoint: wide keeps both panes,
        // narrow (<860px, the phone drawer) shows one at a time. Selecting a surface
        // swaps the VIEWER, never hides the list.
        let page = WebMonitorServer.htmlPage
        #expect(page.contains("id=\"app\" data-view=\"list\""))
        #expect(page.contains("data-view=\"surface\""))
        #expect(page.contains("@media (max-width: 859px)"))   // the narrow breakpoint
        #expect(page.contains("id=\"sidebar\""))
        #expect(page.contains("id=\"main\""))
        #expect(page.contains("id=\"list\""))
        // The active-row highlight tells you which split the viewer is driving.
        #expect(page.contains("function highlightActive"))
        #expect(page.contains("data-id"))
        // Single-surface invariant: dispose the old stream before opening the new.
        #expect(page.contains("disposeStream"))
        #expect(page.contains("stream = openStream(id)"))
    }

    @Test func htmlPageReusesXtermAssets() {
        // Reuses the SAME vendored assets + streaming/frame path — no new routes.
        let page = WebMonitorServer.htmlPage
        #expect(page.contains("/xterm.js"))
        #expect(page.contains("/xterm.css"))
        #expect(page.contains("/jetbrains-mono-regular.woff2"))
        #expect(page.contains("/jetbrains-mono-bold.woff2"))
        #expect(page.contains("function openStream"))
        #expect(page.contains("/stream"))
        #expect(page.contains("X-Ghostty-Cols"))
        #expect(page.contains("X-Ghostty-Rows"))
        #expect(page.contains("function enterFrameMode"))
        #expect(page.contains("function paintFrame"))
        #expect(page.contains("function exitFrameMode"))
        #expect(page.contains("/frame"))
    }

    @Test func htmlPageHasGlobalKeydownWiring() {
        // A CAPTURE-phase global keydown handler maps browser keystrokes to /input,
        // including the general ctrl-<letter> path (derived from KeyboardEvent.code).
        let page = WebMonitorServer.htmlPage
        #expect(page.contains("addEventListener(\"keydown\", function (e) {"))
        #expect(page.contains("}, true);"))                 // CAPTURE phase
        #expect(page.contains("function keyNameFor"))
        #expect(page.contains("sendKey(\"ctrl-\" + code.slice(3).toLowerCase())"))
        #expect(page.contains("/^Key[A-Z]$/.test(code)"))   // derive from KeyboardEvent.code
        // The form-control guard: the handler must NOT steal keys from a focused UI
        // control (sidebar filter checkboxes, the mode <select>, buttons, the Send
        // field), while still letting xterm's own helper textarea (the focused
        // terminal) fall through. The xterm exception is load-bearing, so pin the
        // actual GUARD expression (a classList.contains check) — matching the bare
        // string would be satisfied by the code comment alone.
        #expect(page.contains("classList.contains(\"xterm-helper-textarea\")"))
        // All six focusable form-control tags must bail (only SELECT was pinned
        // before — a dropped tag would silently steal that control's keystrokes).
        #expect(page.contains("tag === \"INPUT\""))
        #expect(page.contains("tag === \"SELECT\""))
        #expect(page.contains("tag === \"TEXTAREA\""))
        #expect(page.contains("tag === \"BUTTON\""))
        #expect(page.contains("tag === \"OPTION\""))
        #expect(page.contains("tag === \"A\""))
        #expect(page.contains("function queueType"))         // printable batching
        #expect(page.contains("function flushType"))
        // ⌘ is repurposed for clipboard/selection, not forwarded to the shell.
        #expect(page.contains("if (e.metaKey)"))
        #expect(page.contains("stream.term.selectAll()"))
    }

    @Test func htmlPageHasCopyPasteHooks() {
        // Browser clipboard via the native DOM events (⌘C / ⌘X / ⌘V), NOT a button:
        // copy/cut write the xterm selection onto the event's clipboardData; paste
        // routes the pasted text through the text/plain /input path.
        let page = WebMonitorServer.htmlPage
        #expect(page.contains("addEventListener(\"paste\""))
        #expect(page.contains("addEventListener(\"copy\""))
        #expect(page.contains("addEventListener(\"cut\""))
        #expect(page.contains("getData(\"text\")"))
        #expect(page.contains("stream.term.getSelection()"))
        // Copy/cut put the selection on the clipboard synchronously via the event
        // (clipboardData.setData), which works without a secure context — so there is
        // NO navigator.clipboard write and NO Copy button anymore.
        #expect(page.contains("e.clipboardData.setData(\"text/plain\", sel)"))
        #expect(!page.contains("copyBtn"))
        #expect(!page.contains("id=\"copybtn\""))
        #expect(!page.contains("navigator.clipboard.writeText"))
        // Pin the paste handler's DESTINATION, not just that it listens: a paste must
        // route through sendText(...) (the text/plain /input path) and bail via
        // isTypingField so pasting into the Send field doesn't also fire into the
        // surface. Mis-routing the paste is a documented load-bearing hazard, and the
        // listener-only assertions above would stay green through such a regression.
        if let start = page.range(of: "addEventListener(\"paste\"")?.lowerBound,
           let end = page.range(of: "function flashTap", range: start..<page.endIndex)?.lowerBound {
            let body = String(page[start..<end])
            #expect(body.contains("isTypingField(e.target)"))   // Send field pastes into itself
            #expect(body.contains("getData(\"text\")"))
            #expect(body.contains("sendText(t)"))               // -> text/plain /input path
        } else {
            Issue.record("paste handler not found in htmlPage")
        }
    }

    @Test func htmlPageHasReconnectOnRefocus() {
        // A UNIVERSAL visibilitychange handler resyncs the live stream on foreground
        // (dispose + re-open via showSurface) so a backgrounded tab that stalled the
        // stream recovers.
        let page = WebMonitorServer.htmlPage
        #expect(page.contains("addEventListener(\"visibilitychange\""))
        #expect(page.contains("document.visibilityState === \"visible\""))
        // The resync is gated ONLY on `current` (a surface is being viewed), then
        // showSurface disposes + re-opens the stream.
        #expect(page.contains("if (current) { showSurface(current, curEl.textContent, false); }"))
        // NEGATIVE guard against the regression the governance change forbids: the
        // handler must NO LONGER bail early when a stream is already live. The old
        // early-bail would test `stream`; the correct handler references only
        // `current`/`showSurface`/`loadList`/`timer` and never `stream`. Slice the
        // handler body (up to its closing `});`) and assert `stream` never appears —
        // so re-adding `if (stream) return;` fails this test.
        if let start = page.range(of: "addEventListener(\"visibilitychange\"")?.lowerBound,
           let end = page.range(of: "});", range: start..<page.endIndex)?.upperBound {
            let body = String(page[start..<end])
            #expect(!body.contains("stream"))
        } else {
            Issue.record("visibilitychange handler not found in htmlPage")
        }
    }

    @Test func htmlPageHasThemeAwareChromeAndPollFallback() {
        // Theme-aware CHROME only (the terminal colors come from the ANSI stream),
        // and the /screen poll viewer is the fallback when the live stream is down.
        let page = WebMonitorServer.htmlPage
        #expect(page.contains("@media (prefers-color-scheme: light)"))
        #expect(page.contains("function fallbackToPoll"))
        #expect(page.contains("/screen"))
        #expect(page.contains("id=\"screen\""))
    }

    @Test func htmlPageDataViewStateMachineTransitions() {
        // The narrow drawer hinges on the state-machine FLIPS, not just the initial
        // attribute: showSurface sets #app data-view="surface" and showPlaceholder
        // sets it back to "list". Without them a phone (<860px) selecting a surface
        // leaves the viewer hidden by #app[data-view="list"] #main{display:none} — a
        // total break of the drawer.
        let page = WebMonitorServer.htmlPage
        #expect(page.contains("app.dataset.view = \"surface\""))   // showSurface
        #expect(page.contains("app.dataset.view = \"list\""))      // showPlaceholder
    }

    @Test func htmlPageSidebarHideRuleIsNarrowOnly() {
        // The "selecting a surface hides the sidebar" rule MUST stay inside the narrow
        // @media block — on wide the sidebar is ALWAYS visible (it swaps the viewer
        // without hiding the list). If the rule leaked out of the media query, a wide
        // screen would lose its persistent picker on select.
        let page = WebMonitorServer.htmlPage
        let media = page.range(of: "@media (max-width: 859px) {")
        let rule = page.range(of: "#app[data-view=\"surface\"] #sidebar { display: none; }")
        let styleClose = page.range(of: "</style>")
        #expect(media != nil && rule != nil && styleClose != nil)
        if let m = media, let r = rule, let s = styleClose {
            #expect(m.lowerBound < r.lowerBound)   // rule is inside/after the narrow query
            #expect(r.lowerBound < s.lowerBound)   // ...and still within the stylesheet
        }
    }

    @Test func htmlPageViewHeaderWrapsOnNarrow() {
        // #viewhdr must flex-wrap (its fixed children — menu + title + Copy + Clear —
        // can exceed a phone width) so the header never scrolls the page body sideways.
        let page = WebMonitorServer.htmlPage
        #expect(page.contains("#viewhdr { display: flex; flex-wrap: wrap;"))
    }

    @Test func htmlPageBannersAreTopLevelChrome() {
        // #banner + #notice live OUTSIDE #main (above #app) so a status message /
        // token-recovery notice stays visible in the narrow list-view drawer, where
        // #main is display:none. Guards the regression where they were nested in #main
        // and vanished on the phone list.
        let page = WebMonitorServer.htmlPage
        let banner = page.range(of: "<div id=\"banner\"")
        let notice = page.range(of: "<div id=\"notice\"")
        let appDiv = page.range(of: "<div id=\"app\" data-view=\"list\">")
        #expect(banner != nil && notice != nil && appDiv != nil)
        if let b = banner, let a = appDiv { #expect(b.lowerBound < a.lowerBound) }  // banner precedes #app
        if let n = notice, let a = appDiv { #expect(n.lowerBound < a.lowerBound) }  // notice precedes #app
    }

    @Test func htmlPageHasBackToListControl() {
        // The narrow drawer's "reopen the list" affordance: a #menubtn whose handler
        // returns to the picker (showPlaceholder + loadList). Without it a phone user
        // is stranded in the viewer with no way back to the session list.
        let page = WebMonitorServer.htmlPage
        #expect(page.contains("id=\"menubtn\""))
        #expect(page.contains("menuBtn.onclick = function () {"))
    }

    @Test func htmlPageKeydownBailsInTypingFields() {
        // The global keydown driver must bail inside our own Send/token fields (the
        // "must bail inside typing fields" half of the guard) so a reply / a pasted
        // token typed into those fields isn't ALSO fired into the surface.
        let page = WebMonitorServer.htmlPage
        #expect(page.contains("function isTypingField"))
        #expect(page.contains("if (isTypingField(e.target)) return;"))
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

    @Test func decideRouteScrollPost() {
        let id = UUID()
        #expect(decide("POST", "/api/surface/\(id.uuidString)/scroll") == .scroll(uuid: id))
    }

    @Test func decideRouteScrollGetMethodNotAllowed() {
        let id = UUID()
        #expect(decide("GET", "/api/surface/\(id.uuidString)/scroll") == .methodNotAllowed)
    }

    @Test func decideRouteClearBellPost() {
        let id = UUID()
        #expect(decide("POST", "/api/surface/\(id.uuidString)/bell") == .clearBell(uuid: id))
    }

    @Test func decideRouteClearBellGetMethodNotAllowed() {
        let id = UUID()
        #expect(decide("GET", "/api/surface/\(id.uuidString)/bell") == .methodNotAllowed)
    }

    // (Bell Attention v2) The attention-clear route mirrors the bell-clear route.
    @Test func decideRouteClearAttentionPost() {
        let id = UUID()
        #expect(decide("POST", "/api/surface/\(id.uuidString)/attention") == .clearAttention(uuid: id))
    }

    @Test func decideRouteClearAttentionGetMethodNotAllowed() {
        let id = UUID()
        #expect(decide("GET", "/api/surface/\(id.uuidString)/attention") == .methodNotAllowed)
    }

    @Test func scrollDeltaYDecode() {
        #expect(WebMonitorServer.scrollDeltaY(body: Data(#"{"dy":3}"#.utf8)) == 3)
        #expect(WebMonitorServer.scrollDeltaY(body: Data(#"{"dy":-5}"#.utf8)) == -5)
        #expect(WebMonitorServer.scrollDeltaY(body: Data(#"{"dy":0}"#.utf8)) == nil)     // zero -> nil
        #expect(WebMonitorServer.scrollDeltaY(body: Data(#"{"dy":999}"#.utf8)) == 30)    // clamped
        #expect(WebMonitorServer.scrollDeltaY(body: Data(#"{}"#.utf8)) == nil)           // missing
        #expect(WebMonitorServer.scrollDeltaY(body: Data("not json".utf8)) == nil)
    }

    // (ramon fork / Web monitor) Host authoritative ANSI frame route (for scrolling
    // a full-screen app without xterm.js re-emulation drift).
    @Test func decideRouteFrameGet() {
        let id = UUID()
        #expect(decide("GET", "/api/surface/\(id.uuidString)/frame") == .frame(uuid: id))
    }

    @Test func decideRouteFramePostMethodNotAllowed() {
        let id = UUID()
        #expect(decide("POST", "/api/surface/\(id.uuidString)/frame") == .methodNotAllowed)
    }

    // (ramon fork / Web monitor) Scroll cursor-seed flag: only the first scroll of a
    // viewing seeds (positions the cursor), so a mouse-reporting TUI's scrolls accumulate.
    @Test func scrollSeedDecode() {
        #expect(WebMonitorServer.scrollSeed(body: Data(#"{"dy":3,"seed":true}"#.utf8)) == true)
        #expect(WebMonitorServer.scrollSeed(body: Data(#"{"dy":3,"seed":false}"#.utf8)) == false)
        #expect(WebMonitorServer.scrollSeed(body: Data(#"{"dy":3}"#.utf8)) == false)   // absent ⇒ no seed
        #expect(WebMonitorServer.scrollSeed(body: Data(#"{"dy":3,"seed":1}"#.utf8)) == true)  // lenient
        #expect(WebMonitorServer.scrollSeed(body: Data("not json".utf8)) == false)
    }

    // (ramon fork / Web monitor) Hide-a-split-from-the-phone route + body parse.
    @Test func decideRouteSetHiddenPost() {
        let id = UUID()
        #expect(decide("POST", "/api/surface/\(id.uuidString)/hidden") == .setHidden(uuid: id))
    }

    @Test func decideRouteSetHiddenGetMethodNotAllowed() {
        let id = UUID()
        #expect(decide("GET", "/api/surface/\(id.uuidString)/hidden") == .methodNotAllowed)
    }

    @Test func hiddenFlagDecode() {
        #expect(WebMonitorServer.hiddenFlag(body: Data(#"{"hidden":true}"#.utf8)) == true)
        #expect(WebMonitorServer.hiddenFlag(body: Data(#"{"hidden":false}"#.utf8)) == false)
        #expect(WebMonitorServer.hiddenFlag(body: Data(#"{"hidden":1}"#.utf8)) == true)   // lenient number
        #expect(WebMonitorServer.hiddenFlag(body: Data(#"{"hidden":0}"#.utf8)) == false)
        #expect(WebMonitorServer.hiddenFlag(body: Data(#"{"hidden":"true"}"#.utf8)) == true)   // lenient string
        #expect(WebMonitorServer.hiddenFlag(body: Data(#"{"hidden":"false"}"#.utf8)) == false)
        #expect(WebMonitorServer.hiddenFlag(body: Data(#"{}"#.utf8)) == nil)              // missing
        #expect(WebMonitorServer.hiddenFlag(body: Data("not json".utf8)) == nil)
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

    @Test func decideRouteDesktopPathIsNotFound() {
        // The old standalone desktop client (/desktop route + RouteDecision.desktopPage +
        // desktopHtmlPage) is REMOVED — the single responsive htmlPage at "/" now serves
        // both phone and desktop. Pin the exact "/desktop" path so a re-added `.desktopPage`
        // branch (which the generic /totally/unknown probe would slip past) fails here.
        #expect(decide("GET", "/desktop") == .notFound)
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

    @Test func htmlPageUsesDynamicViewportForKeyboard() {
        let page = WebMonitorServer.htmlPage
        // The soft keyboard must shrink the layout (resizes-content) and the
        // terminal heights must track it (dvh), else the terminal reserves
        // full-height space and shoves the controls off-screen when typing.
        #expect(page.contains("interactive-widget=resizes-content"))
        #expect(page.contains("dvh"))
    }

    @Test func htmlPageHasClearBellButton() {
        let page = WebMonitorServer.htmlPage
        // A clear-bell button + its handler must exist so a phone can acknowledge
        // a bell (POST .../bell) without focusing the surface locally, and the
        // list flags surfaces whose bell is still ringing.
        #expect(page.contains("id=\"clearbell\""))
        #expect(page.contains("clearBellBtn.onclick"))
        #expect(page.contains("/bell"))
        #expect(page.contains("bellflag"))
        #expect(page.contains("row.bell"))
    }

    @Test func htmlPageHasAgentFilters() {
        let page = WebMonitorServer.htmlPage
        // All THREE agent filters (checkboxes), their persistence, and the disabled
        // handling when the dashboard isn't running must all be wired in the page.
        #expect(page.contains("id=\"filterbar\""))
        #expect(page.contains("id=\"f-heroes\""))
        #expect(page.contains("id=\"f-agents\""))
        #expect(page.contains("id=\"f-visible\""))
        #expect(page.contains("applyFilterAvailability"))
        // Filters read the new response envelope, default ON, and persist.
        #expect(page.contains("data.surfaces"))
        #expect(page.contains("data.agentDashboard"))
        #expect(page.contains("ghostty_filter_heroes"))
        #expect(page.contains("ghostty_filter_agents"))
        #expect(page.contains("ghostty_filter_visible"))
        #expect(page.contains("row.isAgent"))
        #expect(page.contains("row.hidden"))
        // "Hide hidden" only layers on "Agents only": it's disabled when agents-only
        // is off, and the hide filter is gated behind agentsOnly (so hidden splits
        // are shown when agents-only is off). It is ALSO disabled under heroes-focus
        // (heroFocus), which overrides the other two to show ONLY heroes.
        #expect(page.contains("fVisible.disabled = !dashboard || heroFocus || !fAgents.checked"))
        #expect(page.contains("var hideHidden = agentsOnly && fVisible.checked"))
    }

    @Test func htmlPageControlsAreCompact() {
        let page = WebMonitorServer.htmlPage
        // Space quick-key (next to Enter) — useful in Claude Code.
        #expect(page.contains("data-key=\"space\""))
        // Vertical-space savings: wrap + font-size controls and the 1-4 digit
        // quick-keys were removed (key+Send covers the digits).
        #expect(!page.contains("id=\"wrap\""))
        #expect(!page.contains("id=\"fontsize\""))
        #expect(!page.contains("data-raw"))
    }

    @Test func htmlPageGroupsListByTabWithWindowOmission() {
        let page = WebMonitorServer.htmlPage
        // The list is grouped by window+tab, with a multi-line header (location
        // line + wrapping title line).
        #expect(page.contains("grouphdr"))
        #expect(page.contains("\"loc\""))
        #expect(page.contains("\"ttl\""))
        // "Window N" is only prefixed when more than one window group exists.
        #expect(page.contains("multiWin"))
        #expect(page.contains("Object.keys(winSet).length > 1"))
        // Multi-split tabs badge each pane "split i/n".
        #expect(page.contains("\"badge\""))
        #expect(page.contains("\"split \""))
    }

    @Test func htmlPageHasSmartScroll() {
        let page = WebMonitorServer.htmlPage
        // The scroll buttons + PageUp/PageDown drive smartScroll. Unification note:
        // smartScroll ALWAYS uses FRAME MODE when a live xterm is present — it drives
        // a real HOST wheel (which the host routes per the app's true mode) and paints
        // the host's AUTHORITATIVE frame, rather than scrolling xterm.js locally (the
        // old baseY-based local/alt-screen branching drifted + garbled and was removed).
        #expect(page.contains("function smartScroll"))
        #expect(page.contains("smartScroll(1)"))
        #expect(page.contains("smartScroll(-1)"))
        // No live term -> a bare host wheel (the poll fallback reads the scrolled mirror).
        #expect(page.contains("if (!(stream && stream.term)) { sendScroll(dir * 3, seed); return; }"))
        // With a live term: enter frame mode, drive the host wheel, then paint the frame.
        #expect(page.contains("enterFrameMode();"))
        #expect(page.contains("setTimeout(paintFrame, 120);"))
        // The removed local-scroll / alt-screen-mode branching must NOT reappear.
        #expect(!page.contains("term.scrollLines(dir > 0 ? -3 : 3)"))
        #expect(!page.contains("mouseTrackingMode"))
        // The stream handle exposes `term` so smartScroll can gate on a live xterm.
        #expect(page.contains("dispose: teardown, term: term"))
    }

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
        #expect(page.contains("if (r && r.status === 404) { sessionClosedTeardown(); return; }"))
    }

    @Test func htmlPageCtrlCQuickKeyIsDestyled() {
        let page = WebMonitorServer.htmlPage
        // Ctrl-C sits beside benign keys (y/n/Esc); it gets a danger style + a
        // left gap so it is not a one-tap fat-finger neighbor.
        #expect(page.contains("<button data-key=\"ctrl-c\" class=\"danger\">Ctrl-C</button>"))
        #expect(page.contains("button.danger {"))
        #expect(page.contains("margin-left: 12px"))
    }

    @Test func htmlPageSuccessfulSendIsSilent() {
        let page = WebMonitorServer.htmlPage
        // A successful send shows NO banner: the global keydown driver calls
        // reportSend per keystroke, and the typed character already appears on the
        // terminal, so a per-keypress "Sent." toast is just noise + a layout shift.
        // Only failures surface. Guards the regression where success set a banner.
        #expect(!page.contains("setBanner(\"Sent.\""))
        #expect(page.contains("if (r && r.ok) return;"))
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
        // The vendored JetBrains Mono Nerd Font (woff2, Regular + Bold) served so
        // the page matches Ghostty's own font.
        let fontReg = WebMonitorServer.assetRoutes["/jetbrains-mono-regular.woff2"]
        #expect(fontReg?.name == "JetBrainsMonoNerdFont-Regular")
        #expect(fontReg?.ext == "woff2")
        #expect(fontReg?.contentType == "font/woff2")
        let fontBold = WebMonitorServer.assetRoutes["/jetbrains-mono-bold.woff2"]
        #expect(fontBold?.name == "JetBrainsMonoNerdFont-Bold")
        #expect(fontBold?.ext == "woff2")
        #expect(fontBold?.contentType == "font/woff2")
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
        // The font assets are reached from @font-face src url() (no custom header
        // possible), so they too accept ?token= via the bootstrap set.
        #expect(WebMonitorServer.isBootstrapPath("/jetbrains-mono-regular.woff2"))
        #expect(WebMonitorServer.isBootstrapPath("/jetbrains-mono-bold.woff2"))
        #expect(!WebMonitorServer.isBootstrapPath("/api/surfaces"))
        #expect(!WebMonitorServer.isBootstrapPath("/anything/else"))
    }

    @Test func decideRouteAssetJS() {
        let d = decide("GET", "/xterm.js")
        #expect(d == .asset(name: "xterm", ext: "js", contentType: "application/javascript; charset=utf-8"))
    }

    @Test func decideRouteAssetFont() {
        let d = decide("GET", "/jetbrains-mono-regular.woff2")
        #expect(d == .asset(name: "JetBrainsMonoNerdFont-Regular", ext: "woff2", contentType: "font/woff2"))
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

    // MARK: - Web Push: base64url

    @Test func base64urlRoundTrip() {
        let data = Data([0, 1, 2, 250, 251, 252, 253, 254, 255, 65, 66])
        let encoded = WebPushCrypto.base64url(data)
        // URL-safe alphabet, no padding.
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("="))
        #expect(WebPushCrypto.base64urlDecode(encoded) == data)
    }

    @Test func base64urlDecodesUnpaddedVector() {
        // The RFC 8291 §5 auth secret is a 16-byte value in unpadded base64url.
        #expect(WebPushCrypto.base64urlDecode("BTBZMqHH6r4Tts7J_aSIgg")?.count == 16)
    }

    // MARK: - Web Push: message encryption (RFC 8291 §5 worked example)

    @Test func encryptMatchesRFC8291Example() throws {
        // The canonical worked example from RFC 8291 Section 5. Feeding the exact
        // application-server private key + salt the RFC used makes the otherwise-
        // random encryption deterministic, so the full aes128gcm body must match
        // the RFC's published output byte-for-byte.
        let plaintext = Data("When I grow up, I want to be a watermelon".utf8)
        let p256dh = WebPushCrypto.base64urlDecode(
            "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4")!
        let auth = WebPushCrypto.base64urlDecode("BTBZMqHH6r4Tts7J_aSIgg")!
        let asPrivateRaw = WebPushCrypto.base64urlDecode("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw")!
        let serverKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: asPrivateRaw)
        let salt = WebPushCrypto.base64urlDecode("DGv6ra1nlYgDCS1FRnbzlw")!

        let body = try WebPushCrypto.encrypt(
            payload: plaintext, p256dh: p256dh, authSecret: auth, serverKey: serverKey, salt: salt)

        let expected = "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
        #expect(WebPushCrypto.base64url(body) == expected)
    }

    @Test func encryptRejectsBadSubscriptionKey() {
        // A p256dh that is not a valid uncompressed P-256 point must throw, not crash.
        let serverKey = P256.KeyAgreement.PrivateKey()
        #expect(throws: (any Error).self) {
            _ = try WebPushCrypto.encrypt(
                payload: Data("x".utf8), p256dh: Data([0x04, 0x00, 0x01]),
                authSecret: Data(count: 16), serverKey: serverKey, salt: Data(count: 16))
        }
    }

    // MARK: - Web Push: VAPID JWT (RFC 8292)

    @Test func vapidAuthorizationHeaderStructureAndSignature() throws {
        let key = P256.Signing.PrivateKey()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let header = WebPushCrypto.vapidAuthorizationHeader(
            endpoint: "https://fcm.googleapis.com/fcm/send/abc123",
            privateKey: key, now: now)
        let value = try #require(header)

        // "vapid t=<jwt>,k=<pubkey>"
        #expect(value.hasPrefix("vapid t="))
        let rest = String(value.dropFirst("vapid t=".count))
        let comps = rest.components(separatedBy: ",k=")
        #expect(comps.count == 2)
        let jwt = comps[0]
        // k = the VAPID public key (uncompressed point) as base64url.
        #expect(WebPushCrypto.base64urlDecode(comps[1]) == key.publicKey.x963Representation)

        // JWT = header.claims.signature
        let parts = jwt.components(separatedBy: ".")
        #expect(parts.count == 3)
        let headerJSON = String(decoding: WebPushCrypto.base64urlDecode(parts[0])!, as: UTF8.self)
        #expect(headerJSON == #"{"typ":"JWT","alg":"ES256"}"#)
        let claimsJSON = String(decoding: WebPushCrypto.base64urlDecode(parts[1])!, as: UTF8.self)
        #expect(claimsJSON.contains(#""aud":"https://fcm.googleapis.com""#))
        #expect(claimsJSON.contains("\"exp\":\(1_000_000 + 12 * 3600)"))

        // The signature must actually verify against the public key (ES256/SHA-256).
        let signingInput = Data((parts[0] + "." + parts[1]).utf8)
        let sig = try P256.Signing.ECDSASignature(rawRepresentation: WebPushCrypto.base64urlDecode(parts[2])!)
        #expect(key.publicKey.isValidSignature(sig, for: signingInput))
    }

    @Test func vapidAuthorizationHeaderRejectsBadEndpoint() {
        let key = P256.Signing.PrivateKey()
        #expect(WebPushCrypto.vapidAuthorizationHeader(endpoint: "not a url", privateKey: key) == nil)
    }

    // MARK: - Web Push: request-body parsing

    @Test func pushSubscriptionParsesBrowserJSON() {
        let body = Data(#"{"endpoint":"https://x/abc","expirationTime":null,"keys":{"p256dh":"AAA","auth":"BBB"}}"#.utf8)
        let sub = WebMonitorServer.pushSubscription(fromBody: body)
        #expect(sub == WebPushSubscription(endpoint: "https://x/abc", p256dh: "AAA", auth: "BBB"))
    }

    @Test func pushSubscriptionRejectsMissingFields() {
        #expect(WebMonitorServer.pushSubscription(fromBody: Data(#"{"endpoint":"https://x"}"#.utf8)) == nil)
        #expect(WebMonitorServer.pushSubscription(fromBody: Data(#"{"keys":{"p256dh":"A","auth":"B"}}"#.utf8)) == nil)
        #expect(WebMonitorServer.pushSubscription(fromBody: Data(#"{"endpoint":"","keys":{"p256dh":"A","auth":"B"}}"#.utf8)) == nil)
        #expect(WebMonitorServer.pushSubscription(fromBody: Data("not json".utf8)) == nil)
    }

    @Test func pushEndpointParsing() {
        #expect(WebMonitorServer.pushEndpoint(fromBody: Data(#"{"endpoint":"https://x/abc"}"#.utf8)) == "https://x/abc")
        #expect(WebMonitorServer.pushEndpoint(fromBody: Data(#"{"endpoint":""}"#.utf8)) == nil)
        #expect(WebMonitorServer.pushEndpoint(fromBody: Data("{}".utf8)) == nil)
    }

    @Test func pushEnabledFlagParsing() {
        #expect(WebMonitorServer.pushEnabledFlag(fromBody: Data(#"{"enabled":true}"#.utf8)) == true)
        #expect(WebMonitorServer.pushEnabledFlag(fromBody: Data(#"{"enabled":false}"#.utf8)) == false)
        #expect(WebMonitorServer.pushEnabledFlag(fromBody: Data(#"{"enabled":"yes"}"#.utf8)) == nil)
        #expect(WebMonitorServer.pushEnabledFlag(fromBody: Data("{}".utf8)) == nil)
    }

    // MARK: - Web Push: decideRoute (new routes)

    @Test func decideRouteServiceWorkerBootstrap() {
        // /sw.js is a bootstrap path: query token accepted (like GET / and assets).
        #expect(decide("GET", "/sw.js", query: ["token": Self.tok]) == .serviceWorker)
        #expect(decide("GET", "/sw.js") == .serviceWorker)  // header token also fine
        #expect(decide("POST", "/sw.js") == .methodNotAllowed)
    }

    @Test func decideRoutePushConfig() {
        #expect(decide("GET", "/api/push/config") == .pushConfig)
        #expect(decide("POST", "/api/push/config") == .methodNotAllowed)
    }

    @Test func decideRoutePushSubscribeUnsubscribeEnabled() {
        #expect(decide("POST", "/api/push/subscribe") == .pushSubscribe)
        #expect(decide("GET", "/api/push/subscribe") == .methodNotAllowed)
        #expect(decide("POST", "/api/push/unsubscribe") == .pushUnsubscribe)
        #expect(decide("GET", "/api/push/unsubscribe") == .methodNotAllowed)
        #expect(decide("POST", "/api/push/enabled") == .pushEnabled)
        #expect(decide("GET", "/api/push/enabled") == .methodNotAllowed)
    }

    @Test func decideRoutePushApiRejectsQueryToken() {
        // /api/push/* is NOT a bootstrap path: a query token must be ignored, so a
        // request presenting ONLY ?token= (no header) is unauthorized.
        let d = WebMonitorServer.decideRoute(
            method: "GET", path: "/api/push/config", query: ["token": Self.tok],
            headers: ["host": "\(Self.host):\(Self.port)"],
            configuredHost: Self.host, configuredPort: Self.port, token: Self.tok, peerFailureCount: 0)
        #expect(d == .unauthorized)
    }

    @Test func decideRoutePushConfigRequiresHeaderToken() {
        // Missing token entirely on the (header-only) push API ⇒ unauthorized.
        let d = WebMonitorServer.decideRoute(
            method: "GET", path: "/api/push/config", query: [:],
            headers: ["host": "\(Self.host):\(Self.port)"],
            configuredHost: Self.host, configuredPort: Self.port, token: Self.tok, peerFailureCount: 0)
        #expect(d == .unauthorized)
    }

    // MARK: - surfaces cache freshness

    @Test func surfacesCacheFreshNilNeverFresh() {
        #expect(WebMonitorServer.surfacesCacheFresh(at: nil, now: Date(), ttl: 1.0) == false)
    }
    @Test func surfacesCacheFreshWithinTTL() {
        let at = Date()
        #expect(WebMonitorServer.surfacesCacheFresh(at: at, now: at.addingTimeInterval(0.5), ttl: 1.0) == true)
    }
    @Test func surfacesCacheStaleAtTTLBoundary() {
        let at = Date()  // strict `<`: exactly TTL is NOT fresh
        #expect(WebMonitorServer.surfacesCacheFresh(at: at, now: at.addingTimeInterval(1.0), ttl: 1.0) == false)
    }
    @Test func surfacesCacheStalePastTTL() {
        let at = Date()
        #expect(WebMonitorServer.surfacesCacheFresh(at: at, now: at.addingTimeInterval(3.0), ttl: 1.0) == false)
    }
    @Test func surfacesCacheDefaultTTLIsOneSecond() {
        let at = Date()  // locks the documented 3s-poll / ~1s-build contract
        #expect(WebMonitorServer.surfacesCacheFresh(at: at, now: at.addingTimeInterval(0.9)) == true)
        #expect(WebMonitorServer.surfacesCacheFresh(at: at, now: at.addingTimeInterval(1.1)) == false)
    }
    /// Explicitly pin the load-bearing constant itself so a change to the TTL is
    /// flagged directly (not as a confusing boundary-probe failure in the tests above).
    @Test func surfacesCacheTTLConstantIsOneSecond() {
        #expect(WebMonitorServer.surfacesCacheTTL == 1.0)
    }

    // MARK: - surfaces cache read path (hit / miss)

    /// The exact read-side decision the `.surfacesList` handler makes on `queue`:
    /// a fresh entry is a HIT (returns the cached bytes, no main hop); nil/stale is
    /// a MISS (returns nil ⇒ the handler rebuilds on main).
    @Test func cachedSurfacesDataNilIsMiss() {
        #expect(WebMonitorServer.cachedSurfacesData(nil, now: Date(), ttl: 1.0) == nil)
    }
    @Test func cachedSurfacesDataFreshIsHit() {
        let at = Date()
        let payload = Data("[{\"id\":\"x\"}]".utf8)
        let got = WebMonitorServer.cachedSurfacesData((data: payload, at: at), now: at.addingTimeInterval(0.5), ttl: 1.0)
        #expect(got == payload)
    }
    @Test func cachedSurfacesDataStaleIsMiss() {
        let at = Date()
        let payload = Data("[{\"id\":\"x\"}]".utf8)
        // exactly TTL (strict `<`) and well past TTL both miss
        #expect(WebMonitorServer.cachedSurfacesData((data: payload, at: at), now: at.addingTimeInterval(1.0), ttl: 1.0) == nil)
        #expect(WebMonitorServer.cachedSurfacesData((data: payload, at: at), now: at.addingTimeInterval(3.0), ttl: 1.0) == nil)
    }
    @Test func cachedSurfacesDataDefaultTTLIsOneSecond() {
        let at = Date()
        let payload = Data("[]".utf8)
        #expect(WebMonitorServer.cachedSurfacesData((data: payload, at: at), now: at.addingTimeInterval(0.9)) == payload)
        #expect(WebMonitorServer.cachedSurfacesData((data: payload, at: at), now: at.addingTimeInterval(1.1)) == nil)
    }

    // MARK: - surfaces cache STORE-side round-trip
    //
    // The read-side tests above feed hand-built tuples to `cachedSurfacesData`.
    // These compose the two halves end-to-end: build an entry stamped at `now`
    // (exactly as the `.surfacesList` handler does — `cachedSurfaces = (data,
    // at: Date())`), then assert it is a HIT throughout [now, now+TTL) and a
    // MISS at/after now+TTL. This pins the handler's store-at-now / serve-until-
    // TTL contract, not just the freshness predicate in isolation.

    @Test func cachedSurfacesStoreRoundTripHitWithinTTL() {
        let now = Date()
        let payload = Data("[{\"id\":\"abc\"}]".utf8)
        let stored = (data: payload, at: now)  // what the handler stores
        // immediately, mid-window, and just-before-TTL: all HIT, return the bytes
        #expect(WebMonitorServer.cachedSurfacesData(stored, now: now, ttl: 1.0) == payload)
        #expect(WebMonitorServer.cachedSurfacesData(stored, now: now.addingTimeInterval(0.5), ttl: 1.0) == payload)
        #expect(WebMonitorServer.cachedSurfacesData(stored, now: now.addingTimeInterval(0.99), ttl: 1.0) == payload)
    }

    @Test func cachedSurfacesStoreRoundTripMissAtAndPastTTL() {
        let now = Date()
        let payload = Data("[{\"id\":\"abc\"}]".utf8)
        let stored = (data: payload, at: now)
        // exactly TTL (strict `<` ⇒ stale) and past TTL: MISS ⇒ handler rebuilds
        #expect(WebMonitorServer.cachedSurfacesData(stored, now: now.addingTimeInterval(1.0), ttl: 1.0) == nil)
        #expect(WebMonitorServer.cachedSurfacesData(stored, now: now.addingTimeInterval(5.0), ttl: 1.0) == nil)
    }

    @Test func cachedSurfacesStoreRoundTripUsesDefaultTTL() {
        // The handler stores with the default TTL; pin the same boundary via the
        // default-argument path (no explicit ttl:), so a TTL change is caught here too.
        let now = Date()
        let payload = Data("[]".utf8)
        let stored = (data: payload, at: now)
        #expect(WebMonitorServer.cachedSurfacesData(stored, now: now.addingTimeInterval(0.9)) == payload)
        #expect(WebMonitorServer.cachedSurfacesData(stored, now: now.addingTimeInterval(1.0)) == nil)
    }

    // MARK: - /stream post-hop decision (streamSetupDecision)
    //
    // routeStream's genuinely-new logic is the on-`queue` continuation that runs
    // AFTER the async main resolve hop: the liveness guard (peer may have hung up
    // mid-hop ⇒ abort so we don't leak a host client), the 404 (surface gone),
    // the 501 (no pty-host), and the proceed branch. That branching is the pure
    // `streamSetupDecision`; these pin every branch + the precedence between them.

    private static let liveResolution = WebMonitorServer.StreamResolution(
        sessionID: 42, socketPath: "/tmp/host.sock", cols: 80, rows: 24)

    @Test func streamDecisionDeadConnAborts() {
        // Dead conn (connectionRefs[key] == nil after a mid-hop disconnect) ⇒ abort,
        // EVEN with a fully-usable resolution — the liveness guard takes precedence
        // so no host client is opened for a gone peer (the leak the guard prevents).
        #expect(WebMonitorServer.streamSetupDecision(
            connectionAlive: false, resolved: Self.liveResolution) == .abort)
        // and abort regardless of what resolved is
        #expect(WebMonitorServer.streamSetupDecision(
            connectionAlive: false, resolved: nil) == .abort)
    }

    @Test func streamDecisionNilResolveIs404() {
        // Live conn but the surface is gone / has no live surface ⇒ 404.
        #expect(WebMonitorServer.streamSetupDecision(
            connectionAlive: true, resolved: nil) == .notFound)
    }

    @Test func streamDecisionNoPtyHostIs501() {
        // Live conn, surface resolved, but no pty-host configured (nil OR empty
        // socket path) ⇒ 501 so the page degrades to the /screen poll.
        let nilPath = WebMonitorServer.StreamResolution(
            sessionID: 1, socketPath: nil, cols: 80, rows: 24)
        let emptyPath = WebMonitorServer.StreamResolution(
            sessionID: 1, socketPath: "", cols: 80, rows: 24)
        #expect(WebMonitorServer.streamSetupDecision(
            connectionAlive: true, resolved: nilPath) == .notImplemented)
        #expect(WebMonitorServer.streamSetupDecision(
            connectionAlive: true, resolved: emptyPath) == .notImplemented)
    }

    @Test func streamDecisionLiveProceeds() {
        // Live conn + a usable session ⇒ proceed, threading the resolve params
        // through to the host-client open.
        #expect(WebMonitorServer.streamSetupDecision(
            connectionAlive: true, resolved: Self.liveResolution)
            == .proceed(socketPath: "/tmp/host.sock", sessionID: 42, cols: 80, rows: 24))
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

    // MARK: - decodeChildExitedSessionID (u64 LE session_id, first field)

    @Test func decodeChildExitedSessionIDReadsFirstU64LE() {
        // Payload layout: u64 LE session_id, u32 LE exit_code, u64 LE runtime_ms
        // (protocol.ChildExited). We only read the session id; the rest is ignored.
        var p = Data()
        C.appendU64LE(&p, 0xcafef00d)
        C.appendU32LE(&p, 0)           // exit_code
        C.appendU64LE(&p, 1234)        // runtime_ms
        #expect(C.decodeChildExitedSessionID(p) == 0xcafef00d)
    }

    @Test func decodeChildExitedSessionIDFromHeaderOnly() {
        // Even a payload with ONLY the 8-byte session id decodes (we never read
        // past it), so a minimal/forward-compatible frame still tears down cleanly.
        var p = Data()
        C.appendU64LE(&p, 7)
        #expect(C.decodeChildExitedSessionID(p) == 7)
    }

    @Test func decodeChildExitedSessionIDTooShortIsNil() {
        #expect(C.decodeChildExitedSessionID(Data([0x00, 0x01, 0x02])) == nil)
        #expect(C.decodeChildExitedSessionID(Data()) == nil)
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

/// (ramon fork / Hero Agents) The pure push-payload seams that decide the notification
/// title glyph + the `"kind"` field, so a hero push reads apart from a bell/attention push.
struct WebPushPayloadTests {

    // MARK: - pushTitle glyph + fallback

    @Test func heroTitleUsesStarGlyph() {
        #expect(WebPushManager.pushTitle(glyph: "⭐", rawTitle: "build things")
            == "⭐ build things")
    }

    @Test func bellAndAttentionTitlesUseBellGlyph() {
        #expect(WebPushManager.pushTitle(glyph: "🔔", rawTitle: "acme repo")
            == "🔔 acme repo")
    }

    @Test func emptyTitleFallsBackToGhostty() {
        #expect(WebPushManager.pushTitle(glyph: "⭐", rawTitle: "") == "⭐ Ghostty")
        #expect(WebPushManager.pushTitle(glyph: "🔔", rawTitle: "") == "🔔 Ghostty")
    }

    // MARK: - pushPayload "kind" field

    @Test func payloadCarriesHeroKind() {
        let id = UUID()
        let p = WebPushManager.pushPayload(
            title: "⭐ Ghostty", body: "needs you", surface: id, kind: "hero")
        #expect(p["kind"] == "hero")
        #expect(p["title"] == "⭐ Ghostty")
        #expect(p["body"] == "needs you")
        #expect(p["surface"] == id.uuidString)
    }

    @Test func payloadCarriesBellAndAttentionKind() {
        let id = UUID()
        #expect(WebPushManager.pushPayload(
            title: "🔔 x", body: "", surface: id, kind: "bell")["kind"] == "bell")
        #expect(WebPushManager.pushPayload(
            title: "🔔 x", body: "", surface: id, kind: "attention")["kind"] == "attention")
    }
}

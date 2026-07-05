import Foundation
import Testing
@testable import Ghostty

/// Unit tests for the pure / value units of the fork-only MCP `/agent-state`
/// route — the Claude Code hook ingest. They cover the body parser (valid,
/// blank-tty, unknown-state, non-object, truncation, optional fields), the tty
/// normalizer + matcher, `resolveSurface` with an injected `TTYResolver`, and
/// the `decideRoute` extension for `POST /agent-state`. No live server, no AppKit.
struct MCPAgentStateTests {

    // MARK: - parse (happy)

    @Test func parseValidWorking() {
        let body = Data(#"{"tty":"/dev/ttys004","state":"working"}"#.utf8)
        let p = MCPAgentState.parse(body)
        #expect(p?.tty == "/dev/ttys004")
        #expect(p?.state == .working)
        #expect(p?.prompt == nil)
        #expect(p?.tool == nil)
        #expect(p?.message == nil)
    }

    @Test func parseValidIdle() {
        let body = Data(#"{"tty":"ttys004","state":"idle"}"#.utf8)
        let p = MCPAgentState.parse(body)
        #expect(p?.tty == "ttys004")
        #expect(p?.state == .idle)
        #expect(p?.prompt == nil)
        #expect(p?.tool == nil)
        #expect(p?.message == nil)
    }

    @Test func parseValidAllFields() {
        let body = Data(#"{"tty":"ttys004","state":"waiting","prompt":"do the thing","tool":"Bash","message":"needs input"}"#.utf8)
        let p = MCPAgentState.parse(body)
        #expect(p?.tty == "ttys004")
        #expect(p?.state == .waiting)
        #expect(p?.prompt == "do the thing")
        #expect(p?.tool == "Bash")
        #expect(p?.message == "needs input")
    }

    @Test func parseStateCaseInsensitive() {
        #expect(MCPAgentState.parse(Data(#"{"tty":"ttys004","state":"WAITING"}"#.utf8))?.state == .waiting)
        #expect(MCPAgentState.parse(Data(#"{"tty":"ttys004","state":"Idle"}"#.utf8))?.state == .idle)
    }

    @Test func parseTrimsTTY() {
        // Leading/trailing whitespace on tty is stripped (raw value, pre-normalize).
        let p = MCPAgentState.parse(Data(#"{"tty":"  ttys004  ","state":"idle"}"#.utf8))
        #expect(p?.tty == "ttys004")
    }

    // MARK: - parse (errors)

    @Test func parseRejectsMissingTTY() {
        #expect(MCPAgentState.parse(Data(#"{"state":"working"}"#.utf8)) == nil)
    }

    @Test func parseRejectsBlankTTY() {
        #expect(MCPAgentState.parse(Data(#"{"tty":"","state":"working"}"#.utf8)) == nil)
        #expect(MCPAgentState.parse(Data(#"{"tty":"   ","state":"working"}"#.utf8)) == nil)
    }

    @Test func parseRejectsMissingState() {
        #expect(MCPAgentState.parse(Data(#"{"tty":"ttys004"}"#.utf8)) == nil)
    }

    @Test func parseRejectsUnknownState() {
        #expect(MCPAgentState.parse(Data(#"{"tty":"ttys004","state":"bogus"}"#.utf8)) == nil)
    }

    @Test func parseRejectsNonObject() {
        #expect(MCPAgentState.parse(Data("[1,2,3]".utf8)) == nil)
        #expect(MCPAgentState.parse(Data("\"hello\"".utf8)) == nil)
        #expect(MCPAgentState.parse(Data("42".utf8)) == nil)
    }

    @Test func parseRejectsEmptyAndGarbage() {
        #expect(MCPAgentState.parse(Data()) == nil)
        #expect(MCPAgentState.parse(Data("not json".utf8)) == nil)
    }

    @Test func parseRejectsNonStringTTY() {
        #expect(MCPAgentState.parse(Data(#"{"tty":123,"state":"working"}"#.utf8)) == nil)
    }

    @Test func parseEmptyOptionalFieldsBecomeNil() {
        // Empty-string optionals are treated as absent (nil), not "".
        let p = MCPAgentState.parse(Data(#"{"tty":"ttys004","state":"working","prompt":"","tool":"","message":""}"#.utf8))
        #expect(p?.prompt == nil)
        #expect(p?.tool == nil)
        #expect(p?.message == nil)
    }

    // MARK: - parse (truncation)

    @Test func parseTruncatesPromptAndMessage() {
        let huge = String(repeating: "x", count: 5000)
        let body = Data(#"{"tty":"ttys004","state":"working","prompt":"\#(huge)","message":"\#(huge)"}"#.utf8)
        let p = MCPAgentState.parse(body, maxStringLen: 2000)
        #expect(p?.prompt?.count == 2000)
        #expect(p?.message?.count == 2000)
    }

    @Test func parseCapsToolAt256() {
        // tool is a short tool name, capped at a fixed 256 (independent of
        // maxStringLen) so a pathological value can't ride into the tile footer.
        let huge = String(repeating: "y", count: 5000)
        let body = Data(#"{"tty":"ttys004","state":"working","tool":"\#(huge)"}"#.utf8)
        let p = MCPAgentState.parse(body, maxStringLen: 2000)
        #expect(p?.tool?.count == 256)
    }

    @Test func parseKeepsShortStringsIntact() {
        let p = MCPAgentState.parse(Data(#"{"tty":"ttys004","state":"working","prompt":"short"}"#.utf8))
        #expect(p?.prompt == "short")
    }

    // MARK: - normalizeTTY

    @Test func normalizeTTYStripsDevPrefix() {
        #expect(MCPAgentState.normalizeTTY("/dev/ttys004") == "ttys004")
    }

    @Test func normalizeTTYIdentityOnTTYsForm() {
        #expect(MCPAgentState.normalizeTTY("ttys004") == "ttys004")
    }

    @Test func normalizeTTYAddsTTYPrefixToShortForm() {
        // `ps -o tty=` historic short form.
        #expect(MCPAgentState.normalizeTTY("s004") == "ttys004")
    }

    @Test func normalizeTTYLowercases() {
        #expect(MCPAgentState.normalizeTTY("/dev/TTYS004") == "ttys004")
    }

    @Test func normalizeTTYKeepsPTS() {
        #expect(MCPAgentState.normalizeTTY("/dev/pts/3") == "pts/3")
        #expect(MCPAgentState.normalizeTTY("pts/3") == "pts/3")
    }

    // MARK: - ttyMatches

    @Test func ttyMatchesAcrossForms() {
        #expect(MCPAgentState.ttyMatches("/dev/ttys004", "ttys004"))
        #expect(MCPAgentState.ttyMatches("s004", "/dev/ttys004"))
        #expect(MCPAgentState.ttyMatches("ttys004", "ttys004"))
    }

    @Test func ttyMatchesRejectsDifferentDevices() {
        #expect(!MCPAgentState.ttyMatches("ttys004", "ttys005"))
        #expect(!MCPAgentState.ttyMatches("/dev/ttys001", "s002"))
    }

    @Test func ttyMatchesRejectsBlank() {
        // Two blank/missing ttys must NOT collide onto each other.
        #expect(!MCPAgentState.ttyMatches("", ""))
        #expect(!MCPAgentState.ttyMatches("/dev/", "/dev/"))
    }

    // MARK: - resolveSurface (injected resolver)

    @Test func resolveSurfaceMatchesFirstByTTY() {
        let a = UUID(), b = UUID()
        let surfaces: [(uuid: UUID, pid: pid_t)] = [(a, 100), (b, 200)]
        let resolver: MCPAgentState.TTYResolver = { pid in
            pid == 100 ? "ttys004" : "ttys005"
        }
        #expect(MCPAgentState.resolveSurface(forTTY: "/dev/ttys005", surfaces: surfaces, resolver: resolver) == b)
        #expect(MCPAgentState.resolveSurface(forTTY: "s004", surfaces: surfaces, resolver: resolver) == a)
    }

    @Test func resolveSurfaceReturnsNilOnNoMatch() {
        let surfaces: [(uuid: UUID, pid: pid_t)] = [(UUID(), 100)]
        let resolver: MCPAgentState.TTYResolver = { _ in "ttys004" }
        #expect(MCPAgentState.resolveSurface(forTTY: "ttys999", surfaces: surfaces, resolver: resolver) == nil)
    }

    @Test func resolveSurfaceSkipsUnresolvablePIDs() {
        let a = UUID(), b = UUID()
        let surfaces: [(uuid: UUID, pid: pid_t)] = [(a, 100), (b, 200)]
        // pid 100 has no controlling tty (resolver returns nil) -> skipped.
        let resolver: MCPAgentState.TTYResolver = { pid in
            pid == 100 ? nil : "ttys004"
        }
        #expect(MCPAgentState.resolveSurface(forTTY: "ttys004", surfaces: surfaces, resolver: resolver) == b)
    }

    @Test func resolveSurfaceEmptySnapshot() {
        let resolver: MCPAgentState.TTYResolver = { _ in "ttys004" }
        #expect(MCPAgentState.resolveSurface(forTTY: "ttys004", surfaces: [], resolver: resolver) == nil)
    }

    // MARK: - decideRoute (/agent-state)

    @Test func decideRouteAgentStatePost() {
        let d = MCPServer.decideRoute(
            method: "POST", path: "/agent-state", headers: [:],
            configuredHost: "127.0.0.1", configuredPort: 8765,
            token: "", peerFailureCount: 0)
        #expect(d == .agentState)
    }

    @Test func decideRouteAgentStateNonPostIsMethodNotAllowed() {
        let d = MCPServer.decideRoute(
            method: "GET", path: "/agent-state", headers: [:],
            configuredHost: "127.0.0.1", configuredPort: 8765,
            token: "", peerFailureCount: 0)
        #expect(d == .methodNotAllowed)
    }

    @Test func decideRouteAgentStateEnforcesToken() {
        // The /agent-state route rides the SAME token gate as /mcp: a wrong token
        // is .unauthorized BEFORE the path is even consulted.
        let d = MCPServer.decideRoute(
            method: "POST", path: "/agent-state",
            headers: ["x-ghostty-token": "wrong"],
            configuredHost: "127.0.0.1", configuredPort: 8765,
            token: "correct-token-value", peerFailureCount: 0)
        #expect(d == .unauthorized)
    }

    @Test func decideRouteAgentStatePassesWithToken() {
        let d = MCPServer.decideRoute(
            method: "POST", path: "/agent-state",
            headers: ["x-ghostty-token": "correct-token-value"],
            configuredHost: "127.0.0.1", configuredPort: 8765,
            token: "correct-token-value", peerFailureCount: 0)
        #expect(d == .agentState)
    }

    @Test func decideRouteUnknownPathStillNotFound() {
        let d = MCPServer.decideRoute(
            method: "POST", path: "/nope", headers: [:],
            configuredHost: "127.0.0.1", configuredPort: 8765,
            token: "", peerFailureCount: 0)
        #expect(d == .notFound)
    }

    // MARK: - (cloud-hosts M3/D6) nonce body parse — no tty

    @Test func parseAcceptsNonceBodyWithNoTTY() {
        // A REMOTE box's hook carries a nonce and NO tty; parse must accept it.
        let body = Data(#"{"nonce":"abc123","state":"waiting"}"#.utf8)
        let p = MCPAgentState.parse(body)
        #expect(p?.tty == nil)
        #expect(p?.nonce == "abc123")
        #expect(p?.state == .waiting)
    }

    @Test func parseAcceptsNonceWithFields() {
        let body = Data(#"{"nonce":"n1","state":"working","tool":"Bash","prompt":"go"}"#.utf8)
        let p = MCPAgentState.parse(body)
        #expect(p?.nonce == "n1")
        #expect(p?.tool == "Bash")
        #expect(p?.prompt == "go")
    }

    @Test func parseTrimsNonceAndTreatsBlankAsAbsent() {
        #expect(MCPAgentState.parse(Data(#"{"nonce":"  n2 ","state":"idle"}"#.utf8))?.nonce == "n2")
        // A blank nonce AND no tty ⇒ neither identifier ⇒ rejected.
        #expect(MCPAgentState.parse(Data(#"{"nonce":"   ","state":"idle"}"#.utf8)) == nil)
    }

    @Test func parseRejectsBodyWithNeitherTTYNorNonce() {
        #expect(MCPAgentState.parse(Data(#"{"state":"working"}"#.utf8)) == nil)
    }

    @Test func parseKeepsTTYFallbackWhenBothPresent() {
        // A body with both a tty and a nonce parses both; the handler prefers nonce.
        let p = MCPAgentState.parse(Data(#"{"tty":"ttys004","nonce":"n3","state":"idle"}"#.utf8))
        #expect(p?.tty == "ttys004")
        #expect(p?.nonce == "n3")
    }

    // MARK: - (cloud-hosts M1/D6) RemoteAgentIdentity nonce map

    @Test func remoteAgentIdentityRegistersAndResolves() {
        let map = RemoteAgentIdentity.shared
        let nonce = RemoteAgentIdentity.mintNonce()
        let sid = UUID()
        map.register(nonce: nonce, surfaceID: sid, hostName: "cloud-1", sessionID: 0)
        #expect(map.resolveSurfaceID(nonce: nonce) == sid)
        let id = map.resolve(nonce: nonce)
        #expect(id?.hostName == "cloud-1")
        // Backfill the host-assigned session id once "Attached" lands.
        map.recordAttached(nonce: nonce, sessionID: 4242)
        #expect(map.resolve(nonce: nonce)?.sessionID == 4242)
        map.remove(nonce: nonce)
        #expect(map.resolveSurfaceID(nonce: nonce) == nil)
    }

    @Test func mintNonceIsHexAndUnique() {
        let a = RemoteAgentIdentity.mintNonce()
        let b = RemoteAgentIdentity.mintNonce()
        #expect(a != b)
        #expect(a.count == 32)
        #expect(a.allSatisfy { $0.isHexDigit })
    }

    // MARK: - (cloud-hosts M3/D6) capability-token route scoping

    @Test func capabilityTokenAuthorizesAgentStateOnly() {
        // A per-box capability token (NOT the master) is accepted for /agent-state.
        let d = MCPServer.decideRoute(
            method: "POST", path: "/agent-state",
            headers: ["x-ghostty-token": "box-token"],
            configuredHost: "127.0.0.1", configuredPort: 8765,
            token: "master-token-value", peerFailureCount: 0,
            capabilityTokens: ["box-token"])
        #expect(d == .agentState)
    }

    @Test func capabilityTokenRejectedForMCPSpawn() {
        // THE security crux (D6): a box's capability token must NEVER drive /mcp
        // (spawn/input). It is rejected even though it is a VALID ingest credential.
        let d = MCPServer.decideRoute(
            method: "POST", path: "/mcp",
            headers: ["x-ghostty-token": "box-token"],
            configuredHost: "127.0.0.1", configuredPort: 8765,
            token: "master-token-value", peerFailureCount: 0,
            capabilityTokens: ["box-token"])
        #expect(d == .unauthorized)
    }

    @Test func masterTokenStillDrivesMCP() {
        // The master token retains full access to /mcp (unchanged).
        let d = MCPServer.decideRoute(
            method: "POST", path: "/mcp",
            headers: ["x-ghostty-token": "master-token-value"],
            configuredHost: "127.0.0.1", configuredPort: 8765,
            token: "master-token-value", peerFailureCount: 0,
            capabilityTokens: ["box-token"])
        #expect(d == .mcp)
    }

    @Test func unknownTokenIsUnauthorizedEvenWithCapabilitySet() {
        let d = MCPServer.decideRoute(
            method: "POST", path: "/agent-state",
            headers: ["x-ghostty-token": "neither"],
            configuredHost: "127.0.0.1", configuredPort: 8765,
            token: "master-token-value", peerFailureCount: 0,
            capabilityTokens: ["box-token"])
        #expect(d == .unauthorized)
    }

    @Test func emptyCapabilitySetRejectsAnyBoxToken() {
        // Fail-closed default: with NO capability tokens provisioned, a box token is
        // simply an unknown token (401), never accepted.
        let d = MCPServer.decideRoute(
            method: "POST", path: "/agent-state",
            headers: ["x-ghostty-token": "box-token"],
            configuredHost: "127.0.0.1", configuredPort: 8765,
            token: "master-token-value", peerFailureCount: 0,
            capabilityTokens: [])
        #expect(d == .unauthorized)
    }

    // MARK: - (cloud-hosts M3/D6) allowed-hosts (tailnet FQDN)

    @Test func allowedHostAcceptsTailnetFQDN() {
        // A tailnet MagicDNS Host is 403'd by default (rebinding guard)…
        let base = MCPServer.decideRoute(
            method: "POST", path: "/agent-state",
            headers: ["host": "my-mac.tail1234.ts.net:8765"],
            configuredHost: "127.0.0.1", configuredPort: 8765,
            token: "", peerFailureCount: 0)
        #expect(base == .forbiddenHost)
        // …but accepted when added to the allowed-host set.
        let allowed = MCPServer.decideRoute(
            method: "POST", path: "/agent-state",
            headers: ["host": "my-mac.tail1234.ts.net:8765"],
            configuredHost: "127.0.0.1", configuredPort: 8765,
            token: "", peerFailureCount: 0,
            allowedHosts: ["my-mac.tail1234.ts.net"])
        #expect(allowed == .agentState)
    }

    @Test func allowedHostStillGatesPort() {
        // The allow-list matches the host but the port must still be the configured one.
        let d = MCPServer.decideRoute(
            method: "POST", path: "/agent-state",
            headers: ["host": "my-mac.tail1234.ts.net:9999"],
            configuredHost: "127.0.0.1", configuredPort: 8765,
            token: "", peerFailureCount: 0,
            allowedHosts: ["my-mac.tail1234.ts.net"])
        #expect(d == .forbiddenHost)
    }
}

import Foundation
@testable import Ghostty
import Testing

struct SurfaceViewAppKitTests {
    @Test(arguments: [
        ("\u{0008}", true),
        ("\u{001F}", true),
        ("\u{007F}", false),
        (" ", false),
        ("h", false),
        ("", false),
        ("\u{0009}x", false),
        ("\u{0009}\u{0009}", false),
    ])
    func suppressesOnlySingleC0ControlTextWhileComposing(
        text: String,
        expected: Bool
    ) {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                text,
                composing: true
            ) == expected
        )
    }

    @Test func doesNotSuppressControlTextWhenNotComposing() {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                "\u{0008}",
                composing: false
            ) == false
        )
    }

    @Test func doesNotSuppressMissingText() {
        #expect(
            Ghostty.SurfaceView.shouldSuppressComposingControlInput(
                nil,
                composing: true
            ) == false
        )
    }

    // MARK: - (ramon fork / cloud-hosts) Three-way host resolution (E2 / D4)

    private static let sampleRegistry: [String: RemoteHostEntry] = [
        "cloud-1": RemoteHostEntry(
            name: "cloud-1",
            sshTarget: "user@cloud-1.example.ts.net",
            remoteSocketPath: "~/.ghostty-ramon-host.sock",
            localSocketPath: nil),
    ]

    @Test func nilHostResolvesLocal() {
        #expect(
            Ghostty.SurfaceView.resolveHost(nil, registry: Self.sampleRegistry)
                == .local)
    }

    @Test func emptyHostResolvesLocal() {
        #expect(
            Ghostty.SurfaceView.resolveHost("", registry: Self.sampleRegistry)
                == .local)
    }

    @Test(arguments: ["local", "Local", "LOCAL"])
    func reservedLocalNameResolvesLocal(name: String) {
        #expect(
            Ghostty.SurfaceView.resolveHost(name, registry: Self.sampleRegistry)
                == .local)
    }

    @Test func resolvableRemoteResolvesToEntry() {
        let resolution = Ghostty.SurfaceView.resolveHost(
            "cloud-1", registry: Self.sampleRegistry)
        #expect(resolution == .remote(Self.sampleRegistry["cloud-1"]!))
    }

    @Test func unresolvableRemoteResolvesUnresolvable() {
        // A present, non-local name NOT in the registry is the D4 error state —
        // never a local dial, never a spawn.
        #expect(
            Ghostty.SurfaceView.resolveHost("cloud-9", registry: Self.sampleRegistry)
                == .unresolvable("cloud-9"))
    }

    @Test func unresolvableRemoteWithEmptyRegistry() {
        #expect(
            Ghostty.SurfaceView.resolveHost("cloud-1", registry: [:])
                == .unresolvable("cloud-1"))
    }

    // MARK: - (ramon fork / cloud-hosts) hostName Codable gate (E1)

    /// A real (non-local) host name IS persisted so the `(host, sessionID)` pair
    /// round-trips across a GUI restart.
    @Test func hostNameRoundTripsForRemote() {
        #expect(Ghostty.SurfaceView.shouldPersistHostName("cloud-1") == true)
    }

    /// An absent host name decodes as local (nil ⇒ `.local`) and is NOT persisted,
    /// so pre-cloud / `.exec` archives keep reading local.
    @Test func absentHostNameDecodesLocal() {
        #expect(Ghostty.SurfaceView.shouldPersistHostName(nil) == false)
        #expect(
            Ghostty.SurfaceView.resolveHost(nil, registry: [:]) == .local)
    }

    /// A local surface (nil or the reserved `"local"`, any case) encodes NOTHING
    /// for `hostName`, keeping existing local archives byte-for-byte identical.
    @Test(arguments: [String?.none, "local", "Local", ""])
    func localSurfaceArchiveByteIdentical(name: String?) {
        #expect(Ghostty.SurfaceView.shouldPersistHostName(name) == false)
    }

    // MARK: - (ramon fork / cloud-hosts, K1/L1) Reconnect-overlay state mapping

    /// Build a `ClientStateInfo` for the pure mapping tests.
    private static func info(
        _ state: Ghostty.ClientState,
        hostMajor: UInt16 = 0, hostMinor: UInt16 = 0,
        guiMajor: UInt16 = 0, guiMinor: UInt16 = 0
    ) -> Ghostty.ClientStateInfo {
        var i = Ghostty.ClientStateInfo()
        i.state = state
        i.hostMajor = hostMajor; i.hostMinor = hostMinor
        i.guiMajor = guiMajor; i.guiMinor = guiMinor
        return i
    }

    /// `.ok` yields NO banner (no overlay over a healthy surface).
    @Test func okYieldsNoBanner() {
        #expect(Ghostty.SurfaceView.reconnectBanner(
            info: Self.info(.ok), host: "cloud-1") == nil)
    }

    /// L1: `too_old` is DIRECTIONAL + actionable — it names the host protocol version,
    /// this GUI's version, the host, and how to fix it (redeploy). Loud severity.
    @Test func tooOldYieldsActionableMessage() throws {
        let b = Ghostty.SurfaceView.reconnectBanner(
            info: Self.info(.tooOld, hostMajor: 1, hostMinor: 2, guiMajor: 3, guiMinor: 4),
            host: "cloud-1")
        let banner = try #require(b)
        #expect(banner.severity == .loud)
        // Directional: BOTH the host version and the GUI version appear.
        #expect(banner.body.contains("1.2"))          // host protocol
        #expect(banner.body.contains("3"))            // GUI major
        #expect(banner.body.contains("3.4"))          // GUI major.minor
        // Actionable + host-scoped.
        #expect(banner.body.localizedCaseInsensitiveContains("redeploy"))
        #expect(banner.title.contains("cloud-1") || banner.body.contains("cloud-1"))
        #expect(banner.title.localizedCaseInsensitiveContains("too old"))
    }

    /// A MINOR-only gap is NEVER too_old (the Zig side only sets too_old on a MAJOR
    /// mismatch — a minor gap degrades). This asserts the mapping's copy is keyed on the
    /// state, so a same-major host that reached `.ok` shows no banner at all.
    @Test func minorGapDegradesToNoBanner() {
        // Same major (2), host minor 3 vs GUI minor 5 — the negotiated-down healthy case.
        #expect(Ghostty.SurfaceView.reconnectBanner(
            info: Self.info(.ok, hostMajor: 2, hostMinor: 3, guiMajor: 2, guiMinor: 5),
            host: "cloud-1") == nil)
    }

    /// A missing/failed tunnel dial surfaces as `.unreachable`, NOT a blank pane. The
    /// copy names the host + the tunnel and is retry-oriented.
    @Test func missingTunnelYieldsUnreachable() throws {
        let b = Ghostty.SurfaceView.reconnectBanner(
            info: Self.info(.unreachable), host: "cloud-1")
        let banner = try #require(b)
        #expect(banner.severity == .loud)
        #expect(banner.body.localizedCaseInsensitiveContains("tunnel"))
        #expect(banner.title.contains("cloud-1") || banner.body.contains("cloud-1"))
    }

    /// The ambiguous EOF-before-ack case is `cannot_handshake`, DISTINCT from the
    /// confident `too_old`: it must NOT claim a specific protocol version, and its copy
    /// must differ from too_old's.
    @Test func ambiguousEOFYieldsCannotHandshakeNotTooOld() throws {
        // Same version data for both, so any difference is purely the state's copy.
        let ver = (hostMajor: UInt16(1), hostMinor: UInt16(2), guiMajor: UInt16(3), guiMinor: UInt16(4))
        let cannot = try #require(Ghostty.SurfaceView.reconnectBanner(
            info: Self.info(.cannotHandshake,
                            hostMajor: ver.hostMajor, hostMinor: ver.hostMinor,
                            guiMajor: ver.guiMajor, guiMinor: ver.guiMinor),
            host: "cloud-1"))
        let tooOld = try #require(Ghostty.SurfaceView.reconnectBanner(
            info: Self.info(.tooOld,
                            hostMajor: ver.hostMajor, hostMinor: ver.hostMinor,
                            guiMajor: ver.guiMajor, guiMinor: ver.guiMinor),
            host: "cloud-1"))
        // Distinct copy.
        #expect(cannot.title != tooOld.title)
        #expect(cannot.body != tooOld.body)
        // Ambiguous: no confident version claim, not "too old".
        #expect(!cannot.body.localizedCaseInsensitiveContains("too old"))
        #expect(!cannot.body.contains("1.2"))
        #expect(!cannot.body.localizedCaseInsensitiveContains("protocol"))
        #expect(cannot.severity == .loud)
    }

    /// The design rule: EVERY non-ok state resolves to a NAMED banner with non-empty
    /// title AND body — never an unexplained blank pane.
    @Test(arguments: [
        Ghostty.ClientState.reconnecting,
        .sessionEnded,
        .cannotHandshake,
        .tooOld,
        .unreachable,
    ])
    func everyNonOkStateYieldsNonEmptyBanner(state: Ghostty.ClientState) throws {
        let banner = try #require(Ghostty.SurfaceView.reconnectBanner(
            info: Self.info(state, hostMajor: 1, hostMinor: 0, guiMajor: 2, guiMinor: 0),
            host: "cloud-1"))
        #expect(!banner.title.isEmpty)
        #expect(!banner.body.isEmpty)
    }

    /// `reconnecting` is the transient, subtle tier (a lightly-dimmed frame + hint),
    /// distinct from the loud error tier.
    @Test func reconnectingIsTransient() throws {
        let banner = try #require(Ghostty.SurfaceView.reconnectBanner(
            info: Self.info(.reconnecting), host: "cloud-1"))
        #expect(banner.severity == .transient)
        #expect(banner.title.contains("cloud-1"))
    }

    // MARK: - (ramon fork / cloud-hosts, REG-T2) Connect-timeout carriage

    /// The per-attempt connect ceiling defaults to 0 (⇒ the core's compiled default)
    /// and is carried on `SurfaceConfiguration` so `withCValue` can forward it into
    /// `ghostty_surface_config_s.pty_host_connect_timeout_s` (threaded core-side to
    /// `Client.Config.connect_timeout_s`, covered by the Zig parse/thread tests).
    @Test func surfaceConfigurationConnectTimeoutDefaultsToZero() {
        #expect(Ghostty.SurfaceConfiguration().ptyHostConnectTimeoutS == 0)
    }

    @Test func surfaceConfigurationCarriesConnectTimeout() {
        var cfg = Ghostty.SurfaceConfiguration()
        cfg.ptyHostConnectTimeoutS = 15
        #expect(cfg.ptyHostConnectTimeoutS == 15)
    }
}

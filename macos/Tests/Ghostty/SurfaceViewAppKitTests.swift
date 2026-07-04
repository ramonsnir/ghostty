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
}

// (ramon fork) Web monitor — Web Push notifications for terminal bells.
//
// Goal: when a surface rings a bell, deliver a BACKGROUND push notification to a
// subscribed phone (Chrome/Android) even with the browser tab closed / phone
// locked, so you can step away from the laptop and still be pinged when a
// long-running command finishes or a CLI agent wants approval. A page-side toggle
// arms/mutes it (mute at the laptop, arm when you walk away).
//
// This is the full Web Push stack, done in-process with ZERO new dependencies:
//   - VAPID (RFC 8292): we self-generate a P-256 keypair (NO Firebase/Google
//     project). Chrome hands back an `fcm.googleapis.com/...` endpoint and we POST
//     directly to it with a VAPID-signed JWT (ES256).
//   - Message encryption (RFC 8291, `aes128gcm` content coding per RFC 8188):
//     ephemeral ECDH against the subscription's public key, HKDF-SHA256 key
//     derivation, AES-128-GCM. All via Apple's CryptoKit.
// The browser side needs a SECURE CONTEXT (service workers only register over
// HTTPS); we terminate TLS with `tailscale serve` in front of the loopback-bound
// server (see WEB-MONITOR.md). `WebPushCrypto` is PURE + unit-tested against the
// RFC 8291 §5 worked example; `WebPushManager` owns the keypair / subscription
// store / enable flag and fans a bell out to every subscription.

import Foundation
import CryptoKit
import AppKit
import os

/// One browser push subscription, as returned by `PushSubscription.toJSON()` in
/// the page and POSTed to `/api/push/subscribe`. `p256dh`/`auth` are base64url
/// (the browser's `keys` object).
struct WebPushSubscription: Codable, Equatable {
    let endpoint: String
    let p256dh: String
    let auth: String
}

/// PURE Web Push crypto: VAPID JWT (RFC 8292) + `aes128gcm` payload encryption
/// (RFC 8291 / RFC 8188). No I/O, no shared state — every function is a value-in/
/// value-out transform so the security-critical crypto is unit-testable (notably
/// against the RFC 8291 §5 vector). Lives in its own enum namespace.
enum WebPushCrypto {
    // MARK: base64url

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64urlDecode(_ s: String) -> Data? {
        var str = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while str.count % 4 != 0 { str += "=" }
        return Data(base64Encoded: str)
    }

    // MARK: VAPID (RFC 8292)

    /// Build the `Authorization: vapid t=<jwt>,k=<key>` header value for a push
    /// to `endpoint`, signed by the VAPID private key. The JWT `aud` is the
    /// endpoint's origin (scheme://host[:port]); `exp` is +12h (VAPID caps it at
    /// 24h); `sub` is a contact URI. Returns nil only on a malformed endpoint.
    /// `now` is injectable so the JWT is testable.
    static func vapidAuthorizationHeader(
        endpoint: String,
        privateKey: P256.Signing.PrivateKey,
        subject: String = "mailto:web-monitor@ghostty.invalid",
        now: Date = Date()
    ) -> String? {
        guard let url = URL(string: endpoint), let scheme = url.scheme, let host = url.host else {
            return nil
        }
        var aud = "\(scheme)://\(host)"
        if let port = url.port { aud += ":\(port)" }

        // Compact-JSON, fixed key order (we control both ends, so no need for a
        // serializer): header then claims, each base64url'd.
        let headerJSON = #"{"typ":"JWT","alg":"ES256"}"#
        let exp = Int(now.timeIntervalSince1970) + 12 * 3600
        let claimsJSON = "{\"aud\":\"\(aud)\",\"exp\":\(exp),\"sub\":\"\(subject)\"}"

        let signingInput = base64url(Data(headerJSON.utf8)) + "." + base64url(Data(claimsJSON.utf8))
        guard let sig = try? privateKey.signature(for: Data(signingInput.utf8)) else { return nil }
        // ES256 = ECDSA P-256 / SHA-256 with the signature as raw r||s (64 bytes).
        let jwt = signingInput + "." + base64url(sig.rawRepresentation)
        let k = base64url(privateKey.publicKey.x963Representation)
        return "vapid t=\(jwt),k=\(k)"
    }

    // MARK: Message encryption (RFC 8291, aes128gcm)

    enum CryptoError: Error { case badSubscriptionKey }

    /// Encrypt `payload` for a subscription, producing the full `aes128gcm`
    /// content-coding body (RFC 8188 header + a single AEAD record) ready to be
    /// the HTTP request body with `Content-Encoding: aes128gcm`. `p256dh` is the
    /// subscription's UA public key (65-byte uncompressed/X9.63), `authSecret`
    /// its 16-byte auth secret. The ephemeral server keypair + 16-byte salt are
    /// INJECTED so the function is deterministic and testable against RFC 8291 §5;
    /// the random-input convenience overload is below.
    static func encrypt(
        payload: Data,
        p256dh: Data,
        authSecret: Data,
        serverKey: P256.KeyAgreement.PrivateKey,
        salt: Data
    ) throws -> Data {
        guard let uaPublic = try? P256.KeyAgreement.PublicKey(x963Representation: p256dh) else {
            throw CryptoError.badSubscriptionKey
        }
        let asPublic = serverKey.publicKey.x963Representation  // 65 bytes, our keyid

        let shared = try serverKey.sharedSecretFromKeyAgreement(with: uaPublic)

        // Key combining (RFC 8291 §3.4): IKM = HKDF(salt=auth_secret,
        // IKM=ecdh_secret, info="WebPush: info"\0 || ua_public || as_public).
        let keyInfo = Data("WebPush: info\u{0}".utf8) + p256dh + asPublic
        let ikm = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: authSecret, sharedInfo: keyInfo, outputByteCount: 32)

        // Content encryption (RFC 8188 §2.1): CEK/NONCE = HKDF(salt=random salt,
        // IKM=ikm, info="Content-Encoding: aes128gcm"\0 / "...: nonce"\0).
        let cek = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: salt,
            info: Data("Content-Encoding: aes128gcm\u{0}".utf8), outputByteCount: 16)
        let nonceKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm, salt: salt,
            info: Data("Content-Encoding: nonce\u{0}".utf8), outputByteCount: 12)
        let nonce = try AES.GCM.Nonce(data: nonceKey.withUnsafeBytes { Data($0) })

        // Single record: plaintext gets the last-record delimiter 0x02 appended
        // (no further padding). Seal, then take ciphertext||tag (NOT `.combined`,
        // which would prefix the nonce we transmit via HKDF instead).
        var plaintext = payload
        plaintext.append(0x02)
        let sealed = try AES.GCM.seal(plaintext, using: cek, nonce: nonce)
        let record = sealed.ciphertext + sealed.tag

        // aes128gcm header: salt(16) || rs(4, BE) || idlen(1) || keyid(as_public).
        var body = Data()
        body.append(salt)
        var rs = UInt32(4096).bigEndian
        withUnsafeBytes(of: &rs) { body.append(contentsOf: $0) }
        body.append(UInt8(asPublic.count))
        body.append(asPublic)
        body.append(record)
        return body
    }

    /// Random-input convenience: parse the base64url subscription keys, generate
    /// a fresh ephemeral keypair + salt, and encrypt. Returns nil on a malformed
    /// subscription key.
    static func encrypt(payload: Data, p256dhB64: String, authB64: String) -> Data? {
        guard let p256dh = base64urlDecode(p256dhB64),
              let auth = base64urlDecode(authB64) else { return nil }
        let serverKey = P256.KeyAgreement.PrivateKey()
        // 16 random bytes from CryptoKit's CSPRNG (no Security import needed).
        let salt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        return try? encrypt(
            payload: payload, p256dh: p256dh, authSecret: auth, serverKey: serverKey, salt: salt)
    }
}

/// Owns the VAPID keypair, the subscription store, and the global enable flag
/// (all persisted in UserDefaults — the per-bundle-id domain, so each fork
/// identity is independent), observes `.ghosttyBellDidRing`, and fans a bell out
/// to every subscription as an encrypted Web Push. The `WebMonitorServer` holds
/// one of these and routes `/api/push/*` into it.
///
/// THREADING: the bell observer fires on `.main` (it reads SurfaceView value
/// types there); everything else — the subscription store, the enable flag, the
/// debounce map, the URLSession sends — is serialized on a private background
/// queue. UserDefaults itself is thread-safe.
final class WebPushManager {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "web-monitor-push")

    private let queue = DispatchQueue(label: "com.mitchellh.ghostty-ramon.webmonitor.push")
    private let defaults: UserDefaults

    // Persisted-state keys.
    private static let kVapid = "webmonitor.push.vapidPrivateKey"   // base64 raw scalar (32B)
    private static let kSubs = "webmonitor.push.subscriptions"      // JSON [WebPushSubscription]
    private static let kEnabled = "webmonitor.push.enabled"         // Bool, default false

    /// VAPID signing keypair (persisted so subscriptions stay valid across
    /// relaunches — regenerating it would silently invalidate every device).
    private let vapidKey: P256.Signing.PrivateKey

    // Mutated only on `queue`.
    private var subscriptions: [WebPushSubscription]
    private var enabledFlag: Bool
    /// (ramon fork / Agent hooks) Which signal a push represents. The per-surface
    /// debounce is keyed PER KIND so the bell and the agent-`.waiting` push coalesce
    /// INDEPENDENTLY — a chatty bell within 3s must never silently swallow the
    /// headline "agent needs input" push (or vice-versa). Each kind still self-
    /// debounces its own repeats at ~3s/surface.
    private enum PushKind: Hashable { case bell, attention }
    /// Per-(surface, kind) last-push time so a chatty signal does not spam the phone.
    private var lastSent: [PushKey: Date] = [:]
    private struct PushKey: Hashable { let id: UUID; let kind: PushKind }
    private static let debounceInterval: TimeInterval = 3

    /// (ramon fork / Bell Attention v2) Whether the `push` effect is routed to each
    /// tier (set by AppDelegate from bell-features.push / attention-features.push). A
    /// RAW bell pushes iff `bellPush`; a PROMOTED attention pushes iff `attnPush`.
    /// Defaults match the config defaults (both on) so behavior is unchanged until
    /// configured.
    var bellPush = true
    var attnPush = true

    private var bellObserver: NSObjectProtocol?
    /// (ramon fork / Bell Attention) Observes `.ghosttyAttentionDidChange` so a
    /// surface the Agent Manager PROMOTES via `set_attention` pushes to the phone
    /// (the loud Tier-2 signal). Independent of the bell-features tone-down.
    private var attentionStateObserver: NSObjectProtocol?
    /// (ramon fork / Agent hooks) Observes `.ghosttyAgentNeedsAttention` so an
    /// agent that ENTERS `.waiting` (a Claude Code `Notification` hook event,
    /// resolved to a surface by the MCP `/agent-state` handler and re-posted by
    /// `AgentDashboardModel` on the working/idle→waiting edge) pushes to the phone
    /// exactly like a bell. GUI + hooks only — no Zig/host change.
    private var attentionObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Load or generate the VAPID keypair.
        if let b64 = defaults.string(forKey: Self.kVapid),
           let raw = Data(base64Encoded: b64),
           let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) {
            self.vapidKey = key
        } else {
            let key = P256.Signing.PrivateKey()
            defaults.set(key.rawRepresentation.base64EncodedString(), forKey: Self.kVapid)
            self.vapidKey = key
        }

        if let data = defaults.data(forKey: Self.kSubs),
           let subs = try? JSONDecoder().decode([WebPushSubscription].self, from: data) {
            self.subscriptions = subs
        } else {
            self.subscriptions = []
        }
        self.enabledFlag = defaults.bool(forKey: Self.kEnabled)  // false by default
    }

    // MARK: Public API (used by the server routes)

    /// The VAPID public key as base64url (uncompressed point) — the
    /// `applicationServerKey` the page passes to `pushManager.subscribe`.
    var vapidPublicKeyBase64: String {
        WebPushCrypto.base64url(vapidKey.publicKey.x963Representation)
    }

    func isEnabled() -> Bool { queue.sync { enabledFlag } }

    func setEnabled(_ on: Bool) {
        queue.async {
            self.enabledFlag = on
            self.defaults.set(on, forKey: Self.kEnabled)
            self.logger.info("web-monitor-push: notifications \(on ? "ENABLED" : "muted", privacy: .public)")
        }
    }

    func addSubscription(_ sub: WebPushSubscription) {
        queue.async {
            // De-dupe on endpoint (a re-subscribe from the same device replaces).
            self.subscriptions.removeAll { $0.endpoint == sub.endpoint }
            self.subscriptions.append(sub)
            self.persistSubscriptions()
            self.logger.info("web-monitor-push: subscription added (\(self.subscriptions.count, privacy: .public) total)")
        }
    }

    func removeSubscription(endpoint: String) {
        queue.async {
            self.subscriptions.removeAll { $0.endpoint == endpoint }
            self.persistSubscriptions()
        }
    }

    /// Snapshot count, for `/api/push/config`.
    func subscriptionCount() -> Int { queue.sync { subscriptions.count } }

    // MARK: Lifecycle

    /// Register the bell observer on main (mirrors MCPEventBus.start). The
    /// notification's object is the ringing SurfaceView; we read value types off
    /// it on main, then hop to `queue` to encrypt + send.
    func start() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.bellObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name.ghosttyBellDidRing, object: nil, queue: .main
            ) { [weak self] note in
                guard let self, let view = note.object as? Ghostty.SurfaceView else { return }
                // (ramon fork / Bell Attention v2) The raw bell pushes iff the `push`
                // effect is routed to the bell tier (bell-features.push).
                if !self.bellPush { return }
                self.onBell(id: view.id, title: view.title, pwd: view.pwd)
            }
            // (ramon fork / Bell Attention v2) A promoted attention state pushes iff the
            // `push` effect is routed to the attention tier (attention-features.push).
            // userInfo carries surfaceID + attention + reason + title + pwd (value types,
            // enriched by MCPServer.setAttention on its main hop).
            self.attentionStateObserver = NotificationCenter.default.addObserver(
                forName: .ghosttyAttentionDidChange, object: nil, queue: .main
            ) { [weak self] note in
                guard let self, self.attnPush,
                      let id = note.userInfo?[AgentStateUserInfoKey.surfaceID] as? UUID,
                      (note.userInfo?[AgentStateUserInfoKey.attention] as? Bool) == true else { return }
                let title = note.userInfo?[AgentStateUserInfoKey.title] as? String ?? ""
                let pwd = note.userInfo?[AgentStateUserInfoKey.pwd] as? String
                let reason = note.userInfo?[AgentStateUserInfoKey.reason] as? String ?? ""
                self.onAttention(id: id, title: title, pwd: pwd, message: reason)
            }
            // (ramon fork / Agent hooks) Push on agent-waiting, alongside the bell.
            // The userInfo is the pinned value-type payload from AgentStateBridge;
            // it crosses the main hop by value (no SurfaceView reference).
            self.attentionObserver = NotificationCenter.default.addObserver(
                forName: .ghosttyAgentNeedsAttention, object: nil, queue: .main
            ) { [weak self] note in
                guard let self,
                      let id = note.userInfo?[AgentStateUserInfoKey.surfaceID] as? UUID else { return }
                let title = note.userInfo?[AgentStateUserInfoKey.title] as? String ?? ""
                let pwd = note.userInfo?[AgentStateUserInfoKey.pwd] as? String
                let msg = note.userInfo?[AgentStateUserInfoKey.message] as? String ?? ""
                self.onAttention(id: id, title: title, pwd: pwd, message: msg)
            }
        }
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let obs = self.bellObserver {
                NotificationCenter.default.removeObserver(obs)
                self.bellObserver = nil
            }
            if let obs = self.attentionObserver {
                NotificationCenter.default.removeObserver(obs)
                self.attentionObserver = nil
            }
            if let obs = self.attentionStateObserver {
                NotificationCenter.default.removeObserver(obs)
                self.attentionStateObserver = nil
            }
        }
    }

    // MARK: Internals

    private func persistSubscriptions() {
        if let data = try? JSONEncoder().encode(subscriptions) {
            defaults.set(data, forKey: Self.kSubs)
        }
    }

    /// Called on main from the bell observer. Hops to `queue` to check the enable
    /// flag + debounce and fan out. The bell body is the surface's pwd.
    private func onBell(id: UUID, title: String, pwd: String?) {
        enqueuePush(
            id: id,
            kind: .bell,
            title: "🔔 " + (title.isEmpty ? "Ghostty" : title),
            body: pwd ?? "")
    }

    /// (ramon fork / Agent hooks) Called on main from the attention observer when
    /// an agent enters `.waiting`. Reuses the SAME fan-out as `onBell` (enable
    /// flag, per-surface debounce, payload shape, send). The only difference is a
    /// body that prefers the "needs input" `message` over the pwd; the title shares
    /// the SAME "🔔 " prefix as a raw bell, so bells and promoted attentions look
    /// unified on the phone (the hourglass read as unclear). The `kind: .attention`
    /// still keeps the debounce independent from a raw bell.
    private func onAttention(id: UUID, title: String, pwd: String?, message: String) {
        let body = message.isEmpty ? (pwd ?? "") : message
        enqueuePush(
            id: id,
            kind: .attention,
            title: "🔔 " + (title.isEmpty ? "Ghostty" : title),
            body: body)
    }

    /// Shared fan-out for both the bell and the agent-waiting pushes. Hops to
    /// `queue`, applies the enable flag + per-(surface, kind) debounce, builds the
    /// payload, and sends to every subscription. The `lastSent` debounce is keyed by
    /// surface id AND `kind`, so the bell and the agent-`.waiting` push coalesce
    /// INDEPENDENTLY — an unrelated bell within 3s never drops the headline waiting
    /// push (each kind still self-debounces its own repeats at ~3s/surface).
    private func enqueuePush(id: UUID, kind: PushKind, title: String, body: String) {
        queue.async {
            guard self.enabledFlag, !self.subscriptions.isEmpty else { return }
            let key = PushKey(id: id, kind: kind)
            let now = Date()
            if let last = self.lastSent[key], now.timeIntervalSince(last) < Self.debounceInterval {
                return
            }
            // Opportunistically drop entries that are well past their debounce window so
            // `lastSent` can't grow unbounded across a long-lived app session (one entry
            // per (surface, kind) ever seen). A stale entry only exists to suppress a
            // repeat within `debounceInterval`, so anything older is dead weight.
            let pruneAge = Self.debounceInterval * 10
            self.lastSent = self.lastSent.filter { now.timeIntervalSince($0.value) < pruneAge }
            self.lastSent[key] = now

            let payload: [String: String] = [
                "title": title,
                "body": body,
                "surface": id.uuidString,
            ]
            guard let payloadData = try? JSONSerialization.data(withJSONObject: payload) else { return }
            for sub in self.subscriptions { self.send(payloadData, to: sub) }
        }
    }

    /// Encrypt + POST one push. On 404/410 the subscription is gone (the browser
    /// dropped it) — remove it so the store self-heals.
    private func send(_ payload: Data, to sub: WebPushSubscription) {
        guard let url = URL(string: sub.endpoint),
              let encrypted = WebPushCrypto.encrypt(
                payload: payload, p256dhB64: sub.p256dh, authB64: sub.auth),
              let auth = WebPushCrypto.vapidAuthorizationHeader(
                endpoint: sub.endpoint, privateKey: vapidKey) else {
            logger.error("web-monitor-push: could not build push for endpoint")
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("aes128gcm", forHTTPHeaderField: "Content-Encoding")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue("60", forHTTPHeaderField: "TTL")
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        req.httpBody = encrypted

        URLSession.shared.dataTask(with: req) { [weak self] _, resp, err in
            guard let self else { return }
            if let err {
                self.logger.error("web-monitor-push: send failed: \(String(describing: err), privacy: .public)")
                return
            }
            guard let http = resp as? HTTPURLResponse else { return }
            if http.statusCode == 404 || http.statusCode == 410 {
                self.logger.info("web-monitor-push: endpoint gone (\(http.statusCode, privacy: .public)); dropping subscription")
                self.removeSubscription(endpoint: sub.endpoint)
            } else if http.statusCode >= 400 {
                self.logger.error("web-monitor-push: push rejected (HTTP \(http.statusCode, privacy: .public))")
            }
        }.resume()
    }
}

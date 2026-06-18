import Foundation
import OSLog

/// (ramon fork / Phase 2b) A minimal Swift client for the `ghostty-host`
/// length-prefixed binary wire protocol (see `src/host/protocol.zig`). It
/// connects to the host's AF_UNIX socket, performs the Hello/HelloAck
/// handshake, subscribes to a single session's RAW PTY output, and streams the
/// raw bytes back to a callback. The web monitor uses this to render a live,
/// colorful, scrollback-aware view via a browser xterm.js — something the
/// `.client` viewport mirror cannot provide.
///
/// ## Wire format (mirrors `src/host/protocol.zig`)
///
/// A frame on the socket is:
///
///     [u32 LENGTH, BIG-ENDIAN][1 byte TAG][payload of (LENGTH - 1) bytes]
///
/// LENGTH counts the tag byte + payload. All in-frame SCALARS are
/// LITTLE-ENDIAN. A byte slice is encoded as `[u32 LE length][bytes]`.
///
/// Only the four frame types this client needs are modeled here:
///   - `hello` (tag 0):         u16 LE major, u16 LE minor, [u32 LE len][bytes id]
///   - `hello_ack` (tag 1):     u16 LE major, u16 LE minor, ... (we read major)
///   - `subscribe_raw` (tag 31): u64 LE session_id
///   - `raw_output` (tag 32):   u64 LE session_id, [u32 LE len][bytes]
///
/// Handshake order required by the host: connect -> send Hello -> read
/// HelloAck (verify major) -> send subscribe_raw{session_id} -> read a stream
/// of raw_output frames (ring-buffer replay first, then live).
///
/// ## Threading
///
/// All socket I/O runs on a dedicated background serial queue; `start()`
/// dispatches the connect + handshake + read loop there. `onBytes`/`onClose`
/// are invoked on that same background queue (the caller is responsible for
/// hopping to the main thread if it touches AppKit). `stop()` is safe to call
/// from any thread and closes the socket, which unblocks the read loop.
final class WebMonitorHostClient {
    /// The protocol major version this client speaks. Must match
    /// `PROTOCOL_VERSION_MAJOR` in `src/host/protocol.zig`.
    static let protocolVersionMajor: UInt16 = 1

    // MARK: - Frame tags (FrameType enum ordinals in protocol.zig)

    enum FrameTag: UInt8 {
        case hello = 0
        case helloAck = 1
        // host->client: the session's child process exited. The host routes this
        // existing frame to RAW subscribers too (Server.onChildExited) so this
        // client can end a stream that would otherwise hang forever (a dead
        // session emits no more raw_output and the conn never EOFs). See
        // streamLoop's child-exit handling.
        case childExited = 11
        case subscribeRaw = 31
        case rawOutput = 32
    }

    // MARK: - Pure, unit-testable framing helpers

    /// Encode a complete frame: BE u32 length (= 1 + payload.count), the tag
    /// byte, then the payload.
    static func encodeFrame(tag: FrameTag, payload: Data) -> Data {
        var out = Data()
        let len = UInt32(payload.count + 1)
        appendU32BE(&out, len)
        out.append(tag.rawValue)
        out.append(payload)
        return out
    }

    /// Encode a Hello frame (our protocol version + an empty identity bundle id).
    static func encodeHello() -> Data {
        var payload = Data()
        appendU16LE(&payload, protocolVersionMajor)
        appendU16LE(&payload, 0)  // minor: we don't negotiate a minimum minor
        appendU32LE(&payload, 0)  // identity_bundle_id: empty
        return encodeFrame(tag: .hello, payload: payload)
    }

    /// Encode a subscribe_raw frame for `sessionID`.
    static func encodeSubscribeRaw(_ sessionID: UInt64) -> Data {
        var payload = Data()
        appendU64LE(&payload, sessionID)
        return encodeFrame(tag: .subscribeRaw, payload: payload)
    }

    /// Decode the major version from a HelloAck payload (u16 LE major, ...).
    /// Returns nil if the payload is too short.
    static func decodeHelloAckMajor(_ payload: Data) -> UInt16? {
        guard payload.count >= 2 else { return nil }
        return readU16LE(payload, at: payload.startIndex)
    }

    /// Decode a raw_output payload: u64 LE session_id, then [u32 LE len][bytes].
    /// Returns nil on a malformed/truncated payload.
    static func decodeRawOutput(_ payload: Data) -> (sessionID: UInt64, bytes: Data)? {
        var i = payload.startIndex
        guard payload.count >= 8 + 4 else { return nil }
        guard let sid = readU64LE(payload, at: i) else { return nil }
        i = payload.index(i, offsetBy: 8)
        guard let len = readU32LE(payload, at: i) else { return nil }
        i = payload.index(i, offsetBy: 4)
        let remaining = payload.distance(from: i, to: payload.endIndex)
        guard remaining >= Int(len) else { return nil }
        let end = payload.index(i, offsetBy: Int(len))
        let bytes = Data(payload[i..<end])
        return (sid, bytes)
    }

    /// Decode the session_id (u64 LE, the first field) of a `child_exited`
    /// payload (u64 LE session_id, u32 LE exit_code, u64 LE runtime_ms — see
    /// protocol.ChildExited). We only need the session id to confirm the exit is
    /// for THIS subscription; the exit code / runtime are unused on the stream
    /// path. Returns nil on a truncated payload.
    static func decodeChildExitedSessionID(_ payload: Data) -> UInt64? {
        guard payload.count >= 8 else { return nil }
        return readU64LE(payload, at: payload.startIndex)
    }

    // MARK: - FrameReader (partial-read-tolerant reassembler)

    /// Accumulates arbitrary socket-read chunks and yields complete frames.
    /// Mirrors the Zig `FrameReader`: read 4 BE bytes for LENGTH, then wait for
    /// LENGTH more bytes; byte[0] of those is the tag, byte[1..] is the payload.
    struct FrameReader {
        /// Hard cap on a single frame's LENGTH prefix, mirroring
        /// `MAX_FRAME_LEN` (64 MiB) in protocol.zig. A corrupt/oversized prefix
        /// would otherwise force unbounded buffer growth.
        static let maxFrameLen: UInt32 = 64 * 1024 * 1024

        struct Frame {
            let tag: UInt8
            let payload: Data
        }

        enum ReadError: Error {
            case frameTooLarge
        }

        private var buf = Data()

        mutating func push(_ data: Data) {
            buf.append(data)
        }

        /// Return the next complete frame, or nil if not enough is buffered.
        /// Throws `ReadError.frameTooLarge` on an oversized length prefix.
        mutating func next() throws -> Frame? {
            guard buf.count >= 4 else { return nil }
            let start = buf.startIndex
            guard let len = WebMonitorHostClient.readU32BE(buf, at: start) else { return nil }
            if len == 0 { throw ReadError.frameTooLarge }  // len must cover >= the tag byte
            if len > FrameReader.maxFrameLen { throw ReadError.frameTooLarge }
            let total = 4 + Int(len)
            guard buf.count >= total else { return nil }
            let tagIndex = buf.index(start, offsetBy: 4)
            let tag = buf[tagIndex]
            let payloadStart = buf.index(start, offsetBy: 5)
            let payloadEnd = buf.index(start, offsetBy: total)
            let payload = Data(buf[payloadStart..<payloadEnd])
            // Consume the frame's bytes.
            buf.removeSubrange(start..<payloadEnd)
            return Frame(tag: tag, payload: payload)
        }
    }

    // MARK: - LE / BE scalar codec helpers

    static func appendU16LE(_ d: inout Data, _ v: UInt16) {
        d.append(UInt8(v & 0xff))
        d.append(UInt8((v >> 8) & 0xff))
    }

    static func appendU32LE(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8(v & 0xff))
        d.append(UInt8((v >> 8) & 0xff))
        d.append(UInt8((v >> 16) & 0xff))
        d.append(UInt8((v >> 24) & 0xff))
    }

    static func appendU32BE(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8((v >> 24) & 0xff))
        d.append(UInt8((v >> 16) & 0xff))
        d.append(UInt8((v >> 8) & 0xff))
        d.append(UInt8(v & 0xff))
    }

    static func appendU64LE(_ d: inout Data, _ v: UInt64) {
        var x = v
        for _ in 0..<8 {
            d.append(UInt8(x & 0xff))
            x >>= 8
        }
    }

    static func readU16LE(_ d: Data, at i: Data.Index) -> UInt16? {
        guard d.distance(from: i, to: d.endIndex) >= 2 else { return nil }
        let b0 = UInt16(d[i])
        let b1 = UInt16(d[d.index(i, offsetBy: 1)])
        return b0 | (b1 << 8)
    }

    static func readU32LE(_ d: Data, at i: Data.Index) -> UInt32? {
        guard d.distance(from: i, to: d.endIndex) >= 4 else { return nil }
        var v: UInt32 = 0
        for k in 0..<4 {
            v |= UInt32(d[d.index(i, offsetBy: k)]) << (8 * k)
        }
        return v
    }

    static func readU32BE(_ d: Data, at i: Data.Index) -> UInt32? {
        guard d.distance(from: i, to: d.endIndex) >= 4 else { return nil }
        var v: UInt32 = 0
        for k in 0..<4 {
            v = (v << 8) | UInt32(d[d.index(i, offsetBy: k)])
        }
        return v
    }

    static func readU64LE(_ d: Data, at i: Data.Index) -> UInt64? {
        guard d.distance(from: i, to: d.endIndex) >= 8 else { return nil }
        var v: UInt64 = 0
        for k in 0..<8 {
            v |= UInt64(d[d.index(i, offsetBy: k)]) << (8 * k)
        }
        return v
    }

    // MARK: - Instance state / I/O

    private let socketPath: String
    private let sessionID: UInt64
    private let onBytes: (Data) -> Void
    private let onClose: () -> Void
    private let queue = DispatchQueue(label: "com.mitchellh.ghostty-ramon.webmonitor.hostclient")

    /// The connected socket fd. -1 when not open. Guarded by `fdLock` because
    /// `stop()` may close it from another thread while the read loop reads it.
    private var fd: Int32 = -1
    private let fdLock = NSLock()
    private var stopped = false

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty-ramon",
        category: "web-monitor"
    )

    init(
        socketPath: String,
        sessionID: UInt64,
        onBytes: @escaping (Data) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.socketPath = socketPath
        self.sessionID = sessionID
        self.onBytes = onBytes
        self.onClose = onClose
    }

    /// Connect, handshake, subscribe, and begin streaming. Runs entirely on the
    /// background queue; returns immediately.
    func start() {
        queue.async { [weak self] in
            self?.run()
        }
    }

    /// Close the socket. Safe from any thread; unblocks the read loop, which
    /// then invokes `onClose`. Idempotent.
    func stop() {
        fdLock.lock()
        stopped = true
        let f = fd
        fd = -1
        fdLock.unlock()
        if f >= 0 {
            close(f)
        }
    }

    // MARK: - Private

    private func run() {
        guard let connected = connect() else {
            fireClose()
            return
        }

        // Handshake: send Hello, read HelloAck, verify major.
        if !writeAll(connected, WebMonitorHostClient.encodeHello()) {
            cleanupAndClose(connected)
            return
        }

        var reader = FrameReader()
        guard let ack = readUntilFrame(connected, reader: &reader, tag: .helloAck) else {
            cleanupAndClose(connected)
            return
        }
        guard let major = WebMonitorHostClient.decodeHelloAckMajor(ack),
              major == WebMonitorHostClient.protocolVersionMajor else {
            WebMonitorHostClient.logger.warning("web-monitor host client: protocol major mismatch")
            cleanupAndClose(connected)
            return
        }

        // Subscribe to the session's raw output.
        if !writeAll(connected, WebMonitorHostClient.encodeSubscribeRaw(sessionID)) {
            cleanupAndClose(connected)
            return
        }

        // Stream raw_output frames. `reader` may already hold buffered bytes.
        streamLoop(connected, reader: &reader)
        cleanupAndClose(connected)
    }

    /// Open + connect an AF_UNIX SOCK_STREAM socket to `socketPath`. Stores the
    /// fd under the lock so `stop()` can close it. Returns the fd or nil.
    private func connect() -> Int32? {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            WebMonitorHostClient.logger.warning("web-monitor host client: socket() failed")
            return nil
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        // sun_path capacity (104 on Darwin). Reject an over-long path rather
        // than truncate it into a wrong socket.
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < cap else {
            WebMonitorHostClient.logger.warning("web-monitor host client: socket path too long")
            close(sock)
            return nil
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: cap) { dst in
                for (k, b) in pathBytes.enumerated() { dst[k] = b }
                dst[pathBytes.count] = 0
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(sock, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            WebMonitorHostClient.logger.warning("web-monitor host client: connect() failed")
            close(sock)
            return nil
        }

        fdLock.lock()
        if stopped {
            // stop() raced ahead of connect(); don't keep the fd.
            fdLock.unlock()
            close(sock)
            return nil
        }
        fd = sock
        fdLock.unlock()
        return sock
    }

    /// Write all bytes; returns false on error/short-circuit close.
    private func writeAll(_ sock: Int32, _ data: Data) -> Bool {
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return true }
            var off = 0
            let total = raw.count
            while off < total {
                let n = Darwin.write(sock, base + off, total - off)
                if n > 0 {
                    off += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    /// Read socket chunks into `reader` until a frame with `tag` is produced.
    /// Returns that frame's payload, or nil on EOF/error. Frames with other
    /// tags before it are discarded (the host sends none before HelloAck, but
    /// be tolerant).
    private func readUntilFrame(
        _ sock: Int32,
        reader: inout FrameReader,
        tag: FrameTag
    ) -> Data? {
        var scratch = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            // Drain any complete frames already buffered.
            while true {
                let frame: FrameReader.Frame?
                do {
                    frame = try reader.next()
                } catch {
                    return nil
                }
                guard let f = frame else { break }
                if f.tag == tag.rawValue { return f.payload }
                // else: discard and keep looking.
            }
            let n = readChunk(sock, into: &scratch)
            if n <= 0 { return nil }
            reader.push(Data(scratch[0..<n]))
        }
    }

    /// The raw_output streaming loop: pull frames, decode raw_output, forward.
    private func streamLoop(_ sock: Int32, reader: inout FrameReader) {
        var scratch = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            // Drain complete frames.
            while true {
                let frame: FrameReader.Frame?
                do {
                    frame = try reader.next()
                } catch {
                    return  // frame too large -> treat as a clean close
                }
                guard let f = frame else { break }
                if f.tag == FrameTag.rawOutput.rawValue {
                    if let decoded = WebMonitorHostClient.decodeRawOutput(f.payload),
                       decoded.sessionID == sessionID,
                       !decoded.bytes.isEmpty {
                        onBytes(decoded.bytes)
                    }
                } else if f.tag == FrameTag.childExited.rawValue {
                    // The host now notifies RAW subscribers when the session's
                    // child exits (Server.onChildExited). Treat it as end-of-
                    // stream for OUR session: returning ends the read loop ->
                    // cleanupAndClose -> onClose, which cancels the browser
                    // /stream connection so the page falls back to the live
                    // snapshot poll instead of hanging on a dead session. Without
                    // this, the prior bug was a permanent freeze (no more
                    // raw_output, no EOF). Guard on the session id so an unrelated
                    // frame can't tear down a still-live stream.
                    if let sid = WebMonitorHostClient.decodeChildExitedSessionID(f.payload),
                       sid == sessionID {
                        return
                    }
                }
                // Ignore any other frame types on this subscription.
            }
            let n = readChunk(sock, into: &scratch)
            if n <= 0 { return }
            reader.push(Data(scratch[0..<n]))
        }
    }

    /// One read() into `scratch`, retrying EINTR. Returns bytes read (0 = EOF,
    /// <0 = error).
    private func readChunk(_ sock: Int32, into scratch: inout [UInt8]) -> Int {
        while true {
            let n = scratch.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(sock, base, raw.count)
            }
            if n < 0 && errno == EINTR { continue }
            return n
        }
    }

    private func cleanupAndClose(_ sock: Int32) {
        fdLock.lock()
        if fd == sock { fd = -1 }
        fdLock.unlock()
        close(sock)
        fireClose()
    }

    private func fireClose() {
        onClose()
    }
}

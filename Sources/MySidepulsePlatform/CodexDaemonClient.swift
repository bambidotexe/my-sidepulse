import Foundation
import MySidepulseCore

/// Asks Codex's managed daemon, which hosts the TUI's sessions, about its
/// threads: `thread/read` (one thread's status) and `thread/loaded/list`
/// (the threads it holds in memory). The control socket is a WebSocket over
/// a unix socket; each call opens it, upgrades it, sends `initialize`,
/// `initialized` and the one read, and closes it. Nothing else is ever sent
/// (`CodexDaemonRPC.methods`). The protocol is undocumented and versioned,
/// so every call fails closed: a refusal, a timeout, a record of a thread
/// other than the one asked about, or an answer of any other shape
/// completes with nil, and the rollout decides. The I/O runs on
/// a utility queue, non-blocking, never past `deadlineSeconds` from the
/// call, and every completion runs on the main queue.
public enum CodexDaemonClient {
    /// The whole of a call, connection and upgrade included.
    public static let deadlineSeconds: Double = 1

    /// Whether the link resolves to a socket: when it does not, the daemon is
    /// not running and is not asked.
    public static func socketExists(_ socket: URL = Paths.codexControlSocket) -> Bool {
        resolved(socket) != nil
    }

    public static func readThread(id: String, socket: URL = Paths.codexControlSocket,
                                  completion: @escaping (CodexThreadRecord?) -> Void) {
        call(CodexDaemonRPC.threadRead(threadId: id), socket: socket,
             read: { CodexThreadRecord.parse($0, expecting: id) }, completion: completion)
    }

    public static func loadedThreadIds(socket: URL = Paths.codexControlSocket,
                                       completion: @escaping (Set<String>?) -> Void) {
        call(CodexDaemonRPC.loadedList, socket: socket, read: CodexThreadRecord.loadedThreadIds, completion: completion)
    }

    // MARK: the exchange

    private static let queue = DispatchQueue(label: "mysidepulse.codex-daemon", qos: .utility, attributes: .concurrent)

    private static func call<T>(_ request: String, socket: URL, read: @escaping (Data) -> T?,
                                completion: @escaping (T?) -> Void) {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(deadlineSeconds * 1_000_000_000)
        queue.async {
            let answer = exchange(request, socket: socket, deadline: deadline).flatMap(read)
            DispatchQueue.main.async { completion(answer) }
        }
    }

    /// The daemon's socket, the link resolved; nil when it is missing or not
    /// a socket.
    private static func resolved(_ socket: URL) -> String? {
        guard let real = realpath(socket.path, nil) else { return nil }
        defer { free(real) }
        var info = stat()
        guard stat(real, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else { return nil }
        return String(cString: real)
    }

    /// The payload of the answer to `request`, or nil.
    private static func exchange(_ request: String, socket: URL, deadline: UInt64) -> Data? {
        guard let path = resolved(socket) else { return nil }
        let fd = Darwin.socket(PF_LOCAL, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var on: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { return nil }
        var link = Link(fd: fd, deadline: deadline)
        let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        // `Sec-WebSocket-Accept` is not checked: the socket is the user's own,
        // `0600` and local, and a `101` is all the exchange needs.
        guard link.connect(to: path),
              link.send(Data(CodexDaemonRPC.upgradeRequest(key: key).utf8)),
              let head = link.head(), CodexDaemonRPC.upgradeAccepted(head),
              link.send(WebSocketFrame.encodeText(CodexDaemonRPC.initialize(version: version))),
              let initialized = link.answer(to: CodexDaemonRPC.initializeId), CodexDaemonRPC.isInitialized(initialized),
              link.send(WebSocketFrame.encodeText(CodexDaemonRPC.initialized)),
              link.send(WebSocketFrame.encodeText(request)) else { return nil }
        return link.answer(to: CodexDaemonRPC.callId)
    }

    /// One non-blocking connection and what it has read and not yet
    /// consumed. Every wait is a `poll` bounded by the call's deadline, and
    /// the deadline is checked before every read, however many bytes keep
    /// arriving.
    private struct Link {
        let fd: Int32
        let deadline: UInt64
        var buffer = Data()
        /// A response head longer than this is not the daemon's.
        static let headMaxBytes = 16 * 1024

        func connect(to path: String) -> Bool {
            var address = ControlSocketAddress.make(path: path)
            guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result == 0 { return true }
            guard errno == EINPROGRESS, wait(for: Int16(POLLOUT)) else { return false }
            var failure: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            return getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &size) == 0 && failure == 0
        }

        func send(_ data: Data) -> Bool {
            var sent = 0
            while sent < data.count {
                guard !expired else { return false }
                let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + sent, data.count - sent) }
                if n > 0 { sent += n; continue }
                guard n < 0, errno == EAGAIN || errno == EINTR, wait(for: Int16(POLLOUT)) else { return false }
            }
            return true
        }

        /// The response head up to its blank line; what follows it stays in
        /// the buffer.
        mutating func head() -> String? {
            let blank = Data("\r\n\r\n".utf8)
            while true {
                if let end = buffer.range(of: blank) {
                    let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                    buffer = Data(buffer[end.upperBound...])
                    return head
                }
                guard buffer.count < Self.headMaxBytes, fill() else { return nil }
            }
        }

        /// The payload of the frame answering `id`, reading past
        /// notifications, other ids, pings and pongs; nil for an error, a
        /// close, a frame that can never be an answer, the end of the stream
        /// or the deadline.
        mutating func answer(to id: Int) -> Data? {
            while true {
                guard !expired else { return nil }
                switch WebSocketFrame.decode(buffer) {
                case .frame(let payload, let consumed):
                    buffer = Data(buffer.dropFirst(consumed))
                    switch CodexDaemonRPC.answer(payload, to: id) {
                    case .unrelated: continue
                    case .result: return payload
                    case .failed: return nil
                    }
                case .skip(let consumed):
                    buffer = Data(buffer.dropFirst(consumed))
                case .closed, .invalid:
                    return nil
                case .incomplete:
                    guard fill() else { return nil }
                }
            }
        }

        var expired: Bool { DispatchTime.now().uptimeNanoseconds >= deadline }

        /// Reads what has arrived, waiting for it until the deadline; false
        /// at the end of the stream or past the deadline, even while bytes
        /// keep coming.
        mutating func fill() -> Bool {
            var chunk = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                guard !expired else { return false }
                let n = Darwin.read(fd, &chunk, chunk.count)
                if n > 0 { buffer.append(contentsOf: chunk[0..<n]); return true }
                guard n < 0, errno == EAGAIN || errno == EINTR, wait(for: Int16(POLLIN)) else { return false }
            }
        }

        /// Whether `events` came before the deadline.
        func wait(for events: Int16) -> Bool {
            while true {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { return false }
                var descriptor = pollfd(fd: fd, events: events, revents: 0)
                let result = poll(&descriptor, 1, Int32(max(1, (deadline - now) / 1_000_000)))
                if result > 0 { return true }
                if result < 0, errno == EINTR { continue }
                if result < 0 { return false }
            }
        }
    }
}

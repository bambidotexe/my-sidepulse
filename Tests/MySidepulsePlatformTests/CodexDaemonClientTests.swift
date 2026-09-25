import XCTest
import MySidepulseCore
@testable import MySidepulsePlatform

/// A stand-in for Codex's daemon on a temp unix socket, speaking the shapes
/// the read-only probe saw from Codex 0.157: an HTTP upgrade answered `101`,
/// then JSON-RPC in WebSocket text frames, unmasked from the server,
/// notifications between the answers.
final class FakeCodexDaemon {
    enum Script {
        /// Answers the upgrade, `initialize` and the call; `pingFirst` sends a
        /// ping, a notification and an answer to another id before the answer.
        case answers(String, pingFirst: Bool)
        /// Accepts the connection and never writes a byte.
        case silent
        /// Answers the upgrade, then nothing.
        case stallAfterUpgrade
        /// Answers the upgrade and `initialize`, then sends notifications
        /// without end.
        case streamNotifications
        /// Answers the upgrade, then closes the WebSocket.
        case closeAfterUpgrade
    }

    let path: String
    let link: String
    private let listener: Int32
    private let script: Script
    private let lock = NSLock()
    private var stopped = false
    private var received: [String] = []
    private let done = DispatchSemaphore(value: 0)

    var methods: [String] { lock.lock(); defer { lock.unlock() }; return received }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    init(_ script: Script) throws {
        self.script = script
        // sockaddr_un.sun_path caps at 104 bytes — keep it short.
        let name = "/tmp/mspd-\(UInt32.random(in: 0..<UInt32.max))"
        path = name + ".sock"
        link = name + ".link"
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = ControlSocketAddress.make(path: path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(listener, 4) == 0 else { throw POSIXError(.EADDRINUSE) }
        // The daemon's socket is reached through a link, as Codex's is.
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
        Thread.detachNewThread { [self] in serve() }
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        _ = done.wait(timeout: .now() + 3)
        close(listener)
        unlink(path); unlink(link)
    }

    private func serve() {
        defer { done.signal() }
        while !isStopped {
            var p = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 50) > 0 else { continue }
            let conn = accept(listener, nil, nil)
            guard conn >= 0 else { continue }
            var on: Int32 = 1
            setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 0, tv_usec: 100_000)
            setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            handle(conn)
            close(conn)
        }
    }

    private func handle(_ conn: Int32) {
        var buffer = Data()
        func fill() -> Bool {
            var chunk = [UInt8](repeating: 0, count: 4096)
            while !isStopped {
                let n = read(conn, &chunk, chunk.count)
                if n > 0 { buffer.append(contentsOf: chunk[0..<n]); return true }
                if n == 0 { return false }
                if errno != EAGAIN && errno != EINTR { return false }
            }
            return false
        }
        func drain() { while fill() { buffer.removeAll() } }
        func send(_ data: Data) -> Bool {
            data.withUnsafeBytes { write(conn, $0.baseAddress, data.count) } == data.count
        }
        /// The next client frame's method, unmasked; nil at the end of the stream.
        func nextMethod() -> String? {
            while true {
                let b = [UInt8](buffer)
                if b.count >= 2, b[1] & 0x80 != 0 {
                    var length = Int(b[1] & 0x7F), offset = 2
                    if length == 126, b.count >= 4 { length = Int(b[2]) << 8 | Int(b[3]); offset = 4 }
                    if b.count >= offset + 4 + length, length < 126 || offset == 4 {
                        let key = Array(b[offset..<offset + 4])
                        let payload = Data(b[(offset + 4)..<(offset + 4 + length)].enumerated().map { $0.element ^ key[$0.offset % 4] })
                        buffer = Data(b[(offset + 4 + length)...])
                        let method = ((try? JSONSerialization.jsonObject(with: payload)) as? [String: Any])?["method"] as? String ?? "?"
                        lock.lock(); received.append(method); lock.unlock()
                        return method
                    }
                }
                guard fill() else { return nil }
            }
        }
        if case .silent = script { return drain() }
        while buffer.range(of: Data("\r\n\r\n".utf8)) == nil { guard fill() else { return } }
        buffer = Data(buffer[buffer.range(of: Data("\r\n\r\n".utf8))!.upperBound...])
        _ = send(Data("HTTP/1.1 101 Switching Protocols\r\nconnection: upgrade\r\nupgrade: websocket\r\n\r\n".utf8))
        switch script {
        case .stallAfterUpgrade: return drain()
        case .closeAfterUpgrade: _ = send(Data([0x88, 0x02, 0x03, 0xE8])); return
        default: break
        }
        guard nextMethod() == "initialize" else { return }
        _ = send(Self.frame(#"{"method":"remoteControl/status/changed","params":{"status":"x"},"emittedAtMs":1}"#))
        _ = send(Self.frame(#"{"id":1,"result":{"userAgent":"fake/0.157","codexHome":"/x","platformFamily":"unix","platformOs":"macos"}}"#))
        if case .streamNotifications = script {
            while !isStopped, send(Self.frame(#"{"method":"thread/status/changed","params":{},"emittedAtMs":1}"#)) {}
            return
        }
        guard nextMethod() == "initialized", nextMethod() != nil else { return }
        guard case .answers(let reply, let pingFirst) = script else { return }
        if pingFirst {
            _ = send(Data([0x89, 0x04]) + Data("ping".utf8))
            _ = send(Self.frame(#"{"method":"thread/started","params":{}}"#))
            _ = send(Self.frame(#"{"id":7,"result":{}}"#))
        }
        _ = send(Self.frame(reply))
        drain()
    }

    /// An unmasked server text frame.
    static func frame(_ text: String) -> Data {
        let payload = Data(text.utf8)
        let header: [UInt8] = payload.count < 126
            ? [0x81, UInt8(payload.count)]
            : [0x81, 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        return Data(header) + payload
    }
}

final class CodexDaemonClientTests: XCTestCase {
    static let notLoaded = #"{"id":2,"result":{"thread":{"id":"t1","status":{"type":"notLoaded"},"path":"/x/rollout-t1.jsonl","updatedAt":1790000100,"turns":[]}}}"#

    /// Asks `socket` about thread `t1`, returning the record and how long the
    /// answer took; fails if the completion was not on main.
    func read(_ socket: String) -> (record: CodexThreadRecord?, seconds: TimeInterval) {
        let asked = Date()
        var answer: (CodexThreadRecord?, TimeInterval)?
        let answered = expectation(description: "completion")
        CodexDaemonClient.readThread(id: "t1", socket: URL(fileURLWithPath: socket)) { record in
            XCTAssertTrue(Thread.isMainThread, "completions run on main")
            answer = (record, Date().timeIntervalSince(asked))
            answered.fulfill()
        }
        wait(for: [answered], timeout: 3)
        return answer ?? (nil, .infinity)
    }

    func testANotLoadedThreadIsOver() throws {
        let daemon = try FakeCodexDaemon(.answers(Self.notLoaded, pingFirst: false))
        defer { daemon.stop() }
        let answer = read(daemon.link)
        XCTAssertEqual(answer.record?.verdict(), .over)
        XCTAssertEqual(answer.record?.rolloutPath, "/x/rollout-t1.jsonl")
        XCTAssertEqual(daemon.methods, ["initialize", "initialized", "thread/read"], "nothing but the read is asked")
    }

    func testAPingANotificationAndAnotherIdBeforeTheReplyAreReadPast() throws {
        let daemon = try FakeCodexDaemon(.answers(Self.notLoaded, pingFirst: true))
        defer { daemon.stop() }
        XCTAssertEqual(read(daemon.link).record?.verdict(), .over)
    }

    func testTheLoadedListIsRead() throws {
        let daemon = try FakeCodexDaemon(.answers(#"{"id":2,"result":{"data":["a",{"id":"b"}],"nextCursor":null}}"#, pingFirst: false))
        defer { daemon.stop() }
        var ids: Set<String>?
        let answered = expectation(description: "completion")
        CodexDaemonClient.loadedThreadIds(socket: URL(fileURLWithPath: daemon.link)) { ids = $0; answered.fulfill() }
        wait(for: [answered], timeout: 3)
        XCTAssertEqual(ids, ["a", "b"])
        XCTAssertEqual(daemon.methods, ["initialize", "initialized", "thread/loaded/list"])
    }

    func testARefusalIsNil() throws {
        let daemon = try FakeCodexDaemon(.answers(#"{"id":2,"error":{"code":-32600,"message":"no such thread"}}"#, pingFirst: false))
        defer { daemon.stop() }
        XCTAssertNil(read(daemon.link).record)
    }

    func testAServerThatNeverAnswersIsNilWithinTheDeadline() throws {
        let daemon = try FakeCodexDaemon(.silent)
        defer { daemon.stop() }
        let answer = read(daemon.link)
        XCTAssertNil(answer.record)
        XCTAssertLessThan(answer.seconds, 1.5)
    }

    func testAServerThatStallsAfterTheUpgradeIsNilWithinTheDeadline() throws {
        let daemon = try FakeCodexDaemon(.stallAfterUpgrade)
        defer { daemon.stop() }
        let answer = read(daemon.link)
        XCTAssertNil(answer.record)
        XCTAssertLessThan(answer.seconds, 1.5)
    }

    /// Bytes that keep arriving must not hold the call past its deadline.
    func testStreamingNotificationsCannotHoldTheCallPastItsDeadline() throws {
        let daemon = try FakeCodexDaemon(.streamNotifications)
        defer { daemon.stop() }
        let answer = read(daemon.link)
        XCTAssertNil(answer.record)
        XCTAssertLessThan(answer.seconds, 1.5)
    }

    func testACloseEndsTheCallAtOnce() throws {
        let daemon = try FakeCodexDaemon(.closeAfterUpgrade)
        defer { daemon.stop() }
        let answer = read(daemon.link)
        XCTAssertNil(answer.record)
        XCTAssertLessThan(answer.seconds, 0.5)
    }

    func testAMissingSocketIsNilAtOnce() {
        let missing = "/tmp/mspd-missing-\(UInt32.random(in: 0..<UInt32.max)).sock"
        XCTAssertFalse(CodexDaemonClient.socketExists(URL(fileURLWithPath: missing)))
        let answer = read(missing)
        XCTAssertNil(answer.record)
        XCTAssertLessThan(answer.seconds, 0.2)
    }

    func testAPlainFileIsNoSocket() throws {
        let file = "/tmp/mspd-file-\(UInt32.random(in: 0..<UInt32.max))"
        FileManager.default.createFile(atPath: file, contents: Data())
        defer { unlink(file) }
        XCTAssertFalse(CodexDaemonClient.socketExists(URL(fileURLWithPath: file)))
        XCTAssertNil(read(file).record)
    }

    func testTheControlSocketIsUnderCodexHome() {
        XCTAssertEqual(Paths.codexControlSocket.path,
                       Paths.codexHome.appendingPathComponent("app-server-control/app-server-control.sock").path)
    }
}

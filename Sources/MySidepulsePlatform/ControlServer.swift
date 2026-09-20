import Foundation

public final class ControlServer {
    public var handler: ((ControlRequest) -> ControlResponse)?
    private let path: String
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "mysidepulse.control")

    /// Total time one connection may take to deliver its request line.
    /// SO_RCVTIMEO bounds each read; this bounds the whole exchange, so a
    /// slow client cannot hold the serial queue and starve the CLI.
    static let requestDeadlineSeconds: TimeInterval = 3

    private var retryTimer: DispatchSourceTimer?

    public init(socketPath: String) { self.path = socketPath }

    /// Keep trying until the socket is ours: a bind failure leaves the app
    /// headless — the strip keeps working, but `mysidepulse status`, `led`,
    /// `doctor` and `notify` have nothing to talk to until it succeeds. Each
    /// failure is reported, and the first success stops the timer.
    public func startRetrying(every seconds: TimeInterval,
                              onFailure: @escaping (Error) -> Void) {
        do {
            try start()
            return
        } catch {
            onFailure(error)
        }
        guard retryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds, repeating: seconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            do {
                try self.start()
                self.retryTimer?.cancel()
                self.retryTimer = nil
            } catch {
                onFailure(error)
            }
        }
        timer.resume()
        retryTimer = timer
    }

    public func start() throws {
        // Darwin raises SIGPIPE (default disposition: terminate the process) on
        // write() to a peer that already closed its end — a garbage client that
        // writes and disconnects immediately must not be able to kill the server
        // this way. SO_NOSIGPIPE is the usual per-socket fix, but it returns
        // EINVAL for AF_UNIX stream sockets on this platform, so ignore the
        // signal process-wide instead; every write path below already checks
        // its return value / uses `try?`, so a resulting EPIPE is handled.
        signal(SIGPIPE, SIG_IGN)
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)

        // Only reclaim a socket nobody is listening on. Unlinking a live one
        // leaves the running instance silently unreachable: it keeps its
        // descriptor while every future client connects to our path instead.
        if FileManager.default.fileExists(atPath: path) {
            if Self.isListening(at: path) { throw ControlServerError.alreadyRunning }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlServerError.socketFailed(errno) }
        var addr = ControlSocketAddress.make(path: path)
        // Create it owner-only from the start; chmod afterwards would leave a
        // window where the socket exists at a laxer mode.
        let previousMask = umask(0o177)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previousMask)
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw ControlServerError.bindFailed(code)
        }
        guard listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            throw ControlServerError.listenFailed(code)
        }
        if chmod(path, 0o600) != 0 {
            let code = errno
            close(fd)
            unlink(path)
            throw ControlServerError.bindFailed(code)
        }
        self.fd = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    public func stop() {
        retryTimer?.cancel()
        retryTimer = nil
        // Never unlink a socket this instance does not own: a second instance
        // quitting would otherwise cut the live one off from the CLI forever.
        guard source != nil || fd >= 0 else { return }
        source?.cancel()
        source = nil
        fd = -1
        unlink(path)
    }

    /// True once this instance owns the socket.
    public var isServing: Bool { source != nil }

    /// True when something is accepting connections on this path.
    static func isListening(at path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = ControlSocketAddress.make(path: path)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return connected == 0
    }

    private func acceptOne() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(Self.requestDeadlineSeconds)
        while !data.contains(0x0A), data.count < 1_000_000, Date() < deadline {
            let n = read(client, &buffer, buffer.count)
            guard n > 0 else { break }
            data.append(contentsOf: buffer[0..<n])
        }
        guard let newline = data.firstIndex(of: 0x0A) else { return }
        let requestData = data.subdata(in: data.startIndex..<newline)
        let response: ControlResponse
        if let request = try? JSONDecoder().decode(ControlRequest.self, from: requestData) {
            response = handler?(request) ?? ControlResponse(ok: false, error: "no handler")
        } else {
            response = ControlResponse(ok: false, error: "bad request")
        }
        guard var out = try? JSONEncoder().encode(response) else { return }
        out.append(0x0A)
        _ = out.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
    }
}

import Foundation

public enum ControlClient {
    public static func send(_ request: ControlRequest, socketPath: String,
                            timeoutSeconds: Int32 = 2) -> ControlResponse? {
        // See ControlServer.start(): SO_NOSIGPIPE is unavailable for AF_UNIX
        // stream sockets on this platform, so guard the whole process instead —
        // a server that vanishes mid-write must not crash the client either.
        signal(SIGPIPE, SIG_IGN)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var timeout = timeval(tv_sec: time_t(timeoutSeconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var addr = ControlSocketAddress.make(path: socketPath)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0, var out = try? JSONEncoder().encode(request) else { return nil }
        out.append(0x0A)
        let written = out.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == out.count else { return nil }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !data.contains(0x0A), data.count < 1_000_000 {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            data.append(contentsOf: buffer[0..<n])
        }
        guard let newline = data.firstIndex(of: 0x0A) else { return nil }
        return try? JSONDecoder().decode(ControlResponse.self,
                                         from: data.subdata(in: data.startIndex..<newline))
    }
}

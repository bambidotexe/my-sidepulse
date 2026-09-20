import Foundation
import Dispatch
import Darwin
import MySidepulseCore

/// Tails the journal with kqueue (via DispatchSource). Single reader: start()
/// drains everything already on disk — that is the startup replay — then
/// live appends arrive within milliseconds. Rotation (rename) is followed by
/// draining the old inode and re-arming on the recreated path.
public final class JournalTailer {
    public var onEvents: (([JournalEvent]) -> Void)?
    private let url: URL
    private let queue: DispatchQueue
    private var fd: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var remainder = Data()
    private var stopped = false

    /// How long to wait before retrying an open() that failed. Only ever
    /// runs while the tailer has no source armed.
    private static let reopenRetrySeconds: TimeInterval = 0.5

    public init(url: URL, queue: DispatchQueue = DispatchQueue(label: "mysidepulse.tailer")) {
        self.url = url
        self.queue = queue
    }

    public func start() {
        queue.sync {
            openAndArm()
            drain()
        }
    }

    public func stop() {
        queue.sync {
            stopped = true
            source?.cancel()
            source = nil
        }
    }

    public static func readAll(url: URL) -> [JournalEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { JournalCodec.decodeLine(Data($0)) }
    }

    private func openAndArm() {
        // Atomic: O_CREAT with no O_TRUNC either opens the existing inode
        // untouched or creates an empty one — a single kernel call with no
        // check-then-act window. FileManager.fileExists + createFile() would
        // race a hook process's own O_CREAT open: if it wins that race and
        // writes before we get here, an unconditional createFile() call
        // truncates its data away (confirmed empirically — same path, new
        // inode, size back to 0) and the tailer waits forever for a write
        // that already happened.
        let fd = open(url.path, O_RDONLY | O_CREAT, 0o644)
        guard fd >= 0 else {
            // Never leave a stale descriptor behind, and never give up: with
            // no source armed the tailer would silently stop delivering every
            // future event, which is the one failure this design must not have.
            self.fd = -1
            scheduleReopen()
            return
        }
        self.fd = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            let flags = source.data
            self.drain()
            if flags.contains(.rename) || flags.contains(.delete) {
                // Old inode is finished: re-arm on the recreated path.
                self.source?.cancel()
                self.source = nil
                self.remainder.removeAll()
                self.openAndArm()
                self.drain()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    private func scheduleReopen() {
        guard !stopped else { return }
        queue.asyncAfter(deadline: .now() + Self.reopenRetrySeconds) { [weak self] in
            guard let self, !self.stopped, self.source == nil else { return }
            self.openAndArm()
            self.drain()
        }
    }

    private func drain() {
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            remainder.append(contentsOf: buffer[0..<n])
        }
        deliverCompleteLines()
    }

    private func deliverCompleteLines() {
        var events: [JournalEvent] = []
        while let newline = remainder.firstIndex(of: 0x0A) {
            let lineData = remainder.subdata(in: remainder.startIndex..<newline)
            remainder.removeSubrange(remainder.startIndex...newline)
            guard !lineData.isEmpty else { continue }
            if let event = JournalCodec.decodeLine(lineData) { events.append(event) }
        }
        if !events.isEmpty { onEvents?(events) }
    }
}

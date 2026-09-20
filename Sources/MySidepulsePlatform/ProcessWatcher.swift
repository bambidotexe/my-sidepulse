import Foundation

/// kqueue EVFILT_PROC via DispatchSource: the instant a watched Claude
/// process exits — however it exits — onExit fires. This is what removes
/// stuck sessions without waiting for a SessionEnd that may never come.
public final class ProcessWatcher {
    public var onExit: ((Int32) -> Void)?
    private var sources: [Int32: DispatchSourceProcess] = [:]
    private let queue: DispatchQueue

    public init(queue: DispatchQueue = .main) { self.queue = queue }

    public func watch(pid: Int32) {
        queue.async { [self] in
            guard sources[pid] == nil else { return }
            guard kill(pid, 0) == 0 || errno == EPERM else {
                onExit?(pid)
                return
            }
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.sources.removeValue(forKey: pid)?.cancel()
                self.onExit?(pid)
            }
            source.resume()
            sources[pid] = source
            // The pid may have died between the liveness check and resume():
            // the kqueue attach silently misses an already-dead process.
            if kill(pid, 0) != 0 && errno != EPERM {
                sources.removeValue(forKey: pid)?.cancel()
                onExit?(pid)
            }
        }
    }

    public func unwatchAll(except keep: Set<Int32>) {
        queue.async { [self] in
            for (pid, source) in sources where !keep.contains(pid) {
                source.cancel()
                sources.removeValue(forKey: pid)
            }
        }
    }
}

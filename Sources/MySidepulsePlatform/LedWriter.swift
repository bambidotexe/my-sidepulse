import Darwin
import Foundation
import MySidepulseCore

/// All device writes go through one serial queue with a watchdog: a stalled
/// USB volume may freeze the strip, never the brain. Queued writes collapse
/// to the latest desired program per device.
public final class LedWriter {
    private let state = DispatchQueue(label: "mysidepulse.ledwriter.state")
    private let io = DispatchQueue(label: "mysidepulse.ledwriter.io")
    private var lastProgram: [DeviceKey: String] = [:]
    private var pending: [DeviceKey: (program: String, device: LedDevice)] = [:]
    private var stalled: Set<DeviceKey> = []
    private var inFlight: [DeviceKey: UUID] = [:]
    private var performed = 0
    public var onWriteCompleted: (() -> Void)?
    public var onStall: ((DeviceKey) -> Void)?
    public var onRecover: ((DeviceKey) -> Void)?

    public init() {}

    public var writesPerformed: Int { state.sync { performed } }
    public var stalledKeys: Set<DeviceKey> { state.sync { stalled } }

    public func deviceAppeared(_ device: LedDevice) {
        state.sync {
            stalled.remove(device.key)
            lastProgram.removeValue(forKey: device.key)
        }
    }

    public func deviceGone(_ key: DeviceKey) {
        state.sync {
            stalled.remove(key)
            lastProgram.removeValue(forKey: key)
            pending.removeValue(forKey: key)
            // Clears the token a still-in-flight write is racing against, so
            // a stale watchdog closure whose deadline fires after this can no
            // longer match `inFlight[key] == token` and mark an already-
            // departed device stalled. It does not by itself stop that write
            // from repopulating `lastProgram` on completion — that guard
            // lives in performPending's own `isCurrent` check.
            inFlight.removeValue(forKey: key)
        }
    }

    public func write(program: String, to device: LedDevice) {
        let shouldQueue: Bool = state.sync {
            guard lastProgram[device.key] != program else { return false }
            let alreadyQueued = pending[device.key] != nil
            pending[device.key] = (program, device)
            // A stalled device still records what it should be showing, but
            // starts no work: the write the watchdog gave up on still owns
            // the io queue, and when the stall clears this is what says what
            // the strip should show.
            return !alreadyQueued && !stalled.contains(device.key)
        }
        guard shouldQueue else { return }
        io.async { [weak self] in self?.performPending(for: device.key) }
    }

    private func performPending(for key: DeviceKey) {
        guard let started: (job: (program: String, device: LedDevice), token: UUID) = state.sync(execute: {
            // Order matters: testing `stalled` first leaves the pending job
            // in place, where the recovery drain can still find it.
            guard !stalled.contains(key), let job = pending.removeValue(forKey: key) else { return nil }
            let token = UUID()
            inFlight[key] = token
            state.asyncAfter(deadline: .now() + K.writeWatchdogSeconds) { [weak self] in
                guard let self, self.inFlight[key] == token else { return }
                self.stalled.insert(key)
                // Never invoke the callback while holding `state`: a handler
                // that calls back into the writer would state.sync onto the
                // queue it is already running on, and deadlock.
                let callback = self.onStall
                DispatchQueue.global(qos: .utility).async { callback?(key) }
            }
            return (job, token)
        }) else { return }
        let job = started.job
        let token = started.token

        let ok = Self.writeFile(job.program, path: job.device.ledsFilePath)
        var recovered = false
        var drain = false
        state.sync {
            // Only the device's current in-flight job may update state.
            // deviceGone() clears inFlight, so a write that completes after
            // the device left must not repopulate lastProgram under a key
            // nothing owns any more.
            let isCurrent = inFlight[key] == token
            inFlight.removeValue(forKey: key)
            guard isCurrent else { return }
            // The write the watchdog gave up on has *returned*, so the io queue
            // is free and the volume was slow, not hung — a power transition
            // with the lid closed does this. This is the only recovery signal
            // that needs no physical replug; deviceAppeared/deviceGone are the
            // other two, and both need one.
            // A volume that is genuinely hung never reaches here — its write
            // never returns — so the protection this flag exists for is
            // untouched. The outcome deliberately does not matter: a write that
            // *failed* still proves the queue is free, and failing leaves
            // lastProgram alone, so the next sync() retries the same program
            // rather than deduping it away.
            recovered = stalled.remove(key) != nil
            if ok {
                lastProgram[key] = job.program
                performed += 1
            }
            drain = recovered && pending[key] != nil
        }
        if recovered {
            // Never call out while holding `state`, for the same reason the
            // watchdog does not: a handler calling back in would deadlock.
            let callback = onRecover
            DispatchQueue.global(qos: .utility).async { callback?(key) }
        }
        onWriteCompleted?()
        // Paint what accumulated while the stall was up.
        if drain { io.async { [weak self] in self?.performPending(for: key) } }
    }

    /// The quit path: write one program to every strip and wait, once, for
    /// all of them. It bypasses the queue above deliberately — that one
    /// returns before the write has happened, which on the way out means the
    /// process exits with the strip still lit.
    ///
    /// One write per strip in parallel, so a card that has stopped answering
    /// cannot keep the others lit, and the wait is bounded: a filesystem call
    /// on a dying card never returns, and quitting must not depend on it.
    /// Returns whether every strip went dark within `timeout`; the writes that
    /// missed it are abandoned, not cancelled — they cannot be.
    ///
    /// Blocks the calling thread for up to `timeout`, which is why it belongs
    /// only to a process that is going away.
    @discardableResult
    public static func blackout(paths: [String], program: String,
                                timeout: TimeInterval) -> Bool {
        guard !paths.isEmpty else { return true }
        let group = DispatchGroup()
        let landed = DispatchQueue(label: "mysidepulse.ledwriter.blackout")
        var written = 0
        for path in paths {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                let ok = writeFile(program, path: path)
                landed.sync { if ok { written += 1 } }
            }
        }
        guard group.wait(timeout: .now() + timeout) == .success else { return false }
        return landed.sync { written } == paths.count
    }

    static func writeFile(_ program: String, path: String) -> Bool {
        let fd = open(path, O_WRONLY | O_TRUNC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let data = Array(program.utf8)
        // Qualified: an unqualified `write` here resolves against this
        // type's own `write(program:to:)` instance method (present in
        // scope even from a static context) rather than falling back to
        // the global Darwin syscall, and fails to compile.
        return Darwin.write(fd, data, data.count) == data.count
    }
}

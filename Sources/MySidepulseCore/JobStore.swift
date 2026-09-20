import Foundation

public enum JobState: Equatable { case running, succeeded, failed }

/// One ordinary command borrowing the strip. Pushed by `mysidepulse run` or a
/// shell hook; never discovered. Not journaled — a job is seconds-to-minutes
/// of transient state, and an app restart is allowed to forget it.
public struct Job: Equatable {
    public var id: String
    /// Watched for death: while this process is gone and the job is still
    /// running, the job is cleared. For `mysidepulse run` this is the wrapper.
    public var ownerPid: Int32?
    /// The job slot — one job per terminal. Beginning a job evicts whatever
    /// else holds the same slot. For `mysidepulse run` this is the shell that
    /// started it, which is NOT the wrapper: the wrapper is a fresh process
    /// per invocation, so keying eviction on it would let every run linger.
    public var slotPid: Int32?
    public var label: String?
    public var hostBundleId: String?
    public var state: JobState = .running
    public var stateSince: Date
    /// Not displayable until this instant; nil once elapsed. `tick` consumes
    /// it, so the Arbiter stays a pure function of state with no clock.
    public var showAfter: Date?
    public var acknowledged: Bool = false
    /// As for sessions: an outcome proves it will stick before it shows.
    public var settlingFrom: JobState?
    public var settlingUntil: Date?

    public var presentedState: JobState { settlingFrom ?? state }
}

public struct JobStore {
    public private(set) var jobs: [String: Job] = [:]
    public init() {}

    public mutating func begin(id: String, pid: Int32?, slotPid: Int32?, label: String?,
                               hostBundleId: String?, showAfterSeconds: Double, now: Date) {
        // One job per terminal. Without this, a failed `make test` stays amber
        // over the next command's running colour for twenty minutes.
        if let slotPid { jobs = jobs.filter { $0.value.slotPid != slotPid } }
        var job = Job(id: id, ownerPid: pid, slotPid: slotPid, label: label,
                      hostBundleId: hostBundleId, stateSince: now, showAfter: nil)
        if showAfterSeconds > 0 { job.showAfter = now.addingTimeInterval(showAfterSeconds) }
        jobs[id] = job
    }

    /// What a shell reports for the two signals a terminal raises from the
    /// keyboard: 128 + SIGINT (Ctrl-C) and 128 + SIGQUIT (Ctrl-\). Someone who
    /// just pressed the key knows the command stopped, so there is nothing for
    /// the strip to announce. Signals from anywhere else — a stray SIGTERM, an
    /// OOM kill — stay failures, because nobody chose those.
    public static let cancellationStatuses: Set<Int32> = [130, 131]

    public mutating func end(id: String, exitCode: Int32, now: Date) {
        guard var job = jobs[id] else { return }
        // Matches what `mysidepulse run` already does on Ctrl-C, where the
        // wrapper dies with its child and pid-death clears the job. The two
        // paths have to agree or the strip depends on how you started it.
        if Self.cancellationStatuses.contains(exitCode) {
            jobs.removeValue(forKey: id)
            return
        }
        // A command that finished inside its grace never lights the strip at
        // all — outcome included. That is the whole point of --show-after.
        if let showAfter = job.showAfter, showAfter > now {
            jobs.removeValue(forKey: id)
            return
        }
        job.settlingFrom = job.state
        job.settlingUntil = now.addingTimeInterval(K.alertSettleSeconds)
        job.state = exitCode == 0 ? .succeeded : .failed
        job.stateSince = now
        job.acknowledged = false
        job.showAfter = nil
        jobs[id] = job
    }

    /// `mysidepulse run` reports its result and exits, so its death arrives a
    /// moment after the outcome. Clearing unconditionally would erase the
    /// green it just asked for.
    public mutating func processExited(pid: Int32) {
        jobs = jobs.filter { $0.value.ownerPid != pid || $0.value.state != .running }
    }

    public mutating func tick(now: Date) {
        for (id, original) in jobs {
            var job = original
            if let showAfter = job.showAfter, showAfter <= now { job.showAfter = nil }
            if let until = job.settlingUntil, until <= now {
                job.settlingFrom = nil
                job.settlingUntil = nil
            }
            let ttl = job.state == .running ? K.jobStaleSeconds : K.jobVisibleSeconds
            if now.timeIntervalSince(job.stateSince) >= ttl {
                jobs.removeValue(forKey: id)
                continue
            }
            jobs[id] = job
        }
    }

    public func nextDeadline(after now: Date) -> Date? {
        var deadlines: [Date] = []
        for job in jobs.values {
            if let showAfter = job.showAfter { deadlines.append(showAfter) }
            if let settlingUntil = job.settlingUntil { deadlines.append(settlingUntil) }
            let ttl = job.state == .running ? K.jobStaleSeconds : K.jobVisibleSeconds
            deadlines.append(job.stateSince.addingTimeInterval(ttl))
        }
        return deadlines.filter { $0 > now }.min()
    }

    /// A finished job is an unread notification, acknowledged by focusing the
    /// terminal it was started from — the same policy sessions use.
    @discardableResult
    public mutating func acknowledge(hostBundleId: String) -> Bool {
        var changed = false
        for (id, original) in jobs {
            var job = original
            guard !job.acknowledged, job.state != .running,
                  job.hostBundleId == hostBundleId else { continue }
            job.acknowledged = true
            job.settlingFrom = nil
            job.settlingUntil = nil
            changed = true
            jobs[id] = job
        }
        return changed
    }

    public var trackedPids: Set<Int32> {
        Set(jobs.values.filter { $0.state == .running }.compactMap(\.ownerPid))
    }

    /// What the Arbiter may act on. Sorted so a multi-job decision is stable.
    public var displayable: [Job] {
        jobs.values
            .filter { $0.showAfter == nil && ($0.state == .running || !$0.acknowledged) }
            .sorted { $0.id < $1.id }
    }
}

import Foundation

public enum JobState: Equatable { case running, succeeded, failed }

/// One ordinary command borrowing the strip. Pushed by `mysidepulse run` or a
/// shell hook; never discovered. Not journaled — a job is seconds-to-minutes
/// of transient state, and an app restart is allowed to forget it.
public struct Job: Equatable {
    public var id: String
    /// Watched for death: while this process is gone and the job is still
    /// running, the job is cleared. For `mysidepulse run` this is the wrapper;
    /// for the shell hooks, the shell, which is also asked whether it still
    /// runs a command (`probe`).
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
    /// When a probe first found the shell at its prompt with no child started
    /// since the job began (`ShellJobLiveness.judge`).
    public var promptSeenAt: Date?

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

    /// What the job's shell answered (`ShellJobLiveness`), for a running
    /// job; the reason when that clears it, else nil. A cleared job leaves no
    /// outcome, like a cancellation: its end was never seen.
    public mutating func probe(id: String, _ probe: ShellJobLiveness.Probe, now: Date) -> String? {
        guard var job = jobs[id], job.state == .running else { return nil }
        switch ShellJobLiveness.judge(probe, promptSeenAt: &job.promptSeenAt, now: now) {
        case .keep:
            jobs[id] = job
            return nil
        case .drop(let reason):
            jobs.removeValue(forKey: id)
            return reason
        }
    }

    /// A running job with a pid is asked of that process and never timed
    /// out; one without is dropped after `K.jobStaleSeconds`. A finished job
    /// stays `K.jobVisibleSeconds`.
    public mutating func tick(now: Date) {
        for (id, original) in jobs {
            var job = original
            if let showAfter = job.showAfter, showAfter <= now { job.showAfter = nil }
            if let until = job.settlingUntil, until <= now {
                job.settlingFrom = nil
                job.settlingUntil = nil
            }
            if let ttl = Self.lifetime(of: job), now.timeIntervalSince(job.stateSince) >= ttl {
                jobs.removeValue(forKey: id)
                continue
            }
            jobs[id] = job
        }
    }

    /// How long a job lives in its state, nil for a running job with a pid.
    static func lifetime(of job: Job) -> TimeInterval? {
        guard job.state == .running else { return K.jobVisibleSeconds }
        return job.ownerPid == nil ? K.jobStaleSeconds : nil
    }

    /// The next show-after, settle or expiry instant; for a running job with
    /// a pid, the next probe (`K.jobProbeSeconds` from now) and the end of a
    /// prompt sighting's settle.
    public func nextDeadline(after now: Date) -> Date? {
        var deadlines: [Date] = []
        for job in jobs.values {
            if let showAfter = job.showAfter { deadlines.append(showAfter) }
            if let settlingUntil = job.settlingUntil { deadlines.append(settlingUntil) }
            if let ttl = Self.lifetime(of: job) {
                deadlines.append(job.stateSince.addingTimeInterval(ttl))
            } else {
                deadlines.append(now.addingTimeInterval(K.jobProbeSeconds))
                if let seen = job.promptSeenAt { deadlines.append(seen.addingTimeInterval(K.jobPromptSettleSeconds)) }
            }
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

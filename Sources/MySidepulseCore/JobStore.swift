import Foundation

public enum JobState: Equatable { case running, succeeded, failed }

/// One ordinary command borrowing the strip. Journaled by `mysidepulse run`
/// or a shell hook (`JobLine`) and folded in from the journal like every
/// other line, so a restart replays it; never discovered.
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

/// A seen job outcome, journaled so that a relaunch replays it seen: the job
/// and the `stateSince` of the outcome, which a shell's next outcome, under
/// the same job id, never shares.
public struct JobAckRecord: Equatable {
    public let jobId: String
    public let stateSince: Date
    public init(jobId: String, stateSince: Date) {
        self.jobId = jobId; self.stateSince = stateSince
    }
}

/// The journal lines of a terminal job: what the CLI writes for `job begin`,
/// `job end` and `run`, and the app for a seen outcome. Every field is
/// bounded, so a job's line always fits the journal's line cap.
public enum JobLine {
    public static func begin(id: String, pid: Int32?, slotPid: Int32?, label: String?,
                             showAfterSeconds: Double, hostBundleId: String?, loggedAt: Date) -> JournalEvent {
        var e = JournalEvent(loggedAt: loggedAt, event: .jobBegin)
        e.jobId = Trim.clamp(id)
        e.jobPid = pid
        e.jobSlotPid = slotPid
        e.jobLabel = label.map { String($0.prefix(K.jobLabelMaxChars)) }
        e.jobShowAfterSeconds = max(0, showAfterSeconds)
        e.hostBundleId = Trim.clamp(hostBundleId)
        return e
    }

    public static func end(id: String, exitCode: Int32, loggedAt: Date) -> JournalEvent {
        var e = JournalEvent(loggedAt: loggedAt, event: .jobEnd)
        e.jobId = Trim.clamp(id)
        e.jobExitCode = exitCode
        return e
    }

    public static func ack(_ record: JobAckRecord, loggedAt: Date) -> JournalEvent {
        var e = JournalEvent(loggedAt: loggedAt, event: .ack)
        e.jobId = Trim.clamp(record.jobId)
        e.ackStateSince = record.stateSince
        return e
    }
}

/// What one journal line did to the jobs.
public enum JobLineEffect: Equatable {
    /// Not a job's line: the session store's.
    case notAJobLine
    case applied
    /// A begin from a shell with an agent's process on its chain, dropped.
    case agentShell(pid: Int32, agent: AgentKind)
}

public struct JobStore {
    public private(set) var jobs: [String: Job] = [:]
    public init() {}

    /// Folds one journal line in, live or replayed, as of the line's own
    /// stamp. A job's lines are `.jobBegin`, `.jobEnd` and an `.ack` naming a
    /// job; the session store has no use for them. A begin with no slot takes
    /// its watched process as its slot, and one with no grace the `run`
    /// default; an end with no status is a success. A shell with an agent's
    /// process on its chain runs that agent's work, which its session shows:
    /// a begin whose watched pid `hostingAgent` places under an agent begins
    /// nothing, whichever CLI wrote it.
    @discardableResult
    public mutating func apply(_ e: JournalEvent,
                               hostingAgent: (Int32) -> AgentKind? = { _ in nil }) -> JobLineEffect {
        switch e.event {
        case .jobBegin:
            guard let id = e.jobId else { return .applied }
            if let pid = e.jobPid, let agent = hostingAgent(pid) { return .agentShell(pid: pid, agent: agent) }
            begin(id: id, pid: e.jobPid, slotPid: e.jobSlotPid ?? e.jobPid, label: e.jobLabel,
                  hostBundleId: e.hostBundleId,
                  showAfterSeconds: e.jobShowAfterSeconds ?? K.jobShowAfterDefaultSeconds, now: e.loggedAt)
        case .jobEnd:
            guard let id = e.jobId else { return .applied }
            end(id: id, exitCode: e.jobExitCode ?? 0, now: e.loggedAt)
        case .ack:
            guard let id = e.jobId else { return .notAJobLine }
            if let since = e.ackStateSince { acknowledge(JobAckRecord(jobId: id, stateSince: since)) }
        default:
            return .notAJobLine
        }
        return .applied
    }

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
    /// terminal it was started from — the same policy sessions use. Returns
    /// what was seen, for the journal.
    @discardableResult
    public mutating func acknowledge(hostBundleId: String) -> [JobAckRecord] {
        var seen: [JobAckRecord] = []
        for (id, original) in jobs {
            var job = original
            guard !job.acknowledged, job.state != .running,
                  job.hostBundleId == hostBundleId else { continue }
            job.acknowledged = true
            job.settlingFrom = nil
            job.settlingUntil = nil
            seen.append(JobAckRecord(jobId: id, stateSince: job.stateSince))
            jobs[id] = job
        }
        return seen.sorted { $0.jobId < $1.jobId }
    }

    /// A journaled acknowledgement, replayed: it clears only the outcome it
    /// was recorded against (its `stateSince`, within the journal's
    /// millisecond stamps), never a job in flight or a later outcome.
    mutating func acknowledge(_ record: JobAckRecord) {
        guard var job = jobs[record.jobId], job.state != .running,
              abs(job.stateSince.timeIntervalSince(record.stateSince)) < 0.005 else { return }
        job.acknowledged = true
        job.settlingFrom = nil
        job.settlingUntil = nil
        jobs[record.jobId] = job
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

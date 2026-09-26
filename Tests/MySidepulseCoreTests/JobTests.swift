import XCTest
@testable import MySidepulseCore

/// A non-Claude process claiming the strip for the length of a command.
final class JobTests: XCTestCase {
    func store(_ id: String = "j1", pid: Int32? = 900, slot: Int32? = nil,
               showAfter: Double = 0, host: String? = nil, at t: TimeInterval = 0) -> JobStore {
        var s = JobStore()
        s.begin(id: id, pid: pid, slotPid: slot ?? pid, label: "npm build", hostBundleId: host,
                showAfterSeconds: showAfter, now: at(t))
        return s
    }

    /// `mysidepulse run` is a fresh process each time, so its own pid cannot be
    /// the eviction key — two runs in a row would both linger, and a failure
    /// from twenty minutes ago would keep outranking a live Claude turn. The
    /// slot is the shell they were started from; the owner is the process to
    /// watch for death. For the shell hooks the two coincide.
    func testConsecutiveWrapperRunsFromOneShellEvictEachOther() {
        var s = JobStore()
        s.begin(id: "first", pid: 1001, slotPid: 900, label: "make test",
                hostBundleId: nil, showAfterSeconds: 0, now: at(0))
        s.end(id: "first", exitCode: 1, now: at(5))
        s.begin(id: "second", pid: 1002, slotPid: 900, label: "make test",
                hostBundleId: nil, showAfterSeconds: 0, now: at(6))
        XCTAssertNil(s.jobs["first"], "the previous run's failure is history")
        XCTAssertEqual(s.jobs.count, 1)
    }

    func testRunsFromDifferentShellsCoexist() {
        var s = JobStore()
        s.begin(id: "a", pid: 1001, slotPid: 900, label: nil, hostBundleId: nil,
                showAfterSeconds: 0, now: at(0))
        s.begin(id: "b", pid: 1002, slotPid: 901, label: nil, hostBundleId: nil,
                showAfterSeconds: 0, now: at(1))
        XCTAssertEqual(s.jobs.count, 2, "two terminals, two jobs")
    }

    /// The wrapper's death must still clear its own running job even though
    /// the slot belongs to the shell, which is very much alive.
    func testTheWrappersDeathClearsItsJobNotTheShellsSlot() {
        var s = JobStore()
        s.begin(id: "a", pid: 1001, slotPid: 900, label: nil, hostBundleId: nil,
                showAfterSeconds: 0, now: at(0))
        s.processExited(pid: 900)
        XCTAssertEqual(s.jobs.count, 1, "the shell is not the watched process")
        s.processExited(pid: 1001)
        XCTAssertTrue(s.jobs.isEmpty)
    }

    func testBeginRunsAndZeroExitSucceeds() {
        var s = store()
        XCTAssertEqual(s.jobs["j1"]?.state, .running)
        s.end(id: "j1", exitCode: 0, now: at(5))
        XCTAssertEqual(s.jobs["j1"]?.state, .succeeded)
        XCTAssertEqual(s.jobs["j1"]?.stateSince, at(5))
    }

    func testNonZeroExitFails() {
        var s = store()
        s.end(id: "j1", exitCode: 1, now: at(5))
        XCTAssertEqual(s.jobs["j1"]?.state, .failed)
    }

    /// Ctrl-C is someone deciding to stop, not something going wrong. They
    /// are at the keyboard by definition — the strip has nothing to tell them.
    /// `mysidepulse run` already behaves this way: the wrapper dies with its
    /// child and pid-death clears the job. The shell hook must agree.
    func testAnInterruptedCommandClearsRatherThanFailing() {
        for status: Int32 in [130, 131] {   // 128 + SIGINT, 128 + SIGQUIT
            var s = store()
            s.end(id: "j1", exitCode: status, now: at(5))
            XCTAssertTrue(s.jobs.isEmpty, "exit \(status) must leave nothing on the strip")
        }
    }

    /// The line is drawn at signals the terminal raises from the keyboard.
    /// Nobody chose an OOM kill or a stray SIGTERM, so those stay failures.
    func testASignalNobodyChoseIsStillAFailure() {
        for status: Int32 in [137, 143] {   // 128 + SIGKILL, 128 + SIGTERM
            var s = store()
            s.end(id: "j1", exitCode: status, now: at(5))
            XCTAssertEqual(s.jobs["j1"]?.state, .failed, "exit \(status) is worth knowing about")
        }
    }

    func testEndingAnUnknownJobIsIgnored() {
        var s = JobStore()
        s.end(id: "ghost", exitCode: 0, now: at(1))
        XCTAssertTrue(s.jobs.isEmpty, "a stale shell hook must not invent a job")
    }

    /// One job per originator. Without this a failed `make test` keeps the
    /// strip amber over the next command's running colour.
    func testBeginEvictsAnEarlierJobFromTheSameOwner() {
        var s = store("first", pid: 900)
        s.end(id: "first", exitCode: 1, now: at(5))
        s.begin(id: "second", pid: 900, slotPid: 900, label: "npm test", hostBundleId: nil,
                showAfterSeconds: 0, now: at(6))
        XCTAssertNil(s.jobs["first"], "the previous command's outcome is history")
        XCTAssertEqual(s.jobs["second"]?.state, .running)
    }

    func testBeginLeavesAnotherShellsJobAlone() {
        var s = store("first", pid: 900)
        s.begin(id: "second", pid: 901, slotPid: 901, label: "make", hostBundleId: nil,
                showAfterSeconds: 0, now: at(1))
        XCTAssertEqual(s.jobs.count, 2, "two terminals, two jobs")
    }

    /// `mysidepulse run` appends its end line and then exits, so its own death
    /// arrives a moment later. Clearing on death unconditionally would erase the green
    /// it just asked for.
    func testOwnerDeathClearsARunningJobButNotAFinishedOne() {
        var running = store()
        running.processExited(pid: 900)
        XCTAssertTrue(running.jobs.isEmpty, "Ctrl-C leaves nothing on the strip")

        var finished = store()
        finished.end(id: "j1", exitCode: 0, now: at(5))
        finished.processExited(pid: 900)
        XCTAssertEqual(finished.jobs["j1"]?.state, .succeeded,
                       "the wrapper exits immediately after reporting success")
    }

    func testTrackedPidsAreTheOwnersOfRunningJobs() {
        var s = store()
        XCTAssertEqual(s.trackedPids, [900])
        s.end(id: "j1", exitCode: 0, now: at(5))
        XCTAssertEqual(s.trackedPids, [], "nothing left to watch once it finished")
    }

    // MARK: show-after

    func testShowAfterHidesTheJobUntilItElapses() {
        var s = store(showAfter: 10)
        s.tick(now: at(9))
        XCTAssertEqual(s.displayable, [], "short commands must not light the strip")
        s.tick(now: at(10))
        XCTAssertEqual(s.displayable.map(\.state), [.running])
    }

    func testACommandThatFinishesBeforeItsShowAfterNeverAppears() {
        var s = store(showAfter: 10)
        s.end(id: "j1", exitCode: 1, now: at(3))
        XCTAssertTrue(s.jobs.isEmpty, "an `ls` that fails in 3 s is not news")
    }

    // MARK: expiry

    func testFinishedJobsExpireOnTheDoneWindow() {
        var s = store()
        s.end(id: "j1", exitCode: 0, now: at(5))
        s.tick(now: at(5 + K.jobVisibleSeconds - 1))
        XCTAssertEqual(s.jobs.count, 1)
        s.tick(now: at(5 + K.jobVisibleSeconds))
        XCTAssertTrue(s.jobs.isEmpty)
    }

    func testAnAbandonedRunningJobExpiresOnTheStalenessBackstop() {
        var s = store(pid: nil)
        s.tick(now: at(K.jobStaleSeconds - 1))
        XCTAssertEqual(s.jobs.count, 1, "a long build is not stale")
        s.tick(now: at(K.jobStaleSeconds))
        XCTAssertTrue(s.jobs.isEmpty, "no pid to watch, so time is the only backstop")
    }

    /// A job with a shell pid is asked of its shell, never timed out: a
    /// three-hour build keeps its colour for as long as it runs.
    func testAJobWithAShellIsNeverDroppedByStaleness() {
        var s = store("zsh-900", pid: 900)
        s.begin(id: "loose", pid: nil, slotPid: nil, label: nil, hostBundleId: nil,
                showAfterSeconds: 0, now: at(0))
        s.tick(now: at(K.jobStaleSeconds + 3600))
        XCTAssertEqual(Set(s.jobs.keys), ["zsh-900"], "only the job without a pid is timed out")
        XCTAssertEqual(s.displayable.map(\.state), [.running])
    }

    /// A `job end` that never arrived: the shell sits at its prompt with no
    /// child of the job, seen so twice `K.jobPromptSettleSeconds` apart.
    func testAProbeThatFindsTheShellAtItsPromptClearsTheJob() {
        var s = store("zsh-900", pid: 900, showAfter: 5)
        let prompt = ShellJobLiveness.Probe(alive: true, isShell: true, atPrompt: true, hasChildren: false)
        XCTAssertNil(s.probe(id: "zsh-900", prompt, now: at(1)), "probed from the begin, shown or not")
        XCTAssertEqual(s.jobs["zsh-900"]?.promptSeenAt, at(1))
        XCTAssertEqual(s.nextDeadline(after: at(5)), at(1 + K.jobPromptSettleSeconds),
                       "asked again once the settle has run, not at the next probe")
        XCTAssertNil(s.probe(id: "zsh-900", prompt, now: at(3)))
        XCTAssertEqual(s.probe(id: "zsh-900", prompt, now: at(1 + K.jobPromptSettleSeconds)), "shell at its prompt")
        XCTAssertTrue(s.jobs.isEmpty, "cleared, with no outcome")
        XCTAssertNil(s.probe(id: "zsh-900", prompt, now: at(8)), "an unknown job is not dropped twice")

        var gone = store("zsh-901", pid: 901)
        let dead = ShellJobLiveness.Probe(alive: false, isShell: false, atPrompt: false, hasChildren: false)
        XCTAssertEqual(gone.probe(id: "zsh-901", dead, now: at(1)), "shell gone")
        XCTAssertTrue(gone.jobs.isEmpty)
    }

    /// An outcome is not a command in flight: its shell at the prompt is
    /// exactly what a finished job looks like.
    func testAProbeLeavesAFinishedJobAlone() {
        var s = store("zsh-900", pid: 900)
        s.end(id: "zsh-900", exitCode: 0, now: at(5))
        let prompt = ShellJobLiveness.Probe(alive: true, isShell: true, atPrompt: true, hasChildren: false)
        XCTAssertNil(s.probe(id: "zsh-900", prompt, now: at(6)))
        XCTAssertNil(s.probe(id: "zsh-900", prompt, now: at(20)))
        XCTAssertEqual(s.jobs["zsh-900"]?.state, .succeeded)
    }

    func testARunningJobWithAPidIsProbedEveryProbeInterval() {
        let s = store(pid: 900)
        XCTAssertEqual(s.nextDeadline(after: at(30)), at(30 + K.jobProbeSeconds))
        let loose = store(pid: nil)
        XCTAssertEqual(loose.nextDeadline(after: at(30)), at(K.jobStaleSeconds),
                       "a job without a pid is only timed out")
    }

    // MARK: acknowledgement

    func testFocusingTheOriginatingTerminalAcknowledges() {
        var s = store(host: "com.mitchellh.ghostty")
        s.end(id: "j1", exitCode: 0, now: at(5))
        XCTAssertEqual(s.acknowledge(hostBundleId: "com.mitchellh.ghostty"),
                       [JobAckRecord(jobId: "j1", stateSince: at(5))], "what the journal records")
        XCTAssertEqual(s.displayable, [], "seen jobs go dark, exactly like a Claude alert")
    }

    func testAnotherAppsFocusDoesNotAcknowledge() {
        var s = store(host: "com.mitchellh.ghostty")
        s.end(id: "j1", exitCode: 1, now: at(5))
        XCTAssertEqual(s.acknowledge(hostBundleId: "com.apple.Safari"), [])
        XCTAssertEqual(s.displayable.map(\.state), [.failed])
    }

    func testARunningJobIsNotAcknowledgeable() {
        var s = store(host: "com.mitchellh.ghostty")
        XCTAssertEqual(s.acknowledge(hostBundleId: "com.mitchellh.ghostty"), [],
                       "a job in flight is not an unread notification")
    }

    // MARK: the journal

    /// What `job begin`, `job end` and `run` write: what the command said,
    /// every field bounded.
    func testTheJobLinesCarryWhatTheCommandSaid() {
        let begin = JobLine.begin(id: "zsh-900", pid: 1001, slotPid: 900, label: "npm build",
                                  showAfterSeconds: 5, hostBundleId: "com.mitchellh.ghostty", loggedAt: at(0))
        XCTAssertEqual(begin.event, .jobBegin)
        XCTAssertEqual(begin.loggedAt, at(0))
        XCTAssertEqual(begin.jobId, "zsh-900"); XCTAssertEqual(begin.jobPid, 1001); XCTAssertEqual(begin.jobSlotPid, 900)
        XCTAssertEqual(begin.jobLabel, "npm build"); XCTAssertEqual(begin.jobShowAfterSeconds, 5)
        XCTAssertEqual(begin.hostBundleId, "com.mitchellh.ghostty")
        XCTAssertNil(begin.sessionId); XCTAssertNil(begin.agent)

        let long = JobLine.begin(id: String(repeating: "i", count: 500), pid: 1, slotPid: 1,
                                 label: String(repeating: "l", count: 500), showAfterSeconds: -3,
                                 hostBundleId: String(repeating: "h", count: 500), loggedAt: at(0))
        XCTAssertEqual(long.jobId?.count, 200)
        XCTAssertEqual(long.jobLabel?.count, K.jobLabelMaxChars)
        XCTAssertEqual(long.hostBundleId?.count, 200)
        XCTAssertEqual(long.jobShowAfterSeconds, 0, "a negative grace is none")

        let end = JobLine.end(id: "zsh-900", exitCode: 2, loggedAt: at(9))
        XCTAssertEqual(end.event, .jobEnd); XCTAssertEqual(end.jobId, "zsh-900"); XCTAssertEqual(end.jobExitCode, 2)
        XCTAssertNil(end.jobPid)
    }

    /// A begin line begins the job as of its own stamp, live or replayed:
    /// the stamp is what the shell's probe measures its children and its
    /// fork time against.
    func testABeginLineBeginsTheJobAtItsOwnStamp() {
        var s = JobStore()
        XCTAssertEqual(s.apply(JobLine.begin(id: "zsh-900", pid: 900, slotPid: 900, label: "make",
                                             showAfterSeconds: 5, hostBundleId: "com.apple.Terminal", loggedAt: at(0))),
                       .applied)
        let job = s.jobs["zsh-900"]
        XCTAssertEqual(job?.state, .running); XCTAssertEqual(job?.stateSince, at(0))
        XCTAssertEqual(job?.showAfter, at(5)); XCTAssertEqual(job?.label, "make")
        XCTAssertEqual(job?.ownerPid, 900); XCTAssertEqual(job?.slotPid, 900)
        XCTAssertEqual(job?.hostBundleId, "com.apple.Terminal")

        var run = JobStore()
        var wrapper = JobLine.begin(id: "u1", pid: 1001, slotPid: 900, label: nil, showAfterSeconds: 0,
                                    hostBundleId: nil, loggedAt: at(0))
        run.apply(wrapper)
        XCTAssertEqual(run.jobs["u1"]?.slotPid, 900, "the wrapper's slot is its shell")
        XCTAssertNil(run.jobs["u1"]?.showAfter)
        wrapper.jobId = "u2"; wrapper.jobSlotPid = nil; wrapper.jobShowAfterSeconds = nil
        run.apply(wrapper)
        XCTAssertEqual(run.jobs["u2"]?.slotPid, 1001, "no slot: the watched process is its own")
        XCTAssertNil(run.jobs["u2"]?.showAfter, "no grace named: \(K.jobShowAfterDefaultSeconds) s")
    }

    /// The end line carries the outcome, at its own stamp: exit 0 green,
    /// anything else amber, Ctrl-C and Ctrl-\ nothing at all.
    func testAnEndLineCarriesTheOutcome() {
        for (code, state) in [(Int32(0), JobState?.some(.succeeded)), (1, .failed), (137, .failed), (130, nil), (131, nil)] {
            var s = store("zsh-900", pid: 900)
            XCTAssertEqual(s.apply(JobLine.end(id: "zsh-900", exitCode: code, loggedAt: at(7))), .applied)
            XCTAssertEqual(s.jobs["zsh-900"]?.state, state, "exit \(code)")
            if state != nil { XCTAssertEqual(s.jobs["zsh-900"]?.stateSince, at(7)) }
        }
        var early = store("zsh-900", pid: 900, showAfter: 5)
        early.apply(JobLine.end(id: "zsh-900", exitCode: 1, loggedAt: at(3)))
        XCTAssertTrue(early.jobs.isEmpty, "ended inside its grace by the line's own stamp")
        var old = store("zsh-900", pid: 900)
        var lineWithoutCode = JobLine.end(id: "zsh-900", exitCode: 0, loggedAt: at(7))
        lineWithoutCode.jobExitCode = nil
        old.apply(lineWithoutCode)
        XCTAssertEqual(old.jobs["zsh-900"]?.state, .succeeded)
    }

    /// At launch a replayed running job counts only once its shell has been
    /// asked: a shell gone, or a pid now held by a process forked after the
    /// begin line, leaves nothing to show; one at its prompt goes through
    /// the settle.
    func testAReplayedRunningJobIsProbedBeforeItShows() {
        func replayed() -> JobStore {
            var s = JobStore()
            s.apply(JobLine.begin(id: "zsh-900", pid: 900, slotPid: 900, label: "make",
                                  showAfterSeconds: 5, hostBundleId: nil, loggedAt: at(0)))
            s.tick(now: at(600))
            return s
        }
        let launch = at(600)
        XCTAssertEqual(replayed().displayable.map(\.id), ["zsh-900"], "its grace ran out while the app was away")
        let jobSince = replayed().jobs["zsh-900"]!.stateSince

        var gone = replayed()
        XCTAssertEqual(gone.probe(id: "zsh-900", ShellJobLiveness.probe(nil, children: [], jobSince: jobSince),
                                  now: launch), "shell gone")
        XCTAssertEqual(gone.displayable, [])

        var recycled = replayed()
        let stranger = ShellJobLiveness.Reading(isShell: true, pgid: 900, tpgid: 900, startedAt: at(300))
        XCTAssertEqual(recycled.probe(id: "zsh-900", ShellJobLiveness.probe(stranger, children: [], jobSince: jobSince),
                                      now: launch), "shell gone", "forked after the begin line: not the job's shell")

        var prompt = replayed()
        let idle = ShellJobLiveness.Reading(isShell: true, pgid: 900, tpgid: 900, startedAt: at(-60))
        let atPrompt = ShellJobLiveness.probe(idle, children: [at(-59)], jobSince: jobSince)
        XCTAssertNil(prompt.probe(id: "zsh-900", atPrompt, now: launch))
        XCTAssertEqual(prompt.probe(id: "zsh-900", atPrompt, now: launch.addingTimeInterval(K.jobPromptSettleSeconds)),
                       "shell at its prompt")

        var busy = replayed()
        let running = ShellJobLiveness.Reading(isShell: true, pgid: 900, tpgid: 1200, startedAt: at(-60))
        XCTAssertNil(busy.probe(id: "zsh-900", ShellJobLiveness.probe(running, children: [at(1)], jobSince: jobSince),
                                now: launch))
        XCTAssertEqual(busy.displayable.map(\.state), [.running], "a command still in the foreground shows")
    }

    /// A seen outcome is journaled against its own stamp, so a relaunch
    /// replays it seen, and the ack can never clear a later outcome of the
    /// same shell, whose job id is the same.
    func testAJobAckLineAcknowledgesOnlyTheOutcomeItWasRecordedAgainst() {
        var live = JobStore()
        let begin = JobLine.begin(id: "zsh-900", pid: 900, slotPid: 900, label: "make", showAfterSeconds: 0,
                                  hostBundleId: "com.apple.Terminal", loggedAt: at(0))
        let end = JobLine.end(id: "zsh-900", exitCode: 1, loggedAt: at(5))
        live.apply(begin); live.apply(end)
        let records = live.acknowledge(hostBundleId: "com.apple.Terminal")
        XCTAssertEqual(records, [JobAckRecord(jobId: "zsh-900", stateSince: at(5))])
        let ack = JobLine.ack(records[0], loggedAt: at(8))
        XCTAssertEqual(ack.event, .ack); XCTAssertEqual(ack.jobId, "zsh-900"); XCTAssertEqual(ack.ackStateSince, at(5))
        XCTAssertNil(ack.sessionId, "no session's acknowledgement")

        var replay = JobStore()
        for line in [begin, end, ack] { XCTAssertEqual(replay.apply(line), .applied) }
        XCTAssertEqual(replay.displayable, [], "seen before the restart, seen after it")

        var later = JobStore()
        let again = JobLine.begin(id: "zsh-900", pid: 900, slotPid: 900, label: "make", showAfterSeconds: 0,
                                  hostBundleId: "com.apple.Terminal", loggedAt: at(10))
        for line in [begin, end, again, JobLine.end(id: "zsh-900", exitCode: 1, loggedAt: at(15)), ack] { later.apply(line) }
        XCTAssertEqual(later.displayable.map(\.state), [.failed], "the ack was the earlier outcome's")

        var running = JobStore()
        running.apply(begin); running.apply(ack)
        XCTAssertEqual(running.displayable.map(\.state), [.running], "a job in flight is never acknowledged")
    }

    /// A begin line from a shell with an agent on its chain is that agent's
    /// work, live or replayed: no job, and the shell and agent come back for
    /// the log. Lines an older CLI wrote are dropped the same way. The chain
    /// is read from the line's watched pid; a line with none is not asked.
    func testABeginFromAShellUnderAnAgentIsDropped() {
        var asked: [Int32] = []
        let reader: (Int32) -> AgentKind? = { pid in asked.append(pid); return pid == 900 ? .opencode : nil }
        var s = JobStore()
        let underAgent = JobLine.begin(id: "zsh-900", pid: 900, slotPid: 900, label: "sleep", showAfterSeconds: 5,
                                       hostBundleId: nil, loggedAt: at(0))
        XCTAssertEqual(s.apply(underAgent, hostingAgent: reader), .agentShell(pid: 900, agent: .opencode))
        XCTAssertTrue(s.jobs.isEmpty)
        XCTAssertEqual(s.apply(JobLine.end(id: "zsh-900", exitCode: 1, loggedAt: at(9)), hostingAgent: reader), .applied)
        XCTAssertTrue(s.jobs.isEmpty, "its end finds nothing to end")

        var wrapper = JobLine.begin(id: "u1", pid: 1001, slotPid: 900, label: "make", showAfterSeconds: 0,
                                    hostBundleId: nil, loggedAt: at(10))
        XCTAssertEqual(s.apply(wrapper, hostingAgent: reader), .applied)
        XCTAssertEqual(s.jobs["u1"]?.state, .running, "a terminal's shell is the user's")
        wrapper.jobId = "u2"; wrapper.jobPid = nil
        XCTAssertEqual(s.apply(wrapper, hostingAgent: reader), .applied)
        XCTAssertEqual(asked, [900, 1001], "the chain is read from the watched pid, and only with one")

        var prompt = JournalEvent(loggedAt: at(0), event: .userPromptSubmit)
        prompt.sessionId = "s1"
        XCTAssertEqual(s.apply(prompt, hostingAgent: reader), .notAJobLine)
        XCTAssertEqual(asked.count, 2, "a session's line never walks a chain")
    }

    /// Only the job lines, and an ack naming a job, are the job store's; a
    /// session's lines are not, and the session store ignores the job lines.
    func testTheJobLinesAreTheJobStoresAlone() {
        var jobs = JobStore()
        var prompt = JournalEvent(loggedAt: at(0), event: .userPromptSubmit)
        prompt.sessionId = "s1"
        XCTAssertEqual(jobs.apply(prompt), .notAJobLine)
        var sessionAck = JournalEvent(loggedAt: at(0), event: .ack)
        sessionAck.sessionId = "s1"; sessionAck.ackStateSince = at(0)
        XCTAssertEqual(jobs.apply(sessionAck), .notAJobLine)
        XCTAssertTrue(jobs.jobs.isEmpty)

        var sessions = SessionStore()
        sessions.apply(JobLine.begin(id: "zsh-900", pid: 900, slotPid: 900, label: "make", showAfterSeconds: 0,
                                     hostBundleId: nil, loggedAt: at(0)))
        sessions.apply(JobLine.end(id: "zsh-900", exitCode: 0, loggedAt: at(1)))
        sessions.apply(JobLine.ack(JobAckRecord(jobId: "zsh-900", stateSince: at(1)), loggedAt: at(2)))
        XCTAssertTrue(sessions.sessions.isEmpty)
    }

    // MARK: scheduling

    func testNextDeadlineCoversShowAfterThenExpiry() {
        var s = store(showAfter: 10)
        XCTAssertEqual(s.nextDeadline(after: at(0)), at(10), "wake to light the strip")
        s.tick(now: at(10))
        s.end(id: "j1", exitCode: 0, now: at(12))
        XCTAssertEqual(s.nextDeadline(after: at(12)), at(12 + K.alertSettleSeconds),
                       "the outcome has to settle onto the strip first")
        s.tick(now: at(12 + K.alertSettleSeconds))
        XCTAssertEqual(s.nextDeadline(after: at(12 + K.alertSettleSeconds)),
                       at(12 + K.jobVisibleSeconds), "then it expires")
    }
}

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

    /// `mysidepulse run` sends job-end and then exits, so its own death arrives
    /// a moment later. Clearing on death unconditionally would erase the green
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

    // MARK: acknowledgement

    func testFocusingTheOriginatingTerminalAcknowledges() {
        var s = store(host: "com.mitchellh.ghostty")
        s.end(id: "j1", exitCode: 0, now: at(5))
        XCTAssertTrue(s.acknowledge(hostBundleId: "com.mitchellh.ghostty"))
        XCTAssertEqual(s.displayable, [], "seen jobs go dark, exactly like a Claude alert")
    }

    func testAnotherAppsFocusDoesNotAcknowledge() {
        var s = store(host: "com.mitchellh.ghostty")
        s.end(id: "j1", exitCode: 1, now: at(5))
        XCTAssertFalse(s.acknowledge(hostBundleId: "com.apple.Safari"))
        XCTAssertEqual(s.displayable.map(\.state), [.failed])
    }

    func testARunningJobIsNotAcknowledgeable() {
        var s = store(host: "com.mitchellh.ghostty")
        XCTAssertFalse(s.acknowledge(hostBundleId: "com.mitchellh.ghostty"),
                       "a job in flight is not an unread notification")
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

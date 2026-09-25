import XCTest
@testable import MySidepulseCore

final class TimerTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1_787_652_000)
    func at(_ t: TimeInterval) -> Date { base.addingTimeInterval(t) }

    func testDoneExpiresAfterTwentyMinutes() {
        var s = SessionStore()
        s.apply(ev(.stop, 0, tail: "Done."))
        s.tick(now: at(K.doneVisibleSeconds - 1))
        XCTAssertEqual(s.sessions["s1"]?.state, .done)
        s.tick(now: at(K.doneVisibleSeconds + 1))
        XCTAssertEqual(s.sessions["s1"]?.state, .idle)
    }

    /// `done` is the only verdict a hold can defer — a question is shown at
    /// once, helpers or not (see GoldenReplayTests). So the grace has exactly
    /// one thing to apply.
    func testHoldGraceAppliesTheDeferredDone() {
        var s = SessionStore()
        s.apply(ev(.subagentStart, 0, agent: "a1"))
        s.apply(ev(.stop, 1, tail: "Handed the rest to the helper."))
        XCTAssertEqual(s.sessions["s1"]?.state, .working)
        XCTAssertEqual(s.sessions["s1"]?.pendingDone, true)
        s.apply(ev(.subagentStop, 10, agent: "a1"))
        XCTAssertEqual(s.sessions["s1"]?.state, .working, "grace: main agent usually resumes")
        s.tick(now: at(10 + K.holdGraceSeconds - 1))
        XCTAssertEqual(s.sessions["s1"]?.state, .working)
        s.tick(now: at(10 + K.holdGraceSeconds + 1))
        XCTAssertEqual(s.sessions["s1"]?.state, .done, "the deferred done applies")
    }

    /// The same transcript with a question tail is held exactly the same:
    /// the tail is prose, and a prose question is a finished turn, so it
    /// defers behind the helper like any finish.
    func testAProseQuestionTailIsHeldLikeAnyFinish() {
        var s = SessionStore()
        s.apply(ev(.subagentStart, 0, agent: "a1"))
        s.apply(ev(.stop, 1, tail: "Anything else you need?"))
        XCTAssertEqual(s.sessions["s1"]?.state, .working)
        XCTAssertEqual(s.sessions["s1"]?.pendingDone, true, "deferred like any other done")
    }

    func testHoldTTLExpiresWithoutRelease() {
        var s = SessionStore()
        s.apply(ev(.stop, 0, tail: "Done.", bg: ["t1"]))
        s.tick(now: at(K.holdTTLSeconds - 1))
        XCTAssertEqual(s.sessions["s1"]?.state, .working)
        s.tick(now: at(K.holdTTLSeconds + 1))
        XCTAssertEqual(s.sessions["s1"]?.state, .done, "a hold can never stick forever")
    }

    func testMainAgentActivityCancelsPending() {
        var s = SessionStore()
        s.apply(ev(.subagentStart, 0, agent: "a1"))
        s.apply(ev(.stop, 1, tail: "Done."))
        s.apply(ev(.subagentStop, 2, agent: "a1"))
        s.apply(ev(.preToolUse, 3, tool: "Bash")) // woken by the finished helper
        XCTAssertEqual(s.sessions["s1"]?.pendingDone, false)
        s.tick(now: at(3 + K.holdGraceSeconds + 5))
        XCTAssertEqual(s.sessions["s1"]?.state, .working, "no stale disposition may fire")
    }

    func testStalenessBackstopRemoves() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0))
        s.tick(now: at(K.staleSeconds + 1))
        XCTAssertNil(s.sessions["s1"], "deep backstop: PID watch does the real work")
    }

    func testProcessExitedRemovesItsSessions() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0, pid: 42))
        s.apply(ev(.userPromptSubmit, 1, sid: "s2", pid: 43))
        s.processExited(pid: 42)
        XCTAssertNil(s.sessions["s1"])
        XCTAssertNotNil(s.sessions["s2"])
        XCTAssertEqual(s.trackedPids, [43])
    }

    func testPruneDeadKeepsUnknownPids() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0, pid: 42))
        s.apply(ev(.userPromptSubmit, 1, sid: "s2"))
        s.pruneDead { _, _ in false }
        XCTAssertNil(s.sessions["s1"])
        XCTAssertNotNil(s.sessions["s2"], "no pid → staleness handles it, never liveness")
    }

    func testNextDeadline() {
        var s = SessionStore()
        XCTAssertNil(s.nextDeadline(after: base))
        s.apply(ev(.stop, 0, tail: "Done."))
        // Three deadlines stack up after a Stop, nearest first: the alert has
        // to settle onto the strip, then it is notified, then it expires.
        XCTAssertEqual(s.nextDeadline(after: at(K.alertSettleSeconds / 2)), at(K.alertSettleSeconds),
                       "the settle is the nearest deadline")
        _ = s.tick(now: at(K.alertSettleSeconds))
        XCTAssertEqual(s.nextDeadline(after: at(K.alertSettleSeconds)), at(K.notifyDebounceSeconds),
                       "then the notification debounce")
        _ = s.tick(now: at(K.notifyDebounceSeconds))
        XCTAssertEqual(s.nextDeadline(after: at(K.notifyDebounceSeconds)),
                       at(K.doneVisibleSeconds), "then done expiry")
    }
}

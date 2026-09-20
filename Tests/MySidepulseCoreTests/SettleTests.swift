import XCTest
@testable import MySidepulseCore

/// An alert state must prove it will stick before it reaches the strip.
///
/// These tests pin the MECHANISM at whatever K.alertSettleSeconds is set to,
/// not one particular threshold. What the threshold buys is a separate
/// question: replaying 803 recorded events found the shortest real flash held
/// 2.59 s and the next shortest 8.97 s, so only a threshold above 2.59 s
/// suppresses the case that prompted the feature. See the constant.
final class SettleTests: XCTestCase {
    func shown(_ store: SessionStore, jobs: [Job] = []) -> DisplayState {
        Arbiter.decide(mode: .auto, power: nil, glanceActive: false,
                       sessions: Array(store.sessions.values), jobs: jobs, now: Date())
    }

    /// An alert that is over before the window elapses never reaches the strip
    /// at all — checked across the WHOLE window, so the assertion cannot pass
    /// by simply not looking during the interval where green would show.
    func testAnAlertEndingInsideTheSettleWindowNeverShows() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0))
        s.apply(ev(.stop, 10, tail: "Done. All tests pass."))
        XCTAssertEqual(s.sessions["s1"]?.state, .done, "the state machine still records it")
        let reply = 10 + K.alertSettleSeconds * 0.9
        for t in stride(from: 10.0, through: reply, by: K.alertSettleSeconds / 20) {
            _ = s.tick(now: at(t))
            XCTAssertEqual(shown(s), .working, "green must not appear at t=\(t)")
        }
        s.apply(ev(.userPromptSubmit, reply))
        _ = s.tick(now: at(reply))
        XCTAssertEqual(shown(s), .working, "and it never did")
        _ = s.tick(now: at(reply + K.alertSettleSeconds + 1))
        XCTAssertEqual(shown(s), .working, "still working; there was nothing pending to reveal")
    }

    /// The honest counterpart: past the window the alert does show, so a reply
    /// slower than the threshold still turns the strip green for a moment.
    /// This is what the threshold trades off, and it is why the value matters.
    func testAnAlertOutlastingTheWindowDoesShowBeforeItEnds() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0))
        s.apply(ev(.stop, 10, tail: "Done."))
        _ = s.tick(now: at(10 + K.alertSettleSeconds))
        XCTAssertEqual(shown(s), .done)
        s.apply(ev(.userPromptSubmit, 10 + K.alertSettleSeconds + 1))
        _ = s.tick(now: at(10 + K.alertSettleSeconds + 1))
        XCTAssertEqual(shown(s), .working)
    }

    func testAnAlertLeftStandingDoesReachTheStrip() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0))
        s.apply(ev(.stop, 10, tail: "Done."))
        _ = s.tick(now: at(10 + K.alertSettleSeconds - 0.01))
        XCTAssertEqual(shown(s), .working, "still settling")
        _ = s.tick(now: at(10 + K.alertSettleSeconds))
        XCTAssertEqual(shown(s), .done)
    }

    /// Not off, and not a dark gap: the strip holds the state it was in.
    func testTheStripHoldsTheOutgoingStateDuringTheSettle() {
        var s = SessionStore()
        s.apply(ev(.preToolUse, 0, tool: "Bash"))
        s.apply(ev(.stop, 1, tail: "Done."))
        _ = s.tick(now: at(1 + K.alertSettleSeconds / 2))
        XCTAssertEqual(shown(s), .working)
    }

    /// A repeat of an alert already on the strip — a second permission ask
    /// in a row — must not pull it back off for another settle.
    func testARepeatedAlertDoesNotRestartTheSettle() {
        var s = SessionStore()
        s.apply(ev(.permissionRequest, 0, tool: "Bash"))
        _ = s.tick(now: at(K.alertSettleSeconds))
        XCTAssertEqual(shown(s), .waiting)
        s.apply(ev(.permissionRequest, K.alertSettleSeconds + 1, tool: "Edit"))
        _ = s.tick(now: at(K.alertSettleSeconds + 1))
        XCTAssertEqual(shown(s), .waiting, "the ask repeated; the amber must stay lit")
    }

    /// Amber to green: keep showing amber until green has settled, rather than
    /// dropping to working in between.
    func testAnAlertReplacingAnAlertKeepsShowingTheOldOne() {
        var s = SessionStore()
        s.apply(ev(.permissionRequest, 0, tool: "Bash"))
        _ = s.tick(now: at(K.alertSettleSeconds))
        XCTAssertEqual(shown(s), .waiting)
        s.apply(ev(.stop, 20, tail: "Done."))
        _ = s.tick(now: at(20 + K.alertSettleSeconds / 2))
        XCTAssertEqual(shown(s), .waiting, "still amber while green settles")
        _ = s.tick(now: at(20 + K.alertSettleSeconds))
        XCTAssertEqual(shown(s), .done)
    }

    /// Seeing it is the point of the whole model: stop pretending immediately.
    func testAcknowledgingDuringTheSettleDropsItAtOnce() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0, host: "com.apple.Terminal"))
        s.apply(ev(.stop, 10, tail: "Done."))
        _ = s.tick(now: at(10 + K.alertSettleSeconds / 2))
        XCTAssertEqual(shown(s), .working)
        _ = s.acknowledgeAlerts(hostBundleId: "com.apple.Terminal")
        XCTAssertEqual(shown(s), .off, "acknowledged and settled away, not held red")
    }

    func testTheSettleDeadlineIsScheduled() {
        var s = SessionStore()
        s.apply(ev(.stop, 0, tail: "Done."))
        XCTAssertEqual(s.nextDeadline(after: at(0)), at(K.alertSettleSeconds),
                       "without this the strip only catches up on the next event")
    }

    // MARK: jobs get the same treatment

    func testAJobOutcomeSettlesBeforeItShows() {
        var jobs = JobStore()
        jobs.begin(id: "j", pid: 900, slotPid: 900, label: "make", hostBundleId: nil,
                   showAfterSeconds: 0, now: at(0))
        jobs.end(id: "j", exitCode: 1, now: at(1))
        jobs.tick(now: at(1 + K.alertSettleSeconds / 2))
        XCTAssertEqual(shown(SessionStore(), jobs: jobs.displayable), .jobRunning,
                       "a command that fails and is gone must not flash amber")
        jobs.tick(now: at(1 + K.alertSettleSeconds))
        XCTAssertEqual(shown(SessionStore(), jobs: jobs.displayable), .jobFailed)
    }

    func testAJobEvictedInsideTheSettleNeverShowsItsOutcome() {
        var jobs = JobStore()
        jobs.begin(id: "a", pid: 900, slotPid: 900, label: "first", hostBundleId: nil,
                   showAfterSeconds: 0, now: at(0))
        jobs.end(id: "a", exitCode: 1, now: at(1))
        jobs.begin(id: "b", pid: 901, slotPid: 900, label: "second", hostBundleId: nil,
                   showAfterSeconds: 0, now: at(2))
        jobs.tick(now: at(2))
        XCTAssertEqual(shown(SessionStore(), jobs: jobs.displayable), .jobRunning)
        jobs.tick(now: at(30))
        XCTAssertEqual(shown(SessionStore(), jobs: jobs.displayable), .jobRunning,
                       "the failure was replaced before it ever reached the strip")
    }

    func testTheJobSettleDeadlineIsScheduled() {
        var jobs = JobStore()
        jobs.begin(id: "j", pid: 900, slotPid: 900, label: nil, hostBundleId: nil,
                   showAfterSeconds: 0, now: at(0))
        jobs.end(id: "j", exitCode: 0, now: at(1))
        XCTAssertEqual(jobs.nextDeadline(after: at(1)), at(1 + K.alertSettleSeconds))
    }
}

import XCTest
@testable import MySidepulseCore

/// The base instant shared with `ev()` in SessionStoreTests.
func at(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_787_652_000 + t) }

/// Notifications hang off ENTERING an alert state, never off a raw Stop:
/// of 502 recorded Stop events, 234 had background work still running, so
/// announcing "done" on Stop alone would be wrong nearly half the time.
final class NotifyTests: XCTestCase {

    // MARK: the motivating case

    /// A Stop held by background work that later resumes must be silent.
    func testHeldStopThatResumesNeverNotifies() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0))
        s.apply(ev(.stop, 10, tail: "Kicked off the build.", bg: ["bash_1"]))
        XCTAssertEqual(s.sessions["s1"]?.state, .working, "held: background work still out")
        var fired: [Alert] = []
        for t in stride(from: 10.0, through: 300.0, by: 10) {
            fired += s.tick(now: at(t))
        }
        s.apply(ev(.postToolUse, 310, tool: "Bash", bg: ["bash_1"]))
        for t in stride(from: 310.0, through: 600.0, by: 10) {
            fired += s.tick(now: at(t))
        }
        XCTAssertEqual(fired, [], "a turn that resumed announced itself as finished")
    }

    /// The same session settling: exactly one alert, one debounce after it
    /// settles.
    func testSettledStopNotifiesExactlyOnceAfterTheDebounce() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0))
        s.apply(ev(.stop, 10, tail: "Done. All tests pass."))
        let due = 10 + K.notifyDebounceSeconds
        XCTAssertEqual(s.tick(now: at(due - 1)), [], "still inside the debounce")
        let fired = s.tick(now: at(due))
        XCTAssertEqual(fired.map(\.kind), [.finished])
        XCTAssertEqual(fired.map(\.sessionId), ["s1"])
        XCTAssertEqual(s.tick(now: at(due + 1)), [], "an alert fires once, not on every tick")
    }

    /// Held, then released by a second Stop: the debounce starts at the
    /// SETTLEMENT, not at the first Stop. Grace plus debounce is the
    /// documented worst case and it is correct — do not notify mid-build.
    func testHeldStopNotifiesFromTheMomentItSettles() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0))
        s.apply(ev(.stop, 10, tail: "Build running.", bg: ["bash_1"]))
        XCTAssertEqual(s.tick(now: at(45)), [], "no alert armed while held")
        s.apply(ev(.stop, 100, tail: "Build finished.", bg: []))
        XCTAssertEqual(s.sessions["s1"]?.state, .done)
        let due = 100 + K.notifyDebounceSeconds
        XCTAssertEqual(s.tick(now: at(due - 1)), [])
        XCTAssertEqual(s.tick(now: at(due)).map(\.kind), [.finished])
    }

    // MARK: cancellation

    func testResumeInsideTheWindowCancels() {
        var s = SessionStore()
        s.apply(ev(.stop, 0, tail: "Done."))
        s.apply(ev(.userPromptSubmit, 15))
        XCTAssertEqual(s.tick(now: at(30)), [])
        XCTAssertEqual(s.tick(now: at(60)), [])
    }

    func testAcknowledgementInsideTheWindowCancels() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0, host: "com.mitchellh.ghostty"))
        s.apply(ev(.stop, 10, tail: "Which one should I use?"))
        XCTAssertFalse(s.acknowledgeAlerts(hostBundleId: "com.mitchellh.ghostty").isEmpty)
        XCTAssertEqual(s.tick(now: at(40)), [], "you already saw it on the strip")
    }

    func testSessionEndInsideTheWindowCancels() {
        var s = SessionStore()
        s.apply(ev(.stop, 0, tail: "Done."))
        s.apply(ev(.sessionEnd, 15))
        XCTAssertEqual(s.tick(now: at(40)), [])
    }

    func testProcessDeathInsideTheWindowCancels() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0, pid: 4242))
        s.apply(ev(.stop, 10, tail: "Done."))
        s.processExited(pid: 4242)
        XCTAssertEqual(s.tick(now: at(40)), [])
    }

    /// A finished turn must not be announced twice: the strip goes green and
    /// the phone is told, and the 60 s idle nudge that follows must not turn
    /// it amber and push a second time. One finished turn is one
    /// notification.
    func testAFinishedTurnIsAnnouncedOnceNotTwice() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0))
        s.apply(ev(.stop, 10, tail: "Updated the docs; nothing committed."))
        var fired: [Alert] = []
        for t in stride(from: 10.0, through: 200.0, by: 5) {
            if t > 70 - 0.001 && t < 70 + 5 { s.apply(ev(.notification, 70, ntype: "idle_prompt")) }
            fired += s.tick(now: at(t))
        }
        XCTAssertEqual(fired.map(\.kind), [.finished],
                       "the 60 s idle nudge pushed a second time for the same finished turn")
    }

    // MARK: re-arming

    /// A second ask is a fresh unread alert, so each one restarts the
    /// debounce rather than letting the first deadline fire under a newer
    /// alert.
    func testARepeatAlertPushesTheDeadlineForward() {
        var s = SessionStore()
        s.apply(ev(.permissionRequest, 0, tool: "Bash"))
        s.apply(ev(.permissionRequest, 25, tool: "Edit"))
        XCTAssertEqual(s.tick(now: at(30)), [], "the second ask reset the debounce")
        XCTAssertEqual(s.tick(now: at(55)).map(\.kind), [.needsYou(.permission)])
    }

    // MARK: presence

    /// Present means the strip is doing the telling — but "seen" belongs to
    /// acknowledgement, so an alert never acknowledged is still unread and the
    /// push fires at the first tick that finds the user gone.
    func testUserAtTheMachineDefersUntilTheyLeave() {
        var s = SessionStore()
        s.apply(ev(.stop, 0, tail: "Done."))
        XCTAssertEqual(s.tick(now: at(40), userPresent: true), [],
                       "the strip is right there; do not also ring the phone")
        XCTAssertEqual(s.nextDeadline(after: at(40)), at(40 + K.notifyDeferRecheckSeconds),
                       "the deferred deadline must keep the one-shot timer armed")
        XCTAssertEqual(s.tick(now: at(70), userPresent: true), [], "still present, still quiet")
        XCTAssertEqual(s.tick(now: at(100), userPresent: false).map(\.kind), [.finished],
                       "they left without ever focusing the terminal — that alert is unread")
        XCTAssertEqual(s.tick(now: at(101), userPresent: false), [], "and it fires once")
    }

    func testAcknowledgementCancelsADeferredNotification() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0, host: "com.mitchellh.ghostty"))
        s.apply(ev(.stop, 10, tail: "Done."))
        XCTAssertEqual(s.tick(now: at(45), userPresent: true), [], "deferred while present")
        XCTAssertFalse(s.acknowledgeAlerts(hostBundleId: "com.mitchellh.ghostty").isEmpty)
        XCTAssertEqual(s.tick(now: at(200), userPresent: false), [],
                       "they saw it before leaving; the deferral dies with the ack")
    }

    /// A deferred deadline slept past is as stale as an original one: the
    /// user coming back hours later must not be pinged about it on the next
    /// absent tick.
    func testADeferredDeadlineSleptPastIsStillLateDropped() {
        var s = SessionStore()
        s.apply(ev(.stop, 0, tail: "Done."))
        XCTAssertEqual(s.tick(now: at(40), userPresent: true), [], "deferred to t=70")
        XCTAssertEqual(s.tick(now: at(70 + K.notifyMaxLatenessSeconds + 1), userPresent: false), [],
                       "the machine slept through the recheck — drop, not fire")
    }

    /// An unreadable idle time must notify rather than silently swallow.
    func testPresenceGateFailsOpen() {
        var s = SessionStore()
        s.apply(ev(.stop, 0, tail: "Done."))
        XCTAssertEqual(s.tick(now: at(40)).map(\.kind), [.finished])
    }

    // MARK: coverage of the amber states

    func testEveryWaitReasonNotifies() {
        let cases: [(String, JournalEvent, WaitReason)] = [
            ("question", ev(.preToolUse, 0, sid: "q", tool: "AskUserQuestion"), .question),
            ("permission", ev(.permissionRequest, 0, sid: "p", tool: "Bash"), .permission),
            ("plan", ev(.preToolUse, 0, sid: "l", tool: "ExitPlanMode"), .plan),
            ("error", ev(.stopFailure, 0, sid: "e"), .error),
        ]
        for (name, event, reason) in cases {
            var s = SessionStore()
            s.apply(event)
            XCTAssertEqual(s.tick(now: at(40)).map(\.kind), [.needsYou(reason)], name)
        }
    }

    /// A turn ending in a prose question must not push "Asking you
    /// something" and then have the 60 s idle nudge rewrite the wait and
    /// push "Waiting for you" for the same standing turn: the turn is
    /// simply finished, so it is one green, one push, and the nudge is an
    /// echo.
    func testAProseQuestionTurnPushesFinishedOnceAndTheNudgeAddsNothing() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0))
        s.apply(ev(.stop, 10, tail: "Nothing's committed yet. Want me to commit this, or leave it for now?"))
        var fired: [Alert] = []
        for t in stride(from: 10.0, through: 300.0, by: 5) {
            if t == 70 { s.apply(ev(.notification, 70, ntype: "idle_prompt")) }
            fired += s.tick(now: at(t))
        }
        XCTAssertEqual(fired.map(\.kind), [.finished])
    }

    // MARK: lateness

    /// Journal replay at app start, or a machine that slept through the
    /// deadline, must not announce a turn that finished long ago.
    func testANotificationTooLateIsDroppedNotFired() {
        var s = SessionStore()
        s.apply(ev(.stop, 0, tail: "Done."))
        let late = K.notifyDebounceSeconds + K.notifyMaxLatenessSeconds + 1
        XCTAssertEqual(s.tick(now: at(late)), [])
    }

    func testJustInsideTheLatenessWindowStillFires() {
        var s = SessionStore()
        s.apply(ev(.stop, 0, tail: "Done."))
        let late = K.notifyDebounceSeconds + K.notifyMaxLatenessSeconds
        XCTAssertEqual(s.tick(now: at(late)).map(\.kind), [.finished])
    }

    // MARK: scheduling

    func testTheNotifyDeadlineIsScheduled() {
        var s = SessionStore()
        s.apply(ev(.stop, 0, tail: "Done."))
        // The settle lands first; the notification deadline is the one after.
        _ = s.tick(now: at(K.alertSettleSeconds))
        XCTAssertEqual(s.nextDeadline(after: at(K.alertSettleSeconds)), at(K.notifyDebounceSeconds),
                       "without this the one-shot timer never wakes for the alert")
    }

    // MARK: copy — a device contract of its own

    func testAlertCopyIsExact() {
        XCTAssertEqual(AlertCopy.title, "Claude Code")
        let expected: [(AlertKind, String, String, String)] = [
            (.finished, "Finished", "Terminé", "white_check_mark"),
            (.needsYou(.question), "Asking you something", "Vous pose une question", "speech_balloon"),
            (.needsYou(.permission), "Needs permission", "Demande une permission", "lock"),
            (.needsYou(.plan), "Plan ready", "Plan prêt", "clipboard"),
            (.needsYou(.error), "Turn failed", "Échec du tour", "rotating_light"),
        ]
        for (kind, english, french, tag) in expected {
            withLanguage(.en) { XCTAssertEqual(AlertCopy.message(for: kind), english) }
            withLanguage(.fr) { XCTAssertEqual(AlertCopy.message(for: kind), french) }
            // The tag is the wire's, not the reader's: same in every language.
            for language in Language.allCases {
                withLanguage(language) { XCTAssertEqual(AlertCopy.tag(for: kind), tag) }
            }
        }
    }

    /// A push body is read on a phone's lock screen, so it stays short in every
    /// language, and it never ends in a full stop.
    func testEveryPushBodyIsShortInEveryLanguage() {
        let kinds: [AlertKind] = [.finished, .needsYou(.question), .needsYou(.permission),
                                  .needsYou(.plan), .needsYou(.error)]
        for language in Language.allCases {
            withLanguage(language) {
                for kind in kinds {
                    let body = AlertCopy.message(for: kind)
                    XCTAssertFalse(body.isEmpty, "\(language) \(kind)")
                    XCTAssertLessThanOrEqual(body.count, 30, "\(language): \(body)")
                    XCTAssertFalse(body.hasSuffix("."), "\(language): \(body)")
                }
            }
        }
    }
}

import XCTest
@testable import MySidepulseCore

final class GoldenReplayTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1_787_652_000)

    func replay(_ jsonl: String) -> SessionStore {
        var store = SessionStore()
        for line in jsonl.split(separator: "\n") where !line.isEmpty {
            guard let e = JournalCodec.decodeLine(Data(line.utf8)) else {
                XCTFail("fixture line failed to decode: \(line)")
                continue
            }
            store.apply(e)
        }
        return store
    }

    /// An alert settles for K.alertSettleSeconds before it reaches the strip
    /// (see SettleTests, and the recorded data behind that constant). These
    /// tests are about WHICH alert a transcript produces, not about that
    /// delay, so they look just past it. The tick runs on a copy, so the
    /// caller's store is not advanced.
    func display(_ store: SessionStore, power: PowerState? = nil, glance: Bool = false,
                 mode: LedMode = .auto) -> DisplayState {
        var settled = store
        let latest = settled.sessions.values.map(\.stateSince).max()
        if let latest {
            _ = settled.tick(now: latest.addingTimeInterval(K.alertSettleSeconds))
        }
        return Arbiter.decide(mode: mode, power: power, glanceActive: glance,
                              sessions: Array(settled.sessions.values),
                              now: latest?.addingTimeInterval(K.alertSettleSeconds) ?? Date())
    }

    /// A real-shaped session transcript: start, prompt, tools, stop.
    func testPlainTurnFromJournalText() {
        let store = replay("""
        {"logged_at":"2026-08-21T10:00:00.000Z","event":"SessionStart","session_id":"s1","source":"startup","claude_pid":4242,"host_bundle_id":"com.apple.Terminal","cwd":"/tmp/p"}
        {"logged_at":"2026-08-21T10:00:05.000Z","event":"UserPromptSubmit","session_id":"s1"}
        {"logged_at":"2026-08-21T10:00:06.000Z","event":"PreToolUse","session_id":"s1","tool_name":"Bash"}
        {"logged_at":"2026-08-21T10:00:08.000Z","event":"PostToolUse","session_id":"s1","tool_name":"Bash"}
        {"logged_at":"2026-08-21T10:00:20.000Z","event":"Stop","session_id":"s1","last_message_tail":"Done. All tests pass."}
        """)
        XCTAssertEqual(display(store), .done)
        // Intent, not bytes — ProgramTests pins the exact text, once.
        XCTAssertTrue(LedProgram.program(for: display(store), power: nil, ledCount: 8,
                                         brightness: 255).contains(K.doneGreen))
    }

    /// The turn ends by asking in prose: that is a FINISHED turn — green,
    /// never amber. Every one of the 18 question-tail Stops in the recorded
    /// journal was this shape ("Want me to commit this, or leave it for
    /// now?"); amber belongs to the strong signals, which have events of
    /// their own.
    func testProseQuestionAtStopShowsGreenNotAmber() {
        let store = replay("""
        {"logged_at":"2026-08-21T10:00:00.000Z","event":"UserPromptSubmit","session_id":"s1"}
        {"logged_at":"2026-08-21T10:01:00.000Z","event":"Stop","session_id":"s1","last_message_tail":"Root cause confirmed.\\n\\nWhat would you like to clarify?"}
        """)
        XCTAssertEqual(display(store), .done)
        let program = LedProgram.program(for: display(store), power: nil, ledCount: 8, brightness: 255)
        XCTAssertTrue(program.contains(K.doneGreen), "a finished turn shows green")
        XCTAssertFalse(program.contains(K.askAmber), "prose is not a request for attention")
    }

    /// A killed session never sends a SessionEnd; the PID death must darken
    /// the strip immediately rather than letting it linger.
    func testKilledSessionGoesDarkOnPidExit() {
        var store = replay("""
        {"logged_at":"2026-08-21T10:00:00.000Z","event":"UserPromptSubmit","session_id":"s1","claude_pid":4242}
        {"logged_at":"2026-08-21T10:00:06.000Z","event":"PreToolUse","session_id":"s1","tool_name":"Bash"}
        """)
        XCTAssertEqual(display(store), .working)
        store.processExited(pid: 4242)
        XCTAssertEqual(display(store), .off)
    }

    /// Replay-time variant of the same fix: rebuild from journal, prune dead.
    func testStartupPruneDropsDeadSessions() {
        var store = replay("""
        {"logged_at":"2026-08-21T09:00:00.000Z","event":"UserPromptSubmit","session_id":"dead","claude_pid":1111}
        {"logged_at":"2026-08-21T09:00:01.000Z","event":"UserPromptSubmit","session_id":"live","claude_pid":2222}
        """)
        store.pruneDead { _, pid in pid == 2222 }
        XCTAssertNil(store.sessions["dead"])
        XCTAssertEqual(display(store), .working)
    }

    func testPermissionAndPlanWaits() {
        var store = SessionStore()
        store.apply(ev(.userPromptSubmit, 0))
        store.apply(ev(.permissionRequest, 5, tool: "Bash"))
        XCTAssertEqual(display(store), .waiting)
        store.apply(ev(.preToolUse, 8, tool: "Bash"))
        XCTAssertEqual(display(store), .working)
        store.apply(ev(.preToolUse, 9, tool: "ExitPlanMode"))
        XCTAssertEqual(display(store), .waiting)
        store.apply(ev(.postToolUse, 60, tool: "ExitPlanMode"))
        XCTAssertEqual(display(store), .working)
    }

    func testSubagentHoldThenGraceDisposition() {
        var store = SessionStore()
        store.apply(ev(.userPromptSubmit, 0))
        store.apply(ev(.subagentStart, 1, agent: "a1"))
        store.apply(ev(.stop, 2, tail: "Helpers are still running."))
        XCTAssertEqual(display(store), .working, "held: helpers still out")
        store.apply(ev(.subagentStop, 30, agent: "a1"))
        store.tick(now: base.addingTimeInterval(30 + K.holdGraceSeconds + 1))
        XCTAssertEqual(display(store), .done)
    }

    func testResumePairKeepsExactlyOneSession() {
        let store = replay("""
        {"logged_at":"2026-08-21T10:00:00.000Z","event":"UserPromptSubmit","session_id":"old"}
        {"logged_at":"2026-08-21T10:05:00.000Z","event":"SessionEnd","session_id":"old","reason":"resume"}
        {"logged_at":"2026-08-21T10:05:01.000Z","event":"SessionStart","session_id":"new","source":"resume"}
        """)
        XCTAssertNil(store.sessions["old"])
        XCTAssertEqual(store.sessions["new"]?.state, .idle)
        XCTAssertEqual(display(store), .off)
    }

    func testMultiSessionMostUrgentWins() {
        var store = SessionStore()
        store.apply(ev(.userPromptSubmit, 0, sid: "w"))
        store.apply(ev(.stop, 1, sid: "d", tail: "Done."))
        store.apply(ev(.permissionRequest, 2, sid: "a", tool: "Bash"))
        XCTAssertEqual(display(store), .split(alert: .waiting, work: .working),
                       "the request takes the zone; the working session keeps the rest")
        store.apply(ev(.sessionEnd, 3, sid: "a"))
        XCTAssertEqual(display(store), .split(alert: .done, work: .working),
                       "with the request gone, the finish takes the zone")
        store.apply(ev(.sessionEnd, 4, sid: "w"))
        XCTAssertEqual(display(store), .done, "nothing left running: full green")
    }

    func testBatteryOverlaysAndManual() {
        var store = SessionStore()
        store.apply(ev(.userPromptSubmit, 0))
        XCTAssertEqual(display(store, power: PowerState(percent: 10)), .batteryCritical)
        XCTAssertEqual(display(store, power: PowerState(percent: 80, plugged: true), glance: true),
                       .batteryGlance)
        XCTAssertEqual(display(store, mode: .off), .off)
        XCTAssertEqual(display(store, mode: .color("#00ff00")), .manualColor("#00ff00"))
    }

    /// Answering from the phone — a remote turn, or any resume the Mac never
    /// sees — means acknowledgement can never happen: the terminal is not
    /// focused and no key is pressed on this machine. The alert must clear
    /// anyway, because the resume event itself leaves the alert state.
    /// `acknowledged` stays false throughout, on purpose: it is the STATE that
    /// stopped being an alert, not the user that saw it.
    func testAlertsClearOnResumeWithoutAcknowledgement() {
        let resumes: [(String, JournalEvent, JournalEvent)] = [
            ("done", ev(.stop, 10, tail: "All tests pass."), ev(.userPromptSubmit, 20)),
            ("done with a prose question", ev(.stop, 10, tail: "Shall I proceed?"),
             ev(.userPromptSubmit, 20)),
            ("AskUserQuestion", ev(.preToolUse, 10, tool: "AskUserQuestion"),
             ev(.postToolUse, 20, tool: "AskUserQuestion")),
            ("permission", ev(.permissionRequest, 10, tool: "Bash"), ev(.preToolUse, 20, tool: "Bash")),
            ("plan", ev(.preToolUse, 10, tool: "ExitPlanMode"), ev(.postToolUse, 20, tool: "ExitPlanMode")),
            ("stop failure", ev(.stopFailure, 10), ev(.userPromptSubmit, 20)),
            // No user at all: a background shell reports back and the agent
            // picks its own work up again.
            ("done, agent self-resumes", ev(.stop, 10, tail: "Kicked it off."),
             ev(.postToolUse, 20, tool: "Bash")),
            // Inside the 1 s settle: the alert never even reached the strip.
            ("resume mid-settle", ev(.stop, 10, tail: "All tests pass."),
             ev(.userPromptSubmit, 10.5)),
        ]
        for (label, alert, resume) in resumes {
            var store = SessionStore()
            store.apply(ev(.userPromptSubmit, 0))
            store.apply(alert)
            XCTAssertNotNil(store.sessions["s1"]?.notifyAt, "\(label): a push should be armed")
            store.apply(resume)
            XCTAssertEqual(display(store), .working, "\(label): the strip must go back to red")
            XCTAssertEqual(store.sessions["s1"]?.presentedState, .working,
                           "\(label): no settle window left holding the alert")
            XCTAssertNil(store.sessions["s1"]?.notifyAt,
                         "\(label): the phone must not ring for something already answered")
            XCTAssertEqual(store.sessions["s1"]?.acknowledged, false,
                           "\(label): nothing was acknowledged — the state simply moved on")
        }
    }

    /// The push armed by the alert must not fire after a remote answer, even
    /// though the user was never at the machine to acknowledge it.
    func testNoStalePushAfterARemoteAnswer() {
        var store = SessionStore()
        store.apply(ev(.userPromptSubmit, 0))
        store.apply(ev(.stop, 10, tail: "Shall I proceed?"))
        store.apply(ev(.userPromptSubmit, 12))
        let fired = store.tick(now: base.addingTimeInterval(10 + K.notifyDebounceSeconds + 1),
                               userPresent: false)
        XCTAssertEqual(fired, [], "answered before the debounce elapsed: nothing to announce")
    }

    /// Clearing is per session, not per strip: another session still asking
    /// keeps the amber, which is the whole point of the ladder.
    func testAnsweringOneSessionLeavesAnotherSessionsAmberUp() {
        var store = SessionStore()
        store.apply(ev(.preToolUse, 10, sid: "s1", tool: "AskUserQuestion"))
        store.apply(ev(.preToolUse, 10, sid: "s2", tool: "AskUserQuestion"))
        store.apply(ev(.postToolUse, 20, sid: "s1", tool: "AskUserQuestion"))
        XCTAssertEqual(display(store), .split(alert: .waiting, work: .working),
                       "s2 was never answered — its amber keeps the zone over s1's work")
        store.apply(ev(.postToolUse, 21, sid: "s2", tool: "AskUserQuestion"))
        XCTAssertEqual(display(store), .working)
    }

    /// Parses the same ISO-8601 stamps the fixtures carry, so the tick
    /// instants below read against the journal rather than against an offset.
    func t(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso) else {
            XCTFail("bad fixture timestamp \(iso)"); return .distantPast
        }
        return date
    }

    /// Reconstructed from a recorded session: "fake working for 20min, then
    /// end with a done session". The strip was amber for 601 of the
    /// session's 824 s. Claude Code sends `idle_prompt` about 60 s after
    /// every Stop, and it must not clear the hold and light "needs you"
    /// over a background shell that is still running. The prompt box being
    /// idle is exactly what a held turn looks like, so it is not news.
    func testIdlePromptDoesNotBreakABackgroundHold() {
        var store = SessionStore()
        var alerts: [Alert] = []
        func feed(_ jsonl: String) {
            for line in jsonl.split(separator: "\n") where !line.isEmpty {
                guard let e = JournalCodec.decodeLine(Data(line.utf8)) else {
                    XCTFail("fixture line failed to decode: \(line)"); continue
                }
                store.apply(e)
            }
        }
        feed("""
        {"logged_at":"2026-08-22T11:03:27.699Z","event":"UserPromptSubmit","session_id":"s1","claude_pid":40234,"host_bundle_id":"com.apple.Terminal"}
        {"logged_at":"2026-08-22T11:03:31.927Z","event":"PreToolUse","session_id":"s1","tool_name":"Bash"}
        {"logged_at":"2026-08-22T11:03:32.895Z","event":"PostToolUse","session_id":"s1","tool_name":"Bash"}
        {"logged_at":"2026-08-22T11:03:34.340Z","event":"Stop","session_id":"s1","last_message_tail":"Started a 20-minute background sleep (task `b78jye1ft`). I'll report back when it finishes.","background_task_ids":["b78jye1ft"]}
        {"logged_at":"2026-08-22T11:03:35.960Z","event":"SubagentStop","session_id":"s1","agent_id":"a9c925ee9b640fd77","background_task_ids":["b78jye1ft"]}
        """)
        XCTAssertEqual(display(store), .working, "held: the 20-minute shell is still out")

        feed("""
        {"logged_at":"2026-08-22T11:04:34.377Z","event":"Notification","session_id":"s1","notification_type":"idle_prompt"}
        """)
        XCTAssertEqual(display(store), .working,
                       "the idle nudge must not pull the strip off the running job")
        XCTAssertEqual(store.sessions["s1"]?.pendingDone, true,
                       "and must not eat the verdict the hold is keeping")

        alerts += store.tick(now: t("2026-08-22T11:10:00.000Z"))
        XCTAssertEqual(alerts, [], "nothing rings mid-build either")

        // The shell finishes and the agent reports for real.
        feed("""
        {"logged_at":"2026-08-22T11:23:40.000Z","event":"Stop","session_id":"s1","last_message_tail":"Fake work complete.","background_task_ids":[]}
        """)
        XCTAssertEqual(display(store), .done, "green only once the work is actually over")
    }

    /// Reconstructed from a recorded session, the reported case: the turn
    /// finished, the strip breathed green and the phone said "Finished" —
    /// the 60 s idle nudge that arrives afterward must not turn it amber
    /// with a second push, for a turn that is over and already announced.
    /// This is the common case (16 of 18 recorded nudges).
    func testIdlePromptAfterAFinishedTurnLeavesItGreen() {
        var store = replay("""
        {"logged_at":"2026-08-22T14:40:19.536Z","event":"PreToolUse","session_id":"s1","tool_name":"Bash","claude_pid":1442,"host_bundle_id":"com.apple.Terminal"}
        {"logged_at":"2026-08-22T14:40:21.975Z","event":"PostToolUse","session_id":"s1","tool_name":"Bash"}
        {"logged_at":"2026-08-22T14:40:45.093Z","event":"Stop","session_id":"s1","last_message_tail":"FUNCTIONAL.md, README and version are updated; still nothing committed — happy to make it two commits if you want.","background_task_ids":[]}
        """)
        XCTAssertEqual(display(store), .done)

        var fired = store.tick(now: t("2026-08-22T14:41:00.093Z"))
        XCTAssertEqual(fired.map(\.kind), [.finished], "one push, at the debounce")

        store.apply(JournalCodec.decodeLine(Data("""
        {"logged_at":"2026-08-22T14:41:45.149Z","event":"Notification","session_id":"s1","notification_type":"idle_prompt"}
        """.utf8))!)
        XCTAssertEqual(display(store), .done, "the strip stayed green")

        fired += store.tick(now: t("2026-08-22T14:42:00.149Z"))
        fired += store.tick(now: t("2026-08-22T14:45:00.000Z"))
        XCTAssertEqual(fired.map(\.kind), [.finished], "and the phone rang once")
    }

    /// A prose question over a background shell is a FINISH over a
    /// background shell: held like any other, silent until the work is
    /// really over, then green and one "Finished".
    func testAProseQuestionOverBackgroundWorkIsHeldLikeAnyFinish() {
        var store = SessionStore()
        store.apply(ev(.userPromptSubmit, 0))
        store.apply(ev(.stop, 20, tail: "Build is running. Want me to lint too?", bg: ["bash_1"]))
        XCTAssertEqual(store.sessions["s1"]?.state, .working, "held: the shell is still out")
        XCTAssertEqual(store.tick(now: base.addingTimeInterval(20 + K.notifyDebounceSeconds + 1),
                                  userPresent: false), [], "nothing rings mid-build")
        store.apply(ev(.stop, 100, tail: "Lint is green too.", bg: []))
        XCTAssertEqual(display(store), .done)
    }

    /// A REAL question — AskUserQuestion, the dialog — is never held by
    /// anything: attention beats progress, exactly as the ladder says. This
    /// is what survives of the old never-hold-a-question rule, attached to
    /// the strong signal instead of the prose.
    func testAskUserQuestionIsNeverHeldBySubagents() {
        var store = SessionStore()
        store.apply(ev(.userPromptSubmit, 0))
        store.apply(ev(.subagentStart, 1, agent: "a1"))
        store.apply(ev(.preToolUse, 20, tool: "AskUserQuestion"))
        XCTAssertEqual(store.sessions["s1"]?.state, .waiting(.question))
        XCTAssertEqual(display(store), .waiting, "the dialog outranks the helpers running under it")
        let fired = store.tick(now: base.addingTimeInterval(20 + K.notifyDebounceSeconds + 1),
                               userPresent: false)
        XCTAssertEqual(fired.map(\.kind), [.needsYou(.question)])
        XCTAssertEqual(AlertCopy.message(for: fired[0].kind), "Asking you something")
    }

    /// The counterpart that must NOT change: a plain finish over live work is
    /// still deferred, because "done" is not a request.
    func testAPlainFinishIsStillHeld() {
        var store = SessionStore()
        store.apply(ev(.userPromptSubmit, 0))
        store.apply(ev(.stop, 20, tail: "Kicked the build off in the background.", bg: ["bash_1"]))
        XCTAssertEqual(display(store), .working)
        let fired = store.tick(now: base.addingTimeInterval(20 + K.notifyDebounceSeconds + 1),
                               userPresent: false)
        XCTAssertEqual(fired, [], "nothing rings mid-build")
    }

    /// Why notifications key off the state machine: 234 of 502 recorded Stop
    /// events had background work still running, so firing on `Stop` alone
    /// would announce "done" to turns that then carry on.
    ///
    /// Replayed end to end from journal text: no alert while held, exactly one
    /// when it settles, one debounce (15 s) later, and never again.
    func testBackgroundHeldStopIsSilentUntilTheTurnSettles() {
        var store = SessionStore()
        var alerts: [Alert] = []
        func feed(_ jsonl: String) {
            for line in jsonl.split(separator: "\n") where !line.isEmpty {
                guard let e = JournalCodec.decodeLine(Data(line.utf8)) else {
                    XCTFail("fixture line failed to decode: \(line)"); continue
                }
                store.apply(e)
            }
        }

        feed("""
        {"logged_at":"2026-08-21T10:00:00.000Z","event":"UserPromptSubmit","session_id":"s1","claude_pid":4242,"host_bundle_id":"com.apple.Terminal"}
        {"logged_at":"2026-08-21T10:00:04.000Z","event":"PreToolUse","session_id":"s1","tool_name":"Bash"}
        {"logged_at":"2026-08-21T10:00:20.000Z","event":"Stop","session_id":"s1","last_message_tail":"Kicked the build off in the background.","background_task_ids":["bash_1"],"stop_hook_active":false}
        """)
        XCTAssertEqual(display(store), .working, "held: the background shell is still out")
        XCTAssertEqual(LedProgram.program(for: display(store), power: nil, ledCount: 8, brightness: 255),
                       LedProgram.program(for: .working, power: nil, ledCount: 8, brightness: 255),
                       "the strip must stay red, not go green")

        for minute in 1...5 {
            alerts += store.tick(now: t("2026-08-21T10:0\(minute):20.000Z"))
        }
        XCTAssertEqual(alerts, [], "firing on Stop alone would have pushed \"done\" right here")

        // The agent picks the work back up and finishes for real.
        feed("""
        {"logged_at":"2026-08-21T10:06:00.000Z","event":"PostToolUse","session_id":"s1","tool_name":"Bash","background_task_ids":["bash_1"]}
        {"logged_at":"2026-08-21T10:06:30.000Z","event":"Stop","session_id":"s1","last_message_tail":"Build is green.","background_task_ids":[]}
        """)
        XCTAssertEqual(display(store), .done)
        // Intent, not bytes — ProgramTests pins the exact text, once.
        XCTAssertTrue(LedProgram.program(for: display(store), power: nil, ledCount: 8,
                                         brightness: 255).contains(K.doneGreen))

        alerts += store.tick(now: t("2026-08-21T10:06:44.000Z"))
        XCTAssertEqual(alerts, [], "still inside the 15 s debounce")
        alerts += store.tick(now: t("2026-08-21T10:06:45.000Z"))
        XCTAssertEqual(alerts.map(\.kind), [.finished], "one alert, timed from the settlement")
        XCTAssertEqual(AlertCopy.message(for: alerts[0].kind), "Finished")
        alerts += store.tick(now: t("2026-08-21T10:07:30.000Z"))
        XCTAssertEqual(alerts.count, 1, "and never again")
    }

    /// The other half: a turn that settles and then resumes inside the
    /// debounce window is not finished, so nothing is sent.
    func testResumeInsideTheDebounceWindowCancelsTheAlert() {
        var store = replay("""
        {"logged_at":"2026-08-21T11:00:00.000Z","event":"UserPromptSubmit","session_id":"s1","claude_pid":99}
        {"logged_at":"2026-08-21T11:00:30.000Z","event":"Stop","session_id":"s1","last_message_tail":"Done. All tests pass.","background_task_ids":[]}
        """)
        XCTAssertEqual(display(store), .done)
        XCTAssertEqual(store.tick(now: t("2026-08-21T11:00:40.000Z")), [],
                       "inside the 15 s debounce")
        store.apply(JournalCodec.decodeLine(Data(
            #"{"logged_at":"2026-08-21T11:00:42.000Z","event":"UserPromptSubmit","session_id":"s1"}"#.utf8))!)
        XCTAssertEqual(display(store), .working)
        XCTAssertEqual(store.tick(now: t("2026-08-21T11:01:00.000Z")), [],
                       "the deadline passed, but the session had already resumed")
        XCTAssertEqual(store.tick(now: t("2026-08-21T11:05:00.000Z")), [])
    }

    func testAckFlowEndToEnd() {
        var store = SessionStore()
        store.apply(ev(.userPromptSubmit, 0, host: "com.mitchellh.ghostty"))
        store.apply(ev(.preToolUse, 1, tool: "AskUserQuestion"))
        XCTAssertEqual(display(store), .waiting)
        _ = store.acknowledgeAlerts(hostBundleId: "com.mitchellh.ghostty")
        XCTAssertEqual(display(store), .off, "seen, and nothing else is running: dark")

        var busy = SessionStore()
        busy.apply(ev(.userPromptSubmit, 0, host: "com.mitchellh.ghostty"))
        busy.apply(ev(.subagentStart, 1, agent: "a1"))
        busy.apply(ev(.preToolUse, 2, tool: "AskUserQuestion"))
        XCTAssertEqual(display(busy), .waiting)
        _ = busy.acknowledgeAlerts(hostBundleId: "com.mitchellh.ghostty")
        XCTAssertEqual(display(busy), .working,
                       "seen, but a helper is still running: back on the work, not dark")
    }

    /// Codex session 01a0d9e4 on 2026-09-25: a Bash call, the user's Ctrl+C,
    /// and 13 s later the `PostToolUse` Codex fires for the call it aborted,
    /// for the same turn. No `Stop` follows an aborted turn, so a session
    /// put back to working there rolled until the user quit Codex. Event
    /// names, timestamps and ids only.
    func testTheLatePostToolUseOfTheAbortedCodexTurnLeavesTheStripDark() {
        let sid = "01a0d9e4-1902-7a61-a142-b1d9f240b1dc"
        let lines = """
        {"logged_at":"2026-09-25T18:52:28.263Z","event":"PreToolUse","agent":"codex","session_id":"01a0d9e4-1902-7a61-a142-b1d9f240b1dc","turn_id":"01a0d9e8-a902-70b1-a2ad-3146896b400b"}
        {"logged_at":"2026-09-25T18:52:28.353Z","event":"PostToolUse","agent":"codex","session_id":"01a0d9e4-1902-7a61-a142-b1d9f240b1dc","turn_id":"01a0d9e8-a902-70b1-a2ad-3146896b400b"}
        {"logged_at":"2026-09-25T18:52:34.701Z","event":"Interrupt","agent":"codex","session_id":"01a0d9e4-1902-7a61-a142-b1d9f240b1dc","turn_id":"01a0d9e8-a902-70b1-a2ad-3146896b400b"}
        {"logged_at":"2026-09-25T18:52:47.372Z","event":"PostToolUse","agent":"codex","session_id":"01a0d9e4-1902-7a61-a142-b1d9f240b1dc","turn_id":"01a0d9e8-a902-70b1-a2ad-3146896b400b"}
        """.split(separator: "\n").map(String.init)
        let working = replay(lines.prefix(2).joined(separator: "\n"))
        XCTAssertEqual(working.sessions[sid]?.state, .working)
        XCTAssertEqual(display(working), .working(.codex))
        let store = replay(lines.joined(separator: "\n"))
        XCTAssertEqual(store.sessions[sid]?.state, .idle, "the aborted turn stays closed")
        XCTAssertEqual(store.sessions[sid]?.lastEventAt.timeIntervalSince1970 ?? 0,
                       t("2026-09-25T18:52:47.372Z").timeIntervalSince1970, accuracy: 0.001,
                       "the late line proves the hook alive")
        XCTAssertEqual(display(store), .off)
    }
}

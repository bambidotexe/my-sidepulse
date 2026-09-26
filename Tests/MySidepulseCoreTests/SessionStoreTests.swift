import XCTest
@testable import MySidepulseCore

func ev(_ name: HookEventName, _ t: TimeInterval, sid: String? = "s1", tool: String? = nil,
        ntype: String? = nil, tail: String? = nil, bg: [String]? = nil, agent: String? = nil,
        source: String? = nil, pid: Int32? = nil, host: String? = nil, tty: String? = nil,
        ackSince: TimeInterval? = nil, turn: String? = nil) -> JournalEvent {
    var e = JournalEvent(loggedAt: Date(timeIntervalSince1970: 1_787_652_000 + t), event: name)
    e.sessionId = sid; e.toolName = tool; e.notificationType = ntype; e.lastMessageTail = tail
    e.backgroundTaskIds = bg; e.agentId = agent; e.source = source
    e.agentPid = pid; e.hostBundleId = host; e.tty = tty; e.turnId = turn
    e.ackStateSince = ackSince.map { Date(timeIntervalSince1970: 1_787_652_000 + $0) }
    return e
}

final class SessionStoreTests: XCTestCase {
    func state(_ store: SessionStore, _ sid: String = "s1") -> SessionState? {
        store.sessions[sid]?.state
    }

    func testPlainTurnLifecycle() {
        var s = SessionStore()
        s.apply(ev(.sessionStart, 0, source: "startup", pid: 42, host: "com.apple.Terminal"))
        XCTAssertEqual(state(s), .idle)
        XCTAssertEqual(s.sessions["s1"]?.agentPid, 42)
        s.apply(ev(.userPromptSubmit, 1))
        XCTAssertEqual(state(s), .working)
        s.apply(ev(.preToolUse, 2, tool: "Bash"))
        XCTAssertEqual(state(s), .working)
        s.apply(ev(.stop, 10, tail: "Done. All tests pass."))
        XCTAssertEqual(state(s), .done)
        s.apply(ev(.sessionEnd, 11))
        XCTAssertNil(s.sessions["s1"])
    }

    /// A turn that ends by ASKING IN PROSE — "Want me to commit this, or
    /// leave it for now?" — is a finished turn. Amber is reserved for the
    /// strong signals (AskUserQuestion, permissions, plan approval), which
    /// have events of their own. All 18 question-tail Stops in the recorded
    /// journal were this shape.
    func testAQuestionTailAtStopIsFinishedNotWaiting() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0))
        s.apply(ev(.stop, 5, tail: "Nothing's committed yet. Want me to commit this, or leave it for now?"))
        XCTAssertEqual(state(s), .done)
    }

    func testBlockingToolsAndPermissions() {
        var s = SessionStore()
        s.apply(ev(.preToolUse, 0, tool: "AskUserQuestion"))
        XCTAssertEqual(state(s), .waiting(.question))
        s.apply(ev(.postToolUse, 60, tool: "AskUserQuestion"))
        XCTAssertEqual(state(s), .working)
        s.apply(ev(.preToolUse, 61, tool: "ExitPlanMode"))
        XCTAssertEqual(state(s), .waiting(.plan))
        s.apply(ev(.postToolUse, 200, tool: "ExitPlanMode"))
        s.apply(ev(.permissionRequest, 201, tool: "Bash"))
        XCTAssertEqual(state(s), .waiting(.permission))
        s.apply(ev(.preToolUse, 210, tool: "Bash"))
        XCTAssertEqual(state(s), .working)
    }

    /// Claude Code 2.1 surfaces the blocking dialogs through the permission
    /// system: PreToolUse, then a PermissionRequest naming the tool, then a
    /// `permission_prompt` notification, all three within seconds of each
    /// other. None of the three may downgrade the reason to a generic
    /// "Needs permission" — the wait reason, and with it the push copy,
    /// follows the tool.
    func testTheFullDialogTripleKeepsItsSpecificReason() {
        var s = SessionStore()
        s.apply(ev(.preToolUse, 0, tool: "AskUserQuestion"))
        s.apply(ev(.permissionRequest, 0.025, tool: "AskUserQuestion"))
        XCTAssertEqual(state(s), .waiting(.question), "the permission transport is not the reason")
        s.apply(ev(.notification, 6, ntype: "permission_prompt"))
        XCTAssertEqual(state(s), .waiting(.question), "the echo must not rewrite the reason either")

        var p = SessionStore()
        p.apply(ev(.preToolUse, 0, tool: "ExitPlanMode"))
        p.apply(ev(.permissionRequest, 0.025, tool: "ExitPlanMode"))
        p.apply(ev(.notification, 6, ntype: "permission_prompt"))
        XCTAssertEqual(state(p), .waiting(.plan))

        var b = SessionStore()
        b.apply(ev(.permissionRequest, 0, tool: "Bash"))
        XCTAssertEqual(state(b), .waiting(.permission), "a real permission ask stays one")
    }

    /// Claude Code fires `idle_prompt` ~60 s after every turn goes quiet.
    /// On a turn already delivered — done, or held over background work —
    /// it is an echo and changes nothing.
    func testIdlePromptAfterAFinishedTurnIsANoOp() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0))
        s.apply(ev(.stop, 10, tail: "Updated the docs; nothing committed.", bg: []))
        XCTAssertEqual(state(s), .done)
        let settled = s.sessions["s1"]!.stateSince
        s.apply(ev(.notification, 70, ntype: "idle_prompt"))
        XCTAssertEqual(state(s), .done, "the prompt going quiet is what finished looks like")
        XCTAssertEqual(s.sessions["s1"]?.stateSince, settled,
                       "and it is not a fresh alert either")
    }

    /// A nudge arriving while the machine still believes the turn is running
    /// means the Stop was lost: it is the finish line arriving by other
    /// means, and takes the same verdict a Stop would — done, or held if
    /// helpers or background shells are still out. It is never amber: the
    /// idle nudge is a timer, not a request.
    func testIdlePromptOnAQuietWorkingTurnIsTheLostStop() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0))
        s.apply(ev(.preToolUse, 1, tool: "Bash"))
        s.apply(ev(.notification, 70, ntype: "idle_prompt"))
        XCTAssertEqual(state(s), .done, "quiet turn + idle nudge = the Stop was dropped")

        var held = SessionStore()
        held.apply(ev(.userPromptSubmit, 0))
        held.apply(ev(.subagentStart, 1, agent: "a1"))
        held.apply(ev(.preToolUse, 2, tool: "Bash"))
        held.apply(ev(.notification, 70, ntype: "idle_prompt"))
        XCTAssertEqual(state(held), .working, "a live helper holds the rescue exactly like a Stop")
        XCTAssertEqual(held.sessions["s1"]?.pendingDone, true)
    }

    /// The same nudge over FRESH main activity is a glitch, not a lost Stop:
    /// Claude Code only fires it after ~60 s of quiet, so the guard needs
    /// the turn to actually have been quiet.
    func testIdlePromptOverFreshActivityIsIgnored() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0))
        s.apply(ev(.preToolUse, 30, tool: "Bash"))
        s.apply(ev(.notification, 40, ntype: "idle_prompt"))
        XCTAssertEqual(state(s), .working, "10 s of quiet is not a finished turn")
    }

    /// `agent_needs_input` must not be an unconditional amber — even over a
    /// done turn, which would be the literal "Finished, then Waiting for
    /// you" pair. It never fired once in five recorded days, and it takes
    /// the same conservative reading as idle_prompt.
    func testAgentNeedsInputBehavesLikeIdlePrompt() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0))
        s.apply(ev(.stop, 10, tail: "Done."))
        s.apply(ev(.notification, 70, ntype: "agent_needs_input"))
        XCTAssertEqual(state(s), .done, "no amber on a finished turn, whatever the nudge is called")

        var lost = SessionStore()
        lost.apply(ev(.userPromptSubmit, 0))
        lost.apply(ev(.notification, 70, ntype: "agent_needs_input"))
        XCTAssertEqual(state(lost), .done, "on a quiet working turn it is the lost Stop")
    }

    /// A StopFailure is a dead turn; the idle nudge that follows it must not
    /// repaint "Turn failed" as a generic wait.
    func testIdlePromptDoesNotRewriteAFailedTurn() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0))
        s.apply(ev(.stopFailure, 1))
        XCTAssertEqual(state(s), .waiting(.error))
        s.apply(ev(.notification, 61, ntype: "idle_prompt"))
        XCTAssertEqual(state(s), .waiting(.error), "the turn died; that is still the news")
    }

    func testNotificationsAndFailures() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0))
        s.apply(ev(.notification, 1, ntype: "permission_prompt"))
        XCTAssertEqual(state(s), .waiting(.permission))
        s.apply(ev(.userPromptSubmit, 2))
        s.apply(ev(.notification, 3, ntype: "auth_success"))
        XCTAssertEqual(state(s), .working, "auth_success is a no-op")
        s.apply(ev(.postToolUseFailure, 4, tool: "Bash"))
        XCTAssertEqual(state(s), .working, "Claude handles its own failed tools — never amber")
        s.apply(ev(.stopFailure, 5))
        XCTAssertEqual(state(s), .waiting(.error))
    }

    /// A compaction is work while it runs, and afterwards the session goes
    /// back to the state it found — a finished turn's green, or a standing
    /// wait, included — without pushing or blinking again (the same
    /// `stateSince`, `acknowledged`, `notifyAt`, `waitingFromAgent`, and no
    /// settle of the compaction's own making).
    func testCompactionKeepsTheStateItFound() {
        // idle -> working during -> idle after: a compaction at the prompt.
        var idleCase = SessionStore()
        idleCase.apply(ev(.sessionStart, 0, source: "startup"))
        XCTAssertEqual(state(idleCase), .idle)
        idleCase.apply(ev(.preCompact, 1))
        XCTAssertEqual(state(idleCase), .working)
        idleCase.apply(ev(.sessionStart, 2, source: "compact"))
        XCTAssertEqual(state(idleCase), .working, "SessionStart(compact) happens mid-flight")
        idleCase.apply(ev(.postCompact, 3))
        XCTAssertEqual(state(idleCase), .idle)

        // done -> working during -> done after, with the debounce and the
        // settle untouched. A tick past the settle window before PreCompact
        // makes `before` a standing done, exactly what a compaction that
        // finds it already settled should come back to.
        var doneCase = SessionStore()
        doneCase.apply(ev(.userPromptSubmit, 0))
        doneCase.apply(ev(.stop, 1))
        _ = doneCase.tick(now: Date(timeIntervalSince1970: 1_787_652_000 + 3))
        let before = doneCase.sessions["s1"]!
        XCTAssertEqual(before.state, .done)
        XCTAssertNil(before.settlingFrom, "settled before the compaction starts")
        doneCase.apply(ev(.preCompact, 4))
        XCTAssertEqual(state(doneCase), .working)
        XCTAssertEqual(doneCase.sessions["s1"]?.compactionSnapshot?.state, .done)
        // A second PreCompact with no PostCompact between must not overwrite
        // the held snapshot with the already-working state it finds now.
        doneCase.apply(ev(.preCompact, 6))
        XCTAssertEqual(doneCase.sessions["s1"]?.compactionSnapshot?.state, .done,
                        "a repeated PreCompact keeps the first snapshot")
        doneCase.apply(ev(.postCompact, 7))
        let after = doneCase.sessions["s1"]!
        XCTAssertEqual(after.state, .done)
        XCTAssertEqual(after.stateSince, before.stateSince, "no fresh finish time")
        XCTAssertEqual(after.acknowledged, before.acknowledged)
        XCTAssertEqual(after.notifyAt, before.notifyAt, "no re-armed push")
        XCTAssertNil(after.settlingFrom, "no re-armed settle")
        XCTAssertNil(after.settlingUntil, "no re-armed settle")
        XCTAssertNil(after.compactionSnapshot)

        // waiting(permission), raised by a helper -> working during -> the
        // same wait after, with waitingFromAgent restored too.
        var waitCase = SessionStore()
        waitCase.apply(ev(.userPromptSubmit, 0))
        waitCase.apply(ev(.permissionRequest, 1, agent: "a1"))
        _ = waitCase.tick(now: Date(timeIntervalSince1970: 1_787_652_000 + 3))
        let waitBefore = waitCase.sessions["s1"]!
        XCTAssertEqual(waitBefore.state, .waiting(.permission))
        XCTAssertTrue(waitBefore.waitingFromAgent)
        XCTAssertNil(waitBefore.settlingFrom, "settled before the compaction starts")
        waitCase.apply(ev(.preCompact, 4))
        XCTAssertEqual(state(waitCase), .working)
        waitCase.apply(ev(.postCompact, 5))
        let waitAfter = waitCase.sessions["s1"]!
        XCTAssertEqual(waitAfter.state, .waiting(.permission))
        XCTAssertEqual(waitAfter.stateSince, waitBefore.stateSince, "no fresh wait time")
        XCTAssertEqual(waitAfter.acknowledged, waitBefore.acknowledged)
        XCTAssertEqual(waitAfter.notifyAt, waitBefore.notifyAt, "no re-armed push")
        XCTAssertTrue(waitAfter.waitingFromAgent, "still a helper's wait")
        XCTAssertNil(waitAfter.settlingFrom, "no re-armed settle")
        XCTAssertNil(waitAfter.settlingUntil, "no re-armed settle")

        // working -> working: a compaction inside a turn.
        var workingCase = SessionStore()
        workingCase.apply(ev(.userPromptSubmit, 0))
        workingCase.apply(ev(.preToolUse, 1, tool: "Bash"))
        XCTAssertEqual(state(workingCase), .working)
        workingCase.apply(ev(.preCompact, 2))
        XCTAssertEqual(state(workingCase), .working)
        workingCase.apply(ev(.postCompact, 3))
        XCTAssertEqual(state(workingCase), .working)
    }

    /// A snapshot whose `PostCompact` never came dies with its turn: the
    /// Stop forgets it, so a `/compact` at the prompt after it snapshots the
    /// standing finish and gives it back untouched, with no working roll
    /// after the compaction and no second "Finished" push.
    func testAStaleCompactionSnapshotIsForgottenAtTheNextTurn() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0, turn: "p1"))
        s.apply(ev(.preCompact, 5, turn: "p1"))
        XCTAssertEqual(s.sessions["s1"]?.compactionSnapshot?.state, .working)
        s.apply(ev(.stop, 10, tail: "Done.", turn: "p1"))
        XCTAssertEqual(state(s), .done)
        XCTAssertNil(s.sessions["s1"]?.compactionSnapshot, "the Stop is a turn boundary")
        let finished = s.sessions["s1"]!
        XCTAssertEqual(s.tick(now: at(12)), [])
        s.apply(ev(.preCompact, 14))
        XCTAssertEqual(state(s), .working)
        s.apply(ev(.postCompact, 16))
        XCTAssertEqual(state(s), .done, "the compaction at the prompt gives the finish back")
        XCTAssertEqual(s.sessions["s1"]?.stateSince, finished.stateSince)
        XCTAssertEqual(s.sessions["s1"]?.notifyAt, finished.notifyAt, "the same push deadline")
        let pushes = s.tick(now: at(26)) + s.tick(now: at(60)) + s.tick(now: at(600))
        XCTAssertEqual(pushes.count, 1, "one Finished push, not a second one")

        // Every other turn boundary forgets it too; a compaction's own
        // SessionStart does not.
        for boundary in [ev(.userPromptSubmit, 22, turn: "p2"), ev(.interrupt, 22, turn: "p1"),
                         ev(.sessionStart, 22, source: "startup")] {
            var b = SessionStore()
            b.apply(ev(.userPromptSubmit, 0, turn: "p1"))
            b.apply(ev(.preCompact, 20, turn: "p1"))
            b.apply(boundary)
            XCTAssertNil(b.sessions["s1"]?.compactionSnapshot, "\(boundary.event)")
        }
        var compact = SessionStore()
        compact.apply(ev(.userPromptSubmit, 0, turn: "p1"))
        compact.apply(ev(.preCompact, 20, turn: "p1"))
        compact.apply(ev(.sessionStart, 22, source: "compact"))
        XCTAssertNotNil(compact.sessions["s1"]?.compactionSnapshot)
    }

    /// A compaction's own `SessionStart` is no boundary for the hold either:
    /// a Stop held behind a helper stays held through it.
    func testAHeldStopSurvivesACompactSessionStart() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0))
        s.apply(ev(.preToolUse, 1, tool: "Read", agent: "a1"))
        s.apply(ev(.stop, 10, tail: "Done."))
        XCTAssertEqual(s.sessions["s1"]?.pendingDone, true)
        s.apply(ev(.sessionStart, 12, source: "compact"))
        XCTAssertEqual(state(s), .working)
        XCTAssertEqual(s.sessions["s1"]?.pendingDone, true, "the hold stands")
        XCTAssertEqual(s.sessions["s1"]?.liveAgents["a1"], at(1))
    }

    /// `SessionStart(compact)` alone, with no `PreCompact` before it, changes
    /// nothing: it is the mid-flight marker, not a state of its own, and it
    /// keeps the helpers and background shells a plain `SessionStart` would
    /// forget.
    func testACompactSessionStartAloneChangesNothing() {
        var s = SessionStore()
        s.apply(ev(.sessionStart, 0, source: "startup"))
        XCTAssertEqual(state(s), .idle)
        s.apply(ev(.subagentStart, 1, agent: "a1"))
        XCTAssertEqual(s.sessions["s1"].map { Set($0.liveAgents.keys) }, ["a1"])
        s.apply(ev(.sessionStart, 2, source: "compact"))
        XCTAssertEqual(state(s), .idle, "SessionStart(compact) alone forces no state")
        XCTAssertEqual(s.sessions["s1"].map { Set($0.liveAgents.keys) }, ["a1"], "compact keeps helpers")
    }

    func testSubagentEventsNeverSetDisplayButRegister() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0))
        s.apply(ev(.subagentStart, 1, agent: "a1"))
        XCTAssertEqual(state(s), .working, "subagent event must not change display state")
        XCTAssertEqual(s.sessions["s1"].map { Set($0.liveAgents.keys) }, ["a1"])
        s.apply(ev(.preToolUse, 2, tool: "Bash", agent: "a2"))
        XCTAssertEqual(s.sessions["s1"].map { Set($0.liveAgents.keys) }, ["a1", "a2"], "activity self-heals a missed SubagentStart")
        s.apply(ev(.subagentStop, 3, agent: "a1"))
        s.apply(ev(.subagentStop, 4, agent: "a2"))
        XCTAssertEqual(s.sessions["s1"].map { Set($0.liveAgents.keys) }, [])
    }

    /// A helper blocked on a permission prompt blocks the whole turn, and the
    /// prompt surfaces in the main UI exactly like the main agent's own —
    /// even though its event carries the helper's agent_id, which must not
    /// be discarded with the rest of the registry traffic: no amber, no
    /// push, pipeline blocked (4 in the recorded journal).
    func testASubagentPermissionRequestIsTheUsersBusiness() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0))
        s.apply(ev(.preToolUse, 1, tool: "Agent"))
        s.apply(ev(.permissionRequest, 10, tool: "Bash", agent: "a1"))
        XCTAssertEqual(state(s), .waiting(.permission))
        // Approved: the helper acts again, so the prompt was answered.
        s.apply(ev(.preToolUse, 20, tool: "Bash", agent: "a1"))
        XCTAssertEqual(state(s), .working)

        // A helper's prompt can also be cleared by the main agent moving on.
        var denied = SessionStore()
        denied.apply(ev(.userPromptSubmit, 0))
        denied.apply(ev(.permissionRequest, 10, tool: "Bash", agent: "a1"))
        XCTAssertEqual(state(denied), .waiting(.permission))
        denied.apply(ev(.postToolUse, 20, tool: "Agent"))
        XCTAssertEqual(state(denied), .working)
    }

    /// A MAIN-agent permission prompt is not cleared by unrelated helper
    /// chatter: the dialog is still on screen however busy the helpers are.
    func testHelperActivityDoesNotClearAMainPermissionPrompt() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0))
        s.apply(ev(.subagentStart, 1, agent: "a1"))
        s.apply(ev(.permissionRequest, 10, tool: "Bash"))
        XCTAssertEqual(state(s), .waiting(.permission))
        s.apply(ev(.preToolUse, 15, tool: "Read", agent: "a1"))
        XCTAssertEqual(state(s), .waiting(.permission),
                       "the main agent's dialog is still open; helper traffic is not an answer")
    }

    /// Since Claude Code 2.1 a background helper can outlive its turn's Stop
    /// and only emit its first visible event AFTER the verdict landed. That
    /// activity re-opens the turn: the strip goes back on the work and the
    /// verdict re-applies when the helper is done.
    func testHelperActivityAfterDoneReopensTheTurn() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0))
        s.apply(ev(.stop, 10, tail: "Done."))
        XCTAssertEqual(state(s), .done)
        s.apply(ev(.preToolUse, 20, tool: "Bash", agent: "late"))
        XCTAssertEqual(state(s), .working, "a helper still running means the turn was not over")
        XCTAssertEqual(s.sessions["s1"]?.pendingDone, true)
        s.apply(ev(.subagentStop, 30, agent: "late"))
        var clock = at(30)
        let deadline = at(30 + K.holdGraceSeconds + 1)
        while let d = s.nextDeadline(after: clock), d <= deadline {
            clock = d; _ = s.tick(now: d)
        }
        XCTAssertEqual(state(s), .done, "and the verdict re-applies once it truly is")
    }

    func testStopWithHoldsStaysWorking() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0))
        s.apply(ev(.subagentStart, 1, agent: "a1"))
        s.apply(ev(.stop, 2, tail: "Working on it in the background."))
        XCTAssertEqual(state(s), .working, "live subagent holds the strip")
        XCTAssertEqual(s.sessions["s1"]?.pendingDone, true)

        var s2 = SessionStore()
        s2.apply(ev(.userPromptSubmit, 0))
        s2.apply(ev(.stop, 2, bg: ["task-1"]))
        XCTAssertEqual(state(s2), .working, "background task holds the strip")
        s2.apply(ev(.stop, 30, bg: []))
        XCTAssertEqual(state(s2), .done, "empty snapshot releases the hold at the next Stop")
    }

    // MARK: - helpers across turn boundaries
    //
    // Two facts drive this. Helpers whose SubagentStop never comes (19 of 44
    // in the recorded journal) mean silence is the only trustworthy end,
    // hence the 4-minute expiry. And Claude Code 2.1 accepts a prompt while
    // a previous turn's helper is STILL RUNNING (its stop can arrive minutes
    // later), so a prompt is NOT a helper boundary — clearing the registry
    // on one would green-light a Stop over live helper work.

    func testAPromptDoesNotClearAStillLiveHelper() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0))
        s.apply(ev(.preToolUse, 10, tool: "Bash", agent: "bg"))
        s.apply(ev(.userPromptSubmit, 20))
        s.apply(ev(.stop, 30, tail: "Done."))
        XCTAssertEqual(state(s), .working,
                       "the helper was seen 20 s ago; the new prompt is not proof it ended")
        s.apply(ev(.subagentStop, 40, agent: "bg"))
        var clock = at(40)
        let deadline = at(40 + K.holdGraceSeconds + 1)
        while let d = s.nextDeadline(after: clock), d <= deadline {
            clock = d; _ = s.tick(now: d)
        }
        XCTAssertEqual(state(s), .done)
    }

    func testASessionStartClearsPriorHelpersAndShells() {
        var s = SessionStore()
        s.apply(ev(.preToolUse, 0, tool: "Bash", agent: "leaked"))
        s.apply(ev(.stop, 5, bg: ["old-shell"]))
        s.apply(ev(.sessionStart, 10, source: "resume"))
        XCTAssertEqual(s.sessions["s1"]?.backgroundIds, [],
                       "no shell survives the process that owned it")
        s.apply(ev(.userPromptSubmit, 20))
        s.apply(ev(.stop, 30, tail: "Done."))
        XCTAssertEqual(state(s), .done, "a resumed session carries no live helpers")
    }

    func testAHelperGoneQuietReleasesTheHeldStop() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0))
        s.apply(ev(.preToolUse, 10, tool: "Bash", agent: "leaked"))
        s.apply(ev(.stop, 20, tail: "All set."))
        XCTAssertEqual(state(s), .working, "held while the helper could still be alive")

        var early = s
        _ = early.tick(now: at(10 + K.agentStaleSeconds - 1))
        XCTAssertEqual(state(early), .working,
                       "a helper quiet for less than the window is not yet gone")

        // Driven the way Engine drives it: tick at each scheduled deadline.
        // The store must schedule its own way out, not rely on a caller
        // guessing the right moment.
        let deadline = at(10 + K.agentStaleSeconds + K.holdGraceSeconds + 1)
        var clock = at(20)
        while let d = s.nextDeadline(after: clock), d <= deadline {
            clock = d; _ = s.tick(now: d)
        }
        XCTAssertEqual(state(s), .done, "a helper gone quiet stops holding the turn")
    }

    func testAHelperStillReportingInKeepsHoldingTheStop() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0))
        s.apply(ev(.subagentStart, 1, agent: "a1"))
        s.apply(ev(.stop, 2, tail: "Kicked it off."))
        // Tool traffic far past one staleness window: a long helper stays live
        // for as long as it keeps reporting in. Recorded helpers went quiet for
        // up to 202.4 s between events, which is what sizes the window.
        s.apply(ev(.preToolUse, K.agentStaleSeconds * 3, tool: "Bash", agent: "a1"))
        _ = s.tick(now: at(K.agentStaleSeconds * 3 + 60))
        XCTAssertEqual(state(s), .working, "a helper still reporting in must not be expired")
    }

    func testAHeldStopSchedulesItsOwnHelperExpiry() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0))
        s.apply(ev(.preToolUse, 10, tool: "Bash", agent: "leaked"))
        s.apply(ev(.stop, 20, tail: "All set."))
        let now = at(20)
        let next = s.nextDeadline(after: now)
        XCTAssertNotNil(next, "a held Stop must schedule a wake-up")
        XCTAssertLessThanOrEqual(next!.timeIntervalSince(now), K.agentStaleSeconds,
                                 "the tick that notices the helper is gone must be "
                                 + "scheduled, not left to the 30-minute holdTTL")
    }

    func testBackgroundIdsAreASnapshot() {
        var s = SessionStore()
        s.apply(ev(.stop, 0, bg: ["t1", "t2"]))
        XCTAssertEqual(s.sessions["s1"]?.backgroundIds, ["t1", "t2"])
        s.apply(ev(.stop, 1, bg: ["t2"]))
        XCTAssertEqual(s.sessions["s1"]?.backgroundIds, ["t2"], "replaced wholesale, never merged")
    }

    func testSubagentPayloadDoesNotRewriteTheParentsBackgroundSnapshot() {
        var s = SessionStore()
        s.apply(ev(.stop, 0, bg: ["t1"]))
        XCTAssertEqual(s.sessions["s1"]?.backgroundIds, ["t1"])
        // A subagent payload inherits its parent's session_id and carries its
        // own background_tasks; it must not touch the parent's snapshot.
        s.apply(ev(.preToolUse, 1, tool: "Bash", bg: ["sub-shell"], agent: "a1"))
        XCTAssertEqual(s.sessions["s1"]?.backgroundIds, ["t1"],
                       "only a main-agent payload replaces the snapshot")
        s.apply(ev(.subagentStop, 2, bg: ["a1"], agent: "a1"))
        XCTAssertEqual(s.sessions["s1"]?.backgroundIds, ["t1"],
                       "a SubagentStop listing its own agent_id must not re-arm the hold")
        s.apply(ev(.stop, 3, bg: []))
        XCTAssertEqual(state(s), .done, "the parent's own empty snapshot still releases")
    }

    func testEventsWithoutSessionIdOrParseErrorsAreIgnored() {
        var s = SessionStore()
        s.apply(ev(.parseError, 0, sid: nil))
        s.apply(ev(.userPromptSubmit, 1, sid: nil))
        XCTAssertTrue(s.sessions.isEmpty)
    }

    func testRepeatedAlertIsANewInstance() {
        var s = SessionStore()
        s.apply(ev(.permissionRequest, 10, tool: "Bash"))
        let first = s.sessions["s1"]!.stateSince
        s.apply(ev(.permissionRequest, 70, tool: "Edit"))
        XCTAssertEqual(state(s), .waiting(.permission))
        XCTAssertGreaterThan(s.sessions["s1"]!.stateSince, first,
                             "a second ask is a new alert, not an echo")
        XCTAssertFalse(s.sessions["s1"]!.acknowledged)
    }

    func testRepeatedWorkingDoesNotChurnStateSince() {
        var s = SessionStore()
        s.apply(ev(.preToolUse, 0, tool: "Bash"))
        let first = s.sessions["s1"]!.stateSince
        s.apply(ev(.postToolUse, 5, tool: "Bash"))
        XCTAssertEqual(s.sessions["s1"]!.stateSince, first,
                       "ordinary tool traffic is not an alert; no churn")
    }

    func testHoldReleaseIsTimestampedOnceAndResetByANewHelper() {
        var s = SessionStore()
        s.apply(ev(.subagentStart, 0, agent: "a1"))
        s.apply(ev(.stop, 1, tail: "Done."))
        XCTAssertNil(s.sessions["s1"]?.holdReleasedAt, "still held while a helper runs")
        s.apply(ev(.subagentStop, 10, agent: "a1"))
        let released = s.sessions["s1"]?.holdReleasedAt
        XCTAssertEqual(released, Date(timeIntervalSince1970: 1_787_652_000 + 10),
                       "release is timestamped when the last hold clears")
        s.apply(ev(.subagentStop, 20, agent: "never-registered"))
        XCTAssertEqual(s.sessions["s1"]?.holdReleasedAt, released,
                       "already-released hold keeps its original timestamp")
        s.apply(ev(.subagentStart, 30, agent: "a2"))
        XCTAssertNil(s.sessions["s1"]?.holdReleasedAt,
                     "a new helper re-engages the hold")
    }

    // MARK: - the abandoned turn (Esc/Ctrl-C fires no hook at all)

    /// Esc mid-turn fires nothing — no Stop, no idle_prompt (11 of 199
    /// recorded prompts ended that way; the longest left the working roll
    /// standing 4 m 18 s, and walking away would have left it for the whole
    /// 2 h staleness backstop). The store nominates quiet sessions; the app
    /// asks Claude's own process registry and calls `abandonTurn` when it
    /// says idle. The verdict is dark, not green: a turn with no Stop never
    /// finished.
    func testAbandonCandidatesAndVerdict() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0, pid: 42))
        s.apply(ev(.preToolUse, 5, tool: "Bash"))
        XCTAssertTrue(s.abandonCandidates(at: at(K.abandonQuietSeconds)).isEmpty,
                      "not yet quiet for the full gate")
        let due = 5 + K.abandonQuietSeconds
        let candidates = s.abandonCandidates(at: at(due))
        XCTAssertEqual(candidates.map(\.sessionId), ["s1"])
        XCTAssertEqual(candidates.map(\.pid), [42])
        s.abandonTurn(sessionId: "s1", now: at(due + K.abandonRecheckSeconds))
        XCTAssertEqual(state(s), .idle, "dark: nothing runs, nothing finished, nothing needed")
        XCTAssertNil(s.sessions["s1"]?.notifyAt, "and nothing to push about")
    }

    /// The other registry verdict: "busy" with hooks silent — a turn still
    /// genuinely running whose hook delivery died (a Ctrl-C can kill all
    /// hooks for a session mid-flight). Liveness is extended so the 2 h
    /// staleness backstop cannot delete a
    /// demonstrably working session, and nothing else moves — no alert, no
    /// churn. lastMainEventAt stays put, so hook silence remains measurable.
    func testNoteBusyExtendsLivenessAndNothingElse() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0, pid: 42))
        let mainAt = s.sessions["s1"]!.lastMainEventAt
        s.noteBusy(sessionId: "s1", now: at(K.staleSeconds - 1))
        _ = s.tick(now: at(K.staleSeconds + 1))
        XCTAssertNotNil(s.sessions["s1"], "busy at the source outranks event silence")
        XCTAssertEqual(s.sessions["s1"]?.state, .working)
        XCTAssertEqual(s.sessions["s1"]?.lastMainEventAt, mainAt,
                       "hook silence stays measurable under the extension")

        var done = SessionStore()
        done.apply(ev(.stop, 0, tail: "Done."))
        let seen = done.sessions["s1"]!.lastEventAt
        done.noteBusy(sessionId: "s1", now: at(50))
        XCTAssertEqual(done.sessions["s1"]?.lastEventAt, seen,
                       "only a working session can be busy at the source")
    }

    func testHeldOrHelperedSessionsAreNeverAbandonCandidates() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0, pid: 42))
        s.apply(ev(.subagentStart, 1, agent: "a1"))
        XCTAssertTrue(s.abandonCandidates(at: at(60 + K.abandonQuietSeconds)).isEmpty,
                      "a live helper is activity, not abandonment")

        var held = SessionStore()
        held.apply(ev(.userPromptSubmit, 0, pid: 42))
        held.apply(ev(.stop, 1, bg: ["shell-1"]))
        XCTAssertTrue(held.abandonCandidates(at: at(1 + K.abandonQuietSeconds)).isEmpty,
                      "a held Stop is waiting on real work; the hold machinery owns it")

        var pidless = SessionStore()
        pidless.apply(ev(.userPromptSubmit, 0))
        XCTAssertTrue(pidless.abandonCandidates(at: at(K.abandonQuietSeconds)).isEmpty,
                      "no pid, no CPU check — staleness is the only backstop left")
    }

    func testAbandonVerdictIsRefusedOnceStateMovedOn() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0, pid: 42))
        s.apply(ev(.stop, 200, tail: "Done."))
        s.abandonTurn(sessionId: "s1", now: at(210))
        XCTAssertEqual(state(s), .done,
                       "a verdict computed against a stale sample must not clobber a real one")
    }

    /// The lost-Stop finish, proven at the source: registry idle plus a
    /// transcript ending on a completed answer takes the same verdict a
    /// Stop takes — green with its push, or held behind live work.
    func testFinishTurnTakesTheStopVerdict() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0, pid: 42))
        s.finishTurn(sessionId: "s1", now: at(60))
        XCTAssertEqual(state(s), .done)
        XCTAssertNotNil(s.sessions["s1"]?.notifyAt, "a recovered finish still announces itself")

        var held = SessionStore()
        held.apply(ev(.userPromptSubmit, 0, pid: 42))
        held.apply(ev(.stop, 1, bg: ["shell-1"]))
        held.apply(ev(.userPromptSubmit, 10))
        held.apply(ev(.stop, 11, bg: ["shell-1"]))
        XCTAssertEqual(held.sessions["s1"]?.pendingDone, true)
        held.finishTurn(sessionId: "s1", now: at(60))
        XCTAssertEqual(state(held), .working, "already held: finishTurn must not fire early")

        var finished = SessionStore()
        finished.apply(ev(.stop, 0, tail: "Done."))
        let since = finished.sessions["s1"]!.stateSince
        finished.finishTurn(sessionId: "s1", now: at(60))
        XCTAssertEqual(finished.sessions["s1"]?.stateSince, since,
                       "a turn already delivered is not re-finished")
    }

    /// The answered dialog: approving a plan can fire no hook at all, so the
    /// wait would otherwise stand until the next tool call happened by. The
    /// store nominates every Claude wait for the registry check, a failed
    /// turn's included: `busy` after the wait began is the agent at work,
    /// whatever the wait was. The verdict flips it back to working and
    /// disarms its push, and replays the same.
    func testOpenWaitCandidatesAndAnsweredVerdict() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0, pid: 42))
        s.apply(ev(.preToolUse, 5, tool: "ExitPlanMode"))
        s.apply(ev(.permissionRequest, 5.03, tool: "ExitPlanMode"))
        let candidates = s.openWaitCandidates()
        XCTAssertEqual(candidates.map(\.sessionId), ["s1"])
        XCTAssertEqual(candidates.map(\.pid), [42])
        XCTAssertEqual(candidates.map(\.stateSince), [at(5.03)])
        XCTAssertNotNil(s.sessions["s1"]?.notifyAt, "the dialog armed a push")
        s.dialogAnswered(sessionId: "s1", now: at(300))
        XCTAssertEqual(state(s), .working)
        XCTAssertNil(s.sessions["s1"]?.notifyAt, "answered: nothing left to announce")

        var failed = SessionStore()
        failed.apply(ev(.userPromptSubmit, 0, pid: 42))
        failed.apply(ev(.stopFailure, 5))
        XCTAssertEqual(failed.openWaitCandidates().map(\.sessionId), ["s1"],
                       "a failed turn's wait is answered by the agent going busy too")
        XCTAssertEqual(failed.openWaitCandidates().map(\.stateSince), [at(5)])
        var replayed = failed
        XCTAssertEqual(failed.dialogAnswered(sessionId: "s1", now: at(300)), at(300))
        XCTAssertEqual(state(failed), .working)
        XCTAssertNil(failed.sessions["s1"]?.notifyAt, "the failure's push is disarmed")
        replayed.apply(verdictLine("dialog-answered", 300))
        XCTAssertEqual(replayed.sessions["s1"], failed.sessions["s1"], "the journaled verdict replays the same")

        var working = SessionStore()
        working.apply(ev(.userPromptSubmit, 0, pid: 42))
        XCTAssertTrue(working.openWaitCandidates().isEmpty, "a working turn waits on nothing")
        XCTAssertNil(working.dialogAnswered(sessionId: "s1", now: at(300)))
    }

    func testOpenWaitSchedulesItsRecheck() {
        var s = SessionStore()
        s.apply(ev(.preToolUse, 0, tool: "AskUserQuestion", pid: 42))
        _ = s.tick(now: at(60))
        let next = s.nextDeadline(after: at(60))
        XCTAssertNotNil(next)
        XCTAssertLessThanOrEqual(next!.timeIntervalSince(at(60)), K.abandonRecheckSeconds,
                                 "an open wait must keep waking the registry check")

        var failed = SessionStore()
        failed.apply(ev(.userPromptSubmit, 0, pid: 42))
        failed.apply(ev(.stopFailure, 5))
        XCTAssertEqual(failed.nextDeadline(after: at(60)), at(60 + K.abandonRecheckSeconds),
                       "so must a failed turn's")
    }

    // MARK: - acknowledgement persistence

    /// Acknowledgement must be scoped to the visible TAB: a bundle-level ack
    /// would clear sessions in tabs the user cannot see. Known front tab +
    /// known session tty must MATCH; any unknown on either side fails open
    /// to the app-level behaviour, so nothing is ever stranded
    /// unacknowledgeable.
    func testAcknowledgementIsScopedToTheVisibleTab() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0, sid: "seen", host: "com.apple.Terminal", tty: "ttys001"))
        s.apply(ev(.stop, 1, sid: "seen", tail: "Done."))
        s.apply(ev(.userPromptSubmit, 0, sid: "hidden", host: "com.apple.Terminal", tty: "ttys002"))
        s.apply(ev(.stop, 1, sid: "hidden", tail: "Done."))
        s.apply(ev(.userPromptSubmit, 0, sid: "no-tty", host: "com.apple.Terminal"))
        s.apply(ev(.stop, 1, sid: "no-tty", tail: "Done."))

        let acked = s.acknowledgeAlerts(hostBundleId: "com.apple.Terminal", frontTTY: "ttys001")
        XCTAssertEqual(Set(acked.map(\.sessionId)), ["seen", "no-tty"],
                       "the visible tab clears; a session with no tty fails open")
        XCTAssertEqual(s.sessions["hidden"]?.acknowledged, false,
                       "the tab he cannot see stays an unread notification")
        XCTAssertNotNil(s.sessions["hidden"]?.notifyAt, "and its push stays armed")

        let rest = s.acknowledgeAlerts(hostBundleId: "com.apple.Terminal", frontTTY: nil)
        XCTAssertEqual(rest.map(\.sessionId), ["hidden"],
                       "an unknown front tab falls open to the whole app")
    }

    /// A session the Claude Code daemon hosts records no host app at all —
    /// the process chain dies at the daemon — and "nothing" matches no
    /// frontmost bundle, so focusing anything would clear nothing and leave
    /// the alert sitting until the 2 h backstop. An unfocusable host is an
    /// unknown host: presence acknowledges it, and tab scoping does not
    /// apply without a terminal to scope inside.
    func testAHostThatCanNeverBeFrontmostAcknowledgesOnPresence() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0, sid: "daemon"))            // no host recorded
        s.apply(ev(.stop, 1, sid: "daemon", tail: "Done."))
        s.apply(ev(.userPromptSubmit, 0, sid: "cli-bundle",
                   host: "com.anthropic.claude-code", tty: "ttys006"))
        s.apply(ev(.stop, 1, sid: "cli-bundle", tail: "Done."))
        s.apply(ev(.userPromptSubmit, 0, sid: "tab", host: "com.apple.Terminal", tty: "ttys001"))
        s.apply(ev(.stop, 1, sid: "tab", tail: "Done."))

        // Terminal is focusable; the command-line bundle is not.
        let focusable: (String) -> Bool = { $0 == "com.apple.Terminal" }
        let acked = s.acknowledgeAlerts(hostBundleId: "com.apple.Terminal", frontTTY: "ttys002",
                                        hostIsFocusable: focusable)
        XCTAssertEqual(Set(acked.map(\.sessionId)), ["daemon", "cli-bundle"],
                       "no host, and a host with no windows, both clear on presence")
        XCTAssertEqual(s.sessions["tab"]?.acknowledged, false,
                       "a real tab is still scoped: ttys001 is not the front tab")
        XCTAssertNotNil(s.sessions["tab"]?.notifyAt, "and its push stays armed")
    }

    /// The fail-open must not swallow tab scoping: while the host IS
    /// focusable, the tab still decides.
    func testAFocusableHostKeepsTabScoping() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0, sid: "hidden", host: "com.apple.Terminal", tty: "ttys002"))
        s.apply(ev(.stop, 1, sid: "hidden", tail: "Done."))
        XCTAssertTrue(s.acknowledgeAlerts(hostBundleId: "com.apple.Terminal", frontTTY: "ttys001",
                                          hostIsFocusable: { _ in true }).isEmpty,
                      "the tab he cannot see stays unread")
        XCTAssertTrue(s.acknowledgeAlerts(hostBundleId: "com.googlecode.iterm2", frontTTY: nil,
                                          hostIsFocusable: { _ in true }).isEmpty,
                      "and another terminal's focus is not his Terminal's")
    }

    func testAcknowledgeReturnsRecordsForPersistence() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0, host: "com.apple.Terminal"))
        s.apply(ev(.stop, 10, tail: "Done."))
        let acked = s.acknowledgeAlerts(hostBundleId: "com.apple.Terminal")
        XCTAssertEqual(acked.map(\.sessionId), ["s1"])
        XCTAssertEqual(acked.map(\.stateSince), [at(10)])
        XCTAssertTrue(s.acknowledgeAlerts(hostBundleId: "com.apple.Terminal").isEmpty,
                      "already acknowledged; nothing new to persist")
    }

    /// The replayed ack line: clears exactly the alert it was recorded
    /// against, and nothing else — not a newer alert, not liveness, not a
    /// session that no longer exists.
    func testAReplayedAckClearsTheAlertItWasRecordedAgainst() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0, host: "com.apple.Terminal"))
        s.apply(ev(.stop, 10, tail: "Done."))
        let lastEvent = s.sessions["s1"]!.lastEventAt
        s.apply(ev(.ack, 20, ackSince: 10))
        XCTAssertEqual(s.sessions["s1"]?.acknowledged, true)
        XCTAssertNil(s.sessions["s1"]?.notifyAt)
        XCTAssertEqual(s.sessions["s1"]?.lastEventAt, lastEvent,
                       "an ack is not activity; it must not refresh staleness")

        var stale = SessionStore()
        stale.apply(ev(.userPromptSubmit, 0, host: "com.apple.Terminal"))
        stale.apply(ev(.stop, 10, tail: "Done."))
        stale.apply(ev(.permissionRequest, 30, tool: "Bash"))
        stale.apply(ev(.ack, 40, ackSince: 10))
        XCTAssertEqual(stale.sessions["s1"]?.acknowledged, false,
                       "an ack for an older alert must not clear a newer one")

        var ghost = SessionStore()
        ghost.apply(ev(.ack, 0, ackSince: 0))
        XCTAssertTrue(ghost.sessions.isEmpty, "an ack must never create a session")
    }

    /// Without this, every restart would replay the alert, re-arm its long-
    /// past deadline, and the present-user defer would launder the lateness
    /// into a fresh deadline — three duplicate pushes in seven minutes in
    /// one recorded case. After replay, a deadline already outside the
    /// lateness window is dead.
    func testDropStaleNotificationsScrubsLongPastDeadlines() {
        var s = SessionStore()
        s.apply(ev(.stop, 0, tail: "Done."))
        s.dropStaleNotifications(now: at(K.notifyDebounceSeconds + K.notifyMaxLatenessSeconds + 1))
        XCTAssertNil(s.sessions["s1"]?.notifyAt, "a long-past deadline is the old instance's")
        XCTAssertEqual(s.tick(now: at(300), userPresent: true), [], "and can never be deferred back to life")

        var fresh = SessionStore()
        fresh.apply(ev(.stop, 0, tail: "Done."))
        fresh.dropStaleNotifications(now: at(5))
        XCTAssertNotNil(fresh.sessions["s1"]?.notifyAt,
                        "a deadline still in its window kept its chance")
    }

    // MARK: turn identity

    /// A verdict closes the turn. A tool event of that turn arriving later
    /// proves the hook alive and nothing else: the state stands, and the
    /// quiet-turn clock does not move.
    func testAToolEventOfAClosedTurnRefreshesLivenessOnly() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0, pid: 42, turn: "t1"))
        s.apply(ev(.preToolUse, 1, tool: "Bash", turn: "t1"))
        s.abandonTurn(sessionId: "s1", now: at(30))
        XCTAssertEqual(state(s), .idle)
        s.apply(ev(.postToolUse, 40, tool: "Bash", turn: "t1"))
        XCTAssertEqual(state(s), .idle, "a closed turn stays closed")
        XCTAssertEqual(s.sessions["s1"]?.stateSince, at(30))
        XCTAssertEqual(s.sessions["s1"]?.lastMainEventAt, at(1))
        XCTAssertEqual(s.sessions["s1"]?.lastEventAt, at(40), "the hook is alive")
        XCTAssertNil(s.sessions["s1"]?.notifyAt)
        XCTAssertEqual(s.sessions["s1"]?.closedTurnIds, ["t1"])
        s.apply(ev(.permissionRequest, 41, tool: "Bash", turn: "t1"))
        XCTAssertEqual(state(s), .idle, "nor does a permission ask of that turn")
    }

    /// A Stop ends the turn without closing it: a Stop hook that blocks the
    /// Stop keeps the same turn running under the same id, and that work
    /// counts. So does the work after the lost-Stop rescue.
    func testALateToolEventAfterAStopStillCountsBecauseAStopHookMayBlockIt() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0, turn: "t1"))
        s.apply(ev(.stop, 10, tail: "Done.", turn: "t1"))
        XCTAssertEqual(state(s), .done)
        s.apply(ev(.postToolUse, 12, tool: "Bash", turn: "t1"))
        XCTAssertEqual(state(s), .working)
        XCTAssertEqual(s.sessions["s1"]?.closedTurnIds, [])

        var n = SessionStore()
        n.apply(ev(.userPromptSubmit, 0, turn: "p1"))
        n.apply(ev(.notification, 60, ntype: "idle_prompt", turn: "p1"))
        XCTAssertEqual(state(n), .done, "the lost-Stop rescue")
        n.apply(ev(.postToolUse, 70, tool: "Bash", turn: "p1"))
        XCTAssertEqual(state(n), .working, "does not close the turn either")
    }

    /// A helper still out after a Stop is the hold, and a helper active after
    /// `done` means the turn was not over.
    func testAHelperOfAStoppedTurnStillHoldsIt() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0, turn: "t1"))
        s.apply(ev(.stop, 10, tail: "Done.", turn: "t1"))
        XCTAssertEqual(state(s), .done)
        s.apply(ev(.preToolUse, 20, tool: "Read", agent: "a1", turn: "t1"))
        XCTAssertEqual(state(s), .working, "the helper re-opens the finish")
        XCTAssertEqual(s.sessions["s1"]?.pendingDone, true)
        XCTAssertEqual(s.sessions["s1"]?.liveAgents["a1"], at(20))
    }

    /// The registry's verdicts close the turn, the finish as well as the
    /// interrupt, and a session followed from mid-turn closes the turn its
    /// last main-agent event named.
    func testARegistryVerdictClosesTheTurn() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0, pid: 42, turn: "p1"))
        s.apply(ev(.preToolUse, 1, tool: "Bash", turn: "p1"))
        s.abandonTurn(sessionId: "s1", now: at(30))
        s.apply(ev(.postToolUse, 40, tool: "Bash", turn: "p1"))
        XCTAssertEqual(state(s), .idle, "a straggler of the abandoned turn changes nothing")
        s.apply(ev(.preToolUse, 41, tool: "Read", agent: "a1", turn: "p1"))
        XCTAssertEqual(state(s), .idle, "nor does a helper of it")
        XCTAssertEqual(s.sessions["s1"]?.liveAgents, [:])

        var f = SessionStore()
        f.apply(ev(.userPromptSubmit, 0, pid: 42, turn: "p1"))
        f.apply(ev(.preToolUse, 1, tool: "Bash", turn: "p1"))
        f.finishTurn(sessionId: "s1", now: at(30))
        XCTAssertEqual(state(f), .done)
        f.apply(ev(.postToolUse, 40, tool: "Bash", turn: "p1"))
        XCTAssertEqual(state(f), .done)
        XCTAssertEqual(f.sessions["s1"]?.stateSince, at(30))

        var mid = SessionStore()
        mid.apply(ev(.preToolUse, 0, tool: "Bash", pid: 42, turn: "p1"))
        mid.abandonTurn(sessionId: "s1", now: at(30))
        mid.apply(ev(.postToolUse, 40, tool: "Bash", turn: "p1"))
        XCTAssertEqual(state(mid), .idle, "no prompt seen: the last turn named is the one closed")
    }

    /// A line without a turn id is never ignored for want of one: Claude
    /// lines written before the field follow the rules they always had.
    func testLinesWithoutATurnIdKeepTodaysRules() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0, pid: 42))
        s.apply(ev(.preToolUse, 1, tool: "Bash"))
        s.abandonTurn(sessionId: "s1", now: at(30))
        XCTAssertEqual(state(s), .idle)
        s.apply(ev(.postToolUse, 40, tool: "Bash"))
        XCTAssertEqual(state(s), .working, "no id, no closed turn to belong to")
        XCTAssertEqual(s.sessions["s1"]?.lastMainEventAt, at(40))
        XCTAssertEqual(s.sessions["s1"]?.closedTurnIds, [])

        var other = SessionStore()
        other.apply(ev(.userPromptSubmit, 0, pid: 42, turn: "t1"))
        other.abandonTurn(sessionId: "s1", now: at(30))
        other.apply(ev(.postToolUse, 40, tool: "Bash", turn: "t2"))
        XCTAssertEqual(state(other), .working, "an id no close named is no closed turn")
    }

    /// A verdict ends the helpers with the turn: a helper event of that turn
    /// changes nothing.
    func testAHelperEventAfterAVerdictIsIgnored() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0, pid: 42, turn: "p1"))
        s.abandonTurn(sessionId: "s1", now: at(30))
        s.apply(ev(.postToolUse, 40, tool: "Read", agent: "a1", turn: "p1"))
        XCTAssertEqual(state(s), .idle)
        XCTAssertEqual(s.sessions["s1"]?.liveAgents, [:])
        XCTAssertEqual(s.sessions["s1"]?.pendingDone, false)
        XCTAssertEqual(s.sessions["s1"]?.lastEventAt, at(40))
    }

    /// Every main-agent event of a closed turn but a prompt or a session
    /// start changes nothing, its Stop and its notifications included.
    func testAStopOrANotificationOfAClosedTurnIsIgnored() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0, pid: 42, turn: "p1"))
        s.abandonTurn(sessionId: "s1", now: at(30))
        s.apply(ev(.stop, 40, tail: "Done.", turn: "p1"))
        XCTAssertEqual(state(s), .idle, "no green for a turn already over")
        XCTAssertNil(s.sessions["s1"]?.notifyAt)
        s.apply(ev(.notification, 50, ntype: "permission_prompt", turn: "p1"))
        XCTAssertEqual(state(s), .idle, "no amber either")
        s.apply(ev(.stopFailure, 51, turn: "p1"))
        s.apply(ev(.preCompact, 52, turn: "p1"))
        XCTAssertEqual(state(s), .idle)
        XCTAssertEqual(s.sessions["s1"]?.stateSince, at(30))
    }

    /// Only the last eight closed turns are remembered.
    func testTheClosedTurnsAreBounded() {
        var s = SessionStore()
        for i in 0..<10 {
            s.apply(ev(.userPromptSubmit, Double(i * 10), turn: "t\(i)"))
            s.apply(ev(.interrupt, Double(i * 10 + 5), turn: "t\(i)"))
        }
        XCTAssertEqual(s.sessions["s1"]?.closedTurnIds, (2..<10).map { "t\($0)" })
    }

    /// A finish held behind a helper still reporting leaves the turn open,
    /// as a held Stop does: that helper's permission ask raises the amber
    /// and refreshes the helper, whether the finish was rescued or a Stop.
    func testAHeldRescuedFinishDoesNotCloseTheTurn() {
        func run(_ finish: (inout SessionStore) -> Void) -> SessionStore {
            var s = SessionStore()
            s.apply(ev(.userPromptSubmit, 0, pid: 42, turn: "p1"))
            s.apply(ev(.preToolUse, 1, tool: "Task", turn: "p1"))
            s.apply(ev(.preToolUse, 5, tool: "Read", agent: "a1", turn: "p1"))
            finish(&s)
            XCTAssertEqual(s.sessions["s1"]?.state, .working)
            XCTAssertEqual(s.sessions["s1"]?.pendingDone, true, "held behind the helper")
            XCTAssertEqual(s.sessions["s1"]?.closedTurnIds, [], "a held finish is not over yet")
            s.apply(ev(.permissionRequest, 40, tool: "Bash", agent: "a1", turn: "p1"))
            return s
        }
        let rescued = run { XCTAssertNil($0.finishTurn(sessionId: "s1", now: at(30))) }
        XCTAssertEqual(rescued.sessions["s1"]?.state, .waiting(.permission))
        XCTAssertEqual(rescued.sessions["s1"]?.liveAgents["a1"], at(40))
        XCTAssertNotNil(rescued.sessions["s1"]?.notifyAt, "the needs-you push is armed")
        let stopped = run { $0.apply(ev(.stop, 30, tail: "Done.", turn: "p1")) }
        XCTAssertEqual(stopped.sessions["s1"]?.state, rescued.sessions["s1"]?.state)
        XCTAssertEqual(stopped.sessions["s1"]?.liveAgents, rescued.sessions["s1"]?.liveAgents)
        XCTAssertEqual(stopped.sessions["s1"]?.notifyAt, rescued.sessions["s1"]?.notifyAt)
    }

    /// A new tool call is never the straggler of an aborted tool, and a
    /// Claude prompt id carries on across consecutive turns whose prompt
    /// line may be lost: a main-agent `PreToolUse` reopens a turn a verdict
    /// closed, and the turn's events count again.
    func testAToolCallAfterAVerdictReopensTheTurn() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0, pid: 42, turn: "p1"))
        s.apply(ev(.preToolUse, 1, tool: "Bash", turn: "p1"))
        s.finishTurn(sessionId: "s1", now: at(30))
        XCTAssertEqual(state(s), .done)
        XCTAssertEqual(s.sessions["s1"]?.closedTurnIds, ["p1"])
        s.apply(ev(.preToolUse, 60, tool: "Bash", turn: "p1"))
        XCTAssertEqual(state(s), .working, "the next turn under the same id is work")
        XCTAssertEqual(s.sessions["s1"]?.closedTurnIds, [], "and the id is open again")
        XCTAssertEqual(s.sessions["s1"]?.lastMainEventAt, at(60))
        s.apply(ev(.permissionRequest, 61, tool: "Bash", turn: "p1"))
        XCTAssertEqual(state(s), .waiting(.permission))
        s.apply(ev(.postToolUse, 70, tool: "Bash", turn: "p1"))
        XCTAssertEqual(state(s), .working, "a following PostToolUse counts")
        s.apply(ev(.stop, 80, tail: "Done.", turn: "p1"))
        XCTAssertEqual(state(s), .done, "and so does its Stop")

        var a = SessionStore()
        a.apply(ev(.userPromptSubmit, 0, pid: 42, turn: "p1"))
        a.abandonTurn(sessionId: "s1", now: at(30))
        a.apply(ev(.preToolUse, 60, tool: "Read", agent: "a1", turn: "p1"))
        XCTAssertEqual(state(a), .idle, "a helper's tool call reopens nothing")
        a.apply(ev(.preToolUse, 61, tool: "Bash", turn: "p1"))
        XCTAssertEqual(state(a), .working, "the abandoned turn's id reopens too")
    }

    /// An interrupt's close is reopened by a prompt and by nothing else: a
    /// tool call of the interrupted turn is its aborted tool's straggler.
    func testAToolCallAfterAnInterruptDoesNotReopenTheTurn() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0, turn: "t1"))
        s.apply(ev(.preToolUse, 1, tool: "Bash", turn: "t1"))
        s.apply(ev(.interrupt, 10, turn: "t1"))
        s.apply(ev(.preToolUse, 20, tool: "Bash", turn: "t1"))
        XCTAssertEqual(state(s), .idle)
        XCTAssertEqual(s.sessions["s1"]?.closedTurnIds, ["t1"])
        s.apply(ev(.preToolUse, 10 + K.abortQuarantineSeconds + 60, tool: "Bash", turn: "t1"))
        XCTAssertEqual(state(s), .idle, "past the quarantine as well")

        // A verdict that closed the turn first, then an interrupt naming no
        // turn: the interrupt's close is the one that stands.
        var v = SessionStore()
        v.apply(ev(.userPromptSubmit, 0, pid: 42, turn: "t1"))
        v.finishTurn(sessionId: "s1", now: at(30))
        v.apply(ev(.interrupt, 40))
        v.apply(ev(.preToolUse, 50, tool: "Bash", turn: "t1"))
        XCTAssertEqual(state(v), .idle)
        XCTAssertEqual(v.sessions["s1"]?.closedTurnIds, ["t1"])
    }

    /// Only a tool call reopens a verdict's close: the late end of a tool,
    /// its failure, a permission, a Stop, a notification, a compaction and
    /// a helper's event still change nothing.
    func testALatePostToolUseAfterAVerdictStillChangesNothing() {
        let late: [JournalEvent] = [
            ev(.postToolUse, 40, tool: "Bash", turn: "p1"),
            ev(.postToolUseFailure, 40, tool: "Bash", turn: "p1"),
            ev(.permissionRequest, 40, tool: "Bash", turn: "p1"),
            ev(.permissionDenied, 40, tool: "Bash", turn: "p1"),
            ev(.stop, 40, tail: "Done.", turn: "p1"),
            ev(.notification, 40, ntype: "permission_prompt", turn: "p1"),
            ev(.preCompact, 40, turn: "p1"),
            ev(.postCompact, 40, turn: "p1"),
            ev(.preToolUse, 40, tool: "Bash", agent: "a1", turn: "p1"),
        ]
        for e in late {
            var s = SessionStore()
            s.apply(ev(.userPromptSubmit, 0, pid: 42, turn: "p1"))
            s.apply(ev(.preToolUse, 1, tool: "Bash", turn: "p1"))
            s.abandonTurn(sessionId: "s1", now: at(30))
            s.apply(e)
            XCTAssertEqual(state(s), .idle, "\(e.event)")
            XCTAssertEqual(s.sessions["s1"]?.closedTurnIds, ["p1"], "\(e.event)")
            XCTAssertEqual(s.sessions["s1"]?.stateSince, at(30), "\(e.event)")
        }
    }

    // MARK: Codex's rollout check

    /// A Codex event: the agent says who, and the pid is the one the hook
    /// recorded, the managed daemon's for a TUI session.
    func codex(_ name: HookEventName, _ t: TimeInterval, sid: String = "c1", tool: String? = nil,
               pid: Int32? = 40531, turn: String? = nil, rollout: String? = nil) -> JournalEvent {
        var e = ev(name, t, sid: sid, tool: tool, pid: pid, turn: turn)
        e.agent = .codex
        e.transcriptPath = rollout
        return e
    }

    func testAQuietCodexSessionIsACandidateAndAClaudeOneIsNot() {
        let rollout = "/Users/u/.codex/sessions/2026/09/25/rollout-2026-09-25T18-50-00-c1.jsonl"
        var s = SessionStore()
        s.apply(codex(.userPromptSubmit, 0, turn: "t1", rollout: rollout))
        s.apply(codex(.preToolUse, 1, tool: "shell", turn: "t1"))
        s.apply(codex(.userPromptSubmit, 0, sid: "c2", pid: nil, turn: "u1"))
        s.apply(ev(.userPromptSubmit, 0, sid: "a1", pid: 78))
        s.apply(ev(.preToolUse, 1, sid: "a1", tool: "Bash"))

        XCTAssertTrue(s.codexCandidates(at: at(5)).isEmpty, "not quiet yet")
        let quiet = s.codexCandidates(at: at(1 + K.abandonQuietSeconds))
        XCTAssertEqual(quiet.map(\.sessionId), ["c1", "c2"], "a pid is not needed: the rollout is the session's")
        XCTAssertEqual(quiet.first?.transcriptPath, rollout)
        XCTAssertNil(quiet.last?.transcriptPath)
        XCTAssertEqual(s.abandonCandidates(at: at(100)).map(\.sessionId), ["a1"],
                       "the registry rescue stays Claude's")
        XCTAssertEqual(s.codexCandidates(at: at(5), quietSeconds: 0).map(\.sessionId), ["c1", "c2"],
                       "the launch check has no quiet gate")
        XCTAssertEqual(s.abandonCandidates(at: at(5), quietSeconds: 0).map(\.sessionId), ["a1"])

        s.apply(codex(.stop, 30, turn: "t1"))
        s.apply(codex(.subagentStart, 30, sid: "c2", pid: nil, turn: "u1"))
        var helper = codex(.preToolUse, 31, sid: "c2", tool: "shell", pid: nil, turn: "u1")
        helper.agentId = "h1"
        s.apply(helper)
        XCTAssertTrue(s.codexCandidates(at: at(100)).isEmpty,
                      "a finished session, or one with a helper out, is not a candidate")
    }

    /// `turn_aborted` is the interrupt: dark, no alert, no push, and the
    /// turn is closed, so the aborted tool's late event changes nothing.
    /// `task_complete` is the lost Stop, with the push a Stop earns.
    func testAnAbortedRolloutGoesDarkWithoutAPush() {
        var s = SessionStore()
        s.apply(codex(.userPromptSubmit, 0, turn: "t1"))
        s.apply(codex(.preToolUse, 1, tool: "shell", turn: "t1"))
        s.abandonTurn(sessionId: "c1", now: at(30))
        XCTAssertEqual(state(s, "c1"), .idle)
        XCTAssertNil(s.sessions["c1"]?.notifyAt)
        XCTAssertTrue(s.tick(now: at(30 + K.notifyDebounceSeconds + 1)).isEmpty)
        s.apply(codex(.postToolUse, 40, tool: "shell", turn: "t1"))
        XCTAssertEqual(state(s, "c1"), .idle, "the aborted tool's late end does not reopen the turn")

        s.apply(codex(.userPromptSubmit, 100, sid: "c2", turn: "u1"))
        s.finishTurn(sessionId: "c2", now: at(130))
        XCTAssertEqual(state(s, "c2"), .done)
        XCTAssertEqual(s.sessions["c2"]?.notifyAt, at(130 + K.notifyDebounceSeconds))
        let pushed = s.tick(now: at(130 + K.notifyDebounceSeconds))
        XCTAssertEqual(pushed.map(\.sessionId), ["c2"])
        XCTAssertEqual(pushed.first?.agent, .codex)
        XCTAssertEqual(pushed.first?.kind, .finished)
    }

    func testNextDeadlineCoversTheCodexRecheck() {
        var s = SessionStore()
        s.apply(codex(.userPromptSubmit, 0, turn: "t1"))
        s.apply(codex(.preToolUse, 1, tool: "shell", turn: "t1"))
        XCTAssertEqual(s.nextDeadline(after: at(5)), at(1 + K.abandonQuietSeconds),
                       "wake when the session becomes a candidate")
        XCTAssertEqual(s.nextDeadline(after: at(100)), at(100 + K.abandonRecheckSeconds),
                       "then on the recheck cadence while it stays one")

        var pidless = SessionStore()
        pidless.apply(codex(.userPromptSubmit, 0, pid: nil, turn: "t1"))
        XCTAssertEqual(pidless.nextDeadline(after: at(100)), at(100 + K.abandonRecheckSeconds),
                       "the rollout needs no pid")

        var claude = SessionStore()
        claude.apply(ev(.userPromptSubmit, 0))
        XCTAssertEqual(claude.nextDeadline(after: at(100)), at(K.staleSeconds),
                       "a Claude session without a pid has no registry to read")
    }

    /// A rollout or an `events.jsonl` that decided nothing is read again
    /// `K.abandonRecheckSeconds` after the last read at the earliest,
    /// however often the journal delivers other lines, unless the session
    /// had an event since; one never read is read at once.
    func testAQuietSourceIsReadAgainOnlyOnTheRecheckOrAfterAnEvent() {
        var s = SessionStore()
        s.apply(codex(.userPromptSubmit, 0, turn: "t1"))
        let session = s.sessions["c1"]!
        XCTAssertTrue(SessionStore.sourceReadIsDue(session, checkedAt: nil, now: at(30)), "never read")
        XCTAssertFalse(SessionStore.sourceReadIsDue(session, checkedAt: at(30), now: at(31)))
        XCTAssertFalse(SessionStore.sourceReadIsDue(session, checkedAt: at(30),
                                                    now: at(30 + K.abandonRecheckSeconds - 0.001)))
        XCTAssertTrue(SessionStore.sourceReadIsDue(session, checkedAt: at(30),
                                                   now: at(30 + K.abandonRecheckSeconds)))
        s.apply(codex(.postToolUse, 32, tool: "shell", turn: "t1"))
        XCTAssertTrue(SessionStore.sourceReadIsDue(s.sessions["c1"]!, checkedAt: at(30), now: at(33)),
                      "an event since the last read")
        s.noteBusy(sessionId: "c1", now: at(30))
        XCTAssertFalse(SessionStore.sourceReadIsDue(s.sessions["c1"]!, checkedAt: at(32), now: at(33)),
                       "liveness from the source's own last write is no event")
    }

    /// A rescued finish is dated to the turn's real end: found later than
    /// the lateness window, it is the `Stop` that was lost, replayed —
    /// `done` for what is left of its time, and no push.
    func testARescuedFinishStampedInThePastNeverPushes() {
        var s = SessionStore()
        s.apply(codex(.userPromptSubmit, 0, turn: "t1"))
        s.apply(codex(.preToolUse, 1, tool: "shell", turn: "t1"))
        let ended = at(60)
        let found = at(60 + K.notifyMaxLatenessSeconds + K.notifyDebounceSeconds + 30)
        s.finishTurn(sessionId: "c1", now: found, endedAt: ended)
        XCTAssertEqual(state(s, "c1"), .done)
        XCTAssertEqual(s.sessions["c1"]?.stateSince, ended)
        XCTAssertTrue(s.tick(now: found).isEmpty, "a late push is worse than none")
        XCTAssertEqual(state(s, "c1"), .done)
        s.tick(now: ended.addingTimeInterval(K.doneVisibleSeconds))
        XCTAssertEqual(state(s, "c1"), .idle, "green counts from the real end")

        var dark = SessionStore()
        dark.apply(codex(.userPromptSubmit, 0, turn: "t1"))
        dark.abandonTurn(sessionId: "c1", now: found, endedAt: ended)
        XCTAssertEqual(dark.sessions["c1"]?.stateSince, ended)
    }

    /// Found within seconds of its end, the same rescue still pushes. The
    /// stamp is never before the last main-agent event (an end marker naming
    /// the turn can be stamped before the aborted tool's late event) and
    /// never after now.
    func testAFreshRescuedFinishStillPushes() {
        var s = SessionStore()
        s.apply(codex(.userPromptSubmit, 0, turn: "t1"))
        s.apply(codex(.preToolUse, 1, tool: "shell", turn: "t1"))
        s.finishTurn(sessionId: "c1", now: at(40), endedAt: at(30))
        XCTAssertEqual(s.sessions["c1"]?.stateSince, at(30))
        XCTAssertTrue(s.tick(now: at(40)).isEmpty, "the debounce still runs from the end")
        let pushed = s.tick(now: at(30 + K.notifyDebounceSeconds))
        XCTAssertEqual(pushed.map(\.kind), [.finished])

        var late = SessionStore()
        late.apply(codex(.userPromptSubmit, 0, turn: "t1"))
        late.apply(codex(.postToolUse, 13, tool: "shell", turn: "t1"))
        late.abandonTurn(sessionId: "c1", now: at(40), endedAt: at(10))
        XCTAssertEqual(late.sessions["c1"]?.stateSince, at(13), "not before the last main-agent event")
        var ahead = SessionStore()
        ahead.apply(codex(.userPromptSubmit, 0, turn: "t1"))
        ahead.finishTurn(sessionId: "c1", now: at(40), endedAt: at(90))
        XCTAssertEqual(ahead.sessions["c1"]?.stateSince, at(40), "not after now")
    }

    /// A rollout that says the turn runs keeps the session alive as of its
    /// last line, never earlier than the session's own last event: a turn
    /// that died without an end marker stops writing, and the 2 h backstop
    /// still meets it.
    func testABusyRolloutKeepsTheSessionAliveFromItsLastLine() {
        var s = SessionStore()
        s.apply(codex(.userPromptSubmit, 0, turn: "t1"))
        s.noteBusy(sessionId: "c1", now: at(600))
        XCTAssertEqual(s.sessions["c1"]?.lastEventAt, at(600))
        XCTAssertEqual(s.sessions["c1"]?.lastMainEventAt, at(0), "hook silence is still measured")
        s.noteBusy(sessionId: "c1", now: at(300))
        XCTAssertEqual(s.sessions["c1"]?.lastEventAt, at(600), "liveness never moves backwards")
        s.tick(now: at(600 + K.staleSeconds))
        XCTAssertNil(s.sessions["c1"], "forgotten 2 h after the rollout's last line")
    }

    /// Every TUI session's hooks record the managed daemon's pid, which
    /// stays alive across every TUI: the prune keeps them, and the launch
    /// check, which has no quiet gate, decides each one from its rollout.
    /// A dead pid still drops its sessions, the daemon's included.
    func testPruneKeepsADaemonHostedSessionForTheCodexCheck() {
        var s = SessionStore()
        s.apply(codex(.userPromptSubmit, 0, sid: "c1", turn: "t1"))
        s.apply(codex(.userPromptSubmit, 1, sid: "c2", turn: "u1"))
        s.apply(codex(.userPromptSubmit, 2, sid: "c3", pid: 555, turn: "x1"))
        s.pruneDead { agent, pid in agent == .codex && pid == 40531 }
        XCTAssertEqual(s.sessions.keys.sorted(), ["c1", "c2"])
        XCTAssertEqual(s.codexCandidates(at: at(3), quietSeconds: 0).map(\.sessionId), ["c1", "c2"])

        s.processExited(pid: 40531)
        XCTAssertTrue(s.sessions.isEmpty, "the daemon's death forgets every session it hosted")
    }

    // MARK: - verdicts in the journal

    func verdictLine(_ verdict: String, _ t: TimeInterval, sid: String = "s1") -> JournalEvent {
        var e = ev(.verdict, t, sid: sid)
        e.verdict = verdict
        return e
    }

    /// A verdict the app reached live goes into the journal, stamped when it
    /// took effect: replaying the same lines, the line included, gives the
    /// very session the live store holds, and the live store reading its own
    /// line back through the tailer changes nothing.
    func testAJournaledVerdictReplaysAsTheSameVerdict() {
        let turn = [ev(.userPromptSubmit, 0, pid: 42, turn: "p1"),
                    ev(.preToolUse, 5, tool: "Bash", turn: "p1")]
        func replay(_ lines: [JournalEvent]) -> SessionStore {
            var s = SessionStore()
            for line in lines { s.apply(line) }
            return s
        }

        var dark = replay(turn)
        let darkAt = dark.abandonTurn(sessionId: "s1", now: at(60), endedAt: at(40))
        XCTAssertEqual(darkAt, at(40), "the verdict says when it took effect")
        let darkLine = verdictLine("turn-abandoned", 40)
        XCTAssertEqual(replay(turn + [darkLine]).sessions["s1"], dark.sessions["s1"])
        let before = dark.sessions["s1"]
        dark.apply(darkLine)
        XCTAssertEqual(dark.sessions["s1"], before, "the app's own line read back is a no-op")

        var green = replay(turn)
        let greenAt = green.finishTurn(sessionId: "s1", now: at(60), endedAt: at(40))
        XCTAssertEqual(greenAt, at(40))
        let greenLine = verdictLine("turn-finished", 40)
        XCTAssertEqual(replay(turn + [greenLine]).sessions["s1"], green.sessions["s1"])
        XCTAssertEqual(state(replay(turn + [greenLine])), .done)
        let finished = green.sessions["s1"]
        green.apply(greenLine)
        XCTAssertEqual(green.sessions["s1"], finished)

        // The lost Stop with a lost SubagentStop: the helper last reported
        // 10 s before the turn ended and was stale when the check ran. The
        // line records the finish, and replay applies it as it was, not
        // re-decided behind a helper that is still fresh at the stamp.
        let helped = turn + [ev(.preToolUse, 30, tool: "Read", agent: "h1", turn: "p1")]
        var late = replay(helped)
        let lateAt = late.finishTurn(sessionId: "s1", now: at(400), endedAt: at(40))
        XCTAssertEqual(lateAt, at(40))
        let replayed = replay(helped + [verdictLine("turn-finished", 40)])
        XCTAssertEqual(replayed.sessions["s1"], late.sessions["s1"])
        XCTAssertEqual(replayed.sessions["s1"]?.state, .done)
        XCTAssertEqual(replayed.sessions["s1"]?.stateSince, at(40))
        XCTAssertEqual(replayed.sessions["s1"]?.pendingDone, false)
        XCTAssertEqual(replayed.sessions["s1"]?.notifyAt, late.sessions["s1"]?.notifyAt)

        // A finish held behind a helper still out is the hold rules' to end,
        // not an outcome: nothing is recorded, and a relaunch decides afresh.
        var held = replay(turn + [ev(.preToolUse, 30, tool: "Read", agent: "h1", turn: "p1")])
        XCTAssertNil(held.finishTurn(sessionId: "s1", now: at(60), endedAt: at(40)))
        XCTAssertEqual(held.sessions["s1"]?.pendingDone, true)

        let dialog = [ev(.userPromptSubmit, 0, pid: 42, turn: "p1"),
                      ev(.preToolUse, 5, tool: "ExitPlanMode", turn: "p1")]
        var answered = replay(dialog)
        let answeredAt = answered.dialogAnswered(sessionId: "s1", now: at(30))
        XCTAssertEqual(answeredAt, at(30))
        let answeredLine = verdictLine("dialog-answered", 30)
        XCTAssertEqual(replay(dialog + [answeredLine]).sessions["s1"], answered.sessions["s1"])
        XCTAssertEqual(state(replay(dialog + [answeredLine])), .working)

        var waiting = replay(dialog)
        XCTAssertNil(waiting.abandonTurn(sessionId: "s1", now: at(30)),
                     "a verdict that changes nothing has nothing to record")
        var twice = replay(turn)
        twice.abandonTurn(sessionId: "s1", now: at(60), endedAt: at(40))
        XCTAssertNil(twice.abandonTurn(sessionId: "s1", now: at(70), endedAt: at(40)))
    }

    /// A relaunch replays the finish it recovered, never its push: the
    /// deadline is as old as the turn's end, and the launch scrub drops it.
    func testAReplayedFinishVerdictNeverPushesAtLaunch() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0, pid: 42, turn: "p1"))
        s.apply(ev(.preToolUse, 5, tool: "Bash", turn: "p1"))
        s.apply(verdictLine("turn-finished", 40))
        XCTAssertEqual(state(s), .done)
        let launch = at(40 + K.notifyDebounceSeconds + K.notifyMaxLatenessSeconds + 1)
        s.dropStaleNotifications(now: launch)
        XCTAssertEqual(s.tick(now: launch, userPresent: false), [])
        XCTAssertEqual(state(s), .done, "green for what is left of its time")
    }

    func testAVerdictForAnUnknownSessionIsIgnored() {
        var s = SessionStore()
        s.apply(verdictLine("turn-finished", 10, sid: "ghost"))
        s.apply(verdictLine("turn-abandoned", 10, sid: "ghost"))
        s.apply(verdictLine("dialog-answered", 10, sid: "ghost"))
        XCTAssertTrue(s.sessions.isEmpty, "a verdict never creates a session")

        s.apply(ev(.userPromptSubmit, 0, pid: 42))
        s.apply(verdictLine("turn-something-new", 30))
        XCTAssertEqual(state(s), .working, "a verdict this version does not know changes nothing")
        XCTAssertEqual(s.sessions["s1"]?.lastEventAt, at(0))
    }

    /// A verdict is about the turn it saw: a main-agent event after its stamp
    /// means the session moved on, and the line changes nothing. One at the
    /// same instant applies. Either way it is not activity.
    func testAVerdictOlderThanTheLastMainEventIsIgnored() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0, pid: 42))
        s.apply(ev(.preToolUse, 5, tool: "Bash"))
        s.apply(verdictLine("turn-abandoned", 3))
        XCTAssertEqual(state(s), .working)
        XCTAssertEqual(s.sessions["s1"]?.lastEventAt, at(5), "a verdict never refreshes liveness")

        s.apply(verdictLine("turn-abandoned", 5))
        XCTAssertEqual(state(s), .idle, "the same instant applies")
        XCTAssertEqual(s.sessions["s1"]?.stateSince, at(5))
        XCTAssertEqual(s.sessions["s1"]?.lastEventAt, at(5))
    }

    /// A pid Claude Code has since given to another session, or a recycled
    /// pid another Claude took, no longer runs this one: the registry record
    /// names the session a Claude process hosts. No record proves nothing;
    /// Codex has no registry.
    func testPruneDropsAPidWhoseRegistryNamesAnotherSession() {
        var s = SessionStore()
        var withTranscript = ev(.userPromptSubmit, 0, sid: "s1", pid: 42)
        withTranscript.transcriptPath = "/tmp/cfg/projects/slug/s1.jsonl"
        s.apply(withTranscript)
        s.apply(ev(.userPromptSubmit, 1, sid: "s2", pid: 43))
        s.apply(ev(.userPromptSubmit, 2, sid: "s3", pid: 44))
        var codex = ev(.userPromptSubmit, 3, sid: "c1", pid: 43)
        codex.agent = .codex
        s.apply(codex)
        var asked: [Int32: String?] = [:]
        s.pruneDead(isAlive: { _, _ in true }, registrySession: { pid, transcript in
            asked[pid] = transcript
            switch pid {
            case 42: return "s1"
            case 43: return "someone-else"
            default: return nil
            }
        })
        XCTAssertEqual(s.sessions.keys.sorted(), ["c1", "s1", "s3"])
        XCTAssertEqual(asked[42], "/tmp/cfg/projects/slug/s1.jsonl",
                       "the record is looked up where the session's transcript lives")

        var dead = SessionStore()
        dead.apply(ev(.userPromptSubmit, 0, sid: "s1", pid: 42))
        dead.pruneDead(isAlive: { _, _ in false }, registrySession: { _, _ in "s1" })
        XCTAssertTrue(dead.sessions.isEmpty, "a record never keeps a dead pid")
    }

    /// The launch check runs before the first paint with no quiet gate: the
    /// hooks that could have ended a turn fired while the app was away.
    func testAbandonCandidatesAtLaunchIgnoreTheQuietGate() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0, pid: 42))
        XCTAssertTrue(s.abandonCandidates(at: at(1)).isEmpty, "live, the quiet gate holds")
        XCTAssertEqual(s.abandonCandidates(at: at(1), quietSeconds: 0).map(\.sessionId), ["s1"])
    }
}

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

    func testCompactionStaysWorking() {
        var s = SessionStore()
        s.apply(ev(.userPromptSubmit, 0))
        s.apply(ev(.preCompact, 1))
        XCTAssertEqual(state(s), .working)
        s.apply(ev(.sessionStart, 2, source: "compact"))
        XCTAssertEqual(state(s), .working, "SessionStart(compact) happens mid-flight")
        s.apply(ev(.postCompact, 3))
        XCTAssertEqual(state(s), .working)
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
    /// store nominates every open wait for the registry check; the verdict
    /// flips it back to working and disarms its push.
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

        var dead = SessionStore()
        dead.apply(ev(.userPromptSubmit, 0, pid: 42))
        dead.apply(ev(.stopFailure, 5))
        XCTAssertTrue(dead.openWaitCandidates().isEmpty,
                      "a dead turn's wait is not an open dialog")
        dead.dialogAnswered(sessionId: "s1", now: at(300))
        XCTAssertEqual(state(dead), .waiting(.error), "and the verdict refuses it too")
    }

    func testOpenWaitSchedulesItsRecheck() {
        var s = SessionStore()
        s.apply(ev(.preToolUse, 0, tool: "AskUserQuestion", pid: 42))
        _ = s.tick(now: at(60))
        let next = s.nextDeadline(after: at(60))
        XCTAssertNotNil(next)
        XCTAssertLessThanOrEqual(next!.timeIntervalSince(at(60)), K.abandonRecheckSeconds,
                                 "an open wait must keep waking the registry check")
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
        XCTAssertNil(s.sessions["s1"]?.openTurnId)
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

    /// Only the last eight closed turns are remembered.
    func testTheClosedTurnsAreBounded() {
        var s = SessionStore()
        for i in 0..<10 {
            s.apply(ev(.userPromptSubmit, Double(i * 10), turn: "t\(i)"))
            s.apply(ev(.interrupt, Double(i * 10 + 5), turn: "t\(i)"))
        }
        XCTAssertEqual(s.sessions["s1"]?.closedTurnIds, (2..<10).map { "t\($0)" })
    }
}

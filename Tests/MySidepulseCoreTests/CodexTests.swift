import XCTest
@testable import MySidepulseCore

/// Codex beside Claude Code: its own colour and roll, the roll both agents
/// share, its own hooks and events, and the sentences and pushes that name it.
final class CodexTests: XCTestCase {
    func p(_ s: DisplayState, leds: Int = 8, brightness: Int = 255) -> String {
        LedProgram.program(for: s, power: nil, ledCount: leds, brightness: brightness)
    }

    // MARK: the programs, byte for byte

    func testCodexRollsInItsOwnColour() {
        XCTAssertEqual(p(.working(.codex)), """
        off 160ms cosine
        0:#0a00ff 760ms pulse 0ms; 1:#0a00ff 760ms pulse 95ms; 2:#0a00ff 760ms pulse 190ms; 3:#0a00ff 760ms pulse 285ms; 4:#0a00ff 760ms pulse 380ms; 5:#0a00ff 760ms pulse 475ms; 6:#0a00ff 760ms pulse 570ms; 7:#0a00ff 760ms pulse 665ms
        repeat
        """)
        XCTAssertEqual(p(.working(.codex), leds: 2), """
        off 160ms cosine
        0:#0a00ff 760ms pulse 0ms; 1:#0a00ff 760ms pulse 260ms
        repeat
        """)
    }

    /// Both at work: one pass in Claude's colour, the next in Codex's, each
    /// opening with the roll's own fade so the rhythm never changes. Two
    /// passes of eight LEDs are 496 bytes, inside the strip's 512.
    func testASharedRollAlternatesItsColourAtEveryPass() {
        let program = p(.working(.both))
        XCTAssertEqual(program, """
        off 160ms cosine
        0:#ff374a 760ms pulse 0ms; 1:#ff374a 760ms pulse 95ms; 2:#ff374a 760ms pulse 190ms; 3:#ff374a 760ms pulse 285ms; 4:#ff374a 760ms pulse 380ms; 5:#ff374a 760ms pulse 475ms; 6:#ff374a 760ms pulse 570ms; 7:#ff374a 760ms pulse 665ms
        off 160ms cosine
        0:#0a00ff 760ms pulse 0ms; 1:#0a00ff 760ms pulse 95ms; 2:#0a00ff 760ms pulse 190ms; 3:#0a00ff 760ms pulse 285ms; 4:#0a00ff 760ms pulse 380ms; 5:#0a00ff 760ms pulse 475ms; 6:#0a00ff 760ms pulse 570ms; 7:#0a00ff 760ms pulse 665ms
        repeat
        """)
        XCTAssertEqual(program.utf8.count, 496)
        XCTAssertEqual(p(.working(.both), leds: 2), """
        off 160ms cosine
        0:#ff374a 760ms pulse 0ms; 1:#ff374a 760ms pulse 260ms
        off 160ms cosine
        0:#0a00ff 760ms pulse 0ms; 1:#0a00ff 760ms pulse 260ms
        repeat
        """)
        XCTAssertEqual(LedContinuation.loopMs(of: program), 2 * (160 + 665 + 760))
    }

    /// Under a zone the two passes would not fit (two sets of blink lines
    /// and roll lines are over 700 bytes), so the shared roll alternates its
    /// colour by LED instead, Claude's first.
    func testASharedRollUnderAZoneAlternatesByLed() {
        XCTAssertEqual(p(.split(alert: .waiting(.claude), work: .working(.both))), """
        0:#000000 160ms; 1:#000000 160ms; 2:#000000 160ms; 3:#000000 160ms; 4:#000000 160ms; 5:#000000 160ms; 6:#000000 160ms; 7:#000000 160ms
        0:#ff7000 200ms pulse 0ms; 1:#ff7000 200ms pulse 0ms; 2:#ff7000 200ms pulse 0ms
        0:#ff7000 200ms pulse 70ms; 1:#ff7000 200ms pulse 70ms; 2:#ff7000 200ms pulse 70ms; 3:#ff374a 760ms pulse 0ms; 4:#0a00ff 760ms pulse 95ms; 5:#ff374a 760ms pulse 190ms; 6:#0a00ff 760ms pulse 285ms; 7:#ff374a 760ms pulse 380ms
        repeat
        """)
        XCTAssertEqual(p(.split(alert: .done(.codex), work: .working(.both))), """
        0:#00ff37 160ms; 1:#00ff37 160ms; 2:#000000 160ms; 3:#000000 160ms; 4:#000000 160ms; 5:#000000 160ms; 6:#000000 160ms; 7:#000000 160ms
        2:#ff374a 760ms pulse 0ms; 3:#0a00ff 760ms pulse 95ms; 4:#ff374a 760ms pulse 190ms; 5:#0a00ff 760ms pulse 285ms; 6:#ff374a 760ms pulse 380ms; 7:#0a00ff 760ms pulse 475ms
        repeat
        """)
        XCTAssertTrue(p(.split(alert: .done(.claude), work: .working(.codex))).contains("2:#0a00ff 760ms pulse 0ms"))
    }

    /// Needs you and done are the same colours for both agents: the strip
    /// says that the Mac wants the user, not which agent does.
    func testAlertsLookTheSameWhoeverRaisedThem() {
        XCTAssertEqual(p(.waiting(.codex)), p(.waiting(.claude)))
        XCTAssertEqual(p(.done(.codex)), p(.done(.claude)))
        XCTAssertEqual(p(.waiting(.both)), p(.waiting(.claude)))
        XCTAssertEqual(p(.split(alert: .done(.codex), work: .working(.claude))),
                       p(.split(alert: .done(.claude), work: .working(.claude))))
    }

    func testTheSharedRollIsInsideTheDeviceLimitsAndReadsBack() {
        let states: [DisplayState] = [.working(.codex), .working(.both),
                                      .split(alert: .waiting(.both), work: .working(.both)),
                                      .split(alert: .done(.both), work: .working(.both)),
                                      .split(alert: .jobFailed, work: .working(.both))]
        for state in states {
            for leds in [2, 8] {
                let program = p(state, leds: leds, brightness: 200)
                XCTAssertLessThanOrEqual(program.utf8.count, 512, "\(state) on \(leds)")
                XCTAssertLessThanOrEqual(program.split(separator: "\n").count, 20, "\(state) on \(leds)")
                let parsed = LedContinuation.parse(program)
                XCTAssertNotNil(parsed, "\(state) on \(leds) does not read back")
                XCTAssertEqual(parsed.map(LedContinuation.text), program)
            }
        }
        XCTAssertTrue(LedMode.isRGBHex(K.codexWorking))
    }

    /// The full-strip roll changing colour carries on; anything else is a
    /// new animation.
    func testWhichChangesRecolourTheRoll() {
        XCTAssertTrue(LedProgram.rollRecolour(from: .working(.claude), to: .working(.both)))
        XCTAssertTrue(LedProgram.rollRecolour(from: .working(.both), to: .working(.codex)))
        XCTAssertFalse(LedProgram.rollRecolour(from: .working(.claude), to: .working(.claude)))
        XCTAssertFalse(LedProgram.rollRecolour(from: .working(.claude), to: .jobRunning))
        XCTAssertFalse(LedProgram.rollRecolour(from: .split(alert: .done(.claude), work: .working(.claude)),
                                               to: .split(alert: .done(.claude), work: .working(.both))))
        XCTAssertNil(LedProgram.rollHandover(from: .working(.claude), to: .working(.both), ledCount: 8),
                     "a recolour is not a zone change")
        XCTAssertNotNil(LedProgram.rollHandover(from: .working(.both),
                                                to: .split(alert: .waiting(.codex), work: .working(.both)),
                                                ledCount: 8), "the shared roll carries on under a zone")
    }

    /// A brightness change during the shared roll keeps the bridge: while
    /// the bridge and the whole rest fit, the whole rest plays and the loop
    /// starts after the blue pass; when they would not, the tail ends at
    /// the pass boundary instead, where every LED is dark, and the loop
    /// starts there.
    func testASharedRollTailKeepsItsBridgeByEndingAtThePass() {
        let loop = p(.working(.both))
        let whole = LedContinuation.tail(of: loop, elapsedMs: 500, brightness: 128)!
        XCTAssertTrue(whole.unscaled.hasPrefix("0:#ff374a 60ms; 1:#ff374a 60ms; 2:#000000 60ms; 3:#000000 60ms\n"),
                      "the bridge is kept: \(whole.unscaled)")
        XCTAssertEqual(whole.lengthMs, 3170 - 500, "four LEDs lit: the bridge and the whole rest fit")
        XCTAssertTrue(whole.program.contains("#050080"), "the blue pass, scaled")
        XCTAssertLessThanOrEqual(whole.program.utf8.count, 512)
        let pass = LedContinuation.tail(of: loop, elapsedMs: 800, brightness: 128)!
        let lines = pass.unscaled.split(separator: "\n")
        XCTAssertEqual(lines.count, 2, "the bridge and the pass's rest")
        XCTAssertTrue(lines[0].hasPrefix("0:#0f0304 60ms; 1:#5b141a 60ms; 2:#bc2937 60ms; 3:#ff374a 60ms; 4:#ff374a 60ms; 5:#000000 60ms"),
                      "seven LEDs lit or about to be: still bridged: \(pass.unscaled)")
        XCTAssertEqual(pass.lengthMs, 1585 - 800, "the tail ends at the red pass's end")
        XCTAssertLessThanOrEqual(pass.program.utf8.count, 512)
        XCTAssertFalse(pass.unscaled.contains("#0a00ff"), "the blue pass belongs to the loop written next")
    }

    /// A question landing over the shared roll: the zone opens at once, the
    /// roll finishes its pass, and the split's own program takes over at
    /// the pass boundary. Inside 512 bytes at every phase.
    func testAZoneOverTheSharedRollHandsOverAtThePass() {
        let from = DisplayState.working(.both)
        for to in [DisplayState.split(alert: .waiting(.claude), work: .working(.both)),
                   .split(alert: .done(.codex), work: .working(.both))] {
            let roll = LedProgram.rollHandover(from: from, to: to, ledCount: 8)!
            let loopMs = LedContinuation.loopMs(of: p(from))!
            for phase in stride(from: 0, to: loopMs, by: 5) {
                guard let tail = LedContinuation.transition(
                    from: p(from), to: p(to), elapsedMs: phase, ledCount: 8, zoneBefore: roll.zoneBefore,
                    zoneAfter: roll.zoneAfter, opening: roll.opening, brightness: 255) else { continue }
                XCTAssertLessThanOrEqual(tail.program.utf8.count, 512, "\(to) at \(phase)")
                // At most the pass's rest, plus the blink's chord where it
                // replaces a fade shorter than itself.
                XCTAssertLessThanOrEqual(tail.lengthMs, 1585 + K.askBlinkMs, "\(to) at \(phase)")
                XCTAssertFalse(tail.program.contains("#0a00ff") && tail.program.contains("#ff374a"),
                               "\(to) at \(phase): one pass, one colour")
                XCTAssertNotNil(LedContinuation.parse(tail.program), "\(to) at \(phase)")
            }
        }
        let midRed = LedContinuation.transition(
            from: p(from), to: p(.split(alert: .done(.claude), work: .working(.both))), elapsedMs: 500,
            ledCount: 8, zoneBefore: 0, zoneAfter: 2, opening: .steady(K.doneGreen), brightness: 255)!
        XCTAssertEqual(midRed.lengthMs, 1585 - 500, "ends where the red pass ends")
        XCTAssertFalse(midRed.program.contains("#0a00ff"))
    }

    // MARK: the palette

    func testCodexHasItsOwnSlotAndTheAlertsStaySharedColours() {
        XCTAssertEqual(LedPalette.standard.rollColors(.claude), [K.claudeWorking])
        XCTAssertEqual(LedPalette.standard.rollColors(.codex), [K.codexWorking])
        XCTAssertEqual(LedPalette.standard.rollColors(.both), [K.claudeWorking, K.codexWorking])
        XCTAssertEqual(LedPalette.standard.rollColors([]), [K.claudeWorking], "never empty")
        let palette = LedPalette.standard.applying(overrides: ["codexWorking": "#123456"])
        XCTAssertTrue(p(.working(.codex)).contains(K.codexWorking))
        XCTAssertTrue(LedProgram.program(for: .working(.codex), power: nil, ledCount: 8, brightness: 255,
                                         palette: palette).contains("#123456"))
        XCTAssertEqual(LedPalette.Slot.codexWorking.preview.state, .working(.codex))
    }

    // MARK: the arbiter

    private func session(_ id: String, _ agent: AgentKind, _ state: SessionState, acked: Bool = false) -> Session {
        var s = Session(id: id, stateSince: Date(timeIntervalSince1970: 0), lastEventAt: Date(timeIntervalSince1970: 0))
        s.agent = agent; s.state = state; s.acknowledged = acked
        return s
    }

    private func decide(_ sessions: [Session], jobs: [Job] = []) -> DisplayState {
        Arbiter.decide(mode: .auto, power: nil, glanceActive: false, sessions: sessions, jobs: jobs,
                       now: Date(timeIntervalSince1970: 0))
    }

    func testTheArbiterNamesTheAgentsBehindEveryState() {
        XCTAssertEqual(decide([session("c", .codex, .working)]), .working(.codex))
        XCTAssertEqual(decide([session("a", .claude, .working), session("c", .codex, .working)]), .working(.both))
        XCTAssertEqual(decide([session("c", .codex, .waiting(.permission))]), .waiting(.codex))
        XCTAssertEqual(decide([session("c", .codex, .done)]), .done(.codex))
        XCTAssertEqual(decide([session("a", .claude, .done), session("c", .codex, .done)]), .done(.both))
        XCTAssertEqual(decide([session("a", .claude, .waiting(.question)), session("c", .codex, .working)]),
                       .split(alert: .waiting(.claude), work: .working(.codex)),
                       "Claude needs you while Codex works: the owner's example")
        XCTAssertEqual(decide([session("a", .claude, .working), session("c", .codex, .done)]),
                       .split(alert: .done(.codex), work: .working(.claude)))
        XCTAssertEqual(decide([session("a", .claude, .working), session("b", .claude, .done),
                               session("c", .codex, .working)]),
                       .split(alert: .done(.claude), work: .working(.both)))
        XCTAssertEqual(decide([session("c", .codex, .done, acked: true)]), .off)
        XCTAssertEqual(decide([session("c", .codex, .working)], jobs: [failedJob()]),
                       .split(alert: .jobFailed, work: .working(.codex)))
    }

    private func failedJob() -> Job {
        var j = Job(id: "j", stateSince: Date(timeIntervalSince1970: 0))
        j.state = .failed
        return j
    }

    // MARK: the state machine

    func testACodexSessionRecordsItsAgentAndTheInterruptGoesDark() {
        var s = SessionStore()
        var start = ev(.sessionStart, 0, source: "startup", pid: 77)
        start.agent = .codex
        s.apply(start)
        XCTAssertEqual(s.sessions["s1"]?.agent, .codex)
        s.apply(ev(.userPromptSubmit, 1))
        XCTAssertEqual(s.sessions["s1"]?.state, .working)
        XCTAssertEqual(s.sessions["s1"]?.agent, .codex, "a line without the field changes nothing")
        s.apply(ev(.interrupt, 5))
        XCTAssertEqual(s.sessions["s1"]?.state, .idle, "Codex says it was stopped: dark, no alert")
        XCTAssertNil(s.sessions["s1"]?.notifyAt)
        s.apply(ev(.userPromptSubmit, 9))
        s.apply(ev(.permissionRequest, 10, tool: "shell"))
        XCTAssertEqual(s.sessions["s1"]?.state, .waiting(.permission))
        s.apply(ev(.interrupt, 12))
        XCTAssertEqual(s.sessions["s1"]?.state, .idle, "an interrupted dialog is over too")
        s.apply(ev(.userPromptSubmit, 19))
        s.apply(ev(.preToolUse, 20, tool: "request_user_input"))
        XCTAssertEqual(s.sessions["s1"]?.state, .waiting(.question), "Codex's question tool")
        s.apply(ev(.postToolUse, 30, tool: "request_user_input"))
        s.apply(ev(.stop, 40, tail: "Done."))
        XCTAssertEqual(s.sessions["s1"]?.state, .done)
        let fired = s.tick(now: at(40 + K.notifyDebounceSeconds))
        XCTAssertEqual(fired.map(\.agent), [.codex], "the push names Codex")
        XCTAssertEqual(fired.map(\.kind), [.finished])
    }

    func codex(_ name: HookEventName, _ t: TimeInterval, tool: String? = nil, agent: String? = nil,
               bg: [String]? = nil, turn: String? = nil) -> JournalEvent {
        var e = ev(name, t, tool: tool, bg: bg, agent: agent, pid: 77, turn: turn)
        e.agent = .codex
        return e
    }

    /// The ghost of 2026-09-25: Codex reports the end of a tool it aborted
    /// 13 s after the `Interrupt`, for the same turn, and no `Stop` ever
    /// follows an aborted turn. The strip stays dark, with no alert.
    func testALatePostToolUseOfAnAbortedCodexTurnStaysDark() {
        var s = SessionStore()
        s.apply(codex(.userPromptSubmit, 0, turn: "t1"))
        s.apply(codex(.preToolUse, 1, tool: "Bash", turn: "t1"))
        s.apply(codex(.interrupt, 10, turn: "t1"))
        XCTAssertEqual(s.sessions["s1"]?.state, .idle)
        XCTAssertEqual(s.sessions["s1"]?.interruptedAt, at(10))
        s.apply(codex(.postToolUse, 23, tool: "Bash", turn: "t1"))
        XCTAssertEqual(s.sessions["s1"]?.state, .idle, "the aborted turn stays closed")
        XCTAssertEqual(s.sessions["s1"]?.lastEventAt, at(23), "the hook is alive")
        XCTAssertEqual(s.sessions["s1"]?.lastMainEventAt, at(10))
        XCTAssertNil(s.sessions["s1"]?.notifyAt)
        XCTAssertEqual(s.tick(now: at(23 + K.notifyDebounceSeconds)), [])
    }

    /// Followed from mid-turn, the session has seen no prompt: the interrupt
    /// closes the turn its last main-agent event named, and that turn's late
    /// tool events stay dark past the quarantine.
    func testAnInterruptClosesTheTurnEvenWhenNoPromptWasSeen() {
        var s = SessionStore()
        s.apply(codex(.preToolUse, 0, tool: "Bash", turn: "t1"))
        XCTAssertEqual(s.sessions["s1"]?.state, .working)
        s.apply(codex(.interrupt, 10))
        XCTAssertEqual(s.sessions["s1"]?.closedTurnIds, ["t1"])
        s.apply(codex(.postToolUse, 23, tool: "Bash", turn: "t1"))
        XCTAssertEqual(s.sessions["s1"]?.state, .idle)
        s.apply(codex(.postToolUse, 10 + K.abortQuarantineSeconds + 60, tool: "Bash", turn: "t1"))
        XCTAssertEqual(s.sessions["s1"]?.state, .idle, "the turn's id settles it, whatever the delay")

        var moved = SessionStore()
        moved.apply(codex(.userPromptSubmit, 0, turn: "t1"))
        moved.apply(codex(.preToolUse, 1, tool: "Bash", turn: "t2"))
        moved.apply(codex(.interrupt, 10))
        XCTAssertEqual(moved.sessions["s1"]?.closedTurnIds, ["t2"],
                       "a turn running under a new id with no prompt line is the one closed")
        moved.apply(codex(.postToolUse, 23, tool: "Bash", turn: "t2"))
        XCTAssertEqual(moved.sessions["s1"]?.state, .idle)
    }

    /// A prompt that names a closed turn reopens it: its events count again,
    /// and its own Stop and Interrupt end it as they end any turn.
    func testAPromptReopensAClosedTurnId() {
        var s = SessionStore()
        s.apply(codex(.userPromptSubmit, 0, turn: "t1"))
        s.apply(codex(.interrupt, 10, turn: "t1"))
        s.apply(codex(.userPromptSubmit, 12, turn: "t1"))
        XCTAssertEqual(s.sessions["s1"]?.closedTurnIds, [])
        s.apply(codex(.postToolUse, 13, tool: "Bash", turn: "t1"))
        XCTAssertEqual(s.sessions["s1"]?.state, .working, "the reopened turn's tool event counts")
        s.apply(codex(.stop, 20, turn: "t1"))
        XCTAssertEqual(s.sessions["s1"]?.state, .done, "and so does its Stop")
        s.apply(codex(.interrupt, 30, turn: "t1"))
        s.apply(codex(.userPromptSubmit, 32, turn: "t1"))
        s.apply(codex(.preToolUse, 33, tool: "Bash", turn: "t1"))
        XCTAssertEqual(s.sessions["s1"]?.state, .working)
        s.apply(codex(.interrupt, 40, turn: "t1"))
        XCTAssertEqual(s.sessions["s1"]?.state, .idle, "and its Interrupt after another reopening")
    }

    /// The quarantine is for lines that name no turn: a tool line of a turn
    /// no close named counts inside it, prompt or not.
    func testAToolLineOfAnUnclosedTurnCountsInsideTheQuarantine() {
        var s = SessionStore()
        s.apply(codex(.userPromptSubmit, 0, turn: "t1"))
        s.apply(codex(.interrupt, 10, turn: "t1"))
        s.apply(codex(.postToolUse, 20, tool: "Bash", turn: "t2"))
        XCTAssertEqual(s.sessions["s1"]?.state, .working)
    }

    /// A prompt always opens a turn, whatever id it carries: a new one, or
    /// the one the interrupt closed.
    func testANewPromptOpensANewTurnAfterAnInterrupt() {
        var s = SessionStore()
        s.apply(codex(.userPromptSubmit, 0, turn: "t1"))
        s.apply(codex(.interrupt, 10, turn: "t1"))
        s.apply(codex(.userPromptSubmit, 12, turn: "t2"))
        XCTAssertEqual(s.sessions["s1"]?.state, .working)
        XCTAssertEqual(s.sessions["s1"]?.lastMainTurnId, "t2")
        XCTAssertEqual(s.sessions["s1"]?.closedTurnIds, ["t1"])
        XCTAssertNil(s.sessions["s1"]?.interruptedAt)
        s.apply(codex(.preToolUse, 13, tool: "Bash", turn: "t2"))
        s.apply(codex(.postToolUse, 14, tool: "Bash", turn: "t1"))
        XCTAssertEqual(s.sessions["s1"]?.state, .working)
        s.apply(codex(.stop, 20, turn: "t2"))
        XCTAssertEqual(s.sessions["s1"]?.state, .done)

        var same = SessionStore()
        same.apply(codex(.userPromptSubmit, 0, turn: "t1"))
        same.apply(codex(.interrupt, 10, turn: "t1"))
        same.apply(codex(.userPromptSubmit, 12, turn: "t1"))
        same.apply(codex(.postToolUse, 13, tool: "Bash", turn: "t1"))
        XCTAssertEqual(same.sessions["s1"]?.state, .working, "the prompt reopened the turn it names")
        XCTAssertEqual(same.sessions["s1"]?.closedTurnIds, [])
    }

    /// The interrupt ends the helpers and the background shells with the
    /// turn: the session forgets them, and a helper event of that turn
    /// arriving later changes nothing.
    func testAHelperEventOfAnInterruptedTurnIsIgnored() {
        var s = SessionStore()
        s.apply(codex(.userPromptSubmit, 0, bg: ["sh-1"], turn: "t1"))
        s.apply(codex(.subagentStart, 1, agent: "a1", turn: "t1"))
        s.apply(codex(.interrupt, 10, turn: "t1"))
        XCTAssertEqual(s.sessions["s1"]?.state, .idle)
        XCTAssertEqual(s.sessions["s1"]?.liveAgents, [:])
        XCTAssertEqual(s.sessions["s1"]?.backgroundIds, [])
        s.apply(codex(.postToolUse, 20, tool: "Bash", agent: "a1", turn: "t1"))
        XCTAssertEqual(s.sessions["s1"]?.state, .idle)
        XCTAssertEqual(s.sessions["s1"]?.liveAgents, [:], "the helper is not brought back")
        XCTAssertEqual(s.sessions["s1"]?.lastEventAt, at(20))
        s.apply(codex(.permissionRequest, 21, tool: "Bash", agent: "a1", turn: "t1"))
        XCTAssertEqual(s.sessions["s1"]?.state, .idle, "nor raises a wait")
    }

    /// For a Codex that sends no turn id, a tool or permission event in the
    /// two minutes after an `Interrupt` changes nothing either; past them,
    /// or after a new prompt, the ordinary rules apply.
    func testToolEventsWithoutAnIdInTheQuarantineAfterAnInterruptChangeNothing() {
        var s = SessionStore()
        s.apply(codex(.userPromptSubmit, 0))
        s.apply(codex(.preToolUse, 1, tool: "Bash"))
        s.apply(codex(.interrupt, 10))
        s.apply(codex(.permissionRequest, 30, tool: "Bash"))
        XCTAssertEqual(s.sessions["s1"]?.state, .idle, "no wait raised in the quarantine")
        s.apply(codex(.postToolUse, 10 + 60, tool: "Bash"))
        XCTAssertEqual(s.sessions["s1"]?.state, .idle)
        XCTAssertEqual(s.sessions["s1"]?.lastEventAt, at(70))
        s.apply(codex(.postToolUse, 10 + K.abortQuarantineSeconds + 1, tool: "Bash"))
        XCTAssertEqual(s.sessions["s1"]?.state, .working, "the quarantine is over")

        var prompt = SessionStore()
        prompt.apply(codex(.userPromptSubmit, 0))
        prompt.apply(codex(.interrupt, 10))
        prompt.apply(codex(.userPromptSubmit, 12))
        prompt.apply(codex(.preToolUse, 13, tool: "Bash"))
        XCTAssertEqual(prompt.sessions["s1"]?.state, .working, "a prompt ends the quarantine")
        XCTAssertEqual(K.abortQuarantineSeconds, 120)
    }

    /// Claude's rescues read Claude Code's registry and transcript, which a
    /// Codex session has no counterpart of: it is never a candidate, and no
    /// recheck is scheduled for it.
    func testTheRegistryRescuesAreClaudesAlone() {
        var s = SessionStore()
        var prompt = ev(.userPromptSubmit, 0, pid: 77)
        prompt.agent = .codex
        s.apply(prompt)
        s.apply(ev(.preToolUse, 1, tool: "shell"))
        XCTAssertTrue(s.abandonCandidates(at: at(100)).isEmpty)
        XCTAssertEqual(s.nextDeadline(after: at(100)), at(K.staleSeconds + 1),
                       "nothing but the staleness backstop")
        s.apply(ev(.permissionRequest, 200, tool: "shell"))
        XCTAssertTrue(s.openWaitCandidates().isEmpty)

        var claude = SessionStore()
        claude.apply(ev(.userPromptSubmit, 0, pid: 78))
        claude.apply(ev(.preToolUse, 1, tool: "Bash"))
        XCTAssertEqual(claude.abandonCandidates(at: at(100)).map(\.pid), [78])
    }

    func testThePruneAsksAboutTheSessionsOwnAgent() {
        var s = SessionStore()
        var codex = ev(.userPromptSubmit, 0, sid: "c", pid: 77)
        codex.agent = .codex
        s.apply(codex)
        s.apply(ev(.userPromptSubmit, 0, sid: "a", pid: 78))
        var asked: [(AgentKind, Int32)] = []
        s.pruneDead { agent, pid in asked.append((agent, pid)); return agent == .codex }
        XCTAssertEqual(asked.map(\.0).sorted { $0.rawValue < $1.rawValue }, [.claude, .codex])
        XCTAssertEqual(Array(s.sessions.keys), ["c"])
    }

    // MARK: the journal

    func testTheJournalLineCarriesTheAgentAndOldLinesReadAsClaude() throws {
        var e = JournalEvent(loggedAt: Date(timeIntervalSince1970: 1_787_652_000), event: .stop)
        e.sessionId = "s1"; e.agent = .codex; e.agentPid = 77
        let text = String(decoding: try JournalCodec.encodeLine(e), as: UTF8.self)
        XCTAssertTrue(text.contains(#""agent":"codex""#), text)
        XCTAssertTrue(text.contains(#""claude_pid":77"#), "the pid keeps its key: renaming it is a migration")
        XCTAssertEqual(JournalCodec.decodeLine(Data(text.utf8)), e)
        let old = #"{"logged_at":"2026-08-21T10:00:00Z","event":"Stop","session_id":"s1","claude_pid":42}"#
        let decoded = try XCTUnwrap(JournalCodec.decodeLine(Data(old.utf8)))
        XCTAssertNil(decoded.agent)
        XCTAssertEqual(decoded.agentPid, 42)
        var store = SessionStore()
        store.apply(decoded)
        XCTAssertEqual(store.sessions["s1"]?.agent, .claude)
        XCTAssertEqual(JournalCodec.decodeLine(Data(#"{"logged_at":"2026-08-21T10:00:00Z","event":"Interrupt","session_id":"s1"}"#.utf8))?.event,
                       .interrupt)
    }

    func testTheHookTakesCodexsEventNamesInEitherSpelling() {
        let t0 = Date(timeIntervalSince1970: 1_787_652_000)
        func event(_ name: String) -> HookEventName {
            let data = try! JSONSerialization.data(withJSONObject: ["hook_event_name": name, "session_id": "s1"])
            return Trim.journalEvent(fromHookPayload: data, loggedAt: t0).event
        }
        XCTAssertEqual(event("Interrupt"), .interrupt)
        XCTAssertEqual(event("interrupt"), .interrupt)
        XCTAssertEqual(event("pre_tool_use"), .preToolUse)
        XCTAssertEqual(event("user_prompt_submit"), .userPromptSubmit)
        XCTAssertEqual(event("NoSuchEvent"), .parseError)
        XCTAssertEqual(event("parse_error"), .parseError, "the app's own name is not an event")
    }

    // MARK: the hook files

    func testCodexHasTwelveEventsAndACommandThatNamesIt() {
        XCTAssertEqual(HookConfig.codexEvents, [
            "SessionStart", "SessionEnd", "UserPromptSubmit",
            "PreToolUse", "PostToolUse", "PermissionRequest",
            "Stop", "SubagentStart", "SubagentStop",
            "PreCompact", "PostCompact", "Interrupt",
        ], "Codex's event names; a typo is silent at runtime")
        XCTAssertEqual(HookConfig.events(for: .codex), HookConfig.codexEvents)
        XCTAssertEqual(HookConfig.events(for: .claude), HookConfig.events)
        let cli = "/Applications/MySidepulse.app/Contents/MacOS/mysidepulse"
        XCTAssertEqual(HookConfig.command(cliPath: cli, agent: .claude), "\(cli) hook")
        XCTAssertEqual(HookConfig.command(cliPath: cli, agent: .codex), "\(cli) hook --agent codex")
        for agent in AgentKind.allCases {
            let command = HookConfig.command(cliPath: cli, agent: agent)
            XCTAssertTrue(command.contains(HookConfig.ourMarker), "\(agent): unrecognisable once written")
            XCTAssertEqual(HookConfig.binary(ofCommand: command), cli)
        }
        let root = HookConfig.install(into: [:], command: HookConfig.command(cliPath: cli, agent: .codex),
                                      events: HookConfig.codexEvents)
        XCTAssertEqual(HookConfig.installedCommand(in: root, event: "Interrupt"), "\(cli) hook --agent codex")
        XCTAssertNil(HookConfig.installedCommand(in: root, event: "Notification"), "not a Codex event")
        // Codex's own import copies Claude's bare entries into hooks.json;
        // a set-up replaces them with the entry that names Codex.
        let migrated = HookConfig.install(into: [:], command: "\(cli) hook", events: ["Stop"])
        let fixed = HookConfig.install(into: migrated, command: "\(cli) hook --agent codex",
                                       events: HookConfig.codexEvents)
        let stop = (fixed["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        XCTAssertEqual(stop?.count, 1, "one entry of ours, never the migrated one beside it")
        XCTAssertNil(HookConfig.uninstall(from: fixed)["hooks"].flatMap { ($0 as? [String: Any])?["Stop"] })
    }

    // MARK: the sentences

    func testTheSentencesNameTheAgents() {
        withLanguage(.en) {
            XCTAssertEqual(StatusCopy.line(for: .working(.codex)).text, "Codex is working")
            XCTAssertEqual(StatusCopy.line(for: .working(.both)).text, "Claude and Codex are working")
            XCTAssertEqual(StatusCopy.line(for: .waiting(.codex)).text,
                           "Codex needs you: a question, a permission or a plan")
            XCTAssertEqual(StatusCopy.line(for: .waiting(.both)).text,
                           "Claude and Codex need you: a question, a permission or a plan")
            XCTAssertEqual(StatusCopy.line(for: .done(.codex)).text,
                           "Codex has finished. Clears when you look at the terminal")
            XCTAssertEqual(StatusCopy.line(for: .done(.both)).text,
                           "Claude and Codex have finished. Clears when you look at the terminal")
            XCTAssertEqual(StatusCopy.line(for: .split(alert: .waiting(.claude), work: .working(.codex))).text,
                           "Claude needs you, and other work is still running")
            XCTAssertEqual(StatusCopy.line(for: .split(alert: .done(.codex), work: .working(.claude))).text,
                           "Codex has finished, and other work is still running")
        }
        withLanguage(.fr) {
            XCTAssertEqual(StatusCopy.line(for: .working(.codex)).text, "Codex travaille")
            XCTAssertEqual(StatusCopy.line(for: .working(.both)).text, "Claude et Codex travaillent")
            XCTAssertEqual(StatusCopy.line(for: .waiting(.both)).text,
                           "Claude et Codex ont besoin de vous : une question, une permission ou un plan")
            XCTAssertEqual(StatusCopy.line(for: .done(.codex)).text,
                           "Codex a terminé. S'efface quand vous regardez le terminal")
            XCTAssertEqual(StatusCopy.line(for: .done(.both)).text,
                           "Claude et Codex ont terminé. S'efface quand vous regardez le terminal")
        }
        XCTAssertEqual(StatusCopy.line(for: .working(.both)).tone, .info)
        XCTAssertEqual(StatusCopy.line(for: .waiting(.codex)).tone, .warning)
    }

    func testAWarningThatNamesTheCodexButtonNamesItInTheSameLanguage() {
        for language in Language.allCases {
            withLanguage(language) {
                let system = Loc.settings.system
                XCTAssertTrue(system.withoutCodexHooksWarning.contains(system.setUpHooksButton), "\(language)")
                XCTAssertEqual(Loc.settings.colors.label(.codexWorking).isEmpty, false)
            }
        }
    }

    // MARK: the Health page

    private func healthy() -> HealthFacts {
        var facts = HealthFacts()
        facts.notificationsGranted = true
        facts.claudeHooks = .setUp
        facts.hookBinary = .init(ok: true, detail: "binary exists")
        facts.journal = .init(ok: true, detail: "append works")
        facts.terminalHookSetUp = true
        facts.devices = []
        facts.launchAgent = .enabled
        facts.control = .init(ok: true, detail: "running")
        return facts
    }

    private func codexRow(_ facts: HealthFacts) -> HealthRow? {
        HealthReport.checks(for: facts).first { $0.id == "codex hooks" }
    }

    func testTheCodexLineIsThereOnlyWhileCodexIsOrItsHooksAre() {
        var facts = healthy()
        XCTAssertNil(codexRow(facts), "nothing read yet")
        facts.codexHooks = .missing
        facts.codexInstalled = false
        XCTAssertNil(codexRow(facts), "a Mac without Codex has nothing to set up")
        facts.codexInstalled = true
        XCTAssertEqual(codexRow(facts)?.level, .warning, "optional: orange, never red")
        XCTAssertEqual(codexRow(facts)?.fix, Loc.settings.system.withoutCodexHooksWarning)
        facts.codexInstalled = false
        facts.codexHooks = .setUp
        XCTAssertEqual(codexRow(facts)?.level, .good, "set up, so Remove stays reachable")
        facts.codexHooksCheck = .init(ok: false, detail: "binary missing")
        XCTAssertEqual(codexRow(facts)?.level, .warning)
        XCTAssertEqual(codexRow(facts)?.fix, Loc.settings.health.codexHookCommandFix)
        facts.codexHooksCheck = nil
        facts.codexHooks = .unreadable
        XCTAssertNil(codexRow(facts), "unreadable is not set up, and Codex is not there")
        facts.codexInstalled = true
        XCTAssertEqual(codexRow(facts)?.level, .warning)
        XCTAssertEqual(HealthReport.checks(for: facts).map(\.id).prefix(3),
                       ["claude code hooks", "codex hooks", "terminal hook"], "right after Claude's")
    }

    func testTheSessionsReadingCountsBothAgentsAndNamesThem() {
        withLanguage(.en) {
            var facts = healthy()
            facts.claudeHooks = .missing
            facts.codexHooks = .setUp
            facts.codexInstalled = true
            facts.sessions = [.init(id: "0123456789", agent: .codex, phase: .working, ageSeconds: 12, cwd: nil),
                              .init(id: "abcdefghij", agent: .claude, phase: .done, ageSeconds: 60, cwd: nil)]
            let reading = HealthReport.readings(for: facts).first { $0.id == "sessions" }
            XCTAssertEqual(reading?.label, "Agent sessions")
            XCTAssertEqual(reading?.value, "2")
            XCTAssertEqual(reading?.detail, "01234567 Codex: Working, 12 s ago\nabcdefgh Claude: Finished, 1 min ago")
            XCTAssertLessThanOrEqual(HealthReport.checks(for: facts).count, HealthLimits.checks)
        }
    }

    // MARK: the push

    func testACodexPushIsTitledCodexAndLandsOnCodex() {
        XCTAssertEqual(AlertCopy.title(for: .codex), "Codex")
        XCTAssertEqual(AgentKind.codex.homeLink, "https://chatgpt.com/codex")
        XCTAssertEqual(AgentKind.claude.homeLink, "https://claude.ai/code")
        withLanguage(.fr) {
            XCTAssertEqual(AlertCopy.title(for: .codex), "Codex", "a product name is not translated")
        }
        XCTAssertEqual(Agents.both.kinds, [.claude, .codex])
        XCTAssertEqual(Agents(.codex).kinds, [.codex])
    }
}

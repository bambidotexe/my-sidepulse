import XCTest
@testable import MySidepulseCore

final class TransitionTests: XCTestCase {
    func p(_ s: DisplayState, leds: Int = 8, brightness: Int = 255) -> String {
        LedProgram.program(for: s, power: nil, ledCount: leds, brightness: brightness)
    }

    func carried(_ from: DisplayState, _ to: DisplayState, at phase: Int, leds: Int = 8,
                 brightness: Int = 255) -> LedContinuation.Tail? {
        guard let roll = LedProgram.rollHandover(from: from, to: to, ledCount: leds) else { return nil }
        return LedContinuation.transition(from: p(from, leds: leds), to: p(to, leds: leds),
                                          elapsedMs: phase, ledCount: leds, zoneBefore: roll.zoneBefore,
                                          zoneAfter: roll.zoneAfter, opening: roll.opening,
                                          brightness: brightness)
    }

    func testWhichChangesCarryTheRoll() {
        XCTAssertEqual(LedProgram.rollHandover(from: .working, to: .split(alert: .done, work: .working), ledCount: 8),
                       .init(zoneBefore: 0, zoneAfter: 2, opening: .steady(K.doneGreen)))
        XCTAssertEqual(LedProgram.rollHandover(from: .split(alert: .waiting, work: .working), to: .working, ledCount: 8),
                       .init(zoneBefore: 3, zoneAfter: 0, opening: nil))
        XCTAssertEqual(LedProgram.rollHandover(from: .split(alert: .done, work: .jobRunning),
                                               to: .split(alert: .jobFailed, work: .jobRunning), ledCount: 8),
                       .init(zoneBefore: 2, zoneAfter: 3, opening: .blink(K.askAmber)))
        XCTAssertNil(LedProgram.rollHandover(from: .working, to: .done, ledCount: 8), "nothing rolls on")
        XCTAssertNil(LedProgram.rollHandover(from: .working, to: .split(alert: .done, work: .jobRunning), ledCount: 8),
                     "a different roll is a new animation")
        XCTAssertNil(LedProgram.rollHandover(from: .working, to: .working, ledCount: 8))
    }

    /// A finish lands while the roll is mid-wave: the zone goes green over
    /// the bridge, on which LEDs 2 and 3, below half their rise, go to
    /// black to start over; the roll's LEDs 2…7 carry on, LEDs 0 and 1 are
    /// the zone's now.
    func testFinishJoinsTheRollAsASteadyZone() {
        let tail = carried(.working, .split(alert: .done, work: .working), at: 500)
        XCTAssertEqual(tail?.program, """
        2:#000000 60ms; 3:#000000 60ms; 0:#00ff37 60ms; 1:#00ff37 60ms
        2:#ff374a 550ms pulse 0ms; 3:#ff374a 645ms pulse 0ms; 4:#ff374a 740ms pulse 0ms; 5:#ff374a 760ms pulse 75ms; 6:#ff374a 760ms pulse 170ms; 7:#ff374a 760ms pulse 265ms
        """)
        XCTAssertEqual(tail?.lengthMs, 1085)
    }

    /// A question lands mid-wave while LEDs 0…2 are lit: the zone fades to
    /// black over the split's own baseline, then blink one on a line of its
    /// own, then blink two behind the gap on the roll's rest. The roll's next
    /// 160 ms and 200 ms are chords: LED 3, 55 ms into its rise at the cut, is
    /// at 60 % of red after the baseline and 98 % after the blink; LED 4
    /// starts 40 ms in and reaches 23 %, then, past half its rise at the
    /// blink's end, its peak; so does LED 5. LEDs 6 and 7, which would start
    /// during the blink, start over from black at its end instead. The three
    /// lines end where the loop would.
    func testQuestionJoinsTheRollAsABlinkingZone() {
        let tail = carried(.working, .split(alert: .waiting, work: .working), at: 500)
        XCTAssertEqual(tail?.program, """
        3:#9a212d 160ms; 4:#3a0c11 120ms 40ms; 5:#030101 25ms 135ms; 0:#000000 160ms; 1:#000000 160ms; 2:#000000 160ms
        3:#fa3648 0.2s; 4:#ff374a 0.2s; 5:#ff374a 0.2s; 0:#ff7000 0.2s pulse 0ms; 1:#ff7000 0.2s pulse 0ms; 2:#ff7000 0.2s pulse 0ms
        3:#000000 345ms; 4:#000000 440ms; 5:#000000 535ms; 6:#ff374a 630ms pulse 0ms; 7:#ff374a 725ms pulse 0ms; 0:#ff7000 0.2s pulse 70ms; 1:#ff7000 0.2s pulse 70ms; 2:#ff7000 0.2s pulse 70ms
        """)
        XCTAssertEqual(tail?.lengthMs, 160 + 200 + 725)
    }

    /// The question is acknowledged: the zone goes dark over the bridge, the
    /// roll's LEDs carry on, and the loop restarts at the split's own end.
    func testAcknowledgedZoneLeavesTheRollRolling() {
        let tail = carried(.split(alert: .waiting, work: .working), .working, at: 700)
        XCTAssertEqual(tail?.program, """
        3:#ff374a 60ms; 4:#ff374a 60ms; 5:#000000 60ms; 6:#000000 60ms; 0:#000000 60ms; 1:#000000 60ms; 2:#000000 60ms
        3:#000000 360ms; 4:#000000 455ms; 5:#ff374a 550ms pulse 0ms; 6:#ff374a 645ms pulse 0ms; 7:#ff374a 740ms pulse 0ms
        """)
        XCTAssertEqual(tail?.lengthMs, 800)
    }

    func testAtTheRollsDarkEndNothingIsCarried() {
        XCTAssertNil(carried(.working, .split(alert: .waiting, work: .working), at: 1500),
                     "LED 7's fall is all that is left: the split written outright loses nothing")
    }

    /// Every carried change, both LED counts, every phase in 5 ms steps: the
    /// tail is inside the device's limits, reads back, and plays for at least
    /// what was left of the roll's line under way.
    func testEveryTransitionIsWellFormed() {
        let splits: [DisplayState] = [.split(alert: .waiting, work: .working), .split(alert: .done, work: .working)]
        var pairs: [(DisplayState, DisplayState)] = []
        for split in splits {
            pairs.append((.working, split))
            pairs.append((split, .working))
        }
        pairs.append((splits[0], splits[1]))
        pairs.append((splits[1], splits[0]))
        // The roll two agents share, Codex's alone, and the one-pass roll of
        // three and of four agents, under the same zones.
        for work in [Agents.claudeAndCodex, .codex, .claudeCodexCopilot, .all] {
            let shared: [DisplayState] = [.split(alert: .waiting(.codex), work: .working(work)),
                                          .split(alert: .done(.claude), work: .working(work))]
            for split in shared {
                pairs.append((.working(work), split))
                pairs.append((split, .working(work)))
            }
            pairs.append((shared[0], shared[1]))
            pairs.append((shared[1], shared[0]))
        }
        for (from, to) in pairs {
            for leds in [2, 8] {
                for brightness in [255, 254] {
                    let loopMs = LedContinuation.loopMs(of: p(from, leds: leds))!
                    for phase in stride(from: 0, to: loopMs, by: 5) {
                        let label = "\(from) → \(to) on \(leds) LEDs at \(phase) ms"
                        guard let tail = carried(from, to, at: phase, leds: leds, brightness: brightness) else { continue }
                        XCTAssertLessThanOrEqual(tail.program.utf8.count, 512, label)
                        XCTAssertLessThanOrEqual(tail.program.split(separator: "\n").count, 20, label)
                        XCTAssertFalse(tail.program.contains("repeat"), label)
                        guard let parsed = LedContinuation.parse(tail.program) else {
                            XCTFail("\(label): the tail does not read back"); continue
                        }
                        XCTAssertEqual(parsed.loopMs, tail.lengthMs, label)
                        for segment in parsed.lines.flatMap(\.segments) {
                            XCTAssertGreaterThan(segment.durationMs ?? 1, 0, "\(label): a zero-length segment")
                        }
                        XCTAssertGreaterThan(tail.lengthMs, 0, label)
                        XCTAssertFalse(tail.program.contains("brightness"), label)
                        XCTAssertEqual(tail.program.utf8.count, tail.unscaled.utf8.count, label)
                    }
                }
            }
        }
    }

    // MARK: the roll changing agents

    /// The colours a program paints, `#000000` aside.
    private func colours(_ program: String) -> Set<String> {
        var found: Set<String> = []
        var rest = Substring(program)
        while let hash = rest.firstIndex(of: "#") {
            let end = rest.index(hash, offsetBy: 7, limitedBy: rest.endIndex) ?? rest.endIndex
            found.insert(String(rest[hash..<end]))
            rest = rest[end...]
        }
        found.remove("#000000")
        return found
    }

    /// The full-strip roll changing its agents across the one-pass and the
    /// two-pass shapes: one agent to three, three to four, four to two,
    /// three to one. Each is a recolour, never a zone change; at every phase
    /// the tail cut from the roll that plays is inside the device's limits,
    /// reads back, paints none of the colours only the new roll has (its
    /// bridge holds levels of the old roll's own), and ends where its loop
    /// or its pass ends, every LED dark, which is where the new roll is
    /// written.
    func testTheRollRecolouredAcrossAgentCounts() {
        let pairs: [(Agents, Agents)] = [(.claude, .claudeCodexCopilot), (.claudeCodexCopilot, .all),
                                         (.all, .claudeAndCodex), (.claudeCodexCopilot, .claude),
                                         (.claudeAndCodex, .all), (.all, .opencode)]
        for (from, to) in pairs {
            XCTAssertTrue(LedProgram.rollRecolour(from: .working(from), to: .working(to)), "\(from) → \(to)")
            XCTAssertNil(LedProgram.rollHandover(from: .working(from), to: .working(to), ledCount: 8),
                         "\(from) → \(to): a recolour is not a zone change")
            for leds in [2, 8] {
                let loop = p(.working(from), leds: leds)
                let loopMs = LedContinuation.loopMs(of: loop)!
                XCTAssertLessThanOrEqual(p(.working(to), leds: leds).utf8.count, 512)
                let arriving = colours(p(.working(to), leds: leds)).subtracting(colours(loop))
                for brightness in [255, 128] {
                    for phase in stride(from: 0, to: loopMs, by: 5) {
                        let label = "\(from) → \(to) on \(leds) LEDs at \(phase) ms, brightness \(brightness)"
                        guard let tail = LedContinuation.tail(of: loop, elapsedMs: phase, brightness: brightness)
                        else { XCTFail("\(label): no tail"); continue }
                        XCTAssertLessThanOrEqual(tail.program.utf8.count, 512, label)
                        XCTAssertLessThanOrEqual(tail.program.split(separator: "\n").count, 20, label)
                        XCTAssertFalse(tail.program.contains("repeat"), label)
                        XCTAssertTrue(colours(tail.unscaled).isDisjoint(with: arriving),
                                      "\(label): the new colours wait for the new loop: \(tail.unscaled)")
                        let passEnd = ContinuationTests.passEnd(of: loop, at: phase)
                        XCTAssertTrue(tail.lengthMs == loopMs - phase || tail.lengthMs == passEnd - phase,
                                      "\(label): ends at neither the loop's end nor the pass's")
                        guard let parsed = LedContinuation.parse(tail.program) else {
                            XCTFail("\(label): the tail does not read back"); continue
                        }
                        XCTAssertEqual(Double(parsed.loopMs), Double(tail.lengthMs),
                                       accuracy: Double(LedContinuation.frameMs), label)
                    }
                }
            }
        }
    }

    /// A finish landing over the four-agent roll mid-wave: the zone goes
    /// green over the bridge exactly as over Claude's roll, and the roll's
    /// LEDs 2…7 carry on in their own agents' colours.
    func testAFinishJoinsTheFourAgentRollAsASteadyZone() {
        let tail = carried(.working(.all), .split(alert: .done(.codex), work: .working(.all)), at: 500)
        XCTAssertEqual(tail?.program, """
        2:#000000 60ms; 3:#000000 60ms; 0:#00ff37 60ms; 1:#00ff37 60ms
        2:#0e5cff 550ms pulse 0ms; 3:#ff0043 645ms pulse 0ms; 4:#ff374a 740ms pulse 0ms; 5:#0a00ff 760ms pulse 75ms; 6:#0e5cff 760ms pulse 170ms; 7:#ff0043 760ms pulse 265ms
        """)
        XCTAssertEqual(tail?.lengthMs, 1085)
    }

    /// A zone landing over the four-agent roll, at every phase. On eight
    /// LEDs, where that roll is one pass by LED, it opens exactly as over
    /// Claude's own roll: the same lines for the same length. On the Dot,
    /// where it is four passes, it opens like the two-agent roll: the pass
    /// under way carries on in its one colour and the split takes over at
    /// its end.
    func testAZoneOpensOverTheFourAgentRoll() {
        for alert: SplitAlert in [.waiting(.opencode), .done(.copilot)] {
            let loopMs = LedContinuation.loopMs(of: p(.working(.all)))!
            XCTAssertEqual(loopMs, LedContinuation.loopMs(of: p(.working)))
            var carriedAtAll = false
            for phase in stride(from: 0, to: loopMs, by: 5) {
                let label = "\(alert) on 8 LEDs at \(phase) ms"
                let four = carried(.working(.all), .split(alert: alert, work: .working(.all)), at: phase)
                let one = carried(.working, .split(alert: alert, work: .working), at: phase)
                XCTAssertEqual(four == nil, one == nil, label)
                guard let four, let one else { continue }
                carriedAtAll = true
                XCTAssertLessThanOrEqual(four.program.utf8.count, 512, label)
                XCTAssertLessThanOrEqual(four.program.split(separator: "\n").count, 20, label)
                XCTAssertEqual(four.lengthMs, one.lengthMs, label)
                XCTAssertEqual(four.program.split(separator: "\n").count, one.program.split(separator: "\n").count,
                               label)
                XCTAssertEqual(LedContinuation.parse(four.program)?.loopMs, four.lengthMs, label)
            }
            XCTAssertTrue(carriedAtAll, "\(alert) on 8 LEDs: the roll carries on under the zone")

            let dotLoop = p(.working(.all), leds: 2)
            let passMs = LedContinuation.loopMs(of: p(.working, leds: 2))!
            XCTAssertEqual(LedContinuation.loopMs(of: dotLoop), 4 * passMs, "four passes on the Dot")
            let agentColours = [K.claudeWorking, K.codexWorking, K.copilotWorking, K.opencodeWorking]
            carriedAtAll = false
            for phase in stride(from: 0, to: 4 * passMs, by: 5) {
                let label = "\(alert) on the Dot at \(phase) ms"
                guard let tail = carried(.working(.all), .split(alert: alert, work: .working(.all)), at: phase, leds: 2)
                else { continue }
                carriedAtAll = true
                XCTAssertLessThanOrEqual(tail.program.utf8.count, 512, label)
                XCTAssertLessThanOrEqual(tail.lengthMs, passMs + K.askBlinkMs, "\(label): at most the pass's rest")
                XCTAssertLessThanOrEqual(agentColours.filter(tail.program.contains).count, 1,
                                         "\(label): one pass, one colour")
                XCTAssertEqual(LedContinuation.parse(tail.program)?.loopMs, tail.lengthMs, label)
            }
            XCTAssertTrue(carriedAtAll, "\(alert) on the Dot: the roll carries on under the zone")
        }
    }
}

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
}

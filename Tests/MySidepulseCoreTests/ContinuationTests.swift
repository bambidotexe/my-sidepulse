import XCTest
@testable import MySidepulseCore

final class ContinuationTests: XCTestCase {
    static let looping: [DisplayState] = [.working, .waiting, .done, .jobRunning, .batteryCritical,
                                          .working(.codex), .working(.both),
                                          .split(alert: .waiting, work: .working),
                                          .split(alert: .done, work: .working),
                                          .split(alert: .jobFailed, work: .jobRunning),
                                          .split(alert: .jobSucceeded, work: .jobRunning),
                                          .split(alert: .waiting(.codex), work: .working(.both)),
                                          .split(alert: .done(.claude), work: .working(.both))]
        + LedEffects.names.map { .effect($0) }

    /// Where the pass under way at `phase` ends: the loop's end, or on a loop
    /// of several passes the start of the next whole-strip dark line.
    static func passEnd(of loop: String, at phase: Int) -> Int {
        let parsed = LedContinuation.parse(loop)!
        var start = 0
        var ends: [Int] = []
        for (index, line) in parsed.lines.enumerated() {
            let isPassStart = line.segments.count == 1 && line.segments[0].led == nil && line.segments[0].color == "off"
            if index > 0, isPassStart { ends.append(start) }
            start += line.lengthMs
        }
        ends.append(parsed.loopMs)
        return ends.first { $0 > phase } ?? parsed.loopMs
    }

    func p(_ s: DisplayState, leds: Int = 8, brightness: Int = 255) -> String {
        LedProgram.program(for: s, power: PowerState(percent: 42), ledCount: leds, brightness: brightness)
    }

    /// The reader and the writer agree on every program the host emits, byte
    /// for byte: what the tail is cut from is exactly what the strip got.
    func testEveryHostProgramReadsBackAsItself() {
        let states = Self.looping + [.off, .batteryGlance, .manualColor("#123456")]
        for state in states {
            for leds in [2, 8] {
                for brightness in [255, 200] {
                    let program = p(state, leds: leds, brightness: brightness)
                    guard let parsed = LedContinuation.parse(program) else {
                        XCTFail("\(state) on \(leds) LEDs does not parse"); continue
                    }
                    XCTAssertEqual(LedContinuation.text(parsed), program, "\(state) on \(leds) LEDs")
                }
            }
        }
        XCTAssertEqual(LedContinuation.text(LedContinuation.parse(
            LedProgram.brightnessPreview(ledCount: 8, brightness: 120))!),
            LedProgram.brightnessPreview(ledCount: 8, brightness: 120))
    }

    func testLoopLengthsCountOneFramePerInstantLine() {
        XCTAssertEqual(LedContinuation.loopMs(of: p(.working)), 160 + 665 + 760)
        XCTAssertEqual(LedContinuation.loopMs(of: p(.working, leds: 2)), 160 + 260 + 760)
        XCTAssertEqual(LedContinuation.loopMs(of: p(.waiting)), 17 + 200 + 70 + 200 + 1030)
        XCTAssertEqual(LedContinuation.loopMs(of: p(.done)), 17 + 4500)
        XCTAssertEqual(LedContinuation.loopMs(of: p(.split(alert: .waiting, work: .working))), 1500)
        XCTAssertEqual(LedContinuation.loopMs(of: p(.split(alert: .done, work: .working))), 160 + 475 + 760)
        XCTAssertEqual(LedContinuation.loopMs(of: p(.effect("rainbow"))), 800)
        XCTAssertEqual(LedContinuation.loopMs(of: p(.effect("sparkle"))), 160 + 2520 + 360)
        XCTAssertNil(LedContinuation.loopMs(of: "off"), "nothing loops, nothing to carry on")
        XCTAssertNil(LedContinuation.loopMs(of: p(.batteryGlance)))
        XCTAssertNil(LedContinuation.loopMs(of: p(.manualColor("#123456"))))
    }

    // MARK: exact tails

    /// The roll 500 ms in, at a new brightness. First the bridge, 60 ms:
    /// LEDs 0 and 1, past half their rise, go to their peak; LEDs 2 and 3,
    /// below it, go to black; nothing else is lit. Then, from the bridge's
    /// end: LEDs 0 and 1 fall from the peak over what is left, LEDs 2 and 3
    /// play their whole pulse from black, LED 4, which started during the
    /// bridge, does the same a little late, and the rest start on time. The
    /// total keeps the loop's remainder, and nothing is left lit.
    func testWorkingTailMidWave() {
        let tail = LedContinuation.tail(of: p(.working), elapsedMs: 500, brightness: 128)
        XCTAssertEqual(tail?.program, """
        0:#801c25 60ms; 1:#801c25 60ms; 2:#000000 60ms; 3:#000000 60ms
        0:#000000 360ms; 1:#000000 455ms; 2:#801c25 550ms pulse 0ms; 3:#801c25 645ms pulse 0ms; 4:#801c25 740ms pulse 0ms; 5:#801c25 760ms pulse 75ms; 6:#801c25 760ms pulse 170ms; 7:#801c25 760ms pulse 265ms
        """)
        XCTAssertEqual(tail?.unscaled, """
        0:#ff374a 60ms; 1:#ff374a 60ms; 2:#000000 60ms; 3:#000000 60ms
        0:#000000 360ms; 1:#000000 455ms; 2:#ff374a 550ms pulse 0ms; 3:#ff374a 645ms pulse 0ms; 4:#ff374a 740ms pulse 0ms; 5:#ff374a 760ms pulse 75ms; 6:#ff374a 760ms pulse 170ms; 7:#ff374a 760ms pulse 265ms
        """)
        XCTAssertEqual(tail?.lengthMs, 1585 - 500)
    }

    /// The same roll resumed from a dark strip: every LED under way plays its
    /// pulse from black over what is left of it, fading in; the rest start on
    /// time. The strip goes off and comes back where the roll would have been.
    func testWorkingTailFromDarkFadesTheLitLedsIn() {
        let tail = LedContinuation.tail(of: p(.working), elapsedMs: 500, brightness: 128, fromDark: true)
        XCTAssertEqual(tail?.program, """
        0:#801c25 420ms pulse 0ms; 1:#801c25 515ms pulse 0ms; 2:#801c25 610ms pulse 0ms; 3:#801c25 705ms pulse 0ms; 4:#801c25 760ms pulse 40ms; 5:#801c25 760ms pulse 135ms; 6:#801c25 760ms pulse 230ms; 7:#801c25 760ms pulse 325ms
        """)
        XCTAssertEqual(tail?.lengthMs, 1085)
    }

    /// A breath resumed from dark on its way down is a whole breath squeezed
    /// into what is left; on its way up, the rise from black is already the
    /// fade-in.
    func testBreathFromDark() {
        XCTAssertEqual(LedContinuation.tail(of: p(.done), elapsedMs: 3000, brightness: 255, fromDark: true)?.program,
                       "#00ff37 1517ms pulse")
        XCTAssertEqual(LedContinuation.tail(of: p(.done), elapsedMs: 1000, brightness: 255, fromDark: true)?.program,
                       "#00ff37 1267ms cosine\noff 2250ms cosine")
    }

    /// The roll in its opening fade: the fade's rest, then the pulse line whole.
    func testWorkingTailInTheFade() {
        let tail = LedContinuation.tail(of: p(.working), elapsedMs: 100, brightness: 255)
        XCTAssertEqual(tail?.program, "off 60ms cosine\n"
            + p(.working).split(separator: "\n")[1])
        XCTAssertEqual(tail?.lengthMs, 1485)
    }

    /// A breath cut on its way up: the strip at 40 % of green for one frame,
    /// then the rise's rest as a cosine, then the fall.
    func testDoneTailRising() {
        let tail = LedContinuation.tail(of: p(.done), elapsedMs: 1000, brightness: 255)
        XCTAssertEqual(tail?.program, "#006616\n#00ff37 1250ms cosine\noff 2250ms cosine")
        XCTAssertEqual(tail?.lengthMs, 4517 - 1000)
    }

    func testDoneTailFalling() {
        let tail = LedContinuation.tail(of: p(.done), elapsedMs: 3000, brightness: 60)
        XCTAssertEqual(tail?.program, "#002e0a\noff 1.5s cosine")
        XCTAssertEqual(tail?.unscaled, "#00c22a\noff 1.5s cosine")
        XCTAssertEqual(tail?.lengthMs, 1517)
    }

    func testWaitingTailInTheSecondBlink() {
        let tail = LedContinuation.tail(of: p(.waiting), elapsedMs: 300, brightness: 255)
        XCTAssertEqual(tail?.program, "#0a0500\n#ff7000 70ms cosine\noff 0.1s cosine\noff 1030ms")
        XCTAssertEqual(tail?.lengthMs, 1517 - 300)
    }

    /// Halfway through a frame, the bridge takes every LED to where its
    /// crossfade is 60 ms on, 98 % of the way between two hues since a plain
    /// crossfade eases like CSS `ease`; then the frame's last 40 ms.
    func testRainbowTailCrossfadesTheRestOfTheFrame() {
        let tail = LedContinuation.tail(of: p(.effect("rainbow")), elapsedMs: 300, brightness: 255)
        let lines = p(.effect("rainbow")).split(separator: "\n").map(String.init)
        XCTAssertEqual(tail?.program, ["0:#fff900 60ms; 1:#06fc00 60ms; 2:#06fff9 60ms; 3:#0006f9 60ms; 4:#7d06ff 60ms; 5:#f900ff 60ms; 6:#fc0006 60ms; 7:#ff7d06 60ms",
                                       lines[1].replacingOccurrences(of: "0.2s", with: "40ms"),
                                       lines[2], lines[3]].joined(separator: "\n"))
        XCTAssertEqual(tail?.lengthMs, 500)
    }

    /// The rainbow's first frame has no room for a bridge beside its four
    /// lines, so that frame keeps the old brightness for its rest, under 0.2 s;
    /// the tail is the four lines alone.
    func testRainbowFirstFrameHasNoRoomForTheJump() {
        let tail = LedContinuation.tail(of: p(.effect("rainbow")), elapsedMs: 100, brightness: 254)
        XCTAssertEqual(tail?.program.split(separator: "\n").count, 4)
        XCTAssertFalse(tail?.program.contains("60ms") ?? true)
    }

    func testPhaseWrapsAroundTheLoop() {
        XCTAssertEqual(LedContinuation.tail(of: p(.done), elapsedMs: 4517 + 1000, brightness: 255),
                       LedContinuation.tail(of: p(.done), elapsedMs: 1000, brightness: 255))
    }

    /// Every looping program, every LED count, every phase in 5 ms steps: the
    /// tail stays inside the device's limits, every line is a shape the reader
    /// knows, and it plays for exactly the rest of the loop, within one frame.
    func testEveryTailIsWellFormedAndEndsAtTheLoopEnd() {
        for state in Self.looping {
            for leds in [2, 8] {
                for brightness in [255, 254] {
                    let loop = p(state, leds: leds, brightness: brightness)
                    guard let loopMs = LedContinuation.loopMs(of: loop) else {
                        XCTFail("\(state) does not loop"); continue
                    }
                    for phase in stride(from: 0, to: loopMs, by: 5) {
                      for fromDark in [false, true] {
                        guard let tail = LedContinuation.tail(of: loop, elapsedMs: phase, brightness: brightness,
                                                              fromDark: fromDark)
                        else { XCTFail("\(state) \(leds) at \(phase): no tail"); continue }
                        let label = "\(state) \(leds) LEDs at \(phase) ms\(fromDark ? " from dark" : "")"
                        XCTAssertLessThanOrEqual(tail.program.utf8.count, 512, label)
                        XCTAssertLessThanOrEqual(tail.program.split(separator: "\n").count, 20, label)
                        // The loop's remainder; or, on the roll both agents
                        // share, the pass's when the whole rest would not fit
                        // beside the bridge.
                        let passEnd = Self.passEnd(of: loop, at: phase)
                        XCTAssertTrue(tail.lengthMs == loopMs - phase || tail.lengthMs == passEnd - phase,
                                      "\(label): \(tail.lengthMs) is neither \(loopMs - phase) nor \(passEnd - phase)")
                        XCTAssertFalse(tail.program.contains("repeat"), label)
                        guard let parsed = LedContinuation.parse(tail.program) else {
                            XCTFail("\(label): the tail does not read back"); continue
                        }
                        XCTAssertEqual(Double(parsed.loopMs), Double(tail.lengthMs),
                                       accuracy: Double(LedContinuation.frameMs), label)
                        XCTAssertFalse(tail.program.contains("brightness"), label)
                        XCTAssertNotNil(LedContinuation.parse(tail.unscaled), label)
                        XCTAssertEqual(tail.program.utf8.count, tail.unscaled.utf8.count, label)
                      }
                    }
                }
            }
        }
    }
}

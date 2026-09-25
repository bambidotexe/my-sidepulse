import XCTest
@testable import MySidepulseCore

final class BrightnessCycleTests: XCTestCase {
    /// Presses from a starting point, each reading back what the previous
    /// one left: the brightness a level set, or off.
    private func walk(from brightness: Int, off: Bool = false, steps: Int,
                      presses: Int) -> [BrightnessCycle.Step] {
        var brightness = brightness
        var off = off
        var seen: [BrightnessCycle.Step] = []
        for _ in 0..<presses {
            let step = BrightnessCycle.next(after: brightness, modeIsOff: off, steps: steps)
            seen.append(step)
            switch step {
            case .off: off = true
            case .level(let level): brightness = level; off = false
            }
        }
        return seen
    }

    private func level(_ fraction: Double) -> BrightnessCycle.Step {
        .level(BrightnessCurve.device(perceived: fraction))
    }

    // MARK: the curve

    func testTheCurveRunsFromTheStripsLowestToFull() {
        XCTAssertEqual(BrightnessCurve.device(perceived: 1), 255)
        XCTAssertEqual(BrightnessCurve.device(perceived: 0), 1, "never below the strip's lowest")
        XCTAssertEqual(BrightnessCurve.percent(device: 255), 100)
    }

    /// The owner's measurement on a white strip: a third of full looked like
    /// `brightness 30`, two thirds like 110. The curve must land where the
    /// eye did, within what an eye can place.
    func testTheCurveMatchesTheOwnersEye() {
        XCTAssertEqual(Double(BrightnessCurve.device(perceived: 1.0 / 3)), 30, accuracy: 3)
        XCTAssertEqual(Double(BrightnessCurve.device(perceived: 2.0 / 3)), 110, accuracy: 5)
    }

    func testTheCurveGoesUpEverywhere() {
        let values = (0...100).map { BrightnessCurve.device(percent: $0) }
        XCTAssertEqual(values, values.sorted())
    }

    /// Slider and command read back the percent they set, so the Strip page
    /// shows the same number the cycle printed.
    func testAPercentReadsBackAsItself() {
        for percent in BrightnessCurve.percent(device: 1)...100 {
            let device = BrightnessCurve.device(percent: percent)
            XCTAssertEqual(BrightnessCurve.percent(device: device), percent, accuracy: 1,
                           "\(percent) % → \(device)")
        }
    }

    // MARK: the slider

    /// Every slider position is a different value on the strip, and a
    /// visible step from the one before it, by the same rule a press uses.
    func testEverySliderPositionIsAVisibleStep() {
        let positions = Array(stride(from: K.brightnessSliderStepPercent, through: 100,
                                     by: K.brightnessSliderStepPercent))
        let devices = positions.map { BrightnessCurve.device(percent: $0) }
        XCTAssertEqual(devices.first, 1, "the first position is the strip's lowest")
        XCTAssertEqual(devices.last, 255)
        let seen = devices.map(BrightnessCurve.percent)
        for (lower, upper) in zip(seen, seen.dropFirst()) {
            XCTAssertGreaterThan(upper, lower + K.brightnessCycleSlackPercent, "\(seen)")
        }
    }

    /// A value the slider set reads back as the same position.
    func testASliderPositionReadsBackAsItself() {
        for position in stride(from: K.brightnessSliderStepPercent, through: 100,
                               by: K.brightnessSliderStepPercent) {
            XCTAssertEqual(BrightnessCurve.sliderPercent(
                device: BrightnessCurve.device(percent: position)), position)
        }
    }

    func testAnyValueShowsOnTheGrid() {
        XCTAssertEqual(BrightnessCurve.sliderPercent(device: 255), 100)
        XCTAssertEqual(BrightnessCurve.sliderPercent(device: 1), K.brightnessSliderStepPercent)
        XCTAssertEqual(BrightnessCurve.sliderPercent(device: BrightnessCycle.levels(steps: 3)[0]),
                       35, "the cycle's 33 % shows on the nearest position")
    }

    // MARK: the steps

    /// Within one percent: at the dim end one unit of the strip is about that
    /// much to the eye, so a step can read back a percent off.
    func testTheLevelsAreEvenToTheEye() {
        for steps in [3, 4] {
            let percents = BrightnessCycle.levels(steps: steps).map(BrightnessCurve.percent)
            for (index, percent) in percents.enumerated() {
                XCTAssertEqual(Double(percent), 100 * Double(index + 1) / Double(steps),
                               accuracy: 1, "step \(index + 1) of \(steps)")
            }
        }
        XCTAssertEqual(BrightnessCycle.levels(steps: 1), [255])
    }

    /// Every level of the most steps allowed is a visible step from the one
    /// before it, by the same rule a press uses.
    func testTheMostStepsAreStillToldApart() {
        let percents = BrightnessCycle.levels(steps: K.brightnessCycleMaxSteps)
            .map(BrightnessCurve.percent)
        for (lower, upper) in zip(percents, percents.dropFirst()) {
            XCTAssertGreaterThan(upper, lower + K.brightnessCycleSlackPercent, "\(percents)")
        }
    }

    func testNoLevelIsBelowTheDevicesLowest() {
        XCTAssertGreaterThanOrEqual(BrightnessCycle.levels(steps: K.brightnessCycleMaxSteps)
                                        .min() ?? 0, 1)
    }

    /// The owner's own example: three steps, starting at 50 %.
    func testThreeStepsFromHalfway() {
        XCTAssertEqual(walk(from: BrightnessCurve.device(percent: 50), steps: 3, presses: 6),
                       [level(2.0 / 3), level(1), .off, level(1.0 / 3), level(2.0 / 3), level(1)])
    }

    func testTheDefaultWalksQuartersThenOff() {
        XCTAssertEqual(walk(from: 255, off: true, steps: K.brightnessCycleDefaultSteps,
                            presses: 6),
                       [level(0.25), level(0.5), level(0.75), level(1), .off, level(0.25)])
    }

    /// Off always comes back at the first step, whatever brightness the
    /// strip was left at.
    func testOffComesBackAtTheFirstStep() {
        XCTAssertEqual(BrightnessCycle.next(after: 255, modeIsOff: true, steps: 3), level(1.0 / 3))
        XCTAssertEqual(BrightnessCycle.next(after: 40, modeIsOff: true, steps: 3), level(1.0 / 3))
    }

    /// A brightness a unit under a step counts as that step: a press moves
    /// on visibly rather than by one unit.
    func testABrightnessAUnitUnderAStepCountsAsThatStep() {
        XCTAssertEqual(BrightnessCycle.next(after: BrightnessCurve.device(percent: 33),
                                            modeIsOff: false, steps: 3), level(2.0 / 3))
        let half = BrightnessCurve.device(percent: 50)
        XCTAssertEqual(BrightnessCycle.next(after: half - 1, modeIsOff: false, steps: 4),
                       level(0.75))
        XCTAssertEqual(BrightnessCycle.next(after: 254, modeIsOff: false, steps: 4), .off)
    }

    func testABrightnessBetweenStepsGoesToTheNextOneUp() {
        XCTAssertEqual(BrightnessCycle.next(after: 1, modeIsOff: false, steps: 4), level(0.25))
        XCTAssertEqual(BrightnessCycle.next(after: BrightnessCurve.device(percent: 40),
                                            modeIsOff: false, steps: 4), level(0.5))
    }

    func testOneStepIsAToggleAtFullBrightness() {
        XCTAssertEqual(walk(from: 60, steps: 1, presses: 3), [.level(255), .off, .level(255)])
    }

    // MARK: off, and back

    func testThePressAfterOffBringsBackTheModeItReplaced() {
        XCTAssertEqual(BrightnessCycle.modeAfterOff(saved: "rainbow"), .effect("rainbow"))
        XCTAssertEqual(BrightnessCycle.modeAfterOff(saved: "#123456"), .color("#123456"))
        XCTAssertEqual(BrightnessCycle.modeAfterOff(saved: "auto"), .auto)
    }

    func testWithNothingSavedTheStripGoesBackToAuto() {
        XCTAssertEqual(BrightnessCycle.modeAfterOff(saved: nil), .auto)
        XCTAssertEqual(BrightnessCycle.modeAfterOff(saved: "off"), .auto, "off would stay dark")
        XCTAssertEqual(BrightnessCycle.modeAfterOff(saved: "nonsense"), .auto)
    }

    // MARK: the white LED

    /// Only a dark strip lights LED 0: over an animation the white would
    /// restart it a second time when it left.
    func testTheWhiteShowsOnlyOnADarkStripWithinItsWindow() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let until = now.addingTimeInterval(K.brightnessPreviewSeconds)
        XCTAssertTrue(BrightnessCycle.previewShows(mode: .auto, painted: .off, until: until,
                                                   now: now))
        XCTAssertFalse(BrightnessCycle.previewShows(mode: .auto, painted: .working, until: until,
                                                    now: now))
        XCTAssertFalse(BrightnessCycle.previewShows(mode: .color("#123456"),
                                                    painted: .manualColor("#123456"),
                                                    until: until, now: now))
        XCTAssertFalse(BrightnessCycle.previewShows(mode: .off, painted: .off, until: until,
                                                    now: now), "the off step stays dark")
        XCTAssertFalse(BrightnessCycle.previewShows(mode: .auto, painted: .off, until: nil,
                                                    now: now))
        XCTAssertFalse(BrightnessCycle.previewShows(mode: .auto, painted: .off, until: until,
                                                    now: until))
    }

    func testTheWhiteLedProgram() {
        XCTAssertEqual(LedProgram.brightnessPreview(ledCount: 8, brightness: 64), """
        brightness 64
        0:#ba5eff 160ms;1:#000000 160ms;2:#000000 160ms;3:#000000 160ms;4:#000000 160ms;5:#000000 160ms;6:#000000 160ms;7:#000000 160ms
        """)
        XCTAssertEqual(LedProgram.brightnessPreview(ledCount: 2, brightness: 255),
                       "0:#ba5eff 160ms;1:#000000 160ms")
    }

    func testPercentIsWholeAndPerceived() {
        XCTAssertEqual(BrightnessCycle.percent(255), 100)
        XCTAssertEqual(BrightnessCycle.percent(BrightnessCurve.device(percent: 33)), 33)
    }
}

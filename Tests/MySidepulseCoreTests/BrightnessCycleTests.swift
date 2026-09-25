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

    func testTheLevelsAreEqualStepsOfTheDevicesScale() {
        XCTAssertEqual(BrightnessCycle.levels(steps: 4), [64, 128, 191, 255])
        XCTAssertEqual(BrightnessCycle.levels(steps: 3), [85, 170, 255])
        XCTAssertEqual(BrightnessCycle.levels(steps: 1), [255])
    }

    func testNoLevelIsBelowTheDevicesLowest() {
        XCTAssertEqual(BrightnessCycle.levels(steps: K.brightnessCycleMaxSteps).first, 3)
        XCTAssertGreaterThanOrEqual(BrightnessCycle.levels(steps: 1000).first ?? 0, 1)
    }

    /// The owner's own example: three steps, starting at 50 %.
    func testThreeStepsFromHalfway() {
        XCTAssertEqual(walk(from: 128, steps: 3, presses: 6),
                       [.level(170), .level(255), .off, .level(85), .level(170), .level(255)])
    }

    func testTheDefaultWalksQuartersThenOff() {
        XCTAssertEqual(walk(from: 255, off: true, steps: K.brightnessCycleDefaultSteps,
                            presses: 6),
                       [.level(64), .level(128), .level(191), .level(255), .off, .level(64)])
    }

    /// Off always comes back at the first step, whatever brightness the
    /// strip was left at.
    func testOffComesBackAtTheFirstStep() {
        XCTAssertEqual(BrightnessCycle.next(after: 255, modeIsOff: true, steps: 3), .level(85))
        XCTAssertEqual(BrightnessCycle.next(after: 40, modeIsOff: true, steps: 3), .level(85))
    }

    /// The Strip page's slider can leave 127 for 50 %: a press there must
    /// not move by one unit to 128.
    func testABrightnessAUnitUnderAStepCountsAsThatStep() {
        XCTAssertEqual(BrightnessCycle.next(after: 127, modeIsOff: false, steps: 4), .level(191))
        XCTAssertEqual(BrightnessCycle.next(after: 254, modeIsOff: false, steps: 4), .off)
    }

    func testABrightnessBetweenStepsGoesToTheNextOneUp() {
        XCTAssertEqual(BrightnessCycle.next(after: 10, modeIsOff: false, steps: 4), .level(64))
        XCTAssertEqual(BrightnessCycle.next(after: 100, modeIsOff: false, steps: 4), .level(128))
    }

    func testOneStepIsAToggleAtFullBrightness() {
        XCTAssertEqual(walk(from: 60, steps: 1, presses: 3), [.level(255), .off, .level(255)])
    }

    func testPercentIsWhole() {
        XCTAssertEqual(BrightnessCycle.percent(255), 100)
        XCTAssertEqual(BrightnessCycle.percent(128), 50)
        XCTAssertEqual(BrightnessCycle.percent(85), 33)
        XCTAssertEqual(BrightnessCycle.percent(170), 67)
    }
}

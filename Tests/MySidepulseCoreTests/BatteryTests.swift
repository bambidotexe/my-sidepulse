import XCTest
@testable import MySidepulseCore

final class BatteryTests: XCTestCase {
    func testCriticalTruthTable() {
        XCTAssertTrue(BatteryRules.isCritical(PowerState(percent: 15)))
        XCTAssertTrue(BatteryRules.isCritical(PowerState(percent: 1)))
        XCTAssertFalse(BatteryRules.isCritical(PowerState(percent: 16)))
        XCTAssertFalse(BatteryRules.isCritical(PowerState(percent: 10, plugged: true)))
        XCTAssertFalse(BatteryRules.isCritical(PowerState(percent: 10, charging: true)))
        XCTAssertFalse(BatteryRules.isCritical(PowerState(percent: 10, charged: true)))
        XCTAssertFalse(BatteryRules.isCritical(PowerState(percent: 10, present: false)))
        XCTAssertFalse(BatteryRules.isCritical(nil))
    }

    func testColorBandsInclusive() {
        XCTAssertEqual(BatteryRules.color(forPercent: 15), K.batteryLowRed)
        XCTAssertEqual(BatteryRules.color(forPercent: 16), K.batteryMidAmber)
        XCTAssertEqual(BatteryRules.color(forPercent: 50), K.batteryMidAmber)
        XCTAssertEqual(BatteryRules.color(forPercent: 51), K.batteryHighGreen)
    }

    func testFillThirtyPercentOfEight() {
        let f = BatteryRules.fill(percent: 30, ledCount: 8)
        XCTAssertEqual(f.full, 2)
        XCTAssertEqual(f.partial, 0.4, accuracy: 0.0001)
        XCTAssertEqual(f.count, 8)
        let hundred = BatteryRules.fill(percent: 100, ledCount: 8)
        XCTAssertEqual(hundred.full, 8)
        XCTAssertEqual(hundred.partial, 0)
    }

    func testFillColorAndScale() {
        XCTAssertEqual(BatteryRules.scaleHex("#330900", by: 0.4), "#140300")
        XCTAssertEqual(BatteryRules.scaleHex("#ffffff", by: 1.0), "#ffffff")
        XCTAssertEqual(BatteryRules.scaleHex("junk", by: 0.5), "junk")
        let f = BatteryRules.fill(percent: 30, ledCount: 8)
        XCTAssertEqual(BatteryRules.fillColor(index: 0, fill: f, color: "#330900"), "#330900")
        XCTAssertEqual(BatteryRules.fillColor(index: 2, fill: f, color: "#330900"), "#140300")
        XCTAssertEqual(BatteryRules.fillColor(index: 3, fill: f, color: "#330900"), K.batteryOff)
    }
}

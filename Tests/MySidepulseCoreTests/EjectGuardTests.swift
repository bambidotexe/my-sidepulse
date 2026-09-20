import XCTest
@testable import MySidepulseCore

/// macOS loginwindow ejects any disk that appears while the screen is
/// locked — which is what the SD slot does when it re-enumerates after a
/// hibernate wake — so without a veto the card silently vanishes overnight.
final class EjectGuardTests: XCTestCase {
    func match(_ deviceProtocol: String?, _ model: String?) -> Bool {
        EjectGuard.isBuiltInCardReader(deviceProtocol: deviceProtocol, deviceModel: model)
    }

    /// The two shapes the real reader reports. Matching the READER rather than
    /// the volume is deliberate: the card must be protected before any
    /// SidePulse volume has had a chance to mount, which is exactly the case
    /// the guard exists for.
    func testTheBuiltInReaderMatches() {
        XCTAssertTrue(match("Secure Digital", nil))
        XCTAssertTrue(match(nil, "APPLE SDXC Reader"))
        XCTAssertTrue(match("Secure Digital", "APPLE SDXC Reader"))
    }

    func testOtherDisksAreLeftAlone() {
        XCTAssertFalse(match(nil, nil), "an unreadable description must not veto")
        XCTAssertFalse(match("USB", "SanDisk Cruzer"))
        XCTAssertFalse(match("Apple Fabric", "APPLE SSD AP1024Z"))
        XCTAssertFalse(match("Thunderbolt", "Samsung T7"))
    }

    /// Vetoing every removable disk would trap the user's own USB sticks.
    func testAPlainUsbStickIsEjectable() {
        XCTAssertFalse(match("USB", "Generic Flash Disk"))
    }
}

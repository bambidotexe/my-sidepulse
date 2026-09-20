import XCTest
@testable import MySidepulseCore

final class QuietLaunchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testAMarkerJustWrittenCounts() {
        XCTAssertTrue(QuietLaunch.isFresh(writtenAt: now, now: now))
        XCTAssertTrue(QuietLaunch.isFresh(writtenAt: now.addingTimeInterval(-QuietLaunch.window + 1), now: now))
    }

    /// One left behind by an install that died must not silence a launch the user asks for minutes later.
    func testAnOldMarkerDoesNotCount() {
        XCTAssertFalse(QuietLaunch.isFresh(writtenAt: now.addingTimeInterval(-QuietLaunch.window - 1), now: now))
    }

    /// A marker from the future is a clock that moved, not a fresh marker.
    func testAMarkerFromTheFutureDoesNotCount() {
        XCTAssertFalse(QuietLaunch.isFresh(writtenAt: now.addingTimeInterval(60), now: now))
    }

    /// The open request outlives the process it was sent to: it is delivered again to the copy launchd
    /// starts after the hand-over, which is the whole reason this grace exists.
    func testAnOpenRequestRightAfterAQuietLaunchIsTheInstallers() {
        XCTAssertTrue(QuietLaunch.silences(reopenAt: now, quietLaunchAt: now))
        XCTAssertTrue(QuietLaunch.silences(reopenAt: now.addingTimeInterval(QuietLaunch.reopenGrace), quietLaunchAt: now))
    }

    /// A double-click the user means, a while after an install, opens the window as it always did.
    func testAnOpenRequestLongAfterIsThePerson() {
        XCTAssertFalse(QuietLaunch.silences(reopenAt: now.addingTimeInterval(QuietLaunch.reopenGrace + 1), quietLaunchAt: now))
    }

    /// Short enough that it cannot swallow anything a person does on purpose.
    func testTheGraceIsShort() {
        XCTAssertLessThanOrEqual(QuietLaunch.reopenGrace, 30)
        XCTAssertLessThan(QuietLaunch.reopenGrace, QuietLaunch.window)
    }
}

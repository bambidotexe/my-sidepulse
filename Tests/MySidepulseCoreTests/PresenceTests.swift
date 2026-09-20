import XCTest
@testable import MySidepulseCore

/// The gate that decides whether a phone push is wanted at all.
final class PresenceTests: XCTestCase {
    func testSomeoneTypingIsPresent() {
        XCTAssertTrue(Presence.userIsPresent(idleSeconds: 0, screenLocked: false))
        XCTAssertTrue(Presence.userIsPresent(idleSeconds: K.notifyPresenceIdleSeconds - 1,
                                             screenLocked: false))
    }

    func testSomeoneAwayIsAbsent() {
        XCTAssertFalse(Presence.userIsPresent(idleSeconds: K.notifyPresenceIdleSeconds,
                                              screenLocked: false))
    }

    /// "Locked it and walked off ten seconds ago" — idle time has barely
    /// moved, but nobody is going to see the strip.
    func testALockedScreenIsAbsentHoweverRecentTheInput() {
        XCTAssertFalse(Presence.userIsPresent(idleSeconds: 0, screenLocked: true))
    }

    /// An unreadable idle time must notify rather than silently swallow
    /// every notification.
    func testAnUnreadableIdleTimeFailsOpen() {
        XCTAssertFalse(Presence.userIsPresent(idleSeconds: .infinity, screenLocked: false),
                       "absent, so the notification goes out")
    }

    /// The session dictionary mixes two key conventions — kCGSSessionOnConsoleKey
    /// carries its `k` prefix while the lock key is conventionally written
    /// without one — and the lock key is absent entirely while unlocked. Accept
    /// either spelling rather than depend on which one this macOS uses.
    func testEitherSpellingOfTheLockKeyIsUnderstood() {
        XCTAssertTrue(Presence.screenIsLocked(["CGSSessionScreenIsLocked": true]))
        XCTAssertTrue(Presence.screenIsLocked(["kCGSSessionScreenIsLockedKey": true]))
        XCTAssertFalse(Presence.screenIsLocked(["CGSSessionScreenIsLocked": false]))
    }

    func testAnAbsentLockKeyMeansUnlocked() {
        XCTAssertFalse(Presence.screenIsLocked(["kCGSSessionOnConsoleKey": true]))
        XCTAssertFalse(Presence.screenIsLocked([:]))
        XCTAssertFalse(Presence.screenIsLocked(nil), "no session info is not a locked screen")
    }
}

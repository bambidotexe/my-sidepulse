import XCTest
@testable import MySidepulseCore

final class LaunchdHandoverTests: XCTestCase {
    private func script(bundle: String = "/Applications/MySidepulse.app") -> String {
        LaunchdHandover.script(pid: 4242, uid: 501, label: "io.mysidepulse.agent", bundlePath: bundle,
                               executablePath: bundle + "/Contents/MacOS/MySidepulseApp")
    }

    /// `kickstart` replaces the process running it, so it can only happen once that process has gone.
    func testTheKickstartWaitsForThePidToGo() {
        let lines = script().split(separator: "\n").map(String.init)
        let wait = lines.firstIndex { $0.contains("kill -0 4242") }
        let kick = lines.firstIndex { $0.contains("kickstart") }
        XCTAssertNotNil(wait)
        XCTAssertNotNil(kick)
        XCTAssertGreaterThan(kick!, wait!)
    }

    func testItKickstartsThisUsersOwnJob() {
        XCTAssertTrue(script().contains("/bin/launchctl kickstart gui/501/io.mysidepulse.agent"))
    }

    /// The one that matters: a hand-over that fails must leave the app running, not gone.
    func testTheAppIsOpenedAgainIfTheJobDoesNotComeUp() {
        let lines = script().split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.last, "/usr/bin/open '/Applications/MySidepulse.app'")
        XCTAssertTrue(script().contains("pgrep -f '/Applications/MySidepulse.app/Contents/MacOS/MySidepulseApp'"))
    }

    func testBothWaitsAreBounded() {
        XCTAssertTrue(script().contains("[ $i -lt \(LaunchdHandover.waitTenths) ]"))
        XCTAssertTrue(script().contains("[ $i -lt \(LaunchdHandover.confirmTenths) ]"))
    }

    /// `bootout` would be wrong here and `disable` would be a disaster: neither belongs in this script.
    func testItNeitherBootsOutNorDisables() {
        XCTAssertFalse(script().contains("bootout"))
        XCTAssertFalse(script().contains("disable"))
    }

    func testASpaceInThePathSurvives() {
        XCTAssertTrue(script(bundle: "/Users/a b/MySidepulse.app").contains("/usr/bin/open '/Users/a b/MySidepulse.app'"))
    }
}

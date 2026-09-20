import XCTest
@testable import MySidepulseCore

final class UninstallPlanTests: XCTestCase {
    private func script(support: String = "/Users/x/Library/Application Support/MySidepulse",
                        home: String = "/Users/x") -> String {
        UninstallPlan.helperScript(pid: 4242, uid: 501, supportDirectory: support,
                                   bundleIdentifier: "io.mysidepulse.app", home: home)
    }

    /// The whole reason the helper exists: nothing in it may run before the app has gone.
    func testEveryCommandWaitsForThePidToGo() {
        let lines = script().split(separator: "\n").map(String.init)
        let wait = lines.firstIndex { $0.contains("kill -0 4242") }
        XCTAssertNotNil(wait)
        for (index, line) in lines.enumerated()
        where line.contains("bootout") || line.contains("rm -rf") || line.contains("defaults delete") || line.contains("find") {
            XCTAssertGreaterThan(index, wait!, line)
        }
    }

    func testTheWaitIsBounded() {
        XCTAssertTrue(script().contains("[ $i -lt \(UninstallPlan.helperWaitTenths) ]"))
    }

    /// The former name's job too: a Mac that ran SidePulse still carries it.
    func testBothJobLabelsAreBootedOutOfThisUsersDomain() {
        XCTAssertEqual(UninstallPlan.jobLabels, ["io.mysidepulse.agent", "io.sidepulse.agent"])
        for label in UninstallPlan.jobLabels {
            XCTAssertTrue(script().contains("/bin/launchctl bootout gui/501/\(label)"), label)
        }
    }

    /// `bootout`, never `disable`: a disabled job is refused for ever after, and neither deleting the
    /// plist nor reinstalling nor a reboot clears it.
    func testItNeverDisablesAJob() {
        XCTAssertFalse(script().contains("disable"))
    }

    func testTheSupportFolderIsRemovedAndItsSpacesSurvive() {
        XCTAssertTrue(script().contains("/bin/rm -rf '/Users/x/Library/Application Support/MySidepulse'"))
    }

    /// The empty plist cfprefsd writes as a process exits, and the folders named after the bundle.
    func testItTakesThePreferencesTheCachesAndTheSavedState() {
        for tail in ["Preferences/io.mysidepulse.app.plist", "Caches/io.mysidepulse.app",
                     "HTTPStorages/io.mysidepulse.app", "HTTPStorages/io.mysidepulse.app.binarycookies",
                     "Saved Application State/io.mysidepulse.app.savedState"] {
            XCTAssertTrue(script().contains("'/Users/x/Library/\(tail)'"), tail)
        }
    }

    /// `defaults delete` first, or cfprefsd writes its cache back over the gap the `rm` just made.
    func testThePreferencesAreDeletedBeforeTheirFileIsRemoved() {
        let s = script()
        XCTAssertLessThan(s.range(of: "defaults delete")!.lowerBound,
                          s.range(of: "Preferences/io.mysidepulse.app.plist")!.lowerBound)
    }

    func testTheByHostPreferencesGoThroughFindRatherThanAGlob() {
        XCTAssertTrue(script(home: "/Users/a b").contains(
            "/usr/bin/find '/Users/a b/Library/Preferences/ByHost' -maxdepth 1 -name 'io.mysidepulse.app.*.plist' -delete"))
    }

    func testAQuoteInThePathCannotEndTheQuoting() {
        let quoted = UninstallPlan.shellQuoted("/Users/o'brien/Library")
        XCTAssertEqual(quoted, "'/Users/o'\\''brien/Library'")
    }
}

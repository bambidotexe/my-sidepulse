import XCTest
@testable import MySidepulsePlatform

final class TerminalTabProberTests: XCTestCase {
    func testScriptSelectionIsAnAllowlist() {
        XCTAssertNotNil(TerminalTabProber.script(forBundleId: "com.apple.Terminal"))
        XCTAssertNotNil(TerminalTabProber.script(forBundleId: "com.googlecode.iterm2"))
        XCTAssertNil(TerminalTabProber.script(forBundleId: "com.mitchellh.ghostty"),
                     "unscriptable terminals answer nil and ack at the app level")
        XCTAssertNil(TerminalTabProber.script(forBundleId: "com.apple.Safari"))
    }

    func testTTYParsingAcceptsOnlyTTYNames() {
        XCTAssertEqual(TerminalTabProber.parseTTY("/dev/ttys003\n"), "ttys003")
        XCTAssertEqual(TerminalTabProber.parseTTY("ttys011"), "ttys011")
        XCTAssertNil(TerminalTabProber.parseTTY(""), "empty output is not a tab")
        XCTAssertNil(TerminalTabProber.parseTTY("execution error: Not authorized (-1743)"),
                     "an error message must never match a session")
        XCTAssertNil(TerminalTabProber.parseTTY("/dev/null"))
    }
}

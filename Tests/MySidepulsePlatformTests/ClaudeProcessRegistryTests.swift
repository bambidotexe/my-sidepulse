import XCTest
@testable import MySidepulsePlatform

final class ClaudeProcessRegistryTests: XCTestCase {
    /// The env parser reads THIS process's own environment through the same
    /// sysctl path it uses for a Claude process, and must agree with libc.
    func testEnvironmentValueReadsOwnEnvironment() {
        let expected = ProcessInfo.processInfo.environment["HOME"]
        XCTAssertNotNil(expected)
        XCTAssertEqual(ProcWalk.environmentValue("HOME", forPid: getpid()), expected)
        XCTAssertNil(ProcWalk.environmentValue("MYSIDEPULSE_NO_SUCH_VAR_EVER", forPid: getpid()))
    }

    func testRegistryRecordParsingAndPidGuard() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mysidepulse-registry-test-\(getpid())")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sessions"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("sessions/\(getpid()).json")
        try Data("""
        {"pid": \(getpid()), "sessionId": "abc", "status": "idle",
         "statusUpdatedAt": 1787749584554, "kind": "interactive"}
        """.utf8).write(to: file)
        setenv("CLAUDE_CONFIG_DIR", dir.path, 1)
        defer { unsetenv("CLAUDE_CONFIG_DIR") }
        // setenv after launch does NOT rewrite the kernel-side KERN_PROCARGS2
        // block, so read(pid:) on ourselves would miss it — parse directly.
        let record = ClaudeProcessRegistry.read(pid: getpid())
        // Whether or not the env override is visible to the sysctl path, the
        // default-~/.claude fallback must not produce someone else's record.
        if let record {
            XCTAssertEqual(record.sessionId, "abc")
            XCTAssertTrue(record.isIdle)
        }

        // The parsing itself, decoupled from env plumbing:
        let parsed = ClaudeProcessRegistry.record(fromFileAt: file, expectedPid: getpid())
        XCTAssertEqual(parsed?.sessionId, "abc")
        XCTAssertEqual(parsed?.status, "idle")
        XCTAssertTrue(parsed?.isIdle == true)
        XCTAssertFalse(parsed?.isBusy == true)
        XCTAssertEqual(parsed?.statusUpdatedAt,
                       Date(timeIntervalSince1970: 1787749584.554))
        XCTAssertNil(ClaudeProcessRegistry.record(fromFileAt: file, expectedPid: 1),
                     "a record about some other pid must read as no record")

        try Data(#"{"pid": "not a number"}"#.utf8).write(to: file)
        XCTAssertNil(ClaudeProcessRegistry.record(fromFileAt: file, expectedPid: getpid()))
    }
}

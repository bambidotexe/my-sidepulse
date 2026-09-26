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
        let record = ClaudeProcessRegistry.read(pid: getpid(), transcriptPath: nil)
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

    /// Claude Code keeps its transcripts under `<config>/projects/<slug>/`,
    /// so a transcript path names the config directory its registry is in.
    func testConfigDirIsDerivedFromTheTranscriptPath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(ClaudeProcessRegistry.configDir(
            fromTranscriptPath: "\(home)/.claude/projects/-Users-me-proj/abc.jsonl")?.path,
                       "\(home)/.claude")
        XCTAssertEqual(ClaudeProcessRegistry.configDir(
            fromTranscriptPath: "/tmp/cfg/projects/s/a.jsonl")?.path, "/tmp/cfg")
        XCTAssertNil(ClaudeProcessRegistry.configDir(fromTranscriptPath: "/tmp/a.jsonl"))
        XCTAssertEqual(ClaudeProcessRegistry.configDir(
            fromTranscriptPath: "/Users/me/projects/app/.claude/projects/s/a.jsonl")?.path,
                       "/Users/me/projects/app/.claude",
                       "the last projects folder that holds a slug folder is the config's")
        XCTAssertNil(ClaudeProcessRegistry.configDir(fromTranscriptPath: "/tmp/projects/a.jsonl"),
                     "a projects folder right above the file holds no slug")
        XCTAssertNil(ClaudeProcessRegistry.configDir(fromTranscriptPath: "~/.claude/projects/s/a.jsonl"),
                     "only an absolute path names a directory; the fallbacks answer otherwise")
        XCTAssertNil(ClaudeProcessRegistry.configDir(fromTranscriptPath: "cfg/projects/s/a.jsonl"))
        XCTAssertEqual(ClaudeProcessRegistry.configDir(
            fromTranscriptPath: "/Users/x/.claude/projects/-Users-x-p/abc/subagents/agent-1.jsonl")?.path,
                       "/Users/x/.claude", "a helper's transcript sits deeper in the same folder")
        XCTAssertNil(ClaudeProcessRegistry.configDir(fromTranscriptPath: "/Users/x/../y/.claude/projects/s/a.jsonl"),
                     "no .. component")
        XCTAssertNil(ClaudeProcessRegistry.configDir(fromTranscriptPath: "/Users/x/./.claude/projects/s/a.jsonl"),
                     "no . component")
        XCTAssertNil(ClaudeProcessRegistry.configDir(fromTranscriptPath: "/Users/x/.claude/projects/s/../a.jsonl"))
        XCTAssertNil(ClaudeProcessRegistry.configDir(fromTranscriptPath: "/projects/s/a.jsonl"),
                     "no folder above projects: the root is no config directory")
        XCTAssertNil(ClaudeProcessRegistry.configDir(fromTranscriptPath: ""))
    }

    func testReadFollowsTheTranscriptsConfigDir() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mysidepulse-registry-cfg-\(getpid())")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sessions"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("""
        {"pid": \(getpid()), "sessionId": "relocated", "status": "busy",
         "statusUpdatedAt": 1787749584554}
        """.utf8).write(to: dir.appendingPathComponent("sessions/\(getpid()).json"))
        let transcript = dir.appendingPathComponent("projects/-tmp-x/relocated.jsonl").path
        let record = ClaudeProcessRegistry.read(pid: getpid(), transcriptPath: transcript)
        XCTAssertEqual(record?.sessionId, "relocated")
        XCTAssertTrue(record?.isBusy == true)
    }
}

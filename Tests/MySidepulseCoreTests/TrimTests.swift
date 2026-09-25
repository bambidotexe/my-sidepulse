import XCTest
@testable import MySidepulseCore

final class TrimTests: XCTestCase {
    func payload(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }
    let t0 = Date(timeIntervalSince1970: 1_787_652_000)

    func testStopPayloadKeepsSignalDropsBodies() {
        let raw = payload([
            "hook_event_name": "Stop", "session_id": "s1", "prompt_id": "p1",
            "cwd": "/tmp/x", "permission_mode": "auto", "stop_hook_active": false,
            "last_assistant_message": String(repeating: "x", count: 2000) + " END?",
            "background_tasks": [["id": "task-1", "description": "long build"], ["shell_id": "sh-9"]],
            "tool_response": ["huge": String(repeating: "y", count: 100_000)],
        ])
        let e = Trim.journalEvent(fromHookPayload: raw, loggedAt: t0)
        XCTAssertEqual(e.event, .stop)
        XCTAssertEqual(e.sessionId, "s1")
        XCTAssertEqual(e.lastMessageTail?.count, K.messageTailMaxChars)
        XCTAssertTrue(e.lastMessageTail!.hasSuffix(" END?"))
        XCTAssertEqual(e.backgroundTaskIds, ["task-1", "sh-9"])
        XCTAssertNil(e.rawPrefix)
    }

    func testEmptyBackgroundTasksYieldsEmptyArrayNotNil() {
        let e = Trim.journalEvent(fromHookPayload: payload([
            "hook_event_name": "Stop", "session_id": "s1", "background_tasks": [] as [Any],
        ]), loggedAt: t0)
        XCTAssertEqual(e.backgroundTaskIds, [])
        let e2 = Trim.journalEvent(fromHookPayload: payload([
            "hook_event_name": "Stop", "session_id": "s1",
        ]), loggedAt: t0)
        XCTAssertNil(e2.backgroundTaskIds, "absent field must stay nil (snapshot semantics)")
    }

    func testOnlyShellBackgroundTasksHoldTheStrip() {
        let e = Trim.journalEvent(fromHookPayload: payload([
            "hook_event_name": "Stop", "session_id": "s1",
            "background_tasks": [
                ["type": "shell", "id": "sh-1", "status": "running"],
                ["type": "subagent", "id": "agent-7", "status": "running"],
                ["type": "monitor", "id": "mon-3", "status": "running"],
            ],
        ]), loggedAt: t0)
        XCTAssertEqual(e.backgroundTaskIds, ["sh-1"],
                       "subagents release via their own events; monitors never complete at all")
    }

    func testUntypedBackgroundTaskIsStillKept() {
        let e = Trim.journalEvent(fromHookPayload: payload([
            "hook_event_name": "Stop", "session_id": "s1",
            "background_tasks": [["id": "unknown-shape"], ["type": "monitor", "id": "mon-3"]],
        ]), loggedAt: t0)
        XCTAssertEqual(e.backgroundTaskIds, ["unknown-shape"],
                       "an entry with no type is an unknown shape — stay conservative and keep it")
    }

    func testBackgroundTaskWithNoUsableIdIsDropped() {
        let e = Trim.journalEvent(fromHookPayload: payload([
            "hook_event_name": "Stop", "session_id": "s1",
            "background_tasks": [["description": "long build"], ["shell_id": "sh-9"]],
        ]), loggedAt: t0)
        XCTAssertEqual(e.backgroundTaskIds, ["sh-9"],
                       "no id means no hold — never fabricate one from a description")
    }

    func testSubagentAndNotificationFields() {
        let e = Trim.journalEvent(fromHookPayload: payload([
            "hook_event_name": "SubagentStop", "session_id": "s1",
            "agent_id": "a-1", "agent_type": "Explore",
        ]), loggedAt: t0)
        XCTAssertEqual(e.agentId, "a-1")
        XCTAssertEqual(e.agentType, "Explore")
        let n = Trim.journalEvent(fromHookPayload: payload([
            "hook_event_name": "Notification", "session_id": "s1",
            "notification_type": "idle_prompt", "message": "Claude is waiting for your input",
        ]), loggedAt: t0)
        XCTAssertEqual(n.notificationType, "idle_prompt")
    }

    func testGarbageBecomesParseError() {
        let e = Trim.journalEvent(fromHookPayload: Data("{broken".utf8), loggedAt: t0)
        XCTAssertEqual(e.event, .parseError)
        XCTAssertEqual(e.rawPrefix, "{broken")
        let unknown = Trim.journalEvent(fromHookPayload: payload(["hook_event_name": "BrandNewEvent"]), loggedAt: t0)
        XCTAssertEqual(unknown.event, .parseError)
    }

    func testCappedLineFits() throws {
        var e = JournalEvent(loggedAt: t0, event: .stop)
        e.sessionId = "s1"
        e.lastMessageTail = String(repeating: "é", count: K.messageTailMaxChars) // 2-byte chars
        e.cwd = "/" + String(repeating: "d", count: 3800)
        let line = try Trim.cappedLine(e)
        XCTAssertLessThanOrEqual(line.count, K.journalLineMaxBytes)
        XCTAssertNotNil(JournalCodec.decodeLine(line), "capped line must stay valid JSON")
    }

    func testCapHoldsAgainstHugeMetadataField() throws {
        let raw = payload([
            "hook_event_name": "Stop",
            "session_id": String(repeating: "x", count: 8000),
        ])
        let e = Trim.journalEvent(fromHookPayload: raw, loggedAt: t0)
        let line = try Trim.cappedLine(e)
        XCTAssertLessThanOrEqual(line.count, K.journalLineMaxBytes, "cap must hold against huge session_id")
        XCTAssertNotNil(JournalCodec.decodeLine(line), "capped line must stay valid JSON")
    }

    func testCapHoldsForDirectlyConstructedEvent() throws {
        var e = JournalEvent(loggedAt: t0, event: .preToolUse)
        e.agentType = String(repeating: "x", count: 500)
        e.rawPrefix = String(repeating: "r", count: 1000)
        e.cwd = "/" + String(repeating: "d", count: 3000)
        // Sized to genuinely exceed the cap before any shrink pass runs — a
        // payload that already fits proves nothing about the shrink passes.
        e.backgroundTaskIds = (0..<16).map { String(repeating: "abcdefgh", count: 60) + "\($0)" }
        XCTAssertGreaterThan(try JournalCodec.encodeLine(e).count, K.journalLineMaxBytes,
                             "fixture must be over the cap or this test is vacuous")
        let line = try Trim.cappedLine(e)
        XCTAssertLessThanOrEqual(line.count, K.journalLineMaxBytes, "cap must hold for direct construction")
        XCTAssertNotNil(JournalCodec.decodeLine(line), "capped line must stay valid JSON")
    }

    func testIngestionClampsOversizedFields() {
        let raw = payload([
            "hook_event_name": "Stop",
            "session_id": String(repeating: "x", count: 8000),
            "agent_type": String(repeating: "y", count: 1000),
        ])
        let e = Trim.journalEvent(fromHookPayload: raw, loggedAt: t0)
        XCTAssertEqual(e.sessionId?.count, 200, "session_id should be clamped to metadataMaxChars")
        XCTAssertEqual(e.agentType?.count, 200, "agent_type should be clamped to metadataMaxChars")
    }

    /// The transcript path rides only the turn-boundary events: enough for
    /// any session the app can rebuild, without paying ~120 bytes on every
    /// tool event.
    func testTranscriptPathRecordedOnBoundaryEventsOnly() {
        for name in ["SessionStart", "UserPromptSubmit", "Stop"] {
            let e = Trim.journalEvent(fromHookPayload: payload([
                "hook_event_name": name, "session_id": "s1",
                "transcript_path": "/Users/x/.claude/projects/-p/abc.jsonl",
            ]), loggedAt: t0)
            XCTAssertEqual(e.transcriptPath, "/Users/x/.claude/projects/-p/abc.jsonl", name)
        }
        let tool = Trim.journalEvent(fromHookPayload: payload([
            "hook_event_name": "PostToolUse", "session_id": "s1",
            "transcript_path": "/Users/x/.claude/projects/-p/abc.jsonl",
        ]), loggedAt: t0)
        XCTAssertNil(tool.transcriptPath)
    }

    /// The turn's id is Codex's `turn_id` or Claude Code's `prompt_id`,
    /// whichever the payload carries, clamped like every other id.
    func testTheTurnIdIsKeptFromTurnIdOrPromptId() {
        func turn(_ extra: [String: Any]) -> String? {
            Trim.journalEvent(fromHookPayload: payload(
                ["hook_event_name": "PostToolUse", "session_id": "s1"].merging(extra) { $1 }),
                              loggedAt: t0).turnId
        }
        XCTAssertEqual(turn(["turn_id": "01a0d9e8-a902"]), "01a0d9e8-a902")
        XCTAssertEqual(turn(["prompt_id": "p1"]), "p1")
        XCTAssertEqual(turn(["turn_id": "t1", "prompt_id": "p1"]), "t1")
        XCTAssertNil(turn([:]))
        XCTAssertEqual(turn(["turn_id": String(repeating: "x", count: 8000)])?.count, 200)
    }
}

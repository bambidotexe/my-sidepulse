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
        let e = Trim.journalEvent(fromHookPayload: raw, agent: .claude, loggedAt: t0)
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
        ]), agent: .claude, loggedAt: t0)
        XCTAssertEqual(e.backgroundTaskIds, [])
        let e2 = Trim.journalEvent(fromHookPayload: payload([
            "hook_event_name": "Stop", "session_id": "s1",
        ]), agent: .claude, loggedAt: t0)
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
        ]), agent: .claude, loggedAt: t0)
        XCTAssertEqual(e.backgroundTaskIds, ["sh-1"],
                       "subagents release via their own events; monitors never complete at all")
    }

    func testUntypedBackgroundTaskIsStillKept() {
        let e = Trim.journalEvent(fromHookPayload: payload([
            "hook_event_name": "Stop", "session_id": "s1",
            "background_tasks": [["id": "unknown-shape"], ["type": "monitor", "id": "mon-3"]],
        ]), agent: .claude, loggedAt: t0)
        XCTAssertEqual(e.backgroundTaskIds, ["unknown-shape"],
                       "an entry with no type is an unknown shape — stay conservative and keep it")
    }

    func testBackgroundTaskWithNoUsableIdIsDropped() {
        let e = Trim.journalEvent(fromHookPayload: payload([
            "hook_event_name": "Stop", "session_id": "s1",
            "background_tasks": [["description": "long build"], ["shell_id": "sh-9"]],
        ]), agent: .claude, loggedAt: t0)
        XCTAssertEqual(e.backgroundTaskIds, ["sh-9"],
                       "no id means no hold — never fabricate one from a description")
    }

    func testSubagentAndNotificationFields() {
        let e = Trim.journalEvent(fromHookPayload: payload([
            "hook_event_name": "SubagentStop", "session_id": "s1",
            "agent_id": "a-1", "agent_type": "Explore",
        ]), agent: .claude, loggedAt: t0)
        XCTAssertEqual(e.agentId, "a-1")
        XCTAssertEqual(e.agentType, "Explore")
        let n = Trim.journalEvent(fromHookPayload: payload([
            "hook_event_name": "Notification", "session_id": "s1",
            "notification_type": "idle_prompt", "message": "Claude is waiting for your input",
        ]), agent: .claude, loggedAt: t0)
        XCTAssertEqual(n.notificationType, "idle_prompt")
    }

    func testGarbageBecomesParseError() {
        let e = Trim.journalEvent(fromHookPayload: Data("{broken".utf8), agent: .claude, loggedAt: t0)
        XCTAssertEqual(e.event, .parseError)
        XCTAssertEqual(e.rawPrefix, "{broken")
        let unknown = Trim.journalEvent(fromHookPayload: payload(["hook_event_name": "BrandNewEvent"]), agent: .claude, loggedAt: t0)
        XCTAssertEqual(unknown.event, .parseError)
    }

    /// Claude Code's and Codex's payloads name their event; only the
    /// agent's own events pass (`HookConfig.events(for:)`), in either
    /// spelling. Anything else, the app's own line names included, is a
    /// `ParseError` that keeps the payload's first bytes and none of its
    /// fields: a payload cannot forge another agent's `Interrupt` or a
    /// verdict.
    func testAnAgentOnlyPassesItsOwnEvents() {
        let interrupt = payload(["hook_event_name": "Interrupt", "session_id": "c1", "turn_id": "t1"])
        let codex = Trim.journalEvent(fromHookPayload: interrupt, agent: .codex, loggedAt: t0)
        XCTAssertEqual(codex.event, .interrupt); XCTAssertEqual(codex.agent, .codex); XCTAssertEqual(codex.sessionId, "c1")
        let claude = Trim.journalEvent(fromHookPayload: interrupt, agent: .claude, loggedAt: t0)
        XCTAssertEqual(claude.event, .parseError, "Claude Code has no Interrupt")
        XCTAssertNil(claude.sessionId)
        XCTAssertEqual(claude.rawPrefix.map { $0.hasPrefix("{") }, true)
        let notification = payload(["hook_event_name": "Notification", "session_id": "c1", "notification_type": "idle_prompt"])
        XCTAssertEqual(Trim.journalEvent(fromHookPayload: notification, agent: .codex, loggedAt: t0).event, .parseError,
                       "Codex has no Notification")
        XCTAssertEqual(Trim.journalEvent(fromHookPayload: notification, agent: .claude, loggedAt: t0).event, .notification)
        let stop = Trim.journalEvent(fromHookPayload: payload(["hook_event_name": "Stop", "session_id": "c1"]),
                                     agent: .codex, loggedAt: t0)
        XCTAssertEqual(stop.event, .stop); XCTAssertEqual(stop.agent, .codex)
        for name in ["MySidepulseVerdict", "MySidepulseAck", "ParseError", "my_sidepulse_verdict", "JobBegin", "JobEnd"] {
            for agent in [AgentKind.claude, .codex] {
                let forged = payload(["hook_event_name": name, "session_id": "c1", "verdict": "turn-finished"])
                XCTAssertEqual(Trim.journalEvent(fromHookPayload: forged, agent: agent, loggedAt: t0).event, .parseError,
                               "\(name) from \(agent)")
            }
        }
        let start = payload(["hook_event_name": "SessionStart", "session_id": "c1"])
        XCTAssertEqual(Trim.journalEvent(fromHookPayload: start, agent: .copilot, loggedAt: t0).event, .parseError,
                       "Copilot's payloads have a trim of their own")
        XCTAssertEqual(Trim.journalEvent(fromHookPayload: start, agent: .opencode, loggedAt: t0).event, .parseError,
                       "and so do OpenCode's")
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
        let e = Trim.journalEvent(fromHookPayload: raw, agent: .claude, loggedAt: t0)
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
        let e = Trim.journalEvent(fromHookPayload: raw, agent: .claude, loggedAt: t0)
        XCTAssertEqual(e.sessionId?.count, 200, "session_id should be clamped to metadataMaxChars")
        XCTAssertEqual(e.agentType?.count, 200, "agent_type should be clamped to metadataMaxChars")
    }

    /// The transcript path rides only the turn-boundary events: enough for
    /// any session the app can rebuild, without paying ~120 bytes on every
    /// tool event. Codex's `Interrupt` is one: a session followed from its
    /// interrupt on still names its rollout.
    func testTranscriptPathRecordedOnBoundaryEventsOnly() {
        for (name, agent) in [("SessionStart", AgentKind.claude), ("UserPromptSubmit", .claude), ("Stop", .claude),
                              ("Interrupt", .codex)] {
            let e = Trim.journalEvent(fromHookPayload: payload([
                "hook_event_name": name, "session_id": "s1",
                "transcript_path": "/Users/x/.claude/projects/-p/abc.jsonl",
            ]), agent: agent, loggedAt: t0)
            XCTAssertEqual(e.transcriptPath, "/Users/x/.claude/projects/-p/abc.jsonl", name)
        }
        let tool = Trim.journalEvent(fromHookPayload: payload([
            "hook_event_name": "PostToolUse", "session_id": "s1",
            "transcript_path": "/Users/x/.claude/projects/-p/abc.jsonl",
        ]), agent: .claude, loggedAt: t0)
        XCTAssertNil(tool.transcriptPath)
    }

    /// A transcript path is kept up to `K.pathMaxChars` (1024), since a cut
    /// path names no file; identifiers stay clamped at 200. Copilot's path,
    /// given or filled in from its session state, the same.
    func testATranscriptPathIsClampedAt1024AndIdentifiersAt200() {
        let deep = "/Users/x/" + String(repeating: "d/", count: 450) + "rollout-s1.jsonl"
        XCTAssertGreaterThan(deep.count, 200)
        XCTAssertLessThan(deep.count, K.pathMaxChars)
        let kept = Trim.journalEvent(fromHookPayload: payload([
            "hook_event_name": "Stop", "session_id": String(repeating: "s", count: 300), "transcript_path": deep,
        ]), agent: .claude, loggedAt: t0)
        XCTAssertEqual(kept.transcriptPath, deep, "a deep path is kept whole")
        XCTAssertEqual(kept.sessionId?.count, 200)
        let huge = "/" + String(repeating: "p", count: 5000)
        let cut = Trim.journalEvent(fromHookPayload: payload([
            "hook_event_name": "UserPromptSubmit", "session_id": "s1", "transcript_path": huge,
        ]), agent: .codex, loggedAt: t0)
        XCTAssertEqual(cut.transcriptPath?.count, K.pathMaxChars)
        XCTAssertEqual(K.pathMaxChars, 1024)
        let copilot = Trim.copilotEvent(fromHookPayload: payload(["sessionId": "c1", "transcriptPath": huge]),
                                        named: "agentStop", loggedAt: t0)
        XCTAssertEqual(copilot.transcriptPath?.count, K.pathMaxChars)
        let root = "/" + String(repeating: "r", count: 2000)
        let filled = CopilotSessionState.line(
            Trim.copilotEvent(fromHookPayload: payload(["sessionId": "c1"]), named: "agentStop", loggedAt: t0),
            root: root, directoryExists: { _ in true })
        XCTAssertEqual(filled?.transcriptPath?.count, K.pathMaxChars, "a path filled in is clamped the same")
    }

    /// The longest path, beside every identifier at its clamp, still makes
    /// a line under the cap.
    func testALineWithTheLongestPathStillFits() throws {
        let e = Trim.journalEvent(fromHookPayload: payload([
            "hook_event_name": "Stop",
            "session_id": String(repeating: "s", count: 8000), "turn_id": String(repeating: "t", count: 8000),
            "agent_id": String(repeating: "a", count: 8000), "agent_type": String(repeating: "y", count: 8000),
            "transcript_path": "/" + String(repeating: "p", count: 8000),
            "cwd": "/" + String(repeating: "d", count: 3000),
            "last_assistant_message": String(repeating: "é", count: 2000),
            "background_tasks": (0..<16).map { ["id": String(repeating: "b", count: 40) + "\($0)", "type": "shell"] },
        ]), agent: .claude, loggedAt: t0)
        XCTAssertEqual(e.transcriptPath?.count, K.pathMaxChars)
        let line = try Trim.cappedLine(e)
        XCTAssertLessThanOrEqual(line.count, K.journalLineMaxBytes)
        XCTAssertNotNil(JournalCodec.decodeLine(line), "capped line must stay valid JSON")
    }

    /// The turn's id is Codex's `turn_id` or Claude Code's `prompt_id`,
    /// whichever the payload carries, clamped like every other id.
    func testTheTurnIdIsKeptFromTurnIdOrPromptId() {
        func turn(_ extra: [String: Any]) -> String? {
            Trim.journalEvent(fromHookPayload: payload(
                ["hook_event_name": "PostToolUse", "session_id": "s1"].merging(extra) { $1 }),
                              agent: .claude, loggedAt: t0).turnId
        }
        XCTAssertEqual(turn(["turn_id": "01a0d9e8-a902"]), "01a0d9e8-a902")
        XCTAssertEqual(turn(["prompt_id": "p1"]), "p1")
        XCTAssertEqual(turn(["turn_id": "t1", "prompt_id": "p1"]), "t1")
        XCTAssertNil(turn([:]))
        XCTAssertEqual(turn(["turn_id": String(repeating: "x", count: 8000)])?.count, 200)
    }
}

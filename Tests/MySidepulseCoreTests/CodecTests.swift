import XCTest
@testable import MySidepulseCore

final class CodecTests: XCTestCase {
    func testDecodeSnakeCaseLine() throws {
        let line = #"{"logged_at":"2026-08-21T10:00:00.123Z","event":"Stop","session_id":"s1","stop_hook_active":false,"last_message_tail":"Done.","background_task_ids":["t1"],"claude_pid":4242,"host_bundle_id":"com.apple.Terminal"}"#
        let e = try XCTUnwrap(JournalCodec.decodeLine(Data(line.utf8)))
        XCTAssertEqual(e.event, .stop)
        XCTAssertEqual(e.sessionId, "s1")
        XCTAssertEqual(e.stopHookActive, false)
        XCTAssertEqual(e.lastMessageTail, "Done.")
        XCTAssertEqual(e.backgroundTaskIds, ["t1"])
        XCTAssertEqual(e.claudePid, 4242)
        XCTAssertEqual(e.hostBundleId, "com.apple.Terminal")
        XCTAssertEqual(e.loggedAt.timeIntervalSince1970, 1787306400.123, accuracy: 0.001)
    }

    func testRoundTrip() throws {
        var e = JournalEvent(loggedAt: Date(timeIntervalSince1970: 1_787_652_000), event: .preToolUse)
        e.sessionId = "s1"; e.toolName = "Bash"; e.agentId = "a1"; e.cwd = "/tmp/x"
        let data = try JournalCodec.encodeLine(e)
        XCTAssertEqual(JournalCodec.decodeLine(data), e)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(#""session_id":"s1""#))
        XCTAssertTrue(text.contains(#""tool_name":"Bash""#))
        XCTAssertFalse(text.contains("\n"))
        XCTAssertFalse(text.contains("notification_type"), "nil fields must be omitted")
    }

    func testDateWithoutFractionAccepted() throws {
        let line = #"{"logged_at":"2026-08-21T10:00:00Z","event":"UserPromptSubmit","session_id":"s1"}"#
        XCTAssertNotNil(JournalCodec.decodeLine(Data(line.utf8)))
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(JournalCodec.decodeLine(Data("not json".utf8)))
        XCTAssertNil(JournalCodec.decodeLine(Data(#"{"event":"NoSuchEvent","logged_at":"2026-08-21T10:00:00Z"}"#.utf8)))
    }
}

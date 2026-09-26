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
        XCTAssertEqual(e.agentPid, 4242)
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

    func testTheTurnIdRoundTripsUnderItsKey() throws {
        var e = JournalEvent(loggedAt: Date(timeIntervalSince1970: 1_787_652_000), event: .postToolUse)
        e.sessionId = "s1"; e.agent = .codex; e.turnId = "01a0d9e8-a902"
        let data = try JournalCodec.encodeLine(e)
        XCTAssertEqual(JournalCodec.decodeLine(data), e)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""turn_id":"01a0d9e8-a902""#))
        let old = #"{"logged_at":"2026-08-21T10:00:00Z","event":"PostToolUse","session_id":"s1"}"#
        XCTAssertNil(try XCTUnwrap(JournalCodec.decodeLine(Data(old.utf8))).turnId,
                     "a line written before the field reads as one without a turn")
    }

    /// The app's own verdict line. An older app version fails to decode the
    /// event name and skips the line, the compatibility the ack line rides on.
    func testTheVerdictLineRoundTrips() throws {
        var e = JournalEvent(loggedAt: Date(timeIntervalSince1970: 1_787_652_000.25), event: .verdict)
        e.sessionId = "s1"; e.verdict = "turn-abandoned"
        let data = try JournalCodec.encodeLine(e)
        XCTAssertEqual(JournalCodec.decodeLine(data), e)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(#""event":"MySidepulseVerdict""#))
        XCTAssertTrue(text.contains(#""verdict":"turn-abandoned""#))
    }

    /// A terminal job's two lines, written by the CLI. An older app version
    /// fails to decode either name and skips the line.
    func testTheJobLinesRoundTrip() throws {
        var begin = JournalEvent(loggedAt: Date(timeIntervalSince1970: 1_787_652_000.25), event: .jobBegin)
        begin.jobId = "zsh-900"; begin.jobPid = 1001; begin.jobSlotPid = 900; begin.jobLabel = "make"
        begin.jobShowAfterSeconds = 5; begin.hostBundleId = "com.mitchellh.ghostty"
        let beginData = try JournalCodec.encodeLine(begin)
        XCTAssertEqual(JournalCodec.decodeLine(beginData), begin)
        let beginText = String(decoding: beginData, as: UTF8.self)
        for key in [#""event":"JobBegin""#, #""job_id":"zsh-900""#, #""job_pid":1001"#, #""job_slot_pid":900"#,
                    #""job_label":"make""#, #""job_show_after_seconds":5"#, #""host_bundle_id":"com.mitchellh.ghostty""#] {
            XCTAssertTrue(beginText.contains(key), key)
        }
        XCTAssertFalse(beginText.contains("session_id"), "a job belongs to no session")

        var end = JournalEvent(loggedAt: Date(timeIntervalSince1970: 1_787_652_010.5), event: .jobEnd)
        end.jobId = "zsh-900"; end.jobExitCode = 130
        let endData = try JournalCodec.encodeLine(end)
        XCTAssertEqual(JournalCodec.decodeLine(endData), end)
        let endText = String(decoding: endData, as: UTF8.self)
        XCTAssertTrue(endText.contains(#""event":"JobEnd""#))
        XCTAssertTrue(endText.contains(#""job_exit_code":130"#))
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

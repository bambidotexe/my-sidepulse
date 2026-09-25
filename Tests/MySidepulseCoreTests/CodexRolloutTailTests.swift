import XCTest
@testable import MySidepulseCore

/// The rollout Codex writes for every session, read as its transcript. The
/// fixtures are shaped like Codex 0.157's own lines — one JSON object per
/// line, `timestamp`, `type`, `payload.type`, `payload.turn_id` — and carry
/// types, ids and timestamps only.
final class CodexRolloutTailTests: XCTestCase {
    func stamp(_ text: String) -> Date { JournalCodec.date(from: "2026-09-25T\(text)Z")! }

    func line(_ time: String, _ type: String, _ payloadType: String? = nil, turn: String? = nil) -> String {
        var payload: [String] = []
        if let payloadType { payload.append(#""type":"\#(payloadType)""#) }
        if let turn { payload.append(#""turn_id":"\#(turn)""#) }
        return #"{"ordinal":1,"payload":{\#(payload.joined(separator: ","))},"timestamp":"2026-09-25T\#(time)Z","type":"\#(type)"}"#
    }
    func marker(_ time: String, _ kind: String, turn: String = "t1") -> String {
        line(time, "event_msg", kind, turn: turn)
    }
    func tail(_ lines: [String]) -> Data { Data((lines.joined(separator: "\n") + "\n").utf8) }

    // MARK: the verdict

    /// Session 01a0d9e4's abort: the tool's output, then the turn-level
    /// `turn_aborted` 37 ms later.
    func testATurnAbortedAfterOurLastEventEndsTheTurn() {
        let verdict = CodexRolloutTail.verdict(tail: tail([
            marker("18:51:30.100", "task_started"),
            line("18:51:34.000", "response_item", "function_call"),
            line("18:52:34.665", "response_item", "custom_tool_call_output"),
            marker("18:52:34.702", "turn_aborted"),
        ]))
        XCTAssertEqual(verdict, .aborted(at: stamp("18:52:34.702"), turnId: "t1"))
        XCTAssertEqual(CodexRolloutTail.decision(verdict: verdict, lastMainEventAt: stamp("18:52:30.000"),
                                                 lastMainTurnId: nil), .aborted(endedAt: stamp("18:52:34.702")))
    }

    func testATaskCompleteIsAFinish() {
        let verdict = CodexRolloutTail.verdict(tail: tail([
            marker("18:56:42.297", "task_started"),
            line("18:56:42.698", "event_msg", "item_completed", turn: "t1"),
            line("18:57:49.900", "response_item", "message"),
            marker("18:57:49.947", "task_complete"),
            line("18:57:49.950", "event_msg", "token_count"),
        ]))
        XCTAssertEqual(verdict, .complete(at: stamp("18:57:49.947"), turnId: "t1"))
        XCTAssertEqual(CodexRolloutTail.decision(verdict: verdict, lastMainEventAt: stamp("18:57:40.000"),
                                                 lastMainTurnId: "t1"), .finished(endedAt: stamp("18:57:49.947")))
    }

    /// Codex writes a lone `item_completed` for the aborted turn when the
    /// aborted tool's process finally ends, 13 s later that day, and
    /// `token_count` or `thread_settings_applied` lines at any time: none of
    /// them is a turn marker.
    func testAStrayItemCompletedAfterTheAbortIsNotATurnMarker() {
        let verdict = CodexRolloutTail.verdict(tail: tail([
            marker("18:51:30.100", "task_started"),
            marker("18:52:34.702", "turn_aborted"),
            line("18:52:47.344", "event_msg", "item_completed", turn: "t1"),
            line("18:52:47.400", "event_msg", "token_count"),
            line("18:52:48.000", "event_msg", "thread_settings_applied"),
        ]))
        XCTAssertEqual(verdict, .aborted(at: stamp("18:52:34.702"), turnId: "t1"))
    }

    func testTaskStartedWithoutAnEndIsStillRunning() {
        let verdict = CodexRolloutTail.verdict(tail: tail([
            marker("18:56:42.297", "task_started", turn: "t1"),
            marker("18:57:49.947", "task_complete", turn: "t1"),
            marker("18:58:10.000", "task_started", turn: "t2"),
            line("18:58:11.000", "response_item", "function_call"),
            line("18:58:12.500", "event_msg", "item_completed", turn: "t2"),
        ]))
        XCTAssertEqual(verdict, .running(turnId: "t2", writtenAt: stamp("18:58:12.500")),
                       "the last marker wins, and the last line says when the rollout was last written")
    }

    func testAnUnreadableOrTruncatedTailDecidesNothing() {
        XCTAssertEqual(CodexRolloutTail.verdict(tail: Data()), .unreadable)
        XCTAssertEqual(CodexRolloutTail.verdict(tail: Data("not json\n{also not\n".utf8)), .unreadable)
        XCTAssertEqual(CodexRolloutTail.verdict(tail: tail([
            line("18:56:40.000", "session_meta"),
            line("18:56:42.698", "event_msg", "item_completed", turn: "t1"),
            line("18:56:43.000", "response_item", "message"),
        ])), .unreadable, "no turn marker at all")
        XCTAssertEqual(CodexRolloutTail.verdict(tail: tail([
            marker("18:56:42.297", "task_complete"),
            String(marker("18:57:00.000", "turn_aborted", turn: "t2").prefix(70)),
        ])), .complete(at: stamp("18:56:42.297"), turnId: "t1"),
                       "a last line cut mid-write is no line")
        XCTAssertEqual(CodexRolloutTail.verdict(tail: tail([
            #"{"payload":{"type":"task_complete","turn_id":"t1"},"type":"event_msg"}"#,
        ])), .unreadable, "an end marker with no stamp cannot be compared with anything")
    }

    /// The reader takes the window and the byte before it. A tail longer
    /// than the window starts inside a line unless that byte is a newline,
    /// and a cut line is dropped whatever it looks like. A tail exactly the
    /// window's size is a whole file, whose first line counts.
    func testACutFirstLineIsSkipped() {
        let first = marker("18:52:34.702", "turn_aborted")
        let filler = line("18:52:40.000", "event_msg", "token_count")
        var text = first + "\n"
        while text.utf8.count + filler.utf8.count + 1 < CodexRolloutTail.tailBytes - 64 {
            text += filler + "\n"
        }
        let padLine = { (n: Int) in #"{"type":"response_item","pad":"\#(String(repeating: "a", count: n))"}"# }
        let short = CodexRolloutTail.tailBytes - text.utf8.count - padLine(0).utf8.count - 1
        text += padLine(short) + "\n"
        let window = Data(text.utf8)
        XCTAssertEqual(window.count, CodexRolloutTail.tailBytes)
        XCTAssertEqual(CodexRolloutTail.readBytes, CodexRolloutTail.tailBytes + 1)
        let aborted = CodexRolloutTail.Verdict.aborted(at: stamp("18:52:34.702"), turnId: "t1")
        XCTAssertEqual(CodexRolloutTail.verdict(tail: window), aborted,
                       "a file of exactly 65 536 bytes keeps its first line")
        XCTAssertEqual(CodexRolloutTail.verdict(tail: Data("\n".utf8) + window), aborted,
                       "the byte before the window ends a line: the window starts at one")
        XCTAssertEqual(CodexRolloutTail.verdict(tail: Data("}".utf8) + window), .unreadable,
                       "the window starts inside a line: that line is dropped")
    }

    // MARK: the decision

    func testAnEndMarkerAfterOurLastEventEndsTheTurn() {
        let last = stamp("18:52:30.000")
        XCTAssertEqual(CodexRolloutTail.decision(verdict: .complete(at: stamp("18:52:31.000"), turnId: "t9"),
                                                 lastMainEventAt: last, lastMainTurnId: "t1"),
                       .finished(endedAt: stamp("18:52:31.000")))
        XCTAssertEqual(CodexRolloutTail.decision(verdict: .aborted(at: stamp("18:52:31.000"), turnId: nil),
                                                 lastMainEventAt: last, lastMainTurnId: nil),
                       .aborted(endedAt: stamp("18:52:31.000")))
    }

    /// The `Interrupt` hook lost, and the aborted tool's `PostToolUse`
    /// logged 13 s after the `turn_aborted`, for the same turn: the stamp
    /// alone could never end it; the turn id does.
    func testAnEndMarkerNamingOurTurnEndsItEvenWhenStampedEarlier() {
        let latePostToolUse = stamp("18:52:47.372")
        XCTAssertEqual(CodexRolloutTail.decision(verdict: .aborted(at: stamp("18:52:34.702"), turnId: "t1"),
                                                 lastMainEventAt: latePostToolUse, lastMainTurnId: "t1"),
                       .aborted(endedAt: stamp("18:52:34.702")))
        XCTAssertEqual(CodexRolloutTail.decision(verdict: .complete(at: stamp("18:52:34.702"), turnId: "t1"),
                                                 lastMainEventAt: latePostToolUse, lastMainTurnId: "t1"),
                       .finished(endedAt: stamp("18:52:34.702")))
    }

    /// A prompt logged before Codex wrote its `task_started`: the last end
    /// marker is the previous turn's, and says nothing about this one.
    func testAnEndMarkerOfAnEarlierTurnStampedEarlierDecidesNothing() {
        let prompt = stamp("18:58:10.000")
        for verdict in [CodexRolloutTail.Verdict.complete(at: stamp("18:57:49.947"), turnId: "t1"),
                        .aborted(at: stamp("18:57:49.947"), turnId: "t1")] {
            XCTAssertEqual(CodexRolloutTail.decision(verdict: verdict, lastMainEventAt: prompt,
                                                     lastMainTurnId: "t2"), .nothing)
            XCTAssertEqual(CodexRolloutTail.decision(verdict: verdict, lastMainEventAt: prompt,
                                                     lastMainTurnId: nil), .nothing)
        }
        XCTAssertEqual(CodexRolloutTail.decision(verdict: .complete(at: prompt, turnId: nil),
                                                 lastMainEventAt: prompt, lastMainTurnId: nil), .nothing,
                       "stamped at the same instant is not after")
    }

    func testARunningMarkerIsBusy() {
        XCTAssertEqual(CodexRolloutTail.decision(verdict: .running(turnId: "t2", writtenAt: stamp("18:58:12.500")),
                                                 lastMainEventAt: stamp("18:59:00.000"), lastMainTurnId: "t1"),
                       .busy)
    }

    func testAnUnreadableTailDecidesNothing() {
        XCTAssertEqual(CodexRolloutTail.decision(verdict: .unreadable, lastMainEventAt: stamp("18:59:00.000"),
                                                 lastMainTurnId: "t1"), .nothing)
    }

    // MARK: which file may be read

    func testARecordedPathIsTrustedOnlyWhenItNamesTheSession() {
        let sid = "01a0d9e4-1111-7222-8333-444455556666"
        let name = "/Users/u/.codex/sessions/2026/09/25/rollout-2026-09-25T18-50-00-\(sid).jsonl"
        XCTAssertTrue(CodexRolloutTail.namesSession(name, sessionId: sid))
        XCTAssertFalse(CodexRolloutTail.namesSession(name, sessionId: "01a0d9ed-1111-7222-8333-444455556666"))
        XCTAssertFalse(CodexRolloutTail.namesSession(
            "/Users/u/.codex/sessions/2026/09/25/notes-\(sid).jsonl", sessionId: sid))
        XCTAssertFalse(CodexRolloutTail.namesSession(
            "/Users/u/.codex/sessions/2026/09/25/rollout-\(sid).jsonl.fifo", sessionId: sid))
        XCTAssertFalse(CodexRolloutTail.namesSession(name, sessionId: ""))
        XCTAssertFalse(CodexRolloutTail.namesSession(name, sessionId: "../\(sid)"))
    }

    func testARecordedPathIsTrustedOnlyUnderTheSessionsFolder() {
        let home = "/Users/u/.codex"
        XCTAssertTrue(CodexRolloutTail.liesUnderSessions(
            "/Users/u/.codex/sessions/2026/09/25/rollout-x.jsonl", codexHome: home))
        XCTAssertTrue(CodexRolloutTail.liesUnderSessions(
            "/Users/u/.codex/sessions/2026/09/25/rollout-x.jsonl", codexHome: home + "/"))
        XCTAssertFalse(CodexRolloutTail.liesUnderSessions(
            "/Users/u/.codex/sessions/../../../../tmp/rollout-x.jsonl", codexHome: home))
        XCTAssertFalse(CodexRolloutTail.liesUnderSessions(
            "/Users/u/.codex/sessions/./2026/rollout-x.jsonl", codexHome: home))
        XCTAssertFalse(CodexRolloutTail.liesUnderSessions("/tmp/rollout-x.jsonl", codexHome: home))
        XCTAssertFalse(CodexRolloutTail.liesUnderSessions(
            "/Users/u/.codexevil/sessions/rollout-x.jsonl", codexHome: home))
        XCTAssertFalse(CodexRolloutTail.liesUnderSessions(
            "/Users/u/.codex/sessions-x/rollout-x.jsonl", codexHome: home))
        XCTAssertFalse(CodexRolloutTail.liesUnderSessions("/Users/u/.codex/sessions/", codexHome: home))
        XCTAssertFalse(CodexRolloutTail.liesUnderSessions(
            "sessions/2026/09/25/rollout-x.jsonl", codexHome: "sessions/.."))
    }
}

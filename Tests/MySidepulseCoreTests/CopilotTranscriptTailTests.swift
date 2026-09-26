import XCTest
@testable import MySidepulseCore

/// The `events.jsonl` Copilot writes for every session, read as its
/// transcript. The fixtures follow the order of the lines Copilot 1.0.88
/// wrote on this Mac — one JSON object per line, `type`, `timestamp`, and
/// for a hook's mirror `data.hookType` and `data.input.sessionId` — and carry
/// made-up ids and stamps only.
final class CopilotTranscriptTailTests: XCTestCase {
    let sid = "5e551011-0000-4000-8000-000000000001"
    let subagent = "5e551011-0000-4000-8000-0000000000aa"

    func stamp(_ text: String) -> Date { JournalCodec.date(from: "2026-09-25T\(text)Z")! }

    func line(_ time: String, _ type: String) -> String {
        #"{"data":{},"id":"x","parentId":null,"timestamp":"2026-09-25T\#(time)Z","type":"\#(type)"}"#
    }
    /// A hook's mirror: `hook.start` names its hook and carries its payload,
    /// whose `sessionId` is the session the hook fired for.
    func hook(_ time: String, _ hookType: String, session: String?) -> String {
        let input = session.map { #"{"sessionId":"\#($0)"}"# } ?? "{}"
        return #"{"data":{"hookInvocationId":"h","hookType":"\#(hookType)","input":\#(input)},"id":"x","timestamp":"2026-09-25T\#(time)Z","type":"hook.start"}"#
    }
    func hookEnd(_ time: String, _ hookType: String) -> String {
        #"{"data":{"hookInvocationId":"h","hookType":"\#(hookType)","success":true},"id":"x","timestamp":"2026-09-25T\#(time)Z","type":"hook.end"}"#
    }
    func tail(_ lines: [String]) -> Data { Data((lines.joined(separator: "\n") + "\n").utf8) }
    func verdict(_ lines: [String]) -> CopilotTranscriptTail.Verdict {
        CopilotTranscriptTail.verdict(tail: tail(lines), sessionId: sid)
    }

    // MARK: the verdict

    /// Ctrl+C at an open permission prompt: the prompt is cancelled, the
    /// model call ends, and `abort` follows. No hook fired.
    func testAnAbortIsTheInterrupt() {
        let v = verdict([
            line("23:50:28.118", "tool.execution_start"),
            hook("23:50:28.118", "preToolUse", session: sid),
            hookEnd("23:50:28.346", "preToolUse"),
            line("23:50:28.573", "permission.requested"),
            hook("23:50:28.573", "notification", session: sid),
            hookEnd("23:50:28.786", "notification"),
            line("23:50:34.360", "permission.completed"),
            line("23:50:34.361", "assistant.turn_end"),
            line("23:50:34.361", "abort"),
        ])
        XCTAssertEqual(v, .aborted(at: stamp("23:50:34.361")))
        XCTAssertEqual(CopilotTranscriptTail.decision(verdict: v, lastMainEventAt: stamp("23:50:28.900")),
                       .aborted(endedAt: stamp("23:50:34.361")))
    }

    /// The natural end: the session's own `agentStop` hook starting, which
    /// Copilot mirrors in the file because MySidepulse's hooks are set up.
    /// `assistant.turn_end` ends every model call and is no marker.
    func testTheSessionsOwnAgentStopIsAFinish() {
        let v = verdict([
            line("23:44:41.727", "assistant.turn_start"),
            line("23:44:42.662", "assistant.message"),
            line("23:44:42.663", "assistant.turn_end"),
            hook("23:44:42.664", "agentStop", session: sid),
            hookEnd("23:44:42.900", "agentStop"),
            line("23:44:42.901", "session.usage_checkpoint"),
        ])
        XCTAssertEqual(v, .complete(at: stamp("23:44:42.664")))
        XCTAssertEqual(CopilotTranscriptTail.decision(verdict: v, lastMainEventAt: stamp("23:44:41.800")),
                       .finished(endedAt: stamp("23:44:42.664")))
    }

    /// A subagent's `agentStop` is mirrored into its parent's file under the
    /// subagent's id, while the parent's turn goes on: it ends nothing. One
    /// whose payload names no session ends nothing either.
    func testASubagentsAgentStopInTheParentsFileIsNoEnd() {
        let v = verdict([
            line("23:50:50.371", "tool.execution_start"),
            hook("23:50:50.832", "userPromptSubmitted", session: subagent),
            line("23:50:51.042", "user.message"),
            line("23:50:51.046", "assistant.turn_start"),
            hook("23:50:51.046", "agentStop", session: subagent),
            line("23:50:51.052", "assistant.message"),
            line("23:50:51.052", "assistant.turn_end"),
            hookEnd("23:50:51.264", "agentStop"),
            hook("23:50:51.300", "agentStop", session: nil),
        ])
        XCTAssertEqual(v, .running(writtenAt: stamp("23:50:51.300")),
                       "the parent's work is the last marker, and the last line says when the file was last written")
        XCTAssertEqual(CopilotTranscriptTail.decision(verdict: v, lastMainEventAt: stamp("23:50:50.500")), .busy)
        let subagentsStop = [
            line("23:50:50.371", "tool.execution_start"),
            line("23:50:51.046", "assistant.turn_start"),
            hook("23:50:51.046", "agentStop", session: subagent),
        ]
        XCTAssertEqual(verdict(subagentsStop), .running(writtenAt: stamp("23:50:51.046")),
                       "read the instant the subagent's stop was written")
        XCTAssertEqual(verdict(subagentsStop + [hookEnd("23:50:51.264", "agentStop"),
                                                hook("23:50:51.706", "agentStop", session: sid)]),
                       .complete(at: stamp("23:50:51.706")), "the parent's own stop follows")
    }

    /// A failed turn fires no `agentStop`: `session.error` is its end. The
    /// retried errors before it write only their hook's mirror, and the turn
    /// goes on after them.
    func testASessionErrorIsAFailedTurn() {
        let retried = [
            line("23:49:56.934", "assistant.turn_start"),
            hook("23:50:04.775", "errorOccurred", session: sid),
            hookEnd("23:50:05.004", "errorOccurred"),
            hook("23:50:13.814", "errorOccurred", session: sid),
            hookEnd("23:50:14.050", "errorOccurred"),
        ]
        XCTAssertEqual(verdict(retried), .running(writtenAt: stamp("23:50:14.050")))
        let v = verdict(retried + [
            hook("23:50:45.799", "errorOccurred", session: sid),
            hookEnd("23:50:46.010", "errorOccurred"),
            line("23:50:46.010", "assistant.turn_end"),
            line("23:50:46.010", "session.error"),
        ])
        XCTAssertEqual(v, .failed(at: stamp("23:50:46.010")))
        XCTAssertEqual(CopilotTranscriptTail.decision(verdict: v, lastMainEventAt: stamp("23:50:45.900")),
                       .failed(endedAt: stamp("23:50:46.010")))
    }

    /// `session.shutdown` closes the session. The turn's own end, when one
    /// comes before it, still says how the turn ended; a turn with no end
    /// closed with the session.
    func testAShutdownClosesTheSessionAndTheTurnsOwnEndSaysHow() {
        let shutdown = [hook("23:40:08.539", "sessionEnd", session: sid),
                        hookEnd("23:40:08.666", "sessionEnd"),
                        line("23:40:08.668", "session.usage_checkpoint"),
                        line("23:40:08.679", "session.shutdown")]
        XCTAssertEqual(verdict([line("23:40:08.401", "assistant.message"),
                                hook("23:40:08.403", "agentStop", session: sid),
                                hookEnd("23:40:08.538", "agentStop")] + shutdown),
                       .complete(at: stamp("23:40:08.403")))
        XCTAssertEqual(verdict([line("23:40:08.300", "abort")] + shutdown), .aborted(at: stamp("23:40:08.300")))
        XCTAssertEqual(verdict([line("23:40:08.300", "session.error")] + shutdown),
                       .failed(at: stamp("23:40:08.300")))
        XCTAssertEqual(verdict([line("23:40:08.300", "tool.execution_start")] + shutdown),
                       .closed(at: stamp("23:40:08.679")))
        XCTAssertEqual(verdict([line("23:40:00.000", "session.start")] + shutdown),
                       .closed(at: stamp("23:40:08.679")), "a session that never took a prompt")
        XCTAssertEqual(verdict([line("23:30:00.000", "session.shutdown"),
                                line("23:35:00.000", "session.start")] + shutdown),
                       .closed(at: stamp("23:40:08.679")), "a resumed session closes at its last shutdown")
        XCTAssertEqual(verdict([line("23:40:08.300", "tool.execution_start"),
                                hook("23:40:08.400", "agentStop", session: subagent)] + shutdown),
                       .closed(at: stamp("23:40:08.679")),
                       "a subagent's agentStop before the shutdown is no end of the turn")
        XCTAssertEqual(CopilotTranscriptTail.decision(verdict: .closed(at: stamp("23:40:08.679")),
                                                      lastMainEventAt: stamp("23:40:08.000")),
                       .closed(endedAt: stamp("23:40:08.679")))
    }

    func testEveryStepOfATurnIsWork() {
        for type in ["user.message", "assistant.turn_start", "assistant.message", "tool.execution_start",
                     "tool.execution_complete", "permission.requested", "permission.completed"] {
            XCTAssertEqual(verdict([line("23:00:00.000", "abort"), line("23:00:01.000", type)]),
                           .running(writtenAt: stamp("23:00:01.000")), type)
        }
        XCTAssertEqual(verdict([line("23:00:00.000", "abort"), line("23:00:01.000", "assistant.turn_end"),
                                line("23:00:02.000", "session.usage_checkpoint"),
                                hook("23:00:03.000", "postToolUse", session: sid)]),
                       .aborted(at: stamp("23:00:00.000")),
                       "a model call's end, a checkpoint and another hook's mirror are no markers")
    }

    func testAnUnreadableOrTruncatedTailDecidesNothing() {
        XCTAssertEqual(CopilotTranscriptTail.verdict(tail: Data(), sessionId: sid), .unreadable)
        XCTAssertEqual(CopilotTranscriptTail.verdict(tail: Data("not json\n{also not\n".utf8), sessionId: sid),
                       .unreadable)
        XCTAssertEqual(verdict([line("23:46:46.692", "session.start"), line("23:46:46.755", "session.model_change")]),
                       .unreadable, "no turn marker at all")
        XCTAssertEqual(verdict([line("23:00:00.000", "abort"),
                                String(line("23:00:05.000", "session.error").prefix(60))]),
                       .aborted(at: stamp("23:00:00.000")), "a last line cut mid-write is no line")
        XCTAssertEqual(verdict([#"{"data":{},"type":"abort"}"#]), .unreadable,
                       "an end marker with no stamp cannot be compared with anything")
        XCTAssertEqual(verdict([#"{"data":{},"type":"user.message"}"#]), .unreadable,
                       "nor can work with no stamp anywhere")
        XCTAssertEqual(CopilotTranscriptTail.verdict(tail: tail([hook("23:00:00.000", "agentStop", session: sid)]),
                                                     sessionId: ""), .unreadable,
                       "an agentStop names no session when there is none to name")
    }

    /// The reader takes the window and the byte before it. A tail longer
    /// than the window starts inside a line unless that byte is a newline,
    /// and a cut line is dropped whatever it looks like. A tail exactly the
    /// window's size is a whole file, whose first line counts.
    func testACutFirstLineIsSkipped() {
        let first = line("23:50:34.361", "abort")
        let filler = line("23:50:40.000", "session.usage_checkpoint")
        var text = first + "\n"
        while text.utf8.count + filler.utf8.count + 1 < CopilotTranscriptTail.tailBytes - 64 {
            text += filler + "\n"
        }
        let padLine = { (n: Int) in #"{"type":"system.notification","pad":"\#(String(repeating: "a", count: n))"}"# }
        let short = CopilotTranscriptTail.tailBytes - text.utf8.count - padLine(0).utf8.count - 1
        text += padLine(short) + "\n"
        let window = Data(text.utf8)
        XCTAssertEqual(window.count, CopilotTranscriptTail.tailBytes)
        XCTAssertEqual(CopilotTranscriptTail.tailBytes, 65_536)
        XCTAssertEqual(CopilotTranscriptTail.readBytes, CopilotTranscriptTail.tailBytes + 1)
        let aborted = CopilotTranscriptTail.Verdict.aborted(at: stamp("23:50:34.361"))
        XCTAssertEqual(CopilotTranscriptTail.verdict(tail: window, sessionId: sid), aborted,
                       "a file of exactly 65 536 bytes keeps its first line")
        XCTAssertEqual(CopilotTranscriptTail.verdict(tail: Data("\n".utf8) + window, sessionId: sid), aborted,
                       "the byte before the window ends a line: the window starts at one")
        XCTAssertEqual(CopilotTranscriptTail.verdict(tail: Data("}".utf8) + window, sessionId: sid), .unreadable,
                       "the window starts inside a line: that line is dropped")
    }

    // MARK: the decision

    /// Copilot names no turn: an end marker ends the session's turn only
    /// when it is stamped after the last main-agent event. One stamped
    /// earlier is the previous turn's end, seen before Copilot wrote the new
    /// prompt's `user.message`.
    func testAnEndMarkerEndsTheTurnOnlyWhenStampedAfterOurLastEvent() {
        let prompt = stamp("23:50:45.600")
        for v in [CopilotTranscriptTail.Verdict.complete(at: stamp("23:50:34.361")),
                  .aborted(at: stamp("23:50:34.361")), .failed(at: stamp("23:50:34.361")),
                  .closed(at: stamp("23:50:34.361")), .aborted(at: prompt)] {
            XCTAssertEqual(CopilotTranscriptTail.decision(verdict: v, lastMainEventAt: prompt), .nothing, "\(v)")
        }
        XCTAssertEqual(CopilotTranscriptTail.decision(verdict: .unreadable, lastMainEventAt: prompt), .nothing)
        XCTAssertEqual(CopilotTranscriptTail.decision(verdict: .running(writtenAt: stamp("23:40:00.000")),
                                                      lastMainEventAt: prompt), .busy,
                       "work is work whenever the file was last written")
    }

    /// A session waiting on a permission or a question: only an `abort`
    /// stamped after the wait began ends it (Ctrl+C at the prompt). Work, a
    /// finish, a failure or a close, and an abort from before the wait,
    /// change nothing: answering is the next hook's to say.
    func testOnlyAnAbortAfterTheWaitBeganEndsAWait() {
        let waitSince = stamp("23:50:28.786")
        XCTAssertEqual(CopilotTranscriptTail.waitDecision(verdict: .aborted(at: stamp("23:50:34.361")),
                                                          waitSince: waitSince),
                       .aborted(endedAt: stamp("23:50:34.361")))
        for v in [CopilotTranscriptTail.Verdict.aborted(at: stamp("23:50:20.000")), .aborted(at: waitSince),
                  .running(writtenAt: stamp("23:50:40.000")), .complete(at: stamp("23:50:40.000")),
                  .failed(at: stamp("23:50:40.000")), .closed(at: stamp("23:50:40.000")), .unreadable] {
            XCTAssertEqual(CopilotTranscriptTail.waitDecision(verdict: v, waitSince: waitSince), .nothing, "\(v)")
        }
    }

    // MARK: which file may be read

    func testARecordedPathIsTrustedOnlyWhenItIsTheSessionsOwnFile() {
        let root = "/Users/u/.copilot/session-state"
        let path = "\(root)/\(sid)/events.jsonl"
        XCTAssertTrue(CopilotTranscriptTail.isTrusted(path: path, sessionId: sid, root: root))
        XCTAssertTrue(CopilotTranscriptTail.isTrusted(path: path, sessionId: sid, root: root + "/"))
        XCTAssertFalse(CopilotTranscriptTail.isTrusted(path: path, sessionId: subagent, root: root),
                       "another session's file")
        XCTAssertFalse(CopilotTranscriptTail.isTrusted(path: "\(root)/\(sid)/workspace.yaml", sessionId: sid,
                                                       root: root))
        XCTAssertFalse(CopilotTranscriptTail.isTrusted(path: "\(root)/\(sid)/x/events.jsonl", sessionId: sid,
                                                       root: root))
        XCTAssertFalse(CopilotTranscriptTail.isTrusted(path: "\(root)/x/../\(sid)/events.jsonl", sessionId: sid,
                                                       root: root))
        XCTAssertFalse(CopilotTranscriptTail.isTrusted(path: "\(root)/./\(sid)/events.jsonl", sessionId: sid,
                                                       root: root))
        XCTAssertFalse(CopilotTranscriptTail.isTrusted(path: "\(root)//\(sid)/events.jsonl", sessionId: sid,
                                                       root: root))
        XCTAssertFalse(CopilotTranscriptTail.isTrusted(
            path: "/Users/u/.copilot/session-state-x/\(sid)/events.jsonl", sessionId: sid, root: root))
        XCTAssertFalse(CopilotTranscriptTail.isTrusted(path: "/tmp/\(sid)/events.jsonl", sessionId: sid, root: root))
        XCTAssertFalse(CopilotTranscriptTail.isTrusted(path: "session-state/\(sid)/events.jsonl", sessionId: sid,
                                                       root: "session-state"), "relative")
        XCTAssertFalse(CopilotTranscriptTail.isTrusted(path: "\(root)/../events.jsonl", sessionId: "..", root: root))
        XCTAssertFalse(CopilotTranscriptTail.isTrusted(path: "\(root)/events.jsonl", sessionId: "", root: root))
        XCTAssertFalse(CopilotTranscriptTail.isTrusted(path: "/Users/u/.copilot/\(sid)/events.jsonl", sessionId: sid,
                                                       root: "/Users/u/.copilot/session-state/.."))
    }

    /// The file of a session no line named one for: the session's own, under
    /// the root; none for an id that is not one folder name.
    func testTheSessionsFileIsBuiltFromTheRootWhenNoTrustedPathIsRecorded() {
        let root = "/Users/u/.copilot/session-state"
        let own = "\(root)/\(sid)/events.jsonl"
        XCTAssertEqual(CopilotTranscriptTail.path(recorded: own, sessionId: sid, root: root), own)
        XCTAssertEqual(CopilotTranscriptTail.path(recorded: nil, sessionId: sid, root: root), own)
        XCTAssertEqual(CopilotTranscriptTail.path(recorded: "/tmp/\(sid)/events.jsonl", sessionId: sid, root: root),
                       own)
        XCTAssertNil(CopilotTranscriptTail.path(recorded: nil, sessionId: "../x", root: root))
        XCTAssertNil(CopilotTranscriptTail.path(recorded: nil, sessionId: "", root: root))
    }
}

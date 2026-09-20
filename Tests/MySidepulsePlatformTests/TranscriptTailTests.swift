import XCTest
@testable import MySidepulsePlatform

final class TranscriptTailTests: XCTestCase {
    func write(_ lines: [String]) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
        try Data(lines.joined(separator: "\n").utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }

    // Shapes lifted from a real Claude Code 2.1 transcript: the completed
    // turn ends stop_reason end_turn, the interrupted one ends on the bare
    // user prompt, and the file closes with message-less state records.
    let finishedEntry = #"{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Fixed."}]}}"#
    let toolUseEntry = #"{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use"}]}}"#
    let promptEntry = #"{"type":"user","message":{"role":"user","content":"fake working for 1 min"}}"#
    let stateRecord = #"{"type":"cost-state"}"#
    let sidechainFinish = #"{"type":"assistant","isSidechain":true,"message":{"role":"assistant","stop_reason":"end_turn","content":[]}}"#

    func testCompletedAnswerIsFinishedThroughTrailingStateRecords() throws {
        let path = try write([promptEntry, finishedEntry, stateRecord, stateRecord])
        XCTAssertEqual(TranscriptTail.verdict(atPath: path), .finished)
    }

    func testUnansweredPromptIsIncomplete() throws {
        let path = try write([finishedEntry, promptEntry, stateRecord])
        XCTAssertEqual(TranscriptTail.verdict(atPath: path), .incomplete,
                       "the Ctrl-C shape: a prompt no assistant message ever followed")
    }

    func testAssistantStoppedForAToolIsIncomplete() throws {
        let path = try write([promptEntry, toolUseEntry])
        XCTAssertEqual(TranscriptTail.verdict(atPath: path), .incomplete,
                       "a turn that died mid-tool never finished")
    }

    func testSidechainTrafficNeverSpeaksForTheMainTurn() throws {
        let path = try write([promptEntry, sidechainFinish])
        XCTAssertEqual(TranscriptTail.verdict(atPath: path), .incomplete,
                       "a subagent's finish must not paint the interrupted main turn green")
    }

    func testUnreadableAndEmptyDecideNothing() throws {
        XCTAssertEqual(TranscriptTail.verdict(atPath: "/no/such/file"), .unreadable)
        let empty = try write([])
        XCTAssertEqual(TranscriptTail.verdict(atPath: empty), .unreadable)
        let onlyState = try write([stateRecord, stateRecord])
        XCTAssertEqual(TranscriptTail.verdict(atPath: onlyState), .unreadable)
    }
}

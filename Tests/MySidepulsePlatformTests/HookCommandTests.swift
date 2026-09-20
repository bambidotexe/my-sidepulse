import XCTest
@testable import MySidepulsePlatform
@testable import MySidepulseCore

final class HookCommandTests: XCTestCase {
    func tempJournal() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mysidepulse-hook-\(UUID().uuidString)/journal.jsonl")
    }

    func testHookWritesEnrichedTrimmedLine() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let payload = #"{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Bash","tool_input":{"command":"ls"}}"#
        let origin = ProcWalk.Origin(claudePid: 4242, hostAppPid: 99, hostBundlePath: nil)
        let code = HookCommand.run(input: Data(payload.utf8), environment: [:],
                                   journalURL: url, now: Date(), origin: origin)
        XCTAssertEqual(code, 0)
        let line = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").first
        let e = try XCTUnwrap(JournalCodec.decodeLine(Data(String(line!).utf8)))
        XCTAssertEqual(e.event, .preToolUse)
        XCTAssertEqual(e.toolName, "Bash")
        XCTAssertEqual(e.claudePid, 4242)
        XCTAssertFalse(String(line!).contains("tool_input"), "bodies must be dropped")
    }

    /// The hook records the TAB, not Claude's controlling terminal: a session
    /// hosted on a daemon pty must journal no tty at all, or the ack scopes
    /// itself to a tab that does not exist — which once left a real alert
    /// green and unacknowledgeable for 4 m 58 s.
    func testTheJournalledTTYIsTheTabAndNothingElse() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let payload = #"{"hook_event_name":"Stop","session_id":"s1"}"#
        func line(origin: ProcWalk.Origin) throws -> JournalEvent {
            try? FileManager.default.removeItem(at: url)
            XCTAssertEqual(HookCommand.run(input: Data(payload.utf8), environment: [:],
                                           journalURL: url, now: Date(), origin: origin), 0)
            let raw = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").first
            return try XCTUnwrap(JournalCodec.decodeLine(Data(String(raw!).utf8)))
        }
        let tab = try line(origin: ProcWalk.Origin(claudePid: 4242, hostAppPid: 99,
                                                   hostBundlePath: nil, tabTTY: "ttys002"))
        XCTAssertEqual(tab.tty, "ttys002")
        let pty = try line(origin: ProcWalk.Origin(claudePid: 25408, hostAppPid: 5713,
                                                   hostBundlePath: nil, tabTTY: nil))
        XCTAssertNil(pty.tty, "a pty with no window behind it is no tab")
    }

    func testDisableEnvSkipsWriting() {
        let url = tempJournal()
        let code = HookCommand.run(input: Data("{}".utf8), environment: ["MYSIDEPULSE_DISABLE": "1"],
                                   journalURL: url, now: Date(), origin: nil)
        XCTAssertEqual(code, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// Spec §1's 8 MB cap: a pathological payload must not be trusted past it.
    /// Truncated JSON parses as garbage, so the honest record is a ParseError
    /// line — and the hook still exits 0, because it always exits 0.
    func testAPayloadPastTheCapBecomesAParseErrorNotAJournalledEvent() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var payload = Data(#"{"hook_event_name":"Stop","session_id":"s1","filler":""#.utf8)
        payload.append(Data(repeating: UInt8(ascii: "x"), count: K.hookStdinMaxBytes))
        payload.append(Data(#""}"#.utf8))
        XCTAssertEqual(HookCommand.run(input: payload, environment: [:],
                                       journalURL: url, now: Date(), origin: nil), 0)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("ParseError"), "an over-cap payload is not a trustable event")
        XCTAssertLessThanOrEqual(text.utf8.count, K.journalLineMaxBytes + 1,
                                 "the journal line itself must stay capped")
    }

    func testGarbageStillExitsZeroAndJournalsParseError() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(HookCommand.run(input: Data("{oops".utf8), environment: [:],
                                       journalURL: url, now: Date(), origin: nil), 0)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("ParseError"))
    }
}

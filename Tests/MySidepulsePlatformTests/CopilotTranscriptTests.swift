import XCTest
import MySidepulseCore
@testable import MySidepulsePlatform

final class CopilotTranscriptTests: XCTestCase {
    let sid = "5e551011-0000-4000-8000-000000000001"

    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopilotTranscriptTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testReadReturnsOnlyTheTail() throws {
        let dir = try tempDir()
        let big = dir.appendingPathComponent("events.jsonl")
        let bytes = Data((0..<100 * 1024).map { UInt8(truncatingIfNeeded: $0 % 251) })
        try bytes.write(to: big)
        let tail = try XCTUnwrap(CopilotTranscript.read(path: big.path))
        XCTAssertEqual(tail.count, 65_537, "the 64 KB window and the byte before it")
        XCTAssertEqual(tail.count, CopilotTranscriptTail.readBytes)
        XCTAssertEqual(tail, bytes.suffix(65_537))

        let small = dir.appendingPathComponent("small.jsonl")
        try Data("one line\n".utf8).write(to: small)
        XCTAssertEqual(CopilotTranscript.read(path: small.path), Data("one line\n".utf8),
                       "a file shorter than the window is read whole")
        XCTAssertNil(CopilotTranscript.read(path: dir.appendingPathComponent("missing.jsonl").path))
    }

    /// A recorded path is the journal's, and a journal line can be written by
    /// anyone who can write the journal: a FIFO, a directory or a link at that
    /// path is refused at once, never waited on.
    func testReadRefusesAnythingButAPlainFile() throws {
        let dir = try tempDir()
        let fifo = dir.appendingPathComponent("events.fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let started = Date()
        XCTAssertNil(CopilotTranscript.read(path: fifo.path))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "a FIFO with no writer must not block")
        XCTAssertNil(CopilotTranscript.read(path: dir.path))
        let target = dir.appendingPathComponent("target.jsonl")
        try Data("{}\n".utf8).write(to: target)
        let link = dir.appendingPathComponent("link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertNil(CopilotTranscript.read(path: link.path))
    }

    /// The file the Engine reads: the recorded one when Core trusts it, the
    /// session's own under the session-state folder otherwise.
    func testARecordedPathOutsideTheSessionStateFolderIsReplacedByTheSessionsOwn() throws {
        let root = try tempDir().appendingPathComponent("session-state", isDirectory: true)
        let folder = root.appendingPathComponent(sid, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let real = folder.appendingPathComponent("events.jsonl")
        try Data(#"{"type":"abort","timestamp":"2026-09-25T23:50:34.361Z"}"#.utf8).write(to: real)
        XCTAssertEqual(CopilotTranscript.path(recorded: real.path, sessionId: sid, root: root), real.path)
        XCTAssertEqual(CopilotTranscript.path(recorded: "/tmp/\(sid)/events.jsonl", sessionId: sid, root: root),
                       real.path)
        XCTAssertEqual(CopilotTranscript.path(recorded: nil, sessionId: sid, root: root), real.path)
        XCTAssertNil(CopilotTranscript.path(recorded: nil, sessionId: "../\(sid)", root: root))
        XCTAssertEqual(CopilotTranscript.verdict(sessionId: sid, recorded: nil, root: root),
                       .aborted(at: JournalCodec.date(from: "2026-09-25T23:50:34.361Z")!))
        XCTAssertEqual(CopilotTranscript.verdict(sessionId: "5e551011-0000-4000-8000-0000000000ff",
                                                 recorded: nil, root: root), .unreadable,
                       "a session with no file decides nothing")
    }
}

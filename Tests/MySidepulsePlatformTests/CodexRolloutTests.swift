import XCTest
import MySidepulseCore
@testable import MySidepulsePlatform

final class CodexRolloutTests: XCTestCase {
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexRolloutTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testReadReturnsOnlyTheTail() throws {
        let dir = try tempDir()
        let big = dir.appendingPathComponent("big.jsonl")
        let bytes = Data((0..<100 * 1024).map { UInt8(truncatingIfNeeded: $0 % 251) })
        try bytes.write(to: big)
        let tail = try XCTUnwrap(CodexRollout.read(path: big.path))
        XCTAssertEqual(tail.count, 65_536)
        XCTAssertEqual(tail.count, CodexRolloutTail.tailBytes)
        XCTAssertEqual(tail, bytes.suffix(65_536))

        let small = dir.appendingPathComponent("small.jsonl")
        try Data("one line\n".utf8).write(to: small)
        XCTAssertEqual(CodexRollout.read(path: small.path), Data("one line\n".utf8),
                       "a file shorter than the window is read whole")
        XCTAssertNil(CodexRollout.read(path: dir.appendingPathComponent("missing.jsonl").path))
    }

    /// A recorded path is the journal's, and a journal line can be written by
    /// anyone who can write the journal: a FIFO or a directory at that path
    /// is refused at once, never waited on.
    func testReadRefusesAnythingButAPlainFile() throws {
        let dir = try tempDir()
        let fifo = dir.appendingPathComponent("rollout.fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let started = Date()
        XCTAssertNil(CodexRollout.read(path: fifo.path))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "a FIFO with no writer must not block")
        XCTAssertNil(CodexRollout.read(path: dir.path))
    }

    func testLocateFindsTheNewestRolloutForASession() throws {
        let home = try tempDir()
        let sid = "01a0d9e4-1111-7222-8333-444455556666"
        func place(_ day: String, _ name: String, modified: TimeInterval) throws -> URL {
            let folder = home.appendingPathComponent("sessions/\(day)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(name)
            try Data("{}\n".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: modified)], ofItemAtPath: url.path)
            return url
        }
        _ = try place("2026/09/24", "rollout-2026-09-24T10-00-00-\(sid).jsonl", modified: 1_000)
        let newest = try place("2026/09/25", "rollout-2026-09-25T18-50-00-\(sid).jsonl", modified: 2_000)
        _ = try place("2026/09/25", "rollout-2026-09-25T19-00-00-01a0d9ed-0000-0000-0000-000000000000.jsonl",
                      modified: 3_000)
        XCTAssertEqual(CodexRollout.locate(sessionId: sid, codexHome: home), newest.path)
        XCTAssertNil(CodexRollout.locate(sessionId: "01a0d9ff-0000-0000-0000-000000000000", codexHome: home))
        XCTAssertNil(CodexRollout.locate(sessionId: sid, codexHome: home.appendingPathComponent("absent")))
        XCTAssertNil(CodexRollout.locate(sessionId: "", codexHome: home))
    }

    /// The path the Engine reads: the recorded one when Core trusts it, the
    /// located one otherwise.
    func testARecordedPathOutsideTheSessionsFolderIsReplacedByTheLocatedOne() throws {
        let home = try tempDir()
        let sid = "01a0d9e4-1111-7222-8333-444455556666"
        let folder = home.appendingPathComponent("sessions/2026/09/25", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let real = folder.appendingPathComponent("rollout-2026-09-25T18-50-00-\(sid).jsonl")
        try Data("{}\n".utf8).write(to: real)
        XCTAssertEqual(CodexRollout.path(recorded: real.path, sessionId: sid, codexHome: home), real.path)
        XCTAssertEqual(CodexRollout.path(recorded: "/tmp/rollout-2026-09-25T18-50-00-\(sid).jsonl",
                                         sessionId: sid, codexHome: home), real.path)
        XCTAssertEqual(CodexRollout.path(recorded: nil, sessionId: sid, codexHome: home), real.path)
        XCTAssertNil(CodexRollout.path(recorded: nil, sessionId: "01a0d9ff-0000-0000-0000-000000000000",
                                       codexHome: home))
    }
}

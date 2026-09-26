import XCTest
@testable import MySidepulsePlatform
@testable import MySidepulseCore

final class JournalWriterTests: XCTestCase {
    func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mysidepulse-test-\(UUID().uuidString).jsonl")
    }

    func testAppendCreatesAndAppendsWithNewline() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(JournalWriter.append(Data("{\"a\":1}".utf8), to: url))
        XCTAssertTrue(JournalWriter.append(Data("{\"b\":2}".utf8), to: url))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text, "{\"a\":1}\n{\"b\":2}\n")
    }

    /// A job's lines go where the hook's do, one line each, in a folder the
    /// writer makes when it is missing, and read back as written.
    func testTheJobLinesAreAppendedToTheJournal() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mysidepulse-jobs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("journal.jsonl")
        let t0 = Date(timeIntervalSince1970: 1_787_652_000)
        let begin = JobLine.begin(id: "zsh-900", pid: 900, slotPid: 900, label: "make", showAfterSeconds: 5,
                                  hostBundleId: "com.apple.Terminal", loggedAt: t0)
        let end = JobLine.end(id: "zsh-900", exitCode: 1, loggedAt: t0.addingTimeInterval(9))
        XCTAssertTrue(JobJournal.append(begin, to: url))
        XCTAssertTrue(JobJournal.append(end, to: url))
        XCTAssertEqual(JournalTailer.readAll(url: url), [begin, end])
        XCTAssertFalse(JobJournal.append(end, to: URL(fileURLWithPath: "/no-such-dir/x.jsonl")))
    }

    func testAppendToUnwritablePathReturnsFalse() {
        XCTAssertFalse(JournalWriter.append(Data("x".utf8),
                                            to: URL(fileURLWithPath: "/no-such-dir/x.jsonl")))
    }
}

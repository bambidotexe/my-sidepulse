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

    func testAppendToUnwritablePathReturnsFalse() {
        XCTAssertFalse(JournalWriter.append(Data("x".utf8),
                                            to: URL(fileURLWithPath: "/no-such-dir/x.jsonl")))
    }
}

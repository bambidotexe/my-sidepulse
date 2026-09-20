import XCTest
@testable import MySidepulsePlatform
@testable import MySidepulseCore

final class TailerTests: XCTestCase {
    var dir: URL!
    var url: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mysidepulse-tail-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("journal.jsonl")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func line(_ sid: String) -> Data {
        try! JournalCodec.encodeLine({
            var e = JournalEvent(loggedAt: Date(), event: .userPromptSubmit)
            e.sessionId = sid
            return e
        }())
    }

    func testStartDrainsExistingThenTailsAppends() {
        JournalWriter.append(line("pre1"), to: url)
        JournalWriter.append(line("pre2"), to: url)
        let tailer = JournalTailer(url: url)
        var seen: [String] = []
        let lock = NSLock()
        let live = expectation(description: "live event")
        tailer.onEvents = { events in
            lock.lock(); seen += events.compactMap(\.sessionId); lock.unlock()
            if events.contains(where: { $0.sessionId == "live1" }) { live.fulfill() }
        }
        tailer.start()
        lock.lock(); XCTAssertEqual(seen, ["pre1", "pre2"], "start() must deliver the backlog synchronously"); lock.unlock()
        JournalWriter.append(line("live1"), to: url)
        wait(for: [live], timeout: 5)
        tailer.stop()
    }

    func testPartialLineHeldUntilNewline() {
        let tailer = JournalTailer(url: url)
        var count = 0
        let lock = NSLock()
        let done = expectation(description: "completed line")
        tailer.onEvents = { events in
            lock.lock(); count += events.count; lock.unlock()
            done.fulfill()
        }
        tailer.start()
        // Write a line in two raw chunks with no trailing newline first.
        let full = line("split") + Data([0x0A])
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        _ = full.prefix(10).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        Thread.sleep(forTimeInterval: 0.2)
        lock.lock(); XCTAssertEqual(count, 0, "no delivery before the newline"); lock.unlock()
        _ = full.dropFirst(10).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
        wait(for: [done], timeout: 5)
        lock.lock(); XCTAssertEqual(count, 1); lock.unlock()
        tailer.stop()
    }

    func testRotationIsFollowed() {
        let tailer = JournalTailer(url: url)
        var seen: [String] = []
        let lock = NSLock()
        let before = expectation(description: "pre-rotation event")
        let got = expectation(description: "post-rotation event")
        tailer.onEvents = { events in
            lock.lock(); seen += events.compactMap(\.sessionId); lock.unlock()
            if events.contains(where: { $0.sessionId == "before" }) { before.fulfill() }
            if events.contains(where: { $0.sessionId == "after" }) { got.fulfill() }
        }
        tailer.start()
        JournalWriter.append(line("before"), to: url)
        wait(for: [before], timeout: 5)
        lock.lock(); XCTAssertEqual(seen, ["before"], "backlog must not be dropped while following the rotation"); lock.unlock()
        // Rotate exactly as the Engine will: rename, then writers recreate by O_CREAT.
        try! FileManager.default.moveItem(at: url, to: dir.appendingPathComponent("journal.1.jsonl"))
        JournalWriter.append(line("after"), to: url)
        wait(for: [got], timeout: 5)
        tailer.stop()
    }

    func testRecoversWhenTheFileCannotBeOpenedYet() {
        // Parent directory does not exist yet, so the first open() fails.
        // The tailer must keep retrying rather than dying silently.
        let missingDir = dir.appendingPathComponent("not-yet")
        let target = missingDir.appendingPathComponent("journal.jsonl")
        let tailer = JournalTailer(url: target)
        let got = expectation(description: "event delivered after recovery")
        tailer.onEvents = { events in
            if events.contains(where: { $0.sessionId == "late" }) { got.fulfill() }
        }
        tailer.start()
        try! FileManager.default.createDirectory(at: missingDir, withIntermediateDirectories: true)
        JournalWriter.append(line("late"), to: target)
        wait(for: [got], timeout: 10)
        tailer.stop()
    }

    func testReadAllToleratesMissingFileAndGarbage() throws {
        XCTAssertEqual(JournalTailer.readAll(url: url).count, 0)
        JournalWriter.append(line("ok"), to: url)
        JournalWriter.append(Data("not json".utf8), to: url)
        JournalWriter.append(line("ok2"), to: url)
        XCTAssertEqual(JournalTailer.readAll(url: url).compactMap(\.sessionId), ["ok", "ok2"])
    }
}

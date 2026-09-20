import XCTest
@testable import MySidepulsePlatform

final class ProcessWatcherTests: XCTestCase {
    func testExitOfWatchedProcessFires() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["0.2"]
        try sleeper.run()
        let watcher = ProcessWatcher()
        let exited = expectation(description: "exit observed")
        watcher.onExit = { pid in
            XCTAssertEqual(pid, sleeper.processIdentifier)
            exited.fulfill()
        }
        watcher.watch(pid: sleeper.processIdentifier)
        wait(for: [exited], timeout: 5)
    }

    func testAlreadyDeadPidFiresImmediately() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["0.05"]
        try sleeper.run()
        sleeper.waitUntilExit()
        let watcher = ProcessWatcher()
        let exited = expectation(description: "dead pid reported")
        watcher.onExit = { _ in exited.fulfill() }
        watcher.watch(pid: sleeper.processIdentifier)
        wait(for: [exited], timeout: 5)
    }
}

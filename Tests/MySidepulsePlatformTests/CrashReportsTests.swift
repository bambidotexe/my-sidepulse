import XCTest
@testable import MySidepulsePlatform

/// The crash reports are read from real files: only this process's, only the recent ones, newest first.
final class CrashReportsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("crash-reports-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ name: String, at date: Date) throws {
        let file = folder.appendingPathComponent(name)
        try Data("{}".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    }

    func testOnlyRecentReportsOfThisProcessAreCountedNewestFirst() throws {
        let now = Date()
        try write("MySidepulseApp-2026-09-20-101010.ips", at: now.addingTimeInterval(-3_600))
        try write("MySidepulseApp-2026-09-21-101010.ips", at: now.addingTimeInterval(-60))
        try write("MySidepulseApp-2026-09-01-101010.ips", at: now.addingTimeInterval(-20 * 86_400))
        try write("ExcUserFault_MySidepulseApp-2026-09-21-101010.ips", at: now)
        try write("Other-2026-09-21-101010.ips", at: now)

        let dates = CrashReports.recent(process: "MySidepulseApp", since: now.addingTimeInterval(-7 * 86_400),
                                        in: [folder, folder.appendingPathComponent("Retired")])
        XCTAssertEqual(dates.count, 2)
        XCTAssertGreaterThan(dates[0], dates[1])
    }

    func testAFolderThatCannotBeReadCountsNothing() {
        XCTAssertEqual(CrashReports.recent(process: "MySidepulseApp", since: .distantPast,
                                           in: [folder.appendingPathComponent("missing")]), [])
    }
}

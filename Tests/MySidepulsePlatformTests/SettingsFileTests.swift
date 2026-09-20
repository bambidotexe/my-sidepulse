import XCTest
@testable import MySidepulsePlatform

final class SettingsFileTests: XCTestCase {
    var dir: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mysidepulse-settings-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testLoadReturnsNilWhenAbsentAndThrowsWhenUnparseable() throws {
        let missing = dir.appendingPathComponent("nope.json")
        XCTAssertNil(try SettingsFile.load(at: missing))

        let broken = dir.appendingPathComponent("broken.json")
        try Data("{not json".utf8).write(to: broken)
        XCTAssertThrowsError(try SettingsFile.load(at: broken)) { error in
            guard case SettingsFile.Failure.unparseable = error else {
                return XCTFail("expected .unparseable, got \(error)")
            }
        }
    }

    func testBackupCopiesExistingFileAndIsANoOpWhenAbsent() throws {
        let live = dir.appendingPathComponent("settings.json")
        let backup = dir.appendingPathComponent("settings.backup")
        XCTAssertNoThrow(try SettingsFile.backup(from: live, to: backup))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))

        try Data(#"{"model":"x"}"#.utf8).write(to: live)
        try SettingsFile.backup(from: live, to: backup)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), #"{"model":"x"}"#)
    }

    func testWriteRoundTripsAndPreservesUnrelatedKeys() throws {
        let live = dir.appendingPathComponent("settings.json")
        try SettingsFile.write(["model": "x", "hooks": ["Stop": []]], to: live)
        let root = try XCTUnwrap(try SettingsFile.load(at: live))
        XCTAssertEqual(root["model"] as? String, "x")
        XCTAssertNotNil(root["hooks"])
    }
}

import XCTest
@testable import MySidepulsePlatform
import MySidepulseCore

/// Both hooks edit a file that belongs to the user, so every test runs against
/// a scratch home and a stub CLI inside a stub bundle.
final class HookInstallerTests: XCTestCase {
    var dir: URL!
    var settings: URL { dir.appendingPathComponent("settings.json") }
    var backup: URL { dir.appendingPathComponent("settings.json.backup") }
    var zshrc: URL { dir.appendingPathComponent("zshrc") }
    var cli: String { dir.appendingPathComponent("MySidepulse.app/Contents/MacOS/mysidepulse").path }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mysidepulse-hooks-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: cli).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: cli))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    // MARK: Claude Code

    func testInstallSubscribesEveryEventKeepsForeignHooksAndBacksUpFirst() throws {
        let foreign = #"{"model":"x","hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"other"}]}]}}"#
        try Data(foreign.utf8).write(to: settings)
        XCTAssertEqual(HookInstaller.claudeHooksInstalled(cliPath: cli, settings: settings), 0)

        let outcome = HookInstaller.installClaudeHooks(cliPath: cli, settings: settings, backup: backup)
        XCTAssertTrue(outcome.ok, outcome.message)
        XCTAssertEqual(outcome.lines.first, "Installed 15 Claude Code hooks -> \(cli) hook")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), foreign)
        XCTAssertEqual(HookInstaller.claudeHooksInstalled(cliPath: cli, settings: settings), 15)

        let root = try XCTUnwrap(try SettingsFile.load(at: settings))
        XCTAssertEqual(root["model"] as? String, "x")
        let stop = try XCTUnwrap((root["hooks"] as? [String: Any])?["Stop"] as? [Any])
        XCTAssertEqual(stop.count, 2, "the foreign Stop hook stays beside ours")
    }

    func testRemoveTakesOnlyOursAndAnAbsentFileIsNotAnError() throws {
        XCTAssertTrue(HookInstaller.removeClaudeHooks(settings: settings, backup: backup).ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings.path), "nothing is created to remove from")

        XCTAssertTrue(HookInstaller.installClaudeHooks(cliPath: cli, settings: settings, backup: backup).ok)
        XCTAssertTrue(HookInstaller.removeClaudeHooks(settings: settings, backup: backup).ok)
        XCTAssertEqual(HookInstaller.claudeHooksInstalled(cliPath: cli, settings: settings), 0)
    }

    /// Hooks that run another copy's CLI — a build tree, a former location —
    /// are not this bundle's: the window must offer to set them up again.
    func testHooksPointingAtAnotherCopyDoNotCountAndAreReplaced() throws {
        let other = "/Elsewhere/MySidepulse.app/Contents/MacOS/mysidepulse hook"
        try SettingsFile.write(HookConfig.install(into: [:], command: other), to: settings)
        XCTAssertEqual(HookInstaller.claudeHooksInstalled(cliPath: cli, settings: settings), 0)

        XCTAssertTrue(HookInstaller.installClaudeHooks(cliPath: cli, settings: settings, backup: backup).ok)
        let text = try String(contentsOf: settings, encoding: .utf8)
        XCTAssertFalse(text.contains("Elsewhere"), "one entry per event, never two copies of us")
    }

    func testABinaryOutsideABundleOrMissingIsRefusedBeforeTheFileIsTouched() throws {
        let loose = dir.appendingPathComponent("mysidepulse").path
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: loose))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: loose)
        let gone = dir.appendingPathComponent("Gone.app/Contents/MacOS/mysidepulse").path
        for path in [loose, gone] {
            let outcome = HookInstaller.installClaudeHooks(cliPath: path, settings: settings, backup: backup)
            XCTAssertFalse(outcome.ok, path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: settings.path), path)
        }
    }

    func testAnUnparseableSettingsFileIsLeftAloneAndReportedAsUnknown() throws {
        try Data("{not json".utf8).write(to: settings)
        XCTAssertNil(HookInstaller.claudeHooksInstalled(cliPath: cli, settings: settings))
        XCTAssertFalse(HookInstaller.installClaudeHooks(cliPath: cli, settings: settings, backup: backup).ok)
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), "{not json")
    }

    // MARK: ~/.zshrc

    func testAddCreatesTheFileIsIdempotentAndRemoveRestoresIt() throws {
        XCTAssertFalse(HookInstaller.zshrcHasSnippet(zshrc: zshrc))
        XCTAssertTrue(HookInstaller.addToZshrc(cliPath: cli, zshrc: zshrc).ok)
        XCTAssertTrue(HookInstaller.zshrcHasSnippet(zshrc: zshrc))
        let once = try String(contentsOf: zshrc, encoding: .utf8)
        XCTAssertTrue(once.contains("[ -x \"\(cli)\" ] && eval \"$(\"\(cli)\" shell-init zsh)\""), once)

        XCTAssertTrue(HookInstaller.addToZshrc(cliPath: cli, zshrc: zshrc).ok)
        XCTAssertEqual(try String(contentsOf: zshrc, encoding: .utf8), once, "a second add changes nothing")

        XCTAssertTrue(HookInstaller.removeFromZshrc(zshrc: zshrc).ok)
        XCTAssertEqual(try String(contentsOf: zshrc, encoding: .utf8), "")
    }

    func testTheUsersLinesAndTheFilesModeSurviveAddAndRemove() throws {
        let original = "export A=1\nMYSIDEPULSE_SKIP+=(cswap)\n"
        try original.write(to: zshrc, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: zshrc.path)

        XCTAssertTrue(HookInstaller.addToZshrc(cliPath: cli, zshrc: zshrc).ok)
        XCTAssertTrue(HookInstaller.removeFromZshrc(zshrc: zshrc).ok)
        XCTAssertEqual(try String(contentsOf: zshrc, encoding: .utf8), original)
        let mode = try FileManager.default.attributesOfItem(atPath: zshrc.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    /// Read as empty, a Latin-1 file would be replaced whole by the block.
    func testAFileThatIsNotUTF8IsRefusedNotOverwritten() throws {
        let latin1 = Data([0x65, 0x78, 0x70, 0x6F, 0x72, 0x74, 0x20, 0xE9, 0x0A])
        try latin1.write(to: zshrc)
        XCTAssertFalse(HookInstaller.addToZshrc(cliPath: cli, zshrc: zshrc).ok)
        XCTAssertFalse(HookInstaller.removeFromZshrc(zshrc: zshrc).ok)
        XCTAssertEqual(try Data(contentsOf: zshrc), latin1)
    }

    func testAddIsRefusedWithoutACLIToPointAt() {
        let outcome = HookInstaller.addToZshrc(cliPath: dir.appendingPathComponent("gone").path, zshrc: zshrc)
        XCTAssertFalse(outcome.ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: zshrc.path))
    }

    func testTheCLIPathIsASiblingOfTheRunningExecutableNamedLikeTheCLI() {
        let path = HookInstaller.cliPath()
        XCTAssertTrue(path.hasPrefix("/"), path)
        XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent, "mysidepulse")
    }
}

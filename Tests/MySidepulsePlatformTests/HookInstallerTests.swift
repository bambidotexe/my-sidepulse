import XCTest
@testable import MySidepulsePlatform
@testable import MySidepulseCore

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
        XCTAssertEqual(outcome.lines.first, "Installed 15 Claude Code hooks -> \(cli) hook --agent claude")
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

    // MARK: GitHub Copilot — ~/.copilot/hooks/mysidepulse.json

    var copilotFile: URL { dir.appendingPathComponent("copilot/hooks/mysidepulse.json") }

    /// The whole file is MySidepulse's: written with its folder, counted,
    /// replaced when another copy wrote it, and deleted on removal.
    func testCopilotsFileIsWrittenCountedReplacedAndDeleted() throws {
        XCTAssertEqual(HookInstaller.hooksInstalled(for: .copilot, cliPath: cli, file: copilotFile), 0)
        XCTAssertEqual(HookInstaller.hooksSetUp(for: .copilot, cliPath: cli, file: copilotFile), false)

        let outcome = HookInstaller.installHooks(for: .copilot, cliPath: cli, file: copilotFile)
        XCTAssertTrue(outcome.ok, outcome.message)
        XCTAssertEqual(outcome.lines.first, "Installed 7 GitHub Copilot hooks -> \(cli) hook --agent copilot")
        XCTAssertEqual(HookInstaller.hooksInstalled(for: .copilot, cliPath: cli, file: copilotFile), 7)
        XCTAssertEqual(HookInstaller.hooksSetUp(for: .copilot, cliPath: cli, file: copilotFile), true)
        let root = try XCTUnwrap(try SettingsFile.load(at: copilotFile))
        XCTAssertTrue(HookConfig.copilotFileIsOurs(root))
        XCTAssertEqual(root["version"] as? Int, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copilotFile.path + ".backup-mysidepulse"),
                       "a file that is wholly ours needs no copy")

        let other = "/Elsewhere/MySidepulse.app/Contents/MacOS/mysidepulse"
        try SettingsFile.write(HookConfig.copilotFile(cliPath: other), to: copilotFile)
        XCTAssertEqual(HookInstaller.hooksInstalled(for: .copilot, cliPath: cli, file: copilotFile), 0)
        XCTAssertTrue(HookInstaller.installHooks(for: .copilot, cliPath: cli, file: copilotFile).ok)
        XCTAssertFalse(try String(contentsOf: copilotFile, encoding: .utf8).contains("Elsewhere"))

        XCTAssertTrue(HookInstaller.removeHooks(for: .copilot, file: copilotFile).ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copilotFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: copilotFile.deletingLastPathComponent().path),
                      "the hooks folder stays: other files may live there")
        let again = HookInstaller.removeHooks(for: .copilot, file: copilotFile)
        XCTAssertTrue(again.ok)
        XCTAssertEqual(HookInstaller.hooksInstalled(for: .copilot, cliPath: cli, file: copilotFile), 0)
    }

    /// Someone else's file at our path is refused by an install and left by
    /// a removal; a file that cannot be read is reported as unknown.
    func testAFileAtCopilotsPathThatIsNotOursIsRefusedAndLeft() throws {
        try FileManager.default.createDirectory(at: copilotFile.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let foreign = #"{"version":1,"hooks":{"agentStop":[{"type":"command","bash":"say done"}]}}"#
        for text in [foreign, "{not json"] {
            try Data(text.utf8).write(to: copilotFile)
            let install = HookInstaller.installHooks(for: .copilot, cliPath: cli, file: copilotFile)
            XCTAssertFalse(install.ok, text)
            XCTAssertEqual(try String(contentsOf: copilotFile, encoding: .utf8), text)
            XCTAssertTrue(HookInstaller.removeHooks(for: .copilot, file: copilotFile).ok, text)
            XCTAssertEqual(try String(contentsOf: copilotFile, encoding: .utf8), text)
        }
        XCTAssertNil(HookInstaller.hooksInstalled(for: .copilot, cliPath: cli, file: copilotFile))
        try Data(foreign.utf8).write(to: copilotFile)
        XCTAssertEqual(HookInstaller.hooksInstalled(for: .copilot, cliPath: cli, file: copilotFile), 0)
    }

    func testCopilotIsInstalledWhenItsHomeIsADirectoryAndItsHooksCanBeDisabled() throws {
        let home = dir.appendingPathComponent("copilot-home")
        XCTAssertFalse(HookInstaller.copilotInstalled(home: home))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        XCTAssertTrue(HookInstaller.copilotInstalled(home: home))
        XCTAssertFalse(HookInstaller.copilotHooksDisabled(home: home))
        try Data("// managed\n{\"disableAllHooks\": true}\n".utf8).write(to: home.appendingPathComponent("config.json"))
        XCTAssertTrue(HookInstaller.copilotHooksDisabled(home: home))
    }

    // MARK: OpenCode — ~/.config/opencode/plugins/mysidepulse.js

    var opencodePlugin: URL { dir.appendingPathComponent("opencode/plugins/mysidepulse.js") }

    func testOpenCodesPluginIsWrittenSetUpReplacedAndDeleted() throws {
        XCTAssertEqual(HookInstaller.hooksSetUp(for: .opencode, cliPath: cli, file: opencodePlugin), false)
        let outcome = HookInstaller.installHooks(for: .opencode, cliPath: cli, file: opencodePlugin)
        XCTAssertTrue(outcome.ok, outcome.message)
        XCTAssertEqual(outcome.lines.first, "Installed the OpenCode plugin -> \(cli) hook --agent opencode")
        XCTAssertEqual(try String(contentsOf: opencodePlugin, encoding: .utf8), HookConfig.opencodePlugin(cliPath: cli))
        XCTAssertEqual(HookInstaller.hooksInstalled(for: .opencode, cliPath: cli, file: opencodePlugin), 1)
        XCTAssertEqual(HookInstaller.hooksSetUp(for: .opencode, cliPath: cli, file: opencodePlugin), true)

        let other = HookConfig.opencodePlugin(cliPath: "/Elsewhere/MySidepulse.app/Contents/MacOS/mysidepulse")
        try other.write(to: opencodePlugin, atomically: true, encoding: .utf8)
        XCTAssertEqual(HookInstaller.hooksSetUp(for: .opencode, cliPath: cli, file: opencodePlugin), false,
                       "another copy's plugin is not set up for this one")
        XCTAssertTrue(HookInstaller.installHooks(for: .opencode, cliPath: cli, file: opencodePlugin).ok)
        XCTAssertEqual(HookInstaller.hooksSetUp(for: .opencode, cliPath: cli, file: opencodePlugin), true)

        XCTAssertTrue(HookInstaller.removeHooks(for: .opencode, file: opencodePlugin).ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: opencodePlugin.path))
        XCTAssertTrue(HookInstaller.removeHooks(for: .opencode, file: opencodePlugin).ok)
    }

    func testAFileAtOpenCodesPathThatIsNotOursIsRefusedAndLeft() throws {
        try FileManager.default.createDirectory(at: opencodePlugin.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let foreign = "export default { id: \"someone.else\", setup() {} }\n"
        try foreign.write(to: opencodePlugin, atomically: true, encoding: .utf8)
        XCTAssertFalse(HookInstaller.installHooks(for: .opencode, cliPath: cli, file: opencodePlugin).ok)
        XCTAssertTrue(HookInstaller.removeHooks(for: .opencode, file: opencodePlugin).ok)
        XCTAssertEqual(try String(contentsOf: opencodePlugin, encoding: .utf8), foreign)
        XCTAssertEqual(HookInstaller.hooksInstalled(for: .opencode, cliPath: cli, file: opencodePlugin), 0)
    }

    /// Any of its three homes says OpenCode is on this Mac.
    func testOpenCodeIsInstalledWhenAnyOfItsHomesExists() throws {
        let config = dir.appendingPathComponent("oc-config"), cliHome = dir.appendingPathComponent("oc-cli")
        let app = dir.appendingPathComponent("OpenCode.app")
        XCTAssertFalse(HookInstaller.opencodeInstalled(config: config, cliHome: cliHome, app: app))
        for home in [config, cliHome, app] {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            XCTAssertTrue(HookInstaller.opencodeInstalled(config: config, cliHome: cliHome, app: app), home.path)
            try FileManager.default.removeItem(at: home)
        }
    }

    /// Both refuse a CLI that is not there, before touching anything.
    func testCopilotAndOpenCodeRefuseAMissingCLI() {
        let gone = dir.appendingPathComponent("Gone.app/Contents/MacOS/mysidepulse").path
        XCTAssertFalse(HookInstaller.installHooks(for: .copilot, cliPath: gone, file: copilotFile).ok)
        XCTAssertFalse(HookInstaller.installHooks(for: .opencode, cliPath: gone, file: opencodePlugin).ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copilotFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: opencodePlugin.path))
    }

    /// `install-hooks` from a terminal: every agent on this Mac; the others
    /// are said, in the agents' order, and skipped.
    func testInstallAllSaysWhichAgentsAreNotOnThisMac() {
        let outcome = HookInstaller.installAllHooks(cliPath: dir.appendingPathComponent("gone").path,
                                                    installed: { _ in false })
        XCTAssertFalse(outcome.ok, "Claude's install failed on the missing CLI")
        XCTAssertEqual(Array(outcome.lines.suffix(3)), [
            Loc.hookInstall.notInstalledSkipped(.codex),
            Loc.hookInstall.notInstalledSkipped(.copilot),
            Loc.hookInstall.notInstalledSkipped(.opencode),
        ])
        XCTAssertEqual(Loc.hookInstall.notInstalledSkipped(.codex), Loc.hookInstall.codexNotInstalledSkipped)
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

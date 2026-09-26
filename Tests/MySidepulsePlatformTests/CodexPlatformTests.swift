import XCTest
@testable import MySidepulsePlatform
@testable import MySidepulseCore

/// Codex's side of the I/O: its hooks file, its process, its hook command
/// and the doctor's line about it.
final class CodexPlatformTests: XCTestCase {
    var dir: URL!
    /// A Codex home of its own: every test writes here, never in `~/.codex`.
    var files: HookInstaller.CodexFiles { HookInstaller.CodexFiles(home: dir) }
    var hooks: URL { files.hooks }
    var cli: String { dir.appendingPathComponent("MySidepulse.app/Contents/MacOS/mysidepulse").path }
    var command: String { "\(cli) hook --agent codex" }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mysidepulse-codex-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: cli).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: cli))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    // MARK: ~/.codex/hooks.json and its trust in ~/.codex/config.toml

    func testInstallSubscribesTheTwelveEventsWithACommandThatNamesCodex() throws {
        // What Codex's own import of Claude's hooks leaves in the file: a
        // bare entry of ours, and someone else's.
        let migrated = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\#(cli) hook","timeout":5}]},{"matcher":"*","hooks":[{"type":"command","command":"other"}]}]}}"#
        try Data(migrated.utf8).write(to: hooks)
        let config = "model = \"gpt-6\"   # the user's own\n"
        try Data(config.utf8).write(to: files.config)
        XCTAssertEqual(HookInstaller.codexHooksInstalled(cliPath: cli, files: files), 0,
                       "the migrated entry does not name Codex, so it does not count")

        let outcome = HookInstaller.installCodexHooks(cliPath: cli, files: files)
        XCTAssertTrue(outcome.ok, outcome.message)
        XCTAssertEqual(outcome.lines.first, "Installed 12 Codex hooks -> \(command)")
        XCTAssertTrue(outcome.lines.contains("Trusted them in ~/.codex/config.toml"), outcome.message)
        XCTAssertEqual(try String(contentsOf: files.hooksBackup, encoding: .utf8), migrated)
        XCTAssertEqual(try String(contentsOf: files.configBackup, encoding: .utf8), config)
        XCTAssertEqual(HookInstaller.codexHooksInstalled(cliPath: cli, files: files), 12)
        XCTAssertEqual(HookInstaller.codexHooksTrusted(cliPath: cli, files: files), 12)
        XCTAssertEqual(HookInstaller.hooksSetUp(for: .codex, cliPath: cli, file: hooks), true)

        let root = try XCTUnwrap(try SettingsFile.load(at: hooks))
        let stop = try XCTUnwrap((root["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        XCTAssertEqual(stop.count, 2, "the other hook stays; the migrated bare entry is replaced, not doubled")
        // Ours goes after the other, with no matcher: Codex hashes the entry
        // for its trust, and caps SessionEnd and Interrupt at 3 s.
        XCTAssertEqual(stop[0]["matcher"] as? String, "*")
        XCTAssertNil(stop[1]["matcher"])
        XCTAssertEqual((stop[1]["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int, 5)
        let interrupt = try XCTUnwrap((root["hooks"] as? [String: Any])?["Interrupt"] as? [[String: Any]])
        XCTAssertNil(interrupt[0]["matcher"])
        XCTAssertEqual((interrupt[0]["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int, 3)
        let text = try String(contentsOf: hooks, encoding: .utf8)
        XCTAssertFalse(text.contains("\(cli) hook\""), text)
        XCTAssertTrue(text.contains("Interrupt"))
        XCTAssertFalse(text.contains("Notification"), "not a Codex event")

        // The trust: Codex's own shape, after the user's text, keyed after
        // each group's index.
        let toml = try String(contentsOf: files.config, encoding: .utf8)
        XCTAssertTrue(toml.hasPrefix(config), toml)
        XCTAssertTrue(toml.contains("[hooks.state.\"\(files.trustName):stop:1:0\"]"), toml)
        XCTAssertTrue(CodexHookTrust.allTrusted(toml, entries: CodexHookTrust.entries(
            hooksFile: files.trustName, root: root, command: command)))

        let removed = HookInstaller.removeCodexHooks(cliPath: cli, files: files)
        XCTAssertTrue(removed.ok, removed.message)
        XCTAssertEqual(HookInstaller.codexHooksInstalled(cliPath: cli, files: files), 0)
        XCTAssertTrue(try String(contentsOf: hooks, encoding: .utf8).contains("other"))
        XCTAssertEqual(try String(contentsOf: files.config, encoding: .utf8), config,
                       "the trust goes with the hooks, and nothing else of the user's")
    }

    /// hooks.json holding our twelve entries and no trust is how every set-up
    /// before this one left it: ours, and never run by Codex.
    func testAnInstalledHookCodexDoesNotTrustIsNotSetUp() throws {
        try SettingsFile.write(HookConfig.install(into: [:], command: command, agent: .codex), to: hooks)
        XCTAssertEqual(HookInstaller.codexHooksInstalled(cliPath: cli, files: files), 12)
        XCTAssertEqual(HookInstaller.codexHooksTrusted(cliPath: cli, files: files), 0)
        XCTAssertEqual(HookInstaller.hooksSetUp(for: .codex, cliPath: cli, file: hooks), false)

        XCTAssertTrue(HookInstaller.installCodexHooks(cliPath: cli, files: files).ok)
        XCTAssertEqual(HookInstaller.codexHooksTrusted(cliPath: cli, files: files), 12)
        XCTAssertEqual(HookInstaller.hooksSetUp(for: .codex, cliPath: cli, file: hooks), true)

        // One switched off in Codex's /hooks screen (the last table written).
        let toml = try String(contentsOf: files.config, encoding: .utf8)
        try Data((toml + "enabled = false\n").utf8).write(to: files.config)
        XCTAssertEqual(HookInstaller.codexHooksTrusted(cliPath: cli, files: files), 11)
        XCTAssertEqual(HookInstaller.hooksSetUp(for: .codex, cliPath: cli, file: hooks), false)
    }

    /// A trust written inline would be defined twice once a table is added,
    /// which Codex refuses: nothing is written, and the outcome says where to
    /// trust the hooks instead.
    func testAnInlineStateIsRefusedAndNeitherFileIsTouched() throws {
        let inline = "[hooks]\nstate = { \"x\" = { trusted_hash = \"y\" } }\n"
        try Data(inline.utf8).write(to: files.config)
        let outcome = HookInstaller.installCodexHooks(cliPath: cli, files: files)
        XCTAssertFalse(outcome.ok)
        XCTAssertTrue(outcome.message.contains("/hooks"), outcome.message)
        XCTAssertTrue(outcome.message.contains("Your Codex files were not modified."), outcome.message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: hooks.path))
        XCTAssertEqual(try String(contentsOf: files.config, encoding: .utf8), inline)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.configBackup.path))
    }

    func testAConfigThatIsNotTextIsNeverWrittenAndReadsUnknown() throws {
        let binary = Data([0xff, 0xfe, 0x00, 0xc3])
        try binary.write(to: files.config)
        XCTAssertFalse(HookInstaller.installCodexHooks(cliPath: cli, files: files).ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: hooks.path))
        XCTAssertEqual(try Data(contentsOf: files.config), binary)
        try SettingsFile.write(HookConfig.install(into: [:], command: command, agent: .codex), to: hooks)
        XCTAssertEqual(HookInstaller.codexHooksInstalled(cliPath: cli, files: files), 12)
        XCTAssertNil(HookInstaller.codexHooksTrusted(cliPath: cli, files: files))
        XCTAssertNil(HookInstaller.hooksSetUp(for: .codex, cliPath: cli, file: hooks))

        // Removal still takes the hooks out, leaves the file it cannot read,
        // and says so.
        let removed = HookInstaller.removeCodexHooks(cliPath: cli, files: files)
        XCTAssertFalse(removed.ok)
        XCTAssertEqual(HookInstaller.codexHooksInstalled(cliPath: cli, files: files), 0)
        XCTAssertEqual(try Data(contentsOf: files.config), binary)
    }

    /// Whichever copy of the app set them up, and whether hooks.json is still
    /// there or not, removal takes out every trust table of ours.
    func testRemoveUntrustsFirstWhicheverCopyWroteThem() throws {
        let other = dir.appendingPathComponent("Old/MySidepulse.app/Contents/MacOS/mysidepulse").path
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: other).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: cli, toPath: other)
        XCTAssertTrue(HookInstaller.installCodexHooks(cliPath: other, files: files).ok)
        XCTAssertTrue(HookInstaller.removeCodexHooks(cliPath: cli, files: files).ok)
        XCTAssertTrue(CodexHookTrust.states(in: try String(contentsOf: files.config, encoding: .utf8)).isEmpty)

        XCTAssertTrue(HookInstaller.installCodexHooks(cliPath: cli, files: files).ok)
        try FileManager.default.removeItem(at: hooks)
        XCTAssertTrue(HookInstaller.removeCodexHooks(cliPath: cli, files: files).ok)
        XCTAssertTrue(CodexHookTrust.states(in: try String(contentsOf: files.config, encoding: .utf8)).isEmpty,
                      "a table of ours is known by its hash when the file naming it is gone")
    }

    func testAnAbsentFileIsCreatedByInstallAndNotByRemove() throws {
        XCTAssertTrue(HookInstaller.removeCodexHooks(cliPath: cli, files: files).ok)
        XCTAssertFalse(FileManager.default.fileExists(atPath: hooks.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.config.path))
        XCTAssertTrue(HookInstaller.installCodexHooks(cliPath: cli, files: files).ok)
        XCTAssertEqual(HookInstaller.codexHooksInstalled(cliPath: cli, files: files), 12)
        XCTAssertEqual(HookInstaller.codexHooksTrusted(cliPath: cli, files: files), 12)
    }

    /// The generic entry points, told a hooks file, keep to that file's
    /// folder for config.toml too.
    func testTheGenericEntryPointsKeepToTheFolderTheyAreTold() {
        XCTAssertTrue(HookInstaller.installHooks(for: .codex, cliPath: cli, file: hooks).ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.config.path))
        XCTAssertEqual(HookInstaller.hooksSetUp(for: .codex, cliPath: cli, file: hooks), true)
        XCTAssertTrue(HookInstaller.removeHooks(for: .codex, file: hooks).ok)
        XCTAssertEqual(HookInstaller.hooksSetUp(for: .codex, cliPath: cli, file: hooks), false)
    }

    func testTheLiveTrustNameIsCodexsHomeResolvedThenTheHooksFile() {
        XCTAssertEqual(HookInstaller.CodexFiles.live.trustName,
                       Paths.codexHome.resolvingSymlinksInPath().appendingPathComponent("hooks.json").path)
        XCTAssertEqual(HookInstaller.CodexFiles.live.config.lastPathComponent, "config.toml")
    }

    func testCodexIsInstalledWhenItsHomeIsADirectory() throws {
        XCTAssertFalse(HookInstaller.codexInstalled(home: dir.appendingPathComponent("no-such")))
        XCTAssertFalse(HookInstaller.codexInstalled(home: URL(fileURLWithPath: cli)), "a file is not a home")
        XCTAssertTrue(HookInstaller.codexInstalled(home: dir))
    }

    /// `install-hooks` from a terminal: Claude Code's hooks, and Codex's only
    /// when Codex is there, which is said rather than failed.
    func testInstallAllSkipsAnAbsentCodexWithAWord() {
        let missing = HookInstaller.installAllHooks(cliPath: dir.appendingPathComponent("gone").path,
                                                    installed: { _ in false })
        XCTAssertFalse(missing.ok, "Claude's install failed on the missing CLI")
        XCTAssertTrue(missing.lines.contains(Loc.hookInstall.codexNotInstalledSkipped))
    }

    // MARK: the process

    private func proc(_ pid: Int32, _ ppid: Int32, _ name: String, _ path: String?) -> ProcWalk.ProcInfo {
        ProcWalk.ProcInfo(pid: pid, ppid: ppid, name: name, path: path)
    }

    func testTheWalkFindsCodexInItsRealShapes() {
        XCTAssertTrue(ProcWalk.isCodexPath("/Users/u/.codex/packages/standalone/releases/0.157.0-aarch64-apple-darwin/bin/codex"))
        XCTAssertTrue(ProcWalk.isCodexPath("/Users/u/.local/bin/codex"))
        XCTAssertTrue(ProcWalk.isCodexPath("/Applications/ChatGPT.app/Contents/Resources/codex"))
        XCTAssertFalse(ProcWalk.isCodexPath("/bin/zsh"))
        XCTAssertFalse(ProcWalk.isCodexPath("/Users/u/.local/bin/claude"))

        let terminal = [
            proc(500, 400, "sh", "/bin/sh"),
            proc(400, 300, "codex", "/Users/u/.codex/packages/standalone/releases/0.157.0-aarch64-apple-darwin/bin/codex"),
            proc(300, 200, "zsh", "/bin/zsh"),
            proc(200, 1, "Terminal", "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
        ]
        let origin = ProcWalk.classify(terminal)
        XCTAssertEqual(origin.agentPid, 400)
        XCTAssertEqual(origin.agent, .codex)
        XCTAssertEqual(origin.hostBundlePath, "/System/Applications/Utilities/Terminal.app")

        let app = [
            proc(500, 400, "sh", "/bin/sh"),
            proc(400, 300, "codex", "/Applications/ChatGPT.app/Contents/Resources/codex"),
            proc(300, 1, "ChatGPT", "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"),
        ]
        let inApp = ProcWalk.classify(app)
        XCTAssertEqual(inApp.agentPid, 400)
        XCTAssertEqual(inApp.agent, .codex)
        XCTAssertEqual(inApp.hostBundlePath, "/Applications/ChatGPT.app", "the app that hosts it is the host")
    }

    /// One agent can run the other. The nearest agent process is the one
    /// whose hooks fire, and a hook that says who it is looks for that one.
    func testTheNearestAgentWinsUnlessTheHookSaysOtherwise() {
        let codexUnderClaude = [
            proc(600, 500, "sh", "/bin/sh"),
            proc(500, 400, "codex", "/Users/u/.local/bin/codex"),
            proc(400, 300, "sh", "/bin/sh"),
            proc(300, 200, "claude", "/Users/u/.local/bin/claude"),
            proc(200, 1, "Terminal", "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
        ]
        let nearest = ProcWalk.classify(codexUnderClaude)
        XCTAssertEqual(nearest.agent, .codex)
        XCTAssertEqual(nearest.agentPid, 500)
        let told = ProcWalk.classify(codexUnderClaude, agent: .claude)
        XCTAssertEqual(told.agent, .claude)
        XCTAssertEqual(told.agentPid, 300)
        let none = ProcWalk.classify([proc(600, 1, "sh", "/bin/sh")], agent: .codex)
        XCTAssertNil(none.agentPid)
        XCTAssertNil(none.agent)
    }

    /// Copilot and OpenCode are known by their process names: `copilot`,
    /// and `opencode`, `opencode-cli` or `.opencode`.
    func testTheWalkKnowsCopilotAndOpenCodeByName() {
        let copilot = [
            proc(600, 500, "mysidepulse", nil),
            proc(500, 400, "copilot", "/Users/u/Library/Caches/github-copilot-sdk/cli/1.0.88/copilot"),
            proc(400, 1, "github", "/Applications/GitHub Copilot.app/Contents/MacOS/github"),
        ]
        XCTAssertEqual(ProcWalk.classify(copilot).agent, .copilot)
        XCTAssertEqual(ProcWalk.classify(copilot).agentPid, 500)
        for name in ["opencode", "opencode-cli", ".opencode"] {
            let server = [proc(700, 650, "mysidepulse", nil), proc(650, 1, name, nil)]
            XCTAssertEqual(ProcWalk.classify(server).agent, .opencode, name)
            XCTAssertEqual(ProcWalk.classify(server).agentPid, 650, name)
        }
        let claudeUnderCopilot = [
            proc(600, 500, "claude", "/Users/u/.local/bin/claude"),
            proc(500, 1, "copilot", "/Users/u/.local/bin/copilot"),
        ]
        XCTAssertEqual(ProcWalk.classify(claudeUnderCopilot).agent, .claude, "the nearest agent wins")
        XCTAssertNil(ProcWalk.classify([proc(600, 1, "opencodex", nil)]).agent, "a name, not a prefix")
    }

    // MARK: the hook

    func tempJournal() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mysidepulse-codex-hook-\(UUID().uuidString)/journal.jsonl")
    }

    func testTheHookRecordsWhoFiredIt() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let payload = #"{"hook_event_name":"Interrupt","session_id":"s1","turn_id":"t1","cwd":"/tmp","model":"gpt"}"#
        func line(origin: ProcWalk.Origin?, agent: AgentKind?) throws -> JournalEvent {
            try? FileManager.default.removeItem(at: url)
            XCTAssertEqual(HookCommand.run(input: Data(payload.utf8), environment: [:], journalURL: url,
                                           now: Date(), origin: origin, agent: agent), 0)
            let raw = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").first
            return try XCTUnwrap(JournalCodec.decodeLine(Data(String(raw!).utf8)))
        }
        let flagged = try line(origin: ProcWalk.Origin(agentPid: 77, agent: .codex), agent: .codex)
        XCTAssertEqual(flagged.agent, .codex)
        XCTAssertEqual(flagged.agentPid, 77)
        XCTAssertEqual(flagged.event, .interrupt)
        let walked = try line(origin: ProcWalk.Origin(agentPid: 77, agent: .codex), agent: nil)
        XCTAssertEqual(walked.agent, .codex, "no flag: the chain says")
        let bare = try line(origin: ProcWalk.Origin(agentPid: 42, agent: nil), agent: nil)
        XCTAssertEqual(bare.agent, .claude, "no flag and no agent found: Claude, as every line always was")
        let flagWins = try line(origin: ProcWalk.Origin(agentPid: 42, agent: .claude), agent: .codex)
        XCTAssertEqual(flagWins.agent, .codex)
    }

    // MARK: the doctor

    static let trustName = "/Users/me/.codex/hooks.json"

    /// `codexConfig` is config.toml's text: nil when it cannot be read, and by
    /// default whatever trusts every entry of ours `codexRoot` holds.
    func probes(codexRoot: [String: Any]?, codexConfig: String?? = .none) -> Doctor.Probes {
        let trusted = codexRoot.flatMap { root in
            CodexHookTrust.trusting("", entries: CodexHookTrust.ourEntries(hooksFile: Self.trustName, root: root)
                .map(\.entry), ourHashes: [])
        } ?? ""
        return Doctor.Probes(
            appResponse: { ControlResponse(ok: true, mode: "auto", loginItem: "enabled") },
            settingsRoot: {
                HookConfig.install(into: [:], command: "/Applications/MySidepulse.app/Contents/MacOS/mysidepulse hook")
            },
            codexHooksRoot: { codexRoot },
            codexConfigText: { codexConfig ?? trusted },
            codexHooksTrustName: Self.trustName,
            binaryExists: { !$0.contains("gone") },
            journalWritable: { true },
            lastEventAge: { 42 })
    }

    func codexLine(_ report: Doctor.Report) -> String {
        report.lines.first { $0.contains("codex hooks") } ?? ""
    }

    func testTheCodexLineIsAWordUntilSetUpAndACheckOnceItIs() {
        let command = "/Applications/MySidepulse.app/Contents/MacOS/mysidepulse hook --agent codex"
        let full = HookConfig.install(into: [:], command: command, agent: .codex)

        // Nothing of ours at hooks.json passes with a "not set up" sentence, whether or not Codex itself
        // is on this Mac.
        let absent = Doctor.run(probes(codexRoot: [:]))
        XCTAssertEqual(absent.failures, 0)
        XCTAssertTrue(codexLine(absent).hasPrefix("[OK]"), codexLine(absent))
        XCTAssertTrue(codexLine(absent).contains("not set up"), codexLine(absent))

        // A hooks.json that is there and cannot be read is a real failure, distinct from never having one.
        let unreadable = Doctor.run(probes(codexRoot: nil))
        XCTAssertEqual(unreadable.failures, 1)
        XCTAssertTrue(codexLine(unreadable).hasPrefix("[FAIL]") && codexLine(unreadable).contains("hooks.json"),
                      codexLine(unreadable))

        let good = Doctor.run(probes(codexRoot: full))
        XCTAssertEqual(good.failures, 0, good.lines.joined(separator: "\n"))
        XCTAssertTrue(codexLine(good).contains("12 events") && codexLine(good).contains("trusted"), codexLine(good))

        var partial = full
        var hooks = partial["hooks"] as! [String: Any]
        hooks.removeValue(forKey: "Interrupt")
        partial["hooks"] = hooks
        let missing = Doctor.run(probes(codexRoot: partial))
        XCTAssertTrue(codexLine(missing).hasPrefix("[FAIL]") && codexLine(missing).contains("Interrupt"))

        let stale = HookConfig.install(into: [:], command: "/gone/MySidepulse.app/Contents/MacOS/mysidepulse hook --agent codex",
                                       agent: .codex)
        let staleReport = Doctor.run(probes(codexRoot: stale))
        XCTAssertTrue(codexLine(staleReport).hasPrefix("[FAIL]") && codexLine(staleReport).contains("missing binary"))

        // Every event there and pointing at a binary that exists, and Codex
        // has not trusted them: Codex never runs them, so the check fails.
        let untrusted = Doctor.run(probes(codexRoot: full, codexConfig: ""))
        XCTAssertEqual(untrusted.failures, 1, untrusted.lines.joined(separator: "\n"))
        XCTAssertTrue(codexLine(untrusted).hasPrefix("[FAIL]") && codexLine(untrusted).contains("Not trusted")
                      && codexLine(untrusted).contains("Interrupt"), codexLine(untrusted))
        let unknown = Doctor.run(probes(codexRoot: full, codexConfig: .some(nil)))
        XCTAssertTrue(codexLine(unknown).hasPrefix("[FAIL]") && codexLine(unknown).contains("config.toml"),
                      codexLine(unknown))
        XCTAssertTrue(codexLine(Doctor.run(probes(codexRoot: [:], codexConfig: .some(nil)))).hasPrefix("[OK]"),
                      "nothing of ours in hooks.json: config.toml is not our business")

        XCTAssertEqual(Doctor.run(probes(codexRoot: full)).checks.count, 12,
                       "app, auto-start, hooks installed, hook binary, hook command, codex hooks, " +
                       "copilot hooks, opencode plugin, journal, last event, device, notifications")
    }
}

import XCTest
@testable import MySidepulsePlatform
@testable import MySidepulseCore

final class DoctorTests: XCTestCase {
    func probes() -> Doctor.Probes {
        Doctor.Probes(
            appResponse: { ControlResponse(ok: true, mode: "auto",
                                           devices: [DeviceStatus(name: "SidePulse", path: "/Volumes/SidePulse",
                                                                  leds: 8, stalled: false)],
                                           loginItem: "enabled") },
            settingsRoot: {
                HookConfig.install(into: [:],
                                   command: "/Applications/MySidepulse.app/Contents/MacOS/mysidepulse hook")
            },
            binaryExists: { _ in true },
            journalWritable: { true },
            lastEventAge: { 42 })
    }

    func testAllGreen() {
        let report = Doctor.run(probes())
        XCTAssertEqual(report.failures, 0, report.lines.joined(separator: "\n"))
        XCTAssertTrue(report.lines.allSatisfy { $0.hasPrefix("[OK]") })
    }

    func testFailuresAreCountedAndNamed() {
        var p = probes()
        p.appResponse = { nil }
        let report = Doctor.run(p)
        XCTAssertEqual(report.failures, 2, "app down fails the app and auto-start checks")
        XCTAssertTrue(report.lines.contains { $0.hasPrefix("[FAIL]") && $0.contains("app") })
        XCTAssertTrue(report.lines.contains { $0.hasPrefix("[FAIL]") && $0.contains("auto-start") })
    }

    /// The switch now controls crash restart too, so a report that only said
    /// "disabled" would understate what is off.
    func testAutoStartOffSaysWhatIsLost() {
        var p = probes()
        p.appResponse = { ControlResponse(ok: true, mode: "auto",
                                          loginItem: "registered, but this process was not "
                                                   + "started by it: no crash restart") }
        let report = Doctor.run(p)
        XCTAssertTrue(report.lines.contains {
            $0.hasPrefix("[FAIL]") && $0.contains("auto-start & restart")
                && $0.hasSuffix("no crash restart")
        }, report.lines.joined(separator: "\n"))
    }

    /// The settings window shows every detail as a tooltip and copies it into
    /// the Health report, and no sentence the window shows carries a long dash.
    func testEveryDetailIsASentenceTheWindowMayShow() {
        let longDashes: Set<Character> = ["—", "–", "‒", "―", "‐", "‑", "−"]
        var down = probes()
        down.appResponse = { nil }
        var unreadable = probes()
        unreadable.settingsRoot = { nil }
        var stale = probes()
        stale.binaryExists = { _ in false }
        var off = probes()
        off.appResponse = { ControlResponse(ok: true, mode: "auto", loginItem: "enabled",
                                            notify: NotifyStatus(enabled: false, server: K.notifyServerDefault,
                                                                 topicMasked: "(none)", topicUsable: false)) }
        var unusable = probes()
        unusable.appResponse = { ControlResponse(ok: true, mode: "auto", loginItem: "enabled",
                                                 notify: NotifyStatus(enabled: true, server: "https://ntfy.sh",
                                                                      topicMasked: "not a…", topicUsable: false)) }
        var copilotOn = probes()
        copilotOn.copilotHooksRoot = { HookConfig.copilotFile(cliPath: "/Applications/MySidepulse.app/Contents/MacOS/mysidepulse") }
        var copilotDisabled = copilotOn
        copilotDisabled.copilotHooksDisabled = { true }
        var copilotUnreadable = probes()
        copilotUnreadable.copilotHooksRoot = { nil }
        var opencodeOn = probes()
        opencodeOn.opencodePluginPresent = { true }
        opencodeOn.opencodePluginCurrent = { true }
        var opencodeStale = opencodeOn
        opencodeStale.opencodePluginCurrent = { false }
        var claudeNotSetUp = probes()
        claudeNotSetUp.settingsRoot = { [:] }
        claudeNotSetUp.codexHooksRoot = {
            HookConfig.install(into: [:],
                               command: "/Applications/MySidepulse.app/Contents/MacOS/mysidepulse hook --agent codex",
                               agent: .codex)
        }
        for language in Language.allCases {
            let saved = Loc.language
            Loc.language = language
            defer { Loc.language = saved }
            for p in [probes(), down, unreadable, stale, off, unusable, copilotOn, copilotDisabled,
                      copilotUnreadable, opencodeOn, opencodeStale, claudeNotSetUp] {
                for check in Doctor.run(p).checks {
                    XCTAssertFalse(check.detail.contains { longDashes.contains($0) },
                                   "\(language) \(check.name): \(check.detail)")
                }
            }
        }
    }

    /// The check names are identifiers the CLI prints and the Health page
    /// matches on, so they are the same whatever the window's language is.
    func testCheckNamesDoNotTranslate() {
        let saved = Loc.language
        defer { Loc.language = saved }
        Loc.language = .en
        let english = Doctor.run(probes()).checks.map(\.name)
        Loc.language = .fr
        let french = Doctor.run(probes()).checks.map(\.name)
        XCTAssertEqual(english, french)
    }

    func testNotificationsOffAreReportedNotFailed() {
        var p = probes()
        p.appResponse = { ControlResponse(ok: true, mode: "auto", loginItem: "enabled",
                                          notify: NotifyStatus(enabled: false, server: K.notifyServerDefault,
                                                               topicMasked: "(none)", topicUsable: false)) }
        let report = Doctor.run(p)
        XCTAssertEqual(report.failures, 0, "deliberately off is not broken")
        XCTAssertTrue(report.lines.contains { $0.contains("notifications") && $0.contains("off") },
                      report.lines.joined(separator: "\n"))
    }

    func testNotificationsOnAreReportedWithTheirTopic() throws {
        var p = probes()
        p.appResponse = { ControlResponse(ok: true, mode: "auto", loginItem: "enabled",
                                          notify: NotifyStatus(enabled: true, server: "https://ntfy.sh",
                                                               topicMasked: "cc-abc…", topicUsable: true)) }
        let report = Doctor.run(p)
        XCTAssertEqual(report.failures, 0)
        let line = try XCTUnwrap(report.lines.first { $0.contains("notifications") })
        XCTAssertTrue(line.contains("cc-abc…"), line)
        XCTAssertFalse(line.contains("cc-abc123"), "doctor output must be safe to paste")
    }

    /// The one real failure mode: config.json edited by hand into something
    /// that cannot be posted to. Silence would otherwise look like "no alerts".
    func testAnUnusableTopicIsAFailure() {
        var p = probes()
        p.appResponse = { ControlResponse(ok: true, mode: "auto", loginItem: "enabled",
                                          notify: NotifyStatus(enabled: true, server: "https://ntfy.sh",
                                                               topicMasked: "not a…", topicUsable: false)) }
        let report = Doctor.run(p)
        XCTAssertTrue(report.lines.contains { $0.hasPrefix("[FAIL]") && $0.contains("notifications") },
                      report.lines.joined(separator: "\n"))
    }

    // MARK: Copilot

    func testCopilotNotInstalledPassesWithAWord() {
        let report = Doctor.run(probes())
        XCTAssertEqual(report.failures, 0)
        XCTAssertTrue(report.lines.contains { $0.hasPrefix("[OK]") && $0.contains("copilot hooks") })
    }

    func testCopilotWithEveryEventSubscribedPasses() {
        var p = probes()
        p.copilotHooksRoot = { HookConfig.copilotFile(cliPath: "/Applications/MySidepulse.app/Contents/MacOS/mysidepulse") }
        let report = Doctor.run(p)
        XCTAssertTrue(report.lines.contains { $0.hasPrefix("[OK]") && $0.contains("copilot hooks") },
                      report.lines.joined(separator: "\n"))
    }

    func testCopilotMissingAnEventIsAFailure() {
        var p = probes()
        p.copilotHooksRoot = {
            var root = HookConfig.copilotFile(cliPath: "/Applications/MySidepulse.app/Contents/MacOS/mysidepulse")
            var hooks = root["hooks"] as! [String: Any]
            hooks.removeValue(forKey: "sessionEnd")
            root["hooks"] = hooks
            return root
        }
        let report = Doctor.run(p)
        XCTAssertTrue(report.lines.contains { $0.hasPrefix("[FAIL]") && $0.contains("sessionEnd") })
    }

    func testCopilotDisableAllHooksIsAFailureEvenWithEveryEventSubscribed() {
        var p = probes()
        p.copilotHooksRoot = { HookConfig.copilotFile(cliPath: "/Applications/MySidepulse.app/Contents/MacOS/mysidepulse") }
        p.copilotHooksDisabled = { true }
        let report = Doctor.run(p)
        XCTAssertTrue(report.lines.contains { $0.hasPrefix("[FAIL]") && $0.contains("copilot hooks") },
                      report.lines.joined(separator: "\n"))
    }

    /// `disableAllHooks` is Copilot's own setting: with nothing of ours in the file it turns nothing of
    /// ours off, so the line passes as not set up, and it does not stand in for Claude Code's hooks.
    func testCopilotDisableAllHooksWithNothingOfOursIsNotSetUp() {
        var p = probes()
        p.settingsRoot = { [:] }
        p.copilotHooksRoot = { [:] }
        p.copilotHooksDisabled = { true }
        let report = Doctor.run(p)
        let all = report.lines.joined(separator: "\n")
        XCTAssertTrue(report.lines.contains { $0.hasPrefix("[OK]") && $0.contains("copilot hooks") && $0.contains("not set up") }, all)
        XCTAssertTrue(report.lines.contains { $0.hasPrefix("[FAIL]") && $0.contains("hooks installed") }, all)
    }

    func testCopilotUnparseableFileIsAFailure() {
        var p = probes()
        p.copilotHooksRoot = { nil }
        let report = Doctor.run(p)
        XCTAssertTrue(report.lines.contains { $0.hasPrefix("[FAIL]") && $0.contains("copilot hooks") })
    }

    // MARK: OpenCode

    func testOpenCodeNotInstalledPassesWithAWord() {
        let report = Doctor.run(probes())
        XCTAssertTrue(report.lines.contains { $0.hasPrefix("[OK]") && $0.contains("opencode plugin") })
    }

    func testOpenCodeCurrentPluginPasses() {
        var p = probes()
        p.opencodePluginPresent = { true }
        p.opencodePluginCurrent = { true }
        let report = Doctor.run(p)
        XCTAssertTrue(report.lines.contains { $0.hasPrefix("[OK]") && $0.contains("opencode plugin") })
    }

    func testOpenCodeAbsentPluginPassesWithNotSetUp() {
        var p = probes()
        p.opencodePluginPresent = { false }
        let report = Doctor.run(p)
        XCTAssertTrue(report.lines.contains { $0.hasPrefix("[OK]") && $0.contains("opencode plugin") },
                      "nothing of ours at the plugin path passes, whether or not OpenCode is on this Mac")
    }

    func testOpenCodeStalePluginIsAFailure() {
        var p = probes()
        p.opencodePluginPresent = { true }
        p.opencodePluginCurrent = { false }
        let report = Doctor.run(p)
        XCTAssertTrue(report.lines.contains { $0.hasPrefix("[FAIL]") && $0.contains("opencode plugin") })
    }

    // MARK: Claude Code hooks mirror the Health rule

    func testClaudeHooksFailEmptyWhenNoAgentAtAllIsSetUp() {
        var p = probes()
        p.settingsRoot = { [:] }
        let report = Doctor.run(p)
        XCTAssertTrue(report.lines.contains { $0.hasPrefix("[FAIL]") && $0.contains("hooks installed") },
                      "nothing of any agent's is set up: the strip follows nothing, so this stays red")
    }

    func testClaudeHooksPassEmptyOnceAnotherAgentHasSomething() {
        var p = probes()
        p.settingsRoot = { [:] }
        p.codexHooksRoot = {
            HookConfig.install(into: [:],
                               command: "/Applications/MySidepulse.app/Contents/MacOS/mysidepulse hook --agent codex",
                               agent: .codex)
        }
        let report = Doctor.run(p)
        XCTAssertTrue(report.lines.contains { $0.hasPrefix("[OK]") && $0.contains("hooks installed") },
                      "the owner may be using Codex instead of Claude Code")
    }

    func testUnreadableClaudeSettingsAreAFailureEvenWithAnotherAgentSetUp() {
        var p = probes()
        p.settingsRoot = { nil }
        p.codexHooksRoot = {
            HookConfig.install(into: [:],
                               command: "/Applications/MySidepulse.app/Contents/MacOS/mysidepulse hook --agent codex",
                               agent: .codex)
        }
        let report = Doctor.run(p)
        XCTAssertTrue(report.lines.contains { $0.hasPrefix("[FAIL]") && $0.contains("hooks installed") },
                      "a settings.json that cannot be read is broken, not merely unused")
    }

    func testMissingHookEventIsAFailure() {
        var p = probes()
        p.settingsRoot = {
            var root = HookConfig.install(into: [:],
                command: "/Applications/MySidepulse.app/Contents/MacOS/mysidepulse hook")
            var hooks = root["hooks"] as! [String: Any]
            hooks.removeValue(forKey: "SubagentStart")
            root["hooks"] = hooks
            return root
        }
        let report = Doctor.run(p)
        XCTAssertTrue(report.lines.contains { $0.hasPrefix("[FAIL]") && $0.contains("SubagentStart") })
    }
}

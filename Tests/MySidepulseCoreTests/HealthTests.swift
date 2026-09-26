import XCTest
@testable import MySidepulseCore

/// The Health page's rules: which lines the Health table holds and in which colour, which readings the
/// Information table holds, how long both may grow, and which files are this app's crash reports. The
/// page only draws what these build.
final class HealthTests: XCTestCase {
    /// A MySidepulse that works: hooks in, a strip plugged in, the phone off by choice.
    private func healthy() -> HealthFacts {
        var facts = HealthFacts()
        facts.notificationsGranted = true
        facts.claudeHooks = .setUp
        facts.hookBinary = .init(ok: true, detail: "binary exists")
        facts.hookCommand = "/Applications/MySidepulse.app/Contents/MacOS/mysidepulse hook"
        facts.journal = .init(ok: true, detail: "append works")
        facts.lastHookEventSeconds = 12
        facts.terminalHookSetUp = true
        facts.devices = [.init(name: "SidePulseDot", leds: 8, path: "/Volumes/SidePulseDot", stalled: false)]
        facts.display = .working
        facts.phone = .disabled
        facts.launchAgent = .enabled
        facts.control = .init(ok: true, detail: "running")
        return facts
    }

    private func check(_ id: String, _ facts: HealthFacts) -> HealthRow? {
        HealthReport.checks(for: facts).first { $0.id == id }
    }

    private func reading(_ id: String, _ facts: HealthFacts) -> InfoRow? {
        HealthReport.readings(for: facts).first { $0.id == id }
    }

    // MARK: The Health table

    func testAWorkingAppIsAllGreenAndHoldsOnlyWhatItNeeds() {
        let checks = HealthReport.checks(for: healthy())
        XCTAssertEqual(checks.map(\.id), ["claude code hooks", "terminal hook", "notifications permission",
                                          "strip", "launch agent"])
        XCTAssertTrue(checks.allSatisfy { $0.level == .good })
        XCTAssertEqual(checks.warnings, [])
    }

    func testWhatHasNotBeenReadIsLeftOut() {
        XCTAssertEqual(HealthReport.checks(for: HealthFacts()), [])
        XCTAssertEqual(HealthReport.readings(for: HealthFacts()), [])
    }

    func testMissingClaudeHooksAreRedAndSayWhichButton() {
        withLanguage(.en) {
            var facts = healthy()
            facts.claudeHooks = .missing
            XCTAssertEqual(check("claude code hooks", facts)?.level, .failure)
            XCTAssertEqual(check("claude code hooks", facts)?.word, "Disabled")
            XCTAssertEqual(check("claude code hooks", facts)?.fix, Loc.settings.system.withoutHooksWarning)
        }
    }

    func testUnreadableClaudeSettingsAreRed() {
        var facts = healthy()
        facts.claudeHooks = .unreadable
        XCTAssertEqual(check("claude code hooks", facts)?.level, .failure)
        XCTAssertEqual(check("claude code hooks", facts)?.fix, Loc.settings.system.settingsUnreadableWarning)
    }

    func testHooksPointingAtAMissingCopyOrUnableToWriteAreRedOnTheirOneLine() {
        var facts = healthy()
        facts.hookBinary = .init(ok: false, detail: "binary missing")
        XCTAssertEqual(check("claude code hooks", facts)?.level, .failure)
        XCTAssertEqual(check("claude code hooks", facts)?.fix, Loc.settings.health.hookCommandFix)
        facts = healthy()
        facts.journal = .init(ok: false, detail: "cannot append")
        XCTAssertEqual(check("claude code hooks", facts)?.level, .failure)
        XCTAssertEqual(check("claude code hooks", facts)?.fix, Loc.settings.health.journalFix)
    }

    // MARK: Copilot

    func testCopilotHooksAreALineOnlyWhileCopilotIsOnThisMacOrSetUp() {
        var facts = healthy()
        XCTAssertNil(check("copilot hooks", facts), "not on this Mac, nothing set up: no line")
        facts.copilotInstalled = false
        facts.copilotHooks = .setUp
        XCTAssertNotNil(check("copilot hooks", facts), "set up keeps the line even once Copilot is gone")
        facts.copilotHooks = .missing
        facts.copilotInstalled = true
        XCTAssertNotNil(check("copilot hooks", facts))
    }

    func testMissingCopilotHooksAreOrangeAndSayWhichButton() {
        withLanguage(.en) {
            var facts = healthy()
            facts.copilotInstalled = true
            facts.copilotHooks = .missing
            XCTAssertEqual(check("copilot hooks", facts)?.level, .warning)
            XCTAssertEqual(check("copilot hooks", facts)?.word, "Disabled")
            XCTAssertEqual(check("copilot hooks", facts)?.fix, Loc.settings.system.withoutCopilotHooksWarning)
        }
    }

    func testAStaleOrUnreadableCopilotFileIsInvalidAndOrange() {
        var facts = healthy()
        facts.copilotInstalled = true
        facts.copilotHooks = .unreadable
        XCTAssertEqual(check("copilot hooks", facts)?.level, .warning)
        XCTAssertEqual(check("copilot hooks", facts)?.fix, Loc.settings.system.copilotHooksInvalidWarning)
    }

    func testDisableAllHooksTurnsTheSetUpLineOrangeWithItsOwnFix() {
        var facts = healthy()
        facts.copilotInstalled = true
        facts.copilotHooks = .setUp
        facts.copilotHooksDisabled = true
        XCTAssertEqual(check("copilot hooks", facts)?.level, .warning)
        XCTAssertEqual(check("copilot hooks", facts)?.fix, Loc.settings.system.copilotHooksDisabledWarning)
        facts.copilotHooksDisabled = false
        XCTAssertEqual(check("copilot hooks", facts)?.level, .good)
    }

    // MARK: OpenCode

    func testOpencodePluginIsALineOnlyWhileOpenCodeIsOnThisMacOrSetUp() {
        var facts = healthy()
        XCTAssertNil(check("opencode plugin", facts))
        facts.opencodeInstalled = true
        facts.opencodeHooks = .missing
        XCTAssertNotNil(check("opencode plugin", facts))
    }

    func testAPluginOfAnotherCopyIsInvalidNotMissing() {
        withLanguage(.en) {
            var facts = healthy()
            facts.opencodeInstalled = true
            facts.opencodeHooks = .unreadable
            XCTAssertEqual(check("opencode plugin", facts)?.level, .warning)
            XCTAssertEqual(check("opencode plugin", facts)?.word, "Invalid")
            XCTAssertEqual(check("opencode plugin", facts)?.fix, Loc.settings.system.opencodePluginInvalidWarning)
        }
    }

    func testAWorkingOpenCodePluginIsGreen() {
        var facts = healthy()
        facts.opencodeInstalled = true
        facts.opencodeHooks = .setUp
        XCTAssertEqual(check("opencode plugin", facts)?.level, .good)
    }

    func testTheOptionalGrantsAreOrange() {
        var facts = healthy()
        facts.terminalHookSetUp = false
        facts.notificationsGranted = false
        XCTAssertEqual(check("terminal hook", facts)?.level, .warning)
        XCTAssertEqual(check("notifications permission", facts)?.level, .warning)
    }

    func testNoStripAndAStalledStripAreOrange() {
        withLanguage(.en) {
            var facts = healthy()
            facts.devices = []
            XCTAssertEqual(check("strip", facts)?.level, .warning)
            XCTAssertEqual(check("strip", facts)?.word, "Missing")
            facts.devices = [.init(name: "SidePulseDot", leds: 8, path: "/Volumes/SidePulseDot", stalled: true)]
            XCTAssertEqual(check("strip", facts)?.level, .warning)
            XCTAssertEqual(check("strip", facts)?.fix, Loc.settings.strip.stalledWarning(name: "SidePulseDot"))
        }
    }

    func testALaunchAgentThatIsOffOrNotInChargeIsOrange() {
        withLanguage(.en) {
            var facts = healthy()
            facts.launchAgent = .disabled
            XCTAssertEqual(check("launch agent", facts)?.level, .warning)
            XCTAssertEqual(check("launch agent", facts)?.fix, Loc.settings.health.launchAgentFix)
            facts.launchAgent = .notSupervised
            XCTAssertEqual(check("launch agent", facts)?.word, "Opened by hand")
            XCTAssertEqual(check("launch agent", facts)?.fix, Loc.settings.general.startupWarningOpenedByHand)
        }
    }

    func testThePhoneIsALineOnlyWhileItIsSwitchedOn() {
        var facts = healthy()
        XCTAssertNil(check("phone notifications", facts), "switched off is the user's choice, not a check")
        facts.phone = .enabled(detail: "on")
        XCTAssertEqual(check("phone notifications", facts)?.level, .good)
        facts.phone = .unusable(detail: "no topic")
        XCTAssertEqual(check("phone notifications", facts)?.level, .warning)
    }

    func testTheCommandLineIsALineOnlyWhileItCannotReachTheApp() {
        var facts = healthy()
        XCTAssertNil(check("command line", facts))
        facts.control = .init(ok: false, detail: "control socket unreachable")
        XCTAssertEqual(check("command line", facts)?.level, .warning)
    }

    func testACrashIsALineOnlyWhileThereIsOne() {
        withLanguage(.en) {
            var facts = healthy()
            XCTAssertNil(check("crashes", facts))
            let crash = Date(timeIntervalSince1970: 1_790_000_000)
            facts.recentCrashes = [crash]
            XCTAssertEqual(check("crashes", facts)?.level, .warning)
            XCTAssertEqual(check("crashes", facts)?.word, "1")
            XCTAssertEqual(check("crashes", facts)?.detail, "Last one \(HealthReport.stamp(crash))")
        }
    }

    // MARK: The Information table

    func testTheReadingsOfAWorkingApp() {
        withLanguage(.en) {
            let readings = HealthReport.readings(for: healthy())
            XCTAssertEqual(readings.map(\.id), ["last hook event", "sessions", "commands", "showing"])
            XCTAssertEqual(reading("last hook event", healthy())?.value, "12 s ago")
            XCTAssertEqual(reading("sessions", healthy())?.value, "None")
        }
    }

    func testAReadingIsThereOnlyWhileWhatItReadsIsSetUp() {
        var facts = healthy()
        facts.claudeHooks = .missing
        facts.terminalHookSetUp = false
        facts.devices = []
        XCTAssertEqual(HealthReport.readings(for: facts), [])
    }

    func testReadingsAreTranslatedNeverTheEnginesWords() {
        withLanguage(.fr) {
            var facts = healthy()
            facts.sessions = [.init(id: "0123456789", phase: .init(state: "waiting", reason: "question"),
                                    ageSeconds: 125, cwd: "/tmp")]
            facts.jobs = [.init(id: "j", label: "make", phase: .init(state: "failed"),
                                acknowledged: true, ageSeconds: 7_200)]
            XCTAssertEqual(reading("sessions", facts)?.value, "1")
            XCTAssertEqual(reading("sessions", facts)?.detail, "01234567 Claude: A besoin de vous : une question, il y a 2 min")
            XCTAssertEqual(reading("commands", facts)?.detail, "make: Échouée, vue, il y a 2 h")
            XCTAssertEqual(reading("last hook event", facts)?.value, "il y a 12 s")
        }
    }

    func testAnUnknownEngineWordIsShownAsItComes() {
        XCTAssertEqual(HealthFacts.SessionPhase(state: "dreaming", reason: nil), .other("dreaming"))
        XCTAssertEqual(HealthFacts.JobPhase(state: "paused"), .other("paused"))
    }

    // MARK: Limits

    func testTheTablesStayShortInTheWorstCase() {
        var facts = healthy()
        facts.claudeHooks = .missing
        facts.codexInstalled = true
        facts.codexHooks = .missing
        facts.copilotInstalled = true
        facts.copilotHooks = .missing
        facts.opencodeInstalled = true
        facts.opencodeHooks = .missing
        facts.terminalHookSetUp = false
        facts.notificationsGranted = false
        facts.devices = [.init(name: "SidePulseDot", leds: 8, path: "/Volumes/SidePulseDot", stalled: true)]
        facts.launchAgent = .notSupervised
        facts.phone = .unusable(detail: "no topic")
        facts.control = .init(ok: false, detail: "control socket unreachable")
        facts.recentCrashes = [Date(), Date()]
        XCTAssertEqual(HealthReport.checks(for: facts).count, HealthLimits.checks,
                       "the worst case is exactly the limit: every agent installed and missing, both " +
                       "only-while-wrong lines, and a crash")
        XCTAssertLessThanOrEqual(HealthReport.checks(for: facts).count, HealthLimits.checks)

        var busy = healthy()
        busy.sessions = (0..<9).map { .init(id: "s\($0)", phase: .working, ageSeconds: 1, cwd: nil) }
        busy.jobs = (0..<9).map { .init(id: "j\($0)", label: nil, phase: .running, acknowledged: false, ageSeconds: 1) }
        XCTAssertLessThanOrEqual(HealthReport.readings(for: busy).count, HealthLimits.readings)
    }

    // MARK: Crash reports

    func testOnlyThisProcesssCrashReportsAreCounted() {
        XCTAssertTrue(HealthRules.isCrashReport(fileName: "MySidepulseApp-2026-09-21-101010.ips",
                                                process: "MySidepulseApp"))
        XCTAssertFalse(HealthRules.isCrashReport(fileName: "ExcUserFault_MySidepulseApp-2026-09-21-101010.ips",
                                                 process: "MySidepulseApp"))
        XCTAssertFalse(HealthRules.isCrashReport(fileName: "mysidepulse-2026-09-21-101010.ips",
                                                 process: "MySidepulseApp"))
        XCTAssertFalse(HealthRules.isCrashReport(fileName: "MySidepulseApp-notes.ips", process: "MySidepulseApp"))
    }
}

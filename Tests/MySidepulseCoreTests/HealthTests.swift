import XCTest
@testable import MySidepulseCore

/// The Health page's rules: which colour each state takes, what the overview sums up, which files are this
/// app's crash reports, and what the copied report says. The page only draws what these build.
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
        facts.mode = .auto
        facts.display = .working
        facts.battery = PowerState(percent: 80, plugged: true)
        facts.phone = .disabled
        facts.launchAgent = .enabled
        facts.control = .init(ok: true, detail: "running")
        facts.runningSeconds = 3_720
        facts.memoryBytes = 48 * 1_048_576
        facts.location = .applications
        facts.bundlePath = "/Applications/MySidepulse.app"
        return facts
    }

    private func row(_ id: String, _ facts: HealthFacts) -> HealthRow? {
        HealthReport.groups(for: facts).flatMap(\.rows).first { $0.id == id }
    }

    private func summary(_ facts: HealthFacts) -> HealthSummary {
        HealthSummary(groups: HealthReport.groups(for: facts))
    }

    // MARK: The overview

    func testAWorkingAppReadsEverythingWorks() {
        withLanguage(.en) {
            XCTAssertEqual(summary(healthy()).level, .good)
            XCTAssertEqual(HealthReport.summaryWord(summary(healthy())), "Everything works")
        }
    }

    func testRedWinsOverOrange() {
        withLanguage(.en) {
            var facts = healthy()
            facts.claudeHooks = .missing
            facts.terminalHookSetUp = false
            XCTAssertEqual(summary(facts).blocking, 1)
            XCTAssertEqual(summary(facts).toLookAt, 1)
            XCTAssertEqual(HealthReport.summaryWord(summary(facts)), "Not working: 1 problem")
        }
    }

    // MARK: Grants

    /// The strip never shows Claude without the hooks, so they are the one required grant.
    func testMissingClaudeHooksAreRedAndSayWhichButton() {
        withLanguage(.en) {
            var facts = healthy()
            facts.claudeHooks = .missing
            XCTAssertEqual(row("claude code hooks", facts)?.level, .failure)
            let group = HealthReport.groups(for: facts).first { $0.id == "claude code" }
            XCTAssertEqual(group?.warnings, [Loc.settings.system.withoutHooksWarning])
        }
    }

    func testUnreadableClaudeSettingsAreRed() {
        var facts = healthy()
        facts.claudeHooks = .unreadable
        XCTAssertEqual(row("claude code hooks", facts)?.level, .failure)
        XCTAssertEqual(row("claude code hooks", facts)?.fix, Loc.settings.system.settingsUnreadableWarning)
    }

    func testTheOptionalGrantsAreOrangeNeverBlue() {
        var facts = healthy()
        facts.terminalHookSetUp = false
        facts.notificationsGranted = false
        XCTAssertEqual(row("terminal hook", facts)?.level, .warning)
        XCTAssertEqual(row("notifications permission", facts)?.level, .warning)
        XCTAssertEqual(HealthRules.grant(held: false, required: false), .warning)
        XCTAssertEqual(HealthRules.grant(held: false, required: true), .failure)
        XCTAssertEqual(HealthRules.grant(held: true, required: true), .good)
    }

    /// A row that has not been read yet is not shown as unknown: it is not there.
    func testWhatHasNotBeenReadIsLeftOut() {
        let facts = HealthFacts()
        let ids = HealthReport.groups(for: facts).flatMap(\.rows).map(\.id)
        XCTAssertFalse(ids.contains("claude code hooks"))
        XCTAssertFalse(ids.contains("notifications permission"))
        XCTAssertFalse(ids.contains("strip"))
        XCTAssertTrue(ids.contains("last hook event"))
    }

    func testTheHookCommandIsJudgedOnlyOnceTheHooksAreThere() {
        var facts = healthy()
        facts.hookBinary = .init(ok: false, detail: "points at a missing binary")
        XCTAssertEqual(row("hook command", facts)?.level, .failure)
        XCTAssertEqual(row("hook command", facts)?.detail, facts.hookCommand)
        facts.claudeHooks = .missing
        XCTAssertNil(row("hook command", facts))
    }

    func testAJournalThatCannotBeWrittenIsRed() {
        var facts = healthy()
        facts.journal = .init(ok: false, detail: "cannot append")
        XCTAssertEqual(row("journal", facts)?.level, .failure)
    }

    // MARK: The strip and the phone

    func testNoStripAndAStalledStripAreOrange() {
        withLanguage(.en) {
            var facts = healthy()
            facts.devices = []
            XCTAssertEqual(row("strip", facts)?.level, .warning)
            XCTAssertEqual(row("strip", facts)?.word, "Missing")
            facts.devices = [.init(name: "SidePulseDot", leds: 8, path: "/Volumes/SidePulseDot", stalled: true)]
            XCTAssertEqual(row("strip SidePulseDot", facts)?.level, .warning)
            XCTAssertEqual(row("strip SidePulseDot", facts)?.detail, "/Volumes/SidePulseDot")
        }
    }

    /// Off is the user's choice; on and unable to post is a feature that does not work.
    func testThePhone() {
        var facts = healthy()
        XCTAssertEqual(row("phone notifications", facts)?.level, .info)
        facts.phone = .enabled(detail: "on, topic abc…")
        XCTAssertEqual(row("phone notifications", facts)?.level, .good)
        facts.phone = .unusable(detail: "on, topic abc…")
        XCTAssertEqual(row("phone notifications", facts)?.level, .warning)
    }

    func testTheModeIsTheUsersChoiceWhateverItIs() {
        var facts = healthy()
        facts.mode = .color("#331500")
        XCTAssertEqual(row("mode", facts)?.level, .info)
        XCTAssertEqual(row("mode", facts)?.detail, "#331500")
    }

    // MARK: Readings

    func testReadingsAreTranslatedNeverTheEnginesWords() {
        withLanguage(.fr) {
            var facts = healthy()
            facts.sessions = [.init(id: "0123456789", phase: .init(state: "waiting", reason: "question"),
                                    ageSeconds: 125, cwd: "/tmp")]
            facts.jobs = [.init(id: "j", label: "make", phase: .init(state: "failed"),
                                acknowledged: true, ageSeconds: 7_200)]
            XCTAssertEqual(row("session 0123456789", facts)?.word, "A besoin de vous : une question, il y a 2 min")
            XCTAssertEqual(row("session 0123456789", facts)?.label, "Session 01234567")
            XCTAssertEqual(row("job j", facts)?.word, "Échouée, vue, il y a 2 h")
            XCTAssertEqual(row("last hook event", facts)?.word, "il y a 12 s")
        }
    }

    func testAnUnknownEngineWordIsShownAsItComes() {
        XCTAssertEqual(HealthFacts.SessionPhase(state: "dreaming", reason: nil), .other("dreaming"))
        XCTAssertEqual(HealthFacts.JobPhase(state: "paused"), .other("paused"))
    }

    // MARK: The app

    func testALaunchAgentThatIsOffOrNotInChargeIsOrange() {
        withLanguage(.en) {
            var facts = healthy()
            facts.launchAgent = .disabled
            XCTAssertEqual(row("launch agent", facts)?.level, .warning)
            XCTAssertEqual(row("launch agent", facts)?.fix, Loc.settings.health.launchAgentFix)
            facts.launchAgent = .notSupervised
            XCTAssertEqual(row("launch agent", facts)?.fix, Loc.settings.general.startupWarningOpenedByHand)
        }
    }

    func testACommandThatCannotReachTheAppIsOrange() {
        var facts = healthy()
        facts.control = .init(ok: false, detail: "control socket unreachable")
        XCTAssertEqual(row("command line", facts)?.level, .warning)
    }

    func testCrashesAndWhereTheAppIsInstalled() {
        withLanguage(.en) {
            var facts = healthy()
            XCTAssertEqual(row("crashes", facts)?.word, "None")
            let crash = Date(timeIntervalSince1970: 1_790_000_000)
            facts.recentCrashes = [crash]
            XCTAssertEqual(row("crashes", facts)?.level, .warning)
            XCTAssertEqual(row("crashes", facts)?.detail, "Last one \(HealthReport.stamp(crash))")
            facts.location = .diskImage
            XCTAssertEqual(row("location", facts)?.level, .warning)
            XCTAssertEqual(row("running for", facts)?.word, "1 h 2 min")
            XCTAssertEqual(row("memory", facts)?.word, "48 MB")
        }
    }

    func testOnlyThisProcesssCrashReportsAreCounted() {
        XCTAssertTrue(HealthRules.isCrashReport(fileName: "MySidepulseApp-2026-09-21-101010.ips",
                                                process: "MySidepulseApp"))
        XCTAssertFalse(HealthRules.isCrashReport(fileName: "ExcUserFault_MySidepulseApp-2026-09-21-101010.ips",
                                                 process: "MySidepulseApp"))
        XCTAssertFalse(HealthRules.isCrashReport(fileName: "mysidepulse-2026-09-21-101010.ips",
                                                 process: "MySidepulseApp"))
        XCTAssertFalse(HealthRules.isCrashReport(fileName: "MySidepulseApp-notes.ips", process: "MySidepulseApp"))
    }

    func testWhereTheBundleIs() {
        XCTAssertEqual(HealthRules.location(bundlePath: "/Applications/MySidepulse.app", home: "/Users/a",
                                            readOnlyVolume: false), .applications)
        XCTAssertEqual(HealthRules.location(bundlePath: "/Volumes/MySidepulse/MySidepulse.app", home: "/Users/a",
                                            readOnlyVolume: true), .diskImage)
        XCTAssertEqual(HealthRules.location(bundlePath: "/private/var/folders/x/AppTranslocation/1/d/MySidepulse.app",
                                            home: "/Users/a", readOnlyVolume: true), .temporaryCopy)
        XCTAssertEqual(HealthRules.location(bundlePath: "/Users/a/Tools/MySidepulse.app", home: "/Users/a",
                                            readOnlyVolume: false), .elsewhere(folder: "Tools"))
    }

    // MARK: The report

    func testTheReportCarriesEveryRowAndNoRawTopic() {
        withLanguage(.en) {
            var facts = healthy()
            facts.phone = .enabled(detail: "on, topic abc…, server https://ntfy.sh")
            let text = HealthReport.text(appName: "MySidepulse", version: "1.4.0", system: "macOS 27.0.0",
                                         groups: HealthReport.groups(for: facts))
            XCTAssertTrue(text.hasPrefix("MySidepulse 1.4.0, macOS 27.0.0\nEverything works\n"))
            XCTAssertTrue(text.contains("[OK]   Claude Code hooks: Enabled"))
            XCTAssertTrue(text.contains("[INFO] Last hook event: 12 s ago"))
            XCTAssertTrue(text.contains("(on, topic abc…, server https://ntfy.sh)"))
        }
    }
}

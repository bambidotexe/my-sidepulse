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
        for language in Language.allCases {
            let saved = Loc.language
            Loc.language = language
            defer { Loc.language = saved }
            for p in [probes(), down, unreadable, stale, off, unusable] {
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

    /// What the Health page draws its mark from. Reading the detail sentence
    /// instead would have worked in one language only.
    func testTheDeviceAndNotificationChecksCarryTheirStateNotJustASentence() {
        let saved = Loc.language
        defer { Loc.language = saved }
        for language in Language.allCases {
            Loc.language = language

            var absent = probes()
            absent.appResponse = { ControlResponse(ok: true, mode: "auto", devices: [],
                                                  loginItem: "enabled") }
            XCTAssertEqual(nuance(of: "device", Doctor.run(absent)), .absent, "\(language)")

            var stalled = probes()
            stalled.appResponse = {
                ControlResponse(ok: true, mode: "auto",
                                devices: [DeviceStatus(name: "SidePulse", path: "/Volumes/SidePulse",
                                                       leds: 8, stalled: true)],
                                loginItem: "enabled")
            }
            XCTAssertEqual(nuance(of: "device", Doctor.run(stalled)), .stalled, "\(language)")
            XCTAssertEqual(nuance(of: "device", Doctor.run(probes())), Doctor.Check.Nuance.none,
                           "\(language)")

            var off = probes()
            off.appResponse = {
                ControlResponse(ok: true, mode: "auto", loginItem: "enabled",
                                notify: NotifyStatus(enabled: false, server: K.notifyServerDefault,
                                                     topicMasked: "(none)", topicUsable: false))
            }
            XCTAssertEqual(nuance(of: "notifications", Doctor.run(off)), .disabled, "\(language)")
        }
    }

    private func nuance(of name: String, _ report: Doctor.Report) -> Doctor.Check.Nuance? {
        report.checks.first { $0.name == name }?.nuance
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

import Foundation
import MySidepulseCore

public enum Doctor {
    public struct Probes {
        public var appResponse: () -> ControlResponse?
        public var settingsRoot: () -> [String: Any]?
        public var binaryExists: (String) -> Bool
        public var journalWritable: () -> Bool
        public var lastEventAge: () -> TimeInterval?
        public init(appResponse: @escaping () -> ControlResponse?,
                    settingsRoot: @escaping () -> [String: Any]?,
                    binaryExists: @escaping (String) -> Bool,
                    journalWritable: @escaping () -> Bool,
                    lastEventAge: @escaping () -> TimeInterval?) {
            self.appResponse = appResponse; self.settingsRoot = settingsRoot
            self.binaryExists = binaryExists; self.journalWritable = journalWritable
            self.lastEventAge = lastEventAge
        }
    }

    /// `detail` is a sentence the settings window shows as a row's tooltip and
    /// puts in the Health report, so it carries no long dash (`DoctorTests`).
    /// It is also translated, so nothing reads it back to decide anything: the
    /// Health page takes the strip and the phone from the engine's status, and
    /// from this only `ok` and the sentence.
    public struct Check: Equatable {
        public let ok: Bool
        public let name: String
        public let detail: String
    }

    public struct Report {
        public var checks: [Check] = []
        public var failures = 0
        /// The CLI's exact output shape, unchanged; the settings window reads
        /// `checks` instead of parsing these back.
        public var lines: [String] {
            checks.map { "\($0.ok ? "[OK]  " : "[FAIL]") \($0.name) — \($0.detail)" }
        }
        mutating func check(_ ok: Bool, _ name: String, _ detail: String) {
            checks.append(Check(ok: ok, name: name, detail: detail))
            if !ok { failures += 1 }
        }
    }

    public static func run(_ p: Probes) -> Report {
        let t = Loc.doctor
        var r = Report()
        let response = p.appResponse()
        r.check(response != nil, "app", response != nil
            ? t.appRunning(mode: response?.mode ?? "?")
            : t.controlSocketUnreachable)
        // One registration covers both jobs: the launch agent starts the app
        // at login *and* brings it back when it dies. Off means a crash takes
        // the strip and the phone notifications out until the next login —
        // so this check says which is missing rather than just "disabled".
        let login = response?.loginItem
        r.check(login == "enabled", "auto-start & restart",
                login.map { $0 == "enabled" ? t.launchAgentRegistered : $0 }
                    ?? t.unknownAppUnreachable)

        if let root = p.settingsRoot() {
            var missing: [String] = []
            var staleBinary = false
            for event in HookConfig.events {
                guard let command = HookConfig.installedCommand(in: root, event: event) else {
                    missing.append(event)
                    continue
                }
                let binary = String(command.dropLast(" hook".count))
                if !p.binaryExists(binary) { staleBinary = true }
            }
            r.check(missing.isEmpty, "hooks installed",
                    missing.isEmpty ? t.allEventsSubscribed(HookConfig.events.count)
                                    : t.missingEvents(missing.joined(separator: ", ")))
            r.check(!staleBinary, "hook binary",
                    staleBinary ? t.hookPointsAtMissingBinary : t.binaryExists)
            // Informational: what's actually in the user's settings right now,
            // so a stale or PATH-mangled command is visible at a glance
            // without having to open the file.
            r.check(true, "hook command",
                    HookConfig.installedCommand(in: root, event: HookConfig.events[0])
                        ?? t.hookCommandNotInstalled)
        } else {
            r.check(false, "hooks installed", t.settingsMissingOrUnparseable)
            r.check(false, "hook binary", t.settingsUnreadable)
            r.check(true, "hook command", t.hookCommandUnknown)
        }

        r.check(p.journalWritable(), "journal", t.journalAppend)
        if let age = p.lastEventAge() {
            r.check(true, "last event", t.lastEventAgo(seconds: Int(age.rounded())))
        } else {
            r.check(true, "last event", t.journalEmpty)
        }

        let devices = response?.devices ?? []
        r.check(true, "device", devices.isEmpty
            ? t.noVolumeMounted
            : devices.map { t.deviceDetail(name: $0.name, path: $0.path,
                                           leds: $0.leds, stalled: $0.stalled) }
                .joined(separator: "; "))
        // Deliberately off is not broken, so the failure here is narrow: the
        // user asked for notifications and they cannot be sent. Reachable only
        // by hand-editing config.json, since enabling through the CLI mints a
        // topic — but silence would otherwise be indistinguishable from
        // "nothing happened".
        switch response?.notify {
        case nil:
            r.check(true, "notifications", t.unknownAppUnreachable)
        case let status? where !status.enabled:
            r.check(true, "notifications", t.notificationsOff)
        case let status?:
            // The app validates its own config and reports a flag, so doctor
            // never needs the raw topic to say whether it works.
            r.check(status.topicUsable, "notifications", status.topicUsable
                ? t.notificationsOn(topicMasked: status.topicMasked, server: status.server)
                : t.notificationsUnusable(topicMasked: status.topicMasked, server: status.server))
        }
        return r
    }

    /// The probes against the real system, shared by the CLI and the settings
    /// window's Health page. `appResponse` goes through the control socket even
    /// when the caller *is* the app: the first check's meaning is "can a CLI
    /// reach the app", and answering it in-process would prove nothing.
    /// Callers must not run this on the app's main queue — the socket reply is
    /// produced by a `main.sync` hop, so a main thread blocked waiting here
    /// would deadlock into the timeout.
    public static func liveProbes() -> Probes {
        Probes(
            appResponse: { ControlClient.send(ControlRequest(cmd: "status"),
                                              socketPath: Paths.controlSocket.path) },
            settingsRoot: {
                // Same strict reader install-hooks/uninstall-hooks use — an
                // unparseable file collapses to nil here (doctor only needs
                // "can I read hooks or not"), rather than a second ad hoc
                // JSON-parsing implementation.
                guard let loaded = try? SettingsFile.load(at: Paths.claudeSettings) else { return nil }
                return loaded
            },
            binaryExists: { FileManager.default.isExecutableFile(atPath: $0) },
            journalWritable: {
                // Probe the directory with a scratch file — never the real
                // journal, which carries only real records (hook events and
                // the app's ack lines).
                try? FileManager.default.createDirectory(at: Paths.appSupport,
                                                         withIntermediateDirectories: true)
                let probe = Paths.appSupport.appendingPathComponent(".doctor-probe")
                defer { try? FileManager.default.removeItem(at: probe) }
                return JournalWriter.append(Data("probe".utf8), to: probe)
            },
            lastEventAge: {
                // Acks are the app's own lines; this check answers "are
                // hooks arriving", so only hook traffic counts.
                let events = JournalTailer.readAll(url: Paths.journal)
                guard let last = events.last(where: { $0.event != .parseError && $0.event != .ack })
                else { return nil }
                return Date().timeIntervalSince(last.loggedAt)
            })
    }
}

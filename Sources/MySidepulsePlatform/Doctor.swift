import Foundation
import MySidepulseCore

public enum Doctor {
    public struct Probes {
        public var appResponse: () -> ControlResponse?
        public var settingsRoot: () -> [String: Any]?
        /// Codex's `hooks.json`: `[:]` when it is missing, nil only when it is there and cannot be read.
        /// Nothing of ours in it passes with a "not set up" sentence, whether or not Codex itself is on
        /// this Mac (`docs/functional.md` §10, §11).
        public var codexHooksRoot: () -> [String: Any]?
        /// Codex's `config.toml`, where it records which hooks it trusts: `""` when it is missing, nil only
        /// when it is there and cannot be read as text. Read only while something of ours is in hooks.json.
        public var codexConfigText: () -> String?
        /// The hooks file as Codex names it in a trust key (`Paths.codexHooksTrustName`).
        public var codexHooksTrustName: String
        /// Copilot's `hooks/mysidepulse.json`, on the same rule as Codex's: `[:]` for missing or nothing of
        /// ours, nil only for unreadable; whether `disableAllHooks` turns its user hooks off.
        public var copilotHooksRoot: () -> [String: Any]?
        public var copilotHooksDisabled: () -> Bool
        /// Whether OpenCode's plugin file exists; whether it is exactly what this bundle would write.
        public var opencodePluginPresent: () -> Bool
        public var opencodePluginCurrent: () -> Bool
        public var binaryExists: (String) -> Bool
        public var journalWritable: () -> Bool
        public var lastEventAge: () -> TimeInterval?
        public init(appResponse: @escaping () -> ControlResponse?,
                    settingsRoot: @escaping () -> [String: Any]?,
                    codexHooksRoot: @escaping () -> [String: Any]? = { [:] },
                    codexConfigText: @escaping () -> String? = { "" },
                    codexHooksTrustName: String = Paths.codexHooksTrustName,
                    copilotHooksRoot: @escaping () -> [String: Any]? = { [:] },
                    copilotHooksDisabled: @escaping () -> Bool = { false },
                    opencodePluginPresent: @escaping () -> Bool = { false },
                    opencodePluginCurrent: @escaping () -> Bool = { false },
                    binaryExists: @escaping (String) -> Bool,
                    journalWritable: @escaping () -> Bool,
                    lastEventAge: @escaping () -> TimeInterval?) {
            self.appResponse = appResponse; self.settingsRoot = settingsRoot
            self.codexHooksRoot = codexHooksRoot; self.copilotHooksRoot = copilotHooksRoot
            self.codexConfigText = codexConfigText; self.codexHooksTrustName = codexHooksTrustName
            self.copilotHooksDisabled = copilotHooksDisabled; self.opencodePluginPresent = opencodePluginPresent
            self.opencodePluginCurrent = opencodePluginCurrent
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

        // Every check below follows one rule, the same the Health page's lines follow: nothing of
        // MySidepulse's at an agent's hook file (never set up, or removed) passes with a "not set up"
        // sentence, whether or not the agent itself is on this Mac; something of ours there but not
        // working (an event missing, a stale binary, disableAllHooks, a plugin from elsewhere) fails; the
        // file existing and unreadable fails too. Claude Code's hooks are the one exception that can fail
        // while empty: they stay required unless another agent's hooks have something of ours instead.
        func missingEvents(in root: [String: Any], agent: AgentKind) -> (missing: [String], staleBinary: Bool, nameNoAgent: Bool) {
            var missing: [String] = []
            var staleBinary = false
            var nameNoAgent = false
            for event in HookConfig.events(for: agent) {
                guard let command = HookConfig.installedCommand(in: root, event: event) else {
                    missing.append(event)
                    continue
                }
                if !p.binaryExists(HookConfig.binary(ofCommand: command)) { staleBinary = true }
                // An entry from before the hook had to name its agent writes nothing now.
                if !HookConfig.namesItsAgent(command, agent) { nameNoAgent = true }
            }
            return (missing, staleBinary, nameNoAgent)
        }

        let claudeRoot = p.settingsRoot()
        let claudeFacts = claudeRoot.map { missingEvents(in: $0, agent: .claude) }
        let claudeNotSetUp = claudeFacts.map { $0.missing.count == HookConfig.events.count } ?? false

        let codexRoot = p.codexHooksRoot()
        let codexFacts = codexRoot.map { missingEvents(in: $0, agent: .codex) }
        let codexNotSetUp = codexFacts.map { $0.missing.count == HookConfig.codexEvents.count } ?? false

        let copilotRoot = p.copilotHooksRoot()
        let copilotDisabled = p.copilotHooksDisabled()
        var copilotMissing: [String] = []
        var copilotStaleBinary = false
        if let root = copilotRoot {
            for event in HookConfig.copilotEvents {
                guard let exec = HookConfig.copilotEntryExec(in: root, event: event) else {
                    copilotMissing.append(event)
                    continue
                }
                if !p.binaryExists(exec) { copilotStaleBinary = true }
            }
        }
        // disableAllHooks is Copilot's own setting: with nothing of ours in the file there is nothing it turns off.
        let copilotNotSetUp = copilotRoot != nil && copilotMissing.count == HookConfig.copilotEvents.count

        let opencodeNotSetUp = !p.opencodePluginPresent()

        // Whether another agent has something of MySidepulse's, which is what lets Claude Code's own
        // line pass empty: the owner may be using that agent instead.
        let anotherAgentHasSomething = !codexNotSetUp || !copilotNotSetUp || !opencodeNotSetUp

        if let root = claudeRoot, let facts = claudeFacts {
            if claudeNotSetUp && anotherAgentHasSomething {
                r.check(true, "hooks installed", t.claudeHooksNotSetUp)
            } else if facts.nameNoAgent {
                r.check(false, "hooks installed", t.hooksNameNoAgent)
            } else {
                r.check(facts.missing.isEmpty, "hooks installed",
                        facts.missing.isEmpty ? t.allEventsSubscribed(HookConfig.events.count)
                                              : t.missingEvents(facts.missing.joined(separator: ", ")))
            }
            r.check(!facts.staleBinary, "hook binary",
                    facts.staleBinary ? t.hookPointsAtMissingBinary : t.binaryExists)
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
        // Codex: the same per-event bar as Claude Code's, on one line, and every hook of ours trusted in
        // config.toml, since Codex runs no other.
        if let root = codexRoot, let facts = codexFacts {
            if codexNotSetUp {
                r.check(true, "codex hooks", t.codexHooksNotSetUp)
            } else {
                let config = p.codexConfigText()
                let untrusted = config.map {
                    CodexHookTrust.untrustedEvents(hooksFile: p.codexHooksTrustName, root: root, toml: $0)
                } ?? []
                let detail = !facts.missing.isEmpty ? t.missingEvents(facts.missing.joined(separator: ", "))
                    : facts.staleBinary ? t.hookPointsAtMissingBinary
                    : config == nil ? t.codexConfigUnreadable
                    : !untrusted.isEmpty ? t.codexHooksNotTrusted(untrusted.joined(separator: ", "))
                    : t.codexHooksTrusted(HookConfig.codexEvents.count)
                r.check(facts.missing.isEmpty && !facts.staleBinary && config != nil && untrusted.isEmpty,
                        "codex hooks", detail)
            }
        } else {
            r.check(false, "codex hooks", t.codexHooksMissingOrUnparseable)
        }
        // Copilot: the same per-event bar, plus disableAllHooks, which turns every event off without
        // touching the file.
        if copilotRoot != nil {
            if copilotNotSetUp {
                r.check(true, "copilot hooks", t.copilotHooksNotSetUp)
            } else {
                let detail = !copilotMissing.isEmpty ? t.missingEvents(copilotMissing.joined(separator: ", "))
                    : copilotStaleBinary ? t.hookPointsAtMissingBinary
                    : copilotDisabled ? t.copilotHooksDisabledDetail
                    : t.allEventsSubscribed(HookConfig.copilotEvents.count)
                r.check(copilotMissing.isEmpty && !copilotStaleBinary && !copilotDisabled, "copilot hooks", detail)
            }
        } else {
            r.check(false, "copilot hooks", t.copilotHooksMissingOrUnparseable)
        }
        // OpenCode has no per-event shape to check: one plugin file, either exactly what this bundle
        // writes or not.
        if opencodeNotSetUp {
            r.check(true, "opencode plugin", t.opencodePluginNotSetUp)
        } else if p.opencodePluginCurrent() {
            r.check(true, "opencode plugin", t.opencodePluginCurrentDetail)
        } else {
            r.check(false, "opencode plugin", t.opencodePluginStale)
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
                // Same strict reader install-hooks/uninstall-hooks use, and the same idiom
                // (`HookInstaller.hooksInstalled`) that tells a missing file ([:], nothing of ours) apart
                // from one that is there and unparseable (nil, which no button can fix).
                try? (SettingsFile.load(at: Paths.claudeSettings) ?? [:])
            },
            codexHooksRoot: {
                try? (SettingsFile.load(at: Paths.codexHooks) ?? [:])
            },
            codexConfigText: { try? HookInstaller.codexConfigText(Paths.codexConfig) },
            codexHooksTrustName: Paths.codexHooksTrustName,
            copilotHooksRoot: {
                try? (SettingsFile.load(at: Paths.copilotHooks) ?? [:])
            },
            copilotHooksDisabled: { HookInstaller.copilotHooksDisabled() },
            opencodePluginPresent: { FileManager.default.fileExists(atPath: Paths.opencodePlugin.path) },
            opencodePluginCurrent: { HookInstaller.hooksSetUp(for: .opencode) == true },
            binaryExists: { FileManager.default.isExecutableFile(atPath: $0) },
            journalWritable: {
                // Probe the directory with a scratch file — never the real
                // journal, which carries only real records (hook events, job
                // lines and the app's own ack and verdict lines).
                try? FileManager.default.createDirectory(at: Paths.appSupport,
                                                         withIntermediateDirectories: true)
                let probe = Paths.appSupport.appendingPathComponent(".doctor-probe")
                defer { try? FileManager.default.removeItem(at: probe) }
                return JournalWriter.append(Data("probe".utf8), to: probe)
            },
            lastEventAge: {
                // Ack and verdict lines are the app's own and job lines the
                // terminal's; this check answers "are hooks arriving", so only
                // an agent's hook traffic counts.
                let events = JournalTailer.readAll(url: Paths.journal)
                guard let last = events.last(where: { ![.parseError, .ack, .verdict, .jobBegin, .jobEnd].contains($0.event) })
                else { return nil }
                return Date().timeIntervalSince(last.loggedAt)
            })
    }
}

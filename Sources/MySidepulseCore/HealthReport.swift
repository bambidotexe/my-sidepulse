import Foundation

/// Everything the Health page reports, as values. The app gathers them (the engine's status, the doctor's
/// checks, the hook files, the system); this turns them into the page's groups, so what a fact reads as, in
/// which colour and with which sentence, is decided here and tested (`HealthTests`).
///
/// A fact that is nil has not been read yet, and its row is left out rather than shown as unknown.
public struct HealthFacts: Equatable {
    /// One of the doctor's checks: whether it passed, and its sentence, which becomes the row's tooltip.
    public struct Check: Equatable {
        public var ok: Bool
        public var detail: String
        public init(ok: Bool, detail: String) { self.ok = ok; self.detail = detail }
    }

    /// What `~/.claude/settings.json` says about the hooks.
    public enum ClaudeHooks: Equatable {
        /// Every event is subscribed.
        case setUp
        /// At least one event is not.
        case missing
        /// The file is there and cannot be read, which no button can fix.
        case unreadable
    }

    public enum Phone: Equatable {
        case disabled
        case enabled(detail: String)
        /// Switched on, and the topic or the server cannot be posted to.
        case unusable(detail: String)
    }

    public struct Device: Equatable {
        public var name: String
        public var leds: Int
        public var path: String
        public var stalled: Bool
        public init(name: String, leds: Int, path: String, stalled: Bool) {
            self.name = name; self.leds = leds; self.path = path; self.stalled = stalled
        }
    }

    /// A Claude Code session as the engine reports it: its state in the engine's own words, which the page
    /// translates, never shows.
    public struct Session: Equatable {
        public var id: String
        public var phase: SessionPhase
        public var ageSeconds: Int
        public var cwd: String?
        public init(id: String, phase: SessionPhase, ageSeconds: Int, cwd: String?) {
            self.id = id; self.phase = phase; self.ageSeconds = ageSeconds; self.cwd = cwd
        }
    }

    public enum SessionPhase: Equatable {
        case idle, working, done
        case waiting(WaitReason?)
        /// A word the engine added after this table was written: shown as it comes, never dropped.
        case other(String)

        /// The engine's words (`Engine.stateLabel`, `WaitReason.rawValue`) back into a phase.
        public init(state: String, reason: String?) {
            switch state {
            case "idle": self = .idle
            case "working": self = .working
            case "done": self = .done
            case "waiting": self = .waiting(reason.flatMap(WaitReason.init(rawValue:)))
            default: self = .other(state)
            }
        }
    }

    /// A terminal command as the engine reports it.
    public struct Job: Equatable {
        public var id: String
        public var label: String?
        public var phase: JobPhase
        public var acknowledged: Bool
        public var ageSeconds: Int
        public init(id: String, label: String?, phase: JobPhase, acknowledged: Bool, ageSeconds: Int) {
            self.id = id; self.label = label; self.phase = phase
            self.acknowledged = acknowledged; self.ageSeconds = ageSeconds
        }
    }

    public enum JobPhase: Equatable {
        case running, succeeded, failed
        case other(String)

        /// The engine's words (`Engine.jobLabel`) back into a phase.
        public init(state: String) {
            switch state {
            case "running": self = .running
            case "succeeded": self = .succeeded
            case "failed": self = .failed
            default: self = .other(state)
            }
        }
    }

    // Permissions
    public var notificationsGranted: Bool?

    // Claude Code
    public var claudeHooks: ClaudeHooks?
    /// The doctor's "hooks installed", for which events are missing.
    public var hooksCheck: Check?
    /// The doctor's "hook binary": whether every installed hook points at a file that exists.
    public var hookBinary: Check?
    /// The command the hooks run, as `settings.json` holds it.
    public var hookCommand: String?
    /// The doctor's "journal": whether the hook can append to it.
    public var journal: Check?
    public var lastHookEventSeconds: Int?
    public var sessions: [Session] = []

    // Terminal
    public var terminalHookSetUp: Bool?
    public var jobs: [Job] = []

    // Strip
    /// Nil until the engine has answered; empty when no strip is mounted.
    public var devices: [Device]?
    public var mode: LedMode?
    public var display: DisplayState?
    public var battery: PowerState?

    // Phone
    public var phone: Phone?

    // App
    public var launchAgent: LaunchAgentState?
    /// The doctor's "app": whether a `mysidepulse` command can reach this app over its socket.
    public var control: Check?
    public var runningSeconds: TimeInterval?
    public var memoryBytes: UInt64?
    /// When each crash report of the app in the last `K.healthCrashWindow` was written, newest first.
    public var recentCrashes: [Date] = []
    public var location: AppLocation?
    public var bundlePath = ""

    public init() {}
}

/// The Health page's groups, and the text Copy Report puts on the clipboard.
public enum HealthReport {
    /// The groups under the overview, in page order: the permission, then what the whole point rests on
    /// (Claude Code's hooks in, the strip and the phone out), then the terminal, then the app itself.
    public static func groups(for facts: HealthFacts) -> [HealthGroup] {
        [permissions(facts), claudeCode(facts), strip(facts), phone(facts), terminal(facts), app(facts)]
            .filter { !$0.rows.isEmpty }
    }

    static func permissions(_ facts: HealthFacts) -> HealthGroup {
        let t = Loc.settings.health
        let words = Loc.settings.words
        var rows: [HealthRow] = []
        if let granted = facts.notificationsGranted {
            rows.append(HealthRow(id: "notifications permission",
                                  label: Loc.settings.system.notificationsPermissionLabel,
                                  level: HealthRules.grant(held: granted, required: false),
                                  word: granted ? words.granted : words.denied,
                                  fix: Loc.settings.system.notificationsWarning))
        }
        return HealthGroup(id: "permissions", title: t.permissionsTitle, rows: rows)
    }

    static func claudeCode(_ facts: HealthFacts) -> HealthGroup {
        let t = Loc.settings.health
        let system = Loc.settings.system
        let words = Loc.settings.words
        var rows: [HealthRow] = []

        if let hooks = facts.claudeHooks {
            let level = HealthRules.grant(held: hooks == .setUp, required: true)
            rows.append(HealthRow(id: "claude code hooks", label: system.claudeCodeHooksLabel, level: level,
                                  word: hooks == .setUp ? words.enabled
                                      : hooks == .missing ? words.disabled : words.invalid,
                                  detail: facts.hooksCheck?.detail,
                                  fix: hooks == .unreadable ? system.settingsUnreadableWarning
                                                            : system.withoutHooksWarning))
        }
        // Only once the hooks are there: with none installed, no command points anywhere, and a green
        // "Valid" would read as a hook that works.
        if facts.claudeHooks == .setUp, let binary = facts.hookBinary {
            rows.append(HealthRow(id: "hook command", label: t.hookCommandLabel,
                                  level: binary.ok ? .good : .failure,
                                  word: binary.ok ? words.valid : words.invalid,
                                  detail: facts.hookCommand ?? binary.detail, fix: t.hookCommandFix))
        }
        if let journal = facts.journal {
            rows.append(HealthRow(id: "journal", label: t.journalLabel,
                                  level: journal.ok ? .good : .failure,
                                  word: journal.ok ? words.available : words.failed,
                                  detail: journal.detail, fix: t.journalFix))
        }
        rows.append(HealthRow(id: "last hook event", label: t.lastHookEventLabel, level: .info,
                              word: facts.lastHookEventSeconds.map(t.ago(seconds:)) ?? t.noneYet))
        if facts.sessions.isEmpty {
            rows.append(HealthRow(id: "sessions", label: t.claudeSessionsLabel, level: .info,
                                  word: t.noSessions))
        }
        for session in facts.sessions {
            rows.append(HealthRow(id: "session \(session.id)",
                                  label: t.sessionLabel(idPrefix: String(session.id.prefix(8))),
                                  level: .info,
                                  word: t.sessionMark(session.phase, ageSeconds: session.ageSeconds),
                                  detail: session.cwd ?? t.unknownDirectory))
        }
        return HealthGroup(id: "claude code", title: system.claudeCodeTitle, rows: rows)
    }

    static func strip(_ facts: HealthFacts) -> HealthGroup {
        let t = Loc.settings.health
        let strip = Loc.settings.strip
        let words = Loc.settings.words
        var rows: [HealthRow] = []

        if let devices = facts.devices {
            if devices.isEmpty {
                rows.append(HealthRow(id: "strip", label: strip.sidePulseStripLabel, level: .warning,
                                      word: words.missing, fix: strip.stripHintEmpty))
            }
            for device in devices {
                rows.append(HealthRow(id: "strip \(device.name)",
                                      label: strip.deviceRow(name: device.name, leds: device.leds),
                                      level: device.stalled ? .warning : .good,
                                      word: device.stalled ? words.stalled : words.available,
                                      detail: device.path, fix: strip.stalledWarning(name: device.name)))
            }
        }
        if let mode = facts.mode {
            // The user's choice, whichever it is; the detail names the colour or the effect forced.
            let (word, detail): (String, String?) = switch mode {
            case .auto: (strip.modeAuto, nil)
            case .off: (strip.modeOff, nil)
            case .color(let hex): (strip.modeColour, hex)
            case .effect(let name): (strip.modeEffect, name)
            }
            rows.append(HealthRow(id: "mode", label: t.modeLabel, level: .info, word: word, detail: detail))
        }
        if let display = facts.display {
            rows.append(HealthRow(id: "showing", label: strip.showingLabel, level: .info,
                                  word: StatusCopy.line(for: display).text))
        }
        if let battery = facts.battery {
            rows.append(HealthRow(id: "battery", label: t.batteryLabel, level: .info,
                                  word: t.batteryMark(percent: battery.percent, plugged: battery.plugged)))
        }
        return HealthGroup(id: "strip", title: strip.stripTitle, rows: rows)
    }

    static func phone(_ facts: HealthFacts) -> HealthGroup {
        let t = Loc.settings.health
        let words = Loc.settings.words
        var rows: [HealthRow] = []
        if let phone = facts.phone {
            let (word, detail): (String, String?) = switch phone {
            case .disabled: (words.disabled, nil)
            case .enabled(let detail): (words.enabled, detail)
            case .unusable(let detail): (words.invalid, detail)
            }
            rows.append(HealthRow(id: "phone notifications", label: t.phoneNotificationsLabel,
                                  level: HealthRules.phone(phone), word: word, detail: detail,
                                  fix: t.phoneFix))
        }
        return HealthGroup(id: "phone", title: Loc.settings.notifications.phoneTitle, rows: rows)
    }

    static func terminal(_ facts: HealthFacts) -> HealthGroup {
        let t = Loc.settings.health
        let system = Loc.settings.system
        let words = Loc.settings.words
        var rows: [HealthRow] = []
        if let setUp = facts.terminalHookSetUp {
            rows.append(HealthRow(id: "terminal hook", label: system.terminalHookLabel,
                                  level: HealthRules.grant(held: setUp, required: false),
                                  word: setUp ? words.enabled : words.disabled,
                                  fix: system.withoutTerminalHookWarning))
        }
        if facts.jobs.isEmpty {
            rows.append(HealthRow(id: "commands", label: t.terminalCommandsLabel, level: .info,
                                  word: t.noCommands))
        }
        // A command has no name of its own beyond what it runs, so its row is the command itself.
        for job in facts.jobs {
            rows.append(HealthRow(id: "job \(job.id)", label: job.label ?? job.id, level: .info,
                                  word: t.jobMark(job.phase, acknowledged: job.acknowledged,
                                                  ageSeconds: job.ageSeconds)))
        }
        return HealthGroup(id: "terminal", title: system.terminalTitle, rows: rows)
    }

    /// What every app of the family reports about itself, with MySidepulse's launch agent in the place of a
    /// login item and the socket its command answers on.
    static func app(_ facts: HealthFacts) -> HealthGroup {
        let t = Loc.settings.health
        let general = Loc.settings.general
        let words = Loc.settings.words
        var rows: [HealthRow] = []

        if let agent = facts.launchAgent {
            rows.append(HealthRow(id: "launch agent", label: general.openAtLoginToggle,
                                  level: HealthRules.launchAgent(agent),
                                  word: agent == .disabled ? words.disabled : words.enabled,
                                  fix: agent == .notSupervised ? general.startupWarningOpenedByHand
                                                               : t.launchAgentFix))
        }
        if let control = facts.control {
            rows.append(HealthRow(id: "command line", label: t.commandLineLabel,
                                  level: control.ok ? .good : .warning,
                                  word: control.ok ? words.available : words.failed,
                                  detail: control.detail, fix: t.commandLineFix))
        }
        if let seconds = facts.runningSeconds {
            rows.append(HealthRow(id: "running for", label: t.runningForLabel, level: .info,
                                  word: t.duration(seconds: seconds)))
        }
        if let bytes = facts.memoryBytes {
            rows.append(HealthRow(id: "memory", label: t.memoryLabel, level: .info,
                                  word: t.megabytes(Int((Double(bytes) / 1_048_576).rounded()))))
        }
        let crashes = facts.recentCrashes.count
        rows.append(HealthRow(id: "crashes", label: t.crashesLabel(days: Int(K.healthCrashWindow / 86_400)),
                              level: HealthRules.crashes(crashes),
                              word: crashes == 0 ? t.noCrashes : "\(crashes)",
                              detail: facts.recentCrashes.first.map { t.lastCrash(stamp($0)) },
                              fix: t.crashesFix))
        if let location = facts.location {
            rows.append(HealthRow(id: "location", label: t.locationLabel,
                                  level: HealthRules.location(location),
                                  word: t.locationWord(location), detail: facts.bundlePath,
                                  fix: t.locationFix))
        }
        return HealthGroup(id: "app", title: t.appTitle, rows: rows)
    }

    /// The first row's word: everything works, how many lines to look at, or how many stop the app.
    public static func summaryWord(_ summary: HealthSummary) -> String {
        let t = Loc.settings.health
        switch summary.level {
        case .failure: return t.notWorking(problems: summary.blocking)
        case .warning: return t.toLookAt(summary.toLookAt)
        case .good, .info: return t.everythingWorks
        }
    }

    /// The copied report: which app and which system, the summary, then every group of the page with one
    /// line per row, its level, its word and its detail. Written for a bug report, so nothing in it is a
    /// secret: the phone's topic reaches it masked, as the doctor prints it.
    public static func text(appName: String, version: String, system: String, groups: [HealthGroup]) -> String {
        var lines = ["\(appName) \(version), \(system)", summaryWord(HealthSummary(groups: groups))]
        for group in groups {
            lines.append("")
            lines.append(group.title)
            for row in group.rows {
                var line = "\(tag(row.level)) \(row.label): \(row.word)"
                if let detail = row.detail, !detail.isEmpty { line += " (\(detail))" }
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func tag(_ level: HealthLevel) -> String {
        switch level {
        case .info: "[INFO]"
        case .good: "[OK]  "
        case .warning: "[WARN]"
        case .failure: "[FAIL]"
        }
    }

    /// A moment as a bug report wants it: the same in every language, sortable, to the minute, in the Mac's
    /// own time zone.
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

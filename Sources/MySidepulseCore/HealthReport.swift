import Foundation

/// Everything the Health page reports, as values. The app gathers them (the engine's status, the doctor's
/// checks, the hook files, the system); this turns them into the page's two tables, so what a fact reads as, in
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

    /// What an agent's hook file says about the hooks: `~/.claude/settings.json`, `~/.codex/hooks.json`,
    /// `~/.copilot/hooks/mysidepulse.json`, or `~/.config/opencode/plugins/mysidepulse.js`.
    public enum HookFile: Equatable {
        /// Every event is subscribed.
        case setUp
        /// Something of MySidepulse's is there (an event, an entry), but not all of it: some events
        /// missing, a stale binary, disableAllHooks, a plugin from another copy.
        case missing
        /// Nothing of MySidepulse's is there: never set up, or removed. Not a line on the Health page,
        /// except Claude Code's, which stays the one required line while no other agent's hooks have
        /// something of ours instead.
        case notSetUp
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

    /// An agent's session as the engine reports it: its state in the engine's own words, which the page
    /// translates, never shows.
    public struct Session: Equatable {
        public var id: String
        public var agent: AgentKind
        public var phase: SessionPhase
        public var ageSeconds: Int
        public var cwd: String?
        public init(id: String, agent: AgentKind = .claude, phase: SessionPhase, ageSeconds: Int, cwd: String?) {
            self.id = id; self.agent = agent; self.phase = phase; self.ageSeconds = ageSeconds; self.cwd = cwd
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
    public var claudeHooks: HookFile?
    /// The doctor's "hooks installed", for which events are missing.
    public var hooksCheck: Check?
    /// The doctor's "hook binary": whether every installed hook points at a file that exists.
    public var hookBinary: Check?
    /// The command the hooks run, as `settings.json` holds it.
    public var hookCommand: String?
    /// The doctor's "journal": whether the hooks can append to it.
    public var journal: Check?
    public var lastHookEventSeconds: Int?
    public var sessions: [Session] = []

    /// Whether Codex trusts the hooks of ours that are in `~/.codex/hooks.json`: Codex runs a user hook
    /// only while `~/.codex/config.toml` holds its trust.
    public enum CodexTrust: Equatable {
        /// Every hook of ours in the file is trusted.
        case trusted
        /// At least one is not, or is switched off in Codex: Codex never runs it.
        case untrusted
        /// config.toml is there and cannot be read as text.
        case unreadable
    }

    /// Codex's line from its two files: how many of its events run this bundle's CLI in hooks.json (nil
    /// when the file cannot be read), and how many of those Codex trusts (nil when config.toml cannot be
    /// read). Set up only while every event is there **and** trusted; anything of ours short of that is
    /// ours and broken.
    public static func codex(installed: Int?, trusted: Int?) -> (hooks: HookFile, trust: CodexTrust?) {
        guard let installed else { return (.unreadable, nil) }
        let trust: CodexTrust = trusted.map { $0 < installed ? .untrusted : .trusted } ?? .unreadable
        if installed <= 0 { return (.notSetUp, trust) }
        let all = HookConfig.setUpCount(for: .codex)
        return (installed >= all && (trusted ?? 0) >= all ? .setUp : .missing, trust)
    }

    // Codex
    public var codexHooks: HookFile?
    /// Whether Codex trusts what of ours is in hooks.json; read with `codexHooks`.
    public var codexTrust: CodexTrust?
    /// The doctor's "codex hooks".
    public var codexHooksCheck: Check?
    /// The command this bundle's Codex hooks run, which is what `hooks.json` holds while the line is green.
    public var codexHookCommand: String?

    // GitHub Copilot
    public var copilotHooks: HookFile?
    /// The doctor's "copilot hooks".
    public var copilotHooksCheck: Check?
    /// The command this bundle's Copilot hooks run.
    public var copilotHookCommand: String?
    /// Whether `disableAllHooks` turns every one of Copilot's user hooks off, whatever the file says.
    public var copilotHooksDisabled: Bool?

    // OpenCode
    public var opencodeHooks: HookFile?
    /// The doctor's "opencode plugin".
    public var opencodeHooksCheck: Check?
    /// The command this bundle's OpenCode plugin runs.
    public var opencodeHookCommand: String?

    // Terminal
    public var terminalHookSetUp: Bool?
    public var jobs: [Job] = []

    // Strip
    /// Nil until the engine has answered; empty when no strip is mounted.
    public var devices: [Device]?
    public var display: DisplayState?

    // Phone
    public var phone: Phone?

    // App
    public var launchAgent: LaunchAgentState?
    /// The doctor's "app": whether a `mysidepulse` command can reach this app over its socket.
    public var control: Check?
    /// When each crash report of the app in the last `K.healthCrashWindow` was written, newest first.
    public var recentCrashes: [Date] = []

    public init() {}
}

/// The Health page's two tables: the checks, green, orange or red, and the readings, blue.
///
/// **A check is something that has to be in place or running for MySidepulse to work**: the hooks that tell
/// it what Claude Code and the terminal do, the permission its alerts need, the strip it lights, the launch
/// agent that brings it back after a crash, the phone link once it is switched on. A preference is never a
/// check, and neither is a reading. The skill `macos-building-settings-pages` (*The Health page*) holds
/// the rules and every app's list.
public enum HealthReport {
    /// The Health table, in page order. A fact nobody has read yet leaves its line out rather than showing
    /// it unknown.
    public static func checks(for facts: HealthFacts) -> [HealthRow] {
        [claudeHooks(facts), codexHooks(facts), copilotHooks(facts), opencodeHooks(facts), terminalHook(facts),
         notifications(facts), strip(facts), launchAgent(facts), phone(facts), commandLine(facts),
         crashes(facts.recentCrashes)].compactMap { $0 }
    }

    /// The Information table, in page order, each line only once it has something to say.
    public static func readings(for facts: HealthFacts) -> [InfoRow] {
        let t = Loc.settings.health
        var rows: [InfoRow] = []
        let agentSetUp = [facts.claudeHooks, facts.codexHooks, facts.copilotHooks, facts.opencodeHooks]
            .contains(.setUp)
        let terminalSetUp = facts.terminalHookSetUp == true

        if agentSetUp || terminalSetUp {
            rows.append(InfoRow(id: "last hook event", label: t.lastHookEventLabel,
                                value: facts.lastHookEventSeconds.map(t.ago(seconds:)) ?? t.noneYet))
        }
        if agentSetUp {
            rows.append(InfoRow(id: "sessions", label: t.agentSessionsLabel,
                                value: facts.sessions.isEmpty ? t.noSessions : "\(facts.sessions.count)",
                                detail: facts.sessions.isEmpty ? nil : facts.sessions.map {
                                    "\($0.id.prefix(8)) \($0.agent.shortName): "
                                        + t.sessionMark($0.phase, ageSeconds: $0.ageSeconds)
                                }.joined(separator: "\n")))
        }
        if terminalSetUp {
            rows.append(InfoRow(id: "commands", label: t.terminalCommandsLabel,
                                value: facts.jobs.isEmpty ? t.noCommands : "\(facts.jobs.count)",
                                detail: facts.jobs.isEmpty ? nil : facts.jobs.map {
                                    "\($0.label ?? $0.id): \(t.jobMark($0.phase, acknowledged: $0.acknowledged, ageSeconds: $0.ageSeconds))"
                                }.joined(separator: "\n")))
        }
        if let devices = facts.devices, !devices.isEmpty, let display = facts.display {
            rows.append(InfoRow(id: "showing", label: Loc.settings.strip.showingLabel,
                                value: StatusCopy.line(for: display).text))
        }
        return rows
    }

    /// Required: without them the strip never shows Claude. One line says whether they work at all: set up,
    /// pointing at a copy of MySidepulse that exists, and able to write the journal the app reads. Nothing
    /// of Claude Code's is the one case that can still pass: the owner may be using another agent instead,
    /// so the line leaves once that agent's hooks have something of ours and Claude's do not. With no agent
    /// at all set up, the line stays red: the strip then follows nothing.
    static func claudeHooks(_ facts: HealthFacts) -> HealthRow? {
        guard let hooks = facts.claudeHooks else { return nil }
        let t = Loc.settings.health
        let system = Loc.settings.system
        let words = Loc.settings.words
        let label = system.claudeCodeHooksLabel
        if hooks == .notSetUp {
            let anotherAgentHasSomething = [facts.codexHooks, facts.copilotHooks, facts.opencodeHooks]
                .contains { $0 != nil && $0 != .notSetUp }
            if anotherAgentHasSomething { return nil }
        }
        switch hooks {
        case .missing where facts.hookBinary.map({ !$0.ok }) ?? false:
            // Something of ours runs a copy of MySidepulse that is gone: Invalid, the command as the tooltip.
            return HealthRow(id: "claude code hooks", label: label, level: .failure, word: words.invalid,
                             detail: facts.hookCommand ?? facts.hookBinary?.detail, fix: t.hookCommandFix)
        case .notSetUp, .missing:
            return HealthRow(id: "claude code hooks", label: label, level: HealthRules.grant(held: false, required: true),
                             word: words.disabled, detail: facts.hooksCheck?.detail, fix: system.withoutHooksWarning)
        case .unreadable:
            return HealthRow(id: "claude code hooks", label: label, level: .failure, word: words.invalid,
                             detail: facts.hooksCheck?.detail, fix: system.settingsUnreadableWarning)
        case .setUp:
            if let binary = facts.hookBinary, !binary.ok {
                return HealthRow(id: "claude code hooks", label: label, level: .failure, word: words.invalid,
                                 detail: facts.hookCommand ?? binary.detail, fix: t.hookCommandFix)
            }
            if let journal = facts.journal, !journal.ok {
                return HealthRow(id: "claude code hooks", label: label, level: .failure, word: words.failed,
                                 detail: journal.detail, fix: t.journalFix)
            }
            return HealthRow(id: "claude code hooks", label: label, level: .good, word: words.enabled,
                             detail: facts.hookCommand)
        }
    }

    /// Optional: a line only once something of ours is at `~/.codex/hooks.json`, whether or not Codex
    /// itself is on this Mac. Nothing of ours is no line at all; something there but not working is orange,
    /// a hook Codex does not trust included: Codex never runs it.
    static func codexHooks(_ facts: HealthFacts) -> HealthRow? {
        guard let hooks = facts.codexHooks else { return nil }
        let t = Loc.settings.health
        let system = Loc.settings.system
        let words = Loc.settings.words
        let label = system.codexHooksLabel
        switch hooks {
        case .notSetUp: return nil
        case .missing:
            let level = HealthRules.grant(held: false, required: false)
            switch facts.codexTrust {
            case .untrusted?:
                return HealthRow(id: "codex hooks", label: label, level: level, word: words.disabled,
                                 detail: facts.codexHooksCheck?.detail, fix: system.codexHooksUntrustedWarning)
            case .unreadable?:
                return HealthRow(id: "codex hooks", label: label, level: level, word: words.invalid,
                                 detail: facts.codexHooksCheck?.detail, fix: system.codexConfigUnreadableWarning)
            case .trusted?, nil:
                return HealthRow(id: "codex hooks", label: label, level: level, word: words.disabled,
                                 detail: facts.codexHooksCheck?.detail, fix: system.withoutCodexHooksWarning)
            }
        case .unreadable:
            return HealthRow(id: "codex hooks", label: label, level: .warning, word: words.invalid,
                             detail: facts.codexHooksCheck?.detail, fix: system.codexHooksUnreadableWarning)
        case .setUp:
            if let check = facts.codexHooksCheck, !check.ok {
                return HealthRow(id: "codex hooks", label: label, level: .warning, word: words.invalid,
                                 detail: facts.codexHookCommand ?? check.detail, fix: t.codexHookCommandFix)
            }
            if let journal = facts.journal, !journal.ok {
                return HealthRow(id: "codex hooks", label: label, level: .warning, word: words.failed,
                                 detail: journal.detail, fix: t.journalFix)
            }
            return HealthRow(id: "codex hooks", label: label, level: .good, word: words.enabled,
                             detail: facts.codexHookCommand)
        }
    }

    /// Optional, like Codex's: a line only once something of ours is at Copilot's hook file, whether or
    /// not Copilot itself is on this Mac. `disableAllHooks` turns every user hook off without touching the
    /// file, so it is checked even while every event is subscribed.
    static func copilotHooks(_ facts: HealthFacts) -> HealthRow? {
        guard let hooks = facts.copilotHooks else { return nil }
        let t = Loc.settings.health
        let system = Loc.settings.system
        let words = Loc.settings.words
        let label = system.copilotHooksLabel
        switch hooks {
        case .notSetUp: return nil
        case .missing:
            return HealthRow(id: "copilot hooks", label: label, level: HealthRules.grant(held: false, required: false),
                             word: words.disabled, detail: facts.copilotHooksCheck?.detail,
                             fix: system.withoutCopilotHooksWarning)
        case .unreadable:
            return HealthRow(id: "copilot hooks", label: label, level: .warning, word: words.invalid,
                             detail: facts.copilotHooksCheck?.detail, fix: system.copilotHooksInvalidWarning)
        case .setUp:
            if facts.copilotHooksDisabled == true {
                return HealthRow(id: "copilot hooks", label: label, level: .warning, word: words.disabled,
                                 detail: facts.copilotHooksCheck?.detail, fix: system.copilotHooksDisabledWarning)
            }
            if let check = facts.copilotHooksCheck, !check.ok {
                return HealthRow(id: "copilot hooks", label: label, level: .warning, word: words.invalid,
                                 detail: facts.copilotHookCommand ?? check.detail, fix: t.copilotHookCommandFix)
            }
            if let journal = facts.journal, !journal.ok {
                return HealthRow(id: "copilot hooks", label: label, level: .warning, word: words.failed,
                                 detail: journal.detail, fix: t.journalFix)
            }
            return HealthRow(id: "copilot hooks", label: label, level: .good, word: words.enabled,
                             detail: facts.copilotHookCommand)
        }
    }

    /// Optional, like Copilot's: a line only once something of ours is at OpenCode's plugin path, whether
    /// or not OpenCode itself is on this Mac. A plugin that is there but is not this copy's reads Invalid:
    /// a stale plugin of another copy of MySidepulse, which Set Up replaces, or a foreign file, which Set
    /// Up refuses and must be removed by hand — the two cannot be told apart from here, so the fix names
    /// both.
    static func opencodeHooks(_ facts: HealthFacts) -> HealthRow? {
        guard let hooks = facts.opencodeHooks else { return nil }
        let t = Loc.settings.health
        let system = Loc.settings.system
        let words = Loc.settings.words
        let label = system.opencodePluginLabel
        switch hooks {
        case .notSetUp: return nil
        case .missing:
            return HealthRow(id: "opencode plugin", label: label, level: HealthRules.grant(held: false, required: false),
                             word: words.disabled, detail: facts.opencodeHooksCheck?.detail,
                             fix: system.withoutOpencodePluginWarning)
        case .unreadable:
            return HealthRow(id: "opencode plugin", label: label, level: .warning, word: words.invalid,
                             detail: facts.opencodeHooksCheck?.detail, fix: system.opencodePluginInvalidWarning)
        case .setUp:
            if let journal = facts.journal, !journal.ok {
                return HealthRow(id: "opencode plugin", label: label, level: .warning, word: words.failed,
                                 detail: journal.detail, fix: t.journalFix)
            }
            return HealthRow(id: "opencode plugin", label: label, level: .good, word: words.enabled,
                             detail: facts.opencodeHookCommand)
        }
    }

    /// A line only once the zsh block is there: the block itself is the whole of MySidepulse's terminal
    /// hook, so its absence is nothing of ours to check, not a broken setup.
    static func terminalHook(_ facts: HealthFacts) -> HealthRow? {
        guard facts.terminalHookSetUp == true else { return nil }
        let words = Loc.settings.words
        return HealthRow(id: "terminal hook", label: Loc.settings.system.terminalHookLabel,
                         level: .good, word: words.enabled)
    }

    static func notifications(_ facts: HealthFacts) -> HealthRow? {
        guard let granted = facts.notificationsGranted else { return nil }
        let words = Loc.settings.words
        return HealthRow(id: "notifications permission", label: Loc.settings.system.notificationsPermissionLabel,
                         level: HealthRules.grant(held: granted, required: false),
                         word: granted ? words.granted : words.denied,
                         fix: Loc.settings.system.notificationsWarning)
    }

    /// The strip the whole point is lit on: there, and taking what it is sent.
    static func strip(_ facts: HealthFacts) -> HealthRow? {
        guard let devices = facts.devices else { return nil }
        let strip = Loc.settings.strip
        let words = Loc.settings.words
        let detail = devices.map { "\(strip.deviceRow(name: $0.name, leds: $0.leds)), \($0.path)" }
            .joined(separator: "\n")
        if devices.isEmpty {
            return HealthRow(id: "strip", label: strip.sidePulseStripLabel, level: .warning, word: words.missing,
                             fix: strip.stripHintEmpty)
        }
        if let stalled = devices.first(where: \.stalled) {
            return HealthRow(id: "strip", label: strip.sidePulseStripLabel, level: .warning, word: words.stalled,
                             detail: detail, fix: strip.stalledWarning(name: stalled.name))
        }
        return HealthRow(id: "strip", label: strip.sidePulseStripLabel, level: .good, word: words.available,
                         detail: detail)
    }

    /// The launch agent opens MySidepulse at login and brings it back after a crash.
    static func launchAgent(_ facts: HealthFacts) -> HealthRow? {
        guard let agent = facts.launchAgent else { return nil }
        let t = Loc.settings.health
        let words = Loc.settings.words
        let word = switch agent {
        case .enabled: words.enabled
        case .disabled: words.disabled
        case .notSupervised: t.openedByHand
        }
        return HealthRow(id: "launch agent", label: Loc.settings.general.openAtLoginToggle,
                         level: HealthRules.launchAgent(agent), word: word,
                         fix: agent == .notSupervised ? Loc.settings.general.startupWarningOpenedByHand
                                                      : t.launchAgentFix)
    }

    /// Only while the phone half is switched on: off, it is the user's choice and nothing to check.
    static func phone(_ facts: HealthFacts) -> HealthRow? {
        let t = Loc.settings.health
        let words = Loc.settings.words
        switch facts.phone {
        case nil, .disabled?:
            return nil
        case .enabled(let detail)?:
            return HealthRow(id: "phone notifications", label: t.phoneNotificationsLabel, level: .good,
                             word: words.enabled, detail: detail)
        case .unusable(let detail)?:
            return HealthRow(id: "phone notifications", label: t.phoneNotificationsLabel, level: .warning,
                             word: words.invalid, detail: detail, fix: t.phoneFix)
        }
    }

    /// Only while a `mysidepulse` command cannot reach the app: while it can, there is nothing to say.
    static func commandLine(_ facts: HealthFacts) -> HealthRow? {
        guard let control = facts.control, !control.ok else { return nil }
        let t = Loc.settings.health
        return HealthRow(id: "command line", label: t.commandLineLabel, level: .warning,
                         word: Loc.settings.words.failed, detail: control.detail, fix: t.commandLineFix)
    }

    /// The line every app of the family ends its Health table with, **only while there is a crash** in the
    /// last `K.healthCrashWindow`.
    public static func crashes(_ recentCrashes: [Date]) -> HealthRow? {
        guard let last = recentCrashes.first else { return nil }
        let t = Loc.settings.health
        return HealthRow(id: "crashes", label: t.crashesLabel(days: Int(K.healthCrashWindow / 86_400)),
                         level: .warning, word: "\(recentCrashes.count)", detail: t.lastCrash(stamp(last)),
                         fix: t.crashesFix)
    }

    /// A moment as a tooltip wants it: the same in every language, sortable, to the minute, in the Mac's own
    /// time zone.
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

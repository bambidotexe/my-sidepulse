import Foundation
import MachO
import MySidepulseCore

/// Setting up and removing the hooks that feed the app: its entries in Claude
/// Code's settings.json and in Codex's hooks.json, with the trust Codex wants
/// for them in its config.toml, GitHub Copilot's hook file and OpenCode's
/// plugin, which are MySidepulse's whole, and its block in ~/.zshrc. Shared by
/// `mysidepulse install-hooks` / `uninstall-hooks` and the settings window, so
/// both do the same thing and both report what actually landed.
public enum HookInstaller {
    public struct Outcome: Equatable {
        public let ok: Bool
        public let lines: [String]
        public var message: String { lines.joined(separator: "\n") }
    }

    /// The CLI next to the running executable, symlinks resolved: itself when
    /// the CLI asks, its sibling in `Contents/MacOS` when the app does.
    /// Deliberately not argv[0]: a PATH-resolved invocation (a bare
    /// `mysidepulse` through a symlink on $PATH) gives argv[0] as a bare name
    /// with no directory component, and resolving that against the current
    /// directory yields a path that does not exist. Resolving symlinks means
    /// the installed command points into the app bundle, so deleting a
    /// convenience symlink later cannot break the hooks.
    public static func cliPath() -> String {
        var size = UInt32(0)
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        let running = _NSGetExecutablePath(&buffer, &size) == 0
            ? String(cString: buffer) : CommandLine.arguments[0]
        return URL(fileURLWithPath: running).resolvingSymlinksInPath().standardizedFileURL
            .deletingLastPathComponent().appendingPathComponent("mysidepulse").path
    }

    // MARK: an agent's hook file

    /// Where Claude Code keeps its hooks, in a file it shares with the user,
    /// and the copy taken before it is touched. Nil for Codex, whose hooks
    /// file goes with its trust (`CodexFiles`), and for Copilot and OpenCode,
    /// whose file MySidepulse owns whole (`ownedFile`).
    static func files(for agent: AgentKind) -> (file: URL, backup: URL, name: String)? {
        switch agent {
        case .claude: return (Paths.claudeSettings, Paths.claudeSettingsBackup, "~/.claude/settings.json")
        case .codex, .copilot, .opencode: return nil
        }
    }

    /// The file MySidepulse writes whole for an agent, and how it is named in
    /// a sentence: Copilot's hook file and OpenCode's plugin. Nil for Claude
    /// Code and Codex, whose file is the user's (`files`).
    public static func ownedFile(for agent: AgentKind) -> (file: URL, name: String)? {
        switch agent {
        case .copilot: return (Paths.copilotHooks, "~/.copilot/hooks/mysidepulse.json")
        case .opencode: return (Paths.opencodePlugin, "~/.config/opencode/plugins/mysidepulse.js")
        case .claude, .codex: return nil
        }
    }

    /// Whether Codex is on this Mac: its home exists. Its hooks file is
    /// created when the hooks are set up, so the file itself proves nothing.
    public static func codexInstalled(home: URL = Paths.codexHome) -> Bool {
        isDirectory(home)
    }

    /// Whether GitHub Copilot CLI is on this Mac: its home, `~/.copilot`,
    /// exists. The hooks folder in it is created when the hooks are set up.
    public static func copilotInstalled(home: URL = Paths.copilotHome) -> Bool {
        isDirectory(home)
    }

    /// Whether OpenCode is on this Mac: its configuration, its CLI's own
    /// install or its desktop app exists.
    public static func opencodeInstalled(config: URL = Paths.opencodeConfig, cliHome: URL = Paths.opencodeCLIHome,
                                         app: URL = Paths.opencodeApp) -> Bool {
        [config, cliHome, app].contains(where: isDirectory)
    }

    /// Whether an agent is on this Mac, for `install-hooks`. Claude Code's
    /// hooks are always set up: they are the app's reason to be.
    public static func isInstalled(_ agent: AgentKind) -> Bool {
        switch agent {
        case .claude: return true
        case .codex: return codexInstalled()
        case .copilot: return copilotInstalled()
        case .opencode: return opencodeInstalled()
        }
    }

    /// Whether Copilot runs no user hook at all: `disableAllHooks` in its
    /// `settings.json` or its `config.json` (`HookConfig.copilotHooksDisabled`).
    public static func copilotHooksDisabled(home: URL = Paths.copilotHome) -> Bool {
        func read(_ name: String) -> String? {
            try? String(contentsOf: home.appendingPathComponent(name), encoding: .utf8)
        }
        return HookConfig.copilotHooksDisabled(settingsText: read("settings.json"), configText: read("config.json"))
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    public static func installHooks(for agent: AgentKind, cliPath: String = cliPath(),
                                    file: URL? = nil, backup: URL? = nil) -> Outcome {
        let t = Loc.hookInstall
        if agent == .copilot || agent == .opencode {
            return installOwnedFile(for: agent, cliPath: cliPath, file: file)
        }
        if agent == .codex {
            return installCodexHooks(cliPath: cliPath, files: .told(file: file, backup: backup))
        }
        let defaults = files(for: agent)
        guard let file = file ?? defaults?.file, let backup = backup ?? defaults?.backup else {
            return Outcome(ok: false, lines: [t.notModified])
        }
        let command = HookConfig.command(cliPath: cliPath, agent: agent)
        let events = HookConfig.events(for: agent)
        // A hook command pointing at a missing binary fails silently — the
        // agent just never fires it — and an entry without the marker could
        // never be recognised again, let alone removed.
        guard command.contains(HookConfig.ourMarker),
              FileManager.default.isExecutableFile(atPath: cliPath) else {
            return Outcome(ok: false, lines: [t.noCLIInBundle(path: cliPath), t.notModified])
        }
        do {
            let root = try SettingsFile.load(at: file) ?? [:]
            try SettingsFile.backup(from: file, to: backup)
            let edited = HookConfig.install(into: root, command: command, agent: agent)
            try SettingsFile.write(edited, to: file)
            // Count what actually landed rather than assuming: HookConfig
            // declines shapes it does not understand (a non-object `hooks`, a
            // non-array event), and reporting success over a declined edit is
            // how a silent gap in the hook coverage is born.
            let missing = events.filter { HookConfig.installedCommand(in: edited, event: $0) != command }
            let total = events.count
            var lines = missing.isEmpty
                ? [t.installed(total: total, agent: agent, command: command)]
                : [t.installedPartial(installed: total - missing.count, total: total, command: command),
                   t.declinedToTouch(missing.joined(separator: ", ")),
                   t.declinedShapeNote(file: defaults?.name ?? file.path)]
            if FileManager.default.fileExists(atPath: backup.path) {
                lines.append(t.backupWritten(path: backup.path))
            }
            return Outcome(ok: missing.isEmpty, lines: lines)
        } catch {
            return Outcome(ok: false, lines: [t.installFailed("\(error)"), t.notModified])
        }
    }

    public static func removeHooks(for agent: AgentKind, file: URL? = nil, backup: URL? = nil) -> Outcome {
        let t = Loc.hookInstall
        if agent == .copilot || agent == .opencode {
            return removeOwnedFile(for: agent, file: file)
        }
        if agent == .codex {
            return removeCodexHooks(files: .told(file: file, backup: backup))
        }
        let defaults = files(for: agent)
        guard let file = file ?? defaults?.file, let backup = backup ?? defaults?.backup else {
            return Outcome(ok: true, lines: [t.noSettingsFileNothingToRemove])
        }
        do {
            guard let root = try SettingsFile.load(at: file) else {
                return Outcome(ok: true, lines: [t.noSettingsFileNothingToRemove])
            }
            try SettingsFile.backup(from: file, to: backup)
            try SettingsFile.write(HookConfig.uninstall(from: root), to: file)
            return Outcome(ok: true, lines: [t.removedHooks])
        } catch {
            return Outcome(ok: false, lines: [t.uninstallFailed("\(error)"), t.notModified])
        }
    }

    /// How many of the agent's events run this bundle's CLI, or for OpenCode
    /// whether its plugin is the one this bundle writes (1) or not (0). An
    /// absent file counts as none; nil when the file exists and cannot be
    /// read. For Codex, what hooks.json holds, trusted or not
    /// (`codexHooksTrusted` counts the trusted ones).
    public static func hooksInstalled(for agent: AgentKind, cliPath: String = cliPath(),
                                      file: URL? = nil) -> Int? {
        switch agent {
        case .copilot:
            let file = file ?? Paths.copilotHooks
            guard let root = try? SettingsFile.load(at: file) ?? [:] else { return nil }
            return HookConfig.copilotEventsSetUp(in: root, cliPath: cliPath)
        case .opencode:
            let file = file ?? Paths.opencodePlugin
            guard FileManager.default.fileExists(atPath: file.path) else { return 0 }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            return HookConfig.isCurrentOpencodePlugin(text, cliPath: cliPath) ? 1 : 0
        case .codex:
            return codexHooksInstalled(cliPath: cliPath, files: .told(file: file))
        case .claude:
            guard let file = file ?? files(for: agent)?.file else { return 0 }
            guard let root = try? SettingsFile.load(at: file) ?? [:] else { return nil }
            let command = HookConfig.command(cliPath: cliPath, agent: agent)
            return HookConfig.events(for: agent).filter {
                HookConfig.installedCommand(in: root, event: $0) == command
            }.count
        }
    }

    /// Whether the agent's hooks are set up for this bundle's CLI: every one
    /// of its events, and for Codex every one trusted in its config.toml, or
    /// OpenCode's plugin as this bundle writes it; nil when a file cannot be
    /// read.
    public static func hooksSetUp(for agent: AgentKind, cliPath: String = cliPath(), file: URL? = nil) -> Bool? {
        let count = agent == .codex
            ? codexHooksTrusted(cliPath: cliPath, files: .told(file: file))
            : hooksInstalled(for: agent, cliPath: cliPath, file: file)
        return count.map { $0 == HookConfig.setUpCount(for: agent) }
    }

    /// Whether OpenCode's plugin is absent, holds exactly what this bundle would write, or holds something
    /// else: another copy's plugin (ours, but not this cliPath) or a file MySidepulse did not write.
    /// `hooksSetUp` alone reads false for both "nothing there" and "someone's stale copy", which the System
    /// and Health pages tell apart: absent reads Disabled with a Set Up warning, stale reads Invalid with
    /// the same button as its fix.
    public enum OpenCodePluginState: Equatable { case absent, current, stale }

    public static func opencodePluginState(cliPath: String = cliPath(), file: URL = Paths.opencodePlugin) -> OpenCodePluginState {
        switch ownership(of: .opencode, at: file) {
        case .absent: return .absent
        case .notOurs: return .stale
        case .ours: return hooksSetUp(for: .opencode, cliPath: cliPath, file: file) == true ? .current : .stale
        }
    }

    // MARK: a file MySidepulse owns whole: Copilot's hooks, OpenCode's plugin

    /// What is at an owned file's path: nothing, a file of ours, or one that
    /// is not ours, which nothing here replaces or deletes. A file that cannot
    /// be read or parsed is not ours either.
    enum Ownership: Equatable { case absent, ours, notOurs }

    static func ownership(of agent: AgentKind, at file: URL) -> Ownership {
        guard FileManager.default.fileExists(atPath: file.path) else { return .absent }
        switch agent {
        case .copilot:
            guard let root = try? SettingsFile.load(at: file) else { return .notOurs }
            return HookConfig.copilotFileIsOurs(root) ? .ours : .notOurs
        case .opencode:
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return .notOurs }
            return HookConfig.isOurOpencodePlugin(text) ? .ours : .notOurs
        case .claude, .codex:
            return .notOurs
        }
    }

    /// Writes Copilot's hook file or OpenCode's plugin whole, with its folder.
    /// Refused, with nothing touched, when the CLI is not a `mysidepulse`
    /// inside an app bundle, which the entries' marker needs, or when the
    /// file at the path is someone else's.
    static func installOwnedFile(for agent: AgentKind, cliPath: String, file: URL?) -> Outcome {
        let t = Loc.hookInstall
        guard let owned = ownedFile(for: agent) else { return Outcome(ok: false, lines: [t.notModified]) }
        let file = file ?? owned.file
        let command = HookConfig.command(cliPath: cliPath, agent: agent)
        guard command.contains(HookConfig.ourMarker),
              FileManager.default.isExecutableFile(atPath: cliPath) else {
            return Outcome(ok: false, lines: [t.noCLIInBundle(path: cliPath), t.notModified])
        }
        guard ownership(of: agent, at: file) != .notOurs else {
            return Outcome(ok: false, lines: [t.notOursLeftAlone(file: owned.name)])
        }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            if agent == .copilot {
                try SettingsFile.write(HookConfig.copilotFile(cliPath: cliPath), to: file)
            } else if hooksInstalled(for: agent, cliPath: cliPath, file: file) != 1 {
                // Written only when it changes: a running OpenCode server
                // reloads the plugin at every write.
                try Data(HookConfig.opencodePlugin(cliPath: cliPath).utf8).write(to: file, options: .atomic)
            }
        } catch {
            return Outcome(ok: false, lines: [t.installFailed("\(error)"), t.notModified])
        }
        // Read back rather than assumed, as the shared files are.
        guard hooksSetUp(for: agent, cliPath: cliPath, file: file) == true else {
            return Outcome(ok: false, lines: [t.installFailed(owned.name)])
        }
        let total = HookConfig.events(for: agent).count
        return Outcome(ok: true, lines: [agent == .opencode
            ? t.installedPlugin(agent: agent, command: command)
            : t.installed(total: total, agent: agent, command: command)])
    }

    /// Deletes Copilot's hook file or OpenCode's plugin when it is ours,
    /// whichever copy of the app wrote it, and leaves its folder. Someone
    /// else's file is left and said; an absent one is nothing to remove.
    static func removeOwnedFile(for agent: AgentKind, file: URL?) -> Outcome {
        let t = Loc.hookInstall
        guard let owned = ownedFile(for: agent) else { return Outcome(ok: true, lines: [t.noSettingsFileNothingToRemove]) }
        let file = file ?? owned.file
        switch ownership(of: agent, at: file) {
        case .absent:
            return Outcome(ok: true, lines: [t.noFileNothingToRemove(owned.name)])
        case .notOurs:
            return Outcome(ok: true, lines: [t.notOursLeftAlone(file: owned.name)])
        case .ours:
            do {
                try FileManager.default.removeItem(at: file)
                return Outcome(ok: true, lines: [t.removedFile(owned.name)])
            } catch {
                return Outcome(ok: false, lines: [t.uninstallFailed(error.localizedDescription)])
            }
        }
    }

    // MARK: Claude Code — ~/.claude/settings.json

    public static func installClaudeHooks(cliPath: String = cliPath(),
                                          settings: URL = Paths.claudeSettings,
                                          backup: URL = Paths.claudeSettingsBackup) -> Outcome {
        installHooks(for: .claude, cliPath: cliPath, file: settings, backup: backup)
    }

    public static func removeClaudeHooks(settings: URL = Paths.claudeSettings,
                                         backup: URL = Paths.claudeSettingsBackup) -> Outcome {
        removeHooks(for: .claude, file: settings, backup: backup)
    }

    public static func claudeHooksInstalled(cliPath: String = cliPath(),
                                            settings: URL = Paths.claudeSettings) -> Int? {
        hooksInstalled(for: .claude, cliPath: cliPath, file: settings)
    }

    // MARK: Codex — ~/.codex/hooks.json, and its trust in ~/.codex/config.toml

    /// Codex's two files and the name its trust keys give the hooks file.
    /// `live` is `~/.codex`; a test passes a temporary home, so nothing it does
    /// can reach the real one.
    public struct CodexFiles: Equatable {
        public var hooks: URL
        public var hooksBackup: URL
        public var config: URL
        public var configBackup: URL
        /// The hooks file as Codex names it in a trust key.
        public var trustName: String

        public init(home: URL) {
            hooks = home.appendingPathComponent("hooks.json")
            hooksBackup = home.appendingPathComponent("hooks.json.backup-mysidepulse")
            config = home.appendingPathComponent("config.toml")
            configBackup = home.appendingPathComponent("config.toml.backup-mysidepulse")
            trustName = home.resolvingSymlinksInPath().appendingPathComponent("hooks.json").path
        }

        public static var live: CodexFiles {
            var files = CodexFiles(home: Paths.codexHome)
            files.hooks = Paths.codexHooks
            files.hooksBackup = Paths.codexHooksBackup
            files.config = Paths.codexConfig
            files.configBackup = Paths.codexConfigBackup
            files.trustName = Paths.codexHooksTrustName
            return files
        }

        /// What the generic entry points are told: no file is the live home;
        /// a hooks file keeps config.toml in its own folder.
        static func told(file: URL?, backup: URL? = nil) -> CodexFiles {
            guard let file else { return .live }
            var files = CodexFiles(home: file.deletingLastPathComponent())
            files.hooks = file
            if let backup { files.hooksBackup = backup }
            return files
        }
    }

    static let codexHooksName = "~/.codex/hooks.json"
    static let codexConfigName = "~/.codex/config.toml"

    enum CodexFailure: Error, CustomStringConvertible {
        case configNotText, stateNotRewritable
        var description: String {
            switch self {
            case .configNotText: return Loc.hookInstall.configNotText(file: codexConfigName)
            case .stateNotRewritable: return Loc.hookInstall.stateNotRewritable(file: codexConfigName)
            }
        }
    }

    /// config.toml as text: empty when absent, an error when it cannot be
    /// read as UTF-8, which is never treated as empty: the write would
    /// replace the user's whole file with our tables.
    static func codexConfigText(_ config: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: config.path) else { return "" }
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { throw CodexFailure.configNotText }
        return text
    }

    static func writeText(_ text: String, to file: URL) throws {
        do { try text.write(to: file, atomically: true, encoding: .utf8) }
        catch { throw SettingsFile.Failure.writeFailed(error.localizedDescription) }
    }

    /// The 12 hooks into hooks.json, then their trust into config.toml:
    /// without the second, Codex lists the hooks and never runs them. Both
    /// files are read and every refusal decided before either is written; a
    /// failure between the two writes says which file landed. config.toml is
    /// written only when the trust changes it.
    public static func installCodexHooks(cliPath: String = cliPath(), files: CodexFiles = .live) -> Outcome {
        let t = Loc.hookInstall
        let command = HookConfig.command(cliPath: cliPath, agent: .codex)
        let events = HookConfig.codexEvents
        // A hook command pointing at a missing binary fails silently, and an
        // entry without the marker could never be recognised again.
        guard command.contains(HookConfig.ourMarker),
              FileManager.default.isExecutableFile(atPath: cliPath) else {
            return Outcome(ok: false, lines: [t.noCLIInBundle(path: cliPath), t.codexNotModified])
        }
        var written: [String] = []
        do {
            let root = try SettingsFile.load(at: files.hooks) ?? [:]
            let configText = try codexConfigText(files.config)
            let edited = HookConfig.install(into: root, command: command, agent: .codex)
            let entries = CodexHookTrust.entries(hooksFile: files.trustName, root: edited, command: command)
            guard let trusted = CodexHookTrust.trusting(configText, entries: entries,
                                                        ourHashes: CodexHookTrust.hashes(command: command)) else {
                throw CodexFailure.stateNotRewritable
            }
            try SettingsFile.backup(from: files.hooks, to: files.hooksBackup)
            try SettingsFile.write(edited, to: files.hooks)
            written.append(codexHooksName)
            let configWritten = trusted != configText
            if configWritten {
                try SettingsFile.backup(from: files.config, to: files.configBackup)
                try writeText(trusted, to: files.config)
                written.append(codexConfigName)
            }
            // Count what actually landed rather than assuming, as for Claude
            // Code's file.
            let missing = events.filter { HookConfig.installedCommand(in: edited, event: $0) != command }
            let total = events.count
            var lines = missing.isEmpty
                ? [t.installed(total: total, agent: .codex, command: command)]
                : [t.installedPartial(installed: total - missing.count, total: total, command: command),
                   t.declinedToTouch(missing.joined(separator: ", ")),
                   t.declinedShapeNote(file: codexHooksName)]
            if !entries.isEmpty { lines.append(t.trustedInCodex(file: codexConfigName)) }
            if FileManager.default.fileExists(atPath: files.hooksBackup.path) {
                lines.append(t.backupWritten(path: files.hooksBackup.path))
            }
            if configWritten, FileManager.default.fileExists(atPath: files.configBackup.path) {
                lines.append(t.backupWritten(path: files.configBackup.path))
            }
            return Outcome(ok: missing.isEmpty, lines: lines)
        } catch {
            return Outcome(ok: false, lines: [t.installFailed("\(error)"), written.isEmpty
                ? t.codexNotModified : t.writtenBeforeFailure(written.joined(separator: ", "))])
        }
    }

    /// The trust goes first, named after the hooks as they still sit in the
    /// file, whichever copy of the app wrote them, and after this copy's
    /// command, so a table of ours is known by its hash even once the file
    /// naming it is gone; then the hooks. A config.toml that cannot be read
    /// is left as it is and said: the hooks still go, since hooks left behind
    /// would run a command that may soon be gone.
    public static func removeCodexHooks(cliPath: String = cliPath(), files: CodexFiles = .live) -> Outcome {
        let t = Loc.hookInstall
        var written: [String] = []
        var trustLines: [String] = []
        var ok = true
        do {
            let root = try SettingsFile.load(at: files.hooks)
            if let configText = try? codexConfigText(files.config) {
                let ours = CodexHookTrust.ourEntries(hooksFile: files.trustName, root: root ?? [:]).map(\.entry)
                let hashes = Set(ours.map(\.hash))
                    .union(CodexHookTrust.hashes(command: HookConfig.command(cliPath: cliPath, agent: .codex)))
                if let untrusted = CodexHookTrust.untrusting(configText, keys: Set(ours.map(\.key)),
                                                             ourHashes: hashes) {
                    try SettingsFile.backup(from: files.config, to: files.configBackup)
                    try writeText(untrusted, to: files.config)
                    written.append(codexConfigName)
                    trustLines.append(t.trustRemoved(file: codexConfigName))
                }
            } else {
                ok = false
                trustLines.append(t.trustLeft(file: codexConfigName))
            }
            guard let root else {
                return Outcome(ok: ok, lines: [t.noSettingsFileNothingToRemove] + trustLines)
            }
            try SettingsFile.backup(from: files.hooks, to: files.hooksBackup)
            try SettingsFile.write(HookConfig.uninstall(from: root), to: files.hooks)
            return Outcome(ok: ok, lines: [t.removedHooks] + trustLines)
        } catch {
            return Outcome(ok: false, lines: [t.uninstallFailed("\(error)"), written.isEmpty
                ? t.codexNotModified : t.writtenBeforeFailure(written.joined(separator: ", "))])
        }
    }

    /// How many of Codex's events run this bundle's CLI in hooks.json,
    /// trusted or not; nil when the file cannot be read.
    public static func codexHooksInstalled(cliPath: String = cliPath(), files: CodexFiles = .live) -> Int? {
        guard let root = try? SettingsFile.load(at: files.hooks) ?? [:] else { return nil }
        let command = HookConfig.command(cliPath: cliPath, agent: .codex)
        return HookConfig.codexEvents.filter { HookConfig.installedCommand(in: root, event: $0) == command }.count
    }

    /// How many of those Codex trusts and has not switched off: the hooks it
    /// runs. Nil when either file cannot be read.
    public static func codexHooksTrusted(cliPath: String = cliPath(), files: CodexFiles = .live) -> Int? {
        guard let root = try? SettingsFile.load(at: files.hooks) ?? [:],
              let text = try? codexConfigText(files.config) else { return nil }
        let states = CodexHookTrust.states(in: text)
        let command = HookConfig.command(cliPath: cliPath, agent: .codex)
        return CodexHookTrust.entries(hooksFile: files.trustName, root: root, command: command)
            .filter { CodexHookTrust.isTrusted($0, in: states) }.count
    }

    // MARK: every agent at once, for the CLI and the installer

    /// `install-hooks`: Claude Code's hooks, and every other agent's, in
    /// their order, when it is on this Mac. One that is not there is said and
    /// skipped, never a failure.
    public static func installAllHooks(cliPath: String = cliPath(),
                                       installed: (AgentKind) -> Bool = isInstalled) -> Outcome {
        var ok = true
        var lines: [String] = []
        for agent in AgentKind.allCases {
            guard agent == .claude || installed(agent) else {
                lines.append(Loc.hookInstall.notInstalledSkipped(agent))
                continue
            }
            let outcome = installHooks(for: agent, cliPath: cliPath)
            ok = ok && outcome.ok
            lines += outcome.lines
        }
        return Outcome(ok: ok, lines: lines)
    }

    /// `uninstall-hooks`: every agent's, whether it is installed or not, so
    /// nothing of ours is left behind in a file an agent may read later.
    public static func removeAllHooks() -> Outcome {
        let outcomes = AgentKind.allCases.map { removeHooks(for: $0) }
        return Outcome(ok: outcomes.allSatisfy(\.ok), lines: outcomes.flatMap(\.lines))
    }

    // MARK: the terminal — ~/.zshrc

    /// False for an unreadable file, so the settings window still offers the
    /// button instead of hiding it behind a false "set up".
    public static func zshrcHasSnippet(zshrc: URL = Paths.zshrc) -> Bool {
        (try? String(contentsOf: zshrc, encoding: .utf8)).map(ShellInit.zshrcSourcesSnippet) ?? false
    }

    /// Appends the block to ~/.zshrc, creating the file if needed. A file that
    /// exists and cannot be read as UTF-8 is refused, never treated as empty:
    /// the atomic write would replace the whole file with just the block.
    public static func addToZshrc(cliPath: String = cliPath(), zshrc: URL = Paths.zshrc) -> Outcome {
        let t = Loc.hookInstall
        guard FileManager.default.isExecutableFile(atPath: cliPath) else {
            return Outcome(ok: false, lines: [t.noCLIAtPath(cliPath)])
        }
        var existing = ""
        if FileManager.default.fileExists(atPath: zshrc.path) {
            guard let current = try? String(contentsOf: zshrc, encoding: .utf8) else {
                return Outcome(ok: false, lines: [t.couldNotReadZshrc])
            }
            existing = current
        }
        guard let text = ShellInit.zshrcAppending(ShellInit.zshrcLine(mysidepulsePath: cliPath),
                                                  to: existing) else {
            return Outcome(ok: true, lines: [t.alreadySourcesSnippet])
        }
        return write(text, to: zshrc, done: t.addedBlock)
    }

    /// Removes what `ShellInit.zshrcRemoving` owns: the block, and any
    /// hand-written eval line of ours. Same read guard as `addToZshrc`.
    public static func removeFromZshrc(zshrc: URL = Paths.zshrc) -> Outcome {
        let t = Loc.hookInstall
        guard FileManager.default.fileExists(atPath: zshrc.path) else {
            return Outcome(ok: true, lines: [t.zshrcDoesNotExist])
        }
        guard let existing = try? String(contentsOf: zshrc, encoding: .utf8) else {
            return Outcome(ok: false, lines: [t.couldNotReadZshrc])
        }
        guard let text = ShellInit.zshrcRemoving(from: existing) else {
            return Outcome(ok: true, lines: [t.doesNotSourceSnippet])
        }
        return write(text, to: zshrc, done: t.removedBlock)
    }

    private static func write(_ text: String, to zshrc: URL, done: String) -> Outcome {
        let t = Loc.hookInstall
        do {
            try text.write(to: zshrc, atomically: true, encoding: .utf8)
            return Outcome(ok: true, lines: [done])
        } catch {
            return Outcome(ok: false,
                           lines: [t.couldNotWriteZshrc(error.localizedDescription)])
        }
    }
}

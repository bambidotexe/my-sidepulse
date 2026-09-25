import Foundation
import MachO
import MySidepulseCore

/// Setting up and removing the hooks that feed the app: its entries in Claude
/// Code's settings.json and in Codex's hooks.json, and its block in ~/.zshrc.
/// Shared by `mysidepulse install-hooks` / `uninstall-hooks` and the settings
/// window, so both do the same thing and both report what actually landed.
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

    /// Where an agent keeps its hooks, and the copy taken before it is touched.
    static func files(for agent: AgentKind) -> (file: URL, backup: URL, name: String) {
        switch agent {
        case .claude: return (Paths.claudeSettings, Paths.claudeSettingsBackup, "~/.claude/settings.json")
        case .codex: return (Paths.codexHooks, Paths.codexHooksBackup, "~/.codex/hooks.json")
        }
    }

    /// Whether Codex is on this Mac: its home exists. Its hooks file is
    /// created when the hooks are set up, so the file itself proves nothing.
    public static func codexInstalled(home: URL = Paths.codexHome) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: home.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    public static func installHooks(for agent: AgentKind, cliPath: String = cliPath(),
                                    file: URL? = nil, backup: URL? = nil) -> Outcome {
        let t = Loc.hookInstall
        let defaults = files(for: agent)
        let file = file ?? defaults.file
        let backup = backup ?? defaults.backup
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
            let edited = HookConfig.install(into: root, command: command, events: events)
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
                   t.declinedShapeNote(file: defaults.name)]
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
        let defaults = files(for: agent)
        let file = file ?? defaults.file
        let backup = backup ?? defaults.backup
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

    /// How many of the agent's events run this bundle's CLI. An absent file
    /// counts as none; nil when the file exists and cannot be read.
    public static func hooksInstalled(for agent: AgentKind, cliPath: String = cliPath(),
                                      file: URL? = nil) -> Int? {
        let file = file ?? files(for: agent).file
        guard let root = try? SettingsFile.load(at: file) ?? [:] else { return nil }
        let command = HookConfig.command(cliPath: cliPath, agent: agent)
        return HookConfig.events(for: agent).filter {
            HookConfig.installedCommand(in: root, event: $0) == command
        }.count
    }

    /// Whether every one of the agent's events runs this bundle's CLI; nil
    /// when the file cannot be read.
    public static func hooksSetUp(for agent: AgentKind, cliPath: String = cliPath()) -> Bool? {
        hooksInstalled(for: agent, cliPath: cliPath).map { $0 == HookConfig.events(for: agent).count }
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

    // MARK: Codex — ~/.codex/hooks.json

    public static func installCodexHooks(cliPath: String = cliPath(),
                                         hooks: URL = Paths.codexHooks,
                                         backup: URL = Paths.codexHooksBackup) -> Outcome {
        installHooks(for: .codex, cliPath: cliPath, file: hooks, backup: backup)
    }

    public static func removeCodexHooks(hooks: URL = Paths.codexHooks,
                                        backup: URL = Paths.codexHooksBackup) -> Outcome {
        removeHooks(for: .codex, file: hooks, backup: backup)
    }

    public static func codexHooksInstalled(cliPath: String = cliPath(),
                                           hooks: URL = Paths.codexHooks) -> Int? {
        hooksInstalled(for: .codex, cliPath: cliPath, file: hooks)
    }

    // MARK: every agent at once, for the CLI and the installer

    /// `install-hooks`: Claude Code's hooks, and Codex's when Codex is on this
    /// Mac. A Codex that is not there is said and skipped, never a failure.
    public static func installAllHooks(cliPath: String = cliPath(),
                                       codexInstalled: Bool = codexInstalled()) -> Outcome {
        let claude = installClaudeHooks(cliPath: cliPath)
        guard codexInstalled else {
            return Outcome(ok: claude.ok, lines: claude.lines + [Loc.hookInstall.codexNotInstalledSkipped])
        }
        let codex = installCodexHooks(cliPath: cliPath)
        return Outcome(ok: claude.ok && codex.ok, lines: claude.lines + codex.lines)
    }

    /// `uninstall-hooks`: both files, whether Codex is installed or not, so
    /// nothing of ours is left behind in a hooks file Codex may read later.
    public static func removeAllHooks() -> Outcome {
        let claude = removeClaudeHooks()
        let codex = removeCodexHooks()
        return Outcome(ok: claude.ok && codex.ok, lines: claude.lines + codex.lines)
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

import Foundation
import MachO
import MySidepulseCore

/// Setting up and removing the two hooks that feed the app: its entries in
/// Claude Code's settings.json and its block in ~/.zshrc. Shared by
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

    // MARK: Claude Code — ~/.claude/settings.json

    public static func installClaudeHooks(cliPath: String = cliPath(),
                                          settings: URL = Paths.claudeSettings,
                                          backup: URL = Paths.claudeSettingsBackup) -> Outcome {
        let t = Loc.hookInstall
        let command = "\(cliPath) hook"
        // A hook command pointing at a missing binary fails silently — Claude
        // Code just never fires it — and an entry without the marker could
        // never be recognised again, let alone removed.
        guard command.contains(HookConfig.ourMarker),
              FileManager.default.isExecutableFile(atPath: cliPath) else {
            return Outcome(ok: false, lines: [t.noCLIInBundle(path: cliPath), t.notModified])
        }
        do {
            let root = try SettingsFile.load(at: settings) ?? [:]
            try SettingsFile.backup(from: settings, to: backup)
            let edited = HookConfig.install(into: root, command: command)
            try SettingsFile.write(edited, to: settings)
            // Count what actually landed rather than assuming: HookConfig
            // declines shapes it does not understand (a non-object `hooks`, a
            // non-array event), and reporting success over a declined edit is
            // how a silent gap in the hook coverage is born.
            let missing = HookConfig.events.filter {
                HookConfig.installedCommand(in: edited, event: $0) != command
            }
            let total = HookConfig.events.count
            var lines = missing.isEmpty
                ? [t.installed(total: total, command: command)]
                : [t.installedPartial(installed: total - missing.count, total: total,
                                      command: command),
                   t.declinedToTouch(missing.joined(separator: ", ")),
                   t.declinedShapeNote]
            if FileManager.default.fileExists(atPath: backup.path) {
                lines.append(t.backupWritten(path: backup.path))
            }
            return Outcome(ok: missing.isEmpty, lines: lines)
        } catch {
            return Outcome(ok: false, lines: [t.installFailed("\(error)"), t.notModified])
        }
    }

    public static func removeClaudeHooks(settings: URL = Paths.claudeSettings,
                                         backup: URL = Paths.claudeSettingsBackup) -> Outcome {
        let t = Loc.hookInstall
        do {
            guard let root = try SettingsFile.load(at: settings) else {
                return Outcome(ok: true, lines: [t.noSettingsFileNothingToRemove])
            }
            try SettingsFile.backup(from: settings, to: backup)
            try SettingsFile.write(HookConfig.uninstall(from: root), to: settings)
            return Outcome(ok: true, lines: [t.removedHooks])
        } catch {
            return Outcome(ok: false, lines: [t.uninstallFailed("\(error)"), t.notModified])
        }
    }

    /// How many of the events run this bundle's CLI. An absent settings file
    /// counts as none; nil when the file exists and cannot be read.
    public static func claudeHooksInstalled(cliPath: String = cliPath(),
                                            settings: URL = Paths.claudeSettings) -> Int? {
        guard let root = try? SettingsFile.load(at: settings) ?? [:] else { return nil }
        let command = "\(cliPath) hook"
        return HookConfig.events.filter {
            HookConfig.installedCommand(in: root, event: $0) == command
        }.count
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

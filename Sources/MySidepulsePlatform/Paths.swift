import Foundation

public enum Paths {
    public static var appSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MySidepulse")
    }
    public static var journal: URL { appSupport.appendingPathComponent("journal.jsonl") }
    public static var journalRotated: URL { appSupport.appendingPathComponent("journal.1.jsonl") }
    public static var controlSocket: URL { appSupport.appendingPathComponent("control.sock") }
    public static var config: URL { appSupport.appendingPathComponent("config.json") }
    public static var updates: URL { appSupport.appendingPathComponent("updates", isDirectory: true) }
    /// Written by `scripts/install.sh` before it opens the bundle, read once by the launch that follows:
    /// a reinstall opens no window (`QuietLaunch`).
    public static var quietLaunch: URL { appSupport.appendingPathComponent("quiet-launch") }
    public static var claudeSessions: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
    }
    /// Both user files below are resolved: a dotfiles-managed one is often a
    /// symlink, and an atomic write through the unresolved path would replace
    /// the link with a plain file.
    public static var claudeSettings: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json").resolvingSymlinksInPath()
    }
    public static var zshrc: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".zshrc").resolvingSymlinksInPath()
    }
    public static var claudeSettingsBackup: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json.backup-mysidepulse")
    }
}

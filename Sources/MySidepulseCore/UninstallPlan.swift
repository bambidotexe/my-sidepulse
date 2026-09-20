import Foundation

/// What taking MySidepulse off a Mac has to remove, and the part of it that can only happen once this
/// process has gone.
///
/// Dragging the bundle to the Trash removes the app and nothing else. The launch agent stays, and launchd
/// goes on trying to start a binary that is not there at every login; the Claude Code hooks stay, and fire
/// at a missing command once per event; the journal, the config and the ntfy topic stay in Application
/// Support; the zsh line stays in `.zshrc` and runs at every shell.
public enum UninstallPlan {
    /// Every launchd job this app has ever bootstrapped: the one it uses and the one it used under its
    /// former name. Both are booted out, whether or not either is loaded, because a job that is loaded is
    /// still listed after its plist has gone and only a logout would clear it.
    public static let jobLabels = ["io.mysidepulse.agent", "io.sidepulse.agent"]

    /// The command line the Makefile offers to link. `/usr/local/bin` is root-owned, so the app can name
    /// this but not remove it; the caller says so and leaves the one `sudo` line to the user.
    public static let cliSymlink = "/usr/local/bin/mysidepulse"

    /// How long the helper waits for this process to go before giving up, in tenths of a second. A helper
    /// that could spin for ever is worse than one that stops: what it does after the wait is a `bootout`
    /// of a job that has exited and an `rm` of a folder nothing holds open.
    public static let helperWaitTenths = 600

    /// What runs **after** this process has gone, and why none of it can run before.
    ///
    /// `launchctl bootout` on the job this process is running as kills it where it stands, before the
    /// strip has been darkened and before the uninstall has finished; and removing the support folder
    /// while the app is still up only means the journal writes it back. So both wait for the pid.
    /// The caches, the HTTP storage and the saved window state go with the folder. They are not dangerous,
    /// but they are named after the bundle identifier and belong to nothing else, and an uninstall that
    /// leaves them is not the fresh Mac it claims to be.
    public static func helperScript(pid: Int32, uid: UInt32, supportDirectory: String,
                                    bundleIdentifier: String, home: String) -> String {
        let library = home + "/Library"
        var lines = [
            "i=0",
            "while /bin/kill -0 \(pid) 2>/dev/null && [ $i -lt \(helperWaitTenths) ]; do /bin/sleep 0.1; i=$((i+1)); done",
        ]
        lines += jobLabels.map { "/bin/launchctl bootout gui/\(uid)/\($0) 2>/dev/null" }
        // Before the file is removed, or cfprefsd writes its cache back over the gap.
        lines.append("/usr/bin/defaults delete \(bundleIdentifier) 2>/dev/null")
        let paths = [
            supportDirectory,
            "\(library)/Preferences/\(bundleIdentifier).plist",
            "\(library)/Caches/\(bundleIdentifier)",
            "\(library)/HTTPStorages/\(bundleIdentifier)",
            "\(library)/HTTPStorages/\(bundleIdentifier).binarycookies",
            "\(library)/Saved Application State/\(bundleIdentifier).savedState",
        ]
        lines.append("/bin/rm -rf " + paths.map(shellQuoted).joined(separator: " "))
        // One per host identifier, so a glob rather than a path; `find` keeps the glob away from a home
        // folder whose name has a space in it.
        lines.append("/usr/bin/find \(shellQuoted(library + "/Preferences/ByHost")) -maxdepth 1 -name \(shellQuoted(bundleIdentifier + ".*.plist")) -delete 2>/dev/null")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Single quotes, with any quote in the path closed and reopened around an escaped one. The path is
    /// the user's home folder and therefore theirs to name.
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

import Foundation

/// Giving the running app back to launchd, from a process that outlives it.
///
/// A launch that did not come from the agent bootstraps the job, and `RunAtLoad` makes launchd spawn it at
/// once — but that spawn finds this instance already running and terminates itself, which is right, because
/// two copies would fight over the control socket and the journal. What is left is a job that is loaded with
/// nothing running, and an app that LaunchServices started and `KeepAlive` does not supervise: a crash would
/// not be recovered until the next login. That is the state a copy dragged out of the disk image lands in,
/// and the state `doctor` reports as `agent installed, but this process was not started by it`.
///
/// `launchctl kickstart` on the job cannot be run from inside the app, because the job is what would replace
/// the process running it. So it waits for the pid, exactly as the uninstall's helper does.
public enum LaunchdHandover {
    /// How long to wait for the app to go, and then for the job to come up, in tenths of a second.
    public static let waitTenths = 600
    public static let confirmTenths = 50

    /// The script is written so that **the worst outcome is the one it started from, never a Mac with no
    /// MySidepulse on it.** If the job does not come up within `confirmTenths`, the bundle is opened again
    /// by hand: an app that failed to change hands is a warning in Settings, an app that vanished after a
    /// double-click is a broken install.
    public static func script(pid: Int32, uid: UInt32, label: String, bundlePath: String,
                              executablePath: String) -> String {
        [
            "i=0",
            "while /bin/kill -0 \(pid) 2>/dev/null && [ $i -lt \(waitTenths) ]; do /bin/sleep 0.1; i=$((i+1)); done",
            "/bin/launchctl kickstart gui/\(uid)/\(label) 2>/dev/null",
            "i=0",
            "while [ $i -lt \(confirmTenths) ]; do",
            "  /bin/sleep 0.1",
            "  /usr/bin/pgrep -f \(shellQuoted(executablePath)) >/dev/null 2>&1 && exit 0",
            "  i=$((i+1))",
            "done",
            "/usr/bin/open \(shellQuoted(bundlePath))",
        ].joined(separator: "\n") + "\n"
    }

    /// Single quotes, with any quote in the path closed and reopened around an escaped one.
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

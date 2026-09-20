import Foundation

/// A launch the user did not ask for, and which therefore opens no window.
///
/// Opening the bundle is how a person asks for Settings, so `applicationShouldHandleReopen` shows the
/// window. `scripts/install.sh` opens the bundle too, for its own reasons, and what the user got was a
/// window nobody asked for: a reinstall should put the new version in place and otherwise be invisible.
///
/// The request outlives the process it was sent to. The launch the installer makes bootstraps the agent
/// and hands over (`LaunchdHandover`), so it quits within the second, and the open request is delivered
/// again to the copy launchd starts in its place. That is why this is a file and not a launch argument:
/// the argument belongs to the process that went away, and launchd's own `ProgramArguments` carry none.
public enum QuietLaunch {
    /// How long a marker counts for. Long enough to cover the installer's launch and the hand-over that
    /// follows it, short enough that one left behind by an install that died cannot silence a launch the
    /// user asks for by hand minutes later.
    public static let window: TimeInterval = 120

    /// How long after such a launch an open request still counts as the installer's. It covers the
    /// hand-over, and nothing like long enough to swallow a double-click the user means.
    public static let reopenGrace: TimeInterval = 15

    public static func isFresh(writtenAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(writtenAt)
        // A marker from the future is a clock that moved, not a fresh marker.
        return age >= 0 && age <= window
    }

    /// Whether an open request arriving now belongs to the quiet launch that started at `launchedAt`.
    public static func silences(reopenAt: Date, quietLaunchAt: Date) -> Bool {
        let age = reopenAt.timeIntervalSince(quietLaunchAt)
        return age >= 0 && age <= reopenGrace
    }
}

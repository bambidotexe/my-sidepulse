import Foundation

/// The rules that turn what was found into a level. Every page that reports one of these states reads it
/// from here, so the System page's rows and the Health page's agree.
public enum HealthRules {
    /// Something MySidepulse needs set up to do a job, a macOS permission or one of its hooks: green while
    /// it is in place; missing, **red when the wizard marks it required** (the Claude Code hooks: without
    /// them the strip never shows Claude) and orange otherwise (a feature that needs it cannot work, and the
    /// rest can).
    public static func grant(held: Bool, required: Bool) -> HealthLevel {
        if held { return .good }
        return required ? .failure : .warning
    }

    /// The launch agent is both "open at login" and "come back after a crash", so off is more than a
    /// preference: a crash would leave the strip frozen and the phone silent until MySidepulse is opened
    /// again. Orange either way it is missing.
    public static func launchAgent(_ state: LaunchAgentState) -> HealthLevel {
        state == .enabled ? .good : .warning
    }

    /// Whether a file in `~/Library/Logs/DiagnosticReports` is a crash report of the process named
    /// `process`: the name, a dash, the date the system stamps (`MySidepulseApp-2026-09-21-101010.ips`), and
    /// the extension of a crash report old or new. A user fault of the same process (`ExcUserFault_…`), or
    /// another process whose name merely starts the same way, is not.
    public static func isCrashReport(fileName: String, process: String) -> Bool {
        guard fileName.hasPrefix(process + "-"), fileName.hasSuffix(".ips") || fileName.hasSuffix(".crash")
        else { return false }
        let stamp = fileName.dropFirst(process.count + 1)
        // yyyy-MM-dd-HHmmss, digits where the date's digits go.
        let pattern = Array("0000-00-00-000000")
        guard stamp.count > pattern.count else { return false }
        return zip(stamp, pattern).allSatisfy { char, slot in slot == "-" ? char == "-" : char.isASCII && char.isNumber }
    }
}

/// What the launch agent says about this process, as `LoginService` reports it.
public enum LaunchAgentState: Equatable, Sendable {
    case enabled
    /// No agent: the switch on General is off.
    case disabled
    /// The agent is installed, but this process was opened by hand and is not the one launchd supervises,
    /// so a crash would not be recovered until the next login.
    case notSupervised
}

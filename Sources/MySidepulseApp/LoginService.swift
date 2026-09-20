import Foundation
import ServiceManagement
import MySidepulseCore
import MySidepulsePlatform

/// Auto-start *and* auto-restart.
///
/// A plain login item starts the app at login and does nothing else: a crash
/// leaves the strip frozen on whatever it was showing and the phone silent,
/// with nothing to notice or fix it. A LaunchAgent does both jobs, and
/// `KeepAlive/SuccessfulExit = false` puts the line where it belongs — launchd
/// brings the app back when it dies badly, and leaves it alone when the user
/// quits it on purpose, because that exits zero.
///
/// The agent is a plain plist in `~/Library/LaunchAgents`, bootstrapped with
/// `launchctl`, rather than one registered from inside the bundle through
/// `SMAppService.agent`. launchd pins a LightWeight Code Requirement to a job
/// registered that way, so such a job outlives a reinstall only for as long as
/// the code identity behind it holds; when it does not, the next spawn is
/// refused —
///
///     OS_REASON_CODESIGNING | Launch Constraint Violation … launch type 0
///     Service could not initialize: Unable to get updated LWCR … error 0x16
///
/// — while `SMAppService.status` keeps reporting `.enabled` regardless, and
/// neither re-registering nor `launchctl bootout` clears it. A bootstrapped
/// plist has no LWCR and no Background Task Management record to go stale, so
/// it rests on no identity staying the same and survives any number of
/// reinstalls.
enum LoginService {
    static let jobLabel = "io.mysidepulse.agent"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(jobLabel).plist")
    }

    private static var domainTarget: String { "gui/\(getuid())" }
    private static var serviceTarget: String { "\(domainTarget)/\(jobLabel)" }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// Whether launchd started us from our own agent job, as opposed to
    /// LaunchServices (`open`, `make install`, a double-click), which sets this
    /// to `application.io.mysidepulse.app.…` instead. It is the only proof that
    /// a crash would actually be restarted: `KeepAlive` supervises the instance
    /// launchd spawned itself and nothing else.
    static var launchedByOwnAgent: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == jobLabel
    }

    /// What `doctor` and the menu report. A plist on disk is not enough to
    /// claim success — the question is whether *this* process is the one
    /// launchd is supervising.
    static var statusDescription: String {
        guard isEnabled else { return "disabled" }
        return launchedByOwnAgent ? "enabled"
            : "agent installed, but this process was not started by it: no crash restart"
    }

    /// Unregisters an SMAppService login item or bundled agent if one is
    /// still enabled. Leaving either registered starts a second copy at
    /// login — survivable, since it terminates itself, but the stale entry
    /// also sits in System Settings for ever.
    static func migrateFromLoginItem() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        }
        let bundled = SMAppService.agent(plistName: "\(jobLabel).plist")
        if bundled.status == .enabled { try? bundled.unregister() }
    }

    /// Write the plist and (re)bootstrap it. Idempotent: safe to run on every
    /// launch that did not come from the agent itself.
    static func install() throws {
        guard let executable = Bundle.main.executableURL else {
            throw LoginServiceError.noExecutablePath
        }
        let job: [String: Any] = [
            "Label": jobLabel,
            // Absolute, and taken from the running binary, so the agent points
            // at whichever copy installed it.
            "ProgramArguments": [executable.path],
            "RunAtLoad": true,
            // The whole point: restart on a bad exit — crash, signal, kill —
            // and stay out of the way of a deliberate Quit, which exits zero.
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
        // Already running as the job: it is loaded, it points here, and
        // bootstrapping over it would mean booting ourselves out mid-call.
        guard !launchedByOwnAgent else { return }
        // Bootstrapping over a live job fails, so drop it first. A job that is
        // not there makes bootout fail too, which is why neither is checked.
        _ = launchctl(["bootout", serviceTarget])
        guard launchctl(["bootstrap", domainTarget, plistURL.path]) else {
            throw LoginServiceError.bootstrapFailed
        }
    }

    /// Hand this process over to launchd, and say whether the caller should now quit.
    ///
    /// After `install()` the job is bootstrapped but nothing is running as it: launchd's `RunAtLoad` spawn
    /// found this instance already up and terminated itself, as a second copy must. So the app the user is
    /// looking at is one LaunchServices started, which `KeepAlive` does not supervise, and a crash would
    /// cost them the rest of the day. `make install` closed that gap from outside with `killall` and
    /// `launchctl kickstart -k`; a copy dragged out of the disk image has nobody to run those.
    ///
    /// `kickstart` is what the job would replace this process with, so it cannot be run from in here. A
    /// detached helper waits for this pid and runs it, and opens the bundle again if the job does not come
    /// up: an app that failed to change hands is a warning in Settings, an app that vanished after a
    /// double-click is a broken install.
    ///
    /// Returns false when the helper could not be started, and then nothing quits: the app stays as it is
    /// and Settings says what is missing.
    static func handOverToLaunchd() -> Bool {
        guard !launchedByOwnAgent, let executable = Bundle.main.executableURL else { return false }
        let script = LaunchdHandover.script(pid: getpid(), uid: getuid(), label: jobLabel,
                                            bundlePath: Bundle.main.bundleURL.path,
                                            executablePath: executable.path)
        do {
            try DetachedProcess.spawn(executable: "/bin/sh", arguments: ["-c", script], environment: [:])
            return true
        } catch {
            return false
        }
    }

    /// Turning it off must not take MySidepulse down with it. `bootout` unloads
    /// the job *and kills the process running as it*, so when this process
    /// IS the job, bootout would kill the app mid-request before it could
    /// even delete the plist or answer the CLI. Removing the plist is what
    /// actually settles the question: nothing loads at the next login. A job
    /// already supervising this process is left running, and simply is not
    /// there next time.
    static func remove() throws {
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
        guard !launchedByOwnAgent else { return }
        _ = launchctl(["bootout", serviceTarget])
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

enum LoginServiceError: Error {
    case noExecutablePath
    case bootstrapFailed
}

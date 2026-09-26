import AppKit
import Foundation
import ServiceManagement
import MySidepulseCore
import MySidepulsePlatform

/// Everything MySidepulse put on this Mac outside its own bundle, taken off.
///
/// **Dragging the bundle to the Trash is not an uninstall.** It removes the app and nothing else: the
/// launch agent stays and launchd tries to start a binary that is not there at every login, every agent's
/// hooks fire at a missing command once per event, the zsh line runs at every shell, and
/// the journal, the settings and the ntfy topic stay in Application Support.
///
/// The order is the whole of it, and the last of it cannot run here at all: this process is usually the
/// launch agent's own job, so `launchctl bootout` would kill it where it stands, before the strip had been
/// darkened. That part, and the support folder the journal would otherwise write back, go to a detached
/// helper that waits for this pid (`UninstallPlan`).
enum Uninstall {
    /// What could not be done, already worded for the person reading it.
    struct Outcome {
        var failed: [String] = []
    }

    @MainActor
    static func removeEverythingOutsideTheBundle() -> Outcome {
        let t = Loc.settings.general
        var outcome = Outcome()

        // The hooks first: they name a binary inside the bundle, which is still there.
        // nil when a hook file cannot be read, and the removal is still worth trying then.
        // Copilot's hook file and OpenCode's plugin are MySidepulse's whole: removed whichever copy of
        // the app wrote them, and left when they are someone else's.
        for agent in AgentKind.allCases
        where HookInstaller.ownedFile(for: agent) != nil || HookInstaller.hooksInstalled(for: agent) ?? 1 > 0 {
            let result = HookInstaller.removeHooks(for: agent)
            if !result.ok {
                outcome.failed.append(t.uninstallHooksFailed(agent, result.lines.joined(separator: " ")))
            }
        }
        if HookInstaller.zshrcHasSnippet() {
            let result = HookInstaller.removeFromZshrc()
            if !result.ok { outcome.failed.append(t.uninstallZshFailed(result.lines.joined(separator: " "))) }
        }
        try? FileManager.default.removeItem(at: Paths.claudeSettingsBackup)
        try? FileManager.default.removeItem(at: Paths.codexHooksBackup)

        // The plist goes now so that nothing loads at the next login even if the helper never runs. The
        // job itself is booted out by the helper, once this process is no longer the thing running as it.
        do { try LoginService.remove() }
        catch { outcome.failed.append(t.uninstallAgentFailed(error.localizedDescription)) }
        LoginService.migrateFromLoginItem()

        // While the bundle the grants name is still where they name it: `tccutil reset` against a bundle
        // identifier with no bundle behind it fails, and nothing puts that right afterwards.
        let bundleID = Bundle.main.bundleIdentifier ?? "io.mysidepulse.app"
        _ = run("/usr/bin/tccutil", ["reset", "AppleEvents", bundleID])
        _ = NotificationGrant.reset(bundleIdentifier: bundleID)

        // Root-owned, so the app can only name it.
        if FileManager.default.fileExists(atPath: UninstallPlan.cliSymlink) {
            outcome.failed.append(t.uninstallCLILeft(UninstallPlan.cliSymlink))
        }
        return outcome
    }

    /// The Trash, not a delete: the app the user has just removed is still there to put back.
    @MainActor
    static func moveBundleToTrash(_ completion: @escaping @MainActor (String?) -> Void) {
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, error in
            let reason = error.map { Loc.settings.general.uninstallTrashFailed($0.localizedDescription) }
            DispatchQueue.main.async { completion(reason) }
        }
    }

    /// The last two steps, handed to a process that outlives this one. Started just before the quit.
    @MainActor
    static func startHelper() -> String? {
        let script = UninstallPlan.helperScript(
            pid: getpid(), uid: getuid(), supportDirectory: Paths.appSupport.path,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "io.mysidepulse.app",
            home: FileManager.default.homeDirectoryForCurrentUser.path)
        do {
            try DetachedProcess.spawn(executable: "/bin/sh", arguments: ["-c", script], environment: [:])
            return nil
        } catch {
            return Loc.settings.general.uninstallHelperFailed("\(error)")
        }
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

/// Notification authorization lives in usernoted's group preferences; dropping this app's entry and
/// restarting the daemon puts it back to "not asked yet", which no public API does. Without it a
/// reinstall inherits a decision the user made once and cannot be asked again.
enum NotificationGrant {
    static func reset(bundleIdentifier: String) -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist")
        guard let data = try? Data(contentsOf: url),
              var plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let apps = plist["apps"] as? [[String: Any]] else { return false }
        let kept = apps.filter { ($0["bundle-id"] as? String) != bundleIdentifier }
        guard kept.count != apps.count else { return true }
        plist["apps"] = kept
        guard let out = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0),
              (try? out.write(to: url)) != nil else { return false }
        for daemon in ["usernoted", "NotificationCenter"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            process.arguments = [daemon]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
        return true
    }
}

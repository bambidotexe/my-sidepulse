import AppKit
import CoreGraphics
import IOKit
import MySidepulseCore

/// Acknowledgement inputs: app-activation is push (NSWorkspace); input-idle
/// is polled at 500 ms ONLY while an ack-able state is displayed.
final class AttentionMonitor {
    var onActivity: ((String) -> Void)? // frontmost bundle id, on focus or input
    private var observer: NSObjectProtocol?
    private var timer: DispatchSourceTimer?

    func start() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication,
                      let bundle = app.bundleIdentifier else { return }
                self?.onActivity?(bundle)
        }
    }

    func setPolling(_ enabled: Bool) {
        if enabled {
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + K.inputPollSeconds, repeating: K.inputPollSeconds)
            timer.setEventHandler { [weak self] in
                // One poll period of margin: timer leeway plus main-queue
                // contention can push a poll late enough to miss an isolated
                // keystroke, leaving the alert lit with the user right there.
                guard Self.inputIdleSeconds() < 2 * K.inputPollSeconds,
                      let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                else { return }
                self?.onActivity?(bundle)
            }
            timer.resume()
            self.timer = timer
        } else {
            timer?.cancel()
            timer = nil
        }
    }

    static func frontmostBundleId() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// Whether a recorded host bundle id names an app the user could bring to
    /// the front — the live half of the ack's fail-open (see
    /// SessionStore.acknowledgeAlerts). `.regular` is the only activation
    /// policy with windows to focus, so an accessory or command-line bundle
    /// can never be matched by focus; nor can an app that has already quit,
    /// taking its terminal windows with it.
    static func hostIsFocusable(_ bundleId: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .contains { $0.activationPolicy == .regular }
    }

    /// The two live inputs behind Presence.userIsPresent; the rule itself is
    /// pure and lives in Core.
    static func userIsPresent() -> Bool {
        Presence.userIsPresent(
            idleSeconds: inputIdleSeconds(),
            screenLocked: Presence.screenIsLocked(CGSessionCopyCurrentDictionary() as? [String: Any]))
    }

    /// HIDIdleTime from IOHIDSystem: nanoseconds since ANY input — keys,
    /// clicks, scroll, trackpad. No TCC permission involved.
    static func inputIdleSeconds() -> Double {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault,
                                                IOServiceMatching("IOHIDSystem"))
        guard entry != 0 else { return .infinity }
        defer { IOObjectRelease(entry) }
        guard let property = IORegistryEntryCreateCFProperty(
            entry, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        else { return .infinity }
        var nanoseconds: Int64 = 0
        if CFGetTypeID(property) == CFNumberGetTypeID() {
            CFNumberGetValue((property as! CFNumber), .sInt64Type, &nanoseconds)
        }
        return Double(nanoseconds) / 1_000_000_000
    }
}

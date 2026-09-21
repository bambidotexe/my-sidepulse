import AppKit
import ServiceManagement
import UserNotifications
import MySidepulseCore
import MySidepulsePlatform

// MARK: - What a grant is

/// Which row this is, whatever its title and its place in the list. A row's identity must not
/// depend on either, because a grant that moves is found by it to redraw its own row.
enum OnboardingGrant: String, CaseIterable, Sendable {
    case claudeHooks, startup, terminalHook, notifications, phoneAlerts
}

/// One thing the onboarding asks for: a macOS grant, or one setup action of the app's own.
struct GrantItem {
    let id: OnboardingGrant
    /// **Exactly what System Settings calls this grant**, quoted from the system's own strings,
    /// or, for something MySidepulse does itself, exactly what the Settings window already calls
    /// it. The user has to find it in one of those two lists, so a third name is a dead end
    /// however well it reads.
    let title: String
    /// One line: what the app can do with it. Not how it works.
    let why: String
    /// Whether MySidepulse cannot do its job without it. Drawn with a warning mark, and the
    /// page's button stays "Skip" until every required row is done.
    let required: Bool
    /// Read live, every time. Never a cached copy: the user can grant and revoke behind the
    /// window.
    ///
    /// **A reader, never an ask.** Use the check API (`getNotificationSettings` through the
    /// cache below, `LoginService.isEnabled`, `HookInstaller`), never the one that requests: a
    /// request API returns the current state too, which makes it tempting here, and it also
    /// prompts. This closure runs on every poll tick, so that would be a permission prompt every
    /// two seconds. It must not publish either: it goes to `HookInstaller` directly and never
    /// through `SettingsModel`, whose `@Published` fields drive the Settings window.
    let granted: () -> Bool
    let buttonTitle: String
    /// Runs the flow; calls `done` on the main thread when the state may have changed. A flow
    /// that cannot finish in the app still calls `done`, at once.
    let action: (_ window: NSWindow?, _ done: @escaping () -> Void) -> Void

    /// Whether the flow puts up its own dialog and blocks until it is answered. macOS does not
    /// reactivate an accessory app when such a dialog closes, so a flow that owned one takes
    /// activation back when it ends.
    ///
    /// **A flow that hands over to System Settings or to a system permission prompt leaves this
    /// false.** Those report back immediately, while the thing they opened is still coming up, so
    /// taking activation then drops the window on top of the pane it has just opened.
    var returnsFocus: Bool = false

    /// The app this flow can send the user to, if any. **Every macOS grant sets this to System
    /// Settings**, not only the ones whose button opens a pane: a system permission dialog
    /// carries its own button to System Settings, so any such row can be the reason the user ends
    /// up there. macOS gives an ordinary app the front back when the app it handed over to quits,
    /// and leaves an accessory app out of that, so the row waits for that app to quit and does it
    /// itself. Nil for a flow that stays inside MySidepulse.
    var mayOpen: String? = nil

    /// What the row shows once `granted()` is true.
    var doneTitle: String
    /// A row the app can undo itself: the button shown once `granted()` is true.
    var removeTitle: String? = nil
    var remove: ((_ window: NSWindow?, _ done: @escaping () -> Void) -> Void)? = nil
}

extension GrantItem {
    /// Activation back to `window` once a flow that owned a modal dialog has ended, and only then.
    @MainActor func reclaimFocusIfNeeded(_ window: NSWindow?) {
        guard returnsFocus, let window, window.isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Giving the front back

/// Gives the front back after the user has been sent to another app, the way macOS does for an
/// ordinary app by itself. One of these waits for a named app to quit and then brings its window
/// forward, once.
///
/// macOS hands the front to whatever was in front before the app that quit, and skips
/// `LSUIElement` apps doing so. There is no flag for that, and the alternative is becoming
/// `.regular` for as long as the window is up, which re-activates the app: exactly what must not
/// happen while System Settings is in front.
///
/// The wait is bounded: a user who dismisses the prompt and never goes to System Settings would
/// otherwise leave it armed, and an unrelated visit there much later would pull the window forward
/// out of nowhere.
@MainActor
final class FocusReturnWatch {
    private var observer: NSObjectProtocol?
    private weak var target: NSWindow?
    /// How long a wait stays honoured. Long enough to grant a permission, short enough not to
    /// linger.
    private static let honoured: TimeInterval = 300

    deinit { if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }

    /// Waits for `bundleID` to quit, then brings `window` to the front. Replaces any earlier wait,
    /// and does nothing if the window has gone away or been closed by then.
    func whenQuit(_ bundleID: String, bringBack window: NSWindow?) {
        stop()
        guard let window else { return }
        target = window
        let deadline = Date().addingTimeInterval(Self.honoured)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                          as? NSRunningApplication,
                      app.bundleIdentifier == bundleID
                else { return }
                let target = self.target
                self.stop()
                guard Date() < deadline, let target, target.isVisible else { return }
                NSApp.activate(ignoringOtherApps: true)
                target.makeKeyAndOrderFront(nil)
            }
        }
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        target = nil
    }
}

// MARK: - The rows

/// The five rows of the wizard's one list page, in the order they matter.
///
/// **Reads go straight to the installer and to `LoginService`; writes go through `SettingsModel`**,
/// so the wizard and the Settings window set the same hook up by one implementation, with one log
/// line and one error path.
///
/// A row's action asks macOS and nothing else: a system dialog carries its own way to System
/// Settings, so the app never opens a pane beside it, nor instead of it once a grant has been
/// refused.
@MainActor
enum OnboardingCatalog {
    private static let systemSettings = "com.apple.systempreferences"

    /// Notification authorization is read asynchronously, so the rows read this cache and callers
    /// refresh it before asking them.
    private(set) static var notificationsGranted = false

    /// `UNUserNotificationCenter.current()` traps in a process with no bundle (a binary run out of
    /// `.build`), so nothing here touches it unless the app runs from one. `UpdateNotifier` has
    /// the same guard.
    private static var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil
    }

    static func items(model: SettingsModel) -> [GrantItem] {
        let t = Loc.onboarding
        return [
            GrantItem(id: .claudeHooks,
                      title: t.claudeTitle,
                      why: t.claudeWhy(events: HookConfig.events.count),
                      required: true,
                      granted: { HookInstaller.claudeHooksInstalled() == HookConfig.events.count },
                      buttonTitle: t.setUpButton,
                      action: { _, done in model.setUpClaudeHooks(); done() },
                      doneTitle: t.doneSetUp,
                      removeTitle: t.removeButton,
                      remove: { _, done in model.removeClaudeHooks(); done() }),
            GrantItem(id: .startup,
                      title: t.startupTitle,
                      why: t.startupWhy,
                      required: false,
                      granted: { LoginService.isEnabled },
                      buttonTitle: t.turnOnButton,
                      // The app writes its own launch agent plist and bootstraps it, so this flow
                      // stays inside MySidepulse: no pane, no prompt, nothing to come back from.
                      action: { _, done in model.setAutoRestart(true); done() },
                      doneTitle: Loc.settings.words.enabled),
            GrantItem(id: .terminalHook,
                      title: t.terminalTitle,
                      why: t.terminalWhy(seconds: Int(K.shellShowAfterDefaultSeconds)),
                      required: false,
                      granted: { HookInstaller.zshrcHasSnippet() },
                      buttonTitle: t.setUpButton,
                      action: { _, done in model.setUpZshHook(); done() },
                      doneTitle: t.doneSetUp,
                      removeTitle: t.removeButton,
                      remove: { _, done in model.removeZshHook(); done() }),
            GrantItem(id: .notifications,
                      title: t.notificationsTitle,
                      why: t.notificationsWhy,
                      required: false,
                      granted: { notificationsGranted },
                      buttonTitle: t.allowButton,
                      action: { _, done in requestNotifications(done) },
                      mayOpen: systemSettings,
                      doneTitle: t.doneGranted),
            GrantItem(id: .phoneAlerts,
                      title: t.phoneTitle,
                      why: t.phoneWhy,
                      required: false,
                      granted: { model.notifyStatus?.enabled == true },
                      buttonTitle: t.turnOnButton,
                      // Turning it on mints a topic, and a topic nobody has scanned notifies
                      // nothing: Settings opens on the page that shows the QR code.
                      action: { _, done in
                          model.setNotifications(enabled: true)
                          model.showSettings?(.notifications)
                          done()
                      },
                      doneTitle: Loc.settings.words.enabled),
        ]
    }

    /// Reads the authorization into the cache and calls back on the main queue. A process with no
    /// bundle has no centre to ask, and answers "not granted" rather than trapping.
    static func refreshNotifications(_ done: @escaping () -> Void) {
        guard let center else {
            notificationsGranted = false
            done()
            return
        }
        center.getNotificationSettings { settings in
            DispatchQueue.main.async {
                notificationsGranted = settings.authorizationStatus == .authorized
                done()
            }
        }
    }

    /// The one place in MySidepulse that asks for notification authorization, reached only from a
    /// button: this row's, and Allow Notifications on the System page. The result is the state at the
    /// moment of the call, never the user's answer, so nothing branches on it: the cache is re-read
    /// instead.
    static func requestNotifications(_ done: @escaping () -> Void) {
        guard let center else { done(); return }
        center.requestAuthorization(options: [.alert]) { _, _ in
            Task { @MainActor in refreshNotifications(done) }
        }
    }
}

// MARK: - The numbers

/// Every size the wizard uses, in points. Fitted by eye on the running window, in KoffeeLid first.
/// Reproduce them; do not improve on them.
enum OnboardingMetrics {
    static let windowWidth: CGFloat = 540
    /// Page heights, by page. The window resizes around its top-left corner, so the title bar
    /// stays put and the page grows downward.
    static let heroHeight: CGFloat = 440
    static let listHeight: CGFloat = 560
    static let finalHeight: CGFloat = 400

    static let heroIcon: CGFloat = 104
    static let heroTitle: CGFloat = 26
    static let heroBody: CGFloat = 14
    /// The widest a hero's text gets before it wraps, inside a 540 window.
    static let heroTextWidth: CGFloat = 440
    static let heroSpacing: CGFloat = 18
    static let heroTitleToBody: CGFloat = 10
    static let heroInsets = NSEdgeInsets(top: 32, left: 40, bottom: 36, right: 40)

    static let listTitle: CGFloat = 22
    static let listIntro: CGFloat = 13
    static let listIntroWidth: CGFloat = 460
    static let listSpacing: CGFloat = 14
    static let listIntroToList: CGFloat = 20
    static let listToFooter: CGFloat = 24
    static let listRowSpacing: CGFloat = 12
    static let listInsets = NSEdgeInsets(top: 28, left: 40, bottom: 28, right: 40)
    /// The list is the page's width less both insets.
    static let listSideInset: CGFloat = 80

    static let rowTitle: CGFloat = 14
    static let rowWhy: CGFloat = 12
    static let rowTrailing: CGFloat = 13
    /// The widest a row's title and explanation get, leaving room for the trailing control.
    static let rowTextWidth: CGFloat = 320

    static let pillSymbol: CGFloat = 11
    static let pillLabel: CGFloat = 11.5
    static let pillInsets = NSEdgeInsets(top: 5, left: 9, bottom: 5, right: 9)
    static let pillRadius: CGFloat = 13
    static let pillSpacing: CGFloat = 4
    static let pillTint: CGFloat = 0.10
    static let pillRowWidth: CGFloat = 460

    /// How often the list page re-reads its rows while the window is up. Slow enough to be free,
    /// fast enough that coming back from System Settings finds the page already right.
    static let pollInterval: TimeInterval = 2
}

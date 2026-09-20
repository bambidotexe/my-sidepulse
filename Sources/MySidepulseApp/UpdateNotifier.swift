import Foundation
import os
import UserNotifications
import MySidepulseCore

/// Identifiers, never shown.
private enum UpdateNotification {
    static let identifier = "update"
    static let category = "update"
    static let action = "update.open"
}

/// The one notification the app posts on this Mac: a newer release found by a check nobody asked for.
/// What Claude Code is doing goes to the strip and, through ntfy, to a phone; never here. Permission is
/// asked for the first time there is something to say, not at launch, and a user who says no still finds
/// the release in Settings.
///
/// `UNUserNotificationCenter.current()` traps in a process with no bundle (a binary run out of
/// `.build`), so nothing here touches it unless the app runs from one.
final class UpdateNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// The notification's Update button, or a click on the notification itself.
    var onUpdateRequested: (() -> Void)?

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil
    }

    /// At launch, before the first run-loop turn ends: a click on a notification left by an earlier run
    /// starts the app, and is delivered to the delegate found in place then.
    func start() {
        guard let center else { return }
        center.delegate = self
        // `.foreground`: the button brings the app forward, which the update window needs.
        let update = UNNotificationAction(identifier: UpdateNotification.action, title: Loc.settings.general.updateButton, options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: UpdateNotification.category, actions: [update], intentIdentifiers: []),
        ])
    }

    /// One at a time: a later check's notification replaces the one still in Notification Center.
    func postUpdateAvailable(version: String) {
        guard let center else { return }
        let title = Loc.settings.general.versionAvailable(version)
        let body = Loc.updateWindow.notificationBody
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else {
                Log.app.notice("update: notification not posted: not allowed; the release shows in Settings")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.categoryIdentifier = UpdateNotification.category
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UpdateNotification.identifier, content: content, trigger: nil))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let wanted = response.actionIdentifier == UpdateNotification.action
            || response.actionIdentifier == UNNotificationDefaultActionIdentifier
        if response.notification.request.identifier == UpdateNotification.identifier, wanted {
            DispatchQueue.main.async { self.onUpdateRequested?() }
        }
        completionHandler()
    }

    /// Asked only while the app is frontmost, which for this app means Settings is the window in front:
    /// the notification shows then too.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

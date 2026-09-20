import Foundation

/// Whether the user is at the machine, and therefore already looking at the
/// strip. Pure so both halves are testable; the app supplies the two inputs.
public enum Presence {
    public static func userIsPresent(idleSeconds: Double, screenLocked: Bool) -> Bool {
        // .infinity arrives when the idle time is unreadable, and reads as
        // absent — the gate fails OPEN and notifies, rather than silently
        // swallowing every notification.
        idleSeconds < K.notifyPresenceIdleSeconds && !screenLocked
    }

    /// From CGSessionCopyCurrentDictionary. The key is absent entirely while
    /// unlocked, and that dictionary mixes two naming conventions — the
    /// on-console key carries a `k` prefix while the lock key is conventionally
    /// written without one — so accept either rather than depend on which
    /// spelling a given macOS uses. Getting it wrong costs the lock signal but
    /// not the gate: idle time alone still applies.
    public static func screenIsLocked(_ sessionInfo: [String: Any]?) -> Bool {
        guard let sessionInfo else { return false }
        for key in ["CGSSessionScreenIsLocked", "kCGSSessionScreenIsLockedKey"] {
            if sessionInfo[key] as? Bool == true { return true }
        }
        return false
    }
}

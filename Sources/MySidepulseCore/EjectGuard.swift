import Foundation

/// macOS loginwindow ejects any disk that appears while the screen is locked.
/// The SD slot re-enumerating after a hibernate wake does exactly that, so
/// without a veto the card is gone by morning and the strip stays dark until
/// someone notices. The eject travels through DiskArbitration approval, so a
/// registered client can dissent it; the app then retries the mount until it
/// succeeds, which is after unlock.
///
/// This is NOT what Keepalive does. Keepalive touches a file to defeat the
/// reader's idle power-down and takes no part in mount approval.
public enum EjectGuard {
    /// Matched on the READER, not on the volume name, so the card is
    /// protected before any SidePulse volume has had a chance to mount —
    /// which is the case the guard exists for. The two strings are what the
    /// built-in reader actually reports.
    public static func isBuiltInCardReader(deviceProtocol: String?, deviceModel: String?) -> Bool {
        deviceProtocol?.contains("Secure Digital") == true
            || deviceModel?.contains("SDXC") == true
    }
}

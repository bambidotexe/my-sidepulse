import Foundation
import MySidepulseCore
import MySidepulsePlatform

struct AppConfig: Codable {
    var ledMode: String = "auto"
    var brightness: [String: Int] = [:]
    // Optional, and not by preference: load() wraps decoding in a blanket
    // `try?` and synthesised Decodable throws on a missing key, so a
    // non-optional field here would silently reset the user's whole config
    // the first time an older file is read.
    var notifyEnabled: Bool?
    /// Whether MySidepulse should start at login and be restarted when it dies.
    /// Three-valued on purpose: nil is "never asked" and registers, true is
    /// "keep it registered" and re-registers if the registration goes missing,
    /// false is the user having turned it off and must stay off.
    ///
    /// Optional for the same reason as the fields below it, and that matters
    /// more here than anywhere: a non-optional new key resets every existing
    /// config on first read, which would mint a fresh ntfy topic and silently
    /// orphan the phone subscribed to the old one.
    var autoRestartWanted: Bool?
    var notifyTopic: String?
    var notifyServer: String?
    /// Whether the onboarding wizard has been walked to its last button. Nil and false both mean
    /// it has not, so a window closed before the end brings it back at the next launch.
    ///
    /// Optional for the same reason as every key above it.
    var onboardingDone: Bool?
    /// The Colours page's overrides, keyed by `LedPalette.Slot` raw value. A
    /// slot at its default is absent, never written as its own hex.
    ///
    /// Optional for the same reason as every key above it.
    var colors: [String: String]?

    var notifyIsLive: Bool { notifyEnabled == true && notifyTopic?.isEmpty == false }
    var notifyServerOrDefault: String { notifyServer ?? K.notifyServerDefault }

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: Paths.config),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data)
        else { return AppConfig() }
        return config
    }

    func save() {
        try? FileManager.default.createDirectory(at: Paths.appSupport,
                                                 withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? (try? encoder.encode(self))?.write(to: Paths.config, options: .atomic)
        // The ntfy topic is bearer-equivalent: anyone holding it can read the
        // feed. Applied after every write because .atomic replaces the inode.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: Paths.config.path)
    }

    func brightness(forVolumeName name: String) -> Int {
        brightness[name.lowercased()] ?? 255
    }
}

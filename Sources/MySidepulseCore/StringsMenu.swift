import Foundation

/// The menu-bar menu. `MenuBarController` rebuilds it from scratch on every
/// open and reads these then, so the menu is never a language behind.
public struct MenuStrings {
    private let language: Language
    init(_ language: Language) { self.language = language }

    public var ledsAuto: String {
        switch language {
        case .en: "LEDs: Auto"
        case .fr: "LED : Auto"
        }
    }

    public var ledsOff: String {
        switch language {
        case .en: "LEDs: Off"
        case .fr: "LED : Éteintes"
        }
    }

    public func ledsForced(_ hex: String) -> String {
        switch language {
        case .en: "LEDs: \(hex) (forced)"
        case .fr: "LED : \(hex) (forcé)"
        }
    }

    public func ledsEffect(_ name: String) -> String {
        switch language {
        case .en: "LEDs: \(name) (effect)"
        case .fr: "LED : \(name) (effet)"
        }
    }

    public var openAtLogin: String {
        switch language {
        case .en: "Open at Login"
        case .fr: "Ouvrir à la connexion"
        }
    }

    public var settings: String {
        switch language {
        case .en: "Settings…"
        case .fr: "Réglages…"
        }
    }

    public var quit: String {
        switch language {
        case .en: "Quit MySidepulse"
        case .fr: "Quitter MySidepulse"
        }
    }

    public var noDeviceMounted: String {
        switch language {
        case .en: "No device mounted"
        case .fr: "Aucun appareil monté"
        }
    }

    public func deviceSummary(name: String, leds: Int, stalled: Bool) -> String {
        let head = "\(name) · \(language.leds(leds))"
        guard stalled else { return head }
        switch language {
        case .en: return head + " · stalled"
        case .fr: return head + " · bloqué"
        }
    }

    public var noSessions: String {
        switch language {
        case .en: "No Claude sessions"
        case .fr: "Aucune session Claude"
        }
    }

    public func sessionsLine(_ counts: String) -> String {
        switch language {
        case .en: "Sessions: \(counts)"
        case .fr: "Sessions : \(counts)"
        }
    }

    public func lastEventAgo(seconds: Int) -> String {
        switch language {
        case .en: "Last event: \(seconds)s ago"
        case .fr: "Dernier événement : il y a \(seconds) s"
        }
    }

    public var lastEventNone: String {
        switch language {
        case .en: "Last event: none"
        case .fr: "Dernier événement : aucun"
        }
    }
}

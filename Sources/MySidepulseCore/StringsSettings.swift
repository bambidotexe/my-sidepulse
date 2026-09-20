import Foundation

/// The one word a status mark carries, from the window's fixed vocabulary.
/// Shared by every page so that the same state never gets two words.
public struct StatusWords {
    private let language: Language
    init(_ language: Language) { self.language = language }

    public var available: String {
        switch language {
        case .en: "Available"
        case .fr: "Disponible"
        }
    }

    public var missing: String {
        switch language {
        case .en: "Missing"
        case .fr: "Absent"
        }
    }

    public var stalled: String {
        switch language {
        case .en: "Stalled"
        case .fr: "Bloqué"
        }
    }

    public var enabled: String {
        switch language {
        case .en: "Enabled"
        case .fr: "Activé"
        }
    }

    public var disabled: String {
        switch language {
        case .en: "Disabled"
        case .fr: "Désactivé"
        }
    }

    public var valid: String {
        switch language {
        case .en: "Valid"
        case .fr: "Valide"
        }
    }

    /// "Non valide" would read more like macOS, but a mark is one word: the
    /// symbol beside it already carries the negation.
    public var invalid: String {
        switch language {
        case .en: "Invalid"
        case .fr: "Invalide"
        }
    }

    public var failed: String {
        switch language {
        case .en: "Failed"
        case .fr: "Échec"
        }
    }
}

/// Everything the Settings window shows: the toolbar's six titles, the shared
/// status vocabulary, and one table per page.
public struct SettingsStrings {
    private let language: Language
    init(_ language: Language) { self.language = language }

    public var pageGeneral: String {
        switch language {
        case .en: "General"
        case .fr: "Général"
        }
    }

    public var pageStrip: String {
        switch language {
        case .en: "Strip"
        case .fr: "Ruban"
        }
    }

    public var pageNotifications: String {
        switch language {
        case .en: "Notifications"
        case .fr: "Notifications"
        }
    }

    public var pagePlayground: String {
        switch language {
        case .en: "Playground"
        case .fr: "Bac à sable"
        }
    }

    public var pageHealth: String {
        switch language {
        case .en: "Health"
        case .fr: "Diagnostic"
        }
    }

    public var pageSystem: String {
        switch language {
        case .en: "System"
        case .fr: "Système"
        }
    }

    public var words: StatusWords { StatusWords(language) }
    public var general: GeneralPageStrings { GeneralPageStrings(language) }
    public var strip: StripPageStrings { StripPageStrings(language) }
    public var notifications: NotificationsPageStrings { NotificationsPageStrings(language) }
    public var playground: PlaygroundPageStrings { PlaygroundPageStrings(language) }
    public var health: HealthPageStrings { HealthPageStrings(language) }
    public var system: SystemPageStrings { SystemPageStrings(language) }
}

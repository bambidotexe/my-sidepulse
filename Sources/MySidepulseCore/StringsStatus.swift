import Foundation

/// The `Showing` sentences: what the strip shows and why, in the user's words.
/// `StatusCopy` owns which sentence goes with which state and what tone it
/// carries; this owns the words. Every sentence is short, names Claude or the
/// command rather than a colour, carries no long dash and ends without a full
/// stop. `StatusCopyTests` pins both languages.
public struct StatusStrings {
    private let language: Language
    init(_ language: Language) { self.language = language }

    public var off: String {
        switch language {
        case .en: "Nothing to show, the strip is dark"
        case .fr: "Rien à afficher, le ruban est éteint"
        }
    }

    public var working: String {
        switch language {
        case .en: "Claude is working"
        case .fr: "Claude travaille"
        }
    }

    public var waiting: String {
        switch language {
        case .en: "Claude needs you: a question, a permission or a plan"
        case .fr: "Claude a besoin de vous : une question, une permission ou un plan"
        }
    }

    public var done: String {
        switch language {
        case .en: "Claude has finished. Clears when you look at the terminal"
        case .fr: "Claude a terminé. S'efface quand vous regardez le terminal"
        }
    }

    public var jobRunning: String {
        switch language {
        case .en: "A terminal command is running"
        case .fr: "Une commande de terminal est en cours"
        }
    }

    public var jobFailed: String {
        switch language {
        case .en: "A terminal command failed"
        case .fr: "Une commande de terminal a échoué"
        }
    }

    public var jobSucceeded: String {
        switch language {
        case .en: "A terminal command finished"
        case .fr: "Une commande de terminal est terminée"
        }
    }

    public var splitWaiting: String {
        switch language {
        case .en: "Claude needs you, and other work is still running"
        case .fr: "Claude a besoin de vous, et d'autres tâches sont en cours"
        }
    }

    public var splitJobFailed: String {
        switch language {
        case .en: "A command failed, and other work is still running"
        case .fr: "Une commande a échoué, et d'autres tâches sont en cours"
        }
    }

    public var splitDone: String {
        switch language {
        case .en: "Claude has finished, and other work is still running"
        case .fr: "Claude a terminé, et d'autres tâches sont en cours"
        }
    }

    public var splitJobSucceeded: String {
        switch language {
        case .en: "A command finished, and other work is still running"
        case .fr: "Une commande est terminée, et d'autres tâches sont en cours"
        }
    }

    public var batteryCritical: String {
        switch language {
        case .en: "Battery critically low"
        case .fr: "Batterie très faible"
        }
    }

    public var batteryGlance: String {
        switch language {
        case .en: "Battery level, for a moment"
        case .fr: "Niveau de batterie, un instant"
        }
    }

    public func manualColor(_ hex: String) -> String {
        switch language {
        case .en: "Forced to \(hex) until set back to Auto"
        case .fr: "Forcé sur \(hex) jusqu'au retour à Auto"
        }
    }

    public func effect(_ name: String) -> String {
        switch language {
        case .en: "Playing \(name) until set back to Auto"
        case .fr: "Lecture de \(name) jusqu'au retour à Auto"
        }
    }
}

import Foundation

/// The `Showing` sentences: what the strip shows and why, in the user's words.
/// `StatusCopy` owns which sentence goes with which state and what tone it
/// carries; this owns the words. Every sentence is short, names the agent or
/// the command rather than a colour, carries no long dash and ends without a
/// full stop. `StatusCopyTests` pins both languages.
///
/// A sentence about an agent takes the agents it is about: Claude, Codex, or
/// both, in which case the verb agrees with the pair.
public struct StatusStrings {
    private let language: Language
    init(_ language: Language) { self.language = language }

    /// "Claude", "Codex" or "Claude and Codex": product names, the same in
    /// both languages but for the conjunction.
    private func names(_ agents: Agents) -> String {
        let kinds = agents.kinds.isEmpty ? [AgentKind.claude] : agents.kinds
        switch language {
        case .en: return kinds.map(\.shortName).joined(separator: " and ")
        case .fr: return kinds.map(\.shortName).joined(separator: " et ")
        }
    }

    private func isPair(_ agents: Agents) -> Bool { agents.kinds.count > 1 }

    public var off: String {
        switch language {
        case .en: "Nothing to show, the strip is dark"
        case .fr: "Rien à afficher, le ruban est éteint"
        }
    }

    public func working(_ agents: Agents) -> String {
        switch language {
        case .en: "\(names(agents)) \(isPair(agents) ? "are" : "is") working"
        case .fr: "\(names(agents)) \(isPair(agents) ? "travaillent" : "travaille")"
        }
    }

    public func waiting(_ agents: Agents) -> String {
        switch language {
        case .en: "\(names(agents)) \(isPair(agents) ? "need" : "needs") you: a question, a permission or a plan"
        case .fr: "\(names(agents)) \(isPair(agents) ? "ont" : "a") besoin de vous : une question, une permission ou un plan"
        }
    }

    public func done(_ agents: Agents) -> String {
        switch language {
        case .en: "\(names(agents)) \(isPair(agents) ? "have" : "has") finished. Clears when you look at the terminal"
        case .fr: "\(names(agents)) \(isPair(agents) ? "ont" : "a") terminé. S'efface quand vous regardez le terminal"
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

    public func splitWaiting(_ agents: Agents) -> String {
        switch language {
        case .en: "\(names(agents)) \(isPair(agents) ? "need" : "needs") you, and other work is still running"
        case .fr: "\(names(agents)) \(isPair(agents) ? "ont" : "a") besoin de vous, et d'autres tâches sont en cours"
        }
    }

    public var splitJobFailed: String {
        switch language {
        case .en: "A command failed, and other work is still running"
        case .fr: "Une commande a échoué, et d'autres tâches sont en cours"
        }
    }

    public func splitDone(_ agents: Agents) -> String {
        switch language {
        case .en: "\(names(agents)) \(isPair(agents) ? "have" : "has") finished, and other work is still running"
        case .fr: "\(names(agents)) \(isPair(agents) ? "ont" : "a") terminé, et d'autres tâches sont en cours"
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

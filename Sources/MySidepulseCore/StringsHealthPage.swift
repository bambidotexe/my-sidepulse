import Foundation

/// The Health page's own words: the row label each doctor check is known by,
/// and the "Right now" group. The detail sentences under those rows come from
/// `DoctorStrings`, because the CLI prints them too.
public struct HealthPageStrings {
    private let language: Language
    init(_ language: Language) { self.language = language }

    public var checksTitle: String {
        switch language {
        case .en: "Checks"
        case .fr: "Vérifications"
        }
    }

    public var checksHint: String {
        switch language {
        case .en: "The same checks as mysidepulse doctor in a terminal. Hover a row "
            + "for what it found."
        case .fr: "Les mêmes vérifications que mysidepulse doctor dans un terminal. "
            + "Survolez une ligne pour voir ce qu'elle a trouvé."
        }
    }

    public var checkAgainButton: String {
        switch language {
        case .en: "Check Again"
        case .fr: "Vérifier à nouveau"
        }
    }

    public var rightNowTitle: String {
        switch language {
        case .en: "Right now"
        case .fr: "En ce moment"
        }
    }

    public var lastHookEventLabel: String {
        switch language {
        case .en: "Last hook event"
        case .fr: "Dernier événement de hook"
        }
    }

    public func lastEventAgo(seconds: Int) -> String {
        switch language {
        case .en: "\(seconds) s ago"
        case .fr: "il y a \(seconds) s"
        }
    }

    public var noneYet: String {
        switch language {
        case .en: "None yet"
        case .fr: "Aucun pour l'instant"
        }
    }

    public var batteryLabel: String {
        switch language {
        case .en: "Battery"
        case .fr: "Batterie"
        }
    }

    public func batteryMark(percent: Int, plugged: Bool) -> String {
        switch language {
        case .en: "\(percent) %, \(plugged ? "plugged in" : "on battery")"
        case .fr: "\(percent) %, \(plugged ? "sur secteur" : "sur batterie")"
        }
    }

    public var claudeSessionsLabel: String {
        switch language {
        case .en: "Claude sessions"
        case .fr: "Sessions Claude"
        }
    }

    public var none: String {
        switch language {
        case .en: "None"
        case .fr: "Aucune"
        }
    }

    public func sessionLabel(idPrefix: String) -> String {
        switch language {
        case .en: "Session \(idPrefix)"
        case .fr: "Session \(idPrefix)"
        }
    }

    /// `state` and `reason` are the engine's own words, reported as they come
    /// over the control socket.
    public func sessionMark(state: String, reason: String?, ageSeconds: Int) -> String {
        let head = state + (reason.map { ", \($0)" } ?? "")
        switch language {
        case .en: return "\(head), \(ageSeconds) s ago"
        case .fr: return "\(head), il y a \(ageSeconds) s"
        }
    }

    public var unknownDirectory: String {
        switch language {
        case .en: "unknown directory"
        case .fr: "répertoire inconnu"
        }
    }

    public func jobMark(state: String, acknowledged: Bool, ageSeconds: Int) -> String {
        switch language {
        case .en: "\(state)\(acknowledged ? ", seen" : ""), \(ageSeconds) s ago"
        case .fr: "\(state)\(acknowledged ? ", vu" : ""), il y a \(ageSeconds) s"
        }
    }

    public var reportTitle: String {
        switch language {
        case .en: "Report"
        case .fr: "Rapport"
        }
    }

    public var reportHint: String {
        switch language {
        case .en: "Copies the checks and the state above as text. The notification "
            + "topic stays masked, so it is safe to paste anywhere."
        case .fr: "Copie les vérifications et l'état ci-dessus sous forme de texte. "
            + "Le sujet de notification reste masqué, donc sûr à coller n'importe où."
        }
    }

    public var copyReportButton: String {
        switch language {
        case .en: "Copy Report"
        case .fr: "Copier le rapport"
        }
    }

    public var appLabel: String {
        switch language {
        case .en: "MySidepulse app"
        case .fr: "App MySidepulse"
        }
    }

    public var autoStartLabel: String {
        switch language {
        case .en: "Open at login and crash restart"
        case .fr: "Ouverture à la connexion et redémarrage après plantage"
        }
    }

    public var claudeCodeHooksLabel: String {
        switch language {
        case .en: "Claude Code hooks"
        case .fr: "Hooks Claude Code"
        }
    }

    public var hookCommandLabel: String {
        switch language {
        case .en: "Hook command"
        case .fr: "Commande du hook"
        }
    }

    public var journalLabel: String {
        switch language {
        case .en: "Journal"
        case .fr: "Journal"
        }
    }

    public var sidePulseStripLabel: String {
        switch language {
        case .en: "SidePulse strip"
        case .fr: "Ruban SidePulse"
        }
    }

    public var phoneNotificationsLabel: String {
        switch language {
        case .en: "Phone notifications"
        case .fr: "Notifications téléphone"
        }
    }
}

import Foundation

/// The Colours page: the preview, one row per colour, the resets.
///
/// Every number in these sentences is a parameter, never a literal, so the
/// sentence cannot drift from the constant that owns it.
public struct ColorsPageStrings {
    private let language: Language
    init(_ language: Language) { self.language = language }

    public var previewTitle: String {
        switch language {
        case .en: "Preview"
        case .fr: "Aperçu"
        }
    }

    public func previewHint(seconds: Int) -> String {
        switch language {
        case .en: "Click a colour to play its state on the strip for up to \(seconds) seconds."
        case .fr: "Cliquez sur une couleur pour jouer son état sur le ruban pendant "
            + "\(seconds) secondes maximum."
        }
    }

    public var noStripNote: String {
        switch language {
        case .en: "No strip is mounted, so a colour plays on screen only."
        case .fr: "Aucun ruban n'est monté, la couleur ne s'affiche donc qu'à l'écran."
        }
    }

    public var showingLabel: String {
        switch language {
        case .en: "Showing"
        case .fr: "Affiche"
        }
    }

    public var playingLabel: String {
        switch language {
        case .en: "Playing"
        case .fr: "Lecture"
        }
    }

    public func playingRemaining(title: String, seconds: Int) -> String {
        switch language {
        case .en: "\(title), \(seconds) s left"
        case .fr: "\(title), encore \(seconds) s"
        }
    }

    public var playingEnded: String {
        switch language {
        case .en: "Ended. The strip is back to its real state"
        case .fr: "Terminé. Le ruban est revenu à son état réel"
        }
    }

    public var stopButton: String {
        switch language {
        case .en: "Stop"
        case .fr: "Arrêter"
        }
    }

    public var coloursTitle: String {
        switch language {
        case .en: "Colours"
        case .fr: "Couleurs"
        }
    }

    public var coloursHint: String {
        switch language {
        case .en: "Needs you and Done are the same colours for Claude and for Codex. A "
            + "command that fails takes the Needs you colour, and one that succeeds "
            + "takes the Done colour."
        case .fr: "A besoin de vous et Terminé sont les mêmes couleurs pour Claude et pour "
            + "Codex. Une commande qui échoue prend la couleur A besoin de vous, et une "
            + "commande qui réussit prend la couleur Terminé."
        }
    }

    public var coloursNote: String {
        switch language {
        case .en: "Brightness is set for each strip on the Strip page."
        case .fr: "La luminosité se règle pour chaque ruban dans la page Ruban."
        }
    }

    public func label(_ slot: LedPalette.Slot) -> String {
        switch slot {
        case .working:
            switch language {
            case .en: "Claude working"
            case .fr: "Claude au travail"
            }
        case .codexWorking:
            switch language {
            case .en: "Codex working"
            case .fr: "Codex au travail"
            }
        case .needsYou:
            switch language {
            case .en: "Needs you"
            case .fr: "A besoin de vous"
            }
        case .done:
            switch language {
            case .en: "Done"
            case .fr: "Terminé"
            }
        case .jobRunning:
            switch language {
            case .en: "Command running"
            case .fr: "Commande en cours"
            }
        case .batteryCritical:
            switch language {
            case .en: "Battery critical"
            case .fr: "Batterie critique"
            }
        case .batteryLow: batteryBarUpTo(percent: K.batteryCriticalPercent)
        case .batteryMid: batteryBarUpTo(percent: K.batteryMidPercent)
        case .batteryHigh: batteryBarAbove(percent: K.batteryMidPercent)
        }
    }

    private func batteryBarUpTo(percent: Int) -> String {
        switch language {
        case .en: "Battery bar ≤ \(percent) %"
        case .fr: "Barre de batterie ≤ \(percent) %"
        }
    }

    private func batteryBarAbove(percent: Int) -> String {
        switch language {
        case .en: "Battery bar > \(percent) %"
        case .fr: "Barre de batterie > \(percent) %"
        }
    }

    public var resetButton: String {
        switch language {
        case .en: "Reset"
        case .fr: "Réinitialiser"
        }
    }

    public var resetAllButton: String {
        switch language {
        case .en: "Reset All Colours"
        case .fr: "Réinitialiser toutes les couleurs"
        }
    }
}

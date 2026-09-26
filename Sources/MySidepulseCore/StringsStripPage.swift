import Foundation

/// The Strip page: Right now, What the strip shows, Strip, Remembered
/// brightness.
public struct StripPageStrings {
    private let language: Language
    init(_ language: Language) { self.language = language }

    public var rightNowTitle: String {
        switch language {
        case .en: "Right now"
        case .fr: "En ce moment"
        }
    }

    public var showingLabel: String {
        switch language {
        case .en: "Showing"
        case .fr: "Affiche"
        }
    }

    public var whatShowsTitle: String {
        switch language {
        case .en: "What the strip shows"
        case .fr: "Ce qu'affiche le ruban"
        }
    }

    public var whatShowsHint: String {
        switch language {
        case .en: "Auto follows Claude Code, Codex, Copilot and OpenCode, each in its own "
            + "colour while it works, amber when one needs you, green when one has "
            + "finished. A colour or an effect holds until you come back to Auto, "
            + "through restarts too."
        case .fr: "Auto suit Claude Code, Codex, Copilot et OpenCode, chacun dans sa "
            + "propre couleur pendant qu'il travaille, ambre quand l'un a besoin de "
            + "vous, vert quand l'un a terminé. Une couleur ou un effet reste actif "
            + "jusqu'au retour à Auto, même après un redémarrage."
        }
    }

    public var whatShowsNote: String {
        switch language {
        case .en: "The same from a terminal: mysidepulse led auto, off, a colour "
            + "or an effect name."
        case .fr: "Pareil depuis un terminal : mysidepulse led auto, off, une "
            + "couleur ou un nom d'effet."
        }
    }

    public var stripSegmentLabel: String {
        switch language {
        case .en: "Strip"
        case .fr: "Ruban"
        }
    }

    public var modeAuto: String {
        switch language {
        case .en: "Auto"
        case .fr: "Auto"
        }
    }

    public var modeOff: String {
        switch language {
        case .en: "Off"
        case .fr: "Désactivé"
        }
    }

    public var modeColour: String {
        switch language {
        case .en: "Colour"
        case .fr: "Couleur"
        }
    }

    public var modeEffect: String {
        switch language {
        case .en: "Effect"
        case .fr: "Effet"
        }
    }

    public var colourLabel: String {
        switch language {
        case .en: "Colour"
        case .fr: "Couleur"
        }
    }

    public var stripTitle: String {
        switch language {
        case .en: "Strip"
        case .fr: "Ruban"
        }
    }

    public var sidePulseStripLabel: String {
        switch language {
        case .en: "SidePulse strip"
        case .fr: "Ruban SidePulse"
        }
    }

    public func deviceRow(name: String, leds: Int) -> String {
        "\(name), \(language.leds(leds))"
    }

    public func mountedAtTooltip(_ path: String) -> String {
        switch language {
        case .en: "Mounted at \(path)"
        case .fr: "Monté sur \(path)"
        }
    }

    public var brightnessLabel: String {
        switch language {
        case .en: "Brightness"
        case .fr: "Luminosité"
        }
    }

    /// A brightness, in perceived percent.
    public func percentValue(_ percent: Int) -> String {
        switch language {
        case .en: "\(percent) %"
        case .fr: "\(percent) %"
        }
    }

    public var rememberedBrightnessTitle: String {
        switch language {
        case .en: "Remembered brightness"
        case .fr: "Luminosité mémorisée"
        }
    }

    public var rememberedBrightnessHint: String {
        switch language {
        case .en: "Kept for strips that are not plugged in right now."
        case .fr: "Conservée pour les rubans non branchés pour l'instant."
        }
    }

    public var forgetButton: String {
        switch language {
        case .en: "Forget"
        case .fr: "Oublier"
        }
    }

    public var stripHintEmpty: String {
        switch language {
        case .en: "Plug a SidePulse strip into the SD card slot. It is picked up "
            + "and lit by itself."
        case .fr: "Branchez un ruban SidePulse dans le lecteur de carte SD. Il est "
            + "détecté et s'allume automatiquement."
        }
    }

    public var stripHintPresent: String {
        switch language {
        case .en: "Brightness is applied when you let go of the slider and "
            + "remembered for that strip."
        case .fr: "La luminosité est appliquée quand vous relâchez le curseur, et "
            + "mémorisée pour ce ruban."
        }
    }

    public func stalledWarning(name: String) -> String {
        switch language {
        case .en: "A write to \(name) is taking too long. It clears by itself when "
            + "the write lands, or when you unplug the strip and plug it in again."
        case .fr: "Une écriture vers \(name) prend trop de temps. Cela se résout "
            + "tout seul une fois l'écriture terminée, ou en débranchant puis "
            + "rebranchant le ruban."
        }
    }
}

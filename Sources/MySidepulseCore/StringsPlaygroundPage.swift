import Foundation

/// The Playground page: the strip replica, the nine state cards, the six
/// effect tiles.
///
/// Every number in these sentences is a parameter, never a literal, so the
/// sentence cannot drift from the constant that owns it.
public struct PlaygroundPageStrings {
    private let language: Language
    init(_ language: Language) { self.language = language }

    public var onTheStripTitle: String {
        switch language {
        case .en: "On the strip"
        case .fr: "Sur le ruban"
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

    public var batteryLevelLabel: String {
        switch language {
        case .en: "Battery level"
        case .fr: "Niveau de batterie"
        }
    }

    public var colourLabel: String {
        switch language {
        case .en: "Colour"
        case .fr: "Couleur"
        }
    }

    public var keepItButton: String {
        switch language {
        case .en: "Keep It"
        case .fr: "Conserver"
        }
    }

    public var stopButton: String {
        switch language {
        case .en: "Stop"
        case .fr: "Arrêter"
        }
    }

    public var statesTitle: String {
        switch language {
        case .en: "States"
        case .fr: "États"
        }
    }

    public func statesHintDefault(seconds: Int) -> String {
        switch language {
        case .en: "Click a state to play it on the strip for up to \(seconds) seconds."
        case .fr: "Cliquez sur un état pour le jouer sur le ruban pendant "
            + "\(seconds) secondes maximum."
        }
    }

    public var effectsTitle: String {
        switch language {
        case .en: "Effects"
        case .fr: "Effets"
        }
    }

    public func effectsHintDefault(seconds: Int) -> String {
        switch language {
        case .en: "Six effects for fun. Click one to play it on the strip for up "
            + "to \(seconds) seconds."
        case .fr: "Six effets pour le plaisir. Cliquez sur l'un d'eux pour le "
            + "jouer sur le ruban pendant \(seconds) secondes maximum."
        }
    }

    public var effectsNote: String {
        switch language {
        case .en: "Every effect is also a terminal command: mysidepulse led "
            + "rainbow. Keep It makes the effect the strip's mode until you come "
            + "back to Auto."
        case .fr: "Chaque effet est aussi une commande de terminal : mysidepulse "
            + "led rainbow. Conserver fait de l'effet le mode du ruban jusqu'au "
            + "retour à Auto."
        }
    }

    public var stripNoteNoDevice: String {
        switch language {
        case .en: "No strip is mounted, so a state plays on screen only."
        case .fr: "Aucun ruban n'est monté, l'état ne s'affiche donc qu'à l'écran."
        }
    }

    public var titleWorking: String {
        switch language {
        case .en: "Claude working"
        case .fr: "Claude au travail"
        }
    }

    public var subtitleWorking: String {
        switch language {
        case .en: "Rolls while a turn runs."
        case .fr: "Défile pendant qu'un tour s'exécute."
        }
    }

    public var titleWaiting: String {
        switch language {
        case .en: "Needs you"
        case .fr: "A besoin de vous"
        }
    }

    public var subtitleWaiting: String {
        switch language {
        case .en: "Blinks twice for a question, a permission or a plan. A failed "
            + "command looks the same."
        case .fr: "Clignote deux fois pour une question, une permission ou un "
            + "plan. Une commande échouée a le même aspect."
        }
    }

    public var titleDone: String {
        switch language {
        case .en: "Finished"
        case .fr: "Terminé"
        }
    }

    public var subtitleDone: String {
        switch language {
        case .en: "Breathes until you look at the terminal. A finished command "
            + "looks the same."
        case .fr: "Respire jusqu'à ce que vous regardiez le terminal. Une commande "
            + "terminée a le même aspect."
        }
    }

    public var titleWaitingWorking: String {
        switch language {
        case .en: "Needs you and working"
        case .fr: "A besoin de vous, et travaille"
        }
    }

    public func subtitleWaitingWorking(leds: Int) -> String {
        switch language {
        case .en: "A double blink on the first \(leds) \(language.ledsNoun(leds)) "
            + "while the rest keep rolling."
        case .fr: "Un double clignotement sur les \(leds) premières "
            + "\(language.ledsNoun(leds)) pendant que le reste continue de défiler."
        }
    }

    public var titleDoneWorking: String {
        switch language {
        case .en: "Finished and working"
        case .fr: "Terminé, et travaille"
        }
    }

    public func subtitleDoneWorking(leds: Int) -> String {
        switch language {
        case .en: "Steady green on the first \(leds) \(language.ledsNoun(leds)) "
            + "while the rest keep rolling."
        case .fr: "Vert fixe sur les \(leds) premières \(language.ledsNoun(leds)) "
            + "pendant que le reste continue de défiler."
        }
    }

    public var titleJob: String {
        switch language {
        case .en: "A command running"
        case .fr: "Une commande en cours"
        }
    }

    public var subtitleJob: String {
        switch language {
        case .en: "A command started with mysidepulse run or through the terminal "
            + "hook."
        case .fr: "Une commande démarrée avec mysidepulse run ou via le hook du "
            + "terminal."
        }
    }

    public var titleCritical: String {
        switch language {
        case .en: "Battery critical"
        case .fr: "Batterie critique"
        }
    }

    public func subtitleCritical(percent: Int) -> String {
        switch language {
        case .en: "\(percent) % or less, unplugged."
        case .fr: "\(percent) % ou moins, débranché."
        }
    }

    public var titleGlance: String {
        switch language {
        case .en: "Battery glance"
        case .fr: "Aperçu de la batterie"
        }
    }

    public var subtitleGlance: String {
        switch language {
        case .en: "The fill bar shown after plugging or unplugging."
        case .fr: "La barre de niveau affichée après un branchement ou "
            + "débranchement."
        }
    }

    public var titleCustom: String {
        switch language {
        case .en: "A colour"
        case .fr: "Une couleur"
        }
    }

    public var subtitleCustom: String {
        switch language {
        case .en: "Solid, exactly as sent to the strip."
        case .fr: "Unie, exactement comme envoyée au ruban."
        }
    }

    public var effectSubtitleRainbow: String {
        switch language {
        case .en: "The whole wheel, chasing."
        case .fr: "Toute la roue, en poursuite."
        }
    }

    public var effectSubtitleAurora: String {
        switch language {
        case .en: "Northern lights, drifting slowly."
        case .fr: "Aurores boréales, dérive lente."
        }
    }

    public var effectSubtitleOcean: String {
        switch language {
        case .en: "Rolling deep blues."
        case .fr: "Bleus profonds qui roulent."
        }
    }

    public var effectSubtitleLava: String {
        switch language {
        case .en: "Molten reds and ambers."
        case .fr: "Rouges et ambres en fusion."
        }
    }

    public var effectSubtitleEmber: String {
        switch language {
        case .en: "A warm fireside breath."
        case .fr: "Un souffle chaud de foyer."
        }
    }

    public var effectSubtitleSparkle: String {
        switch language {
        case .en: "Scattered little glints."
        case .fr: "Petits éclats dispersés."
        }
    }
}

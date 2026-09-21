import Foundation

/// The onboarding wizard: the pitch, the one page of things to set up, and "All set".
///
/// A row's title is either exactly what System Settings calls the switch, or, for what
/// MySidepulse does itself, exactly what the Settings window already calls the same thing:
/// `Claude Code hooks` and `Terminal hook` read as the System page's own rows do, so the two
/// windows never give one thing two names.
public struct OnboardingStrings {
    private let language: Language
    init(_ language: Language) { self.language = language }

    // MARK: the pitch

    public var heroTitle: String {
        switch language {
        case .en: "Know when Claude is working, finished, or needs you."
        case .fr: "Sachez quand Claude travaille, a terminé, ou a besoin de vous."
        }
    }

    /// Accented on its own, so each language colours its own word rather than a fragment of
    /// the other's sentence.
    public var heroAccent: String {
        switch language {
        case .en: "Claude"
        case .fr: "Claude"
        }
    }

    public var heroBody: String {
        switch language {
        case .en: "MySidepulse lights the SidePulse card in your Mac's slot: a rolling red "
            + "wave while Claude Code works, a green breath once it has finished, an amber "
            + "blink when it needs you. Away from the Mac, the same alerts reach your phone."
        case .fr: "MySidepulse allume la carte SidePulse dans le lecteur de votre Mac : une "
            + "vague rouge pendant que Claude Code travaille, une respiration verte quand il "
            + "a terminé, un clignotement orange quand il a besoin de vous. Loin du Mac, les "
            + "mêmes alertes arrivent sur votre téléphone."
        }
    }

    public var pillWorking: String {
        switch language {
        case .en: "Working"
        case .fr: "Travaille"
        }
    }

    public var pillFinished: String {
        switch language {
        case .en: "Finished"
        case .fr: "A terminé"
        }
    }

    public var pillNeedsYou: String {
        switch language {
        case .en: "Needs you"
        case .fr: "Besoin de vous"
        }
    }

    // MARK: the page of rows

    public var setupHeader: String {
        switch language {
        case .en: "Setting up"
        case .fr: "Configuration"
        }
    }

    public var setupIntro: String {
        switch language {
        case .en: "MySidepulse needs a few things before it can show anything. The row marked "
            + "with a warning is the one it cannot work without. The others are optional, and "
            + "every one of them can be changed later in Settings."
        case .fr: "MySidepulse a besoin de quelques éléments avant de pouvoir montrer quoi que "
            + "ce soit. La ligne marquée d'un avertissement est la seule sans laquelle il ne "
            + "fonctionne pas. Les autres sont facultatives, et toutes se modifient ensuite "
            + "dans les réglages."
        }
    }

    /// The tooltip on the orange mark a required row carries.
    public var required: String {
        switch language {
        case .en: "Required"
        case .fr: "Obligatoire"
        }
    }

    // MARK: Claude Code

    public var claudeTitle: String {
        switch language {
        case .en: "Claude Code hooks"
        case .fr: "Hooks Claude Code"
        }
    }

    public func claudeWhy(events: Int) -> String {
        switch language {
        case .en: "The whole point: they tell MySidepulse when Claude Code works, finishes or "
            + "needs you. Adds \(events) entries to Claude Code's settings, after backing the "
            + "file up."
        case .fr: "Tout l'intérêt : ils indiquent à MySidepulse quand Claude Code travaille, "
            + "termine ou a besoin de vous. Ajoute \(events) entrées aux réglages de Claude "
            + "Code, après avoir sauvegardé le fichier."
        }
    }

    // MARK: Startup

    /// The General page's group is called Startup, and this row is that group.
    public var startupTitle: String {
        switch language {
        case .en: "Startup"
        case .fr: "Démarrage"
        }
    }

    public var startupWhy: String {
        switch language {
        case .en: "Opens MySidepulse at login and brings it back by itself after a crash. Off, "
            + "a crash leaves the strip frozen and your phone silent until you open it again."
        case .fr: "Ouvre MySidepulse à la connexion et le relance seul après un plantage. "
            + "Désactivé, un plantage laisse le ruban figé et votre téléphone silencieux "
            + "jusqu'à ce que vous le rouvriez."
        }
    }

    // MARK: Terminal

    public var terminalTitle: String {
        switch language {
        case .en: "Terminal hook"
        case .fr: "Hook de terminal"
        }
    }

    public func terminalWhy(seconds: Int) -> String {
        switch language {
        case .en: "Shows a command that runs longer than \(seconds) s on the strip, and whether "
            + "it succeeded. Adds one block to ~/.zshrc. Open a new terminal afterwards."
        case .fr: "Affiche sur le ruban une commande qui dure plus de \(seconds) s, et si elle "
            + "a réussi. Ajoute un bloc à ~/.zshrc. Ouvrez ensuite une nouvelle fenêtre de "
            + "terminal."
        }
    }

    // MARK: Notifications

    /// System Settings calls this switch Notifications, in both languages.
    public var notificationsTitle: String {
        switch language {
        case .en: "Notifications"
        case .fr: "Notifications"
        }
    }

    public var notificationsWhy: String {
        switch language {
        case .en: "Lets MySidepulse tell you on this Mac when a newer version is out, and "
            + "nothing else. What Claude Code is doing goes to the strip and to your phone."
        case .fr: "Permet à MySidepulse de vous signaler sur ce Mac qu'une nouvelle version "
            + "existe, et rien d'autre. Ce que fait Claude Code passe par le ruban et par "
            + "votre téléphone."
        }
    }

    // MARK: Phone alerts

    public var phoneTitle: String {
        switch language {
        case .en: "Phone alerts"
        case .fr: "Alertes sur le téléphone"
        }
    }

    public var phoneWhy: String {
        switch language {
        case .en: "Sends the finished and needs you alerts to your phone through ntfy, so you "
            + "know without being at the Mac. Settings opens on the QR code your phone scans "
            + "to subscribe."
        case .fr: "Envoie les alertes de fin et de demande à votre téléphone via ntfy, pour "
            + "savoir sans être devant le Mac. Les réglages s'ouvrent sur le QR code que votre "
            + "téléphone scanne pour s'abonner."
        }
    }

    // MARK: what the trailing control says

    public var setUpButton: String {
        switch language {
        case .en: "Set Up…"
        case .fr: "Configurer…"
        }
    }

    public var allowButton: String {
        switch language {
        case .en: "Allow…"
        case .fr: "Autoriser…"
        }
    }

    public var turnOnButton: String {
        switch language {
        case .en: "Turn On"
        case .fr: "Activer"
        }
    }

    public var removeButton: String {
        switch language {
        case .en: "Remove"
        case .fr: "Retirer"
        }
    }

    /// What a row of the app's own shows once it is done.
    public var doneSetUp: String {
        switch language {
        case .en: "Set up"
        case .fr: "Configuré"
        }
    }

    /// What a macOS grant shows once it is there.
    public var doneGranted: String {
        switch language {
        case .en: "Granted"
        case .fr: "Accordé"
        }
    }

    // MARK: stepping

    public var continueButton: String {
        switch language {
        case .en: "Continue"
        case .fr: "Continuer"
        }
    }

    public var skipButton: String {
        switch language {
        case .en: "Skip"
        case .fr: "Passer"
        }
    }

    public var finishButton: String {
        switch language {
        case .en: "Finish"
        case .fr: "Terminer"
        }
    }

    // MARK: All set

    public var finalTitle: String {
        switch language {
        case .en: "All set"
        case .fr: "Tout est prêt"
        }
    }

    public var finalBody: String {
        switch language {
        case .en: "Slide the SidePulse card into your Mac's card slot and watch it light up. "
            + "MySidepulse lives in the menu bar, at the top right, and everything here can be "
            + "changed again from Settings."
        case .fr: "Glissez la carte SidePulse dans le lecteur de votre Mac et regardez-la "
            + "s'allumer. MySidepulse vit dans la barre des menus, en haut à droite, et tout "
            + "ceci se modifie à nouveau depuis les réglages."
        }
    }

    // MARK: the way back

    public var showAgainTitle: String {
        switch language {
        case .en: "Welcome"
        case .fr: "Bienvenue"
        }
    }

    public var showAgainHint: String {
        switch language {
        case .en: "Walks through everything MySidepulse needs, the way it did the first time "
            + "you opened it."
        case .fr: "Reprend tout ce dont MySidepulse a besoin, comme au premier lancement."
        }
    }

    public var showAgainButton: String {
        switch language {
        case .en: "Show Onboarding Again"
        case .fr: "Revoir la présentation"
        }
    }
}

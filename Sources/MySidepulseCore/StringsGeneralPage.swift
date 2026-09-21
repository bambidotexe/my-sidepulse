import Foundation

/// The General page: Startup, Updates, Quit.
public struct GeneralPageStrings {
    private let language: Language
    init(_ language: Language) { self.language = language }

    public var startupTitle: String {
        switch language {
        case .en: "Startup"
        case .fr: "Démarrage"
        }
    }

    public var startupHint: String {
        switch language {
        case .en: "Off, a crash leaves the strip frozen and your phone silent "
            + "until you open MySidepulse again."
        case .fr: "Désactivé, un plantage laisse le ruban figé et votre téléphone "
            + "silencieux jusqu'à ce que vous rouvriez MySidepulse."
        }
    }

    public var startupNote: String {
        switch language {
        case .en: "With the icon hidden, MySidepulse keeps working. Open it again "
            + "from the Applications folder or Spotlight to get back to this window."
        case .fr: "Avec l'icône masquée, MySidepulse continue de fonctionner. "
            + "Rouvrez-le depuis le dossier Applications ou Spotlight pour revenir "
            + "à cette fenêtre."
        }
    }

    public var startupWarningOpenedByHand: String {
        switch language {
        case .en: "MySidepulse was opened by hand, so a crash would not bring it "
            + "back. Log out and in again and it runs under its launch agent."
        case .fr: "MySidepulse a été ouvert à la main : un plantage ne le "
            + "relancerait pas. Déconnectez-vous puis reconnectez-vous pour qu'il "
            + "tourne sous son agent de lancement."
        }
    }

    public var openAtLoginToggle: String {
        switch language {
        case .en: "Open at login and reopen after a crash"
        case .fr: "Ouvrir à la connexion et rouvrir après un plantage"
        }
    }

    public var showInMenuBarToggle: String {
        switch language {
        case .en: "Show in menu bar"
        case .fr: "Afficher dans la barre des menus"
        }
    }

    public var updatesTitle: String {
        switch language {
        case .en: "Updates"
        case .fr: "Mises à jour"
        }
    }

    public var checking: String {
        switch language {
        case .en: "Checking"
        case .fr: "Vérification"
        }
    }

    public var upToDate: String {
        switch language {
        case .en: "Up to date"
        case .fr: "À jour"
        }
    }

    public func versionAvailable(_ version: String) -> String {
        switch language {
        case .en: "Version \(version) is available"
        case .fr: "La version \(version) est disponible"
        }
    }

    public var noReleaseYet: String {
        switch language {
        case .en: "No release published yet"
        case .fr: "Aucune version publiée pour l'instant"
        }
    }

    public func couldNotCheck(_ reason: String) -> String {
        switch language {
        case .en: "Could not check: \(reason)"
        case .fr: "Vérification impossible : \(reason)"
        }
    }

    public func updateFailed(_ reason: String) -> String {
        switch language {
        case .en: "Update failed: \(reason)"
        case .fr: "Échec de la mise à jour : \(reason)"
        }
    }

    public var updateButton: String {
        switch language {
        case .en: "Update"
        case .fr: "Mettre à jour"
        }
    }

    public var checkForUpdatesButton: String {
        switch language {
        case .en: "Check for Updates"
        case .fr: "Rechercher des mises à jour"
        }
    }

    // MARK: Support

    public var quitTitle: String {
        switch language {
        case .en: "Quit"
        case .fr: "Quitter"
        }
    }

    public var quitButton: String {
        switch language {
        case .en: "Quit MySidepulse"
        case .fr: "Quitter MySidepulse"
        }
    }

    // MARK: Uninstall

    public var uninstallTitle: String {
        switch language {
        case .en: "Uninstall"
        case .fr: "Désinstaller"
        }
    }

    public var uninstallHint: String {
        switch language {
        case .en: "Removes everything MySidepulse set up outside its own folder: "
            + "what starts it at login and reopens it after a crash, what it added "
            + "to Claude Code and to the shell, and its settings, its journal and "
            + "your notification topic. The strip goes dark, MySidepulse moves "
            + "itself to the Trash and quits."
        case .fr: "Retire tout ce que MySidepulse a installé hors de son propre "
            + "dossier : ce qui le lance à l'ouverture de session et le rouvre "
            + "après un plantage, ce qu'il a ajouté à Claude Code et au shell, "
            + "ainsi que ses réglages, son journal et votre sujet de "
            + "notification. Le ruban s'éteint, MySidepulse se met à la corbeille "
            + "et quitte."
        }
    }

    public var uninstallWarning: String {
        switch language {
        case .en: "Do not drag MySidepulse to the Trash. All of that stays behind: "
            + "macOS goes on trying to start an app that is gone at every login, "
            + "and the Claude Code hooks fire at a missing command on every event."
        case .fr: "Ne mettez pas MySidepulse à la corbeille vous-même. Tout cela "
            + "resterait en place : macOS essaierait de lancer une app disparue à "
            + "chaque ouverture de session, et les hooks Claude Code appelleraient "
            + "une commande absente à chaque événement."
        }
    }

    public var uninstallButton: String {
        switch language {
        case .en: "Uninstall MySidepulse"
        case .fr: "Désinstaller MySidepulse"
        }
    }

    public var uninstallConfirmTitle: String {
        switch language {
        case .en: "Uninstall MySidepulse?"
        case .fr: "Désinstaller MySidepulse ?"
        }
    }

    public var uninstallConfirmBody: String {
        switch language {
        case .en: "MySidepulse turns the strip off, removes what starts it at "
            + "login, what it added to Claude Code and to the shell, and its "
            + "settings, its journal and your notification topic. It then moves "
            + "itself to the Trash and quits."
        case .fr: "MySidepulse éteint le ruban, retire ce qui le lance à "
            + "l'ouverture de session, ce qu'il a ajouté à Claude Code et au "
            + "shell, ainsi que ses réglages, son journal et votre sujet de "
            + "notification. Il se met ensuite à la corbeille et quitte."
        }
    }

    public var uninstallConfirmButton: String {
        switch language {
        case .en: "Uninstall"
        case .fr: "Désinstaller"
        }
    }

    public var uninstallCancelButton: String {
        switch language {
        case .en: "Cancel"
        case .fr: "Annuler"
        }
    }

    public var uninstallDoneTitle: String {
        switch language {
        case .en: "MySidepulse has been removed"
        case .fr: "MySidepulse a été désinstallé"
        }
    }

    public var uninstallDoneBody: String {
        switch language {
        case .en: "MySidepulse is in the Trash, and nothing it set up is left on the Mac."
        case .fr: "MySidepulse est dans la corbeille, et rien de ce qu'il avait "
            + "installé ne reste sur le Mac."
        }
    }

    public var uninstallPartialTitle: String {
        switch language {
        case .en: "MySidepulse has been removed, except for this"
        case .fr: "MySidepulse a été désinstallé, sauf ceci"
        }
    }

    public var uninstallQuitButton: String {
        switch language {
        case .en: "Quit"
        case .fr: "Quitter"
        }
    }

    public func uninstallHooksFailed(_ reason: String) -> String {
        switch language {
        case .en: "The Claude Code hooks could not be removed: \(reason)"
        case .fr: "Les hooks Claude Code n'ont pas pu être retirés : \(reason)"
        }
    }

    public func uninstallZshFailed(_ reason: String) -> String {
        switch language {
        case .en: "The line in .zshrc could not be removed: \(reason)"
        case .fr: "La ligne ajoutée à .zshrc n'a pas pu être retirée : \(reason)"
        }
    }

    public func uninstallAgentFailed(_ reason: String) -> String {
        switch language {
        case .en: "What starts MySidepulse at login could not be removed: \(reason)"
        case .fr: "Ce qui lance MySidepulse à l'ouverture de session n'a pas pu "
            + "être retiré : \(reason)"
        }
    }

    public func uninstallTrashFailed(_ reason: String) -> String {
        switch language {
        case .en: "MySidepulse could not move itself to the Trash: \(reason). Drag "
            + "it there from the Applications folder; that is all that is left of it."
        case .fr: "MySidepulse n'a pas pu se mettre à la corbeille : \(reason). "
            + "Faites-le depuis le dossier Applications ; c'est tout ce qu'il en reste."
        }
    }

    public func uninstallHelperFailed(_ reason: String) -> String {
        switch language {
        case .en: "The last step could not be started: \(reason). Log out and in "
            + "again, and nothing of MySidepulse will be loaded."
        case .fr: "La dernière étape n'a pas pu démarrer : \(reason). Déconnectez-vous "
            + "puis reconnectez-vous, et plus rien de MySidepulse ne sera chargé."
        }
    }

    public func uninstallCLILeft(_ path: String) -> String {
        switch language {
        case .en: "This one needs an administrator password, so it is still there: "
            + "\(path). Remove it with `sudo rm \(path)`."
        case .fr: "Celui-ci demande un mot de passe administrateur, il est donc "
            + "toujours là : \(path). Retirez-le avec `sudo rm \(path)`."
        }
    }
}

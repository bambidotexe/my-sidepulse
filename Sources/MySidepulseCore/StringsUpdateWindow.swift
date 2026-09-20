import Foundation

/// The update window and the notification that leads to it. The version line
/// ("MySidepulse 1.13.0") is the app's name and is never translated; a failure
/// reads `Update failed: <reason>`, the General page's own sentence.
public struct UpdateWindowStrings {
    private let language: Language
    init(_ language: Language) { self.language = language }

    public var windowTitle: String {
        switch language {
        case .en: "Software Update"
        case .fr: "Mise à jour de logiciels"
        }
    }

    /// Under the notification's title, which is the General page's
    /// `Version 1.13.0 is available`.
    public var notificationBody: String {
        switch language {
        case .en: "Click Update to download and install it."
        case .fr: "Cliquez sur Mettre à jour pour la télécharger et l'installer."
        }
    }

    public func downloading(_ received: String, of total: String) -> String {
        switch language {
        case .en: "Downloading: \(received) of \(total)"
        case .fr: "Téléchargement : \(received) sur \(total)"
        }
    }

    /// No total to measure against.
    public var downloadingUnmeasured: String {
        switch language {
        case .en: "Downloading"
        case .fr: "Téléchargement"
        }
    }

    public var preparing: String {
        switch language {
        case .en: "Preparing the update"
        case .fr: "Préparation de la mise à jour"
        }
    }

    public var ready: String {
        switch language {
        case .en: "Ready to install. MySidepulse will quit and reopen."
        case .fr: "Prête à être installée. MySidepulse va quitter puis se rouvrir."
        }
    }

    public var cannotReplaceItself: String {
        switch language {
        case .en: "MySidepulse cannot replace itself where it is installed. Open the disk image "
            + "and drag MySidepulse to Applications, then quit and reopen it."
        case .fr: "MySidepulse ne peut pas se remplacer là où il est installé. Ouvrez l'image "
            + "disque et faites glisser MySidepulse vers Applications, puis quittez-le et rouvrez-le."
        }
    }

    public var installing: String {
        switch language {
        case .en: "Installing"
        case .fr: "Installation"
        }
    }

    public var didNotQuit: String {
        switch language {
        case .en: "MySidepulse did not quit. Close its open dialogs, then try again."
        case .fr: "MySidepulse n'a pas quitté. Fermez ses dialogues ouverts, puis réessayez."
        }
    }

    /// The window's last word, at the launch that follows an install.
    public var installed: String {
        switch language {
        case .en: "The update is installed. MySidepulse is running the new version."
        case .fr: "La mise à jour est installée. MySidepulse utilise la nouvelle version."
        }
    }

    /// The same, when the version that runs is still the one that was there before.
    public func notInstalled(_ version: String, _ reason: String) -> String {
        switch language {
        case .en: "Version \(version) was not installed. \(reason)"
        case .fr: "La version \(version) n'a pas été installée. \(reason)"
        }
    }

    public var doneButton: String {
        switch language {
        case .en: "Done"
        case .fr: "Terminé"
        }
    }

    public var cancelButton: String {
        switch language {
        case .en: "Cancel"
        case .fr: "Annuler"
        }
    }

    public var closeButton: String {
        switch language {
        case .en: "Close"
        case .fr: "Fermer"
        }
    }

    public var installButton: String {
        switch language {
        case .en: "Install and Relaunch"
        case .fr: "Installer et relancer"
        }
    }

    public var openDiskImageButton: String {
        switch language {
        case .en: "Open Disk Image"
        case .fr: "Ouvrir l'image disque"
        }
    }

    public var tryAgainButton: String {
        switch language {
        case .en: "Try Again"
        case .fr: "Réessayer"
        }
    }
}

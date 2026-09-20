import Foundation

/// `HookInstaller`'s outcome lines. Like the doctor's details these serve two
/// callers: `mysidepulse install-hooks` / `uninstall-hooks` in a terminal,
/// always English, and the System page, in the ambient language.
///
/// Command names, paths and file names inside these sentences are not prose and
/// stay as they are in both languages.
public struct HookInstallStrings {
    private let language: Language
    init(_ language: Language) { self.language = language }

    public var notModified: String {
        switch language {
        case .en: "Your settings file was not modified."
        case .fr: "Votre fichier de réglages n'a pas été modifié."
        }
    }

    public func noCLIInBundle(path: String) -> String {
        switch language {
        case .en: "install-hooks failed: no mysidepulse CLI inside an app bundle at \(path)"
        case .fr: "install-hooks a échoué : aucun CLI mysidepulse dans une app à \(path)"
        }
    }

    public func installed(total: Int, command: String) -> String {
        switch language {
        case .en: total == 1 ? "Installed 1 Claude Code hook -> \(command)"
                            : "Installed \(total) Claude Code hooks -> \(command)"
        case .fr: total == 1 ? "1 hook Claude Code installé -> \(command)"
                            : "\(total) hooks Claude Code installés -> \(command)"
        }
    }

    public func installedPartial(installed: Int, total: Int, command: String) -> String {
        switch language {
        case .en: "Installed \(installed) of \(total) hooks -> \(command)"
        case .fr: "\(installed) hooks sur \(total) installés -> \(command)"
        }
    }

    public func declinedToTouch(_ joined: String) -> String {
        switch language {
        case .en: "Declined to touch: \(joined)"
        case .fr: "Non modifiés : \(joined)"
        }
    }

    public var declinedShapeNote: String {
        switch language {
        case .en: "(their existing value in ~/.claude/settings.json has a shape "
            + "this tool does not rewrite)"
        case .fr: "(leur valeur actuelle dans ~/.claude/settings.json a une forme "
            + "que cet outil ne réécrit pas)"
        }
    }

    public func backupWritten(path: String) -> String {
        switch language {
        case .en: "Backup written to \(path)"
        case .fr: "Sauvegarde écrite dans \(path)"
        }
    }

    public func installFailed(_ error: String) -> String {
        switch language {
        case .en: "install-hooks failed: \(error)"
        case .fr: "install-hooks a échoué : \(error)"
        }
    }

    public var noSettingsFileNothingToRemove: String {
        switch language {
        case .en: "No settings file found, nothing to remove."
        case .fr: "Aucun fichier de réglages trouvé, rien à retirer."
        }
    }

    public var removedHooks: String {
        switch language {
        case .en: "Removed MySidepulse hooks."
        case .fr: "Hooks MySidepulse retirés."
        }
    }

    public func uninstallFailed(_ error: String) -> String {
        switch language {
        case .en: "uninstall-hooks failed: \(error)"
        case .fr: "uninstall-hooks a échoué : \(error)"
        }
    }

    public func noCLIAtPath(_ path: String) -> String {
        switch language {
        case .en: "No mysidepulse CLI at \(path); left ~/.zshrc untouched."
        case .fr: "Aucun CLI mysidepulse à \(path) ; ~/.zshrc laissé inchangé."
        }
    }

    public var couldNotReadZshrc: String {
        switch language {
        case .en: "Could not read ~/.zshrc (not UTF-8?); left it untouched."
        case .fr: "Impossible de lire ~/.zshrc (pas de l'UTF-8 ?) ; laissé inchangé."
        }
    }

    public var alreadySourcesSnippet: String {
        switch language {
        case .en: "~/.zshrc already sources the MySidepulse snippet."
        case .fr: "~/.zshrc charge déjà l'extrait MySidepulse."
        }
    }

    public var addedBlock: String {
        switch language {
        case .en: "Added the MySidepulse block to ~/.zshrc. Open a new terminal for "
            + "it to take effect."
        case .fr: "Bloc MySidepulse ajouté à ~/.zshrc. Ouvrez un nouveau terminal "
            + "pour qu'il prenne effet."
        }
    }

    public var zshrcDoesNotExist: String {
        switch language {
        case .en: "~/.zshrc does not exist; nothing to remove."
        case .fr: "~/.zshrc n'existe pas ; rien à retirer."
        }
    }

    public var doesNotSourceSnippet: String {
        switch language {
        case .en: "~/.zshrc does not source the MySidepulse snippet."
        case .fr: "~/.zshrc ne charge pas l'extrait MySidepulse."
        }
    }

    public var removedBlock: String {
        switch language {
        case .en: "Removed the MySidepulse block from ~/.zshrc. Open a new terminal "
            + "for it to take effect."
        case .fr: "Bloc MySidepulse retiré de ~/.zshrc. Ouvrez un nouveau terminal "
            + "pour qu'il prenne effet."
        }
    }

    public func couldNotWriteZshrc(_ error: String) -> String {
        switch language {
        case .en: "Could not write ~/.zshrc: \(error)"
        case .fr: "Impossible d'écrire ~/.zshrc : \(error)"
        }
    }
}

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

    public func installed(total: Int, agent: AgentKind, command: String) -> String {
        let name = agent.productName
        switch language {
        case .en: return total == 1 ? "Installed 1 \(name) hook -> \(command)"
                                   : "Installed \(total) \(name) hooks -> \(command)"
        case .fr: return total == 1 ? "1 hook \(name) installé -> \(command)"
                                   : "\(total) hooks \(name) installés -> \(command)"
        }
    }

    /// OpenCode's plugin is one file, not a count of hooks.
    public func installedPlugin(agent: AgentKind, command: String) -> String {
        let name = agent.productName
        switch language {
        case .en: return "Installed the \(name) plugin -> \(command)"
        case .fr: return "Plugin \(name) installé -> \(command)"
        }
    }

    /// `install-hooks` from a terminal sets up every agent on the Mac; one
    /// that is not there is said, not failed.
    public var codexNotInstalledSkipped: String { notInstalledSkipped(.codex) }

    public func notInstalledSkipped(_ agent: AgentKind) -> String {
        switch (agent, language) {
        case (.claude, .en): "Claude Code is not installed, so its hooks were not set up."
        case (.claude, .fr): "Claude Code n'est pas installé, ses hooks n'ont donc pas été configurés."
        case (.codex, .en): "Codex is not installed (no ~/.codex), so its hooks were not set up."
        case (.codex, .fr): "Codex n'est pas installé (pas de ~/.codex), ses hooks n'ont donc pas été configurés."
        case (.copilot, .en): "GitHub Copilot is not installed (no ~/.copilot), so its hooks were not set up."
        case (.copilot, .fr): "GitHub Copilot n'est pas installé (pas de ~/.copilot), ses hooks n'ont donc pas été configurés."
        case (.opencode, .en): "OpenCode is not installed (no ~/.config/opencode, ~/.opencode or OpenCode.app), "
            + "so its plugin was not set up."
        case (.opencode, .fr): "OpenCode n'est pas installé (pas de ~/.config/opencode, ~/.opencode ni OpenCode.app), "
            + "son plugin n'a donc pas été configuré."
        }
    }

    /// A file at the path MySidepulse writes whole that something else wrote:
    /// never replaced, never deleted.
    public func notOursLeftAlone(file: String) -> String {
        switch language {
        case .en: "\(file) is not MySidepulse's; left it untouched."
        case .fr: "\(file) n'est pas celui de MySidepulse ; laissé inchangé."
        }
    }

    public func removedFile(_ file: String) -> String {
        switch language {
        case .en: "Removed \(file)."
        case .fr: "\(file) retiré."
        }
    }

    public func noFileNothingToRemove(_ file: String) -> String {
        switch language {
        case .en: "No \(file), nothing to remove."
        case .fr: "Pas de \(file), rien à retirer."
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

    public func declinedShapeNote(file: String) -> String {
        switch language {
        case .en: "(their existing value in \(file) has a shape this tool does not rewrite)"
        case .fr: "(leur valeur actuelle dans \(file) a une forme que cet outil ne réécrit pas)"
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

import Foundation

/// The System page: what the app needs from Claude Code and from the terminal.
public struct SystemPageStrings {
    private let language: Language
    init(_ language: Language) { self.language = language }

    public var claudeCodeTitle: String {
        switch language {
        case .en: "Claude Code"
        case .fr: "Claude Code"
        }
    }

    public func claudeCodeHint(events: Int) -> String {
        switch language {
        case .en: "The hooks tell MySidepulse when Claude Code works, finishes or "
            + "needs you. Set Up adds \(events) of them to Claude Code's settings, "
            + "after backing the file up. Remove takes out MySidepulse's own "
            + "entries and nothing else."
        case .fr: "Les hooks indiquent à MySidepulse quand Claude Code travaille, "
            + "termine ou a besoin de vous. Configurer en ajoute \(events) aux "
            + "réglages de Claude Code, après avoir sauvegardé le fichier. Retirer "
            + "ne supprime que les entrées propres à MySidepulse."
        }
    }

    public var claudeCodeNote: String {
        switch language {
        case .en: "Sessions already open pick the hooks up on their own."
        case .fr: "Les sessions déjà ouvertes détectent les hooks automatiquement."
        }
    }

    public var claudeCodeHooksLabel: String {
        switch language {
        case .en: "Claude Code hooks"
        case .fr: "Hooks Claude Code"
        }
    }

    public var removeHooksButton: String {
        switch language {
        case .en: "Remove Hooks"
        case .fr: "Retirer les hooks"
        }
    }

    public var setUpHooksButton: String {
        switch language {
        case .en: "Set Up Hooks"
        case .fr: "Configurer les hooks"
        }
    }

    public var terminalTitle: String {
        switch language {
        case .en: "Terminal"
        case .fr: "Terminal"
        }
    }

    public func terminalHint(seconds: Int) -> String {
        switch language {
        case .en: "Shows a command that runs longer than \(seconds) s on the strip, "
            + "and whether it succeeded. Set Up adds one block to ~/.zshrc."
        case .fr: "Affiche sur le ruban une commande qui dure plus de \(seconds) s, "
            + "et si elle a réussi. Configurer ajoute un bloc à ~/.zshrc."
        }
    }

    public var terminalNote: String {
        switch language {
        case .en: "Open a new terminal window after setting it up."
        case .fr: "Ouvrez une nouvelle fenêtre de terminal après la configuration."
        }
    }

    public var terminalHookLabel: String {
        switch language {
        case .en: "Terminal hook"
        case .fr: "Hook de terminal"
        }
    }

    public var removeTerminalHookButton: String {
        switch language {
        case .en: "Remove Terminal Hook"
        case .fr: "Retirer le hook de terminal"
        }
    }

    public var setUpTerminalHookButton: String {
        switch language {
        case .en: "Set Up Terminal Hook"
        case .fr: "Configurer le hook de terminal"
        }
    }

    /// Names the button the user must press, so it has to read exactly as the
    /// button does in the same language.
    public var withoutHooksWarning: String {
        switch language {
        case .en: "Without the hooks the strip never shows Claude. Press "
            + "\(setUpHooksButton)."
        case .fr: "Sans les hooks, le ruban ne montre jamais Claude. Cliquez sur "
            + "\(setUpHooksButton)."
        }
    }

    /// Names the button the user must press, so it has to read exactly as the
    /// button does in the same language.
    public var withoutTerminalHookWarning: String {
        switch language {
        case .en: "Without it, commands you run in a terminal never show on the strip. Press "
            + "\(setUpTerminalHookButton)."
        case .fr: "Sans lui, les commandes lancées dans un terminal ne s'affichent jamais sur le "
            + "ruban. Cliquez sur \(setUpTerminalHookButton)."
        }
    }

    // MARK: Notifications

    public var notificationsTitle: String {
        switch language {
        case .en: "Notifications"
        case .fr: "Notifications"
        }
    }

    public var notificationsPermissionLabel: String {
        switch language {
        case .en: "Notifications permission"
        case .fr: "Autorisation des notifications"
        }
    }

    public var allowNotificationsButton: String {
        switch language {
        case .en: "Allow Notifications"
        case .fr: "Autoriser les notifications"
        }
    }

    /// Names the button the user must press, so it has to read exactly as the
    /// button does in the same language. Once refused, macOS asks nothing more
    /// and the button does nothing visible, hence the second sentence.
    public var notificationsWarning: String {
        switch language {
        case .en: "Press \(allowNotificationsButton). If nothing appears, turn on notifications for "
            + "MySidepulse in System Settings › Notifications."
        case .fr: "Cliquez sur \(allowNotificationsButton). Si rien n'apparaît, activez les "
            + "notifications de MySidepulse dans Réglages Système › Notifications."
        }
    }

    public var settingsUnreadableWarning: String {
        switch language {
        case .en: "Claude Code's settings file could not be read. Check that "
            + "~/.claude/settings.json is valid JSON."
        case .fr: "Le fichier de réglages de Claude Code n'a pas pu être lu. "
            + "Vérifiez que ~/.claude/settings.json est un JSON valide."
        }
    }
}

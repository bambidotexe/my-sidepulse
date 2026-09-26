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

    // MARK: Codex

    public var codexTitle: String {
        switch language {
        case .en: "Codex"
        case .fr: "Codex"
        }
    }

    public func codexHint(events: Int) -> String {
        switch language {
        case .en: "The hooks tell MySidepulse when Codex works, finishes or needs you. "
            + "Set Up adds \(events) of them to Codex's hooks file and trusts them in its "
            + "config.toml, after backing both files up. Remove takes out MySidepulse's own "
            + "entries and their trust, and nothing else."
        case .fr: "Les hooks indiquent à MySidepulse quand Codex travaille, termine ou "
            + "a besoin de vous. Configurer en ajoute \(events) au fichier de hooks de "
            + "Codex et les approuve dans son config.toml, après avoir sauvegardé les deux "
            + "fichiers. Retirer ne supprime que les entrées propres à MySidepulse et leur "
            + "approbation."
        }
    }

    /// Codex runs a hook only once it is trusted, and Set Up writes that
    /// trust, so no visit to Codex's own /hooks screen is needed.
    public var codexNote: String {
        switch language {
        case .en: "Codex runs a hook only once it is trusted. Set Up trusts these for you."
        case .fr: "Codex ne lance un hook qu'une fois approuvé. Configurer approuve "
            + "ceux-ci pour vous."
        }
    }

    public var codexHooksLabel: String {
        switch language {
        case .en: "Codex hooks"
        case .fr: "Hooks Codex"
        }
    }

    /// Names the button the user must press, so it has to read exactly as the
    /// button does in the same language.
    public var withoutCodexHooksWarning: String {
        switch language {
        case .en: "Without the hooks the strip never shows Codex. Press "
            + "\(setUpHooksButton)."
        case .fr: "Sans les hooks, le ruban ne montre jamais Codex. Cliquez sur "
            + "\(setUpHooksButton)."
        }
    }

    public var codexHooksUnreadableWarning: String {
        switch language {
        case .en: "Codex's hooks file could not be read. Check that "
            + "~/.codex/hooks.json is valid JSON."
        case .fr: "Le fichier de hooks de Codex n'a pas pu être lu. "
            + "Vérifiez que ~/.codex/hooks.json est un JSON valide."
        }
    }

    /// The hooks are in hooks.json and Codex has not trusted them, or one is
    /// switched off in Codex: Codex never runs them. Names the button, so it
    /// has to read exactly as the button does in the same language.
    public var codexHooksUntrustedWarning: String {
        switch language {
        case .en: "Codex has not trusted the hooks, so it never runs them. Press "
            + "\(setUpHooksButton) to trust them."
        case .fr: "Codex n'a pas approuvé les hooks, il ne les lance donc jamais. "
            + "Cliquez sur \(setUpHooksButton) pour les approuver."
        }
    }

    /// config.toml is there and cannot be read as text: whether Codex trusts
    /// the hooks is unknown, and Set Up refuses to write it.
    public var codexConfigUnreadableWarning: String {
        switch language {
        case .en: "Codex's config.toml could not be read, so whether Codex trusts the "
            + "hooks is unknown. Check that ~/.codex/config.toml is plain text."
        case .fr: "Le fichier config.toml de Codex n'a pas pu être lu : on ne sait pas "
            + "si Codex approuve les hooks. Vérifiez que ~/.codex/config.toml est du "
            + "texte brut."
        }
    }

    // MARK: GitHub Copilot

    public var copilotTitle: String {
        switch language {
        case .en: "Copilot"
        case .fr: "Copilot"
        }
    }

    public func copilotHint(events: Int) -> String {
        switch language {
        case .en: "The hooks tell MySidepulse when Copilot works, finishes or needs you. Set Up writes "
            + "\(events) of them to ~/.copilot/hooks/mysidepulse.json, a file MySidepulse owns whole. "
            + "Remove deletes it."
        case .fr: "Les hooks indiquent à MySidepulse quand Copilot travaille, termine ou a besoin de "
            + "vous. Configurer en écrit \(events) dans ~/.copilot/hooks/mysidepulse.json, un fichier "
            + "propre à MySidepulse. Retirer le supprime."
        }
    }

    /// Copilot needs no trust step, unlike Codex: it reads every file under hooks/ at each start.
    public var copilotNote: String {
        switch language {
        case .en: "Copilot reads the hooks at its next start, with no trust step of its own."
        case .fr: "Copilot lit les hooks à son prochain démarrage, sans étape d'approbation."
        }
    }

    public var copilotHooksLabel: String {
        switch language {
        case .en: "Copilot hooks"
        case .fr: "Hooks Copilot"
        }
    }

    /// Names the button the user must press, so it has to read exactly as the
    /// button does in the same language.
    public var withoutCopilotHooksWarning: String {
        switch language {
        case .en: "Without the hooks the strip never shows Copilot. Press \(setUpHooksButton)."
        case .fr: "Sans les hooks, le ruban ne montre jamais Copilot. Cliquez sur \(setUpHooksButton)."
        }
    }

    public var copilotHooksInvalidWarning: String {
        switch language {
        case .en: "Copilot's hook file could not be read as JSON. Fix or remove "
            + "~/.copilot/hooks/mysidepulse.json by hand: \(setUpHooksButton) refuses a file it "
            + "does not recognise."
        case .fr: "Le fichier de hooks de Copilot n'a pas pu être lu comme JSON. Réparez-le ou "
            + "supprimez ~/.copilot/hooks/mysidepulse.json à la main : \(setUpHooksButton) refuse "
            + "un fichier qu'il ne reconnaît pas."
        }
    }

    public var copilotHooksDisabledWarning: String {
        switch language {
        case .en: "Copilot's hooks are turned off. Remove \u{201c}disableAllHooks\u{201d} from "
            + "~/.copilot/settings.json or ~/.copilot/config.json."
        case .fr: "Les hooks de Copilot sont désactivés. Retirez \u{ab} disableAllHooks \u{bb} de "
            + "~/.copilot/settings.json ou ~/.copilot/config.json."
        }
    }

    // MARK: OpenCode

    public var opencodeTitle: String {
        switch language {
        case .en: "OpenCode"
        case .fr: "OpenCode"
        }
    }

    public var opencodeHint: String {
        switch language {
        case .en: "The plugin tells MySidepulse when OpenCode works, finishes or needs you. Set Up "
            + "writes it to ~/.config/opencode/plugins/mysidepulse.js, a file MySidepulse owns whole. "
            + "Remove deletes it."
        case .fr: "Le plugin indique à MySidepulse quand OpenCode travaille, termine ou a besoin de "
            + "vous. Configurer l'écrit dans ~/.config/opencode/plugins/mysidepulse.js, un fichier "
            + "propre à MySidepulse. Retirer le supprime."
        }
    }

    public var opencodeNote: String {
        switch language {
        case .en: "A running OpenCode server picks up the plugin within a second, with no restart."
        case .fr: "Un serveur OpenCode en cours d'exécution prend le plugin en compte en moins d'une "
            + "seconde, sans redémarrage."
        }
    }

    public var opencodePluginLabel: String {
        switch language {
        case .en: "OpenCode plugin"
        case .fr: "Plugin OpenCode"
        }
    }

    public var setUpPluginButton: String {
        switch language {
        case .en: "Set Up Plugin"
        case .fr: "Configurer le plugin"
        }
    }

    public var removePluginButton: String {
        switch language {
        case .en: "Remove Plugin"
        case .fr: "Retirer le plugin"
        }
    }

    /// Names the button the user must press, so it has to read exactly as the
    /// button does in the same language.
    public var withoutOpencodePluginWarning: String {
        switch language {
        case .en: "Without the plugin the strip never shows OpenCode. Press \(setUpPluginButton)."
        case .fr: "Sans le plugin, le ruban ne montre jamais OpenCode. Cliquez sur \(setUpPluginButton)."
        }
    }

    public var opencodePluginInvalidWarning: String {
        switch language {
        case .en: "OpenCode's plugin is not this copy's. A stale plugin of another copy of "
            + "MySidepulse is replaced by pressing \(setUpPluginButton); a plugin it does not "
            + "recognise must be removed by hand."
        case .fr: "Le plugin OpenCode n'est pas celui de cette copie. Un plugin d'une autre copie "
            + "de MySidepulse est remplacé en cliquant sur \(setUpPluginButton) ; un plugin qu'il "
            + "ne reconnaît pas doit être supprimé à la main."
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

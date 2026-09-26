import Foundation

/// The doctor's detail sentences. `Doctor` produces them for two callers at
/// once: `mysidepulse doctor` in a terminal, which is always English, and the
/// Health page, which is in the ambient language. Reading the language here,
/// at the moment the sentence is built, is what serves both.
///
/// The check *names* are not here. They are identifiers the CLI prints and the
/// Health page matches on, not prose, so they stay English.
///
/// No detail carries a long dash, in either language: the window shows them as
/// tooltips and copies them into the Health report. `DoctorTests` pins that.
public struct DoctorStrings {
    private let language: Language
    init(_ language: Language) { self.language = language }

    public func appRunning(mode: String) -> String {
        switch language {
        case .en: "MySidepulse.app is running (mode \(mode))"
        case .fr: "MySidepulse.app est en cours d'exécution (mode \(mode))"
        }
    }

    public var controlSocketUnreachable: String {
        switch language {
        case .en: "control socket unreachable: is MySidepulse.app running?"
        case .fr: "socket de contrôle injoignable : MySidepulse.app est-il lancé ?"
        }
    }

    public var unknownAppUnreachable: String {
        switch language {
        case .en: "unknown (app unreachable)"
        case .fr: "inconnu (app injoignable)"
        }
    }

    public var launchAgentRegistered: String {
        switch language {
        case .en: "launch agent registered: starts at login, restarts on crash"
        case .fr: "agent de lancement enregistré : démarre à la connexion, "
            + "redémarre après un plantage"
        }
    }

    public func allEventsSubscribed(_ count: Int) -> String {
        switch language {
        case .en: count == 1 ? "1 event subscribed" : "all \(count) events subscribed"
        case .fr: count == 1 ? "1 événement abonné" : "les \(count) événements sont tous abonnés"
        }
    }

    public func missingEvents(_ joined: String) -> String {
        switch language {
        case .en: "missing: \(joined). Run mysidepulse install-hooks"
        case .fr: "manquants : \(joined). Lancez mysidepulse install-hooks"
        }
    }

    public var hookPointsAtMissingBinary: String {
        switch language {
        case .en: "hook command points at a missing binary. Run mysidepulse install-hooks"
        case .fr: "la commande du hook pointe vers un binaire manquant. "
            + "Lancez mysidepulse install-hooks"
        }
    }

    public var binaryExists: String {
        switch language {
        case .en: "binary exists"
        case .fr: "le binaire existe"
        }
    }

    public var hookCommandNotInstalled: String {
        switch language {
        case .en: "not installed"
        case .fr: "non installée"
        }
    }

    public var hookCommandUnknown: String {
        switch language {
        case .en: "unknown (settings unreadable)"
        case .fr: "inconnue (réglages illisibles)"
        }
    }

    public var settingsMissingOrUnparseable: String {
        switch language {
        case .en: "~/.claude/settings.json missing or unparseable"
        case .fr: "~/.claude/settings.json manquant ou illisible"
        }
    }

    public var settingsUnreadable: String {
        switch language {
        case .en: "settings unreadable"
        case .fr: "réglages illisibles"
        }
    }

    public var journalAppend: String {
        switch language {
        case .en: "append to journal.jsonl"
        case .fr: "écriture dans journal.jsonl"
        }
    }

    public func lastEventAgo(seconds: Int) -> String {
        switch language {
        case .en: "\(seconds) s ago"
        case .fr: "il y a \(seconds) s"
        }
    }

    public var journalEmpty: String {
        switch language {
        case .en: "journal empty (no agent session since install)"
        case .fr: "journal vide (aucune session d'agent depuis l'installation)"
        }
    }

    public var codexNotInstalled: String {
        switch language {
        case .en: "Codex not installed (no ~/.codex), nothing to subscribe"
        case .fr: "Codex non installé (pas de ~/.codex), rien à abonner"
        }
    }

    public var codexHooksMissingOrUnparseable: String {
        switch language {
        case .en: "~/.codex/hooks.json missing or unparseable. Run mysidepulse install-hooks"
        case .fr: "~/.codex/hooks.json manquant ou illisible. Lancez mysidepulse install-hooks"
        }
    }

    public var copilotNotInstalled: String {
        switch language {
        case .en: "GitHub Copilot not installed (no ~/.copilot), nothing to subscribe"
        case .fr: "GitHub Copilot non installé (pas de ~/.copilot), rien à abonner"
        }
    }

    public var copilotHooksMissingOrUnparseable: String {
        switch language {
        case .en: "~/.copilot/hooks/mysidepulse.json missing or unparseable. Run mysidepulse install-hooks"
        case .fr: "~/.copilot/hooks/mysidepulse.json manquant ou illisible. Lancez mysidepulse install-hooks"
        }
    }

    public var copilotHooksDisabledDetail: String {
        switch language {
        case .en: "disableAllHooks turns every Copilot hook off. Remove it from ~/.copilot/settings.json"
        case .fr: "disableAllHooks désactive tous les hooks Copilot. Retirez-le de ~/.copilot/settings.json"
        }
    }

    public var opencodeNotInstalled: String {
        switch language {
        case .en: "OpenCode not installed (no ~/.config/opencode, ~/.opencode or OpenCode.app), nothing to load"
        case .fr: "OpenCode non installé (pas de ~/.config/opencode, ~/.opencode ni OpenCode.app), rien à charger"
        }
    }

    public var opencodePluginMissing: String {
        switch language {
        case .en: "~/.config/opencode/plugins/mysidepulse.js missing. Run mysidepulse install-hooks"
        case .fr: "~/.config/opencode/plugins/mysidepulse.js manquant. Lancez mysidepulse install-hooks"
        }
    }

    public var opencodePluginCurrentDetail: String {
        switch language {
        case .en: "plugin written by this copy of MySidepulse"
        case .fr: "plugin écrit par cette copie de MySidepulse"
        }
    }

    public var opencodePluginStale: String {
        switch language {
        case .en: "plugin belongs to another copy of MySidepulse. Run mysidepulse install-hooks"
        case .fr: "le plugin appartient à une autre copie de MySidepulse. Lancez mysidepulse install-hooks"
        }
    }

    public var noVolumeMounted: String {
        switch language {
        case .en: "no SidePulse volume mounted (plug it in to verify)"
        case .fr: "aucun volume SidePulse monté (branchez-le pour vérifier)"
        }
    }

    /// `STALLED` shouts because it is the one detail worth spotting in a wall
    /// of report text. Nothing reads it back: the Health page takes the strip's
    /// state from the engine.
    public func deviceDetail(name: String, path: String, leds: Int, stalled: Bool) -> String {
        switch language {
        case .en: "\(name) at \(path) (\(language.leds(leds))\(stalled ? ", STALLED" : ""))"
        case .fr: "\(name) à \(path) (\(language.leds(leds))\(stalled ? ", BLOQUÉ" : ""))"
        }
    }

    public var notificationsOff: String {
        switch language {
        case .en: "off. Enable with mysidepulse notify on"
        case .fr: "désactivé. Activez avec mysidepulse notify on"
        }
    }

    public func notificationsOn(topicMasked: String, server: String) -> String {
        switch language {
        case .en: "on: \(topicMasked) at \(server)"
        case .fr: "activé : \(topicMasked) sur \(server)"
        }
    }

    public func notificationsUnusable(topicMasked: String, server: String) -> String {
        switch language {
        case .en: "on, but topic or server is unusable: \(topicMasked) at \(server)"
        case .fr: "activé, mais le sujet ou le serveur est inutilisable : "
            + "\(topicMasked) sur \(server)"
        }
    }
}

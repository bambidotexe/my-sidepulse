import Foundation

/// The Health page's own words: the two tables' titles, the labels of the lines no other page has, the
/// readings, and the sentences that say how to put a line right. A row that another page also shows takes that page's
/// label and warning, so one state is never named twice. The detail sentences in the tooltips come from
/// `DoctorStrings`, because the CLI prints them too.
///
/// Console's own name for its crash list is quoted from its loctable (`plutil -extract fr xml1` on
/// `/System/Applications/Utilities/Console.app/Contents/Resources/Localizable.loctable`), like a pane's.
public struct HealthPageStrings {
    private let language: Language
    init(_ language: Language) { self.language = language }

    // MARK: The two tables

    public var healthTitle: String {
        switch language {
        case .en: "Health"
        case .fr: "Santé"
        }
    }

    public var informationTitle: String {
        switch language {
        case .en: "Information"
        case .fr: "Informations"
        }
    }

    public var checkAgainButton: String {
        switch language {
        case .en: "Check Again"
        case .fr: "Vérifier à nouveau"
        }
    }

    // MARK: Claude Code

    public var hookCommandFix: String {
        switch language {
        case .en: "The hooks run a copy of MySidepulse that is not there any more. On the System page, "
            + "remove the hooks and set them up again."
        case .fr: "Les hooks lancent une copie de MySidepulse qui n'existe plus. Sur la page Système, "
            + "retirez les hooks puis réinstallez-les."
        }
    }

    public var journalFix: String {
        switch language {
        case .en: "The hooks cannot write down what Claude does, so the strip cannot show it. Check "
            + "that your disk is not full and that ~/Library/Application Support/MySidepulse is yours."
        case .fr: "Les hooks ne peuvent pas noter ce que fait Claude, donc le ruban ne peut pas le "
            + "montrer. Vérifiez que votre disque n'est pas plein et que "
            + "~/Library/Application Support/MySidepulse vous appartient."
        }
    }

    public var lastHookEventLabel: String {
        switch language {
        case .en: "Last hook event"
        case .fr: "Dernier événement de hook"
        }
    }

    /// How long ago something happened, in the one unit that reads best.
    public func ago(seconds: Int) -> String {
        let span = amount(seconds)
        switch language {
        case .en: return "\(span) ago"
        case .fr: return "il y a \(span)"
        }
    }

    private func amount(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let day = language == .fr ? "j" : "d"
        if s < 60 { return "\(s) s" }
        if s < 3_600 { return "\(s / 60) min" }
        if s < 86_400 { return "\(s / 3_600) h" }
        return "\(s / 86_400) \(day)"
    }

    public var noneYet: String {
        switch language {
        case .en: "None yet"
        case .fr: "Aucun pour l'instant"
        }
    }

    public var claudeSessionsLabel: String {
        switch language {
        case .en: "Claude sessions"
        case .fr: "Sessions Claude"
        }
    }

    public var noSessions: String {
        switch language {
        case .en: "None"
        case .fr: "Aucune"
        }
    }

    /// What a session is doing and since when, in the user's words rather than the engine's.
    public func sessionMark(_ phase: HealthFacts.SessionPhase, ageSeconds: Int) -> String {
        "\(sessionPhase(phase)), \(ago(seconds: ageSeconds))"
    }

    private func sessionPhase(_ phase: HealthFacts.SessionPhase) -> String {
        switch (phase, language) {
        case (.idle, .en): "Idle"
        case (.idle, .fr): "Inactive"
        case (.working, .en): "Working"
        case (.working, .fr): "Travaille"
        case (.done, .en): "Finished"
        case (.done, .fr): "Terminée"
        case (.waiting(let reason), .en): reason.map { "\(needsYou): \(waitReason($0))" } ?? needsYou
        case (.waiting(let reason), .fr): reason.map { "\(needsYou) : \(waitReason($0))" } ?? needsYou
        case (.other(let word), _): word
        }
    }

    private var needsYou: String {
        switch language {
        case .en: "Needs you"
        case .fr: "A besoin de vous"
        }
    }

    private func waitReason(_ reason: WaitReason) -> String {
        switch (reason, language) {
        case (.question, .en): "a question"
        case (.question, .fr): "une question"
        case (.permission, .en): "a permission"
        case (.permission, .fr): "une permission"
        case (.plan, .en): "a plan"
        case (.plan, .fr): "un plan"
        case (.error, .en): "an error"
        case (.error, .fr): "une erreur"
        }
    }

    // MARK: Phone

    public var phoneNotificationsLabel: String {
        switch language {
        case .en: "Phone notifications"
        case .fr: "Notifications téléphone"
        }
    }

    public var phoneFix: String {
        switch language {
        case .en: "Your phone cannot be notified. Check the server address on the Notifications page."
        case .fr: "Votre téléphone ne peut pas être notifié. Vérifiez l'adresse du serveur sur la page "
            + "Notifications."
        }
    }

    // MARK: Terminal

    public var terminalCommandsLabel: String {
        switch language {
        case .en: "Terminal commands"
        case .fr: "Commandes du terminal"
        }
    }

    public var noCommands: String {
        switch language {
        case .en: "None"
        case .fr: "Aucune"
        }
    }

    public func jobMark(_ phase: HealthFacts.JobPhase, acknowledged: Bool, ageSeconds: Int) -> String {
        let seen = acknowledged ? ", \(seenWord)" : ""
        return "\(jobPhase(phase))\(seen), \(ago(seconds: ageSeconds))"
    }

    private func jobPhase(_ phase: HealthFacts.JobPhase) -> String {
        switch (phase, language) {
        case (.running, .en): "Running"
        case (.running, .fr): "En cours"
        case (.succeeded, .en): "Succeeded"
        case (.succeeded, .fr): "Réussie"
        case (.failed, .en): "Failed"
        case (.failed, .fr): "Échouée"
        case (.other(let word), _): word
        }
    }

    private var seenWord: String {
        switch language {
        case .en: "seen"
        case .fr: "vue"
        }
    }

    // MARK: Service

    public var launchAgentFix: String {
        switch language {
        case .en: "Turn it on in General, under Startup. Off, a crash leaves the strip frozen and your "
            + "phone silent until you open MySidepulse again."
        case .fr: "Activez-le dans Général, sous Démarrage. Désactivé, un plantage laisse le ruban figé "
            + "et votre téléphone silencieux jusqu'à ce que vous rouvriez MySidepulse."
        }
    }

    public var openedByHand: String {
        switch language {
        case .en: "Opened by hand"
        case .fr: "Ouvert à la main"
        }
    }

    public var commandLineLabel: String {
        switch language {
        case .en: "The mysidepulse command"
        case .fr: "La commande mysidepulse"
        }
    }

    public var commandLineFix: String {
        switch language {
        case .en: "The mysidepulse command cannot reach the app, so terminal commands do not show on "
            + "the strip. Quit MySidepulse and open it again."
        case .fr: "La commande mysidepulse ne joint pas l'app, donc les commandes du terminal ne "
            + "s'affichent pas sur le ruban. Quittez MySidepulse et rouvrez-le."
        }
    }

    public func crashesLabel(days: Int) -> String {
        switch language {
        case .en: "Crashes in the last \(days) days"
        case .fr: "Plantages ces \(days) derniers jours"
        }
    }

    public func lastCrash(_ stamp: String) -> String {
        switch language {
        case .en: "Last one \(stamp)"
        case .fr: "Le dernier le \(stamp)"
        }
    }

    public var crashesFix: String {
        switch language {
        case .en: "Console shows what happened, under “Crash Reports”."
        case .fr: "Console montre ce qui s'est passé, sous « Rapports de blocage »."
        }
    }
}

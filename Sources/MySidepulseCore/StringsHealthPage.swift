import Foundation

/// The Health page's own words: the overview, the labels of the rows no other page has, the readings, and
/// the sentences that say how to put a row right. A row that another page also shows takes that page's
/// label and warning, so one state is never named twice. The detail sentences in the tooltips come from
/// `DoctorStrings`, because the CLI prints them too.
///
/// Console's own name for its crash list is quoted from its loctable (`plutil -extract fr xml1` on
/// `/System/Applications/Utilities/Console.app/Contents/Resources/Localizable.loctable`), like a pane's.
public struct HealthPageStrings {
    private let language: Language
    init(_ language: Language) { self.language = language }

    // MARK: Overview

    public var overviewTitle: String {
        switch language {
        case .en: "Overview"
        case .fr: "Vue d'ensemble"
        }
    }

    public var everythingWorks: String {
        switch language {
        case .en: "Everything works"
        case .fr: "Tout fonctionne"
        }
    }

    public func toLookAt(_ count: Int) -> String {
        switch language {
        case .en: count == 1 ? "1 thing to look at" : "\(count) things to look at"
        case .fr: count == 1 ? "1 point à vérifier" : "\(count) points à vérifier"
        }
    }

    public func notWorking(problems count: Int) -> String {
        switch language {
        case .en: count == 1 ? "Not working: 1 problem" : "Not working: \(count) problems"
        case .fr: count == 1 ? "Ne fonctionne pas : 1 problème" : "Ne fonctionne pas : \(count) problèmes"
        }
    }

    public var checking: String {
        switch language {
        case .en: "Checking"
        case .fr: "Vérification"
        }
    }

    public var checkAgainButton: String {
        switch language {
        case .en: "Check Again"
        case .fr: "Vérifier à nouveau"
        }
    }

    // MARK: Permissions

    public var permissionsTitle: String {
        switch language {
        case .en: "Permissions"
        case .fr: "Autorisations"
        }
    }

    // MARK: Claude Code

    public var hookCommandLabel: String {
        switch language {
        case .en: "Hook command"
        case .fr: "Commande du hook"
        }
    }

    public var hookCommandFix: String {
        switch language {
        case .en: "The hooks run a copy of MySidepulse that is not there any more. On the System page, "
            + "remove the hooks and set them up again."
        case .fr: "Les hooks lancent une copie de MySidepulse qui n'existe plus. Sur la page Système, "
            + "retirez les hooks puis réinstallez-les."
        }
    }

    public var journalLabel: String {
        switch language {
        case .en: "Journal"
        case .fr: "Journal"
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

    public func sessionLabel(idPrefix: String) -> String {
        switch language {
        case .en: "Session \(idPrefix)"
        case .fr: "Session \(idPrefix)"
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

    public var unknownDirectory: String {
        switch language {
        case .en: "unknown directory"
        case .fr: "répertoire inconnu"
        }
    }

    // MARK: Strip

    public var modeLabel: String {
        switch language {
        case .en: "What the strip shows"
        case .fr: "Ce que montre le ruban"
        }
    }

    public var batteryLabel: String {
        switch language {
        case .en: "Battery"
        case .fr: "Batterie"
        }
    }

    public func batteryMark(percent: Int, plugged: Bool) -> String {
        switch language {
        case .en: "\(percent) %, \(plugged ? "plugged in" : "on battery")"
        case .fr: "\(percent) %, \(plugged ? "sur secteur" : "sur batterie")"
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

    // MARK: App

    public var appTitle: String {
        switch language {
        case .en: "App"
        case .fr: "App"
        }
    }

    public var launchAgentFix: String {
        switch language {
        case .en: "Turn it on in General, under Startup. Off, a crash leaves the strip frozen and your "
            + "phone silent until you open MySidepulse again."
        case .fr: "Activez-le dans Général, sous Démarrage. Désactivé, un plantage laisse le ruban figé "
            + "et votre téléphone silencieux jusqu'à ce que vous rouvriez MySidepulse."
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

    public var runningForLabel: String {
        switch language {
        case .en: "Running for"
        case .fr: "En marche depuis"
        }
    }

    /// How long something has run, to the minute, in the two largest units that mean anything.
    public func duration(seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        switch language {
        case .en:
            if days > 0 { return "\(days) d \(hours) h" }
            if hours > 0 { return "\(hours) h \(minutes) min" }
            return minutes > 0 ? "\(minutes) min" : "Less than a minute"
        case .fr:
            if days > 0 { return "\(days) j \(hours) h" }
            if hours > 0 { return "\(hours) h \(minutes) min" }
            return minutes > 0 ? "\(minutes) min" : "Moins d'une minute"
        }
    }

    public var memoryLabel: String {
        switch language {
        case .en: "Memory used"
        case .fr: "Mémoire utilisée"
        }
    }

    public func megabytes(_ count: Int) -> String {
        switch language {
        case .en: "\(count) MB"
        case .fr: "\(count) Mo"
        }
    }

    public func crashesLabel(days: Int) -> String {
        switch language {
        case .en: "Crashes in the last \(days) days"
        case .fr: "Plantages ces \(days) derniers jours"
        }
    }

    public var noCrashes: String {
        switch language {
        case .en: "None"
        case .fr: "Aucun"
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
        case .en: "Console shows what happened, under “Crash Reports”. Copy the report below to send it along."
        case .fr: "Console montre ce qui s'est passé, sous « Rapports de blocage ». Copiez le rapport "
            + "ci-dessous pour l'envoyer avec."
        }
    }

    public var locationLabel: String {
        switch language {
        case .en: "Installed in"
        case .fr: "Emplacement"
        }
    }

    public func locationWord(_ location: AppLocation) -> String {
        switch (location, language) {
        case (.applications, _): "Applications"
        case (.elsewhere(let folder), _): folder
        case (.diskImage, .en): "Disk image"
        case (.diskImage, .fr): "Image disque"
        case (.temporaryCopy, .en): "Temporary copy"
        case (.temporaryCopy, .fr): "Copie temporaire"
        }
    }

    public var locationFix: String {
        switch language {
        case .en: "Quit MySidepulse, drag it to the Applications folder, and open it from there. "
            + "Where it runs now, it cannot update itself."
        case .fr: "Quittez MySidepulse, glissez-le dans le dossier Applications et ouvrez-le "
            + "depuis là. Là où il tourne, il ne peut pas se mettre à jour."
        }
    }

    // MARK: Report

    public var reportTitle: String {
        switch language {
        case .en: "Report"
        case .fr: "Rapport"
        }
    }

    public var reportHint: String {
        switch language {
        case .en: "Copies everything on this page as text. The notification topic stays masked, so it "
            + "is safe to paste anywhere."
        case .fr: "Copie tout le contenu de cette page sous forme de texte. Le sujet de notification "
            + "reste masqué, donc sûr à coller n'importe où."
        }
    }

    public var copyReportButton: String {
        switch language {
        case .en: "Copy Report"
        case .fr: "Copier le rapport"
        }
    }
}

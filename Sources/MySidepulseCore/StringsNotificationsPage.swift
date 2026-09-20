import Foundation

/// The Notifications page: Phone, Server, Topic, Test.
///
/// The quotes around the example push body follow each language's own
/// convention: curly doubles in English, guillemets with their spaces in
/// French.
public struct NotificationsPageStrings {
    private let language: Language
    init(_ language: Language) { self.language = language }

    public var phoneTitle: String {
        switch language {
        case .en: "Phone"
        case .fr: "Téléphone"
        }
    }

    public var phoneHint: String {
        switch language {
        case .en: "When Claude finishes or needs you while you are away from the "
            + "Mac, your phone gets a notification through ntfy. It carries a fixed "
            + "label like \u{201c}Finished\u{201d} and a claude.ai link, never a "
            + "prompt, a path or code."
        case .fr: "Quand Claude termine ou a besoin de vous pendant que vous êtes "
            + "loin du Mac, votre téléphone reçoit une notification via ntfy. Elle "
            + "porte une étiquette fixe comme \u{ab} Terminé \u{bb} et un lien "
            + "claude.ai, jamais une invite, un chemin ou du code."
        }
    }

    public var phoneNote: String {
        switch language {
        case .en: "You need the ntfy app on your phone, subscribed to the topic "
            + "shown below once this is on."
        case .fr: "Il vous faut l'app ntfy sur votre téléphone, abonnée au sujet "
            + "indiqué ci-dessous une fois ceci activé."
        }
    }

    public var notifyToggle: String {
        switch language {
        case .en: "Notify my phone when Claude finishes or needs you"
        case .fr: "Notifier mon téléphone quand Claude termine ou a besoin de moi"
        }
    }

    public var serverTitle: String {
        switch language {
        case .en: "Server"
        case .fr: "Serveur"
        }
    }

    public var serverHint: String {
        switch language {
        case .en: "Leave it empty for ntfy.sh. Point it at your own ntfy server to "
            + "keep the notifications entirely yours. Press Return to apply."
        case .fr: "Laissez vide pour ntfy.sh. Indiquez votre propre serveur ntfy "
            + "pour garder les notifications entièrement privées. Appuyez sur "
            + "Retour pour valider."
        }
    }

    public var serverAddressWarning: String {
        switch language {
        case .en: "This address cannot be posted to. Check it."
        case .fr: "Impossible d'envoyer à cette adresse. Vérifiez-la."
        }
    }

    public var serverLabel: String {
        switch language {
        case .en: "Server"
        case .fr: "Serveur"
        }
    }

    public var topicTitle: String {
        switch language {
        case .en: "Topic"
        case .fr: "Sujet"
        }
    }

    public var topicHint: String {
        switch language {
        case .en: "The topic works like a password: anyone who has it can read "
            + "your notifications. Your phone must be subscribed to the exact "
            + "current topic."
        case .fr: "Le sujet fonctionne comme un mot de passe : quiconque le "
            + "connaît peut lire vos notifications. Votre téléphone doit être "
            + "abonné exactement au sujet actuel."
        }
    }

    public var topicUnsubscribedWarning: String {
        switch language {
        case .en: "Your phone is not subscribed to the new topic yet. Reveal it and "
            + "scan the code again."
        case .fr: "Votre téléphone n'est pas encore abonné au nouveau sujet. "
            + "Affichez-le et scannez de nouveau le code."
        }
    }

    public var topicScanNote: String {
        switch language {
        case .en: "Scan the code from the ntfy app or your phone camera to "
            + "subscribe. Whoever scans it can read your notifications."
        case .fr: "Scannez le code avec l'app ntfy ou l'appareil photo de votre "
            + "téléphone pour vous abonner. Quiconque le scanne peut lire vos "
            + "notifications."
        }
    }

    public var topicLabel: String {
        switch language {
        case .en: "Topic"
        case .fr: "Sujet"
        }
    }

    public var copyTopicButton: String {
        switch language {
        case .en: "Copy Topic"
        case .fr: "Copier le sujet"
        }
    }

    public var copyLinkButton: String {
        switch language {
        case .en: "Copy Link"
        case .fr: "Copier le lien"
        }
    }

    public var hideButton: String {
        switch language {
        case .en: "Hide"
        case .fr: "Masquer"
        }
    }

    public var revealButton: String {
        switch language {
        case .en: "Reveal Topic and QR Code"
        case .fr: "Afficher le sujet et le code QR"
        }
    }

    public var newTopicButton: String {
        switch language {
        case .en: "New Topic…"
        case .fr: "Nouveau sujet…"
        }
    }

    public var testTitle: String {
        switch language {
        case .en: "Test"
        case .fr: "Test"
        }
    }

    public var testHint: String {
        switch language {
        case .en: "Sends one notification to your phone right now, whether you are "
            + "at the Mac or not."
        case .fr: "Envoie immédiatement une notification à votre téléphone, que "
            + "vous soyez au Mac ou non."
        }
    }

    public var testNotificationLabel: String {
        switch language {
        case .en: "Test notification"
        case .fr: "Notification de test"
        }
    }

    public var sendTestButton: String {
        switch language {
        case .en: "Send a Test Notification"
        case .fr: "Envoyer une notification de test"
        }
    }

    public var testSent: String {
        switch language {
        case .en: "Sent"
        case .fr: "Envoyée"
        }
    }

    public func testCouldNotSend(_ reason: String) -> String {
        switch language {
        case .en: "Could not send: \(reason)"
        case .fr: "Envoi impossible : \(reason)"
        }
    }

    public var mintDialogTitle: String {
        switch language {
        case .en: "Mint a new topic?"
        case .fr: "Créer un nouveau sujet ?"
        }
    }

    public var mintDialogButton: String {
        switch language {
        case .en: "New Topic"
        case .fr: "Nouveau sujet"
        }
    }

    public var mintDialogMessage: String {
        switch language {
        case .en: "Your phone stops receiving notifications until you subscribe it "
            + "to the new topic."
        case .fr: "Votre téléphone cesse de recevoir des notifications tant que "
            + "vous ne l'abonnez pas au nouveau sujet."
        }
    }

    public var appDidNotAnswer: String {
        switch language {
        case .en: "the app did not answer"
        case .fr: "l'app n'a pas répondu"
        }
    }
}

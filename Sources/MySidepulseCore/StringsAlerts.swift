import Foundation

/// The phone notification bodies, the only strings that leave the machine.
/// `AlertCopy.title` is the product name and `AlertCopy.tag` is the wire
/// protocol's tag name: neither is prose and neither is translated.
/// `NotifyTests` pins both languages.
public struct AlertStrings {
    private let language: Language
    init(_ language: Language) { self.language = language }

    public var finished: String {
        switch language {
        case .en: "Finished"
        case .fr: "Terminé"
        }
    }

    public var question: String {
        switch language {
        case .en: "Asking you something"
        case .fr: "Vous pose une question"
        }
    }

    public var permission: String {
        switch language {
        case .en: "Needs permission"
        case .fr: "Demande une permission"
        }
    }

    public var plan: String {
        switch language {
        case .en: "Plan ready"
        case .fr: "Plan prêt"
        }
    }

    public var error: String {
        switch language {
        case .en: "Turn failed"
        case .fr: "Échec du tour"
        }
    }
}

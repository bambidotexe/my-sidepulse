import Foundation

/// Why a check or an update did not work. The reasons reach the user as
/// `Could not check: <reason>` in the General page's version row, and as
/// `Update failed: <reason>` there and in the update window.
public struct UpdateStrings {
    private let language: Language
    init(_ language: Language) { self.language = language }

    public func httpStatus(_ code: Int) -> String {
        switch language {
        case .en: "GitHub answered with status \(code)."
        case .fr: "GitHub a répondu avec le statut \(code)."
        }
    }

    public var malformedResponse: String {
        switch language {
        case .en: "The release information could not be read."
        case .fr: "Les informations de version n'ont pas pu être lues."
        }
    }

    public var damagedDownload: String {
        switch language {
        case .en: "The download is damaged."
        case .fr: "Le téléchargement est endommagé."
        }
    }

    public var cannotOpenImage: String {
        switch language {
        case .en: "The disk image could not be opened."
        case .fr: "L'image disque n'a pas pu être ouverte."
        }
    }

    public var appMissing: String {
        switch language {
        case .en: "The disk image does not contain MySidepulse."
        case .fr: "L'image disque ne contient pas MySidepulse."
        }
    }

    public var notNewer: String {
        switch language {
        case .en: "The disk image does not hold a newer version."
        case .fr: "L'image disque ne contient pas de version plus récente."
        }
    }

    public func needsNewerSystem(_ version: String) -> String {
        switch language {
        case .en: "This version needs macOS \(version) or later."
        case .fr: "Cette version nécessite macOS \(version) ou une version ultérieure."
        }
    }

    public var differentSigner: String {
        switch language {
        case .en: "The update is not signed by the same developer."
        case .fr: "La mise à jour n'est pas signée par le même développeur."
        }
    }

    public var invalidSignature: String {
        switch language {
        case .en: "The update's signature is not valid."
        case .fr: "La signature de la mise à jour n'est pas valide."
        }
    }

    public var couldNotReplace: String {
        switch language {
        case .en: "The new version could not be put in place."
        case .fr: "La nouvelle version n'a pas pu être mise en place."
        }
    }

    public var didNotStart: String {
        switch language {
        case .en: "The new version did not start, so the previous one was put back."
        case .fr: "La nouvelle version n'a pas démarré, la précédente a donc été remise en place."
        }
    }

    public var stranded: String {
        switch language {
        case .en: "The new version did not start and the previous one could not be put back. "
            + "Download MySidepulse again."
        case .fr: "La nouvelle version n'a pas démarré et la précédente n'a pas pu être remise en "
            + "place. Téléchargez à nouveau MySidepulse."
        }
    }
}

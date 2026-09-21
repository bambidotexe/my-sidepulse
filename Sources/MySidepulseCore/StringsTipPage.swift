import Foundation

/// The Tip page: what the app costs, and the one way to say thank you.
public struct TipPageStrings {
    private let language: Language
    init(_ language: Language) { self.language = language }

    /// The sentence beside the app icon, at the top of the page.
    public var intro: String {
        switch language {
        case .en: "MySidepulse offers all its features free to everyone, and always will. "
            + "You can support this project by offering me a coffee."
        case .fr: "MySidepulse offre toutes ses fonctionnalités gratuitement à tout le monde, "
            + "et ce sera toujours le cas. Vous pouvez soutenir ce projet en m'offrant un café."
        }
    }

    public var offerTitle: String {
        switch language {
        case .en: "One-time tip"
        case .fr: "Don ponctuel"
        }
    }

    /// The offer's own name, beside the Ko-fi cup.
    public var offerName: String {
        switch language {
        case .en: "A cup of coffee"
        case .fr: "Une tasse de café"
        }
    }

    public var offerDescription: String {
        switch language {
        case .en: "A good coffee to keep this project going"
        case .fr: "Un bon café pour faire avancer ce projet"
        }
    }

    /// The amount is the smallest tip the page takes, so it is read from the constant that owns it.
    public func offerHint(_ amount: Int) -> String {
        switch language {
        case .en: "Ko-fi opens in your browser. €\(amount) is the smallest tip, and you can type any "
            + "amount there."
        case .fr: "Ko-fi s'ouvre dans votre navigateur. \(amount) € est le plus petit don, et vous "
            + "pouvez y saisir le montant que vous voulez."
        }
    }

    public func tipButton(_ amount: Int) -> String {
        switch language {
        case .en: "Tip €\(amount)"
        case .fr: "Offrir \(amount) €"
        }
    }
}

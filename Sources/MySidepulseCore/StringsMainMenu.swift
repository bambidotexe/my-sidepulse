import Foundation

/// The main menu bar the app puts up while the settings window is open. An
/// `LSUIElement` app gets no menu for free, so these standard titles are ours
/// to write, and to translate, rather than macOS's.
///
/// `Settings…` and `Quit MySidepulse` are not here: they read the same in both
/// menus, so they come from `MenuStrings`.
public struct MainMenuStrings {
    private let language: Language
    init(_ language: Language) { self.language = language }

    public var about: String {
        switch language {
        case .en: "About MySidepulse"
        case .fr: "À propos de MySidepulse"
        }
    }

    public var edit: String {
        switch language {
        case .en: "Edit"
        case .fr: "Édition"
        }
    }

    public var undo: String {
        switch language {
        case .en: "Undo"
        case .fr: "Annuler"
        }
    }

    public var redo: String {
        switch language {
        case .en: "Redo"
        case .fr: "Rétablir"
        }
    }

    public var cut: String {
        switch language {
        case .en: "Cut"
        case .fr: "Couper"
        }
    }

    public var copy: String {
        switch language {
        case .en: "Copy"
        case .fr: "Copier"
        }
    }

    public var paste: String {
        switch language {
        case .en: "Paste"
        case .fr: "Coller"
        }
    }

    public var selectAll: String {
        switch language {
        case .en: "Select All"
        case .fr: "Tout sélectionner"
        }
    }

    public var window: String {
        switch language {
        case .en: "Window"
        case .fr: "Fenêtre"
        }
    }

    public var close: String {
        switch language {
        case .en: "Close"
        case .fr: "Fermer"
        }
    }

    /// macOS's own French for this one is not "Réduire".
    public var minimize: String {
        switch language {
        case .en: "Minimize"
        case .fr: "Placer dans le Dock"
        }
    }
}

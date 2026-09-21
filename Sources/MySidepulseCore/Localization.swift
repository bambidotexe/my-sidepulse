import Foundation

/// The languages MySidepulse speaks. English is the fallback: every language
/// that is not French is shown in English.
///
/// Adding a case here is a compile error in every string table until each one
/// answers for the new language, which is the point: no string can exist in one
/// language only.
public enum Language: String, CaseIterable, Sendable {
    case en, fr

    /// The rule that turns the system's preferred language into one of ours.
    /// The tag is BCP-47, so the primary subtag is what decides: `fr`, `fr-FR`
    /// and `fr-CA` are French, `fry` (Frisian) is not.
    ///
    /// The tag is passed in. Core never asks the system anything, so this rule
    /// is testable without a system to ask.
    public init(preferredLanguage tag: String?) {
        let primary = tag?.split(whereSeparator: { $0 == "-" || $0 == "_" }).first?.lowercased()
        self = primary == "fr" ? .fr : .en
    }

    /// "LED" is a product name, never translated, and takes the same s-plural
    /// in both languages. The noun alone, for a sentence that puts a count
    /// somewhere else.
    public func ledsNoun(_ count: Int) -> String { count == 1 ? "LED" : "LEDs" }

    /// A count and its noun: `1 LED`, `8 LEDs`.
    public func leds(_ count: Int) -> String { "\(count) \(ledsNoun(count))" }
}

/// The one language every string table reads.
///
/// `MySidepulseApp` sets it once at launch, before it builds a window, a menu
/// or a status item. `MySidepulseCLI` never sets it, which is the whole of why
/// the command line stays English: `Doctor` and `HookInstaller` serve both, and
/// reading the language at the moment a sentence is produced is what gives each
/// caller its own.
///
/// Locked because those readers are not on one queue: the settings window reads
/// from the main queue while the notifier writes a push from its own.
public enum Loc {
    private static let lock = NSLock()
    private static var current: Language = .en

    public static var language: Language {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    public static var menu: MenuStrings { MenuStrings(language) }
    public static var mainMenu: MainMenuStrings { MainMenuStrings(language) }
    public static var status: StatusStrings { StatusStrings(language) }
    public static var alerts: AlertStrings { AlertStrings(language) }
    public static var settings: SettingsStrings { SettingsStrings(language) }
    public static var onboarding: OnboardingStrings { OnboardingStrings(language) }
    public static var doctor: DoctorStrings { DoctorStrings(language) }
    public static var hookInstall: HookInstallStrings { HookInstallStrings(language) }
    public static var update: UpdateStrings { UpdateStrings(language) }
    public static var updateWindow: UpdateWindowStrings { UpdateWindowStrings(language) }
}

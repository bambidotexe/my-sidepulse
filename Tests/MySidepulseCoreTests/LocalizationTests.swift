import XCTest
@testable import MySidepulseCore

/// Runs `body` with the ambient language set, and puts it back whatever
/// happens: the tables read a process-wide switch, so a test that left it set
/// would change what every later test sees.
func withLanguage(_ language: Language, _ body: () throws -> Void) rethrows {
    let saved = Loc.language
    defer { Loc.language = saved }
    Loc.language = language
    try body()
}

/// The same, for a body that answers something.
func withLanguageReturning<T>(_ language: Language, _ body: () throws -> T) rethrows -> T {
    let saved = Loc.language
    defer { Loc.language = saved }
    Loc.language = language
    return try body()
}

final class LocalizationTests: XCTestCase {
    // MARK: what the system language resolves to

    func testFrenchInAnyRegionIsFrench() {
        for tag in ["fr", "fr-FR", "fr-CA", "fr-BE", "FR", "fr_FR"] {
            XCTAssertEqual(Language(preferredLanguage: tag), .fr, tag)
        }
    }

    /// English is the fallback, and it is the fallback for everything: a
    /// language we do not speak is never a half-translated window.
    func testEverythingElseIsEnglish() {
        for tag in ["en", "en-GB", "en-US", "de", "de-DE", "it", "es-419", "pt-BR", "ja", ""] {
            XCTAssertEqual(Language(preferredLanguage: tag), .en, tag)
        }
        XCTAssertEqual(Language(preferredLanguage: nil), .en)
    }

    /// `fry` is Frisian. Matching on a prefix rather than the primary subtag
    /// would have shown it a French window.
    func testALanguageThatMerelyStartsWithFrIsNotFrench() {
        for tag in ["fry", "fry-NL", "frr", "frc"] {
            XCTAssertEqual(Language(preferredLanguage: tag), .en, tag)
        }
    }

    func testTheDefaultIsEnglishSoTheCLINeverNeedsToAsk() {
        XCTAssertEqual(Loc.language, .en)
    }

    // MARK: the words themselves

    func testTheThreeClaudeStatesAreTranslated() {
        withLanguage(.fr) {
            XCTAssertEqual(StatusCopy.line(for: .working).text, "Claude travaille")
            XCTAssertEqual(StatusCopy.line(for: .waiting).text,
                           "Claude a besoin de vous : une question, une permission ou un plan")
            XCTAssertEqual(StatusCopy.line(for: .done).text,
                           "Claude a terminé. S'efface quand vous regardez le terminal")
        }
    }

    func testThePushBodiesAreTranslated() {
        withLanguage(.fr) {
            XCTAssertEqual(AlertCopy.message(for: .finished), "Terminé")
            XCTAssertEqual(AlertCopy.message(for: .needsYou(.question)), "Vous pose une question")
            XCTAssertEqual(AlertCopy.message(for: .needsYou(.permission)), "Demande une permission")
            XCTAssertEqual(AlertCopy.message(for: .needsYou(.plan)), "Plan prêt")
            XCTAssertEqual(AlertCopy.message(for: .needsYou(.error)), "Échec du tour")
        }
    }

    /// The title is the product's name and the tag is a wire value. A push whose
    /// tag was translated would lose its icon on the phone.
    func testTheTitleAndTheTagsAreNotTranslated() {
        withLanguage(.fr) {
            XCTAssertEqual(AlertCopy.title, "Claude Code")
            XCTAssertEqual(AlertCopy.tag(for: .finished), "white_check_mark")
            XCTAssertEqual(AlertCopy.tag(for: .needsYou(.question)), "speech_balloon")
            XCTAssertEqual(AlertCopy.tag(for: .needsYou(.permission)), "lock")
            XCTAssertEqual(AlertCopy.tag(for: .needsYou(.plan)), "clipboard")
            XCTAssertEqual(AlertCopy.tag(for: .needsYou(.error)), "rotating_light")
        }
    }

    /// The vocabulary a status mark draws from, which must not drift into
    /// synonyms: the same state gets the same word on every page.
    func testTheStatusWordsAreOneWordEach() {
        for language in Language.allCases {
            withLanguage(language) {
                let words = Loc.settings.words
                for word in [words.available, words.missing, words.stalled, words.enabled,
                             words.disabled, words.valid, words.invalid, words.failed] {
                    XCTAssertFalse(word.isEmpty)
                    XCTAssertFalse(word.contains(" "), "\(language): \(word) is more than a word")
                    XCTAssertFalse(word.hasSuffix("."), "\(language): \(word)")
                }
            }
        }
    }

    /// LED is a product name in both languages, and the count agrees with it.
    func testLedCountsAgree() {
        for language in Language.allCases {
            XCTAssertEqual(language.leds(1), "1 LED")
            XCTAssertEqual(language.leds(0), "0 LEDs")
            XCTAssertEqual(language.leds(8), "8 LEDs")
        }
    }

    /// A warning that names a button has to name it as the button reads, or it
    /// sends the user looking for an English button in a French window.
    func testAWarningThatNamesAButtonNamesTheButtonInTheSameLanguage() {
        for language in Language.allCases {
            withLanguage(language) {
                let system = Loc.settings.system
                XCTAssertTrue(system.withoutHooksWarning.contains(system.setUpHooksButton),
                              "\(language): \(system.withoutHooksWarning)")
            }
        }
    }

    /// Every sentence in the window, in both languages, read out of the source
    /// rather than listed here: a string added to a table without its rule
    /// checked is exactly what this is for.
    ///
    /// The rule is the window's: no long dash anywhere the user reads. The
    /// doctor's details are covered again by `DoctorTests`, which runs the real
    /// checks.
    func testNoStringTableCarriesALongDash() throws {
        let longDashes: Set<Character> = ["—", "–", "‒", "―", "‐", "‑", "−"]
        let files = try Self.stringTableSources()
        XCTAssertFalse(files.isEmpty, "no string tables found — wrong path?")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() {
                // Comments are for whoever reads the code, not the user.
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), !code.hasPrefix("///") else { continue }
                for literal in Self.stringLiterals(in: String(line)) {
                    XCTAssertFalse(literal.contains { longDashes.contains($0) },
                                   "\(file.lastPathComponent):\(number + 1): \(literal)")
                }
            }
        }
    }

    /// Every table answers for every language, or it does not compile: each
    /// accessor switches over `Language` exhaustively. This guards the shape
    /// that makes that true, so a table cannot quietly go back to defaulting.
    func testNoTableDefaultsInsteadOfAnsweringForEachLanguage() throws {
        for file in try Self.stringTableSources() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.split(separator: "\n").enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                XCTAssertFalse(code.hasPrefix("default:"),
                               "\(file.lastPathComponent):\(number + 1): a string table may not "
                                   + "default; every language answers for itself")
            }
        }
    }

    // MARK: reading the tables off disk

    private static func stringTableSources() throws -> [URL] {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let coreDir = repoRoot.appendingPathComponent("Sources/MySidepulseCore")
        return try FileManager.default.contentsOfDirectory(at: coreDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("Strings") && $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Good enough for these files: they hold no escaped quote outside an
    /// interpolation, and interpolations carry no quote of their own.
    private static func stringLiterals(in line: String) -> [String] {
        var literals: [String] = []
        var current: String?
        for character in line {
            guard character == "\"" else {
                if current != nil { current?.append(character) }
                continue
            }
            if let finished = current {
                literals.append(finished)
                current = nil
            } else {
                current = ""
            }
        }
        return literals
    }
}

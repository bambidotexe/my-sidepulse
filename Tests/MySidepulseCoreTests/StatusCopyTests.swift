import XCTest
@testable import MySidepulseCore

/// The "Showing" sentence is window copy that no compiler checks, so every
/// state's line is pinned here.
final class StatusCopyTests: XCTestCase {
    static let everyState: [DisplayState] = [
        .off, .working, .waiting, .done, .jobRunning, .jobFailed, .jobSucceeded,
        .split(alert: .waiting, work: .working), .split(alert: .jobFailed, work: .working),
        .split(alert: .done, work: .jobRunning), .split(alert: .jobSucceeded, work: .jobRunning),
        .batteryCritical, .batteryGlance, .manualColor("#ff9900"), .effect("rainbow"),
    ]

    /// The window's rule for every sentence it shows: no long dash, and a mark's
    /// sentence ends without a full stop.
    func testEverySentenceObeysTheWindowsRules() {
        let longDashes: Set<Character> = ["—", "–", "‒", "―", "‐", "‑", "−"]
        for language in Language.allCases {
            withLanguage(language) {
                for state in Self.everyState {
                    let text = StatusCopy.line(for: state).text
                    XCTAssertFalse(text.isEmpty, "\(language) \(state) has no sentence")
                    XCTAssertFalse(text.contains { longDashes.contains($0) },
                                   "\(language) \(state): \(text)")
                    XCTAssertFalse(text.hasSuffix("."), "\(language) \(state): \(text)")
                }
            }
        }
    }

    /// The tone is the state's, not the language's: a translation that changed
    /// one would change which mark the window draws.
    func testToneDoesNotDependOnTheLanguage() {
        for state in Self.everyState {
            let english = withLanguageReturning(.en) { StatusCopy.line(for: state).tone }
            let french = withLanguageReturning(.fr) { StatusCopy.line(for: state).tone }
            XCTAssertEqual(english, french, "\(state)")
        }
    }

    func testTheThreeClaudeStatesReadAsWritten() {
        XCTAssertEqual(StatusCopy.line(for: .working),
                       StatusCopy.Line(tone: .info, text: "Claude is working"))
        XCTAssertEqual(StatusCopy.line(for: .waiting),
                       StatusCopy.Line(tone: .warning,
                                       text: "Claude needs you: a question, a permission or a plan"))
        XCTAssertEqual(StatusCopy.line(for: .done),
                       StatusCopy.Line(tone: .good,
                                       text: "Claude has finished. Clears when you look at the terminal"))
    }

    /// A split's second clause is the same promise in both languages.
    func testASplitSaysWorkGoesOnInFrenchToo() {
        withLanguage(.fr) {
            for alert in [SplitAlert.waiting, .jobFailed, .done, .jobSucceeded] {
                XCTAssertTrue(StatusCopy.line(for: .split(alert: alert, work: .working)).text
                    .hasSuffix("et d'autres tâches sont en cours"))
            }
        }
    }

    /// A split takes the alert's tone and says that work goes on behind it,
    /// whichever kind of work that is.
    func testASplitIsTheAlertPlusTheWorkBehindIt() {
        for work in [SplitWork.working, .jobRunning] {
            XCTAssertEqual(StatusCopy.line(for: .split(alert: .waiting, work: work)).tone, .warning)
            XCTAssertEqual(StatusCopy.line(for: .split(alert: .jobFailed, work: work)).tone, .failure)
            XCTAssertEqual(StatusCopy.line(for: .split(alert: .done, work: work)).tone, .good)
            for alert in [SplitAlert.waiting, .jobFailed, .done, .jobSucceeded] {
                XCTAssertTrue(StatusCopy.line(for: .split(alert: alert, work: work)).text
                    .hasSuffix("and other work is still running"))
            }
        }
    }

    func testAForcedModeNamesItselfAndTheWayBack() {
        XCTAssertEqual(StatusCopy.line(for: .manualColor("#ff9900")).text,
                       "Forced to #ff9900 until set back to Auto")
        XCTAssertEqual(StatusCopy.line(for: .effect("rainbow")).text,
                       "Playing rainbow until set back to Auto")
    }
}

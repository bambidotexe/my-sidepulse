import XCTest
@testable import MySidepulseCore

/// Replays a REAL journal file through the store, ticking at every scheduled
/// deadline exactly as the Engine would, with the user treated as always
/// absent — the worst case, where every armed alert becomes a push. Prints
/// the full push list and per-kind counts for eyeballing against the app's
/// own `notifying:` log lines.
///
/// Off unless pointed at a journal:
///     MYSIDEPULSE_REPLAY_JOURNAL=/path/to/journal.jsonl swift test \
///         --filter RealJournalReplayTests
/// The journal is private (message tails, cwds); this test never ships one
/// and never asserts on its contents — only on invariants that must hold for
/// ANY journal.
final class RealJournalReplayTests: XCTestCase {
    func testReplayRealJournal() throws {
        guard let path = ProcessInfo.processInfo.environment["MYSIDEPULSE_REPLAY_JOURNAL"] else {
            throw XCTSkip("set MYSIDEPULSE_REPLAY_JOURNAL to a journal.jsonl to run")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let events = data.split(separator: 0x0A).compactMap { JournalCodec.decodeLine(Data($0)) }
        XCTAssertFalse(events.isEmpty, "no decodable events in \(path)")

        var store = SessionStore()
        var fired: [Alert] = []
        var askUserQuestionSessions = Set<String>()
        var stopFailureSessions = Set<String>()
        // A monotone clock cursor, because nextDeadline(after:) may name
        // deadlines relative to `after` (the abandon-sampling cadence).
        var clock = events.first?.loggedAt ?? Date()
        for event in events {
            // Drain every deadline that falls before this event, like Engine.
            while let d = store.nextDeadline(after: clock), d <= event.loggedAt {
                clock = d
                fired += store.tick(now: d, userPresent: false)
            }
            clock = max(clock, event.loggedAt)
            if event.event == .preToolUse, event.toolName == "AskUserQuestion",
               let sid = event.sessionId { askUserQuestionSessions.insert(sid) }
            if event.event == .stopFailure, let sid = event.sessionId {
                stopFailureSessions.insert(sid)
            }
            store.apply(event)
        }
        let horizon = clock.addingTimeInterval(K.notifyDebounceSeconds + 1)
        while let d = store.nextDeadline(after: clock), d <= horizon {
            clock = d
            fired += store.tick(now: d, userPresent: false)
        }

        var counts: [String: Int] = [:]
        print("=== \(fired.count) pushes from \(events.count) events ===")
        for alert in fired {
            let label = AlertCopy.message(for: alert.kind)
            counts[label, default: 0] += 1
            print("  \(alert.at)  \(alert.sessionId.prefix(8))  \(label)")
        }
        print("=== per-kind ===")
        for (label, n) in counts.sorted(by: { $0.value > $1.value }) { print("  \(n)  \(label)") }

        // Invariants that hold for any journal: amber only ever comes from
        // the strong signals, so a push about a question needs an
        // AskUserQuestion, and a turn-failure push needs a StopFailure.
        // There is no "waiting for you" case to assert on.
        for alert in fired {
            switch alert.kind {
            case .needsYou(.question):
                XCTAssertTrue(askUserQuestionSessions.contains(alert.sessionId),
                              "question push without an AskUserQuestion: \(alert)")
            case .needsYou(.error):
                XCTAssertTrue(stopFailureSessions.contains(alert.sessionId),
                              "error push without a StopFailure: \(alert)")
            case .finished, .needsYou(.permission), .needsYou(.plan):
                break
            }
        }
    }
}

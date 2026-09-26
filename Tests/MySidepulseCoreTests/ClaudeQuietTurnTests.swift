import XCTest
import MySidepulseCore

/// A quiet Claude Code turn, decided from its registry record: the record
/// alone says whether the turn is over, the transcript only how it ended.
final class ClaudeQuietTurnTests: XCTestCase {
    let lastMain = at(10)

    /// How many times the transcript was read.
    var reads = 0

    func decide(_ status: String?, _ stamp: Date?, ending: ClaudeQuietTurn.Ending = .unreadable)
    -> ClaudeQuietTurn.Decision {
        ClaudeQuietTurn.decision(status: status, statusUpdatedAt: stamp, lastMainEventAt: lastMain) {
            reads += 1
            return ending
        }
    }

    /// `idle` stamped after the last main-agent event ends the turn at once,
    /// dated to the stamp: a completed answer is the lost `Stop`, an
    /// unanswered entry is the interrupt.
    func testAnIdleRecordAfterOurLastEventEndsTheTurnAtOnce() {
        XCTAssertEqual(decide("idle", at(15), ending: .finished), .finished(endedAt: at(15)))
        XCTAssertEqual(decide("idle", at(15), ending: .incomplete), .abandoned(endedAt: at(15)))
    }

    /// A transcript that cannot say how the turn ended does not hold the
    /// turn open: the registry has said it is over, and it goes dark now.
    func testAnUnreadableTranscriptGoesDarkAtOnce() {
        XCTAssertEqual(decide("idle", at(15), ending: .unreadable), .abandoned(endedAt: at(15)))
    }

    /// An `idle` stamped at or before our last event is the previous turn's
    /// rest; a record with no stamp, or a status the vocabulary does not
    /// know, decides nothing; `busy` is liveness. The transcript is read
    /// only when the turn is over.
    func testOnlyAFreshIdleEndsTheTurnAndOnlyThenIsTheTranscriptRead() {
        XCTAssertEqual(decide("idle", lastMain, ending: .finished), .nothing)
        XCTAssertEqual(decide("idle", at(5), ending: .finished), .nothing)
        XCTAssertEqual(decide("idle", nil, ending: .finished), .nothing)
        XCTAssertEqual(decide("busy", at(15), ending: .finished), .busy)
        XCTAssertEqual(decide("Idle", at(15), ending: .finished), .nothing, "the vocabulary is exact")
        XCTAssertEqual(decide(nil, at(15), ending: .finished), .nothing)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(decide("idle", at(15), ending: .finished), .finished(endedAt: at(15)))
        XCTAssertEqual(reads, 1)
    }
}

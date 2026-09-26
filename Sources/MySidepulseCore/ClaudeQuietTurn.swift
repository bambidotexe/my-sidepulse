import Foundation

/// What a quiet Claude Code turn's registry record means: Claude Code's own
/// `<config>/sessions/<pid>.json` (the app reads it), whose `status` is
/// `busy` while a turn runs and `idle` at the input prompt, with the stamp of
/// its last change. The record alone says whether the turn is over; the
/// transcript's tail only says how it ended, and is read only then.
public enum ClaudeQuietTurn {
    /// How the transcript's tail says the turn ended: a completed assistant
    /// answer, an unanswered entry, or nothing that can be read.
    public enum Ending: Equatable { case finished, incomplete, unreadable }

    /// What the store does with the record.
    public enum Decision: Equatable {
        /// The lost `Stop`: `finishTurn`, with the push a `Stop` earns.
        case finished(endedAt: Date)
        /// The interrupt, or an ending no transcript can tell: `abandonTurn`,
        /// dark, no push.
        case abandoned(endedAt: Date)
        /// The turn runs: `noteBusy`.
        case busy
        case nothing
    }

    /// `idle` stamped after the last main-agent event ends the turn at once,
    /// dated to the stamp: a completed answer in the transcript is a finish,
    /// anything else, an unreadable transcript included, is dark. `busy` is
    /// liveness. An `idle` stamped at or before the last main-agent event is
    /// the rest before this turn, and a record with no stamp or a status the
    /// vocabulary does not know decides nothing. `ending` reads the
    /// transcript, and is called only when the turn is over.
    public static func decision(status: String?, statusUpdatedAt: Date?, lastMainEventAt: Date,
                                ending: () -> Ending) -> Decision {
        switch status {
        case "idle":
            guard let stamped = statusUpdatedAt, stamped > lastMainEventAt else { return .nothing }
            return ending() == .finished ? .finished(endedAt: stamped) : .abandoned(endedAt: stamped)
        case "busy":
            return .busy
        default:
            return .nothing
        }
    }
}

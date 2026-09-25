import Foundation

/// What the strip is showing and why, in the user's words: the sentence the
/// settings window puts on its "Showing" row and reads out for the strip
/// replica. A text no compiler checks, so `StatusCopyTests` pins it the way
/// `NotifyTests` pins the push copy: in every language, each sentence is
/// short, names the agent or the command rather than a colour, carries no
/// long dash and ends without a full stop. The words live in `StatusStrings`;
/// what this owns is which sentence a state gets and what tone it carries.
public enum StatusCopy {
    /// Which of the window's marks the sentence takes. `info` is news that
    /// asks nothing of the user, `good` a finish, `warning` a request for the
    /// user, `failure` something that went wrong.
    public enum Tone: Equatable {
        case info, good, warning, failure
    }

    public struct Line: Equatable {
        public let tone: Tone
        public let text: String

        public init(tone: Tone, text: String) {
            self.tone = tone
            self.text = text
        }
    }

    public static func line(for state: DisplayState) -> Line {
        let t = Loc.status
        switch state {
        case .off:
            return Line(tone: .info, text: t.off)
        case .working(let agents):
            return Line(tone: .info, text: t.working(agents))
        case .waiting(let agents):
            return Line(tone: .warning, text: t.waiting(agents))
        case .done(let agents):
            return Line(tone: .good, text: t.done(agents))
        case .jobRunning:
            return Line(tone: .info, text: t.jobRunning)
        case .jobFailed:
            return Line(tone: .failure, text: t.jobFailed)
        case .jobSucceeded:
            return Line(tone: .good, text: t.jobSucceeded)
        case .split(let alert, _):
            // The alert is the news; the work behind it is the second clause.
            switch alert {
            case .waiting(let agents):
                return Line(tone: .warning, text: t.splitWaiting(agents))
            case .jobFailed:
                return Line(tone: .failure, text: t.splitJobFailed)
            case .done(let agents):
                return Line(tone: .good, text: t.splitDone(agents))
            case .jobSucceeded:
                return Line(tone: .good, text: t.splitJobSucceeded)
            }
        case .batteryCritical:
            return Line(tone: .failure, text: t.batteryCritical)
        case .batteryGlance:
            return Line(tone: .info, text: t.batteryGlance)
        case .manualColor(let hex):
            return Line(tone: .info, text: t.manualColor(hex))
        case .effect(let name):
            return Line(tone: .info, text: t.effect(name))
        }
    }
}

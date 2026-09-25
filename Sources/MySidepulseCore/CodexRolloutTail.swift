import Foundation

/// How a quiet Codex turn stands, read from the tail of the session's
/// rollout: the JSON-lines file Codex writes for every session
/// (`<codexHome>/sessions/YYYY/MM/DD/rollout-<stamp>-<session id>.jsonl`),
/// whose path every Codex hook names as `transcript_path`.
///
/// The turn-level markers are `event_msg` lines whose `payload.type` is
/// `task_started`, `task_complete` or `turn_aborted`, each naming its turn
/// (`payload.turn_id`, the id the hooks send). They balance exactly: across
/// the 55 rollouts of 2026-09-25, 399 `task_started`, 392 `task_complete`,
/// 7 `turn_aborted`. Everything else in the file, `item_completed`,
/// `token_count` and `thread_settings_applied` included, is item-level and
/// never a marker: Codex writes a lone `item_completed` for an aborted
/// turn when the aborted tool's process ends, seconds or minutes after the
/// abort. The last marker wins.
///
/// Only the lines' `type`, `payload.type`, `payload.turn_id` and
/// `timestamp` are ever read. The rest of a line is the conversation: it
/// is never kept, returned or logged.
public enum CodexRolloutTail {
    public enum Verdict: Equatable {
        /// The last marker is a `task_started`: the turn runs. `writtenAt`
        /// is the stamp of the last line the tail holds, of any type: when
        /// Codex last wrote to the session.
        case running(turnId: String?, writtenAt: Date)
        case complete(at: Date, turnId: String?)
        case aborted(at: Date, turnId: String?)
        /// No marker, nothing parseable, or an end marker with no stamp.
        case unreadable
    }

    /// What the store does with a verdict. An end carries the marker's
    /// stamp: the verdict is applied as of when the turn ended, so a finish
    /// found long after it shows `done` for what is left of its time and
    /// earns no push, as a replayed `Stop` would.
    public enum Decision: Equatable {
        /// The lost `Stop`: `finishTurn`, with the push a `Stop` earns.
        case finished(endedAt: Date)
        /// The interrupt: `abandonTurn`, dark, no push.
        case aborted(endedAt: Date)
        /// The turn runs: `noteBusy`.
        case busy
        case nothing
    }

    /// How much of the rollout's end is read. Across the 55 rollouts of
    /// 2026-09-25, the last marker started at most 1 315 bytes before the
    /// end of its file (median 220), and the longest line was 57 KB: an end
    /// marker is always inside 64 KB. A turn still running can have written
    /// more than that since its `task_started` (53 of 744 gaps between
    /// markers did); its tail then holds no marker and decides nothing,
    /// which costs nothing while the turn runs.
    public static let tailBytes = 65_536
    /// What the reader takes: the window and the one byte before it, which
    /// says whether the window starts at a line (that byte is a newline) or
    /// inside one.
    public static let readBytes = tailBytes + 1

    /// A tail longer than the window holds the byte before it: everything
    /// up to its first newline is the end of a line the window cut, and is
    /// dropped. A tail no longer than the window is the whole file, first
    /// line included. A line that does not parse, the last one cut
    /// mid-write included, is no line.
    public static func verdict(tail: Data) -> Verdict {
        var body = tail[...]
        if tail.count > tailBytes {
            guard let newline = tail.firstIndex(of: 0x0A) else { return .unreadable }
            body = tail[tail.index(after: newline)...]
        }
        let lines = body.split(separator: 0x0A, omittingEmptySubsequences: true)
        var writtenAt: Date?
        for line in lines.reversed() {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
            else { continue }
            let stamp = (object["timestamp"] as? String).flatMap(JournalCodec.date(from:))
            if writtenAt == nil { writtenAt = stamp }
            guard object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  let kind = payload["type"] as? String else { continue }
            let turnId = payload["turn_id"] as? String
            switch kind {
            case "task_started":
                guard let written = writtenAt ?? stamp else { return .unreadable }
                return .running(turnId: turnId, writtenAt: written)
            case "task_complete":
                return stamp.map { .complete(at: $0, turnId: turnId) } ?? .unreadable
            case "turn_aborted":
                return stamp.map { .aborted(at: $0, turnId: turnId) } ?? .unreadable
            default:
                continue
            }
        }
        return .unreadable
    }

    /// An end marker ends the session's turn when it is stamped after the
    /// last main-agent event, or when it names the turn that event named:
    /// with the `Interrupt` hook lost, the aborted tool's late `PostToolUse`
    /// is logged after the `turn_aborted`, for the same turn. An end marker
    /// of an earlier turn stamped earlier is the previous turn's end, seen
    /// before Codex wrote the new turn's `task_started`.
    public static func decision(verdict: Verdict, lastMainEventAt: Date, lastMainTurnId: String?) -> Decision {
        func endsOurTurn(_ at: Date, _ turnId: String?) -> Bool {
            if at > lastMainEventAt { return true }
            guard let turnId, let lastMainTurnId else { return false }
            return turnId == lastMainTurnId
        }
        switch verdict {
        case .running: return .busy
        case .complete(let at, let turnId): return endsOurTurn(at, turnId) ? .finished(endedAt: at) : .nothing
        case .aborted(let at, let turnId): return endsOurTurn(at, turnId) ? .aborted(endedAt: at) : .nothing
        case .unreadable: return .nothing
        }
    }

    /// Whether a path's file name is a rollout of this session:
    /// `rollout-<stamp>-<session id>.jsonl`.
    public static func namesSession(_ path: String, sessionId: String) -> Bool {
        guard !sessionId.isEmpty, !sessionId.contains("/"), sessionId != "..", sessionId != "." else {
            return false
        }
        let name = path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        return name.hasPrefix("rollout-") && name.hasSuffix("-\(sessionId).jsonl")
    }

    /// Whether an absolute path lies inside `<codexHome>/sessions/`, with no
    /// `.` or `..` component to walk it out again.
    public static func liesUnderSessions(_ path: String, codexHome: String) -> Bool {
        guard path.hasPrefix("/"), codexHome.hasPrefix("/") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        let homeParts = codexHome.split(separator: "/").map(String.init)
        guard !parts.contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }),
              !homeParts.contains(where: { $0 == "." || $0 == ".." }) else { return false }
        let root = homeParts + ["sessions"]
        return parts.count > root.count && Array(parts.prefix(root.count)).map(String.init) == root
    }

    /// A recorded `transcript_path` is read only when both hold: a journal
    /// line is anyone's to write, and the path must not point the reader at
    /// another file.
    public static func isTrusted(path: String, sessionId: String, codexHome: String) -> Bool {
        namesSession(path, sessionId: sessionId) && liesUnderSessions(path, codexHome: codexHome)
    }
}

import Foundation

/// How a quiet Copilot turn stands, read from the tail of the session's
/// event log: the JSON-lines file GitHub Copilot CLI writes for every
/// session (`<session-state>/<session id>/events.jsonl`), whose path the
/// hook records on a Copilot start, prompt or stop. Copilot writes there
/// what no hook reports: Ctrl+C and Esc Esc fire no hook and write an
/// `abort`; a failed turn fires no `agentStop` and writes a `session.error`;
/// an answered permission prompt fires no hook and writes a
/// `permission.completed`.
///
/// The markers are a line's `type`: `abort` (the turn was interrupted),
/// `session.error` (the turn failed: only the last of a model call's retries
/// writes one, the retried ones writing only their `errorOccurred` hook's
/// mirror), `session.shutdown` (the session closed), the steps of a turn at
/// work (`user.message`, `assistant.turn_start`, `assistant.message`,
/// `tool.execution_start`, `tool.execution_complete`,
/// `permission.requested`, `permission.completed`), and the natural end: the
/// `hook.start` line Copilot writes when it runs a hook, for an `agentStop`
/// whose payload (`data.input.sessionId`) names this session. A subagent's
/// `agentStop` is written into its parent's file under the subagent's id,
/// while the parent's turn goes on. `assistant.turn_end` ends every model
/// call, not the turn, and `session.idle` is never written. The last marker
/// wins, but for `session.shutdown`: the turn's own end before it, when
/// there is one, says how the turn ended, and the shutdown's own stamp is
/// kept beside it, so a shutdown after the last main-agent event ends the
/// turn whatever older end precedes it.
///
/// Only a line's `type`, `timestamp`, `data.hookType` and
/// `data.input.sessionId` are ever read. The rest of a line is the
/// conversation: it is never kept, returned or logged.
public enum CopilotTranscriptTail {
    public enum Verdict: Equatable {
        /// The last marker is a step of the turn: it runs. `writtenAt` is
        /// the stamp of the last line the tail holds, of any type: when
        /// Copilot last wrote to the session.
        case running(writtenAt: Date)
        /// The turn's own end. `closedAt` is the stamp of a
        /// `session.shutdown` written after it, when one was.
        case complete(at: Date, closedAt: Date? = nil)
        case aborted(at: Date, closedAt: Date? = nil)
        case failed(at: Date, closedAt: Date? = nil)
        /// The session closed while its turn had no end of its own, or one
        /// with no stamp.
        case closed(at: Date)
        /// No marker, nothing parseable, or an end marker with no stamp.
        case unreadable
    }

    /// What the store does with a verdict. An end carries the marker's
    /// stamp: the verdict is applied as of when the turn ended, as a
    /// replayed hook would be.
    public enum Decision: Equatable {
        /// The lost `Stop`: `finishTurn`, with the push a `Stop` earns.
        case finished(endedAt: Date)
        /// The interrupt: `abandonTurn`, dark, no push.
        case aborted(endedAt: Date)
        /// The `StopFailure` Copilot never sends: `failTurn`.
        case failed(endedAt: Date)
        /// The session closed mid-turn: `abandonTurn`, dark, no push.
        case closed(endedAt: Date)
        /// The turn runs: `noteBusy`.
        case busy
        case nothing
    }

    /// What the store does with a session in an open wait.
    public enum WaitDecision: Equatable {
        /// Ctrl+C or Esc Esc at the prompt: `abandonWait`, dark, no push.
        case aborted(endedAt: Date)
        /// The prompt was answered and the turn works on: `dialogAnswered`.
        /// `at` is the stamp of its `permission.completed`.
        case answered(at: Date)
        case nothing
    }

    /// How much of the file's end is read. Across the five probe sessions
    /// recorded on this Mac on 2026-09-25 (219 lines, 11 end markers), a
    /// turn's end was followed by at most 6.7 KB before the next marker,
    /// except after a `/compact`, whose model lines (about 95 KB) can push a
    /// finished turn's end out of the window, which then decides nothing.
    /// The longest line, a turn's opening `system.message` (up to 91 KB),
    /// is written right after its `user.message` and followed within a
    /// fraction of a second by the turn's first step.
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
    public static func verdict(tail: Data, sessionId: String) -> Verdict {
        scan(tail: tail, sessionId: sessionId).verdict
    }

    /// The verdict, and for a `.running` one the latest permission step in
    /// the window (`permission.requested` or `permission.completed`) with
    /// its own stamp: whichever came last says whether a prompt is open.
    private static func scan(tail: Data, sessionId: String) -> (verdict: Verdict, permission: (answered: Bool, at: Date?)?) {
        var body = tail[...]
        if tail.count > tailBytes {
            guard let newline = tail.firstIndex(of: 0x0A) else { return (.unreadable, nil) }
            body = tail[tail.index(after: newline)...]
        }
        let lines = body.split(separator: 0x0A, omittingEmptySubsequences: true)
        var writtenAt: Date?
        var shutdownAt: Date?
        for index in lines.indices.reversed() {
            let line = lines[index]
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            let stamp = (object["timestamp"] as? String).flatMap(JournalCodec.date(from:))
            if writtenAt == nil { writtenAt = stamp }
            let found = marker(type, object, sessionId: sessionId)
            switch found {
            case .work?:
                if let shutdownAt { return (.closed(at: shutdownAt), nil) }
                guard let written = writtenAt ?? stamp else { return (.unreadable, nil) }
                return (.running(writtenAt: written), latestPermission(in: lines[...index]))
            case .complete?, .aborted?, .failed?:
                // An end with no stamp cannot be weighed: after a shutdown,
                // the session closed; else nothing is known.
                guard let stamp else { return (shutdownAt.map { .closed(at: $0) } ?? .unreadable, nil) }
                switch found {
                case .complete?: return (.complete(at: stamp, closedAt: shutdownAt), nil)
                case .aborted?: return (.aborted(at: stamp, closedAt: shutdownAt), nil)
                default: return (.failed(at: stamp, closedAt: shutdownAt), nil)
                }
            case .shutdown?:
                if let shutdownAt { return (.closed(at: shutdownAt), nil) }
                guard let stamp else { return (.unreadable, nil) }
                // The look-back: the scan goes on for the turn's own end,
                // which says how the turn ended, and the shutdown's stamp is
                // kept beside it. A new prompt closed before Copilot wrote its
                // `user.message` (a window of milliseconds) finds the previous
                // turn's end, stamped before the last main-agent event: the
                // shutdown still ends the turn (`decision`).
                shutdownAt = stamp
            case nil:
                continue
            }
        }
        return (shutdownAt.map { .closed(at: $0) } ?? .unreadable, nil)
    }

    /// The last `permission.requested` or `permission.completed` among
    /// `lines`, and its own stamp.
    private static func latestPermission(in lines: ArraySlice<Data.SubSequence>) -> (answered: Bool, at: Date?)? {
        for line in lines.reversed() {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = object["type"] as? String,
                  type == "permission.requested" || type == "permission.completed" else { continue }
            return (type == "permission.completed", (object["timestamp"] as? String).flatMap(JournalCodec.date(from:)))
        }
        return nil
    }

    /// Copilot names no turn: an end marker ends the session's turn only
    /// when it is stamped after the last main-agent event. One stamped
    /// earlier is the previous turn's end, seen before Copilot wrote the new
    /// prompt's `user.message`; a `session.shutdown` after it, stamped after
    /// the last main-agent event, still closes the session mid-turn.
    public static func decision(verdict: Verdict, lastMainEventAt: Date) -> Decision {
        func closed(_ closedAt: Date?) -> Decision {
            guard let closedAt, closedAt > lastMainEventAt else { return .nothing }
            return .closed(endedAt: closedAt)
        }
        switch verdict {
        case .running: return .busy
        case .complete(let at, let closedAt): return at > lastMainEventAt ? .finished(endedAt: at) : closed(closedAt)
        case .aborted(let at, let closedAt): return at > lastMainEventAt ? .aborted(endedAt: at) : closed(closedAt)
        case .failed(let at, let closedAt): return at > lastMainEventAt ? .failed(endedAt: at) : closed(closedAt)
        case .closed(let at): return closed(at)
        case .unreadable: return .nothing
        }
    }

    /// What a session's tail means for it while it waits on a permission or
    /// a question since `waitSince`. The latest turn marker decides:
    /// - an `abort` stamped after the wait began is Ctrl+C or Esc Esc at the
    ///   prompt, and ends the turn as a working turn's abort does;
    /// - with the turn still running, a latest permission step that is a
    ///   `permission.completed` stamped after the wait began is the prompt
    ///   answered (approving or denying fires no hook and writes it),
    ///   reported at its own stamp;
    /// - anything else changes nothing: a latest `permission.requested` is a
    ///   prompt still open (a second one opens right after the first is
    ///   answered), a tool finishing beside an open prompt is no answer, a
    ///   finish, a failure or a close is no answer, and a step or an abort
    ///   stamped at or before the wait began is not about it. A question's
    ///   answer needs none of this: it ends its tool, and `postToolUse` fires.
    /// The verdict's `writtenAt` never decides: the wait's own `notification`
    /// hook writes a `hook.end` after the wait began, answered or not.
    public static func waitDecision(tail: Data, sessionId: String, waitSince: Date) -> WaitDecision {
        let read = scan(tail: tail, sessionId: sessionId)
        switch read.verdict {
        case .aborted(let at, _) where at > waitSince:
            return .aborted(endedAt: at)
        case .running:
            guard let permission = read.permission, permission.answered,
                  let at = permission.at, at > waitSince else { return .nothing }
            return .answered(at: at)
        default:
            return .nothing
        }
    }

    /// A recorded path is read only when it is exactly
    /// `<root>/<session id>/events.jsonl`, absolute, with no `.` or `..`
    /// component and no empty one: a journal line is anyone's to write, and
    /// the path must not point the reader at another file, nor at another
    /// session's.
    public static func isTrusted(path: String, sessionId: String, root: String) -> Bool {
        guard path.hasPrefix("/"), root.hasPrefix("/"), CopilotSessionState.isFolderName(sessionId) else {
            return false
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        let rootParts = root.split(separator: "/").map(String.init)
        guard !rootParts.isEmpty,
              !parts.contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }),
              !rootParts.contains(where: { $0 == "." || $0 == ".." }) else { return false }
        return parts == rootParts + [sessionId, "events.jsonl"]
    }

    /// The file the app reads for a session: the recorded path when it is
    /// trusted, else the session's own under the root; none for an id that
    /// is not one folder name.
    public static func path(recorded: String?, sessionId: String, root: String) -> String? {
        if let recorded, isTrusted(path: recorded, sessionId: sessionId, root: root) { return recorded }
        let own = CopilotSessionState.transcriptPath(root: root, sessionId: sessionId)
        return isTrusted(path: own, sessionId: sessionId, root: root) ? own : nil
    }

    private enum Marker { case work, complete, aborted, failed, shutdown }

    private static let workTypes: Set<String> = [
        "user.message", "assistant.turn_start", "assistant.message", "tool.execution_start",
        "tool.execution_complete", "permission.requested", "permission.completed",
    ]

    private static func marker(_ type: String, _ object: [String: Any], sessionId: String) -> Marker? {
        switch type {
        case "abort": return .aborted
        case "session.error": return .failed
        case "session.shutdown": return .shutdown
        case "hook.start":
            guard !sessionId.isEmpty, let data = object["data"] as? [String: Any],
                  data["hookType"] as? String == "agentStop",
                  let input = data["input"] as? [String: Any],
                  (input["sessionId"] ?? input["session_id"]) as? String == sessionId else { return nil }
            return .complete
        default:
            return workTypes.contains(type) ? .work : nil
        }
    }
}

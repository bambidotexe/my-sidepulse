import Foundation

/// GitHub Copilot CLI's session folders: `~/.copilot/session-state/<session
/// id>/`, or the same under `$COPILOT_HOME` when the hook's environment sets
/// it, one per session, named by its id and holding its `events.jsonl`. A
/// subagent's own prompt and stop carry the subagent's id, which has no
/// folder: the hook writes no line for them, so a subagent's stop never
/// finishes its parent's turn. Pure: the hook hands in the environment and the
/// folder check.
public enum CopilotSessionState {
    /// `$COPILOT_HOME/session-state` when `COPILOT_HOME` is set and not empty,
    /// else `<home>/.copilot/session-state`.
    public static func root(environment: [String: String], home: String) -> String {
        let base: String
        if let copilotHome = environment["COPILOT_HOME"], !copilotHome.isEmpty { base = copilotHome }
        else { base = (home as NSString).appendingPathComponent(".copilot") }
        return (base as NSString).appendingPathComponent("session-state")
    }

    /// The session's event log, where Copilot writes its turn markers.
    public static func transcriptPath(root: String, sessionId: String) -> String {
        ((root as NSString).appendingPathComponent(sessionId) as NSString).appendingPathComponent("events.jsonl")
    }

    /// Whether the hook writes a Copilot line: always for a line of no
    /// session (a `ParseError`), and when the root is missing, since then
    /// nothing tells a subagent apart; otherwise only for a session with its
    /// folder under the root. An id that is not one folder name names none.
    public static func keeps(sessionId: String?, root: String, directoryExists: (String) -> Bool) -> Bool {
        guard let sessionId, directoryExists(root) else { return true }
        return isFolderName(sessionId) && directoryExists((root as NSString).appendingPathComponent(sessionId))
    }

    /// The line the hook writes for a trimmed Copilot event: nil for a
    /// subagent's (`keeps`), else the event, naming the session's
    /// `events.jsonl` on a `SessionStart`, a `UserPromptSubmit` or a `Stop`
    /// whose payload named none, so the session knows its file from its
    /// first prompt.
    public static func line(_ event: JournalEvent, root: String, directoryExists: (String) -> Bool) -> JournalEvent? {
        guard keeps(sessionId: event.sessionId, root: root, directoryExists: directoryExists) else { return nil }
        var e = event
        if [.sessionStart, .userPromptSubmit, .stop].contains(e.event), e.transcriptPath == nil,
           let sid = e.sessionId, isFolderName(sid) {
            e.transcriptPath = transcriptPath(root: root, sessionId: sid)
        }
        return e
    }

    static func isFolderName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }
}

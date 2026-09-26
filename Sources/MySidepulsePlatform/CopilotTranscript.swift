import Foundation
import MySidepulseCore

/// The file side of a Copilot session's `events.jsonl`: which file, and
/// reading its tail. What the tail says is `CopilotTranscriptTail`'s to
/// decide.
public enum CopilotTranscript {
    /// The last `CopilotTranscriptTail.readBytes` of a plain file (the window
    /// and the byte before it), or the whole file when it is shorter.
    /// Anything but a regular file is refused before a byte is read, and the
    /// open never blocks: the path may come from a journal line, and a FIFO
    /// there would otherwise hang the main queue.
    public static func read(path: String) -> Data? {
        FileTail.read(path: path, bytes: CopilotTranscriptTail.readBytes)
    }

    /// The file the app reads for a session: the recorded path when Core
    /// trusts it (`<root>/<session id>/events.jsonl`), else the session's
    /// own under `root`. The app's root is `~/.copilot/session-state`
    /// (`Paths.copilotSessionState`): a Copilot run with `$COPILOT_HOME`
    /// set writes elsewhere, which the app, started by launchd, cannot see.
    public static func path(recorded: String?, sessionId: String, root: URL) -> String? {
        CopilotTranscriptTail.path(recorded: recorded, sessionId: sessionId, root: root.path)
    }

    /// The verdict of a session's file, `.unreadable` when there is none.
    public static func verdict(sessionId: String, recorded: String?, root: URL) -> CopilotTranscriptTail.Verdict {
        path(recorded: recorded, sessionId: sessionId, root: root)
            .flatMap(read(path:))
            .map { CopilotTranscriptTail.verdict(tail: $0, sessionId: sessionId) } ?? .unreadable
    }
}

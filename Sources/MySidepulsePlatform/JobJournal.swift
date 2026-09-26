import Foundation
import MySidepulseCore

/// A terminal job's lines reach the app the way a hook's do: one capped line,
/// one `O_APPEND` write to the journal, nothing that waits on the app, which
/// reads the line whenever it runs and replays it after a restart. A line
/// that cannot be written is dropped: the shell's probe ends a job whose end
/// was lost.
public enum JobJournal {
    /// A begin line, unless `chain`, the watched process's ancestry, holds an
    /// agent's process: a shell under an agent runs that agent's work, which
    /// its session shows, and it is decided here while the shell is certainly
    /// alive, so the journal never carries the line. True when written.
    @discardableResult
    public static func begin(_ event: JournalEvent, chain: [ProcWalk.ProcInfo], to journalURL: URL) -> Bool {
        guard ProcWalk.hostingAgent(in: chain) == nil else { return false }
        return append(event, to: journalURL)
    }

    @discardableResult
    public static func append(_ event: JournalEvent, to journalURL: URL) -> Bool {
        try? FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let line = try? Trim.cappedLine(event) else { return false }
        return JournalWriter.append(line, to: journalURL)
    }
}

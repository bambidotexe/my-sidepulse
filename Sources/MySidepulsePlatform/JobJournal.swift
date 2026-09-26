import Foundation
import MySidepulseCore

/// A terminal job's lines reach the app the way a hook's do: one capped line,
/// one `O_APPEND` write to the journal, nothing that waits on the app, which
/// reads the line whenever it runs and replays it after a restart. A line
/// that cannot be written is dropped: the shell's probe ends a job whose end
/// was lost.
public enum JobJournal {
    @discardableResult
    public static func append(_ event: JournalEvent, to journalURL: URL) -> Bool {
        try? FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let line = try? Trim.cappedLine(event) else { return false }
        return JournalWriter.append(line, to: journalURL)
    }
}

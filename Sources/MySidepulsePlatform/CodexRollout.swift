import Foundation
import MySidepulseCore

/// The file side of a Codex session's rollout: finding it and reading its
/// tail. What the tail says is `CodexRolloutTail`'s to decide.
public enum CodexRollout {
    /// The last `CodexRolloutTail.tailBytes` of a plain file, or the whole
    /// file when it is shorter. Anything but a regular file is refused
    /// before a byte is read, and the open never blocks: the path may come
    /// from a journal line, and a FIFO there would otherwise hang the main
    /// queue.
    public static func read(path: String) -> Data? {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let size = Int(info.st_size)
        let count = min(size, CodexRolloutTail.tailBytes)
        guard count > 0 else { return Data() }
        var buffer = Data(count: count)
        let read = buffer.withUnsafeMutableBytes { raw in
            pread(fd, raw.baseAddress, count, off_t(size - count))
        }
        guard read >= 0 else { return nil }
        return buffer.prefix(read)
    }

    /// The newest rollout of a session under `<codexHome>/sessions/YYYY/MM/DD/`,
    /// for a session no line recorded a path for. Days are searched newest
    /// first and the first day holding one answers; within it the most
    /// recently written file wins.
    public static func locate(sessionId: String, codexHome: URL) -> String? {
        guard !sessionId.isEmpty else { return nil }
        let fm = FileManager.default
        // Built by name from `codexHome`, never from resolved URLs, so a
        // located path reads under the same prefix a recorded one is
        // checked against.
        func children(_ path: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: path)) ?? []).sorted(by: >).map { path + "/" + $0 }
        }
        func modified(_ path: String) -> Date {
            ((try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
        }
        for year in children(codexHome.appendingPathComponent("sessions").path) {
            for month in children(year) {
                for day in children(month) {
                    let matches = children(day).filter { CodexRolloutTail.namesSession($0, sessionId: sessionId) }
                    if let newest = matches.max(by: { modified($0) < modified($1) }) { return newest }
                }
            }
        }
        return nil
    }

    /// The rollout the app reads for a session: the recorded path when it
    /// names the session and lies under `<codexHome>/sessions/`, the located
    /// one otherwise.
    public static func path(recorded: String?, sessionId: String, codexHome: URL) -> String? {
        if let recorded,
           CodexRolloutTail.isTrusted(path: recorded, sessionId: sessionId, codexHome: codexHome.path) {
            return recorded
        }
        return locate(sessionId: sessionId, codexHome: codexHome)
    }
}

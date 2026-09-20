import Foundation

public enum JournalWriter {
    /// One open + one write(2) on an O_APPEND descriptor. Lines are capped at
    /// K.journalLineMaxBytes upstream, so concurrent hook processes append
    /// atomically in practice on APFS. O_CREAT means rotation needs no
    /// coordination: writers just land in the freshly created file.
    @discardableResult
    public static func append(_ line: Data, to url: URL) -> Bool {
        var data = line
        data.append(0x0A)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let written = data.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return write(fd, base, buffer.count)
        }
        return written == data.count
    }
}

import Foundation

/// The end of a plain file, for the readers of an agent's transcript
/// (`CodexRollout`, `CopilotTranscript`).
enum FileTail {
    /// The last `bytes` of a plain file, or the whole file when it is
    /// shorter. Anything but a regular file, a symbolic link included, is
    /// refused before a byte is read, and the open never blocks: the path
    /// may come from a journal line, and a FIFO there would otherwise hang
    /// the main queue.
    static func read(path: String, bytes: Int) -> Data? {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let size = Int(info.st_size)
        let count = min(size, bytes)
        guard count > 0 else { return Data() }
        var buffer = Data(count: count)
        let read = buffer.withUnsafeMutableBytes { raw in
            pread(fd, raw.baseAddress, count, off_t(size - count))
        }
        guard read >= 0 else { return nil }
        return buffer.prefix(read)
    }
}

import Foundation
import MySidepulseCore

/// Claude Code's own per-process record: `<config>/sessions/<pid>.json`,
/// maintained by the process itself with a live `status` ("busy" while a
/// turn runs, "idle" at the input prompt) and the id of the session it
/// hosts. This is the one signal about a turn that does not travel through
/// hooks — which matters because hooks can die mid-session while the
/// journal goes silent and the turn keeps working underneath.
///
/// The config dir is per account under an account switcher such as cswap
/// (`CLAUDE_CONFIG_DIR`), so the file is located through the session: its
/// transcript lives at `<config>/projects/<slug>/<session>.jsonl`, which
/// names the directory. A session no line has named a transcript for falls
/// back to the process's own `CLAUDE_CONFIG_DIR`, when macOS lets another
/// process's environment be read, then to `~/.claude`.
public enum ClaudeProcessRegistry {
    public struct Record: Equatable {
        public let sessionId: String?
        public let status: String?
        public let statusUpdatedAt: Date?
        public init(sessionId: String?, status: String?, statusUpdatedAt: Date?) {
            self.sessionId = sessionId; self.status = status; self.statusUpdatedAt = statusUpdatedAt
        }
        /// Strictly "idle", not merely "not busy": unknown values a future
        /// Claude Code may add must not read as at-rest.
        public var isIdle: Bool { status == "idle" }
        public var isBusy: Bool { status == "busy" }
    }

    public static func read(pid: Int32, transcriptPath: String?) -> Record? {
        let configDir = transcriptPath.flatMap(configDir(fromTranscriptPath:))
            ?? ProcWalk.environmentValue("CLAUDE_CONFIG_DIR", forPid: pid).map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return record(fromFileAt: configDir.appendingPathComponent("sessions/\(pid).json"),
                      expectedPid: pid)
    }

    /// The config directory a Claude Code transcript lives in: the parent of
    /// the last `projects` folder that sits at least two levels above the
    /// file (`<config>/projects/<slug>/<session>.jsonl`). The last one, so a
    /// config directory inside a folder called `projects` is still found.
    /// Nil for a path with no such folder, and for a path that is not
    /// absolute, which would name a folder under the app's own working
    /// directory and hide the fallbacks.
    public static func configDir(fromTranscriptPath path: String) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        let components = (path as NSString).pathComponents
        guard components.count >= 4,
              let index = components[..<(components.count - 2)].lastIndex(of: "projects"),
              index > 0 else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(components[..<index])))
    }

    static func record(fromFileAt file: URL, expectedPid: Int32) -> Record? {
        guard let data = try? Data(contentsOf: file),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        // Never trust a record about some other process: a recycled pid, or
        // a file the daemon left behind, must read as "no record".
        guard object["pid"] as? Int == Int(expectedPid) else { return nil }
        let updatedMs = (object["statusUpdatedAt"] as? Double)
            ?? (object["statusUpdatedAt"] as? Int).map(Double.init)
        return Record(sessionId: object["sessionId"] as? String,
                      status: object["status"] as? String,
                      statusUpdatedAt: updatedMs.map { Date(timeIntervalSince1970: $0 / 1000) })
    }
}

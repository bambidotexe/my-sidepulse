import Foundation
import MySidepulseCore

/// Claude Code's own per-process record: `<config>/sessions/<pid>.json`,
/// maintained by the process itself with a live `status` ("busy" while a
/// turn runs, "idle" at the input prompt) and the id of the session it
/// hosts. This is the one signal about a turn that does not travel through
/// hooks — which matters because hooks can die mid-session while the
/// journal goes silent and the turn keeps working underneath.
///
/// The config dir is per account under cswap (CLAUDE_CONFIG_DIR in the
/// process's environment), so the file is located through the process, not
/// through a fixed path.
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

    public static func read(pid: Int32) -> Record? {
        let configDir = ProcWalk.environmentValue("CLAUDE_CONFIG_DIR", forPid: pid)
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return record(fromFileAt: configDir.appendingPathComponent("sessions/\(pid).json"),
                      expectedPid: pid)
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

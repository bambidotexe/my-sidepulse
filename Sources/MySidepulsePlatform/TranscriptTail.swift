import Foundation

/// How a quiet turn actually ended, read from the session transcript's
/// tail. Claude Code writes NO interrupt marker on Ctrl-C, but the SHAPE
/// of the last substantive entry tells the two endings apart:
///
/// - a completed assistant message — `stop_reason: "end_turn"`, observed
///   stamped at the exact second of a real Stop hook — is a finish;
/// - an unanswered user entry (the prompt itself, or a tool_result no
///   assistant message followed), or an assistant message that stopped for
///   a tool, is a turn that died mid-flight;
/// - sidechain entries are subagent traffic inside the same file and never
///   speak for the main turn; the trailing state records (cost-state,
///   ai-title, …) carry no message at all and are skipped.
///
/// Anything unreadable answers `.unreadable`, which the caller treats as
/// "decide nothing yet" — never as either verdict.
public enum TranscriptTail {
    public enum Verdict: Equatable { case finished, incomplete, unreadable }

    /// How much of the file's tail is examined. A turn's final entries sit
    /// well inside this; a file whose last substantive entry is further
    /// back than 256 KB of state records is not one to guess about.
    static let tailBytes = 256 * 1024

    public static func verdict(atPath path: String) -> Verdict {
        guard let handle = FileHandle(forReadingAtPath: path) else { return .unreadable }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return .unreadable }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else { return .unreadable }
        var lines = data.split(separator: 0x0A)
        // A tail cut mid-line: the first fragment is not a whole record.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line)))
                    as? [String: Any] else { continue }
            if let verdict = classify(object) { return verdict }
        }
        return .unreadable
    }

    /// Nil for entries that do not speak for the main turn.
    static func classify(_ entry: [String: Any]) -> Verdict? {
        guard entry["isSidechain"] as? Bool != true,
              let type = entry["type"] as? String,
              let message = entry["message"] as? [String: Any] else { return nil }
        switch type {
        case "assistant":
            let stop = message["stop_reason"] as? String
            return (stop == "end_turn" || stop == "stop_sequence") ? .finished : .incomplete
        case "user":
            return .incomplete
        default:
            return nil
        }
    }
}

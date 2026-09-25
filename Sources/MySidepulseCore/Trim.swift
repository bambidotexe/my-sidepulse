import Foundation

public enum Trim {
    /// Ids, tool names and enum-ish fields are short in practice (a session
    /// id is a 36-char UUID). Clamping far above any real value keeps a
    /// hostile or malformed payload from inflating the journal line.
    static let metadataMaxChars = 200

    /// Reduce a raw Claude Code hook payload to a journal line. Bodies are
    /// dropped here so the journal stays small and appends stay atomic.
    /// All copied string fields are clamped at ingestion; the encoded line
    /// is then shrunk iteratively and finally guaranteed to fit via terminal fallback.
    public static func journalEvent(fromHookPayload data: Data, loggedAt: Date) -> JournalEvent {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = obj["hook_event_name"] as? String,
              let event = eventName(name), event != .parseError
        else {
            var e = JournalEvent(loggedAt: loggedAt, event: .parseError)
            e.rawPrefix = String(decoding: data.prefix(300), as: UTF8.self)
            return e
        }
        var e = JournalEvent(loggedAt: loggedAt, event: event)
        e.sessionId = clamp(obj["session_id"])
        e.promptId = clamp(obj["prompt_id"])
        e.turnId = clamp(obj["turn_id"]) ?? e.promptId
        e.agentId = clamp(obj["agent_id"])
        e.agentType = clamp(obj["agent_type"])
        e.toolName = clamp(obj["tool_name"])
        e.notificationType = clamp(obj["notification_type"])
        e.reason = clamp(obj["reason"])
        e.source = clamp(obj["source"])
        e.stopHookActive = obj["stop_hook_active"] as? Bool
        e.errorType = clamp(obj["error_type"])
        e.isInterrupt = obj["is_interrupt"] as? Bool
        // Turn boundaries only: enough for any session the app can rebuild,
        // without paying the path on every tool event. Codex's `Interrupt`
        // is one, so a session first seen at its interrupt names its rollout.
        if event == .sessionStart || event == .userPromptSubmit || event == .stop || event == .interrupt {
            e.transcriptPath = clamp(obj["transcript_path"])
        }
        e.cwd = obj["cwd"] as? String
        e.permissionMode = clamp(obj["permission_mode"])
        if let tail = obj["last_assistant_message"] as? String {
            e.lastMessageTail = String(tail.suffix(K.messageTailMaxChars))
        }
        if let tasks = obj["background_tasks"] {
            e.backgroundTaskIds = taskIds(tasks)
        }
        return e
    }

    /// The event names are Claude Code's spellings, which Codex shares. Codex
    /// spells the same names in snake case in its own configuration, so that
    /// spelling is taken too, in case a payload ever carries it.
    static func eventName(_ raw: String) -> HookEventName? {
        if let event = HookEventName(rawValue: raw) { return event }
        let pascal = raw.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        return HookEventName(rawValue: pascal)
    }

    static func clamp(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        return String(text.prefix(metadataMaxChars))
    }

    static func taskIds(_ raw: Any) -> [String]? {
        guard let arr = raw as? [Any] else { return nil }
        return arr.prefix(16).compactMap { item -> String? in
            if let s = item as? String { return String(s.prefix(40)) }
            guard let d = item as? [String: Any] else { return nil }
            // Only background shells hold the animation. Subagents are tracked
            // by their own events, which also release them; monitor-type
            // entries never report completion at all, so including either
            // holds the strip long after the turn really ended.
            if let type = d["type"] as? String, type != "shell" { return nil }
            for key in ["id", "task_id", "shell_id", "bash_id"] {
                if let v = d[key] as? String { return String(v.prefix(40)) }
            }
            return nil
        }
    }

    /// Encode with guaranteed cap via fixed shrink passes and terminal fallback.
    /// Pass 1: Full encoding. Pass 2: Trim message tail if present.
    /// Pass 3: Drastic cuts (tail, prefix, task count, task item length, cwd).
    /// Terminal: If still over cap, a minimal line with only event and timestamp.
    /// The cap is unconditional; a line that does not fit atomicity is never returned.
    public static func cappedLine(_ event: JournalEvent) throws -> Data {
        var e = event
        var data = try JournalCodec.encodeLine(e)
        if data.count > K.journalLineMaxBytes, let tail = e.lastMessageTail {
            let overflow = data.count - K.journalLineMaxBytes
            let keep = max(0, tail.utf8.count - overflow - 16)
            var newTail = tail
            while newTail.utf8.count > keep, !newTail.isEmpty { newTail.removeFirst() }
            e.lastMessageTail = newTail.isEmpty ? nil : newTail
            data = try JournalCodec.encodeLine(e)
        }
        if data.count > K.journalLineMaxBytes {
            e.lastMessageTail = nil
            e.rawPrefix = e.rawPrefix.map { String($0.prefix(100)) }
            e.backgroundTaskIds = e.backgroundTaskIds.map { arr in
                arr.prefix(4).map { String($0.prefix(40)) }
            }
            if let cwd = e.cwd, cwd.utf8.count > 200 { e.cwd = String(cwd.prefix(200)) }
            data = try JournalCodec.encodeLine(e)
        }
        if data.count > K.journalLineMaxBytes {
            // Terminal fallback: a minimal line always fits. Losing detail
            // beats emitting an oversized line, which would break the
            // atomicity of concurrent O_APPEND writes.
            var minimal = JournalEvent(loggedAt: event.loggedAt, event: event.event)
            minimal.sessionId = event.sessionId.map { String($0.prefix(64)) }
            data = try JournalCodec.encodeLine(minimal)
            if data.count > K.journalLineMaxBytes {
                data = try JournalCodec.encodeLine(
                    JournalEvent(loggedAt: event.loggedAt, event: event.event))
            }
        }
        return data
    }
}

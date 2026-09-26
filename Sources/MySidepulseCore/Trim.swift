import Foundation

public enum Trim {
    /// Ids, tool names and enum-ish fields are short in practice (a session
    /// id is a 36-char UUID). Clamping far above any real value keeps a
    /// hostile or malformed payload from inflating the journal line.
    static let metadataMaxChars = 200

    /// Reduce a raw Claude Code or Codex hook payload to a journal line.
    /// Bodies are dropped here so the journal stays small and appends stay
    /// atomic. The hook says which agent sent it (`agent`), never the
    /// payload, and only that agent's own events pass
    /// (`HookConfig.events(for:)`: Claude Code's 15, Codex's 12), in either
    /// spelling (`eventName`): any other name, the app's own line names
    /// included, is a `ParseError` that keeps the payload's first bytes and
    /// none of its fields, so a payload cannot forge another agent's
    /// `Interrupt` or a verdict. Copilot's and OpenCode's payloads have
    /// their own trims (`copilotEvent`, `opencodeEvent`), and here are a
    /// `ParseError` too. All copied string fields are clamped at ingestion;
    /// the encoded line is then shrunk iteratively and finally guaranteed to
    /// fit via terminal fallback.
    public static func journalEvent(fromHookPayload data: Data, agent: AgentKind, loggedAt: Date) -> JournalEvent {
        guard agent == .claude || agent == .codex,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = obj["hook_event_name"] as? String,
              let event = eventName(name), HookConfig.events(for: agent).contains(event.rawValue)
        else {
            var e = JournalEvent(loggedAt: loggedAt, event: .parseError)
            e.agent = agent
            e.rawPrefix = String(decoding: data.prefix(300), as: UTF8.self)
            return e
        }
        var e = JournalEvent(loggedAt: loggedAt, event: event)
        e.agent = agent
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
            e.transcriptPath = clampPath(obj["transcript_path"])
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

    /// A GitHub Copilot payload. Its event comes from the hook's `--event`,
    /// one of `HookConfig.copilotEvents`, since a camelCase payload names
    /// none; without the flag, the payload's own `hook_event_name`, which a
    /// `notification` and the PascalCase shape carry. The body is camelCase
    /// (`sessionId`, `toolName`, `transcriptPath`), but for
    /// `notification_type`; the snake-case spellings are taken too. Copilot
    /// names no turn. An event outside the seven is a `ParseError` that keeps
    /// the name it was given and none of the body, whose prompt or tool
    /// input a `preToolUse` or a `userPromptTransformed` would carry. Which
    /// sessions are subagents' is `CopilotSessionState`'s to say.
    public static func copilotEvent(fromHookPayload data: Data, named name: String?, loggedAt: Date) -> JournalEvent {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            var e = JournalEvent(loggedAt: loggedAt, event: .parseError)
            e.agent = .copilot
            e.rawPrefix = String(decoding: data.prefix(300), as: UTF8.self)
            return e
        }
        let given = name ?? obj["hook_event_name"] as? String
        guard let given, let event = copilotEventNames[given] else {
            var e = JournalEvent(loggedAt: loggedAt, event: .parseError)
            e.agent = .copilot
            e.rawPrefix = given.map { "copilot event: " + String($0.prefix(64)) }
            return e
        }
        var e = JournalEvent(loggedAt: loggedAt, event: event)
        e.agent = .copilot
        e.sessionId = clamp(obj["sessionId"]) ?? clamp(obj["session_id"])
        e.toolName = clamp(obj["toolName"]) ?? clamp(obj["tool_name"])
        e.notificationType = clamp(obj["notification_type"]) ?? clamp(obj["notificationType"])
        e.reason = clamp(obj["reason"])
        e.source = clamp(obj["source"])
        e.stopHookActive = (obj["stop_hook_active"] ?? obj["stopHookActive"]) as? Bool
        if event == .sessionStart || event == .userPromptSubmit || event == .stop {
            e.transcriptPath = clampPath(obj["transcriptPath"]) ?? clampPath(obj["transcript_path"])
        }
        e.cwd = obj["cwd"] as? String
        return e
    }

    /// Copilot's seven subscribed events, and the PascalCase aliases it
    /// accepts for them, onto the journal's names.
    static let copilotEventNames: [String: HookEventName] = [
        "sessionStart": .sessionStart, "SessionStart": .sessionStart,
        "userPromptSubmitted": .userPromptSubmit, "UserPromptSubmit": .userPromptSubmit,
        "postToolUse": .postToolUse, "PostToolUse": .postToolUse,
        "postToolUseFailure": .postToolUseFailure, "PostToolUseFailure": .postToolUseFailure,
        "notification": .notification, "Notification": .notification,
        "agentStop": .stop, "Stop": .stop,
        "sessionEnd": .sessionEnd, "SessionEnd": .sessionEnd,
    ]

    /// An OpenCode payload, which MySidepulse's plugin writes: OpenCode's own
    /// event type as `hook_event_name`, mapped onto the journal's names
    /// (`opencodeEventName`). A session with a `parent_id` is a subagent's,
    /// and its events are helper events of that top session (`sessionId`
    /// the top session, `agentId` the subagent's). OpenCode names no turn.
    /// Nil is no line at all: an event outside the mapping, a form that asks
    /// the user nothing, an event of no session (`null`, or `global` for a
    /// form outside any). A body that is not an event is a `ParseError`.
    public static func opencodeEvent(fromHookPayload data: Data, loggedAt: Date) -> JournalEvent? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["hook_event_name"] as? String else {
            var e = JournalEvent(loggedAt: loggedAt, event: .parseError)
            e.agent = .opencode
            e.rawPrefix = String(decoding: data.prefix(300), as: UTF8.self)
            return e
        }
        guard let session = clamp(obj["session_id"]), !session.isEmpty, session != "global" else { return nil }
        let parent = clamp(obj["parent_id"]).flatMap { $0.isEmpty ? nil : $0 }
        guard let (event, notification) = opencodeEventName(type, subagent: parent != nil,
                                                            status: obj["status"] as? String,
                                                            question: obj["question"] as? Bool ?? false)
        else { return nil }
        var e = JournalEvent(loggedAt: loggedAt, event: event)
        e.agent = .opencode
        if let parent { e.sessionId = parent; e.agentId = session } else { e.sessionId = session }
        // A permission's action (`shell`, `edit`, …) names the tool it guards.
        e.toolName = clamp(obj["tool_name"]) ?? (type == "permission.asked" ? clamp(obj["permission"]) : nil)
        e.notificationType = notification
        e.reason = clamp(obj["reason"])
        e.errorType = clamp(obj["error_name"])
        return e
    }

    /// OpenCode's event type onto the journal's name, for a top session or a
    /// subagent, with the notification type a question to the user carries.
    /// A subagent's end of any kind is its `SubagentStop`; its question or
    /// permission holds its top session's turn; a permission it is refused
    /// is a reply like any other, and a refused one at the top a denial. Nil:
    /// nothing is written.
    static func opencodeEventName(_ type: String, subagent: Bool, status: String?,
                                  question: Bool) -> (HookEventName, String?)? {
        switch type {
        case "session.created", "session.forked": return (subagent ? .subagentStart : .sessionStart, nil)
        case "session.inbox.enqueued", "session.execution.started": return (.userPromptSubmit, nil)
        case "session.tool.called": return (.preToolUse, nil)
        case "session.tool.success": return (.postToolUse, nil)
        case "session.tool.failed": return (.postToolUseFailure, nil)
        case "permission.asked": return (.permissionRequest, nil)
        case "permission.replied": return (status == "reject" && !subagent ? .permissionDenied : .postToolUse, nil)
        case "form.created":
            guard question else { return nil }
            return subagent ? (.permissionRequest, nil) : (.notification, "elicitation_dialog")
        case "form.replied", "form.cancelled": return (.postToolUse, nil)
        case "session.compaction.started": return (.preCompact, nil)
        case "session.compaction.ended", "session.compaction.failed": return (.postCompact, nil)
        case "session.execution.succeeded": return (subagent ? .subagentStop : .stop, nil)
        case "session.execution.failed": return (subagent ? .subagentStop : .stopFailure, nil)
        case "session.execution.interrupted": return (subagent ? .subagentStop : .interrupt, nil)
        case "session.deleted": return (subagent ? .subagentStop : .sessionEnd, nil)
        default: return nil
        }
    }

    /// The OpenCode server the payload names: the plugin's own process, the
    /// hook's parent. A claim, which the hook keeps only when that pid is an
    /// OpenCode ancestor of its own (`ProcWalk.classify`).
    public static func opencodePid(fromHookPayload data: Data) -> Int32? {
        // Never 1: launchd is no OpenCode, and a JSON `true` reads as 1.
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let value = obj["opencode_pid"] as? Int,
              let pid = Int32(exactly: value), pid > 1 else { return nil }
        return pid
    }

    /// The event names are Claude Code's spellings, which Codex shares. Codex
    /// spells the same names in snake case in its own configuration, so that
    /// spelling is taken too, in case a payload ever carries it. Whether the
    /// name is one of the agent's own is `journalEvent`'s to say.
    static func eventName(_ raw: String) -> HookEventName? {
        if let event = HookEventName(rawValue: raw) { return event }
        let pascal = raw.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        return HookEventName(rawValue: pascal)
    }

    static func clamp(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        return String(text.prefix(metadataMaxChars))
    }

    /// A transcript path, kept up to `K.pathMaxChars`: a cut path names no
    /// file.
    static func clampPath(_ value: Any?) -> String? {
        guard let path = value as? String else { return nil }
        return String(path.prefix(K.pathMaxChars))
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

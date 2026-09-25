import Foundation

public enum HookEventName: String, Codable, Equatable {
    case sessionStart = "SessionStart"
    case sessionEnd = "SessionEnd"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case postToolUseFailure = "PostToolUseFailure"
    case permissionRequest = "PermissionRequest"
    case permissionDenied = "PermissionDenied"
    case notification = "Notification"
    case stop = "Stop"
    case stopFailure = "StopFailure"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case preCompact = "PreCompact"
    case postCompact = "PostCompact"
    /// Codex only: the user interrupted the turn. Claude Code has no such
    /// event, which is why its interrupts need the registry and the
    /// transcript instead (`Engine.checkAbandonedTurns`).
    case interrupt = "Interrupt"
    case parseError = "ParseError"
    /// Not a Claude Code event: the app's own record that an alert was seen,
    /// appended to the same journal so acknowledgements survive a restart.
    /// Older app versions fail to decode the name and skip the line, which
    /// is the compatibility this rides on.
    case ack = "MySidepulseAck"
}

/// One trimmed journal line. Bodies (tool_input/response, prompts) never
/// reach this type — the hook drops them before writing.
public struct JournalEvent: Codable, Equatable {
    public var loggedAt: Date
    public var event: HookEventName
    /// Which agent fired the hook. Absent on lines written before Codex was
    /// followed, which were all Claude Code's: a reader takes nil as Claude.
    public var agent: AgentKind?
    public var sessionId: String?
    public var promptId: String?
    public var agentId: String?
    public var agentType: String?
    public var toolName: String?
    public var notificationType: String?
    public var reason: String?
    public var source: String?
    public var stopHookActive: Bool?
    public var errorType: String?
    public var isInterrupt: Bool?
    public var lastMessageTail: String?
    public var backgroundTaskIds: [String]?
    /// The agent's own process, Claude Code's or Codex's: what the process
    /// watcher and the startup prune key on. Its journal key stays
    /// `claude_pid`, the name it had when only Claude was followed.
    public var agentPid: Int32?
    public var hostAppPid: Int32?
    public var hostBundleId: String?
    /// The Claude process's controlling terminal ("ttys003") — the one
    /// thing that distinguishes a TAB, since every tab of a terminal shares
    /// its bundle id and pid. Recorded by the hook, used to scope
    /// acknowledgement to the tab actually being looked at.
    public var tty: String?
    /// The session transcript file, recorded on the turn-boundary events
    /// only (SessionStart, UserPromptSubmit, Stop) to keep the journal
    /// lean. Read when a quiet turn's registry says idle, to tell an
    /// interrupt (last entry: an unanswered user message) from a finish
    /// whose Stop was lost (last entry: an assistant message that says
    /// end_turn).
    public var transcriptPath: String?
    public var cwd: String?
    public var permissionMode: String?
    public var rawPrefix: String?
    /// For `.ack` lines only: the stateSince of the alert that was seen, so
    /// replay can never clear a newer alert than the one acknowledged.
    public var ackStateSince: Date?

    public init(loggedAt: Date, event: HookEventName) {
        self.loggedAt = loggedAt
        self.event = event
    }

    enum CodingKeys: String, CodingKey {
        case loggedAt = "logged_at"
        case event, agent
        case sessionId = "session_id"
        case promptId = "prompt_id"
        case agentId = "agent_id"
        case agentType = "agent_type"
        case toolName = "tool_name"
        case notificationType = "notification_type"
        case reason, source
        case stopHookActive = "stop_hook_active"
        case errorType = "error_type"
        case isInterrupt = "is_interrupt"
        case lastMessageTail = "last_message_tail"
        case backgroundTaskIds = "background_task_ids"
        case agentPid = "claude_pid"
        case hostAppPid = "host_app_pid"
        case hostBundleId = "host_bundle_id"
        case tty
        case transcriptPath = "transcript_path"
        case cwd
        case permissionMode = "permission_mode"
        case rawPrefix = "raw_prefix"
        case ackStateSince = "ack_state_since"
    }
}

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
    /// Not a hook event either: the app's own record of a verdict it reached
    /// when hooks said nothing (`TurnVerdict`), appended to the journal so a
    /// relaunch replays it. Older app versions skip it, as they skip `.ack`.
    case verdict = "MySidepulseVerdict"
    /// Not a hook event: a terminal job, written by the CLI (`job begin`,
    /// `job end`, `run`), never by an agent's hook, whose trims refuse both
    /// names. A line of neither names a session. Older app versions skip
    /// them, as they skip `.ack`.
    case jobBegin = "JobBegin"
    case jobEnd = "JobEnd"
}

/// What a `.verdict` line says the app decided about a quiet turn or an open
/// wait. Its line is stamped when the verdict took effect, so replaying it
/// gives the same state since the same instant.
public enum TurnVerdict: String, Equatable {
    /// The turn ended without delivering anything: dark (`abandonTurn`).
    case turnAbandoned = "turn-abandoned"
    /// The turn finished and only its `Stop` was lost (`finishTurn`).
    case turnFinished = "turn-finished"
    /// The turn failed and no hook said so: the outcome a `StopFailure`
    /// gives (`failTurn`).
    case turnFailed = "turn-failed"
    /// An open dialog was answered with no hook (`dialogAnswered`).
    case dialogAnswered = "dialog-answered"
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
    /// The turn the event belongs to: Codex's `turn_id`, else Claude Code's
    /// `prompt_id`. Both agents send it on the events of a turn, never on
    /// `SessionStart`. What lets the store tell an event of the running turn
    /// from one of a turn already closed (`SessionStore.changesNothing`).
    public var turnId: String?
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
    /// only (SessionStart, UserPromptSubmit, Stop, Interrupt) to keep the
    /// journal lean. For Claude Code, read when a quiet turn's registry
    /// says idle, to tell an interrupt (last entry: an unanswered user
    /// message) from a finish whose Stop was lost (last entry: an assistant
    /// message that says end_turn). For Codex it is the session's rollout,
    /// read when a turn goes quiet (`CodexRolloutTail`); for Copilot, the
    /// session's `events.jsonl` (`CopilotTranscriptTail`).
    public var transcriptPath: String?
    public var cwd: String?
    public var permissionMode: String?
    public var rawPrefix: String?
    /// For `.ack` lines only: the stateSince of the alert that was seen, so
    /// replay can never clear a newer alert than the one acknowledged.
    public var ackStateSince: Date?
    /// For `.verdict` lines only: a `TurnVerdict` raw value. A string, so a
    /// verdict a later version adds reads as unknown and changes nothing.
    public var verdict: String?
    /// For the job lines, and an `.ack` line that names a job instead of a
    /// session: the job (`zsh-<pid>` for a shell, a UUID for `run`).
    public var jobId: String?
    /// For `.jobBegin` only: the process watched for the job's end (the
    /// shell, or the `run` wrapper), the shell whose one slot the job takes,
    /// its label, and how long it waits before it shows. The host app is
    /// `hostBundleId`.
    public var jobPid: Int32?
    public var jobSlotPid: Int32?
    public var jobLabel: String?
    public var jobShowAfterSeconds: Double?
    /// For `.jobEnd` only: the command's exit status.
    public var jobExitCode: Int32?

    public init(loggedAt: Date, event: HookEventName) {
        self.loggedAt = loggedAt
        self.event = event
    }

    enum CodingKeys: String, CodingKey {
        case loggedAt = "logged_at"
        case event, agent
        case sessionId = "session_id"
        case promptId = "prompt_id"
        case turnId = "turn_id"
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
        case verdict
        case jobId = "job_id"
        case jobPid = "job_pid"
        case jobSlotPid = "job_slot_pid"
        case jobLabel = "job_label"
        case jobShowAfterSeconds = "job_show_after_seconds"
        case jobExitCode = "job_exit_code"
    }
}

import Foundation

public enum WaitReason: String, Equatable {
    case question, permission, plan, error
}

public enum SessionState: Equatable {
    case idle, working, done
    case waiting(WaitReason)
    public var isWaiting: Bool { if case .waiting = self { return true }; return false }
    /// A waiting state whose turn is still open: Claude is blocked on a
    /// dialog, and answering it resumes the same turn. `error` is the one
    /// waiting reason that is NOT open — the turn died.
    public var isOpenWaiting: Bool {
        if case .waiting(let r) = self { return r != .error }; return false
    }
}

public struct Session: Equatable {
    public var id: String
    /// Whose session. Claude until an event says otherwise, which is what
    /// every line written before Codex was followed means.
    public var agent: AgentKind = .claude
    public var state: SessionState = .idle
    public var stateSince: Date
    public var lastEventAt: Date
    /// Last event from the MAIN agent (prompt, tool use, stop…) — not from a
    /// helper, not a Notification, not an ack. This is what "the turn has
    /// gone quiet" is measured against.
    public var lastMainEventAt: Date
    /// The agent's own process: Claude Code's, or Codex's.
    public var agentPid: Int32?
    public var hostBundleId: String?
    /// The claude process's controlling terminal ("ttys003") — the tab.
    public var tty: String?
    /// The session transcript file, for the quiet-turn verdicts.
    public var transcriptPath: String?
    public var cwd: String?
    /// Helper agents believed to be running, each with the time it was last
    /// seen. A timestamp rather than bare membership because there is no
    /// reliable end event: Claude Code drops `SubagentStop` for some agents
    /// (19 of 44 registry-visible helpers in the recorded journal never got
    /// one), so a set could never empty again. See `hasLiveHelpers(at:)`.
    public var liveAgents: [String: Date] = [:]
    public var backgroundIds: Set<String> = []
    /// A `done` verdict deferred because helpers or background shells were
    /// still out. Only `done` is ever deferred, so this is a flag.
    public var pendingDone: Bool = false
    public var holdReleasedAt: Date?
    public var acknowledged: Bool = false
    /// True while the current `waiting(.permission)` was raised by a helper
    /// agent rather than the main agent — cleared the moment the helper acts
    /// again, since main-agent activity only clears main-raised waits.
    public var waitingFromAgent: Bool = false
    /// When an unacknowledged alert should be pushed off the machine.
    public var notifyAt: Date?
    /// While an alert is proving it will stick, the strip keeps showing the
    /// state being left. Cleared by `tick` once the window passes.
    public var settlingFrom: SessionState?
    public var settlingUntil: Date?
    /// The turn the last main-agent event that carried an id named, a
    /// prompt's included: the turn a close closes.
    public var lastMainTurnId: String?
    /// The turns an `Interrupt` or a verdict closed, the most recent last,
    /// at most `Session.closedTurnsKept` of them. An event of one of these
    /// turns proves the hook alive and changes nothing else.
    public var closedTurnIds: [String] = []
    /// When the last `Interrupt` arrived, until a prompt opens a turn: the
    /// start of the quarantine for tool events that name no turn.
    public var interruptedAt: Date?
    /// The state `PreCompact` found, restored by `PostCompact`: a
    /// compaction is work while it runs, and afterwards the session goes
    /// back to what it was, not to `working`.
    public var stateBeforeCompaction: SessionState?
    /// The alert bookkeeping `PreCompact` found, restored beside a `.done`
    /// `stateBeforeCompaction` so `PostCompact` does not re-arm a push for a
    /// standing finish.
    var compactionSnapshot: CompactionSnapshot?
    public static let closedTurnsKept = 8

    /// What arbitration acts on, as opposed to what the machine records.
    public var presentedState: SessionState { settlingFrom ?? state }
    /// Whether any helper has reported in recently enough to still count as
    /// running. Silence is the only end signal that can be trusted, because a
    /// missing `SubagentStop` is indistinguishable from a helper that never
    /// finished — and treating it as still-running would wedge the strip on
    /// `working` for a finished turn.
    public func hasLiveHelpers(at now: Date) -> Bool {
        liveAgents.values.contains { now.timeIntervalSince($0) < K.agentStaleSeconds }
    }
    /// When the last helper still counted as live is due to fall silent, so
    /// the store can schedule the tick that notices. Nil once none is live.
    public func helperExpiry(after now: Date) -> Date? {
        guard hasLiveHelpers(at: now), let last = liveAgents.values.max() else { return nil }
        return last.addingTimeInterval(K.agentStaleSeconds)
    }
    public var waitReason: WaitReason? {
        if case .waiting(let r) = state { return r }; return nil
    }
    public init(id: String, stateSince: Date, lastEventAt: Date) {
        self.id = id; self.stateSince = stateSince; self.lastEventAt = lastEventAt
        self.lastMainEventAt = lastEventAt
    }
}

/// The alert fields `PostCompact` copies back verbatim when the state it is
/// restoring is `.done`, so a standing finish does not re-arm its debounce
/// through `set`.
struct CompactionSnapshot: Equatable {
    var state: SessionState
    var stateSince: Date
    var acknowledged: Bool
    var notifyAt: Date?
}

/// A session acknowledgement worth persisting: keyed by the state-entry time
/// so a replayed ack can only ever clear the exact alert it cleared live.
public struct AckRecord: Equatable {
    public let sessionId: String
    public let stateSince: Date
    public init(sessionId: String, stateSince: Date) {
        self.sessionId = sessionId; self.stateSince = stateSince
    }
}

/// The per-session state machine. Pure: driven entirely by event timestamps
/// and explicit tick(now:) calls, so replay from the journal uses the same
/// code path as live events.
public struct SessionStore {
    public private(set) var sessions: [String: Session] = [:]
    public init() {}

    public mutating func apply(_ e: JournalEvent) {
        guard e.event != .parseError, let sid = e.sessionId else { return }
        let now = e.loggedAt
        if e.event == .sessionEnd {
            sessions.removeValue(forKey: sid)
            return
        }
        if e.event == .ack {
            // The app's own persisted acknowledgement, replayed after a
            // restart. It must not create sessions, refresh liveness, or
            // clear anything but the exact alert it was recorded against.
            guard var s = sessions[sid], let since = e.ackStateSince,
                  abs(s.stateSince.timeIntervalSince(since)) < 0.005 else { return }
            s.acknowledged = true
            s.notifyAt = nil
            s.settlingFrom = nil
            s.settlingUntil = nil
            sessions[sid] = s
            return
        }
        var s = sessions[sid] ?? Session(id: sid, stateSince: now, lastEventAt: now)
        s.lastEventAt = now
        if let agent = e.agent { s.agent = agent }
        if let pid = e.agentPid { s.agentPid = pid }
        if let host = e.hostBundleId { s.hostBundleId = host }
        if let tty = e.tty { s.tty = tty }
        if let path = e.transcriptPath { s.transcriptPath = path }
        if let cwd = e.cwd { s.cwd = cwd }
        if Self.changesNothing(e, in: s, now: now) {
            sessions[sid] = s
            return
        }

        if let agentId = e.agentId {
            // Helper events maintain the registry and never speak for the
            // main agent — with two exceptions that ARE the user's business:
            // a helper blocked on a permission prompt blocks the whole turn,
            // and a helper active after `done` means the turn is not over.
            switch e.event {
            case .subagentStop:
                s.liveAgents.removeValue(forKey: agentId)
            case .permissionRequest:
                // The prompt surfaces in the main UI exactly like the main
                // agent's own, so it raises the same wait.
                s.liveAgents[agentId] = now
                clearPending(&s)
                set(&s, .waiting(Self.waitReason(forPermissionTool: e.toolName)), now,
                    fromAgent: true)
            default:
                s.liveAgents[agentId] = now
                if s.state == .waiting(.permission), s.waitingFromAgent {
                    // The helper is acting again, so its prompt was answered.
                    set(&s, .working, now)
                } else if s.state == .done {
                    // A helper still running after `done` means the turn was
                    // never really over — re-open it and re-arm the verdict.
                    s.pendingDone = true
                    set(&s, .working, now)
                }
            }
            updateHoldRelease(&s, now: now)
            sessions[sid] = s
            return
        }

        // Below the subagent return on purpose: the snapshot belongs to the
        // main agent. A subagent payload inherits its parent's session_id and
        // carries its own background_tasks — letting it rewrite the parent's
        // set re-arms a hold that the parent's own Stop is trying to release.
        if let bg = e.backgroundTaskIds { s.backgroundIds = Set(bg) }
        if e.event != .notification { s.lastMainEventAt = now }
        if let id = e.turnId { s.lastMainTurnId = id }

        switch e.event {
        case .sessionStart:
            // A start that is not mid-turn compaction is a process boundary:
            // no helper recorded before it can still be running, and no
            // background shell survived it either. Compaction is NOT one: it
            // happens inside a turn, with helpers possibly out. It is also
            // not a state of its own — `PreCompact` already went `working`,
            // and this mid-flight marker changes nothing.
            if e.source != "compact" {
                s.liveAgents.removeAll()
                s.backgroundIds.removeAll()
            }
            clearPending(&s)
            if e.source != "compact" { set(&s, .idle, now) }
        case .userPromptSubmit:
            // A prompt always opens a turn, even one that names a closed
            // turn: its events count again, its Stop and Interrupt included.
            if let id = e.turnId { s.closedTurnIds.removeAll { $0 == id } }
            s.interruptedAt = nil
            // NOT a helper boundary: Claude Code 2.1 accepts a prompt while
            // a previous turn's background helper still runs, so clearing
            // the registry here would green-light a Stop over a
            // still-running helper. Helpers leave only via SubagentStop or
            // the 4-minute silence expiry.
            clearPending(&s)
            set(&s, .working, now)
        case .postToolUse, .postToolUseFailure, .permissionDenied:
            clearPending(&s)
            set(&s, .working, now)
        case .preCompact:
            // Work while it runs, remembering the state it found so
            // `PostCompact` can go back to it rather than to `working`.
            s.stateBeforeCompaction = s.state
            s.compactionSnapshot = CompactionSnapshot(
                state: s.state, stateSince: s.stateSince,
                acknowledged: s.acknowledged, notifyAt: s.notifyAt)
            clearPending(&s)
            set(&s, .working, now)
        case .postCompact:
            // A compaction inside a turn leaves it working (no state was
            // found before it — none ran); one at the prompt leaves it idle
            // or finished. Restoring `.done` through `set` would re-arm its
            // push as a fresh alert and its settle as a fresh transition, so
            // the original stateSince, acknowledged and notifyAt are copied
            // back over it and no settle is left standing: a standing green
            // must not blink or push again just because a compaction ran.
            let restored = s.stateBeforeCompaction ?? .working
            clearPending(&s)
            set(&s, restored, now)
            if restored == .done, let snap = s.compactionSnapshot {
                s.stateSince = snap.stateSince
                s.acknowledged = snap.acknowledged
                s.notifyAt = snap.notifyAt
                s.settlingFrom = nil
                s.settlingUntil = nil
            }
            s.stateBeforeCompaction = nil
            s.compactionSnapshot = nil
        case .preToolUse:
            clearPending(&s)
            switch e.toolName {
            case "AskUserQuestion", "request_user_input": set(&s, .waiting(.question), now)
            case "ExitPlanMode": set(&s, .waiting(.plan), now)
            default: set(&s, .working, now)
            }
        case .permissionRequest:
            clearPending(&s)
            set(&s, .waiting(Self.waitReason(forPermissionTool: e.toolName)), now)
        case .notification:
            switch e.notificationType {
            case "permission_prompt", "elicitation_dialog", "elicitation_url_dialog":
                // The dialog echo of a prompt the machine may already know
                // in a more specific form: AskUserQuestion and ExitPlanMode
                // both fire one a few seconds after their PreToolUse. Keep
                // the specific reason — downgrading question/plan to
                // permission changed the push copy and re-armed a second
                // push for the same standing dialog.
                if s.state == .waiting(.question) || s.state == .waiting(.plan) { break }
                clearPending(&s); set(&s, .waiting(.permission), now)
            case "idle_prompt", "agent_needs_input":
                // A timer, not a request: Claude Code says the turn has gone
                // quiet and it is sitting at the input prompt. That is never
                // "needs you" — the strong signals (AskUserQuestion,
                // permissions, plan) all have their own events. Its one use
                // is as a rescue: if the machine
                // still believes the turn is running, the Stop was lost, and
                // this is the finish line arriving by other means. Anything
                // else — done, held, a standing dialog, a dead turn — it is
                // an echo, and echoes change nothing.
                guard s.state == .working, !s.pendingDone,
                      now.timeIntervalSince(s.lastMainEventAt) >= K.idleSignalMinQuietSeconds
                else { break }
                applyStopVerdict(&s, now: now)
            default:
                break // auth_success, elicitation_complete/_response, agent_completed, unknown
            }
        case .stopFailure:
            clearPending(&s)
            set(&s, .waiting(.error), now)
        case .interrupt:
            // Codex says so itself when the user stops a turn, dialog or
            // not: the turn is over and delivered nothing, so the strip goes
            // dark. The interrupt ends the turn's helpers and background
            // shells with it. Claude Code has no such event; its interrupts
            // are read from the registry and the transcript instead.
            clearPending(&s)
            s.liveAgents.removeAll()
            s.backgroundIds.removeAll()
            set(&s, .idle, now)
            closeTurn(&s, byInterrupt: true, now: now)
        case .stop:
            // A Stop is a finish, full stop: a trailing question in prose is
            // a finished turn, not a request for attention — AskUserQuestion
            // is the request path, and it has its own event. It ends the
            // turn without closing it: a Stop hook that blocks the Stop
            // keeps the same turn running, and its later events count.
            clearPending(&s)
            applyStopVerdict(&s, now: now)
        case .sessionEnd, .parseError, .ack, .subagentStart, .subagentStop:
            break // handled above; subagent shapes without agent_id carry no signal
        }
        updateHoldRelease(&s, now: now)
        sessions[sid] = s
    }

    /// Claude Code 2.1 routes the blocking dialogs through the permission
    /// system: AskUserQuestion and ExitPlanMode each fire a PermissionRequest
    /// naming themselves as the tool (28 and 6 of the 44 recorded
    /// PermissionRequests). The tool name is what tells a question and a
    /// plan approval apart from a real permission ask — the wait reason, and
    /// with it the push copy, follows the tool, not the transport. Codex's
    /// question tool is `request_user_input`.
    static func waitReason(forPermissionTool tool: String?) -> WaitReason {
        switch tool {
        case "AskUserQuestion", "request_user_input": return .question
        case "ExitPlanMode": return .plan
        default: return .permission
        }
    }

    /// Whether an event belongs to a turn that is over, and so only proves
    /// the hook alive. Codex reports the end of a tool it aborted seconds or
    /// minutes after the `Interrupt`, for the same turn, and no `Stop` ever
    /// follows an aborted turn: an event that reopened it would roll for
    /// hours. An event of a closed turn changes nothing, a helper's included
    /// (the interrupt or the verdict ended the helpers), except a prompt,
    /// which opens a turn, and a session's start. A tool or permission
    /// event that names no turn changes nothing for
    /// `K.abortQuarantineSeconds` after an `Interrupt`, until a prompt.
    /// `SessionEnd` and acknowledgements never reach it.
    private static func changesNothing(_ e: JournalEvent, in s: Session, now: Date) -> Bool {
        let ofAClosedTurn = e.turnId.map { s.closedTurnIds.contains($0) } ?? false
        if e.agentId != nil { return ofAClosedTurn }
        switch e.event {
        case .sessionStart, .userPromptSubmit: return false
        default: break
        }
        if ofAClosedTurn { return true }
        guard e.turnId == nil, let interruptedAt = s.interruptedAt,
              now.timeIntervalSince(interruptedAt) < K.abortQuarantineSeconds else { return false }
        switch e.event {
        case .preToolUse, .postToolUse, .postToolUseFailure, .permissionRequest, .permissionDenied:
            return true
        default:
            return false
        }
    }

    /// An `Interrupt` or a verdict that the turn is over closes the turn the
    /// last main-agent event that carried an id named: the prompt's, a
    /// later tool event's when the turn goes on under a new id with no
    /// prompt line, or the closing `Interrupt`'s own.
    private func closeTurn(_ s: inout Session, byInterrupt: Bool, now: Date) {
        if let id = s.lastMainTurnId, !s.closedTurnIds.contains(id) {
            s.closedTurnIds = Array((s.closedTurnIds + [id]).suffix(Session.closedTurnsKept))
        }
        s.interruptedAt = byInterrupt ? now : nil
    }

    /// The finish line, shared by Stop and the lost-Stop rescue: done if
    /// nothing is still out, held otherwise.
    func applyStopVerdict(_ s: inout Session, now: Date) {
        if !s.hasLiveHelpers(at: now) && s.backgroundIds.isEmpty {
            set(&s, .done, now)
        } else {
            // An agent whose helpers are still out is not finished with you:
            // keep the strip on the work and apply `done` when they clear.
            s.pendingDone = true
            set(&s, .working, now)
        }
    }

    func clearPending(_ s: inout Session) {
        s.pendingDone = false
        s.holdReleasedAt = nil
    }

    /// A state change always re-arms acknowledgement. So does a REPEATED
    /// alert of the same kind: a second permission ask is a second unread
    /// notification, not an echo of the first. Working and idle are not
    /// alerts — they keep the change-only guard so ordinary tool traffic
    /// never churns stateSince.
    func set(_ s: inout Session, _ new: SessionState, _ now: Date, fromAgent: Bool = false) {
        let isAlert: Bool
        switch new {
        case .waiting, .done: isAlert = true
        case .idle, .working: isAlert = false
        }
        guard s.state != new || isAlert else { return }
        // Only a change of VALUE starts a settle. A repeated alert must not
        // pull an amber already on the strip back off for another window.
        if s.state != new {
            s.settlingFrom = isAlert ? s.state : nil
            s.settlingUntil = isAlert ? now.addingTimeInterval(K.alertSettleSeconds) : nil
        }
        s.state = new
        s.stateSince = now
        s.acknowledged = false
        s.waitingFromAgent = fromAgent
        // The whole notification feature lives on this line. An accepted
        // transition into an alert state arms the debounce; anything else —
        // notably the held Stop's .working — disarms it, which is why a turn
        // that resumes can never announce itself as finished. A repeat alert
        // pushes the deadline forward rather than letting the older one fire.
        s.notifyAt = isAlert ? now.addingTimeInterval(K.notifyDebounceSeconds) : nil
    }

    static func alertKind(for state: SessionState) -> AlertKind? {
        switch state {
        case .done: return .finished
        case .waiting(let reason): return .needsYou(reason)
        case .idle, .working: return nil
        }
    }

    func updateHoldRelease(_ s: inout Session, now: Date) {
        guard s.pendingDone else { return }
        if !s.hasLiveHelpers(at: now) && s.backgroundIds.isEmpty {
            // Dated to now, never backdated to the moment silence began:
            // `nextDeadline` only reports deadlines in the future, so a
            // backdated release whose grace had already lapsed would be
            // filtered out and no tick would ever be scheduled to act on it —
            // leaving the session on `working` until the 30-minute holdTTL.
            if s.holdReleasedAt == nil { s.holdReleasedAt = now }
        } else {
            s.holdReleasedAt = nil // a new helper re-engages the hold
        }
    }

    /// Applies every time-based rule. Call with wall-clock now; schedule the
    /// next call at nextDeadline(after:) — there is no periodic tick.
    @discardableResult
    public mutating func tick(now: Date, userPresent: Bool = false) -> [Alert] {
        var fired: [Alert] = []
        for (id, original) in sessions {
            var s = original
            // A helper that simply stops reporting generates no event, so the
            // hold has to be re-examined on the clock, not only on arrival.
            if s.pendingDone {
                updateHoldRelease(&s, now: now)
                let graceExpired = s.holdReleasedAt.map {
                    now.timeIntervalSince($0) >= K.holdGraceSeconds } ?? false
                let ttlExpired = now.timeIntervalSince(s.lastEventAt) >= K.holdTTLSeconds
                if graceExpired || ttlExpired {
                    clearPending(&s)
                    set(&s, .done, now)
                }
            }
            if s.state == .done, now.timeIntervalSince(s.stateSince) >= K.doneVisibleSeconds {
                set(&s, .idle, now)
            }
            if now.timeIntervalSince(s.lastEventAt) >= K.staleSeconds {
                sessions.removeValue(forKey: id)
                continue
            }
            if let until = s.settlingUntil, until <= now {
                s.settlingFrom = nil
                s.settlingUntil = nil
            }
            if let due = s.notifyAt, due <= now {
                if s.acknowledged || Self.alertKind(for: s.state) == nil {
                    // Seen, or no longer an alert: nothing left to announce.
                    s.notifyAt = nil
                } else if userPresent {
                    // Deferred, not dropped: the strip is doing the telling
                    // while the user is at the machine. "Seen" is what
                    // acknowledgement decides — an alert never acknowledged is
                    // still unread, so it fires at the first tick that finds
                    // the user gone, however much later that is.
                    s.notifyAt = now.addingTimeInterval(K.notifyDeferRecheckSeconds)
                } else {
                    // The late-drop: a deadline missed by more than the window
                    // means the machine slept through it or this is journal
                    // replay — announcing an old turn now would be noise.
                    s.notifyAt = nil
                    if now.timeIntervalSince(due) <= K.notifyMaxLatenessSeconds,
                       let kind = Self.alertKind(for: s.state) {
                        fired.append(Alert(sessionId: id, agent: s.agent, kind: kind, at: now))
                    }
                }
            }
            sessions[id] = s
        }
        return fired.sorted { $0.sessionId < $1.sessionId }
    }

    public func nextDeadline(after now: Date) -> Date? {
        var deadlines: [Date] = []
        for s in sessions.values {
            if s.pendingDone {
                if let released = s.holdReleasedAt {
                    deadlines.append(released.addingTimeInterval(K.holdGraceSeconds))
                }
                if let expiry = s.helperExpiry(after: now) { deadlines.append(expiry) }
                deadlines.append(s.lastEventAt.addingTimeInterval(K.holdTTLSeconds))
            }
            if s.state == .done {
                deadlines.append(s.stateSince.addingTimeInterval(K.doneVisibleSeconds))
            }
            if s.state == .working, !s.pendingDone, s.agent == .claude, s.agentPid != nil {
                // The abandoned-turn watch: wake when the session becomes
                // eligible for its first registry read, then keep waking on
                // the recheck cadence while it stays eligible. See
                // `abandonCandidates(at:)` and Engine's registry check.
                // Claude only: the registry is Claude Code's.
                let eligibleAt = s.lastEventAt.addingTimeInterval(K.abandonQuietSeconds)
                deadlines.append(eligibleAt > now
                                 ? eligibleAt
                                 : now.addingTimeInterval(K.abandonRecheckSeconds))
            }
            if s.state.isOpenWaiting, s.agent == .claude, s.agentPid != nil {
                // The answered-dialog watch: an approval may fire no hook
                // at all, so open waits are re-checked on the same cadence.
                // Claude only, like the registry it reads.
                deadlines.append(now.addingTimeInterval(K.abandonRecheckSeconds))
            }
            if let settlingUntil = s.settlingUntil { deadlines.append(settlingUntil) }
            if let notifyAt = s.notifyAt { deadlines.append(notifyAt) }
            deadlines.append(s.lastEventAt.addingTimeInterval(K.staleSeconds))
        }
        return deadlines.filter { $0 > now }.min()
    }

    /// The stuck-state fix: the agent's process died, so every session it
    /// hosted is gone — no SessionEnd required.
    public mutating func processExited(pid: Int32) {
        sessions = sessions.filter { $0.value.agentPid != pid }
    }

    /// Startup prune after journal replay: drop sessions whose recorded
    /// process no longer exists, or is no longer that agent's. Sessions
    /// without a pid are left to staleness.
    public mutating func pruneDead(isAlive: (AgentKind, Int32) -> Bool) {
        sessions = sessions.filter { entry in
            entry.value.agentPid.map { isAlive(entry.value.agent, $0) } ?? true
        }
    }

    public var trackedPids: Set<Int32> {
        Set(sessions.values.compactMap(\.agentPid))
    }

    /// Startup scrub after journal replay: a push deadline that is already
    /// long past belonged to the previous app instance — it either fired
    /// there or was abandoned there. Left armed, a present-user defer would
    /// launder its lateness into a fresh deadline and deliver a duplicate
    /// minutes after every restart. Deadlines still inside the lateness
    /// window are kept: those pushes never had their chance.
    public mutating func dropStaleNotifications(now: Date) {
        for (id, var s) in sessions {
            if let due = s.notifyAt, now.timeIntervalSince(due) > K.notifyMaxLatenessSeconds {
                s.notifyAt = nil
                sessions[id] = s
            }
        }
    }

    /// Sessions that look abandoned — a turn with no events, no live
    /// helpers, no background shells for `abandonQuietSeconds` — and can be
    /// checked against Claude Code's own process registry. The read itself
    /// touches the filesystem and lives in the app; a session only reaches
    /// it with a pid to look up, and only a Claude session does: Codex has
    /// no registry, and says its interrupts itself (`Interrupt`).
    public func abandonCandidates(at now: Date) -> [(sessionId: String, pid: Int32)] {
        sessions.values.compactMap { s in
            guard s.agent == .claude, s.state == .working, !s.pendingDone, let pid = s.agentPid,
                  !s.hasLiveHelpers(at: now), s.backgroundIds.isEmpty,
                  now.timeIntervalSince(s.lastEventAt) >= K.abandonQuietSeconds
            else { return nil }
            return (s.id, pid)
        }
    }

    /// The interrupt ending: Esc or Ctrl-C mid-turn fires no hook at all
    /// (11 of 199 recorded prompts ended that way — no Stop, no
    /// idle_prompt, nothing), so the working roll would stand until the 2 h
    /// staleness backstop. When Claude's own registry says the process is
    /// sitting idle at its prompt and the transcript shows no completed
    /// answer, the turn is over and delivered nothing: dark.
    public mutating func abandonTurn(sessionId: String, now: Date) {
        guard var s = sessions[sessionId], s.state == .working, !s.pendingDone else { return }
        set(&s, .idle, now)
        closeTurn(&s, byInterrupt: false, now: now)
        sessions[sessionId] = s
    }

    /// The lost Stop, proven at the source: the registry says idle and the
    /// transcript's final entry is a COMPLETED assistant message
    /// (stop_reason end_turn — observed stamped at the exact second of a
    /// real Stop hook). The turn finished and only its event was lost, so
    /// it takes the same verdict a Stop takes — green, or held behind
    /// still-live helpers — and the "Finished" push that goes with it.
    /// Works during full hook outages, where the idle_prompt rescue (a
    /// hook itself) cannot.
    public mutating func finishTurn(sessionId: String, now: Date) {
        guard var s = sessions[sessionId], s.state == .working, !s.pendingDone else { return }
        applyStopVerdict(&s, now: now)
        closeTurn(&s, byInterrupt: false, now: now)
        updateHoldRelease(&s, now: now)
        sessions[sessionId] = s
    }

    /// The registry said "busy": Claude is genuinely running a turn even
    /// though no hook has arrived — which is what a session whose hooks
    /// died mid-flight looks like: a Ctrl-C can kill hook delivery for the
    /// whole session while the turn keeps working for minutes. Count
    /// it as liveness so the 2 h staleness backstop cannot delete a session
    /// that is demonstrably still working, and so the quiet gate re-arms.
    /// It re-arms nothing else: no state change, no alert, no ack churn.
    public mutating func noteBusy(sessionId: String, now: Date) {
        guard var s = sessions[sessionId], s.state == .working else { return }
        s.lastEventAt = now
        sessions[sessionId] = s
    }

    /// Open waits (question/permission/plan) that can be checked against
    /// the registry for having been ANSWERED: approving a plan can produce
    /// no PostToolUse(ExitPlanMode) hook at all, leaving the wait standing
    /// until the next tool call happens by. The registry stamp is the
    /// approval's footprint.
    public func openWaitCandidates() -> [(sessionId: String, pid: Int32, stateSince: Date)] {
        sessions.values.compactMap { s in
            guard s.agent == .claude, s.state.isOpenWaiting, let pid = s.agentPid else { return nil }
            return (s.id, pid, s.stateSince)
        }
    }

    /// The dialog was answered and the turn is running again — Claude's own
    /// registry says busy with a stamp newer than the dialog itself. Back
    /// to working; `set` disarms the pending push with the state change.
    public mutating func dialogAnswered(sessionId: String, now: Date) {
        guard var s = sessions[sessionId], s.state.isOpenWaiting else { return }
        set(&s, .working, now)
        sessions[sessionId] = s
    }

    /// A waiting/done LED is an unread notification: seeing it clears it.
    /// The app calls this when the hosting app gains focus, or on any input
    /// while it is already frontmost. Returns what was cleared so the app
    /// can persist it — an ack must survive a restart, or the replayed
    /// journal resurrects the alert and its push.
    ///
    /// `frontTTY` is the visible TAB, when the app could learn it: every
    /// tab of a terminal shares one bundle id, so bundle alone would ack
    /// sessions the user cannot even see. When both
    /// sides are known and disagree, the alert is NOT acknowledged; any
    /// unknown fails open to the old app-level behaviour, so a terminal
    /// that cannot be asked, a denied permission, or a session with no tty
    /// never strands an alert unacknowledgeable.
    /// `hostIsFocusable` answers whether a recorded host bundle id names an
    /// app the user could actually bring to the front. A session the Claude
    /// Code daemon hosts has no focusable host at all: the process chain dies
    /// at the daemon, so the host is recorded as nothing — and "nothing"
    /// matches no frontmost app, which would strand such an alert until the
    /// 2 h backstop with no tab and no keystroke able to clear it. An
    /// unfocusable host is therefore an unknown host: it acknowledges on
    /// presence, and tab scoping is meaningless without a terminal to scope
    /// inside. Same fail-open direction as every other unknown here.
    public mutating func acknowledgeAlerts(hostBundleId: String,
                                           frontTTY: String? = nil,
                                           hostIsFocusable: (String) -> Bool = { _ in true })
    -> [AckRecord] {
        var acked: [AckRecord] = []
        for (id, original) in sessions {
            var s = original
            guard !s.acknowledged else { continue }
            if let host = s.hostBundleId, hostIsFocusable(host) {
                guard host == hostBundleId else { continue }
                if let front = frontTTY, let tab = s.tty, front != tab { continue }
            }
            switch s.state {
            case .waiting, .done:
                s.acknowledged = true
                s.notifyAt = nil
                // Seeing it is the whole model: stop pretending it has not
                // happened yet, rather than holding the old state red.
                s.settlingFrom = nil
                s.settlingUntil = nil
                acked.append(AckRecord(sessionId: id, stateSince: s.stateSince))
                sessions[id] = s
            case .idle, .working:
                break
            }
        }
        return acked
    }
}

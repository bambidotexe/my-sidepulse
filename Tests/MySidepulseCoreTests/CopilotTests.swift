import XCTest
@testable import MySidepulseCore

/// GitHub Copilot CLI: the hook file MySidepulse owns, its camelCase payloads,
/// the subagent filter, and the sequences recorded on this Mac replayed
/// through the store.
final class CopilotTests: XCTestCase {
    let cli = "/Applications/MySidepulse.app/Contents/MacOS/mysidepulse"
    let t0 = Date(timeIntervalSince1970: 1_787_652_000)

    func line(_ event: String?, _ body: [String: Any], _ t: TimeInterval = 0) -> JournalEvent {
        Trim.copilotEvent(fromHookPayload: try! JSONSerialization.data(withJSONObject: body),
                          named: event, loggedAt: t0.addingTimeInterval(t))
    }

    // MARK: ~/.copilot/hooks/mysidepulse.json

    /// Seven entries in the `exec` form, no shell, each naming its event,
    /// since a camelCase payload names none.
    func testTheFileHoldsSevenExecEntriesThatNameTheirEvent() throws {
        let file = HookConfig.copilotFile(cliPath: cli)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(file))
        XCTAssertEqual(file["version"] as? Int, 1)
        let hooks = try XCTUnwrap(file["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), Set(HookConfig.copilotEvents))
        for event in HookConfig.copilotEvents {
            let entries = try XCTUnwrap(hooks[event] as? [[String: Any]], event)
            XCTAssertEqual(entries.count, 1, event)
            let entry = entries[0]
            XCTAssertEqual(entry["type"] as? String, "command", event)
            XCTAssertEqual(entry["exec"] as? String, cli, event)
            XCTAssertEqual(entry["args"] as? [String], ["hook", "--agent", "copilot", "--event", event], event)
            XCTAssertEqual(entry["timeoutSec"] as? Int, 5, event)
            XCTAssertNil(entry["bash"], "no shell between Copilot and the hook")
            XCTAssertNil(entry["command"])
            XCTAssertTrue(HookConfig.isOurCopilotEntry(entry), event)
        }
        XCTAssertEqual(Set(file.keys), ["version", "hooks"])
    }

    func testAnEntryIsOursByItsExecAndItsArguments() {
        let ours: [String: Any] = ["type": "command", "exec": "/Elsewhere/MySidepulse.app/Contents/MacOS/mysidepulse",
                                   "args": ["hook", "--agent", "copilot", "--event", "agentStop"], "timeoutSec": 5]
        XCTAssertTrue(HookConfig.isOurCopilotEntry(ours), "another copy's entry is still ours")
        var otherBinary = ours; otherBinary["exec"] = "/usr/local/bin/notify"
        var otherAgent = ours; otherAgent["args"] = ["hook", "--agent", "codex"]
        var short = ours; short["args"] = ["hook"]
        let shell: [String: Any] = ["type": "command", "bash": "\(cli) hook --agent copilot --event agentStop"]
        for entry in [otherBinary, otherAgent, short, shell] {
            XCTAssertFalse(HookConfig.isOurCopilotEntry(entry), "\(entry)")
        }
        XCTAssertFalse(HookConfig.isOurCopilotEntry("not an entry"))
    }

    /// The file is MySidepulse's alone: rewritten or deleted only while
    /// nothing in it is anyone else's.
    func testTheFileIsOursOnlyWhileEverythingInItIs() {
        XCTAssertTrue(HookConfig.copilotFileIsOurs(HookConfig.copilotFile(cliPath: cli)))
        XCTAssertTrue(HookConfig.copilotFileIsOurs(HookConfig.copilotFile(cliPath: "/Old/MySidepulse.app/Contents/MacOS/mysidepulse")))
        XCTAssertTrue(HookConfig.copilotFileIsOurs([:]), "an empty object holds nothing of anyone's")
        var foreign = HookConfig.copilotFile(cliPath: cli)
        var hooks = foreign["hooks"] as! [String: Any]
        hooks["agentStop"] = (hooks["agentStop"] as! [Any]) + [["type": "command", "bash": "say done"]]
        foreign["hooks"] = hooks
        XCTAssertFalse(HookConfig.copilotFileIsOurs(foreign))
        var disabled = HookConfig.copilotFile(cliPath: cli)
        disabled["disableAllHooks"] = true
        XCTAssertFalse(HookConfig.copilotFileIsOurs(disabled), "a key someone added is theirs")
        XCTAssertFalse(HookConfig.copilotFileIsOurs(["hooks": "not an object"]))
        XCTAssertFalse(HookConfig.copilotFileIsOurs(["hooks": ["agentStop": "not a list"]]))
    }

    /// Set up means every event runs this bundle's CLI with its own name.
    func testTheCountIsTheEventsThatRunThisCLI() {
        XCTAssertEqual(HookConfig.copilotEventsSetUp(in: HookConfig.copilotFile(cliPath: cli), cliPath: cli), 7)
        XCTAssertEqual(HookConfig.copilotEventsSetUp(
            in: HookConfig.copilotFile(cliPath: "/Old/MySidepulse.app/Contents/MacOS/mysidepulse"), cliPath: cli), 0)
        var missing = HookConfig.copilotFile(cliPath: cli)
        var hooks = missing["hooks"] as! [String: Any]
        hooks.removeValue(forKey: "sessionEnd")
        hooks["agentStop"] = hooks["notification"]
        missing["hooks"] = hooks
        XCTAssertEqual(HookConfig.copilotEventsSetUp(in: missing, cliPath: cli), 5,
                       "an absent event and an entry naming another event do not count")
        XCTAssertEqual(HookConfig.copilotEventsSetUp(in: [:], cliPath: cli), 0)
        XCTAssertEqual(HookConfig.setUpCount(for: .copilot), 7)
    }

    /// `disableAllHooks` turns every user hook off, from `settings.json` or
    /// from `config.json`, whose first lines are `//` comments.
    func testDisableAllHooksIsReadFromEitherFileCommentsAndAll() {
        let config = """
        // User settings belong in settings.json.
        // This file is managed automatically.
        {
          "banner": "https://example.com/a//b",
            // a comment further down
          "disableAllHooks": true
        }
        """
        XCTAssertTrue(HookConfig.copilotHooksDisabled(settingsText: nil, configText: config))
        XCTAssertTrue(HookConfig.copilotHooksDisabled(settingsText: #"{"disableAllHooks": true}"#, configText: nil))
        XCTAssertFalse(HookConfig.copilotHooksDisabled(settingsText: #"{"disableAllHooks": false}"#, configText: "{}"))
        XCTAssertFalse(HookConfig.copilotHooksDisabled(settingsText: #"{"disableAllHooks": "true"}"#, configText: nil))
        XCTAssertFalse(HookConfig.copilotHooksDisabled(settingsText: nil, configText: nil))
        XCTAssertFalse(HookConfig.copilotHooksDisabled(settingsText: "{not json", configText: "// only\n"))
    }

    // MARK: the payloads

    /// The event comes from `--event`; the body is camelCase, but for
    /// `notification_type`; nothing of a prompt, a tool's input or output,
    /// or a message reaches the line.
    func testThePayloadIsReadFromItsEventNameAndItsCamelCaseBody() throws {
        let names: [String: HookEventName] = [
            "sessionStart": .sessionStart, "userPromptSubmitted": .userPromptSubmit,
            "postToolUse": .postToolUse, "postToolUseFailure": .postToolUseFailure,
            "notification": .notification, "agentStop": .stop, "sessionEnd": .sessionEnd,
        ]
        XCTAssertEqual(Set(names.keys), Set(HookConfig.copilotEvents))
        for (name, event) in names {
            XCTAssertEqual(line(name, ["sessionId": "c1"]).event, event, name)
            XCTAssertEqual(line(name, ["sessionId": "c1"]).agent, .copilot, name)
        }
        let body: [String: Any] = [
            "sessionId": "6c7e446d", "timestamp": 1_790_379_605_505, "cwd": "/tmp/repo1",
            "toolName": "bash", "toolArgs": ["command": "echo SECRET-ARGS"],
            "toolResult": ["resultType": "success", "textResultForLlm": "SECRET-RESULT"],
            "prompt": "SECRET-PROMPT", "initialPrompt": "SECRET-PROMPT", "source": "new",
            "message": "SECRET-MESSAGE", "title": "Permission needed",
            "notification_type": "permission_prompt", "hook_event_name": "Notification",
            "transcriptPath": "/Users/u/.copilot/session-state/6c7e446d/events.jsonl",
            "stopReason": "end_turn", "stop_hook_active": false, "reason": "complete",
        ]
        let stop = line("agentStop", body)
        XCTAssertEqual(stop.sessionId, "6c7e446d")
        XCTAssertEqual(stop.cwd, "/tmp/repo1")
        XCTAssertEqual(stop.toolName, "bash")
        XCTAssertEqual(stop.notificationType, "permission_prompt")
        XCTAssertEqual(stop.source, "new")
        XCTAssertEqual(stop.reason, "complete")
        XCTAssertEqual(stop.stopHookActive, false)
        XCTAssertEqual(stop.transcriptPath, "/Users/u/.copilot/session-state/6c7e446d/events.jsonl")
        XCTAssertNil(stop.turnId, "Copilot names no turn")
        let text = String(decoding: try Trim.cappedLine(stop), as: UTF8.self)
        XCTAssertFalse(text.contains("SECRET"), text)
        XCTAssertNil(line("postToolUse", body).transcriptPath, "the path rides the turn's boundaries only")
        XCTAssertEqual(line("userPromptSubmitted", ["session_id": "c2"]).sessionId, "c2", "snake case is taken too")
    }

    /// An event the file does not name is a `ParseError`, and keeps its name,
    /// never its body. No flag: the payload's own name, when it has one.
    func testAnUnknownEventIsAParseErrorThatKeepsNoBody() {
        let unknown = line("preToolUse", ["sessionId": "c1", "toolArgs": ["command": "SECRET"]])
        XCTAssertEqual(unknown.event, .parseError)
        XCTAssertEqual(unknown.agent, .copilot)
        XCTAssertFalse(unknown.rawPrefix?.contains("SECRET") ?? false)
        XCTAssertEqual(line(nil, ["sessionId": "c1", "prompt": "SECRET"]).event, .parseError)
        XCTAssertEqual(line(nil, ["sessionId": "c1", "hook_event_name": "Notification",
                                  "notification_type": "elicitation_dialog"]).event, .notification)
        let garbage = Trim.copilotEvent(fromHookPayload: Data("{oops".utf8), named: "agentStop", loggedAt: t0)
        XCTAssertEqual(garbage.event, .parseError)
    }

    // MARK: the subagent filter

    func testTheSessionStateRootHonoursCopilotHome() {
        XCTAssertEqual(CopilotSessionState.root(environment: [:], home: "/Users/u"), "/Users/u/.copilot/session-state")
        XCTAssertEqual(CopilotSessionState.root(environment: ["COPILOT_HOME": "/x/cop"], home: "/Users/u"),
                       "/x/cop/session-state")
        XCTAssertEqual(CopilotSessionState.root(environment: ["COPILOT_HOME": ""], home: "/Users/u"),
                       "/Users/u/.copilot/session-state")
        XCTAssertEqual(CopilotSessionState.transcriptPath(root: "/r", sessionId: "c1"), "/r/c1/events.jsonl")
    }

    /// A subagent's own prompt and stop carry the subagent's id, which has
    /// no folder: its stop must not end the parent's turn.
    func testASessionWithoutItsFolderIsASubagentsAndWritesNothing() {
        let root = "/r/session-state"
        let folders: Set<String> = [root, "\(root)/parent"]
        let exists: (String) -> Bool = { folders.contains($0) }
        XCTAssertTrue(CopilotSessionState.keeps(sessionId: "parent", root: root, directoryExists: exists))
        XCTAssertFalse(CopilotSessionState.keeps(sessionId: "819c2c3e", root: root, directoryExists: exists))
        XCTAssertFalse(CopilotSessionState.keeps(sessionId: "../parent", root: root, directoryExists: { _ in true }),
                       "an id that is not one folder name names no folder")
        XCTAssertTrue(CopilotSessionState.keeps(sessionId: nil, root: root, directoryExists: exists),
                      "a line of no session (a ParseError) is kept")
        XCTAssertTrue(CopilotSessionState.keeps(sessionId: "819c2c3e", root: "/elsewhere", directoryExists: exists),
                      "no root: nothing to tell a subagent by")

        XCTAssertNil(CopilotSessionState.line(line("agentStop", ["sessionId": "819c2c3e"]), root: root, directoryExists: exists))
        let prompt = CopilotSessionState.line(line("userPromptSubmitted", ["sessionId": "parent"]), root: root, directoryExists: exists)
        XCTAssertEqual(prompt?.transcriptPath, "\(root)/parent/events.jsonl", "the session's own events file")
        let stop = CopilotSessionState.line(line("agentStop", ["sessionId": "parent", "transcriptPath": "/named.jsonl"]),
                                            root: root, directoryExists: exists)
        XCTAssertEqual(stop?.transcriptPath, "/named.jsonl", "a path the payload names is kept")
        let tool = CopilotSessionState.line(line("postToolUse", ["sessionId": "parent"]), root: root, directoryExists: exists)
        XCTAssertNotNil(tool)
        XCTAssertNil(tool?.transcriptPath)
    }

    // MARK: the recorded sequences

    /// `copilot -p` (run 1): the prompt comes first, then the lazy start,
    /// which changes nothing; the stop finishes the turn; `sessionEnd`
    /// `complete` closes the session with every `-p` turn and forgets it, as
    /// every agent's `SessionEnd` does.
    func testAPromptModeRunWorksFinishesAndIsForgotten() {
        var store = SessionStore()
        store.apply(line("userPromptSubmitted", ["sessionId": "c1", "cwd": "/tmp/repo1"], 0))
        XCTAssertEqual(store.sessions["c1"]?.state, .working)
        XCTAssertEqual(store.sessions["c1"]?.agent, .copilot)
        store.apply(line("sessionStart", ["sessionId": "c1", "source": "new"], 0.18))
        XCTAssertEqual(store.sessions["c1"]?.state, .working, "the lazy start does not undo the prompt")
        store.apply(line("postToolUse", ["sessionId": "c1", "toolName": "bash"], 3))
        XCTAssertEqual(store.sessions["c1"]?.state, .working)
        store.apply(line("agentStop", ["sessionId": "c1", "stopReason": "end_turn"], 6))
        XCTAssertEqual(store.sessions["c1"]?.state, .done)
        store.apply(line("sessionEnd", ["sessionId": "c1", "reason": "complete"], 6.1))
        XCTAssertNil(store.sessions["c1"])
    }

    /// Interactive with a permission prompt (run 2): the notification is
    /// the wait, and approving it fires nothing; the next tool's end is the
    /// answer.
    func testAPermissionPromptWaitsUntilTheNextToolEnds() {
        var store = SessionStore()
        store.apply(line("userPromptSubmitted", ["sessionId": "c1"], 0))
        store.apply(line("sessionStart", ["sessionId": "c1", "source": "new"], 0.2))
        store.apply(line("notification", ["sessionId": "c1", "notification_type": "permission_prompt"], 2))
        XCTAssertEqual(store.sessions["c1"]?.state, .waiting(.permission))
        let pushes = store.tick(now: t0.addingTimeInterval(2 + K.notifyDebounceSeconds))
        XCTAssertEqual(pushes.map(\.kind), [.needsYou(.permission)])
        XCTAssertEqual(pushes.map(\.agent), [.copilot])
        store.apply(line("postToolUse", ["sessionId": "c1", "toolName": "bash"], 30))
        XCTAssertEqual(store.sessions["c1"]?.state, .working)
        store.apply(line("agentStop", ["sessionId": "c1"], 31))
        XCTAssertEqual(store.sessions["c1"]?.state, .done)
    }

    /// An `ask_user` question (run 3) is Copilot's `elicitation_dialog`: a
    /// question, where Claude Code's is an MCP form and stays a permission.
    func testAnAskUserQuestionIsAQuestion() {
        var store = SessionStore()
        store.apply(line("userPromptSubmitted", ["sessionId": "c1"], 0))
        store.apply(line("notification", ["sessionId": "c1", "notification_type": "elicitation_dialog"], 2))
        XCTAssertEqual(store.sessions["c1"]?.state, .waiting(.question))
        let pushes = store.tick(now: t0.addingTimeInterval(2 + K.notifyDebounceSeconds))
        XCTAssertEqual(pushes.map(\.kind), [.needsYou(.question)])
        XCTAssertEqual(pushes.map { AlertCopy.title(for: $0.agent) }, ["GitHub Copilot"])
        XCTAssertEqual(pushes.map { AlertCopy.message(for: $0.kind) }, ["Asking you something"])
        store.apply(line("postToolUse", ["sessionId": "c1", "toolName": "ask_user"], 30))
        XCTAssertEqual(store.sessions["c1"]?.state, .working)
        store.apply(line("notification", ["sessionId": "c1", "notification_type": "shell_completed"], 40))
        XCTAssertEqual(store.sessions["c1"]?.state, .working, "a shell's end is news, not a request")

        var claude = SessionStore()
        claude.apply(ev(.userPromptSubmit, 0))
        claude.apply(ev(.notification, 1, ntype: "elicitation_dialog"))
        XCTAssertEqual(claude.sessions["s1"]?.state, .waiting(.permission))
    }

    /// A Claude Code start still resets the session: the lazy start is
    /// Copilot's alone.
    func testOnlyCopilotsStartChangesNothing() {
        var store = SessionStore()
        store.apply(ev(.userPromptSubmit, 0))
        store.apply(ev(.sessionStart, 1, source: "resume"))
        XCTAssertEqual(store.sessions["s1"]?.state, .idle)
    }

    // MARK: the events.jsonl check

    func at(_ t: TimeInterval) -> Date { t0.addingTimeInterval(t) }
    let transcript = "/Users/u/.copilot/session-state/c1/events.jsonl"

    /// A quiet working Copilot session is checked against its `events.jsonl`,
    /// pid or not; the registry rescue stays Claude's and the rollout check
    /// Codex's.
    func testAQuietCopilotSessionIsACandidate() {
        var store = SessionStore()
        store.apply(line("userPromptSubmitted", ["sessionId": "c1", "transcriptPath": transcript], 0))
        store.apply(line("postToolUse", ["sessionId": "c1", "toolName": "bash"], 1))
        var withPid = line("userPromptSubmitted", ["sessionId": "c2"], 0)
        withPid.agentPid = 4242
        store.apply(withPid)
        var codex = ev(.userPromptSubmit, 0, sid: "x1", turn: "t1")
        codex.agent = .codex
        store.apply(codex)

        XCTAssertTrue(store.copilotCandidates(at: at(5)).isEmpty, "not quiet yet")
        let quiet = store.copilotCandidates(at: at(1 + K.abandonQuietSeconds))
        XCTAssertEqual(quiet.map(\.sessionId), ["c1", "c2"])
        XCTAssertEqual(quiet.first?.transcriptPath, transcript)
        XCTAssertNil(quiet.last?.transcriptPath)
        XCTAssertEqual(store.copilotCandidates(at: at(2), quietSeconds: 0).map(\.sessionId), ["c1", "c2"],
                       "the launch check has no quiet gate")
        XCTAssertEqual(store.codexCandidates(at: at(100)).map(\.sessionId), ["x1"])
        XCTAssertTrue(store.abandonCandidates(at: at(100)).isEmpty, "a Copilot pid has no Claude registry")

        store.apply(line("agentStop", ["sessionId": "c1"], 30))
        store.apply(line("notification", ["sessionId": "c2", "notification_type": "permission_prompt"], 30))
        XCTAssertTrue(store.copilotCandidates(at: at(100)).isEmpty, "a finished or waiting session is not one")
    }

    func testNextDeadlineCoversTheCopilotRecheck() {
        var store = SessionStore()
        store.apply(line("userPromptSubmitted", ["sessionId": "c1"], 0))
        store.apply(line("postToolUse", ["sessionId": "c1", "toolName": "bash"], 1))
        XCTAssertEqual(store.nextDeadline(after: at(5)), at(1 + K.abandonQuietSeconds),
                       "wake when the session becomes a candidate")
        XCTAssertEqual(store.nextDeadline(after: at(100)), at(100 + K.abandonRecheckSeconds),
                       "then on the recheck cadence, with no pid: the file is the session's")
    }

    /// `abort` is the interrupt: dark, no alert, no push. The agentStop
    /// mirror is the lost `Stop`, with the push a `Stop` earns.
    func testAnAbortGoesDarkAndAnAgentStopFinishes() {
        var store = SessionStore()
        store.apply(line("userPromptSubmitted", ["sessionId": "c1"], 0))
        XCTAssertEqual(store.abandonTurn(sessionId: "c1", now: at(40), endedAt: at(30)), at(30))
        XCTAssertEqual(store.sessions["c1"]?.state, .idle)
        XCTAssertNil(store.sessions["c1"]?.notifyAt)
        XCTAssertTrue(store.tick(now: at(30 + K.notifyDebounceSeconds + 1)).isEmpty)

        store.apply(line("userPromptSubmitted", ["sessionId": "c2"], 100))
        XCTAssertEqual(store.finishTurn(sessionId: "c2", now: at(130), endedAt: at(125)), at(125))
        let pushed = store.tick(now: at(125 + K.notifyDebounceSeconds))
        XCTAssertEqual(pushed.map(\.kind), [.finished])
        XCTAssertEqual(pushed.map(\.agent), [.copilot])
    }

    /// `session.error` is the `StopFailure` Copilot never sends: amber with
    /// the error reason and its push, as of the marker's stamp; a new prompt
    /// is work again.
    func testAFailedTurnTakesTheStopFailureOutcome() {
        var store = SessionStore()
        store.apply(line("userPromptSubmitted", ["sessionId": "c1"], 0))
        XCTAssertEqual(store.failTurn(sessionId: "c1", now: at(40), endedAt: at(30)), at(30))
        XCTAssertEqual(store.sessions["c1"]?.state, .waiting(.error))
        XCTAssertEqual(store.sessions["c1"]?.stateSince, at(30))
        let pushed = store.tick(now: at(30 + K.notifyDebounceSeconds))
        XCTAssertEqual(pushed.map(\.kind), [.needsYou(.error)])
        XCTAssertEqual(pushed.map(\.agent), [.copilot])
        XCTAssertNil(store.failTurn(sessionId: "c1", now: at(60), endedAt: at(30)),
                     "only a working turn fails: a verdict that changes nothing has nothing to record")
        store.apply(line("userPromptSubmitted", ["sessionId": "c1"], 70))
        XCTAssertEqual(store.sessions["c1"]?.state, .working)

        var stopFailure = SessionStore()
        stopFailure.apply(line("userPromptSubmitted", ["sessionId": "c1"], 0))
        var hook = JournalEvent(loggedAt: at(30), event: .stopFailure)
        hook.sessionId = "c1"
        stopFailure.apply(hook)
        var failed = SessionStore()
        failed.apply(line("userPromptSubmitted", ["sessionId": "c1"], 0))
        failed.failTurn(sessionId: "c1", now: at(30), endedAt: at(30))
        XCTAssertEqual(failed.sessions["c1"]?.state, stopFailure.sessions["c1"]?.state,
                       "the outcome a StopFailure hook gives")
        XCTAssertEqual(failed.sessions["c1"]?.notifyAt, stopFailure.sessions["c1"]?.notifyAt)

        var late = SessionStore()
        late.apply(line("userPromptSubmitted", ["sessionId": "c1"], 0))
        let found = at(30 + K.notifyMaxLatenessSeconds + K.notifyDebounceSeconds + 30)
        late.failTurn(sessionId: "c1", now: found, endedAt: at(30))
        XCTAssertTrue(late.tick(now: found).isEmpty, "a failure found long after it pushes nothing")
        XCTAssertEqual(late.sessions["c1"]?.state, .waiting(.error))

        var held = SessionStore()
        held.apply(line("userPromptSubmitted", ["sessionId": "c1"], 0))
        held.apply(line("agentStop", ["sessionId": "c1"], 5))
        XCTAssertNil(held.failTurn(sessionId: "c1", now: at(40), endedAt: at(30)), "a finished turn does not fail")
    }

    /// The failure is journaled as `turn-failed`, stamped when it took
    /// effect: replaying the lines gives the session the live store holds,
    /// and the live store reading its own line back changes nothing.
    func testAJournaledFailureReplaysAsTheSameVerdict() {
        let turn = [line("userPromptSubmitted", ["sessionId": "c1"], 0),
                    line("postToolUse", ["sessionId": "c1", "toolName": "bash"], 5)]
        func replay(_ lines: [JournalEvent]) -> SessionStore {
            var s = SessionStore()
            for l in lines { s.apply(l) }
            return s
        }
        var live = replay(turn)
        let failedAt = live.failTurn(sessionId: "c1", now: at(60), endedAt: at(40))
        XCTAssertEqual(failedAt, at(40))
        var verdict = JournalEvent(loggedAt: at(40), event: .verdict)
        verdict.sessionId = "c1"
        verdict.verdict = TurnVerdict.turnFailed.rawValue
        XCTAssertEqual(TurnVerdict.turnFailed.rawValue, "turn-failed")
        XCTAssertEqual(replay(turn + [verdict]).sessions["c1"], live.sessions["c1"])
        let before = live.sessions["c1"]
        live.apply(verdict)
        XCTAssertEqual(live.sessions["c1"], before, "the app's own line read back is a no-op")

        var moved = replay(turn + [line("postToolUse", ["sessionId": "c1", "toolName": "bash"], 50)])
        moved.apply(verdict)
        XCTAssertEqual(moved.sessions["c1"]?.state, .working, "a main-agent event after the stamp wins")
        var ghost = SessionStore()
        ghost.apply(verdict)
        XCTAssertTrue(ghost.sessions.isEmpty, "a verdict never creates a session")
    }

    // MARK: a wait cancelled with Ctrl+C

    func waiting(_ reason: String, at t: TimeInterval = 2) -> SessionStore {
        var store = SessionStore()
        store.apply(line("userPromptSubmitted", ["sessionId": "c1", "transcriptPath": transcript], 0))
        store.apply(line("notification", ["sessionId": "c1", "notification_type": reason], t))
        return store
    }

    /// A Copilot session waiting on a permission or a question is checked
    /// too, its quiet gate counted from when the wait began; a failed turn's
    /// `waiting(error)` never is, nor is a working session.
    func testAnOpenCopilotWaitIsAWaitCandidate() {
        var store = waiting("permission_prompt")
        store.apply(line("userPromptSubmitted", ["sessionId": "c2"], 0))
        store.apply(line("userPromptSubmitted", ["sessionId": "c3"], 0))
        store.failTurn(sessionId: "c3", now: at(1), endedAt: at(1))
        XCTAssertEqual(store.sessions["c3"]?.state, .waiting(.error))
        var claude = ev(.userPromptSubmit, 0, sid: "s1", pid: 42)
        claude.agent = .claude
        store.apply(claude)
        store.apply(ev(.notification, 2, sid: "s1", ntype: "permission_prompt"))

        XCTAssertTrue(store.copilotWaitCandidates(at: at(10)).isEmpty, "not quiet yet")
        let quiet = store.copilotWaitCandidates(at: at(2 + K.abandonQuietSeconds))
        XCTAssertEqual(quiet.map(\.sessionId), ["c1"], "not a working session, an error or Claude's")
        XCTAssertEqual(quiet.first?.transcriptPath, transcript)
        XCTAssertEqual(quiet.first?.waitSince, at(2))
        XCTAssertEqual(store.copilotWaitCandidates(at: at(3), quietSeconds: 0).map(\.sessionId), ["c1"],
                       "the launch check has no quiet gate")
        XCTAssertEqual(waiting("elicitation_dialog").copilotWaitCandidates(at: at(100)).map(\.sessionId), ["c1"],
                       "a question too")
    }

    func testNextDeadlineCoversTheCopilotWaitRecheck() {
        let store = waiting("permission_prompt", at: 5)
        XCTAssertEqual(store.nextDeadline(after: at(5 + K.notifyDebounceSeconds)), at(5 + K.abandonQuietSeconds),
                       "wake when the wait becomes a candidate")
        XCTAssertEqual(store.nextDeadline(after: at(100)), at(100 + K.abandonRecheckSeconds),
                       "then on the recheck cadence")
    }

    /// Ctrl+C at a permission prompt: the file's `abort`, stamped after the
    /// wait began, ends the turn as a working turn's abort does: dark, the
    /// push the wait armed disarmed, the turn closed. A question the same.
    func testAWaitCancelledWithCtrlCGoesDarkWithoutAPush() {
        var store = waiting("permission_prompt")
        XCTAssertEqual(store.abandonWait(sessionId: "c1", now: at(40), endedAt: at(8)), at(8))
        XCTAssertEqual(store.sessions["c1"]?.state, .idle)
        XCTAssertEqual(store.sessions["c1"]?.stateSince, at(8))
        XCTAssertNil(store.sessions["c1"]?.notifyAt)
        XCTAssertTrue(store.tick(now: at(2 + K.notifyDebounceSeconds + 30)).isEmpty, "no push")

        var question = waiting("elicitation_dialog")
        XCTAssertEqual(question.abandonWait(sessionId: "c1", now: at(40), endedAt: at(8)), at(8))
        XCTAssertEqual(question.sessions["c1"]?.state, .idle)

        var early = waiting("permission_prompt")
        XCTAssertNil(early.abandonWait(sessionId: "c1", now: at(40), endedAt: at(2)),
                     "an abort from before the wait began is another turn's")
        XCTAssertEqual(early.sessions["c1"]?.state, .waiting(.permission))

        var working = SessionStore()
        working.apply(line("userPromptSubmitted", ["sessionId": "c1"], 0))
        XCTAssertNil(working.abandonWait(sessionId: "c1", now: at(40), endedAt: at(8)), "a wait only")
        var failed = SessionStore()
        failed.apply(line("userPromptSubmitted", ["sessionId": "c1"], 0))
        failed.failTurn(sessionId: "c1", now: at(1), endedAt: at(1))
        XCTAssertNil(failed.abandonWait(sessionId: "c1", now: at(40), endedAt: at(8)), "an error is not an open wait")
        XCTAssertEqual(failed.sessions["c1"]?.state, .waiting(.error))
    }

    /// Journaled as `turn-abandoned`: replaying the lines gives the session
    /// the live store holds, reading the line back changes nothing, and a
    /// line stamped before the wait began changes nothing either.
    func testAnAbandonedWaitReplaysAsTheSameVerdict() {
        let lines = [line("userPromptSubmitted", ["sessionId": "c1"], 0),
                     line("notification", ["sessionId": "c1", "notification_type": "permission_prompt"], 2)]
        func replay(_ extra: [JournalEvent]) -> SessionStore {
            var s = SessionStore()
            for l in lines + extra { s.apply(l) }
            return s
        }
        func verdict(_ t: TimeInterval) -> JournalEvent {
            var e = JournalEvent(loggedAt: at(t), event: .verdict)
            e.sessionId = "c1"
            e.verdict = TurnVerdict.turnAbandoned.rawValue
            return e
        }
        var live = replay([])
        XCTAssertEqual(live.abandonWait(sessionId: "c1", now: at(40), endedAt: at(8)), at(8))
        XCTAssertEqual(replay([verdict(8)]).sessions["c1"], live.sessions["c1"])
        let before = live.sessions["c1"]
        live.apply(verdict(8))
        XCTAssertEqual(live.sessions["c1"], before, "the app's own line read back is a no-op")
        XCTAssertEqual(replay([verdict(1)]).sessions["c1"]?.state, .waiting(.permission),
                       "a verdict from before the wait began is not about it")

        var claude = SessionStore()
        claude.apply(ev(.userPromptSubmit, 0, sid: "c1", pid: 42))
        claude.apply(ev(.notification, 2, sid: "c1", ntype: "permission_prompt"))
        claude.apply(verdict(8))
        XCTAssertEqual(claude.sessions["c1"]?.state, .waiting(.permission), "only Copilot abandons a wait")
    }
}

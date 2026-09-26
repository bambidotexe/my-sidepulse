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
}

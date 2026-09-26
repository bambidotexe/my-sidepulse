import XCTest
@testable import MySidepulsePlatform
@testable import MySidepulseCore

final class HookCommandTests: XCTestCase {
    func tempJournal() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mysidepulse-hook-\(UUID().uuidString)/journal.jsonl")
    }

    func testHookWritesEnrichedTrimmedLine() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let payload = #"{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Bash","tool_input":{"command":"ls"}}"#
        let origin = ProcWalk.Origin(agentPid: 4242, hostAppPid: 99, hostBundlePath: nil)
        let code = HookCommand.run(input: Data(payload.utf8), environment: [:],
                                   journalURL: url, now: Date(), origin: origin)
        XCTAssertEqual(code, 0)
        let line = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").first
        let e = try XCTUnwrap(JournalCodec.decodeLine(Data(String(line!).utf8)))
        XCTAssertEqual(e.event, .preToolUse)
        XCTAssertEqual(e.toolName, "Bash")
        XCTAssertEqual(e.agentPid, 4242)
        XCTAssertFalse(String(line!).contains("tool_input"), "bodies must be dropped")
    }

    /// The hook records the TAB, not Claude's controlling terminal: a session
    /// hosted on a daemon pty must journal no tty at all, or the ack scopes
    /// itself to a tab that does not exist — which once left a real alert
    /// green and unacknowledgeable for 4 m 58 s.
    func testTheJournalledTTYIsTheTabAndNothingElse() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let payload = #"{"hook_event_name":"Stop","session_id":"s1"}"#
        func line(origin: ProcWalk.Origin) throws -> JournalEvent {
            try? FileManager.default.removeItem(at: url)
            XCTAssertEqual(HookCommand.run(input: Data(payload.utf8), environment: [:],
                                           journalURL: url, now: Date(), origin: origin), 0)
            let raw = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").first
            return try XCTUnwrap(JournalCodec.decodeLine(Data(String(raw!).utf8)))
        }
        let tab = try line(origin: ProcWalk.Origin(agentPid: 4242, hostAppPid: 99,
                                                   hostBundlePath: nil, tabTTY: "ttys002"))
        XCTAssertEqual(tab.tty, "ttys002")
        let pty = try line(origin: ProcWalk.Origin(agentPid: 25408, hostAppPid: 5713,
                                                   hostBundlePath: nil, tabTTY: nil))
        XCTAssertNil(pty.tty, "a pty with no window behind it is no tab")
    }

    func testDisableEnvSkipsWriting() {
        let url = tempJournal()
        let code = HookCommand.run(input: Data("{}".utf8), environment: ["MYSIDEPULSE_DISABLE": "1"],
                                   journalURL: url, now: Date(), origin: nil)
        XCTAssertEqual(code, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// Spec §1's 8 MB cap: a pathological payload must not be trusted past it.
    /// Truncated JSON parses as garbage, so the honest record is a ParseError
    /// line — and the hook still exits 0, because it always exits 0.
    func testAPayloadPastTheCapBecomesAParseErrorNotAJournalledEvent() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var payload = Data(#"{"hook_event_name":"Stop","session_id":"s1","filler":""#.utf8)
        payload.append(Data(repeating: UInt8(ascii: "x"), count: K.hookStdinMaxBytes))
        payload.append(Data(#""}"#.utf8))
        XCTAssertEqual(HookCommand.run(input: payload, environment: [:],
                                       journalURL: url, now: Date(), origin: nil), 0)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("ParseError"), "an over-cap payload is not a trustable event")
        XCTAssertLessThanOrEqual(text.utf8.count, K.journalLineMaxBytes + 1,
                                 "the journal line itself must stay capped")
    }

    // MARK: the command line

    /// Every form of `hook` is read, and nothing it is given is an error:
    /// an unknown agent or a flag without its value is simply not there.
    func testTheArgumentsAreReadAndNoneOfThemFails() {
        func read(_ args: [String]) -> HookCommand.Arguments { HookCommand.Arguments(args) }
        XCTAssertEqual(read(["hook"]), HookCommand.Arguments(agent: nil, event: nil))
        XCTAssertEqual(read(["hook", "--agent", "codex"]), HookCommand.Arguments(agent: .codex, event: nil))
        XCTAssertEqual(read(["hook", "--agent", "Copilot", "--event", "agentStop"]),
                       HookCommand.Arguments(agent: .copilot, event: "agentStop"))
        XCTAssertEqual(read(["hook", "--event", "agentStop", "--agent", "copilot"]),
                       HookCommand.Arguments(agent: .copilot, event: "agentStop"))
        XCTAssertEqual(read(["hook", "--agent", "opencode"]), HookCommand.Arguments(agent: .opencode, event: nil))
        XCTAssertEqual(read(["hook", "--agent", "gemini"]), HookCommand.Arguments(agent: nil, event: nil))
        XCTAssertEqual(read(["hook", "--agent"]), HookCommand.Arguments(agent: nil, event: nil))
        XCTAssertEqual(read(["hook", "--agent", "copilot", "--event"]), HookCommand.Arguments(agent: .copilot, event: nil))
        XCTAssertEqual(read(["hook", "--bogus", "x", "--agent", "codex"]), HookCommand.Arguments(agent: .codex, event: nil))
    }

    // MARK: who fired it

    func proc(_ pid: Int32, _ ppid: Int32, _ name: String, _ path: String?, tty: String? = nil) -> ProcWalk.ProcInfo {
        ProcWalk.ProcInfo(pid: pid, ppid: ppid, name: name, path: path, tty: tty)
    }

    func firstLine(_ url: URL) throws -> JournalEvent {
        let raw = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").first
        return try XCTUnwrap(JournalCodec.decodeLine(Data(String(try XCTUnwrap(raw)).utf8)))
    }

    /// The flag always wins. With none, the nearest agent process the walk
    /// recognises says, whichever agent it is: a Claude Code the walk cannot
    /// recognise (one run through an interpreter) under a Copilot is
    /// journaled as Copilot's, which is the known cost of reading a bare
    /// hook's agent from its ancestry.
    func testTheFlagAlwaysWinsAndABareHookTakesTheNearestRecognisedAgent() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let chain = [
            proc(700, 600, "node", "/opt/homebrew/bin/node"),
            proc(600, 500, "zsh", "/bin/zsh"),
            proc(500, 1, "copilot", "/Users/u/.local/bin/copilot"),
        ]
        let payload = Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1"}"#.utf8)
        func record(_ agent: AgentKind?) throws -> JournalEvent {
            try? FileManager.default.removeItem(at: url)
            let origin = HookCommand.origin(for: chain, agent: agent, input: payload)
            XCTAssertEqual(HookCommand.run(input: payload, environment: [:], journalURL: url, now: Date(),
                                           origin: origin, agent: agent), 0)
            return try firstLine(url)
        }
        let bare = try record(nil)
        XCTAssertEqual(bare.agent, .copilot)
        XCTAssertEqual(bare.agentPid, 500)
        let flagged = try record(.claude)
        XCTAssertEqual(flagged.agent, .claude, "the flag says who fired it")
        XCTAssertNil(flagged.agentPid, "and no Claude process is in the chain")
    }

    /// OpenCode's payload names its server; it is taken when it is an
    /// OpenCode ancestor of the hook, else the nearest OpenCode is. The
    /// server hosts every session and holds no tab.
    func testTheOpenCodeServerIsThePayloadsWhenItIsAnAncestorAndHoldsNoTab() {
        let standalone = [
            proc(900, 850, "opencode-cli", "/Applications/OpenCode.app/Contents/Resources/opencode-cli", tty: "ttys004"),
            proc(850, 800, "opencode-cli", "/Applications/OpenCode.app/Contents/Resources/opencode-cli", tty: "ttys004"),
            proc(800, 700, "zsh", "/bin/zsh", tty: "ttys004"),
            proc(700, 1, "Terminal", "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
        ]
        func payload(_ pid: Int) -> Data { Data(#"{"hook_event_name":"session.tool.called","session_id":"ses_1","opencode_pid":\#(pid)}"#.utf8) }
        XCTAssertEqual(HookCommand.origin(for: standalone, agent: .opencode, input: payload(850)).agentPid, 850)
        XCTAssertEqual(HookCommand.origin(for: standalone, agent: .opencode, input: payload(900)).agentPid, 900)
        XCTAssertEqual(HookCommand.origin(for: standalone, agent: .opencode, input: payload(800)).agentPid, 900,
                       "a claim that is not OpenCode is not taken")
        XCTAssertEqual(HookCommand.origin(for: standalone, agent: .opencode, input: payload(4242)).agentPid, 900,
                       "nor one outside the chain")
        let origin = HookCommand.origin(for: standalone, agent: .opencode, input: payload(900))
        XCTAssertEqual(origin.agent, .opencode)
        XCTAssertNil(origin.tabTTY, "the server is shared: it is no tab")
        XCTAssertEqual(origin.hostBundlePath, "/Applications/OpenCode.app",
                       "the host is the first bundle in the chain, as for every agent: here the server's own")
        XCTAssertEqual(HookCommand.origin(for: standalone, agent: .claude, input: payload(900)).agentPid, nil,
                       "the claim is OpenCode's alone")
    }

    // MARK: Copilot and OpenCode lines

    /// Copilot: the event from the flag, a subagent's line dropped by its
    /// missing folder under `$COPILOT_HOME/session-state`, and the session's
    /// events file named on a prompt that names none.
    func testACopilotLineTakesItsEventFromTheFlagAndDropsASubagents() throws {
        let url = tempJournal()
        let home = url.deletingLastPathComponent().appendingPathComponent("copilot-home")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let root = home.appendingPathComponent("session-state")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("6c7e446d"),
                                                withIntermediateDirectories: true)
        let environment = ["COPILOT_HOME": home.path]
        func run(_ body: String, event: String?) -> Int32 {
            HookCommand.run(input: Data(body.utf8), environment: environment, journalURL: url, now: Date(),
                            origin: ProcWalk.Origin(agentPid: 500, agent: .copilot), agent: .copilot, event: event)
        }
        XCTAssertEqual(run(#"{"sessionId":"819c2c3e","transcriptPath":"x"}"#, event: "agentStop"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "a subagent's stop writes nothing")

        XCTAssertEqual(run(#"{"sessionId":"6c7e446d","prompt":"SECRET"}"#, event: "userPromptSubmitted"), 0)
        let prompt = try firstLine(url)
        XCTAssertEqual(prompt.event, .userPromptSubmit)
        XCTAssertEqual(prompt.agent, .copilot)
        XCTAssertEqual(prompt.agentPid, 500)
        XCTAssertEqual(prompt.transcriptPath, root.appendingPathComponent("6c7e446d/events.jsonl").path)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("SECRET"))

        try? FileManager.default.removeItem(at: url)
        let elsewhere = ["COPILOT_HOME": home.appendingPathComponent("absent").path]
        XCTAssertEqual(HookCommand.run(input: Data(#"{"sessionId":"819c2c3e"}"#.utf8), environment: elsewhere,
                                       journalURL: url, now: Date(), origin: nil, agent: .copilot,
                                       event: "agentStop"), 0)
        XCTAssertEqual(try firstLine(url).event, .stop, "no session-state folder: nothing to tell a subagent by")
    }

    /// OpenCode: a mapped event is a line; an event the mapping leaves out
    /// writes nothing; every form exits 0.
    func testAnOpenCodeLineIsMappedAndANothingRowWritesNothing() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        func run(_ body: String) -> Int32 {
            HookCommand.run(input: Data(body.utf8), environment: [:], journalURL: url, now: Date(),
                            origin: ProcWalk.Origin(agentPid: 86711, agent: .opencode), agent: .opencode)
        }
        XCTAssertEqual(run(#"{"hook_event_name":"session.step.started","session_id":"ses_1"}"#), 0)
        XCTAssertEqual(run(#"{"hook_event_name":"form.created","session_id":"ses_1","question":false}"#), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(run(#"{"hook_event_name":"session.execution.succeeded","session_id":"ses_1","parent_id":"ses_0","opencode_pid":86711}"#), 0)
        let line = try firstLine(url)
        XCTAssertEqual(line.event, .subagentStop)
        XCTAssertEqual(line.sessionId, "ses_0")
        XCTAssertEqual(line.agentId, "ses_1")
        XCTAssertEqual(line.agent, .opencode)
        XCTAssertEqual(line.agentPid, 86711)
    }

    /// The hook runs inside Copilot's own turn, where a failure could deny a
    /// tool: every form, bad input or none, exits 0.
    func testEveryFormExitsZero() {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        for agent in [nil, AgentKind.claude, .codex, .copilot, .opencode] {
            for event in [nil, "agentStop", "no-such-event"] {
                for input in ["", "{oops", "[]", #"{"sessionId":"x"}"#] {
                    XCTAssertEqual(HookCommand.run(input: Data(input.utf8), environment: [:], journalURL: url,
                                                   now: Date(), origin: nil, agent: agent, event: event), 0)
                }
            }
        }
    }

    func testGarbageStillExitsZeroAndJournalsParseError() throws {
        let url = tempJournal()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(HookCommand.run(input: Data("{oops".utf8), environment: [:],
                                       journalURL: url, now: Date(), origin: nil), 0)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("ParseError"))
    }
}

import XCTest
@testable import MySidepulseCore

/// OpenCode: the plugin MySidepulse writes, the mapping of OpenCode's own
/// events onto the journal's, and the sequences recorded on this Mac replayed
/// through the store.
final class OpencodeTests: XCTestCase {
    let cli = "/Applications/MySidepulse.app/Contents/MacOS/mysidepulse"
    let t0 = Date(timeIntervalSince1970: 1_787_652_000)

    func oc(_ type: String, _ t: TimeInterval = 0, session: String? = "ses_top", parent: String? = nil,
            _ extra: [String: Any] = [:]) -> JournalEvent? {
        var body: [String: Any] = ["hook_event_name": type, "session_id": session ?? NSNull(),
                                   "event_time": 1_790_000_000_000, "opencode_pid": 86711]
        if let parent { body["parent_id"] = parent }
        body.merge(extra) { $1 }
        return Trim.opencodeEvent(fromHookPayload: try! JSONSerialization.data(withJSONObject: body),
                                  loggedAt: t0.addingTimeInterval(t))
    }

    // MARK: the plugin

    /// The tested source, with MySidepulse's command and id, forwarding no
    /// `location.shutdown` and no directory at all.
    func testThePluginIsTheTestedSourceWithOurCommandAndId() {
        let source = HookConfig.opencodePlugin(cliPath: cli)
        let first = source.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        XCTAssertTrue(first.hasPrefix("// MySidepulse"), first)
        XCTAssertTrue(first.contains(HookConfig.ourMarker), "the first line names the command: \(first)")
        XCTAssertTrue(source.contains(#"const COMMAND = ["\#(cli)", "hook", "--agent", "opencode"]"#))
        XCTAssertTrue(source.contains(#"const ID = "io.mysidepulse.app.opencode""#))
        XCTAssertEqual(HookConfig.opencodePluginId, "io.mysidepulse.app.opencode")
        XCTAssertTrue(source.contains("export default {"))
        XCTAssertTrue(source.contains("ctx.event.subscribe({ signal: controller.signal })"))
        XCTAssertTrue(source.contains(#"import { spawn } from "node:child_process""#))
        for forwarded in ["session.created", "session.forked", "session.deleted", "session.inbox.enqueued",
                          "session.execution.started", "session.execution.succeeded", "session.execution.failed",
                          "session.execution.interrupted", "session.tool.called", "session.tool.success",
                          "session.tool.failed", "permission.asked", "permission.replied", "form.created",
                          "form.replied", "form.cancelled", "session.compaction.started",
                          "session.compaction.ended", "session.compaction.failed"] {
            XCTAssertTrue(source.contains("\"\(forwarded)\","), forwarded)
        }
        XCTAssertFalse(source.contains("location.shutdown"))
        XCTAssertFalse(source.contains("directory"), "no path leaves OpenCode")
        XCTAssertTrue(source.hasSuffix("}\n"))
    }

    /// A path is written as a JavaScript string, whatever it holds.
    func testThePathIsAStringLiteral() {
        let odd = #"/Users/a "b" \c/MySidepulse.app/Contents/MacOS/mysidepulse"#
        XCTAssertTrue(HookConfig.opencodePlugin(cliPath: odd)
            .contains(#"const COMMAND = ["/Users/a \"b\" \\c/MySidepulse.app/Contents/MacOS/mysidepulse", "hook""#))
    }

    /// A subagent's events attach to the top session, however deep it is:
    /// the plugin walks its parents up before it writes `parent_id`, and a
    /// cycle or a very long chain cannot hold it.
    func testThePluginAttachesASubagentToItsTopSession() {
        let source = HookConfig.opencodePlugin(cliPath: cli)
        XCTAssertTrue(source.contains("function top(state, sessionID)"))
        XCTAssertTrue(source.contains("out.parent_id = parent"))
        XCTAssertFalse(source.contains("out.parent_id = data.parentID"))
    }

    func testAFileIsOursByItsMarkerAndIdAndSetUpWhenItIsWhatThisBundleWrites() {
        let source = HookConfig.opencodePlugin(cliPath: cli)
        XCTAssertTrue(HookConfig.isOurOpencodePlugin(source))
        XCTAssertTrue(HookConfig.isCurrentOpencodePlugin(source, cliPath: cli))
        let other = HookConfig.opencodePlugin(cliPath: "/Old/MySidepulse.app/Contents/MacOS/mysidepulse")
        XCTAssertTrue(HookConfig.isOurOpencodePlugin(other), "another copy's plugin is ours")
        XCTAssertFalse(HookConfig.isCurrentOpencodePlugin(other, cliPath: cli), "and is not set up for this one")
        XCTAssertFalse(HookConfig.isCurrentOpencodePlugin(source + "\n", cliPath: cli), "byte for byte")
        XCTAssertFalse(HookConfig.isOurOpencodePlugin("export default { id: \"someone.else\", setup() {} }\n"))
        XCTAssertFalse(HookConfig.isOurOpencodePlugin("// \(cli) hook\n"), "the marker without the id")
        XCTAssertEqual(HookConfig.setUpCount(for: .opencode), 1)
        XCTAssertEqual(HookConfig.setUpCount(for: .claude), 15)
        XCTAssertEqual(HookConfig.setUpCount(for: .codex), 12)
    }

    // MARK: the mapping

    /// Every row of the table, for a top session and for a subagent, whose
    /// events are its top session's helper events.
    func testEveryOpenCodeEventMapsOntoTheJournal() {
        let rows: [(String, [String: Any], HookEventName?, HookEventName?)] = [
            ("session.created", [:], .sessionStart, .subagentStart),
            ("session.forked", [:], .sessionStart, .subagentStart),
            ("session.inbox.enqueued", ["delivery": "steer"], .userPromptSubmit, .userPromptSubmit),
            ("session.execution.started", [:], .userPromptSubmit, .userPromptSubmit),
            ("session.tool.called", ["tool_name": "shell"], .preToolUse, .preToolUse),
            ("session.tool.success", [:], .postToolUse, .postToolUse),
            ("session.tool.failed", ["error_name": "aborted"], .postToolUseFailure, .postToolUseFailure),
            ("permission.asked", ["permission": "shell"], .permissionRequest, .permissionRequest),
            ("permission.replied", ["status": "once"], .postToolUse, .postToolUse),
            ("permission.replied", ["status": "always"], .postToolUse, .postToolUse),
            ("permission.replied", ["status": "reject"], .permissionDenied, .postToolUse),
            ("form.created", ["question": true], .notification, .permissionRequest),
            ("form.created", ["question": false], nil, nil),
            ("form.created", [:], nil, nil),
            ("form.replied", [:], .postToolUse, .postToolUse),
            ("form.cancelled", [:], .postToolUse, .postToolUse),
            ("session.compaction.started", ["reason": "auto"], .preCompact, .preCompact),
            ("session.compaction.ended", [:], .postCompact, .postCompact),
            ("session.compaction.failed", [:], .postCompact, .postCompact),
            ("session.execution.succeeded", ["status": "succeeded"], .stop, .subagentStop),
            ("session.execution.failed", ["status": "failed", "error_name": "api"], .stopFailure, .subagentStop),
            ("session.execution.interrupted", ["status": "interrupted", "reason": "user"], .interrupt, .subagentStop),
            ("session.execution.interrupted", ["reason": "shutdown"], .interrupt, .subagentStop),
            ("session.deleted", [:], .sessionEnd, .subagentStop),
            ("session.step.started", [:], nil, nil),
            ("location.shutdown", [:], nil, nil),
            ("session.idle", [:], nil, nil),
        ]
        for (type, extra, top, helper) in rows {
            let main = oc(type, session: "ses_top", extra)
            XCTAssertEqual(main?.event, top, "\(type) \(extra)")
            if let main {
                XCTAssertEqual(main.sessionId, "ses_top")
                XCTAssertNil(main.agentId)
                XCTAssertEqual(main.agent, .opencode)
                XCTAssertNil(main.turnId, "OpenCode names no turn")
            }
            let child = oc(type, session: "ses_child", parent: "ses_top", extra)
            XCTAssertEqual(child?.event, helper, "subagent \(type) \(extra)")
            if let child {
                XCTAssertEqual(child.sessionId, "ses_top", "a subagent's event is its top session's")
                XCTAssertEqual(child.agentId, "ses_child")
            }
        }
    }

    func testTheLineKeepsWhatTheStoreReadsAndNothingElse() throws {
        let question = try XCTUnwrap(oc("form.created", 0, ["question": true]))
        XCTAssertEqual(question.notificationType, "elicitation_dialog")
        let asked = try XCTUnwrap(oc("permission.asked", 0, ["permission": "edit"]))
        XCTAssertEqual(asked.toolName, "edit", "a permission's action names the tool it guards")
        let called = try XCTUnwrap(oc("session.tool.called", 0, ["tool_name": "shell", "tool_use_id": "call-1"]))
        XCTAssertEqual(called.toolName, "shell")
        let failed = try XCTUnwrap(oc("session.execution.failed", 0, ["error_name": "api"]))
        XCTAssertEqual(failed.errorType, "api")
        let interrupted = try XCTUnwrap(oc("session.execution.interrupted", 0, ["reason": "user"]))
        XCTAssertEqual(interrupted.reason, "user")
        let created = try XCTUnwrap(oc("session.created", 0, ["directory": "/Users/u/SECRET-PATH"]))
        XCTAssertNil(created.cwd)
        XCTAssertFalse(String(decoding: try Trim.cappedLine(created), as: UTF8.self).contains("SECRET"))
    }

    /// A form outside any session (an MCP form can say `global`), or an
    /// event with no session, writes nothing; a body that is not an event is
    /// a `ParseError`.
    func testAnEventOfNoSessionWritesNothingAndGarbageIsAParseError() {
        XCTAssertNil(oc("form.created", session: "global", ["question": true]))
        XCTAssertNil(oc("session.execution.succeeded", session: nil))
        XCTAssertNil(oc("session.execution.succeeded", session: ""))
        let garbage = Trim.opencodeEvent(fromHookPayload: Data("{oops".utf8), loggedAt: t0)
        XCTAssertEqual(garbage?.event, .parseError)
        XCTAssertEqual(garbage?.agent, .opencode)
        XCTAssertEqual(Trim.opencodeEvent(fromHookPayload: Data(#"{"session_id":"s"}"#.utf8), loggedAt: t0)?.event,
                       .parseError)
    }

    func testTheServerPidIsReadFromThePayload() {
        XCTAssertEqual(Trim.opencodePid(fromHookPayload: Data(#"{"opencode_pid":86711}"#.utf8)), 86711)
        XCTAssertNil(Trim.opencodePid(fromHookPayload: Data(#"{"opencode_pid":"86711"}"#.utf8)))
        XCTAssertNil(Trim.opencodePid(fromHookPayload: Data(#"{"opencode_pid":0}"#.utf8)))
        XCTAssertNil(Trim.opencodePid(fromHookPayload: Data(#"{"opencode_pid":99999999999}"#.utf8)))
        XCTAssertNil(Trim.opencodePid(fromHookPayload: Data("{oops".utf8)))
    }

    // MARK: the recorded sequences

    func apply(_ store: inout SessionStore, _ events: [JournalEvent?]) {
        for e in events { if let e { store.apply(e) } }
    }

    /// Prompt 1 (`opencode run --auto`): the permission is asked and
    /// approved 3 ms later. It never reaches the strip or the phone; the
    /// finish does.
    func testARunWithAPermissionApprovedAtOnceShowsNoAmberAndPushesNoWait() {
        var store = SessionStore()
        apply(&store, [
            oc("session.created", 0),
            oc("session.inbox.enqueued", 0.006, ["delivery": "steer"]),
            oc("session.execution.started", 0.019),
            oc("session.tool.called", 1.909, ["tool_name": "shell"]),
            oc("permission.asked", 1.912, ["permission": "shell"]),
        ])
        XCTAssertEqual(store.sessions["ses_top"]?.state, .waiting(.permission))
        XCTAssertEqual(store.sessions["ses_top"]?.presentedState, .working, "settling")
        apply(&store, [oc("permission.replied", 1.915, ["status": "once"])])
        XCTAssertEqual(store.sessions["ses_top"]?.state, .working)
        apply(&store, [oc("session.tool.success", 1.923)])
        var pushes: [Alert] = []
        for t in stride(from: 1.923, through: 4.8, by: 0.05) {
            pushes += store.tick(now: t0.addingTimeInterval(t))
            XCTAssertEqual(store.sessions["ses_top"]?.presentedState, .working, "t=\(t)")
        }
        apply(&store, [oc("session.execution.succeeded", 4.846)])
        XCTAssertEqual(store.sessions["ses_top"]?.state, .done)
        pushes += store.tick(now: t0.addingTimeInterval(4.846 + K.notifyDebounceSeconds))
        XCTAssertEqual(pushes.map(\.kind), [.finished], "the finish pushes; the 3 ms wait never does")
        XCTAssertEqual(pushes.map(\.agent), [.opencode])
    }

    /// Prompt 3 (`opencode run` without `--auto`): the permission is
    /// rejected, the tool fails, and the run interrupts the session: dark,
    /// no alert, no push.
    func testARejectedPermissionThenTheInterruptGoesDark() {
        var store = SessionStore()
        apply(&store, [
            oc("session.created", 0),
            oc("session.inbox.enqueued", 0.01),
            oc("session.execution.started", 0.02),
            oc("session.tool.called", 2, ["tool_name": "shell"]),
            oc("permission.asked", 2.003, ["permission": "shell"]),
            oc("permission.replied", 2.006, ["status": "reject"]),
            oc("session.tool.failed", 2.008, ["error_name": "aborted"]),
            oc("session.execution.interrupted", 2.02, ["status": "interrupted", "reason": "user"]),
        ])
        XCTAssertEqual(store.sessions["ses_top"]?.state, .idle)
        XCTAssertTrue(store.tick(now: t0.addingTimeInterval(2 + K.notifyDebounceSeconds + 1)).isEmpty)
        apply(&store, [oc("session.inbox.enqueued", 60), oc("session.execution.started", 60.01)])
        XCTAssertEqual(store.sessions["ses_top"]?.state, .working, "the next prompt opens a turn")
    }

    /// A subagent running when its top session's turn ends holds the finish
    /// until it ends too, a grandchild's events included: the plugin
    /// attaches them all to the top session.
    func testASubagentHoldsTheFinishUntilItEnds() {
        var store = SessionStore()
        apply(&store, [
            oc("session.created", 0),
            oc("session.inbox.enqueued", 0.01),
            oc("session.execution.started", 0.02),
            oc("session.tool.called", 1, ["tool_name": "subagent"]),
            oc("session.created", 1.1, session: "ses_child", parent: "ses_top"),
            oc("session.inbox.enqueued", 1.2, session: "ses_child", parent: "ses_top"),
            oc("session.execution.started", 1.3, session: "ses_child", parent: "ses_top"),
            oc("session.created", 2, session: "ses_grandchild", parent: "ses_top"),
            oc("session.tool.success", 3),
            oc("session.execution.succeeded", 4),
        ])
        XCTAssertEqual(store.sessions["ses_top"]?.state, .working, "held behind the subagents")
        XCTAssertEqual(store.sessions["ses_top"]?.pendingDone, true)
        XCTAssertNil(store.sessions["ses_child"], "a subagent is no session of its own")
        apply(&store, [oc("session.execution.succeeded", 30, session: "ses_child", parent: "ses_top")])
        store.tick(now: t0.addingTimeInterval(30 + K.holdGraceSeconds + 1))
        XCTAssertEqual(store.sessions["ses_top"]?.state, .working, "the grandchild still runs")
        apply(&store, [oc("session.deleted", 200, session: "ses_grandchild", parent: "ses_top")])
        store.tick(now: t0.addingTimeInterval(200 + K.holdGraceSeconds))
        XCTAssertEqual(store.sessions["ses_top"]?.state, .done)
    }

    /// The question tool's form is a question; its reply is the answer. A
    /// subagent's question holds its top session's turn like a permission,
    /// and the subagent's next event clears it.
    func testAQuestionAsksAndItsReplyAnswers() {
        var store = SessionStore()
        apply(&store, [
            oc("session.inbox.enqueued", 0),
            oc("session.tool.called", 1, ["tool_name": "question"]),
            oc("form.created", 1.01, ["question": true]),
        ])
        XCTAssertEqual(store.sessions["ses_top"]?.state, .waiting(.question))
        apply(&store, [oc("form.replied", 20)])
        XCTAssertEqual(store.sessions["ses_top"]?.state, .working)
        apply(&store, [oc("form.created", 21, ["question": false])])
        XCTAssertEqual(store.sessions["ses_top"]?.state, .working, "an MCP form is not a question to the user")

        apply(&store, [
            oc("session.created", 30, session: "ses_child", parent: "ses_top"),
            oc("form.created", 31, session: "ses_child", parent: "ses_top", ["question": true]),
        ])
        XCTAssertEqual(store.sessions["ses_top"]?.state, .waiting(.permission))
        XCTAssertEqual(store.sessions["ses_top"]?.waitingFromAgent, true)
        apply(&store, [oc("form.replied", 40, session: "ses_child", parent: "ses_top")])
        XCTAssertEqual(store.sessions["ses_top"]?.state, .working)
    }
}

import XCTest
@testable import MySidepulseCore

/// The OpenCode plugin is a text no compiler checks, like the zsh snippet: it
/// is run here by a real `node`, as OpenCode's server would load it, with a
/// stand-in `ctx` and a stand-in hook that appends its stdin to a file. Two
/// instances read the same stream, as they do inside one server. Opt-in:
/// skipped where no `node` is found. Hermetic: temp folders only.
final class OpencodePluginRunTests: XCTestCase {
    var dir: URL!
    var log: URL { dir.appendingPathComponent("hook.log") }
    var cli: String { dir.appendingPathComponent("Stub.app/Contents/MacOS/mysidepulse").path }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mysidepulse-opencode-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: cli).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\ncat >> '\(log.path)'\n".utf8).write(to: URL(fileURLWithPath: cli))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli)
        try HookConfig.opencodePlugin(cliPath: cli)
            .write(to: dir.appendingPathComponent("mysidepulse.mjs"), atomically: true, encoding: .utf8)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// `node` on PATH, or where Homebrew, the official installer or a
    /// version manager puts it.
    static func node() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { "\($0)/node" }
        candidates += ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        for manager in ["\(home)/.local/share/mise/installs/node", "\(home)/.nvm/versions/node"] {
            let versions = (try? FileManager.default.contentsOfDirectory(atPath: manager)) ?? []
            candidates += versions.sorted().reversed().map { "\(manager)/\($0)/bin/node" }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    @discardableResult
    func run(_ node: URL, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = node
        process.arguments = arguments
        process.currentDirectoryURL = dir
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate(); XCTFail("node did not finish in 20 s") }
        process.waitUntilExit()
        return process.terminationStatus
    }

    func testThePluginParsesAsAModule() throws {
        guard let node = Self.node() else { throw XCTSkip("no node on this Mac") }
        XCTAssertEqual(try run(node, ["--check", "mysidepulse.mjs"]), 0)
    }

    /// The whole plugin, driven: every forwarded event reaches the hook once
    /// in order, a grandchild's events name the top session even after its
    /// parent was deleted, a parent cycle ends the walk, and nothing it
    /// writes carries a path or a word of the conversation.
    func testThePluginForwardsEachEventOnceToTheTopSessionAndNothingPrivate() throws {
        guard let node = Self.node() else { throw XCTSkip("no node on this Mac") }
        let harness = #"""
        import plugin from "./mysidepulse.mjs"
        import { readFileSync, existsSync } from "node:fs"
        const events = []
        let n = 0
        const ev = (type, data, extra = {}) => events.push({ id: `evt_${++n}`, created: 1790000000000 + n, type, data, ...extra })
        ev("session.created", { sessionID: "ses_top", location: { directory: "/Users/u/SECRET-DIR" } })
        ev("session.inbox.enqueued", { sessionID: "ses_top", item: { type: "user", delivery: "steer", payload: "SECRET-PROMPT" } })
        ev("session.inbox.enqueued", { sessionID: "ses_top", item: { type: "synthetic", payload: "SECRET-SYNTHETIC" } })
        ev("session.execution.started", { sessionID: "ses_top" })
        ev("session.tool.input.started", { sessionID: "ses_top", id: "call-1", name: "subagent" })
        ev("session.reasoning.delta", { sessionID: "ses_top", delta: "SECRET-THOUGHT" })
        ev("session.tool.called", { sessionID: "ses_top", id: "call-1", input: { command: "SECRET-INPUT" } })
        ev("session.created", { sessionID: "ses_child", parentID: "ses_top" })
        ev("session.created", { sessionID: "ses_grand", parentID: "ses_child" })
        ev("session.deleted", { sessionID: "ses_child" })
        ev("permission.asked", { sessionID: "ses_grand", action: "shell", metadata: { command: "SECRET-INPUT" } })
        ev("form.created", { form: { sessionID: "ses_grand", title: "SECRET-TITLE", metadata: { kind: "question" } } })
        ev("session.execution.succeeded", { sessionID: "ses_grand" })
        ev("session.created", { sessionID: "ses_a", parentID: "ses_b" })
        ev("session.created", { sessionID: "ses_b", parentID: "ses_a" })
        ev("session.tool.success", { sessionID: "ses_a", id: "x", content: "SECRET-OUTPUT" })
        ev("location.shutdown", {}, { location: { directory: "/Users/u/SECRET-DIR" } })
        ev("session.execution.succeeded", { sessionID: "ses_top" })
        const stream = async function* () { for (const e of events) yield e; yield events[events.length - 1] }
        const cleanups = [plugin.setup({ event: { subscribe: stream } }), plugin.setup({ event: { subscribe: stream } })]
        const lines = () => existsSync("hook.log") ? readFileSync("hook.log", "utf8").split("\n").filter(Boolean).length : 0
        const until = Date.now() + 10000
        while (lines() < 14 && Date.now() < until) await new Promise((r) => setTimeout(r, 25))
        await new Promise((r) => setTimeout(r, 300))
        for (const cleanup of cleanups) cleanup()
        """#
        try harness.write(to: dir.appendingPathComponent("harness.mjs"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try run(node, ["harness.mjs"]), 0)

        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertFalse(text.contains("SECRET"), text)
        XCTAssertFalse(text.contains("directory"), text)
        let lines = try text.split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        func type(_ line: [String: Any]) -> String { line["hook_event_name"] as? String ?? "" }
        XCTAssertEqual(lines.map(type), [
            "session.created", "session.inbox.enqueued", "session.execution.started", "session.tool.called",
            "session.created", "session.created", "session.deleted", "permission.asked", "form.created",
            "session.execution.succeeded", "session.created", "session.created", "session.tool.success",
            "session.execution.succeeded",
        ], "each forwarded event once, in order; no synthetic prompt, no shutdown, no delta")
        func parent(_ index: Int) -> String? { lines[index]["parent_id"] as? String }
        XCTAssertNil(parent(0))
        XCTAssertEqual(parent(4), "ses_top")
        XCTAssertEqual(parent(5), "ses_top", "a grandchild attaches to the top session")
        XCTAssertEqual(parent(6), "ses_top")
        for index in 7...9 {
            XCTAssertEqual(lines[index]["session_id"] as? String, "ses_grand")
            XCTAssertEqual(parent(index), "ses_top", "its parent's deletion does not orphan it")
        }
        XCTAssertEqual(lines[3]["tool_name"] as? String, "subagent")
        XCTAssertEqual(lines[7]["permission"] as? String, "shell")
        XCTAssertEqual(lines[8]["question"] as? Bool, true)
        XCTAssertEqual(lines[12]["session_id"] as? String, "ses_a")
        XCTAssertEqual(parent(12), "ses_b", "a cycle ends the walk")
        XCTAssertNil(parent(13))
        XCTAssertEqual(lines[13]["status"] as? String, "succeeded")
        for line in lines {
            XCTAssertEqual(Set(line.keys).subtracting([
                "hook_event_name", "session_id", "event_time", "opencode_pid", "parent_id", "delivery", "status",
                "reason", "error_name", "tool_name", "tool_use_id", "permission", "question",
            ]), [], "\(line)")
        }
    }
}

import XCTest
@testable import MySidepulseCore

final class HookConfigTests: XCTestCase {
    let cmd = "/Applications/MySidepulse.app/Contents/MacOS/mysidepulse hook"

    /// Shaped like a real settings.json: a hook of the user's own that must
    /// survive untouched. Made up on purpose — the fixture's job is to prove
    /// we never clobber a stranger's hook, not to describe this machine.
    var fixture: [String: Any] {
        [
            "model": "claude-fable-5",
            "hooks": [
                "Stop": [
                    ["hooks": [["type": "command",
                                "command": "afplay /System/Library/Sounds/Glass.aiff >/dev/null 2>&1 &",
                                "timeout": 10, "async": true]]],
                ],
            ],
        ]
    }

    func groups(_ root: [String: Any], _ event: String) -> [Any] {
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        return hooks[event] as? [Any] ?? []
    }
    func commands(_ root: [String: Any], _ event: String) -> [String] {
        groups(root, event).flatMap { element -> [String] in
            guard let group = element as? [String: Any],
                  let items = group["hooks"] as? [Any] else { return [] }
            return items.compactMap { ($0 as? [String: Any])?["command"] as? String }
        }
    }

    func testInstallAddsAllEventsAndKeepsForeignHooks() {
        let out = HookConfig.install(into: fixture, command: cmd)
        XCTAssertEqual(HookConfig.events.count, 15)
        for event in HookConfig.events {
            XCTAssertEqual(HookConfig.installedCommand(in: out, event: event), cmd,
                           "missing or wrong command for \(event)")
        }
        let stop = commands(out, "Stop")
        XCTAssertTrue(stop.contains { $0.contains("Glass.aiff") }, "user hook must survive")
        XCTAssertEqual(out["model"] as? String, "claude-fable-5", "unrelated settings untouched")
    }

    func testInstalledEntryHasTheExactPrescribedShape() {
        let out = HookConfig.install(into: [:], command: cmd)
        for event in HookConfig.events {
            let ours = groups(out, event).compactMap { $0 as? [String: Any] }.filter { group in
                ((group["hooks"] as? [Any]) ?? []).contains {
                    (($0 as? [String: Any])?["command"] as? String) == cmd
                }
            }
            XCTAssertEqual(ours.count, 1, "exactly one entry of ours for \(event)")
            let group = ours[0]
            XCTAssertEqual(group["matcher"] as? String, "*",
                           "\(event): a matcher-less group may never fire for tool events")
            let items = group["hooks"] as? [[String: Any]] ?? []
            XCTAssertEqual(items.count, 1, "\(event): one hook item")
            XCTAssertEqual(items.first?["type"] as? String, "command")
            XCTAssertEqual(items.first?["command"] as? String, cmd)
            XCTAssertEqual(items.first?["timeout"] as? Int, 5)
        }
    }

    func testInstallLeavesANonObjectHooksValueAlone() {
        let root: [String: Any] = ["model": "claude-fable-5", "hooks": "not an object"]
        let out = HookConfig.install(into: root, command: cmd)
        XCTAssertEqual(out["hooks"] as? String, "not an object",
                       "a hooks value we do not understand must not be replaced")
        XCTAssertEqual(out["model"] as? String, "claude-fable-5")
        let array: [String: Any] = ["hooks": [["Stop": "x"]]]
        XCTAssertNotNil(HookConfig.install(into: array, command: cmd)["hooks"] as? [Any],
                        "an array hooks value is likewise left as it is")
    }

    func testInstallIsIdempotent() {
        let once = HookConfig.install(into: fixture, command: cmd)
        let twice = HookConfig.install(into: once, command: cmd)
        for event in HookConfig.events {
            XCTAssertEqual(commands(twice, event).filter { $0 == cmd }.count, 1,
                           "\(event) must not accumulate duplicates")
        }
    }

    func testInstallUpdatesStaleBinaryPath() {
        let old = HookConfig.install(into: [:], command: "/old/MySidepulse.app/Contents/MacOS/mysidepulse hook")
        let new = HookConfig.install(into: old, command: cmd)
        XCTAssertEqual(HookConfig.installedCommand(in: new, event: "Stop"), cmd)
        XCTAssertEqual(commands(new, "Stop").count, 1)
    }

    func testUninstallRemovesOnlyOurs() {
        let installed = HookConfig.install(into: fixture, command: cmd)
        let out = HookConfig.uninstall(from: installed)
        XCTAssertNil(HookConfig.installedCommand(in: out, event: "Stop"))
        XCTAssertTrue(commands(out, "Stop").contains { $0.contains("Glass.aiff") })
        XCTAssertNil((out["hooks"] as? [String: Any])?["PreToolUse"], "event arrays left empty are removed")
    }

    func testInstallIntoEmptySettings() {
        let out = HookConfig.install(into: [:], command: cmd)
        XCTAssertEqual(HookConfig.installedCommand(in: out, event: "SubagentStart"), cmd)
    }

    func testEventListIsExactlyTheFifteenClaudeEvents() {
        XCTAssertEqual(HookConfig.events, [
            "SessionStart", "SessionEnd", "UserPromptSubmit",
            "PreToolUse", "PostToolUse", "PostToolUseFailure",
            "PermissionRequest", "PermissionDenied", "Notification",
            "Stop", "StopFailure", "SubagentStart", "SubagentStop",
            "PreCompact", "PostCompact",
        ], "these are Claude Code's event names; a typo is silent at runtime")
    }

    func testMalformedSiblingDoesNotDestroyNeighbouringHooks() {
        let root: [String: Any] = ["hooks": [
            "Stop": [
                "a stray string that is not a hook group",
                ["hooks": [["type": "command", "command": "afplay Glass.aiff"]]],
            ],
        ]]
        let out = HookConfig.install(into: root, command: cmd)
        XCTAssertTrue(commands(out, "Stop").contains("afplay Glass.aiff"),
                      "a malformed sibling must not take the user's real hook with it")
        XCTAssertEqual(HookConfig.installedCommand(in: out, event: "Stop"), cmd)
        XCTAssertTrue(groups(out, "Stop").contains { $0 as? String == "a stray string that is not a hook group" },
                      "unrecognised elements are preserved, not silently dropped")
    }

    func testNonArrayEventValueIsLeftAlone() {
        let root: [String: Any] = ["hooks": ["Stop": "not an array at all"]]
        let out = HookConfig.install(into: root, command: cmd)
        XCTAssertEqual((out["hooks"] as? [String: Any])?["Stop"] as? String, "not an array at all")
        XCTAssertNil(HookConfig.installedCommand(in: out, event: "Stop"))
    }

    func testUninstallOnSettingsWithoutHooksIsANoOp() {
        let out = HookConfig.uninstall(from: ["model": "claude-fable-5"])
        XCTAssertNil(out["hooks"], "must not invent an empty hooks object")
        XCTAssertEqual(out["model"] as? String, "claude-fable-5")
    }
}

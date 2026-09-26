import Foundation

/// Edits the `hooks` section of an agent's hook file: Claude Code's
/// `settings.json`, or Codex's `hooks.json`, which holds the same shape under
/// the same key. Pure dictionary transforms; file I/O and backups belong to
/// `HookInstaller`.
public enum HookConfig {
    /// Every Claude Code event the state machine consumes (docs/functional.md §4).
    public static let events = [
        "SessionStart", "SessionEnd", "UserPromptSubmit",
        "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "PermissionRequest", "PermissionDenied", "Notification",
        "Stop", "StopFailure", "SubagentStart", "SubagentStop",
        "PreCompact", "PostCompact",
    ]
    /// Every Codex event: the same names, less the four Codex does not have
    /// (`PostToolUseFailure`, `PermissionDenied`, `Notification`,
    /// `StopFailure`), plus `Interrupt`, which Claude Code does not have.
    public static let codexEvents = [
        "SessionStart", "SessionEnd", "UserPromptSubmit",
        "PreToolUse", "PostToolUse", "PermissionRequest",
        "Stop", "SubagentStart", "SubagentStop",
        "PreCompact", "PostCompact", "Interrupt",
    ]

    /// The GitHub Copilot CLI events subscribed, in camelCase as Copilot
    /// names them. Never `preToolUse` or `permissionRequest`: Copilot denies
    /// the tool when either hook fails or is missing, so a hook file that
    /// outlived the app would block every Copilot tool call.
    public static let copilotEvents = [
        "sessionStart", "userPromptSubmitted", "postToolUse", "postToolUseFailure",
        "notification", "agentStop", "sessionEnd",
    ]

    /// OpenCode runs no command hooks: it loads a plugin, which calls the hook
    /// command itself, so it subscribes none of these.
    public static func events(for agent: AgentKind) -> [String] {
        switch agent {
        case .claude: return events
        case .codex: return codexEvents
        case .copilot: return copilotEvents
        case .opencode: return []
        }
    }

    /// Our own entries, recognized for idempotent reinstall and uninstall.
    /// Both agents' commands carry it: `… hook` and `… hook --agent codex`.
    public static let ourMarker = "/Contents/MacOS/mysidepulse hook"

    /// The command an agent's hooks run. Claude Code's is the bare `hook`,
    /// the shape every install has written; every other agent's names itself,
    /// so the journal line carries the agent whatever process fired the hook.
    /// Copilot's payloads carry no event name, so its command names the event
    /// too, when one is given.
    public static func command(cliPath: String, agent: AgentKind, event: String? = nil) -> String {
        switch agent {
        case .claude: return "\(cliPath) hook"
        case .codex: return "\(cliPath) hook --agent codex"
        case .copilot: return "\(cliPath) hook --agent copilot" + (event.map { " --event \($0)" } ?? "")
        case .opencode: return "\(cliPath) hook --agent opencode"
        }
    }

    /// The binary an installed command runs: everything before ` hook`.
    public static func binary(ofCommand command: String) -> String {
        guard let range = command.range(of: " hook") else { return command }
        return String(command[..<range.lowerBound])
    }

    public static func install(into root: [String: Any], command: String,
                               events: [String] = events) -> [String: Any] {
        var root = root
        // A `hooks` value that is not an object is a file we do not
        // understand. Replacing it would discard whatever the user has
        // there; leave it, exactly as `uninstall` does.
        if let existing = root["hooks"], !(existing is [String: Any]) { return root }
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]
        for (event, value) in hooks {
            guard value is [Any] else { continue }
            hooks[event] = scrubEventValue(value)
        }
        for event in events {
            // An event whose value is not an array is a shape we do not
            // understand. Leave it exactly as it is rather than clobber it;
            // `doctor` reporting the hook as missing is the honest signal.
            if let existing = hooks[event], !(existing is [Any]) { continue }
            var groups = (hooks[event] as? [Any]) ?? []
            // `matcher` selects which tools a PreToolUse/PostToolUse group
            // fires for. A matcher-less group is accepted for the events that
            // have nothing to match on, but "*" is what the docs prescribe
            // for every event — the shape known to work. Codex reads "*" as
            // match-all too.
            let entry: [String: Any] = [
                "matcher": "*",
                "hooks": [["type": "command", "command": command, "timeout": 5]],
            ]
            groups.append(entry)
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return root
    }

    public static func uninstall(from root: [String: Any]) -> [String: Any] {
        var root = root
        // No hooks at all: nothing of ours to remove, and nothing to add.
        guard var hooks = root["hooks"] as? [String: Any] else { return root }
        for (event, value) in hooks {
            guard value is [Any] else { continue }
            let scrubbed = scrubEventValue(value)
            if scrubbed.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = scrubbed }
        }
        root["hooks"] = hooks
        return root
    }

    public static func installedCommand(in root: [String: Any], event: String) -> String? {
        guard let hooks = root["hooks"] as? [String: Any],
              let groups = hooks[event] as? [Any] else { return nil }
        for element in groups {
            guard let group = element as? [String: Any],
                  let items = group["hooks"] as? [Any] else { continue }
            for item in items {
                if let hook = item as? [String: Any],
                   let command = hook["command"] as? String,
                   command.contains(ourMarker) {
                    return command
                }
            }
        }
        return nil
    }

    /// Scrub one event's array element-wise. A hook group we recognise gets
    /// its items filtered; anything else passes through untouched. This
    /// rewrites the user's real settings file, so one malformed element must
    /// never take its well-formed neighbours down with it.
    static func scrubEventValue(_ value: Any) -> [Any] {
        guard let elements = value as? [Any] else { return [] }
        return elements.compactMap { element -> Any? in
            guard let group = element as? [String: Any] else { return element }
            return scrubGroup(group)
        }
    }

    /// Remove our hook items from one group. A group with no recognisable
    /// `hooks` array is kept as-is; a group left empty is dropped.
    static func scrubGroup(_ group: [String: Any]) -> [String: Any]? {
        guard let items = group["hooks"] as? [Any] else { return group }
        let kept = items.filter { item in
            guard let hook = item as? [String: Any],
                  let command = hook["command"] as? String else { return true }
            return !command.contains(ourMarker)
        }
        if kept.isEmpty { return nil }
        var group = group
        group["hooks"] = kept
        return group
    }
}

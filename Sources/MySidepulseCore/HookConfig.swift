import Foundation

/// Edits the `hooks` section of Claude Code's settings.json. Pure dictionary
/// transforms — file I/O and backups belong to `HookInstaller`.
public enum HookConfig {
    /// Every event the state machine consumes (docs/functional.md §4).
    public static let events = [
        "SessionStart", "SessionEnd", "UserPromptSubmit",
        "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "PermissionRequest", "PermissionDenied", "Notification",
        "Stop", "StopFailure", "SubagentStart", "SubagentStop",
        "PreCompact", "PostCompact",
    ]
    /// Our own entries, recognized for idempotent reinstall and uninstall.
    public static let ourMarker = "/Contents/MacOS/mysidepulse hook"

    public static func install(into root: [String: Any], command: String) -> [String: Any] {
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
            // for every event — the shape known to work.
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

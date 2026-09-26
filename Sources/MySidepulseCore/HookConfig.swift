import Foundation

/// What sets up each agent's hooks, as pure values: the entries MySidepulse
/// adds to Claude Code's `settings.json` and Codex's `hooks.json`, which hold
/// the same shape under the same key; the whole of Copilot's hook file
/// `~/.copilot/hooks/mysidepulse.json`; and the source of OpenCode's plugin.
/// File I/O and backups belong to `HookInstaller`.
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

    /// How many things are in place when an agent's hooks are set up: each of
    /// its events, or OpenCode's one plugin file.
    public static func setUpCount(for agent: AgentKind) -> Int {
        agent == .opencode ? 1 : events(for: agent).count
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

    /// Seconds the agent gives the hook: 5, but 3 for Codex's `SessionEnd`
    /// and `Interrupt`, which Codex caps at 3 s, warning at every start about
    /// a larger value and hashing it as 3 for its trust.
    public static func timeout(for event: String, agent: AgentKind) -> Int {
        agent == .codex && (event == "SessionEnd" || event == "Interrupt") ? 3 : 5
    }

    /// The group written for one event: one command hook, and for Claude
    /// Code a match-all matcher. `matcher` selects which tools a
    /// PreToolUse/PostToolUse group fires for; a matcher-less group is
    /// accepted by Claude Code for the events with nothing to match on, but
    /// "*" is what its docs prescribe for every event, the shape known to
    /// work. Codex reads a missing matcher as match-all and hashes the entry
    /// for its trust (`CodexHookTrust`), so its entry carries none.
    public static func entry(for event: String, command: String, agent: AgentKind) -> [String: Any] {
        var group: [String: Any] = [
            "hooks": [["type": "command", "command": command, "timeout": timeout(for: event, agent: agent)]],
        ]
        if agent != .codex { group["matcher"] = "*" }
        return group
    }

    /// Our entry for each of the agent's events, appended after every group
    /// already there: Codex names a hook's trust after its group's index, so
    /// a stranger's group keeps its index and its trust.
    public static func install(into root: [String: Any], command: String,
                               agent: AgentKind = .claude) -> [String: Any] {
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
        for event in events(for: agent) {
            // An event whose value is not an array is a shape we do not
            // understand. Leave it exactly as it is rather than clobber it;
            // `doctor` reporting the hook as missing is the honest signal.
            if let existing = hooks[event], !(existing is [Any]) { continue }
            var groups = (hooks[event] as? [Any]) ?? []
            groups.append(entry(for: event, command: command, agent: agent))
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

    /// The index, in the event's array, of the group holding `command`:
    /// Codex names a hook's trust after it.
    public static func installedGroupIndex(in root: [String: Any], event: String, command: String) -> Int? {
        guard let hooks = root["hooks"] as? [String: Any], let groups = hooks[event] as? [Any] else { return nil }
        return groups.firstIndex { element in
            guard let group = element as? [String: Any] else { return false }
            return ((group["hooks"] as? [Any]) ?? []).contains {
                ($0 as? [String: Any])?["command"] as? String == command
            }
        }
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

    // MARK: GitHub Copilot — ~/.copilot/hooks/mysidepulse.json

    /// The end of the path an entry of ours runs, whichever copy of the app
    /// wrote it.
    static let ourBinarySuffix = "/Contents/MacOS/mysidepulse"

    /// The arguments of our entry for one Copilot event. A camelCase payload
    /// names no event, so the entry names it.
    public static func copilotArguments(event: String) -> [String] {
        ["hook", "--agent", "copilot", "--event", event]
    }

    /// The whole of Copilot's hook file, which MySidepulse owns: one entry
    /// per event in the `exec` form, which runs the CLI with no shell between
    /// Copilot and it, 5 s at most.
    public static func copilotFile(cliPath: String) -> [String: Any] {
        var hooks: [String: Any] = [:]
        for event in copilotEvents {
            hooks[event] = [["type": "command", "exec": cliPath,
                             "args": copilotArguments(event: event), "timeoutSec": 5] as [String: Any]]
        }
        return ["version": 1, "hooks": hooks]
    }

    /// Whether one entry of Copilot's file is ours: it runs a `mysidepulse`
    /// inside an app bundle, any copy of it, with `hook --agent copilot`.
    public static func isOurCopilotEntry(_ entry: Any) -> Bool {
        guard let entry = entry as? [String: Any],
              let exec = entry["exec"] as? String, exec.hasSuffix(ourBinarySuffix),
              let args = entry["args"] as? [String] else { return false }
        return args.starts(with: ["hook", "--agent", "copilot"])
    }

    /// The `exec` path of our entry for one Copilot event, or nil when none of ours is there. The doctor
    /// checks it still exists on disk, the same bar as Claude Code's and Codex's hook binary.
    public static func copilotEntryExec(in root: [String: Any], event: String) -> String? {
        guard let hooks = root["hooks"] as? [String: Any], let entries = hooks[event] as? [Any] else { return nil }
        for entry in entries where isOurCopilotEntry(entry) {
            return (entry as? [String: Any])?["exec"] as? String
        }
        return nil
    }

    /// Whether a parsed Copilot hook file is MySidepulse's alone, and so may
    /// be rewritten or deleted: nothing but `version` and `hooks`, and every
    /// entry in `hooks` ours. A key or an entry anyone else put there makes it
    /// theirs.
    public static func copilotFileIsOurs(_ root: [String: Any]) -> Bool {
        guard Set(root.keys).isSubset(of: ["version", "hooks"]) else { return false }
        guard let hooks = root["hooks"] else { return true }
        guard let events = hooks as? [String: Any] else { return false }
        return events.values.allSatisfy { value in
            guard let entries = value as? [Any] else { return false }
            return entries.allSatisfy(isOurCopilotEntry)
        }
    }

    /// How many of Copilot's events run this CLI with their own name.
    public static func copilotEventsSetUp(in root: [String: Any], cliPath: String) -> Int {
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        return copilotEvents.filter { event in
            (hooks[event] as? [Any] ?? []).contains { element in
                guard let entry = element as? [String: Any] else { return false }
                return entry["exec"] as? String == cliPath
                    && entry["args"] as? [String] == copilotArguments(event: event)
            }
        }.count
    }

    /// Whether Copilot runs no user hook at all: `disableAllHooks: true` in
    /// `~/.copilot/settings.json`, or in `~/.copilot/config.json`, whose
    /// whole-line `//` comments are not JSON. A file that is absent or does
    /// not parse turns nothing off.
    public static func copilotHooksDisabled(settingsText: String?, configText: String?) -> Bool {
        [settingsText, configText].contains { text in
            guard let text, let root = jsonObject(strippingLineComments: text) else { return false }
            return root["disableAllHooks"] as? Bool == true
        }
    }

    static func jsonObject(strippingLineComments text: String) -> [String: Any]? {
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        return (try? JSONSerialization.jsonObject(with: Data(kept.utf8))) as? [String: Any]
    }

    // MARK: OpenCode — ~/.config/opencode/plugins/mysidepulse.js

    /// The plugin's id. OpenCode refuses a second plugin with an id already
    /// loaded, so it is MySidepulse's own.
    public static let opencodePluginId = "io.mysidepulse.app.opencode"

    /// Whether a plugin file is ours: it names the hook command (`ourMarker`,
    /// in its first line) and our id.
    public static func isOurOpencodePlugin(_ text: String) -> Bool {
        text.contains(ourMarker) && text.contains(opencodePluginId)
    }

    /// Whether a plugin file is set up for this CLI: byte for byte what this
    /// bundle writes.
    public static func isCurrentOpencodePlugin(_ text: String, cliPath: String) -> Bool {
        text == opencodePlugin(cliPath: cliPath)
    }

    /// The plugin OpenCode 2 loads from its global plugins folder, with no
    /// registration and no trust step, and reloads within a second of any
    /// change. It is OpenCode's v2 shape, `export default { id, setup(ctx) }`,
    /// reading `ctx.event.subscribe()`; a v1 plugin fails to load. OpenCode
    /// starts one instance per open location, and every instance sees every
    /// location's events, so the event id decides which one forwards. It runs
    /// the hook once per forwarded event, one at a time in event order, 2 s
    /// at most each, with one small JSON object on its stdin that holds no
    /// text, input, output, answer or path. A subagent's events name its top
    /// session as `parent_id`, however deep it runs, its parent deleted or not. It never throws and never
    /// blocks OpenCode. Tested against a real OpenCode 2.0.17 server.
    public static func opencodePlugin(cliPath: String) -> String {
        let command = self.command(cliPath: cliPath, agent: .opencode)
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let args = ([cliPath] + ["hook", "--agent", "opencode"]).map(javaScriptString).joined(separator: ", ")
        return """
        // MySidepulse: runs \(command) on OpenCode's session events.
        // Written at ~/.config/opencode/plugins/mysidepulse.js by MySidepulse, which removes it; OpenCode 2 loads it by itself.
        // One small JSON object on the hook's stdin per lifecycle event. It never blocks OpenCode and never throws.
        \(pluginImport)

        const COMMAND = [\(args)]
        const ID = \(javaScriptString(opencodePluginId))

        // Every instance of this plugin in one OpenCode server shares this state. OpenCode loads a global
        // plugin once per open location, and every instance receives the events of every location, so the
        // event id decides which instance forwards.
        const SHARED = Symbol.for(`${ID}:1`)
        const LIMIT = 2048
        const DEPTH = 32

        const FORWARDED = new Set([
          "session.created",
          "session.forked",
          "session.deleted",
          "session.inbox.enqueued",
          "session.execution.started",
          "session.execution.succeeded",
          "session.execution.failed",
          "session.execution.interrupted",
          "session.tool.called",
          "session.tool.success",
          "session.tool.failed",
          "permission.asked",
          "permission.replied",
          "form.created",
          "form.replied",
          "form.cancelled",
          "session.compaction.started",
          "session.compaction.ended",
          "session.compaction.failed",
        ])

        function shared() {
          const state = globalThis[SHARED]
          if (state) return state
          return (globalThis[SHARED] = { seen: new Set(), tools: new Map(), parents: new Map(), tail: Promise.resolve(), pending: 0 })
        }

        function bounded(collection, key, value) {
          if (collection instanceof Map) collection.set(key, value)
          else collection.add(key)
          if (collection.size > LIMIT) collection.delete(collection.keys().next().value)
        }

        function text(value) {
          return typeof value === "string" && value.length > 0 && value.length <= 200 ? value : undefined
        }

        // The top session a subagent's session runs under, however deep, or undefined for a top session.
        // A cycle or a chain past DEPTH stops the walk where it is. A deleted session keeps its link, so a
        // subagent that outlives its parent still finds the top; LIMIT bounds the map.
        function top(state, sessionID) {
          const visited = new Set([sessionID])
          let current = sessionID
          for (let hops = 0; hops < DEPTH; hops++) {
            const parent = state.parents.get(current)
            if (!parent || visited.has(parent)) break
            visited.add(parent)
            current = parent
          }
          return current === sessionID ? undefined : current
        }

        function payload(state, event) {
          const data = event.data && typeof event.data === "object" ? event.data : {}
          const type = event.type
          const sessionID = text(data.sessionID) ?? text(data.form?.sessionID)
          if (type === "session.created" && sessionID && text(data.parentID)) bounded(state.parents, sessionID, data.parentID)
          const out = { hook_event_name: type, session_id: sessionID ?? null, event_time: event.created, opencode_pid: process.pid }
          const parent = sessionID ? top(state, sessionID) : undefined
          if (parent) out.parent_id = parent

          switch (type) {
            case "session.inbox.enqueued":
              if (data.item?.type !== "user") return undefined
              out.delivery = text(data.item.delivery) ?? null
              break
            case "session.execution.succeeded":
              out.status = "succeeded"
              break
            case "session.execution.failed":
              out.status = "failed"
              out.error_name = text(data.error?.type) ?? null
              break
            case "session.execution.interrupted":
              out.status = "interrupted"
              out.reason = text(data.reason) ?? null
              break
            case "session.tool.called":
            case "session.tool.success":
            case "session.tool.failed":
              out.tool_use_id = text(data.id) ?? null
              out.tool_name = state.tools.get(data.id) ?? null
              if (type !== "session.tool.called") state.tools.delete(data.id)
              if (type === "session.tool.failed") out.error_name = text(data.error?.type) ?? null
              break
            case "permission.asked":
              out.permission = text(data.action) ?? null
              break
            case "permission.replied":
              out.status = text(data.reply) ?? null
              break
            case "form.created":
              out.question = data.form?.metadata?.kind === "question"
              break
            case "session.compaction.started":
            case "session.compaction.ended":
            case "session.compaction.failed":
              out.reason = text(data.reason) ?? null
              break
          }
          return out
        }

        // One hook process at a time, in event order, so the journal keeps OpenCode's order.
        // A hook that hangs holds the queue for at most two seconds; a full queue drops new events.
        function launch(message) {
          return new Promise((resolve) => {
            let settled = false
            const finish = () => {
              if (settled) return
              settled = true
              clearTimeout(timer)
              resolve()
            }
            const timer = setTimeout(finish, 2000)
            try {
              const child = spawn(COMMAND[0], COMMAND.slice(1), { stdio: ["pipe", "ignore", "ignore"], detached: true })
              child.on("error", finish)
              child.on("exit", finish)
              child.stdin.on("error", () => {})
              child.stdin.end(JSON.stringify(message) + "\\n")
              child.unref()
            } catch {
              finish()
            }
          })
        }

        function enqueue(state, message) {
          if (state.pending >= 256) return
          state.pending++
          state.tail = state.tail
            .then(() => launch(message))
            .catch(() => {})
            .then(() => {
              state.pending--
            })
        }

        function handle(event) {
          if (!event || typeof event.type !== "string") return
          const state = shared()
          if (event.type === "session.tool.input.started") {
            if (text(event.data?.id) && text(event.data?.name)) bounded(state.tools, event.data.id, event.data.name)
            return
          }
          if (!FORWARDED.has(event.type)) return
          if (typeof event.id !== "string" || state.seen.has(event.id)) return
          bounded(state.seen, event.id)
          const message = payload(state, event)
          if (message) enqueue(state, message)
        }

        export default {
          id: ID,
          setup(ctx) {
            const controller = new AbortController()
            void (async () => {
              try {
                for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
                  try {
                    handle(event)
                  } catch {}
                }
              } catch {}
            })()
            return () => controller.abort()
          },
        }

        """
    }

    /// The plugin's one import, kept off the start of a line of Swift: the
    /// purity check reads every such line as an import of Core's.
    static let pluginImport = #"import { spawn } from "node:child_process""#

    /// A JavaScript string literal: JSON's, which JavaScript reads the same.
    static func javaScriptString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}

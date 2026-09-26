import Foundation
import MySidepulseCore

public enum HookCommand {
    /// What `mysidepulse hook` was told: `--agent claude|codex|copilot|opencode`
    /// and, for Copilot, whose payloads name no event, `--event NAME`. Nothing
    /// here is an error: an unknown agent, a flag without its value or a flag
    /// it does not know is simply not there, since the hook must never fail.
    public struct Arguments: Equatable {
        public var agent: AgentKind?
        public var event: String?
        public init(agent: AgentKind?, event: String?) { self.agent = agent; self.event = event }

        public init(_ args: [String]) {
            func value(of flag: String) -> String? {
                guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else { return nil }
                let value = args[index + 1]
                return value.hasPrefix("--") ? nil : value
            }
            agent = value(of: "--agent").flatMap { AgentKind(rawValue: $0.lowercased()) }
            event = value(of: "--event").map { String($0.prefix(64)) }
        }
    }

    /// Who fired the hook, read from its ancestry: the nearest process of the
    /// agent the flag names, or with no flag the nearest agent process the
    /// walk recognises, whichever agent that is. OpenCode's payload names its
    /// server, which is taken when it is an OpenCode ancestor of the hook.
    public static func origin(for chain: [ProcWalk.ProcInfo], agent: AgentKind?, input: Data) -> ProcWalk.Origin {
        let claimed = agent == .opencode ? Trim.opencodePid(fromHookPayload: input.prefix(K.hookStdinMaxBytes)) : nil
        return ProcWalk.classify(chain, agent: agent, claimed: claimed)
    }

    /// The entire hook path. Must never block on anything but the single
    /// append, and must always report success to the agent: Copilot denies a
    /// tool whose hook fails, so no form of it, bad input included, exits
    /// other than 0. `agent` is who fired the hook: the command line's
    /// `--agent`, which always wins, or the nearest agent process in the
    /// chain, or Claude, whose hooks carry no flag because they never needed
    /// one. A Copilot payload takes its event from `event` and writes nothing
    /// for a subagent's session (`CopilotSessionState`, under
    /// `$COPILOT_HOME` when the environment sets it); an OpenCode payload
    /// is mapped by `Trim.opencodeEvent`, and an event outside its mapping
    /// writes nothing.
    public static func run(input: Data, environment: [String: String],
                           journalURL: URL, now: Date,
                           origin: ProcWalk.Origin?, agent: AgentKind? = nil, event name: String? = nil,
                           home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                           directoryExists: (String) -> Bool = HookCommand.directoryExists) -> Int32 {
        if environment["MYSIDEPULSE_DISABLE"] == "1" { return 0 }
        // Spec §1: 8 MB cap. A payload past it parses as garbage and becomes
        // a ParseError line, which is the honest record of "too big to trust".
        let payload = input.prefix(K.hookStdinMaxBytes)
        let speaker = agent ?? origin?.agent ?? .claude
        var event: JournalEvent
        switch agent {
        case .copilot:
            let trimmed = Trim.copilotEvent(fromHookPayload: payload, named: name, loggedAt: now)
            let root = CopilotSessionState.root(environment: environment, home: home)
            guard let kept = CopilotSessionState.line(trimmed, root: root, directoryExists: directoryExists)
            else { return 0 }
            event = kept
        case .opencode:
            guard let mapped = Trim.opencodeEvent(fromHookPayload: payload, loggedAt: now) else { return 0 }
            event = mapped
        case .claude, .codex, nil:
            event = Trim.journalEvent(fromHookPayload: payload, agent: speaker, loggedAt: now)
        }
        event.agent = speaker
        if let origin {
            event.agentPid = origin.agentPid
            event.hostAppPid = origin.hostAppPid
            if let bundlePath = origin.hostBundlePath {
                event.hostBundleId = ProcWalk.bundleIdentifier(forBundleAt: bundlePath)
            }
            // The tab-level identity: the terminal tab Claude is displayed
            // in, which is Claude's controlling terminal ONLY when the chain
            // proves a shell under the host app holds it. A daemon-hosted
            // session's pty is not a tab and is recorded as no tab at all —
            // see ProcWalk.tabTTY.
            event.tty = origin.tabTTY
        }
        try? FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let line = try? Trim.cappedLine(event) {
            JournalWriter.append(line, to: journalURL)
        }
        return 0
    }

    public static func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

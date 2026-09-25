import Foundation
import MySidepulseCore

public enum HookCommand {
    /// The entire hook path. Must never block on anything but the single
    /// append, and must always report success to Claude Code.
    /// `agent` is who fired the hook: the command line's `--agent`, or the
    /// nearest agent process in the chain, or Claude, whose hooks carry no
    /// flag because they never needed one.
    public static func run(input: Data, environment: [String: String],
                           journalURL: URL, now: Date,
                           origin: ProcWalk.Origin?, agent: AgentKind? = nil) -> Int32 {
        if environment["MYSIDEPULSE_DISABLE"] == "1" { return 0 }
        // Spec §1: 8 MB cap. A payload past it parses as garbage and becomes
        // a ParseError line, which is the honest record of "too big to trust".
        var event = Trim.journalEvent(fromHookPayload: input.prefix(K.hookStdinMaxBytes),
                                      loggedAt: now)
        event.agent = agent ?? origin?.agent ?? .claude
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
}

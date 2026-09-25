import Foundation

/// A session state worth telling the user about when they are not at the
/// machine. Emitted on ENTERING `.done` or `.waiting`, never on a raw Stop.
public enum AlertKind: Equatable {
    case finished
    case needsYou(WaitReason)
}

public struct Alert: Equatable {
    public let sessionId: String
    /// Whose session: the push is titled with the agent's name and its click
    /// lands on that agent's web app.
    public let agent: AgentKind
    public let kind: AlertKind
    public let at: Date
    public init(sessionId: String, agent: AgentKind = .claude, kind: AlertKind, at: Date) {
        self.sessionId = sessionId; self.agent = agent; self.kind = kind; self.at = at
    }
}

/// The push copy: the only user-facing strings that leave the machine. Under
/// exact-text test, in both languages, for the same reason the LED programs
/// are: nothing else checks them. The title is the product's name and the tag
/// is a wire value, so neither is translated.
public enum AlertCopy {
    /// The push's title: which agent is talking.
    public static func title(for agent: AgentKind) -> String { agent.productName }

    /// The bodies are the same words for either agent: the title already
    /// says who.
    public static func message(for kind: AlertKind) -> String {
        let t = Loc.alerts
        switch kind {
        case .finished: return t.finished
        case .needsYou(.question): return t.question
        case .needsYou(.permission): return t.permission
        case .needsYou(.plan): return t.plan
        case .needsYou(.error): return t.error
        }
    }

    public static func tag(for kind: AlertKind) -> String {
        switch kind {
        case .finished: return "white_check_mark"
        case .needsYou(.question): return "speech_balloon"
        case .needsYou(.permission): return "lock"
        case .needsYou(.plan): return "clipboard"
        case .needsYou(.error): return "rotating_light"
        }
    }
}

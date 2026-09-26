import Foundation

/// The coding agents the strip follows, in the order every roll, sentence and
/// list follows: Claude Code, Codex, GitHub Copilot, OpenCode. The raw value
/// is what the journal records under `agent`, what `mysidepulse hook --agent`
/// takes and what the hooks are installed for, so renaming a case is a
/// migration.
public enum AgentKind: String, Codable, CaseIterable, Equatable, Sendable {
    case claude, codex, copilot, opencode

    /// The product's name: a push's title, a doctor line. Never translated.
    public var productName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .copilot: return "GitHub Copilot"
        case .opencode: return "OpenCode"
        }
    }

    /// The name a sentence uses. Never translated either.
    public var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .copilot: return "Copilot"
        case .opencode: return "OpenCode"
        }
    }

    /// Where a push's click lands when the session has no link of its own:
    /// the agent's own web page.
    public var homeLink: String {
        switch self {
        case .claude: return "https://claude.ai/code"
        case .codex: return "https://chatgpt.com/codex"
        case .copilot: return "https://github.com/copilot"
        case .opencode: return "https://opencode.ai"
        }
    }
}

/// Which agents a display state is about: one of them, or several at once.
/// The order of `kinds` is `AgentKind`'s, and every roll, sentence and label
/// follows it.
public struct Agents: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let claude = Agents(rawValue: 1)
    public static let codex = Agents(rawValue: 2)
    public static let copilot = Agents(rawValue: 4)
    public static let opencode = Agents(rawValue: 8)
    /// Every agent the strip follows.
    public static let all = Agents(AgentKind.allCases.map(Agents.init))

    public init(_ kind: AgentKind) {
        switch kind {
        case .claude: self = .claude
        case .codex: self = .codex
        case .copilot: self = .copilot
        case .opencode: self = .opencode
        }
    }

    /// The agents in the set, in `AgentKind`'s order.
    public var kinds: [AgentKind] {
        AgentKind.allCases.filter { contains(Agents($0)) }
    }
}

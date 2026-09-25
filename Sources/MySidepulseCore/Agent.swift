import Foundation

/// The coding agents the strip follows. The raw value is what the journal
/// records under `agent`, what `mysidepulse hook --agent` takes and what the
/// hooks are installed for, so renaming a case is a migration.
public enum AgentKind: String, Codable, CaseIterable, Equatable, Sendable {
    case claude, codex

    /// The product's name: a push's title, a doctor line. Never translated.
    public var productName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// The name a sentence uses. Never translated either.
    public var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    /// Where a push's click lands when the session has no link of its own:
    /// Claude Code's web app, or Codex's.
    public var homeLink: String {
        switch self {
        case .claude: return "https://claude.ai/code"
        case .codex: return "https://chatgpt.com/codex"
        }
    }
}

/// Which agents a display state is about: one of them, or both at once. The
/// order of `kinds` is fixed, Claude then Codex, and every roll, sentence and
/// label follows it.
public struct Agents: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let claude = Agents(rawValue: 1)
    public static let codex = Agents(rawValue: 2)
    public static let both: Agents = [.claude, .codex]

    public init(_ kind: AgentKind) {
        switch kind {
        case .claude: self = .claude
        case .codex: self = .codex
        }
    }

    /// The agents in the set, Claude first.
    public var kinds: [AgentKind] {
        AgentKind.allCases.filter { contains(Agents($0)) }
    }
}

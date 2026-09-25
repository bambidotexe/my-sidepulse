@testable import MySidepulseCore

/// The bare names are Claude's states alone: `.working` is `.working(.claude)`.
/// Every state about an agent names its agents; the tests written when only
/// Claude was followed keep reading as they did, and a test about Codex or
/// about both says so in full.
extension DisplayState {
    static let working: DisplayState = .working(.claude)
    static let waiting: DisplayState = .waiting(.claude)
    static let done: DisplayState = .done(.claude)
}

extension SplitAlert {
    static let waiting: SplitAlert = .waiting(.claude)
    static let done: SplitAlert = .done(.claude)
}

extension SplitWork {
    static let working: SplitWork = .working(.claude)
}

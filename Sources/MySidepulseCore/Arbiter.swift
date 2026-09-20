import Foundation

public enum LedMode: Equatable {
    case auto, off
    case color(String)
    /// A named fun program (`rainbow`, …) forced exactly like a colour:
    /// persisted, shortcut-friendly, and held until set back to auto.
    case effect(String)

    public static func parse(_ raw: String) -> LedMode? {
        let s = raw.lowercased()
        if s == "auto" { return .auto }
        if s == "off" { return .off }
        if LedEffects.names.contains(s) { return .effect(s) }
        if isRGBHex(s) { return .color(s) }
        return nil
    }

    /// `#rrggbb`, six ASCII hex digits — nothing else. Deliberately not
    /// `UInt32(_:radix:)`, which accepts a leading sign and would let
    /// "#+00000" through to the device, where an unparseable program makes
    /// the strip blink red six times.
    static func isRGBHex(_ s: String) -> Bool {
        guard s.count == 7, s.hasPrefix("#") else { return false }
        return s.dropFirst().allSatisfy { $0.isHexDigit && $0.isASCII }
    }

    public var configValue: String {
        switch self {
        case .auto: return "auto"
        case .off: return "off"
        case .color(let hex): return hex
        case .effect(let name): return name
        }
    }

    /// What one toggle key should do next. Only `off` returns to `auto`; a
    /// forced colour toggles to `off` rather than to `auto`, so the shortcut
    /// keeps a single predictable direction — press to make the strip stop,
    /// press again to hand it back to the rules.
    public func toggled() -> LedMode {
        self == .off ? .auto : .off
    }
}

public enum Arbiter {
    /// Precedence, top wins: manual override, battery critical, plug/unplug
    /// glance, then the most urgent unacknowledged session or job. `now` is
    /// data, not a hidden clock: it is only read to ask whether an
    /// acknowledged wait still has helper work in flight behind it.
    public static func decide(mode: LedMode, power: PowerState?, glanceActive: Bool,
                              sessions: [Session], jobs: [Job] = [], now: Date) -> DisplayState {
        switch mode {
        case .off: return .off
        case .color(let hex): return .manualColor(hex)
        case .effect(let name): return .effect(name)
        case .auto: break
        }
        if BatteryRules.isCritical(power) { return .batteryCritical }
        if glanceActive, let power, power.present { return .batteryGlance }
        // Two questions decide the strip: is anything asking for attention
        // or finished (the ALERT), and is anything still running (the
        // WORK)? When both answer yes the strip splits — alert on the left
        // zone, work on the rest — because a finish or a request must be
        // visible even while another session still runs. Alone, either
        // takes the whole strip.
        //
        // Within each, Claude outranks a job at every matching rung, and
        // needs-you outranks finished.
        // Callers pass JobStore.displayable, which has already dropped jobs
        // still inside their show-after — that gate needs a clock. So does
        // exactly one thing here: whether an ACKNOWLEDGED wait still has
        // helper work running behind it, which counts as work rather than
        // darkness — seeing the amber answered "does Claude need me", not
        // "is the build over". An acknowledged wait with nothing running
        // shows nothing: nothing IS happening until the user answers.
        // waiting(error) is never work — that turn is dead.
        // presentedState, not state: an alert that has not yet proved it
        // will stick still shows as whatever it is replacing.
        let alert: SplitAlert?
        if sessions.contains(where: { $0.presentedState.isWaiting && !$0.acknowledged }) {
            alert = .waiting
        } else if jobs.contains(where: { $0.presentedState == .failed && !$0.acknowledged }) {
            alert = .jobFailed
        } else if sessions.contains(where: { $0.presentedState == .done && !$0.acknowledged }) {
            alert = .done
        } else if jobs.contains(where: { $0.presentedState == .succeeded && !$0.acknowledged }) {
            alert = .jobSucceeded
        } else {
            alert = nil
        }
        let work: SplitWork?
        if sessions.contains(where: { $0.presentedState == .working
            || ($0.acknowledged && $0.presentedState.isOpenWaiting
                && ($0.hasLiveHelpers(at: now) || !$0.backgroundIds.isEmpty)) }) {
            work = .working
        } else if jobs.contains(where: { $0.presentedState == .running }) {
            work = .jobRunning
        } else {
            work = nil
        }
        switch (alert, work) {
        case (let alert?, let work?):
            return .split(alert: alert, work: work)
        case (.waiting, nil): return .waiting
        case (.jobFailed, nil): return .jobFailed
        case (.done, nil): return .done
        case (.jobSucceeded, nil): return .jobSucceeded
        case (nil, .working): return .working
        case (nil, .jobRunning): return .jobRunning
        case (nil, nil): return .off
        }
    }
}

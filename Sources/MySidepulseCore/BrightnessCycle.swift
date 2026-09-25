import Foundation

/// `mysidepulse brightness cycle`: one key that walks the strip's brightness
/// up in steps even to the eye (`BrightnessCurve`), then off, then back from
/// the first step. With 3 steps, from 50 %: 67 % → 100 % → off → 33 % → 67 %.
///
/// Off is the mode `off`, the same as `led toggle`'s, so the strip goes dark
/// by the one rule that already outranks everything; the press after it
/// brings back the mode the off step replaced, at the first step.
public enum BrightnessCycle {
    public enum Step: Equatable {
        case off
        /// A brightness in 1…255, the device's scale.
        case level(Int)
    }

    /// The step levels on the device's scale: step k of n looks like k/n of
    /// full (`BrightnessCurve`), never below 1, the device's lowest.
    public static func levels(steps: Int) -> [Int] {
        let n = max(1, steps)
        return (1...n).map { k in BrightnessCurve.device(perceived: Double(k) / Double(n)) }
    }

    /// Where one press goes. From off, the first step. Otherwise the first
    /// step brighter than now by more than `K.brightnessCycleSlackPercent`,
    /// compared in whole perceived percent, so a brightness a unit under a
    /// step counts as that step and the press moves on visibly. Past the last
    /// step, off.
    public static func next(after brightness: Int, modeIsOff: Bool, steps: Int) -> Step {
        let levels = levels(steps: steps)
        if modeIsOff { return .level(levels[0]) }
        let now = percent(brightness)
        if let brighter = levels.first(where: { percent($0) > now + K.brightnessCycleSlackPercent }) {
            return .level(brighter)
        }
        return .off
    }

    /// The mode the press after the off step brings back: the one the off
    /// step replaced, saved in `config.json`, or `auto` when there is none.
    public static func modeAfterOff(saved: String?) -> LedMode {
        guard let mode = saved.flatMap(LedMode.parse), mode != .off else { return .auto }
        return mode
    }

    /// Whether LED 0 lights white now: within `K.brightnessPreviewSeconds` of
    /// the last press, and only while the strip would be dark. Over an
    /// animation the white would cost a second restart when it left, since
    /// the strip only takes whole programs; there, the animation itself shows
    /// the new brightness. Never while the mode is `off`.
    public static func previewShows(mode: LedMode, painted: DisplayState, until: Date?,
                                    now: Date) -> Bool {
        guard mode != .off, painted == .off, let until else { return false }
        return now < until
    }

    /// A brightness as the whole perceived percent the command prints.
    public static func percent(_ brightness: Int) -> Int {
        BrightnessCurve.percent(device: brightness)
    }
}

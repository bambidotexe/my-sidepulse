import Foundation

/// `mysidepulse brightness cycle`: one key that walks the strip's brightness
/// up in equal steps, then off, then back from the first step. With 3 steps,
/// from 50 %: 67 % → 100 % → off → 33 % → 67 %.
///
/// Off is the mode `off`, the same as `led toggle`'s, so the strip goes dark
/// by the one rule that already outranks everything; the press after it hands
/// the strip back to `auto` at the first step.
public enum BrightnessCycle {
    public enum Step: Equatable {
        case off
        /// A brightness in 1…255, the device's scale.
        case level(Int)
    }

    /// The step levels on the device's scale: step k of n is k/n of 255,
    /// rounded, and never below 1, the device's lowest.
    public static func levels(steps: Int) -> [Int] {
        let n = max(1, steps)
        return (1...n).map { k in max(1, Int((255.0 * Double(k) / Double(n)).rounded())) }
    }

    /// Where one press goes. From off, the first step. Otherwise the first
    /// step brighter than now, compared in whole percent, so a brightness set
    /// by hand a unit under a step (the slider's 127 for 50 %) counts as that
    /// step and the press moves on visibly instead of by one unit. Past the
    /// last step, off.
    public static func next(after brightness: Int, modeIsOff: Bool, steps: Int) -> Step {
        let levels = levels(steps: steps)
        if modeIsOff { return .level(levels[0]) }
        let now = percent(brightness)
        if let brighter = levels.first(where: { percent($0) > now }) { return .level(brighter) }
        return .off
    }

    /// A brightness as the whole percent the command prints.
    public static func percent(_ brightness: Int) -> Int {
        Int((Double(max(0, min(255, brightness))) * 100 / 255).rounded())
    }
}

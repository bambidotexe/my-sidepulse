import Foundation

/// Brightness as the eye sees it. The strip's `brightness N` (1…255) scales
/// the LEDs' power in a straight line and the eye does not: a third of the
/// power already looks like most of full. So every brightness the owner sets,
/// by the Strip page's slider or by `brightness cycle`, is a perceived
/// fraction, and the value sent to the strip is `255 · fraction^γ`
/// (`K.brightnessGamma`). The stored value stays the strip's own 1…255.
public enum BrightnessCurve {
    /// The strip's value for a perceived fraction of full, 0…1. Never below
    /// 1, the strip's lowest.
    public static func device(perceived fraction: Double) -> Int {
        let f = max(0, min(1, fraction))
        return max(1, min(255, Int((255 * pow(f, K.brightnessGamma)).rounded())))
    }

    /// The perceived fraction of full a strip value gives, 0…1.
    public static func perceived(device value: Int) -> Double {
        pow(Double(max(0, min(255, value))) / 255, 1 / K.brightnessGamma)
    }

    /// A strip value as the whole perceived percent the window and the
    /// command show.
    public static func percent(device value: Int) -> Int {
        Int((perceived(device: value) * 100).rounded())
    }

    public static func device(percent: Int) -> Int {
        device(perceived: Double(percent) / 100)
    }

    /// A strip value as the slider position that shows it: its perceived
    /// percent on the slider's grid (`K.brightnessSliderStepPercent`), never
    /// below the first position.
    public static func sliderPercent(device value: Int) -> Int {
        let step = Double(K.brightnessSliderStepPercent)
        let snapped = Int((Double(percent(device: value)) / step).rounded() * step)
        return max(K.brightnessSliderStepPercent, min(100, snapped))
    }
}

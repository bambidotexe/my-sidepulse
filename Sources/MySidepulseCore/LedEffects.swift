import Foundation

/// Named fun programs — `mysidepulse led rainbow` and the Playground's Fun
/// cards. An effect is a full LedMode: forced like a colour, persisted like a
/// colour, and outranked by nothing (rung 1 of the ladder).
///
/// Every program is assembled from token shapes the device already accepts —
/// per-LED assignment segments (the battery bar's), whole-strip breaths,
/// `repeat` — never from invented syntax. The rotating effects sequence three
/// glance-shaped frames in a loop, each crossfading into the next over its
/// transition time, so every LED stays lit and the colours travel; the
/// working roll's single-pulse shape would not do — its ~50 % duty renders
/// as a travelling snake with dark gaps, not the all-on drift the settings
/// window shows. Three frames is not a taste decision: the device
/// takes at most 512 bytes, and that ceiling is what sets the frame count.
/// Writing each segment's duration in seconds rather than milliseconds
/// ("3s", not "3000ms") drops an 8-LED frame line from 127 bytes to 103,
/// which is exactly what buys a FOURTH frame — 437 bytes with a brightness
/// line. Rainbow spends it: eight hues
/// stepping by two, the smallest step that still closes the loop in four
/// frames. Aurora, ocean and lava keep three hues stepping by one.
///
/// Eight frames — a hue per LED shifting one position at a time — is not
/// merely tight, it is impossible: eight segments cost 79 bytes before any
/// duration at all, so six frames is the ceiling even with none, and a frame
/// without a duration jumps instead of crossfading. Stepping by two is the
/// real limit, and the wheel below is ordered so it does not show: each hue
/// and the one two along average, in RGB, to roughly the hue between them,
/// so the crossfade travels through the colour it skips rather than
/// desaturating across it.
///
/// The palettes are starter values in the same dim range as K's calibrated
/// colours (channels ≤ 0x38); like everything the strip shows, retune them
/// only by eye on the device.
public enum LedEffects {
    /// Also the allowlist LedMode.parse accepts, so a typo can never reach
    /// the device as a program.
    public static let names = ["rainbow", "aurora", "ocean", "lava", "ember", "sparkle"]

    /// One step of a rotating effect's wheel per frame. The settings window
    /// renders previews from this same description (via wheelIndex), so the
    /// screen and the strip can only ever disagree in colour calibration.
    public struct Rotation: Equatable {
        public let wheel: [String]
        public let stepMs: Int
        /// Wheel positions advanced per frame.
        public let advance: Int
        /// Frames before the pattern repeats exactly.
        public var frames: Int { wheel.count / greatestCommonDivisor(wheel.count, advance) }
    }

    /// Eight hues at equal code values, one per LED on the Pro, none
    /// repeating. Orange and violet are the two hues that let a two-step
    /// crossfade pass through an intervening hue: red -> yellow averages to
    /// exactly this orange.
    ///
    /// Do not "correct" these for perceived brightness. The theory is sound
    /// — at equal code values the eye sees this yellow about 13x brighter
    /// than this blue, so on paper yellow blooms and blue shrinks — and a
    /// wheel flattened to one Rec.709 luma (yellow #111100, red #4b0000,
    /// blue #0000de) does measure even, but looks worse on the strip.
    /// Flattening drags the wheel down to what the blue channel can manage,
    /// which desaturates the bright hues and costs the midpoint property
    /// above, since RGB interpolation is linear in code value and not in
    /// luma. Whatever the numbers say, the strip is the authority here.
    static let rainbowWheel = ["#380000", "#381c00", "#383800", "#003800",
                               "#003838", "#000038", "#1c0038", "#380038"]
    static let auroraWaves = ["#003812", "#00332e", "#120038"]
    static let oceanWaves = ["#001238", "#003038", "#002e26"]
    static let lavaFlows = ["#380400", "#381400", "#300000"]
    static let emberGlow = "#381200"
    static let sparkleGlint = "#2e2e38"

    public static func rotation(for name: String) -> Rotation? {
        switch name {
        // Paced to the working roll: that wave moves one LED every
        // K.rollingStaggerMs (95 ms), and this moves two LEDs a frame, so
        // 200 ms is the same speed across the strip — 100 ms per LED, an
        // 0.8 s lap.
        //
        // 200 ms is also the fastest that still fits. It spells "0.2s", four
        // characters, which puts the 8-LED program at 501 of the device's 512
        // bytes; anything needing five ("190ms", "0.19s") costs 8 more and
        // overflows, dropping the wheel back to three frames.
        // testProgramsRespectDeviceLimits is the guard.
        case "rainbow": return Rotation(wheel: rainbowWheel, stepMs: 200, advance: 2)
        case "aurora": return Rotation(wheel: auroraWaves, stepMs: 900, advance: 1)
        case "ocean": return Rotation(wheel: oceanWaves, stepMs: 800, advance: 1)
        case "lava": return Rotation(wheel: lavaFlows, stepMs: 800, advance: 1)
        default: return nil
        }
    }

    /// Which wheel entry LED `led` shows during `frame`. The spacing spreads
    /// the wheel across however many LEDs there are, so the Dot's two LEDs
    /// get well-separated hues rather than neighbouring ones.
    public static func wheelIndex(_ rotation: Rotation, led: Int, frame: Int,
                                  ledCount: Int) -> Int {
        let spacing = max(1, rotation.wheel.count / max(1, ledCount))
        return (led * spacing + rotation.advance * frame) % rotation.wheel.count
    }

    public static func program(name: String, ledCount: Int) -> String? {
        if let rotation = rotation(for: name) {
            return rotationProgram(rotation, ledCount: ledCount)
        }
        switch name {
        case "ember":
            // The done-program shape at a fireside pace.
            return "off\n\(emberGlow) 3.2s pulse\nrepeat"
        case "sparkle":
            return sparkle(ledCount: ledCount)
        default:
            return nil
        }
    }

    /// Frame lines in the battery bar's exact segment shape, looped. No off
    /// line on purpose: the point is that the strip never goes dark.
    static func rotationProgram(_ rotation: Rotation, ledCount: Int) -> String {
        let count = max(2, min(8, ledCount))
        let lines = (0..<rotation.frames).map { frame in
            (0..<count)
                .map { led in
                    let hex = rotation.wheel[wheelIndex(rotation, led: led, frame: frame,
                                                        ledCount: count)]
                    return "\(led):\(hex) \(duration(ms: rotation.stepMs))"
                }
                .joined(separator: ";")
        }
        return (lines + ["repeat"]).joined(separator: "\n")
    }

    /// Short glints scattered across a long cycle. The slot permutation
    /// (i·5 mod n) keeps neighbours from lighting in order without needing
    /// randomness, which the exact-text tests could not hold still.
    static func sparkle(ledCount: Int) -> String {
        let count = max(2, min(8, ledCount))
        let cycleMs = 2880
        let segments = (0..<count)
            .map { i in
                let slot = (i * 5) % count
                return "\(i):\(sparkleGlint) 360ms pulse \(slot * (cycleMs / count))ms"
            }
            .joined(separator: "; ")
        return "off \(K.rollingFadeMs)ms cosine\n\(segments)\nrepeat"
    }

    /// The shorter of the two spellings the device accepts. Milliseconds are
    /// the working roll's ("760ms"); seconds are the vendor's own INIT.LED
    /// ("0.15s", "1s"). Neither is new syntax — but past one second the
    /// seconds form is shorter, and inside a 512-byte ceiling those
    /// characters are the difference between three frames and four.
    static func duration(ms: Int) -> String {
        if ms % 1000 == 0 { return "\(ms / 1000)s" }
        if ms % 100 == 0 { return "\(Double(ms) / 1000)s" }
        return "\(ms)ms"
    }

    static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var (a, b) = (a, b)
        while b != 0 { (a, b) = (b, a % b) }
        return max(1, a)
    }
}

import Foundation

/// What plays on the alert zone of a split display. Session states outrank
/// their job counterparts, and needs-you outranks finished — the same order
/// the full-strip ladder uses.
public enum SplitAlert: Equatable {
    case waiting, jobFailed, done, jobSucceeded
}

/// What plays on the rest of the strip under a split alert.
public enum SplitWork: Equatable {
    case working, jobRunning
}

public enum DisplayState: Equatable {
    case off
    case working
    case waiting
    case done
    case jobRunning
    case jobSucceeded
    case jobFailed
    /// An alert and running work at the same time: the alert takes the first
    /// `K.alertZoneLedsNeedsYou` or `K.alertZoneLedsFinished` LEDs, the work
    /// keeps the rest — a finish or a request must be visible even while
    /// another session still runs.
    case split(alert: SplitAlert, work: SplitWork)
    case batteryCritical
    case batteryGlance
    case manualColor(String)
    case effect(String)

    /// An unread notification: lit until seen, and cleared by focusing the
    /// window that owns it. Engine.sync() asks this rather than listing
    /// states, so a new alert state cannot silently miss acknowledgement.
    public var isAlertable: Bool {
        switch self {
        case .waiting, .done, .jobFailed, .jobSucceeded, .split: return true
        case .off, .working, .jobRunning, .batteryCritical, .batteryGlance, .manualColor,
             .effect:
            return false
        }
    }
}

public enum LedProgram {
    public static func ledCount(volumeName: String) -> Int {
        let name = volumeName.lowercased()
        if name.hasPrefix("sidepulsedot") { return 2 }
        if name.hasPrefix("sidepulsepro") { return 8 }
        return K.defaultLedCount
    }

    public static func program(for state: DisplayState, power: PowerState?,
                               ledCount: Int, brightness: Int,
                               palette: LedPalette = .standard) -> String {
        switch state {
        case .off:
            return "off"
        case .working:
            return applyBrightness(rolling(color: palette.working, ledCount: ledCount), brightness)
        case .waiting, .jobFailed:
            return applyBrightness(askBlink(palette: palette), brightness)
        case .done, .jobSucceeded:
            return applyBrightness("off\n\(palette.done) \(K.doneBreathSeconds)s pulse\nrepeat", brightness)
        case .jobRunning:
            return applyBrightness(rolling(color: palette.jobRunning, ledCount: ledCount), brightness)
        case .split(let alert, let work):
            return applyBrightness(
                splitProgram(alert: alert, work: work, ledCount: ledCount, palette: palette),
                brightness)
        case .batteryCritical:
            return applyBrightness(
                "off\n\(palette.batteryCritical) \(K.batteryCriticalBreathSeconds)s pulse\nrepeat",
                brightness)
        case .batteryGlance:
            guard let power else { return "off" }
            return applyBrightness(glanceBar(power: power, ledCount: ledCount, palette: palette),
                                   brightness)
        case .manualColor(let hex):
            return applyBrightness(hex, brightness)
        case .effect(let name):
            // Unknown names cannot get here through parse; "off" is the safe
            // answer for a config edited by hand into something else.
            return applyBrightness(LedEffects.program(name: name, ledCount: ledCount) ?? "off",
                                   brightness)
        }
    }

    /// Two fast pulses, a short gap, then a longer pause — read as "blink
    /// blink … blink blink". Whole-strip, so it is the same on the Dot's two
    /// LEDs as on the Pro's eight and needs no per-LED segments.
    ///
    /// Assembled only from shapes the device is already known to accept: the
    /// whole-strip `#hex <dur> pulse`, and `off <dur>`, which the vendor's
    /// own INIT.LED ends with (`off 1s`).
    /// A pulse returns to black on its own, so each `off` line is pure dark
    /// time — the gap that separates the two blinks, and the pause that
    /// separates the pairs. 6 lines, ~70 bytes: far inside the device's
    /// 20-line, 512-byte ceiling.
    static func askBlink(palette: LedPalette = .standard) -> String {
        let blink = "\(palette.needsYou) \(K.askBlinkMs)ms pulse"
        return ["off", blink, "off \(K.askBlinkGapMs)ms", blink,
                "off \(K.askBlinkPauseMs)ms", "repeat"].joined(separator: "\n")
    }

    static func rolling(color: String, ledCount: Int) -> String {
        let count = max(2, min(8, ledCount))
        let stagger = count == 2 ? K.rollingStaggerDotMs : K.rollingStaggerMs
        let segments = (0..<count)
            .map { "\($0):\(color) \(K.rollingPulseMs)ms pulse \($0 * stagger)ms" }
            .joined(separator: "; ")
        return "off \(K.rollingFadeMs)ms cosine\n\(segments)\nrepeat"
    }

    /// The zone an alert borrows: needs-you is wider than finished, and at
    /// least one LED always stays with the roll.
    /// Public because the settings replica renders from the same rule.
    public static func splitZone(alert: SplitAlert, ledCount: Int) -> Int {
        let wanted: Int
        switch alert {
        case .waiting, .jobFailed: wanted = K.alertZoneLedsNeedsYou
        case .done, .jobSucceeded: wanted = K.alertZoneLedsFinished
        }
        return max(1, min(wanted, ledCount - 1))
    }

    /// The alert zone on the left, the working roll on the rest — built
    /// entirely from shapes this strip has PROVEN:
    ///
    /// - a per-LED pulse returns to its PRE-pulse value, not to black, so
    ///   every split opens with a BASELINE frame assigning every LED (green
    ///   zone to its steady green, everything else to black) — without it
    ///   the gaps showed the previous program's colours;
    /// - a hold persists through later lines that do not reassign the LED,
    ///   which is what keeps a green zone steady under the pulse line;
    /// - scheduling the same LED twice in one line does NOT stack — the
    ///   strip renders a single pulse — so the amber pair is composed
    ///   ACROSS lines instead: pulse one on its own line (sequential lines
    ///   run to their content's end, giving exactly the blink's length),
    ///   then pulse two on the roll's line, delayed by the gap.
    ///
    /// Amber shape (needs-you / job failed), cycle ≈ 1.6 s on the Pro:
    ///     baseline (160 ms, all dark) → zone pulse one (200 ms) →
    ///     zone pulse two after a 70 ms delay, beside the roll's staggered
    ///     pulses (1235 ms) → repeat.
    /// The pair's 200/70/200 is byte-for-byte the full blink's; the pause is
    /// the roll's remainder. Green shape (finished / job succeeded): the
    /// baseline sets the zone green once and only the roll pulses — two
    /// lines, no zone animation, steady by design.
    static func splitProgram(alert: SplitAlert, work: SplitWork, ledCount: Int,
                             palette: LedPalette = .standard) -> String {
        let count = max(2, min(8, ledCount))
        let zone = splitZone(alert: alert, ledCount: count)
        let rest = count - zone
        let workColor: String
        switch work {
        case .working: workColor = palette.working
        case .jobRunning: workColor = palette.jobRunning
        }
        let zoneIsGreen: Bool
        switch alert {
        case .waiting, .jobFailed: zoneIsGreen = false
        case .done, .jobSucceeded: zoneIsGreen = true
        }
        let baseline = (0..<count)
            .map { "\($0):\($0 < zone && zoneIsGreen ? palette.done : "#000000") \(K.rollingFadeMs)ms" }
            .joined(separator: "; ")
        let stagger = rest <= 2 ? K.rollingStaggerDotMs : K.rollingStaggerMs
        let rollPulses = (0..<rest).map {
            "\(zone + $0):\(workColor) \(K.rollingPulseMs)ms pulse \($0 * stagger)ms"
        }
        if zoneIsGreen {
            return baseline + "\n" + rollPulses.joined(separator: "; ") + "\nrepeat"
        }
        let firstBlink = (0..<zone)
            .map { "\($0):\(palette.needsYou) \(K.askBlinkMs)ms pulse 0ms" }
            .joined(separator: "; ")
        let secondBlink = (0..<zone).map {
            "\($0):\(palette.needsYou) \(K.askBlinkMs)ms pulse \(K.askBlinkGapMs)ms"
        }
        return baseline + "\n" + firstBlink + "\n"
            + (secondBlink + rollPulses).joined(separator: "; ") + "\nrepeat"
    }

    /// Plain fill bar: one LED per eighth of charge, frontier dimmed by the
    /// remainder. No charging animation — for a seven-second glance the only
    /// question is "how full is it".
    static func glanceBar(power: PowerState, ledCount: Int,
                          palette: LedPalette = .standard) -> String {
        let count = max(1, min(8, ledCount))
        let percent = max(0, min(100, power.percent))
        let fill = BatteryRules.fill(percent: percent, ledCount: count)
        let color = BatteryRules.color(forPercent: percent, palette: palette)
        return (0..<count)
            .map { "\($0):\(BatteryRules.fillColor(index: $0, fill: fill, color: color)) \(K.batterySegmentTransitionMs)ms" }
            .joined(separator: ";")
    }

    static func applyBrightness(_ program: String, _ brightness: Int) -> String {
        let b = max(1, min(255, brightness))
        guard b < 255, program != "off" else { return program }
        return "brightness \(b)\n\(program)"
    }
}

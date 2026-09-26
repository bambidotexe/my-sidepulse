import Foundation

/// What plays on the alert zone of a split display. Session states outrank
/// their job counterparts, and needs-you outranks finished — the same order
/// the full-strip ladder uses. An agent alert names the agents behind it,
/// for the sentence about it; the zone looks the same whoever they are.
public enum SplitAlert: Equatable {
    case waiting(Agents), jobFailed, done(Agents), jobSucceeded
}

/// What plays on the rest of the strip under a split alert. A roll names the
/// agents it rolls for: one colour, or several, one per LED in turn.
public enum SplitWork: Equatable {
    case working(Agents), jobRunning
}

public enum DisplayState: Equatable {
    case off
    /// The roll, in the colour of each agent it names. Two agents take one
    /// colour on one pass and the other's on the next; three or four take
    /// one colour per LED in turn, on one pass.
    case working(Agents)
    case waiting(Agents)
    case done(Agents)
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
        case .working(let agents):
            return applyBrightness(rolling(colors: palette.rollColors(agents), ledCount: ledCount),
                                   brightness)
        case .waiting, .jobFailed:
            return applyBrightness(askBlink(palette: palette), brightness)
        case .done, .jobSucceeded:
            return applyBrightness("off\n\(palette.done) \(K.doneBreathSeconds)s pulse\nrepeat", brightness)
        case .jobRunning:
            return applyBrightness(rolling(colors: [palette.jobRunning], ledCount: ledCount), brightness)
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

    /// The roll: a dark fade, then one staggered pulse per LED, looped, in
    /// the passes `rollPasses` lays out. With two colours the loop holds one
    /// pass per colour, each opening with the same fade, so the wave keeps
    /// its rhythm and changes colour at every pass: two passes of eight LEDs
    /// are 496 bytes, inside the strip's 512. With three or four, one pass
    /// whose LEDs take the colours in turn, 251 bytes: three passes would be
    /// 741.
    static func rolling(colors: [String], ledCount: Int) -> String {
        let count = max(2, min(8, ledCount))
        let stagger = count == 2 ? K.rollingStaggerDotMs : K.rollingStaggerMs
        let passes = rollPasses(colors, ledCount: count).map { leds in
            let segments = leds.indices
                .map { "\($0):\(leds[$0]) \(K.rollingPulseMs)ms pulse \($0 * stagger)ms" }
                .joined(separator: "; ")
            return "off \(K.rollingFadeMs)ms cosine\n\(segments)"
        }
        return (passes + ["repeat"]).joined(separator: "\n")
    }

    /// The colour of each of `count` LEDs on each pass of a roll in `colors`:
    /// for one or two colours one pass per colour, the whole strip in it;
    /// for three or more one pass, LED i in colour i mod n. Public because
    /// the settings replica draws the roll from the same rule.
    public static func rollPasses(_ colors: [String], ledCount count: Int) -> [[String]] {
        guard colors.count > 2 else {
            return colors.map { color in Array(repeating: color, count: count) }
        }
        return [(0..<count).map { colors[$0 % colors.count] }]
    }

    /// Whether a change of state is the full-strip roll changing colour:
    /// the agents rolling changing, one joining or one leaving. The wave then
    /// carries on from where it is and takes the new colours at its next
    /// pass (`Engine.paint`), instead of restarting from its first line.
    public static func rollRecolour(from: DisplayState, to: DisplayState) -> Bool {
        guard from != to, case .working = from, case .working = to else { return false }
        return true
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

    /// A change of state that carries the roll on: the same work keeps
    /// rolling on the LEDs it keeps while an alert zone opens, closes or
    /// changes width. The zone's LEDs before and after, and how the new zone
    /// starts; nil when nothing rolls through the change.
    public struct RollHandover: Equatable {
        public let zoneBefore: Int
        public let zoneAfter: Int
        public let opening: LedContinuation.ZoneOpening?
    }

    public static func rollHandover(from: DisplayState, to: DisplayState, ledCount: Int,
                                    palette: LedPalette = .standard) -> RollHandover? {
        let count = max(2, min(8, ledCount))
        func work(_ state: DisplayState) -> SplitWork? {
            switch state {
            case .working(let agents): return .working(agents)
            case .jobRunning: return .jobRunning
            case .split(_, let work): return work
            default: return nil
            }
        }
        func zone(_ state: DisplayState) -> Int {
            if case .split(let alert, _) = state { return splitZone(alert: alert, ledCount: count) }
            return 0
        }
        guard from != to, let before = work(from), let after = work(to), before == after else { return nil }
        var opening: LedContinuation.ZoneOpening?
        if case .split(let alert, _) = to {
            switch alert {
            case .waiting, .jobFailed: opening = .blink(palette.needsYou)
            case .done, .jobSucceeded: opening = .steady(palette.done)
            }
        }
        return RollHandover(zoneBefore: zone(from), zoneAfter: zone(to), opening: opening)
    }

    /// The alert zone on the left, the working roll on the rest, in the
    /// work's colour or, for a roll several agents share, alternating by LED —
    /// built entirely from shapes this strip has PROVEN:
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
        // A roll several agents share cannot alternate its colour by pass
        // here: two passes of blink lines and roll lines are over 700 bytes
        // on eight LEDs, and the strip takes 512. Under a zone a shared roll
        // of any number of agents alternates its colour by LED instead.
        let workColors: [String]
        switch work {
        case .working(let agents): workColors = palette.rollColors(agents)
        case .jobRunning: workColors = [palette.jobRunning]
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
            "\(zone + $0):\(workColors[$0 % workColors.count]) \(K.rollingPulseMs)ms pulse \($0 * stagger)ms"
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

    /// A dark strip under the brightness preview: LED 0 white (`K.brightnessPreviewWhite`) at the
    /// new brightness, every other LED assigned black, the baseline shape the
    /// split opens with.
    public static func brightnessPreview(ledCount: Int, brightness: Int) -> String {
        let count = max(1, min(8, ledCount))
        let fade = "\(K.rollingFadeMs)ms"
        let line = (0..<count).map { led in
            "\(led):\(led == 0 ? K.brightnessPreviewWhite : "#000000") \(fade)"
        }.joined(separator: ";")
        return applyBrightness(line, brightness)
    }

    /// A program at a brightness: every colour scaled by `brightness / 255`,
    /// each channel rounded, which is what the strip's own `brightness N`
    /// line does to the values it draws. Scaled here, not there, because a
    /// program that carries a brightness line shows its lit LEDs at full
    /// scale for a frame at every parse on the owner's strip, and a colour
    /// already at the brightness cannot. The palette stays the true colour:
    /// this is the last step before the text goes out.
    static func applyBrightness(_ program: String, _ brightness: Int) -> String {
        scaled(program, brightness: brightness)
    }

    public static func scaled(_ program: String, brightness: Int) -> String {
        let b = max(1, min(255, brightness))
        guard b < 255 else { return program }
        var out = ""
        var rest = Substring(program)
        while let hash = rest.firstIndex(of: "#") {
            out += rest[..<hash]
            let start = rest.index(after: hash)
            let end = rest.index(start, offsetBy: 6, limitedBy: rest.endIndex) ?? rest.endIndex
            let hex = rest[start..<end]
            if hex.count == 6, let value = UInt32(hex, radix: 16) {
                func channel(_ shift: UInt32) -> Int {
                    Int((Double((value >> shift) & 0xff) * Double(b) / 255).rounded())
                }
                out += String(format: "#%02x%02x%02x", channel(16), channel(8), channel(0))
                rest = rest[end...]
            } else {
                out += "#"
                rest = rest[start...]
            }
        }
        out += rest
        return out
    }
}

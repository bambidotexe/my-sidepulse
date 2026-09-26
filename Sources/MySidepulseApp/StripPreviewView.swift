import AppKit
import SwiftUI
import MySidepulseCore

/// The window's picture of the strip: a dark housing with one dot per LED,
/// animating whatever display state it is given on the real device cadences
/// (roll stagger, pulse and breath timings straight from K). Colours are the
/// palette's own hexes, drawn exactly; the strip's brightness setting is not
/// applied, so the picture always shows a colour at full.
struct StripPreviewView: View {
    var state: DisplayState
    var power: PowerState?
    var ledCount: Int = K.defaultLedCount
    var dotSize: CGFloat = 16
    var palette: LedPalette = .standard

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animates)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: dotSize * 0.55) {
                ForEach(0..<max(1, ledCount), id: \.self) { index in
                    let look = appearance(dot: index, at: animates ? t : nil)
                    dot(color: look.color, level: look.level)
                }
            }
            .padding(.horizontal, dotSize * 0.75)
            .padding(.vertical, dotSize * 0.5)
            .background(
                Capsule()
                    .fill(Color(white: 0.08))
                    .overlay(Capsule().strokeBorder(Color(white: 1.0).opacity(0.14)))
            )
        }
        .accessibilityLabel("LED strip: \(state.explanation)")
    }

    private var animates: Bool {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return false }
        switch state {
        case .working, .jobRunning, .waiting, .jobFailed, .done, .jobSucceeded, .batteryCritical,
             .effect, .split:
            return true
        case .off, .batteryGlance, .manualColor:
            return false
        }
    }

    /// Colour and intensity for one dot; `t` nil means a still frame.
    private func appearance(dot index: Int, at t: TimeInterval?) -> (color: Color, level: Double) {
        if case .effect(let name) = state {
            return EffectScreen.appearance(name: name, dot: index, count: max(1, ledCount), at: t)
        }
        if case .split(let alert, let work) = state {
            return splitAppearance(alert: alert, work: work, dot: index, at: t)
        }
        if case .working(let agents) = state {
            // The device program's own passes (`LedProgram.rollPasses`), each
            // the single roll's cycle: a shared roll changes colour at every
            // pass where its passes fit the strip, and gives each LED an
            // agent's colour where they do not, exactly as the strip does. A
            // still frame shows the first pass.
            let passes = LedProgram.rollPasses(palette.rollColors(agents), ledCount: max(2, min(8, ledCount)))
            var pass = 0
            if let t {
                let raw = Int((t / rollCycle).rounded(.down)) % passes.count
                pass = (raw + passes.count) % passes.count
            }
            let leds = passes[pass]
            let level = t.map { intensity(dot: index, at: $0) } ?? staticIntensity(dot: index)
            return (screen(leds[index % leds.count]), level)
        }
        let level = t.map { intensity(dot: index, at: $0) } ?? staticIntensity(dot: index)
        return (solidColor, level)
    }

    /// One pass of the roll on this strip: the fade, then the last LED's
    /// pulse after its stagger, as `LedProgram.rolling` lays it out.
    private var rollCycle: TimeInterval {
        let stagger = Double(ledCount <= 2 ? K.rollingStaggerDotMs : K.rollingStaggerMs) / 1000
        return Double(K.rollingFadeMs) / 1000 + Double(K.rollingPulseMs) / 1000
            + stagger * Double(max(ledCount - 1, 1))
    }

    /// The one colour of a state that paints the whole strip in one colour,
    /// the battery bar's being the one its charge picks. A roll is painted
    /// per dot by `appearance`, from its passes; this is its first colour.
    private var solidColor: Color {
        switch state {
        case .working(let agents): return screen(palette.rollColors(agents)[0])
        case .jobRunning: return screen(palette.jobRunning)
        case .waiting, .jobFailed: return screen(palette.needsYou)
        case .done, .jobSucceeded: return screen(palette.done)
        case .batteryCritical: return screen(palette.batteryCritical)
        case .batteryGlance:
            return screen(BatteryRules.color(forPercent: power?.percent ?? 0, palette: palette))
        case .manualColor(let hex): return screen(hex)
        // Dark; and the two per-dot states, which appearance() paints before
        // ever asking for one colour.
        case .off, .split, .effect: return Color(white: 0.5)
        }
    }

    private func screen(_ hex: String) -> Color { Color(deviceHex: hex) ?? Color(white: 0.5) }

    /// The split display, on the device program's own timeline as
    /// `LedProgram.splitProgram` builds it: the baseline frame, then — for
    /// an amber zone — pulse one on its own line, then the line carrying
    /// pulse two (after the gap's delay) beside the roll's staggered
    /// pulses. A green zone is set once in the baseline and holds.
    private func splitAppearance(alert: SplitAlert, work: SplitWork, dot index: Int,
                                 at t: TimeInterval?) -> (color: Color, level: Double) {
        let count = max(2, ledCount)
        let zone = LedProgram.splitZone(alert: alert, ledCount: count)
        let rest = count - zone
        // Under a zone a roll several agents share alternates its colour by
        // LED, as the device program does (`LedProgram.zoneRollColors`).
        let hexes: [String]
        switch work {
        case .working(let agents): hexes = palette.rollColors(agents)
        case .jobRunning: hexes = [palette.jobRunning]
        }
        let workColors = LedProgram.zoneRollColors(hexes, zone: zone, ledCount: count).map(screen)
        func workColor(_ index: Int) -> Color {
            workColors.isEmpty ? screen(hexes[0]) : workColors[max(0, index - zone) % workColors.count]
        }
        let alertColor: Color
        let zoneIsGreen: Bool
        switch alert {
        case .waiting, .jobFailed:
            alertColor = screen(palette.needsYou); zoneIsGreen = false
        case .done, .jobSucceeded:
            alertColor = screen(palette.done); zoneIsGreen = true
        }
        guard let t else {
            return index < zone ? (alertColor, 1) : (workColor(index), 1)
        }
        let fade = Double(K.rollingFadeMs) / 1000
        let blink = Double(K.askBlinkMs) / 1000
        let gap = Double(K.askBlinkGapMs) / 1000
        let stagger = Double(rest <= 2 ? K.rollingStaggerDotMs : K.rollingStaggerMs) / 1000
        let pulseSeconds = Double(K.rollingPulseMs) / 1000
        let rollEnd = pulseSeconds + stagger * Double(max(rest - 1, 0))
        // Line starts: the roll line begins after the baseline (green) or
        // after baseline + the first blink's own line (amber).
        let rollStart = fade + (zoneIsGreen ? 0 : blink)
        let cycle = rollStart + max(rollEnd, zoneIsGreen ? 0 : gap + blink)
        let raw = t.truncatingRemainder(dividingBy: cycle)
        let phase = raw < 0 ? raw + cycle : raw
        if index < zone {
            if zoneIsGreen { return (alertColor, 1) } // the hold persists throughout
            let first = phase - fade
            if first >= 0, first < blink { return (alertColor, pulse(first / blink)) }
            let second = phase - rollStart - gap
            if second >= 0, second < blink { return (alertColor, pulse(second / blink)) }
            return (alertColor, 0.06)
        }
        let local = phase - rollStart - Double(index - zone) * stagger
        guard local >= 0, local < pulseSeconds else { return (workColor(index), 0.06) }
        return (workColor(index), pulse(local / pulseSeconds))
    }

    private func dot(color: Color, level: Double) -> some View {
        let level = max(0, min(1, level))
        return Circle()
            .fill(color.opacity(0.10 + 0.90 * level))
            .overlay(Circle().strokeBorder(Color(white: 1.0).opacity(0.10)))
            .frame(width: dotSize, height: dotSize)
            .shadow(color: color.opacity(0.75 * level), radius: dotSize * 0.45)
    }

    /// Reduce Motion, and states that hold still anyway: one honest frame.
    private func staticIntensity(dot index: Int) -> Double {
        switch state {
        case .off: return 0
        case .batteryGlance: return glanceIntensity(dot: index)
        default: return 1
        }
    }

    private func intensity(dot index: Int, at t: TimeInterval) -> Double {
        switch state {
        case .off:
            return 0
        case .manualColor:
            return 1
        case .effect, .split:
            return 1 // painted per-dot upstream; appearance() never gets here
        case .working, .jobRunning:
            // The program's own pass: the fade first, then each LED's pulse
            // after its stagger, so a two-colour roll's pass boundary lands
            // where the colour changes.
            let stagger = Double(ledCount <= 2 ? K.rollingStaggerDotMs : K.rollingStaggerMs) / 1000
            let pulse = Double(K.rollingPulseMs) / 1000
            let fade = Double(K.rollingFadeMs) / 1000
            let cycle = rollCycle
            let raw = t.truncatingRemainder(dividingBy: cycle)
            let phase = (raw < 0 ? raw + cycle : raw) - fade - Double(index) * stagger
            guard phase >= 0, phase < pulse else { return 0.06 }
            let s = sin(.pi * phase / pulse)
            return 0.06 + 0.94 * s * s
        case .waiting, .jobFailed:
            return askBlink(t)
        case .done, .jobSucceeded:
            return breath(t, cycle: K.doneBreathSeconds)
        case .batteryCritical:
            return breath(t, cycle: K.batteryCriticalBreathSeconds)
        case .batteryGlance:
            return glanceIntensity(dot: index)
        }
    }

    private func breath(_ t: TimeInterval, cycle: TimeInterval) -> Double {
        let s = sin(.pi * t / cycle)
        return 0.12 + 0.88 * s * s
    }

    /// The device program's own timeline, walked in the same order and the
    /// same units: pulse, dark gap, pulse, dark pause. Built from K exactly
    /// as `LedProgram.askBlink()` is, so screen and strip can only ever
    /// disagree in colour calibration — never in rhythm.
    private func askBlink(_ t: TimeInterval) -> Double {
        let blink = Double(K.askBlinkMs) / 1000
        let gap = Double(K.askBlinkGapMs) / 1000
        let cycle = blink * 2 + gap + Double(K.askBlinkPauseMs) / 1000
        let raw = t.truncatingRemainder(dividingBy: cycle)
        let phase = raw < 0 ? raw + cycle : raw
        if phase < blink { return pulse(phase / blink) }
        if phase < blink + gap { return 0.06 }
        if phase < blink * 2 + gap { return pulse((phase - blink - gap) / blink) }
        return 0.06
    }

    /// One `pulse` step: dark, up to full, back to dark.
    private func pulse(_ x: Double) -> Double {
        let s = sin(.pi * x)
        return 0.06 + 0.94 * s * s
    }

    /// The same fill rule the device program is built from.
    private func glanceIntensity(dot index: Int) -> Double {
        let fill = BatteryRules.fill(percent: power?.percent ?? 0, ledCount: ledCount)
        if index < fill.full { return 1 }
        if index == fill.full, fill.partial > 0 { return fill.partial }
        return 0
    }
}

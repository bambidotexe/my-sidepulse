import Foundation

/// Carrying an animation on across a rewrite. The strip takes whole programs
/// and every program starts from its first line, so a brightness change, or
/// an alert joining a running roll, would restart the animation. Instead the
/// host writes a one-shot TAIL: the rest of the current loop from the point
/// the strip has reached, at the new brightness, with no `repeat`. When the
/// tail ends the loop is at a boundary, a dark or steady moment in every
/// animation the host plays, and the normal looping program is written there.
///
/// Pure: the phase is passed in as the milliseconds elapsed since the loop's
/// program was written. The firmware refuses `repeat N`, so a single program
/// cannot hold a play-once prefix before its loop; two writes are the only way.
///
/// Cut rules, each keeping the line's length so the tail ends exactly at the
/// loop's end:
/// - a whole-strip `off <d>`: the rest as `off`;
/// - a whole-strip pulse: two cosine halves (verified identical on the strip),
///   the half under way cut to its remainder;
/// - a per-LED segment not started yet keeps its delay, reduced; one already
///   finished is dropped (the LED holds what it holds);
/// - a per-LED crossfade under way crossfades from the current value to its
///   target over the remaining time;
/// - a per-LED pulse past its peak falls to its pre-pulse colour, black in
///   every program the host writes, over the remaining time;
/// - a per-LED pulse still rising cannot be written exactly with one segment
///   per LED per line: a fall over the remaining time leaves a hole in the
///   wave, and a pulse from its current level returns to that level and holds
///   it until the loop's next dark line, both seen on the strip. So a tail
///   opens with a BRIDGE line of up to `bridgeMs`: a rising LED below half
///   its peak fades to black on it and then plays its whole pulse from black,
///   a little late; one past half rises to its peak on it and falls from
///   there; a falling LED and a held one move to their value at the new
///   brightness. Nothing is left lit and no LED is skipped.
///
/// From a dark strip (`fromDark`), the same cut with every pulse under way
/// played from black over its remaining time: the animation resumes where it
/// would have been, its lit LEDs fading in.
public enum LedContinuation {
    /// A line with no duration, easing or delay lasts one 60 Hz frame.
    public static let frameMs = 17
    /// The longest bridge line. Under the roll's 95 ms stagger and under what
    /// the eye reads as instant, long enough that a fade to black or a rise to
    /// the peak on it is a ramp rather than a step.
    public static let bridgeMs = 60
    /// A rising pulse at or above this share of its peak rises to the peak on
    /// the bridge and falls from there; below it, it fades out and starts
    /// over from black. Half bounds both steps alike.
    static let riseToPeakFrom = 0.5

    struct Segment: Equatable {
        /// nil for a whole-strip segment.
        var led: Int?
        /// `off` or `#rrggbb`.
        var color: String
        var durationMs: Int?
        /// The duration as the host spelled it, kept while it is unchanged.
        var durationWord: String? = nil
        var easing: String?
        var delayMs: Int
        /// The moment the segment's motion ends, from the line's start.
        var endMs: Int { delayMs + (durationMs ?? 0) }
    }

    struct Line: Equatable {
        var segments: [Segment]
        /// `; ` in per-LED programs, `;` where bytes are scarce.
        var separator: String
        var lengthMs: Int {
            let motion = segments.map(\.endMs).max() ?? 0
            let hasTiming = segments.contains { $0.durationMs != nil || $0.easing != nil || $0.delayMs > 0 }
            return hasTiming ? motion : frameMs
        }
    }

    struct Program: Equatable {
        var brightness: Int?
        var lines: [Line]
        var repeats: Bool
        var loopMs: Int { lines.reduce(0) { $0 + $1.lengthMs } }
    }

    // MARK: reading the host's own text

    /// Reads a program the host wrote. Only the host's own shapes are
    /// understood; anything else answers nil, and the caller writes the new
    /// program outright.
    static func parse(_ text: String) -> Program? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return nil }
        var brightness: Int?
        if lines[0].hasPrefix("brightness ") {
            guard let value = Int(lines[0].dropFirst("brightness ".count)) else { return nil }
            brightness = value
            lines.removeFirst()
        }
        var repeats = false
        if lines.last == "repeat" {
            repeats = true
            lines.removeLast()
        }
        guard !lines.isEmpty, !lines.contains("repeat") else { return nil }
        var parsed: [Line] = []
        for line in lines {
            guard let one = parseLine(line) else { return nil }
            parsed.append(one)
        }
        return Program(brightness: brightness, lines: parsed, repeats: repeats)
    }

    static func parseLine(_ line: String) -> Line? {
        let separator = line.contains("; ") ? "; " : ";"
        let parts = line.components(separatedBy: separator)
        var segments: [Segment] = []
        for part in parts {
            guard let segment = parseSegment(part) else { return nil }
            segments.append(segment)
        }
        // A whole-strip segment stands alone on its line.
        if segments.count > 1, segments.contains(where: { $0.led == nil }) { return nil }
        return Line(segments: segments, separator: separator)
    }

    /// `off`, `#rrggbb`, `i:#rrggbb`, each followed by up to
    /// `<duration> [easing] [delay]`, the host's own order.
    static func parseSegment(_ text: String) -> Segment? {
        let words = text.split(separator: " ").map(String.init)
        guard let head = words.first else { return nil }
        var led: Int?
        var color = head
        if let colon = head.firstIndex(of: ":") {
            guard let index = Int(head[..<colon]) else { return nil }
            led = index
            color = String(head[head.index(after: colon)...])
        }
        guard color == "off" || LedMode.isRGBHex(color) else { return nil }
        var segment = Segment(led: led, color: color, durationMs: nil, easing: nil, delayMs: 0)
        var rest = words.dropFirst()
        if let first = rest.first, let ms = milliseconds(first) {
            segment.durationMs = ms
            segment.durationWord = first
            rest = rest.dropFirst()
        }
        if let easing = rest.first, !easing.first!.isNumber {
            guard ["linear", "ease", "ease-in", "ease-out", "ease-in-out", "cosine", "pulse", "none"]
                .contains(easing) else { return nil }
            segment.easing = easing
            rest = rest.dropFirst()
        }
        if let delay = rest.first {
            guard let ms = milliseconds(delay) else { return nil }
            segment.delayMs = ms
            rest = rest.dropFirst()
        }
        guard rest.isEmpty else { return nil }
        return segment
    }

    /// `760ms`, `2s`, `0.2s` → milliseconds.
    static func milliseconds(_ word: String) -> Int? {
        if word.hasSuffix("ms") { return Int(word.dropLast(2)) }
        if word.hasSuffix("s"), let seconds = Double(word.dropLast()) {
            return Int((seconds * 1000).rounded())
        }
        return nil
    }

    // MARK: writing

    static func text(_ segment: Segment) -> String {
        var words = [segment.led.map { "\($0):\(segment.color)" } ?? segment.color]
        if let ms = segment.durationMs {
            let kept = segment.durationWord.flatMap { milliseconds($0) == ms ? $0 : nil }
            words.append(kept ?? LedEffects.duration(ms: ms))
        }
        if let easing = segment.easing { words.append(easing) }
        if segment.delayMs > 0 || (segment.led != nil && segment.easing == "pulse") {
            words.append("\(segment.delayMs)ms")
        }
        return words.joined(separator: " ")
    }

    static func text(_ line: Line) -> String {
        line.segments.map(text).joined(separator: line.separator)
    }

    static func text(_ program: Program) -> String {
        var lines = program.lines.map(text)
        if program.repeats { lines.append("repeat") }
        return lines.joined(separator: "\n")
    }

    // MARK: cutting

    /// The rest of `line` from `t` milliseconds into it, the same length
    /// shorter. Nil when nothing of it remains.
    /// `reset` names the LEDs the line before took to black, whose pulse
    /// under way plays whole from black.
    static func cut(_ line: Line, at t: Int, fromDark: Bool = false, reset: Set<Int> = []) -> Line? {
        guard t > 0 else { return line }
        guard t < line.lengthMs else { return nil }
        var kept: [Segment] = []
        for segment in line.segments {
            let dark = fromDark || segment.led.map(reset.contains) == true
            if let rest = cut(segment, at: t, fromDark: dark) { kept.append(rest) }
        }
        guard !kept.isEmpty else { return nil }
        return Line(segments: kept, separator: line.separator)
    }

    static func cut(_ segment: Segment, at t: Int, fromDark: Bool = false) -> Segment? {
        var s = segment
        // Not started: the same segment, sooner.
        if t <= s.delayMs {
            s.delayMs -= t
            return s
        }
        guard let duration = s.durationMs, t < s.endMs else {
            // An instant segment, or a finished one: the LED holds what it
            // holds. A whole-strip instant line is re-emitted as the state it
            // set, since nothing else on the line can hold the strip there.
            return s.led == nil && s.durationMs == nil ? s : nil
        }
        let into = t - s.delayMs
        let remaining = duration - into
        s.delayMs = 0
        s.durationMs = remaining
        guard s.easing == "pulse" else { return s } // a crossfade or a fade: from here to its target
        let half = duration / 2
        // From black, a pulse under way is played whole from black over what
        // is left of it: on a dark strip that is the fade-in the eye expects.
        if fromDark, s.led != nil || into >= half {
            return Segment(led: s.led, color: s.color, durationMs: remaining, easing: "pulse",
                           delayMs: 0)
        }
        if s.led == nil {
            // A whole-strip pulse is two cosine halves.
            if into < half {
                return Segment(led: nil, color: s.color, durationMs: half - into, easing: "cosine",
                               delayMs: 0)
            }
            return Segment(led: nil, color: "off", durationMs: remaining, easing: "cosine", delayMs: 0)
        }
        // A per-LED pulse returns to its pre-pulse value, black in every host
        // program, so its fall is a crossfade to black over what is left; one
        // still rising falls too, from wherever the bridge took it.
        return Segment(led: s.led, color: "#000000", durationMs: remaining, easing: nil, delayMs: 0)
    }

    /// Whether a per-LED pulse is on its way up `t` into its line, and how far.
    static func rising(_ s: Segment, at t: Int) -> (into: Int, level: Double)? {
        guard s.led != nil, s.easing == "pulse", let duration = s.durationMs, t > s.delayMs,
              t - s.delayMs < duration / 2 else { return nil }
        let into = t - s.delayMs
        return (into, (1 - cos(Double.pi * Double(into) / Double(duration / 2))) / 2)
    }

    /// The whole-strip pulse's other half, which follows its cut first half
    /// on a line of its own.
    static func secondHalf(of segment: Segment) -> Line? {
        guard segment.led == nil, segment.easing == "pulse", let duration = segment.durationMs
        else { return nil }
        return Line(segments: [Segment(led: nil, color: "off", durationMs: duration - duration / 2,
                                       easing: "cosine", delayMs: 0)], separator: "; ")
    }

    // MARK: the tail

    /// Every program here is UNSCALED: the palette's true colours, as
    /// `LedProgram.program` renders them at brightness 255. A tail is cut and
    /// its bridge computed on that text, and only the text that goes to the
    /// strip is scaled (`LedProgram.scaled`), so the levels are exact and a
    /// second cut works from the same colours.
    public struct Tail: Equatable {
        /// The one-shot program to write: the rest of the loop, no `repeat`,
        /// its colours at the brightness.
        public let program: String
        /// The same at brightness 255, to cut again from.
        public let unscaled: String
        /// How long it plays; the looping program is written when it ends.
        public let lengthMs: Int
    }

    /// The length of one loop of a host program, nil when it does not loop or
    /// is not one the host wrote.
    public static func loopMs(of program: String) -> Int? {
        guard let parsed = parse(program), parsed.repeats else { return nil }
        return parsed.loopMs
    }

    /// The rest of `loop` (unscaled) from `elapsedMs` after it was written,
    /// at `brightness`. Nil when nothing remains to carry on.
    public static func tail(of loop: String, elapsedMs: Int, brightness: Int,
                            fromDark: Bool = false) -> Tail? {
        guard let parsed = parse(loop), parsed.loopMs > 0 else { return nil }
        // A one-shot already playing, a tail, is cut from where it is; past
        // its end there is nothing left of it.
        guard parsed.repeats || elapsedMs < parsed.loopMs else { return nil }
        let phase = parsed.repeats ? max(0, elapsedMs) % parsed.loopMs : max(0, elapsedMs)
        // A segment starts from the LED's visible value, at the old
        // brightness, so a lit LED would carry that brightness to the end of
        // its segment. The bridge line moves every lit LED to where it goes
        // on from, at the new brightness once scaled, and the loop continues
        // from the bridge's end. Not from dark, where the fade-in is the
        // point, and not when it would not fit.
        if !fromDark, let bridge = bridgeLine(parsed, at: phase), parsed.loopMs - phase > bridge.ms {
            let after = rest(of: parsed, from: phase + bridge.ms, reset: bridge.reset).lines
            let unscaled = text(Program(brightness: nil, lines: [bridge.line] + after, repeats: false))
            if !after.isEmpty, unscaled.utf8.count <= 512 {
                return Tail(program: LedProgram.scaled(unscaled, brightness: brightness), unscaled: unscaled,
                            lengthMs: parsed.loopMs - phase)
            }
        }
        let lines = rest(of: parsed, from: phase, fromDark: fromDark).lines
        guard !lines.isEmpty else { return nil }
        let unscaled = text(Program(brightness: nil, lines: lines, repeats: false))
        return Tail(program: LedProgram.scaled(unscaled, brightness: brightness), unscaled: unscaled,
                    lengthMs: parsed.loopMs - phase)
    }

    // MARK: the bridge

    /// The line that carries every lit LED from where it is to where it goes
    /// on from, and how long it is: up to `bridgeMs`, or what is left of the
    /// line under way. A whole-strip line under way bridges as one instant
    /// whole-strip colour. `reset` names the LEDs taken to black, whose
    /// pulse then plays whole from black. Nil when nothing is lit, or nothing
    /// can be told.
    static func bridgeLine(_ parsed: Program, at phase: Int)
        -> (line: Line, ms: Int, reset: Set<Int>)? {
        var start = 0
        for (index, line) in parsed.lines.enumerated() {
            let end = start + line.lengthMs
            defer { start = end }
            guard start < phase, phase < end else { continue }
            let t = phase - start
            if line.segments.count == 1, let only = line.segments.first, only.led == nil {
                guard let color = value(of: only, at: t, previous: previousColor(parsed, before: index, led: nil)),
                      color != "#000000" else { return nil }
                return (Line(segments: [Segment(led: nil, color: color, durationMs: nil, easing: nil, delayMs: 0)],
                             separator: "; "), frameMs, [])
            }
            let ms = min(bridgeMs, end - phase)
            guard ms > 0 else { return nil }
            var bridge: [Segment] = []
            var reset: Set<Int> = []
            let leds = Set(parsed.lines.flatMap(\.segments).compactMap(\.led)).sorted()
            for led in leds {
                let color: String?
                if let s = line.segments.last(where: { $0.led == led }), s.delayMs < t, t < s.endMs {
                    if let rise = rising(s, at: t) {
                        if rise.level >= riseToPeakFrom {
                            color = s.color
                        } else {
                            color = "#000000"
                            reset.insert(led)
                        }
                    } else {
                        color = value(of: s, at: t + ms, previous: previousColor(parsed, before: index, led: led))
                    }
                } else if let s = line.segments.last(where: { $0.led == led }), t >= s.endMs {
                    // Finished on this line: a crossfade holds its target, a
                    // pulse what was there before.
                    color = s.easing == "pulse" ? previousColor(parsed, before: index, led: led) : s.color
                } else if let s = line.segments.last(where: { $0.led == led }), s.easing == "pulse",
                          s.delayMs < t + ms {
                    // A pulse starting during the bridge starts over from
                    // black at its end, a little late.
                    reset.insert(led)
                    color = previousColor(parsed, before: index, led: led) == "#000000" ? nil : "#000000"
                } else {
                    color = previousColor(parsed, before: index, led: led) // holds
                }
                guard let color, color != "#000000" || reset.contains(led) else { continue }
                bridge.append(Segment(led: led, color: color, durationMs: ms, easing: nil, delayMs: 0))
            }
            return bridge.isEmpty ? nil : (Line(segments: bridge, separator: "; "), ms, reset)
        }
        return nil
    }

    /// The colour an LED holds when a line starts: the target of its latest
    /// crossfade in the lines before, a pulse being transparent since it
    /// returns to what was there. A loop is walked round; nil when nothing
    /// before says.
    static func previousColor(_ parsed: Program, before index: Int, led: Int?) -> String? {
        let count = parsed.lines.count
        for step in 1...max(1, count) {
            let i = index - step
            guard i >= 0 || parsed.repeats else { return nil }
            let line = parsed.lines[((i % count) + count) % count]
            for segment in line.segments.reversed() where segment.led == nil || segment.led == led || led == nil {
                if segment.easing == "pulse" { continue }
                return segment.color == "off" ? "#000000" : segment.color
            }
        }
        return nil
    }

    /// What a segment shows `t` milliseconds into its line, as a colour. A
    /// pulse rises from the previous colour, black when unknown, to its
    /// target and back on a raised cosine; a crossfade moves from the
    /// previous colour to its target in a straight line, or on a half cosine
    /// when so eased; unknown starts answer nil.
    static func value(of segment: Segment, at t: Int, previous: String?) -> String? {
        let target = segment.color == "off" ? "#000000" : segment.color
        guard let duration = segment.durationMs, duration > 0 else { return target }
        let tau = t - segment.delayMs
        guard tau > 0 else { return previous }
        guard tau < duration else { return segment.easing == "pulse" ? previous : target }
        let fraction = Double(tau) / Double(duration)
        switch segment.easing {
        case "pulse":
            return mix(previous ?? "#000000", target, (1 - cos(2 * Double.pi * fraction)) / 2)
        case "cosine":
            guard let previous else { return nil }
            return mix(previous, target, (1 - cos(Double.pi * fraction)) / 2)
        case "linear", "none":
            guard let previous else { return nil }
            return mix(previous, target, segment.easing == "none" ? 1 : fraction)
        default:
            // A plain duration eases like CSS `ease` on the vendor's engine.
            guard let previous else { return nil }
            return mix(previous, target, ease(fraction))
        }
    }

    /// CSS `ease`, cubic-bezier(0.25, 0.1, 0.25, 1), the curve a plain
    /// per-LED crossfade follows on the vendor's engine: 0.5 of the time is
    /// 0.80 of the way.
    static func ease(_ x: Double) -> Double {
        func bezier(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
            3 * (1 - t) * (1 - t) * t * p1 + 3 * (1 - t) * t * t * p2 + t * t * t
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if bezier(mid, 0.25, 0.25) < x { lo = mid } else { hi = mid }
        }
        return bezier((lo + hi) / 2, 0.1, 1)
    }

    /// `a` to `b` at `fraction`, per channel, rounded.
    static func mix(_ a: String, _ b: String, _ fraction: Double) -> String {
        guard a.count == 7, b.count == 7, let va = UInt32(a.dropFirst(), radix: 16),
              let vb = UInt32(b.dropFirst(), radix: 16) else { return b }
        let f = max(0, min(1, fraction))
        func channel(_ shift: UInt32) -> Int {
            let ca = Double((va >> shift) & 0xff), cb = Double((vb >> shift) & 0xff)
            return Int((ca + (cb - ca) * f).rounded())
        }
        return String(format: "#%02x%02x%02x", channel(16), channel(8), channel(0))
    }

    /// The loop's lines from `phase` on: the line under way cut, the later
    /// ones whole. Also the original line under way and how far into it.
    static func rest(of parsed: Program, from phase: Int, fromDark: Bool = false, reset: Set<Int> = [])
        -> (lines: [Line], underWay: (line: Line, t: Int)?) {
        var lines: [Line] = []
        var underWay: (line: Line, t: Int)?
        var start = 0
        for line in parsed.lines {
            let end = start + line.lengthMs
            defer { start = end }
            if end <= phase { continue }
            if phase <= start {
                lines.append(line)
                continue
            }
            let t = phase - start
            guard let cutLine = cut(line, at: t, fromDark: fromDark, reset: reset) else { continue }
            if underWay == nil { underWay = (line, t) }
            lines.append(cutLine)
            // A whole-strip pulse cut in its rising half: its fall follows.
            if let only = line.segments.first, line.segments.count == 1, only.led == nil,
               only.easing == "pulse", let duration = only.durationMs, t < duration / 2,
               let fall = secondHalf(of: only) {
                lines.append(fall)
            }
        }
        return (lines, underWay)
    }

    // MARK: a zone over the roll

    /// How an alert zone starts over a roll that carries on.
    public enum ZoneOpening: Equatable {
        /// The zone set to a colour over the baseline's fade, then held.
        case steady(String)
        /// The zone's double blink, starting at once.
        case blink(String)
    }

    /// The tail that carries the roll of `current` (a loop, or a tail already
    /// playing) into `next`: the roll's LEDs continue from where they are,
    /// the LEDs of a zone that closes go dark over the baseline's fade, and
    /// the new zone opens at once. A blinking zone needs two lines, blink one
    /// on its own and blink two behind the gap on the next, so the roll's
    /// line under way is split at the blink's end: its first `K.askBlinkMs`
    /// as one crossfade per LED to the value the roll reaches there, then its
    /// rest under the cut rules. Nil when the roll is at its dark end, where
    /// `next` written outright loses nothing.
    public static func transition(from current: String, to next: String, elapsedMs: Int,
                                  ledCount: Int, zoneBefore: Int, zoneAfter: Int,
                                  opening: ZoneOpening?, brightness: Int) -> Tail? {
        guard let parsed = parse(current), parsed.loopMs > 0 else { return nil }
        guard parsed.repeats || elapsedMs < parsed.loopMs else { return nil }
        let count = max(2, min(8, ledCount))
        let phase = parsed.repeats ? max(0, elapsedMs) % parsed.loopMs : max(0, elapsedMs)
        let reassigned = 0..<max(zoneBefore, zoneAfter)
        func strip(_ line: Line) -> Line {
            var line = line
            line.segments.removeAll { $0.led.map(reassigned.contains) ?? false }
            return line
        }
        // The lines that carry the roll on, and how long the first of them
        // is, which is how long the zone takes to open.
        var lines: [Line]
        var lengths: [Int]
        var openMs = K.rollingFadeMs
        if case .blink(let hex) = opening {
            guard let built = blinkOpening(parsed, at: phase, count: count, hex: hex, zone: zoneAfter,
                                           strip: strip) else { return nil }
            lines = built.lines
            lengths = built.lengths
        } else if let bridge = bridgeLine(parsed, at: phase), parsed.loopMs - phase > bridge.ms {
            let after = rest(of: parsed, from: phase + bridge.ms, reset: bridge.reset).lines
            lines = ([bridge.line] + after).map { strip(perLed($0, count: count)) }
            lengths = [bridge.ms] + after.map(\.lengthMs)
            openMs = bridge.ms
        } else {
            let cut = rest(of: parsed, from: phase).lines
            lines = cut.map { strip(perLed($0, count: count)) }
            lengths = cut.map(\.lengthMs)
        }
        guard !lines.isEmpty else { return nil }
        // A line emptied of everything but its timing keeps it, dark, on the
        // last LED, which is dark whenever the roll's own lines are.
        for i in lines.indices where lines[i].segments.isEmpty {
            lines[i].segments = [Segment(led: count - 1, color: "#000000", durationMs: lengths[i], easing: nil,
                                         delayMs: 0)]
        }
        // LEDs leaving the old zone go dark, and a steady zone is set, over
        // the first line; the blink's own lines were built with the zone in.
        for led in zoneAfter..<max(zoneAfter, zoneBefore) {
            lines[0].segments.append(Segment(led: led, color: "#000000", durationMs: openMs, easing: nil,
                                             delayMs: 0))
        }
        if case .steady(let hex) = opening {
            for led in 0..<zoneAfter {
                lines[0].segments.append(Segment(led: led, color: hex, durationMs: openMs, easing: nil,
                                                 delayMs: 0))
            }
        }
        let program = Program(brightness: nil, lines: lines, repeats: false)
        let unscaled = text(program)
        return Tail(program: LedProgram.scaled(unscaled, brightness: brightness), unscaled: unscaled,
                    lengthMs: program.loopMs)
    }

    /// A blinking zone opening over the roll. The zone needs blink one on a
    /// line of its own and blink two behind the gap on the next, so the roll's
    /// line under way is split at the blink's end: its next `K.askBlinkMs` as
    /// one crossfade per LED (a chord of the pulse), then its rest under the
    /// cut rules, blink two riding it. A pulse returns to its pre-pulse
    /// value, so a zone LED that is lit when the blink starts would hold that
    /// red under the pair; then the split's own baseline comes first, the
    /// zone fading to black over `K.rollingFadeMs` beside a chord of the
    /// roll, which is as soon as the split written outright would blink.
    /// Three lines when they fit, two when the zone is dark already. The
    /// last chord is the bridge: a rising LED below half its peak fades to
    /// black on it and starts over from black, one past half rises to its
    /// peak. Nil when the roll is at its dark end.
    static func blinkOpening(_ parsed: Program, at phase: Int, count: Int, hex: String, zone: Int,
                             strip: (Line) -> Line) -> (lines: [Line], lengths: [Int])? {
        let span = K.askBlinkMs
        let fade = K.rollingFadeMs
        let cutResult = rest(of: parsed, from: phase)
        guard !cutResult.lines.isEmpty else { return nil }
        let (original, t) = cutResult.underWay.map { (perLed($0.line, count: count), $0.t) }
            ?? (perLed(cutResult.lines[0], count: count), 0)
        let rest = cutResult.lines.dropFirst().map { strip(perLed($0, count: count)) }
        let restLengths = cutResult.lines.dropFirst().map(\.lengthMs)
        func blink(after delay: Int) -> [Segment] {
            (0..<zone).map { Segment(led: $0, color: hex, durationMs: span, easing: "pulse", delayMs: delay) }
        }
        let lit = (0..<zone).contains { led in
            original.segments.contains { $0.led == led && $0.delayMs < t && $0.endMs > t }
        }
        if lit, original.lengthMs - t > fade + span, let after = cut(original, at: t + fade + span,
                                                                    reset: pieces(original, from: t + fade, span: span, final: true).reset) {
            var line0 = strip(pieces(original, from: t, span: fade, final: false).line)
            line0.segments += (0..<zone).map {
                Segment(led: $0, color: "#000000", durationMs: fade, easing: nil, delayMs: 0)
            }
            var line1 = strip(pieces(original, from: t + fade, span: span, final: true).line)
            line1.segments += blink(after: 0)
            var line2 = strip(after)
            line2.segments += blink(after: K.askBlinkGapMs)
            let candidate = [line0, line1, line2] + rest
            if text(Program(brightness: nil, lines: candidate, repeats: false)).utf8.count <= 512 {
                return (candidate, [fade, span, original.lengthMs - t - fade - span] + restLengths)
            }
        }
        let first = pieces(original, from: t, span: span, final: true)
        var lineA = strip(first.line)
        var lineB: Line
        var lengths: [Int]
        var tail: [Line]
        if original.lengthMs - t > span, let after = cut(original, at: t + span, reset: first.reset) {
            lineB = strip(after)
            lengths = [span, original.lengthMs - t - span] + restLengths
            tail = Array(rest)
        } else if let next = rest.first {
            lineB = next
            lengths = [span] + restLengths
            tail = Array(rest.dropFirst())
        } else {
            return nil
        }
        lineA.segments += blink(after: 0)
        lineB.segments += blink(after: K.askBlinkGapMs)
        return ([lineA, lineB] + tail, lengths)
    }

    /// A line's next `span` milliseconds from `t` into it, as one crossfade
    /// per LED to the value each reaches there: chords of the pulses. At a
    /// `final` boundary, where the cut rules take over, a rising pulse below
    /// half its peak fades to black instead and is named in `reset`, to start
    /// over from black; one past half rises to its peak. A pulse that has not
    /// started by the boundary stays dark until it.
    static func pieces(_ line: Line, from t: Int, span: Int, final: Bool) -> (line: Line, reset: Set<Int>) {
        var segments: [Segment] = []
        var reset: Set<Int> = []
        for s in line.segments {
            guard let led = s.led, let duration = s.durationMs, s.endMs > t, s.delayMs < t + span else { continue }
            let begin = max(s.delayMs, t)
            let end = min(s.endMs, t + span)
            let delay = begin - t
            guard s.easing == "pulse" else {
                segments.append(Segment(led: led, color: s.color, durationMs: end - begin, easing: nil,
                                        delayMs: delay))
                continue
            }
            if final, let rise = rising(s, at: t + span) {
                if rise.level >= riseToPeakFrom {
                    segments.append(Segment(led: led, color: s.color, durationMs: end - begin, easing: nil,
                                            delayMs: delay))
                } else {
                    reset.insert(led)
                    if s.delayMs < t {
                        segments.append(Segment(led: led, color: "#000000", durationMs: end - begin,
                                                easing: nil, delayMs: delay))
                    }
                }
                continue
            }
            let tau = end - s.delayMs
            let level = tau >= duration ? 0 : (1 - cos(2 * Double.pi * Double(tau) / Double(duration))) / 2
            segments.append(Segment(led: led, color: scaled(s.color, by: level), durationMs: end - begin,
                                    easing: nil, delayMs: delay))
        }
        return (Line(segments: segments, separator: "; "), reset)
    }

    /// A whole-strip line as one segment per LED, so a zone can ride it. The
    /// roll's whole-strip lines are dark fades, which lose their easing here:
    /// a per-LED crossfade is a shape the strip has taken, a per-LED cosine
    /// is not.
    static func perLed(_ line: Line, count: Int) -> Line {
        guard line.segments.count == 1, let only = line.segments.first, only.led == nil else { return line }
        let color = only.color == "off" ? "#000000" : only.color
        let easing = only.easing == "pulse" ? "pulse" : nil
        return Line(segments: (0..<count).map {
            Segment(led: $0, color: color, durationMs: only.durationMs ?? frameMs, easing: easing,
                    delayMs: only.delayMs)
        }, separator: "; ")
    }

    /// `#rrggbb` at a fraction of itself, each channel rounded.
    static func scaled(_ hex: String, by level: Double) -> String {
        guard hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16) else { return hex }
        let f = max(0, min(1, level))
        func channel(_ shift: UInt32) -> Int { Int((Double((value >> shift) & 0xff) * f).rounded()) }
        return String(format: "#%02x%02x%02x", channel(16), channel(8), channel(0))
    }
}

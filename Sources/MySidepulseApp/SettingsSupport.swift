import AppKit
import CoreImage
import SwiftUI
import MySidepulseCore

/// Screen-side vocabulary for display states. The hardware hex values in K are
/// calibrated for the strip and look like nothing on a monitor, so the window
/// never shows them as colours: every state gets a screen-legible stand-in of
/// its own here, and only the *cadences* are borrowed from the device programs.
extension DisplayState {
    var screenColor: Color {
        switch self {
        case .off: return Color(white: 0.5)
        case .working: return Color(red: 1.0, green: 0.33, blue: 0.30)
        case .jobRunning: return Color(red: 0.62, green: 0.47, blue: 1.0)
        case .waiting, .jobFailed: return Color(red: 1.0, green: 0.70, blue: 0.16)
        case .done, .jobSucceeded: return Color(red: 0.22, green: 0.82, blue: 0.50)
        case .batteryCritical: return Color(red: 1.0, green: 0.23, blue: 0.23)
        case .batteryGlance: return Color(red: 0.22, green: 0.82, blue: 0.50)
        case .manualColor(let hex): return Color(deviceHex: hex) ?? Color(white: 0.5)
        // Split paints per-dot in StripPreviewView (zone colour vs work
        // colour); the single-colour fallback is the alert's, since the
        // alert is the news.
        case .split(let alert, _):
            switch alert {
            case .waiting, .jobFailed: return Color(red: 1.0, green: 0.70, blue: 0.16)
            case .done, .jobSucceeded: return Color(red: 0.22, green: 0.82, blue: 0.50)
            }
        // Effects paint per-dot through EffectScreen; this is only the glow
        // fallback anywhere a single colour is wanted.
        case .effect: return Color(white: 0.92)
        }
    }

    /// What the strip is showing and why, as the mark of a status row. The words and their tone
    /// are `StatusCopy`'s, in Core, where they are pinned; this only picks the mark they take.
    var mark: StatusMark {
        let line = StatusCopy.line(for: self)
        switch line.tone {
        case .info: return .info(line.text)
        case .good: return .good(line.text)
        case .warning: return .warning(line.text)
        case .failure: return .failure(line.text)
        }
    }

    /// The same sentence without its mark, for the strip replica's accessibility label.
    var explanation: String { StatusCopy.line(for: self).text }
}

/// Picture tiles, `perRow` to a row, the selected one tinted and ringed in the accent colour.
/// `selection` nil means none. Tapping the selected tile calls the binding's setter with the same
/// value again; the page decides what that means.
struct TileGrid<Option: Hashable, Picture: View>: View {
    let options: [Option]
    let perRow: Int
    @Binding var selection: Option?
    var enabled = true
    let label: (Option) -> String
    @ViewBuilder let picture: (Option) -> Picture

    var body: some View {
        SettingsRowFrame {
            VStack(spacing: 8) {
                ForEach(rows.indices, id: \.self) { index in
                    let row = rows[index]
                    HStack(spacing: 8) {
                        ForEach(row, id: \.self) { option in
                            Button { selection = option } label: { tile(option) }
                                .buttonStyle(.plain)
                                .contentShape(Rectangle())
                        }
                        // A short last row is padded, so a tile there is exactly as wide as
                        // the tiles above it rather than stretching to fill.
                        ForEach(Array(0..<max(0, perRow - row.count)), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private var rows: [[Option]] {
        stride(from: 0, to: options.count, by: max(1, perRow)).map { start in
            Array(options[start..<min(start + max(1, perRow), options.count)])
        }
    }

    private func tile(_ option: Option) -> some View {
        let selected = option == selection
        return VStack(spacing: 6) {
            picture(option)
            Text(label(option))
                .font(.body)
                .foregroundStyle(selected ? Color.primary : Color.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
        )
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 1.5)
            }
        }
    }
}

/// What an effect looks like *in the window*. The rotating effects render
/// from the same Rotation description (frames, step, wheel indices) their
/// device programs are generated from, LedEffects.wheelIndex on both sides,
/// with screen-bright stand-ins for the dim device hexes, so the window
/// shows exactly the motion the strip performs.
enum EffectScreen {
    /// Screen counterparts of the device wheels, entry for entry.
    private static let screenWheels: [String: [(r: Double, g: Double, b: Double)]] = [
        "rainbow": [(1.0, 0.2, 0.2), (1.0, 0.92, 0.25), (0.25, 0.9, 0.35),
                    (0.2, 0.85, 0.9), (0.3, 0.4, 1.0), (1.0, 0.35, 0.9)],
        "aurora": [(0.2, 0.9, 0.5), (0.2, 0.8, 0.8), (0.6, 0.4, 1.0)],
        "ocean": [(0.15, 0.35, 1.0), (0.1, 0.7, 0.9), (0.15, 0.8, 0.6)],
        "lava": [(1.0, 0.3, 0.1), (1.0, 0.55, 0.1), (0.85, 0.12, 0.08)],
    ]

    /// Colour and intensity for one dot. `t` nil means Reduce Motion: one
    /// honest still frame (the rainbow stays a rainbow, just parked).
    static func appearance(name: String, dot: Int, count: Int,
                           at t: TimeInterval?) -> (color: Color, level: Double) {
        let n = max(1, count)
        if let rotation = LedEffects.rotation(for: name),
           let wheel = screenWheels[name] {
            return rotating(rotation, wheel: wheel, dot: dot, count: n, at: t)
        }
        switch name {
        case "ember":
            let level = t.map { x in 0.2 + 0.8 * pow(sin(.pi * x / 3.2), 2) } ?? 1
            return (Color(red: 1.0, green: 0.55, blue: 0.2), level)
        case "sparkle":
            guard let t else { return (Color(white: 0.95), 1) }
            // The device program's slot permutation, so window and strip glint
            // in the same order.
            let cycle = 2.88
            let slot = Double((dot * 5) % n)
            let phase = ((t - slot * cycle / Double(n)) / cycle)
                .truncatingRemainder(dividingBy: 1)
            let wrapped = phase < 0 ? phase + 1 : phase
            let level = wrapped < 0.125 ? pow(sin(.pi * wrapped / 0.125), 2) : 0.04
            return (Color(white: 0.95), level)
        default:
            return (Color(white: 0.5), 0.3)
        }
    }

    /// Every LED lit, crossfading from its current frame's wheel entry to the
    /// next over the step time, the frame semantics the device program has.
    /// The blend is a plain RGB lerp: honest about the muddy midpoints two
    /// crossfading hues really pass through.
    private static func rotating(_ rotation: LedEffects.Rotation,
                                 wheel: [(r: Double, g: Double, b: Double)],
                                 dot: Int, count: Int,
                                 at t: TimeInterval?) -> (color: Color, level: Double) {
        func color(frame: Int) -> (r: Double, g: Double, b: Double) {
            wheel[LedEffects.wheelIndex(rotation, led: dot, frame: frame,
                                        ledCount: count) % wheel.count]
        }
        guard let t else { return (Color(rgb: color(frame: 0)), 1) }
        let step = Double(rotation.stepMs) / 1000
        let position = t / step
        let frame = Int(position.rounded(.down))
        let blend = position - position.rounded(.down)
        let from = color(frame: frame % rotation.frames)
        let to = color(frame: (frame + 1) % rotation.frames)
        return (Color(rgb: (from.r + (to.r - from.r) * blend,
                            from.g + (to.g - from.g) * blend,
                            from.b + (to.b - from.b) * blend)), 1)
    }
}

private extension Color {
    init(rgb: (r: Double, g: Double, b: Double)) {
        self.init(red: rgb.r, green: rgb.g, blue: rgb.b)
    }
}

extension Color {
    /// "#rrggbb" as the device understands it. Used for the forced-colour
    /// swatch only, the one place a raw hex is what the user picked.
    init?(deviceHex hex: String) {
        guard hex.count == 7, hex.hasPrefix("#"),
              let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

extension NSColor {
    /// The reverse direction, for the colour picker. sRGB, clamped, lowercase:
    /// the same shape LedMode.parse accepts.
    var deviceHex: String? {
        guard let srgb = usingColorSpace(.sRGB) else { return nil }
        let r = Int((srgb.redComponent * 255).rounded())
        let g = Int((srgb.greenComponent * 255).rounded())
        let b = Int((srgb.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", r, g, b)
    }
}

enum QRCode {
    /// Sharp-edged QR for the Notifications page. Rendered on demand and shown
    /// on screen only, because the encoded URL contains the raw topic.
    static func image(for string: String, scale: CGFloat = 8) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

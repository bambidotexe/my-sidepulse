import AppKit
import SwiftUI
import MySidepulseCore
import MySidepulsePlatform

/// What the strip is doing now, what it is told to do, and the hardware it is doing it on.
struct StripPage: View {
    @ObservedObject var model: SettingsModel
    /// Remembered so switching the picker to Colour has something sensible to force.
    @State private var lastHex = K.askAmber
    @State private var lastEffect = LedEffects.names[0]

    private enum ModeChoice: Hashable { case auto, off, colour, effect }

    var body: some View {
        let t = Loc.settings.strip
        SettingsPage {
            SettingsGroup(title: t.rightNowTitle) {
                SettingsRowFrame {
                    StripPreviewView(state: model.displayState, power: model.power,
                                     ledCount: ledCount, dotSize: 18, palette: model.palette)
                        .frame(maxWidth: .infinity)
                }
                StatusRow(t.showingLabel, mark: model.displayState.mark)
            }

            SettingsGroup(title: t.whatShowsTitle,
                          hint: t.whatShowsHint,
                          notes: [t.whatShowsNote]) {
                SegmentedRow(t.stripSegmentLabel, options: [ModeChoice.auto, .off, .colour, .effect],
                             selection: modeChoice) { choice in
                    switch choice {
                    case .auto: t.modeAuto
                    case .off: t.modeOff
                    case .colour: t.modeColour
                    case .effect: t.modeEffect
                    }
                }
                if case .color(let hex) = model.mode {
                    SettingsRow(t.colourLabel) {
                        HStack(spacing: 8) {
                            Text(hex)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                            ColorPicker(t.colourLabel, selection: colorBinding(current: hex),
                                        supportsOpacity: false)
                                .labelsHidden()
                        }
                    }
                }
                if case .effect(let name) = model.mode {
                    TileGrid(options: LedEffects.names, perRow: 3,
                             selection: effectSelection(current: name),
                             label: { $0.capitalized }) { effect in
                        StripPreviewView(state: .effect(effect), ledCount: ledCount, dotSize: 7,
                                         palette: model.palette)
                    }
                }
            }

            SettingsGroup(title: t.stripTitle, hint: stripHint, warnings: stalledWarnings) {
                if devices.isEmpty {
                    StatusRow(t.sidePulseStripLabel, mark: .warning(Loc.settings.words.missing))
                }
                ForEach(devices, id: \.path) { device in
                    StatusRow(t.deviceRow(name: device.name, leds: device.leds),
                              mark: device.stalled ? .warning(Loc.settings.words.stalled)
                                                   : .good(Loc.settings.words.available))
                        .help(t.mountedAtTooltip(device.path))
                    BrightnessRow(volumeName: device.name, model: model)
                }
            }

            if !orphans.isEmpty {
                SettingsGroup(title: t.rememberedBrightnessTitle,
                              hint: t.rememberedBrightnessHint) {
                    ForEach(orphans, id: \.key) { name, value in
                        StatusRow(name, mark: .info(t.percentValue(
                            BrightnessCurve.sliderPercent(device: value))))
                        ButtonRow {
                            Button(t.forgetButton) { model.setBrightness(nil, forVolumeName: name) }
                        }
                    }
                }
            }
        }
        .onAppear {
            if case .color(let hex) = model.mode { lastHex = hex }
            if case .effect(let name) = model.mode { lastEffect = name }
        }
    }

    // MARK: what is plugged in

    private var devices: [DeviceStatus] { model.status?.devices ?? [] }

    private var ledCount: Int { model.status?.devices?.first?.leds ?? K.defaultLedCount }

    /// The brightness kept for strips that are not mounted: the setting outlives the hardware,
    /// so it stays visible and removable.
    private var orphans: [(key: String, value: Int)] {
        let mounted = Set(devices.map { $0.name.lowercased() })
        return model.brightnessOverrides
            .filter { !mounted.contains($0.key) }
            .sorted { $0.key < $1.key }
    }

    private var stripHint: String {
        devices.isEmpty ? Loc.settings.strip.stripHintEmpty : Loc.settings.strip.stripHintPresent
    }

    private var stalledWarnings: [String] {
        devices.filter { $0.stalled }.map { Loc.settings.strip.stalledWarning(name: $0.name) }
    }

    // MARK: the mode

    private var modeChoice: Binding<ModeChoice> {
        Binding(
            get: {
                switch model.mode {
                case .auto: return .auto
                case .off: return .off
                case .color: return .colour
                case .effect: return .effect
                }
            },
            set: { choice in
                switch choice {
                case .auto: model.setMode(.auto)
                case .off: model.setMode(.off)
                case .colour: model.setMode(.color(lastHex))
                case .effect: model.setMode(.effect(lastEffect))
                }
            })
    }

    /// A tile grid deselects to nil; there is no "no effect" while the mode is Effect, so nil is
    /// ignored and re-picking the shown effect simply re-sends it.
    private func effectSelection(current: String) -> Binding<String?> {
        Binding(get: { current },
                set: { name in
                    guard let name else { return }
                    lastEffect = name
                    model.setMode(.effect(name))
                })
    }

    private func colorBinding(current: String) -> Binding<Color> {
        Binding(
            get: { Color(deviceHex: current) ?? .orange },
            set: { newColor in
                guard let hex = NSColor(newColor).deviceHex else { return }
                lastHex = hex
                model.setMode(.color(hex))
            })
    }
}

/// Committed on release, not per tick: each commit writes config.json and repaints the strip,
/// which is exactly one honest apply per adjustment.
/// The slider moves in perceived percent (`BrightnessCurve`), in steps the eye can tell apart
/// (`K.brightnessSliderStepPercent`), so its travel is even to the eye; what is stored and sent is
/// the strip's own 1…255.
private struct BrightnessRow: View {
    let volumeName: String
    @ObservedObject var model: SettingsModel
    @State private var percent = 100.0
    @State private var loaded = false

    var body: some View {
        SettingsRow(Loc.settings.strip.brightnessLabel) {
            HStack(spacing: 8) {
                Slider(value: $percent, in: Double(K.brightnessSliderStepPercent)...100,
                       step: Double(K.brightnessSliderStepPercent),
                       onEditingChanged: { editing in
                           guard !editing else { return }
                           let device = BrightnessCurve.device(percent: Int(percent.rounded()))
                           // 255 is the default: store nothing rather than a no-op.
                           model.setBrightness(device == 255 ? nil : device,
                                               forVolumeName: volumeName)
                       })
                    .frame(width: 220)
                Text(Loc.settings.strip.percentValue(Int(percent.rounded())))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            let device = model.brightnessOverrides[volumeName.lowercased()] ?? 255
            percent = Double(BrightnessCurve.sliderPercent(device: device))
        }
    }
}

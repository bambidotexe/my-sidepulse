import AppKit
import SwiftUI
import MySidepulseCore

/// The colour of each state, picked while the state plays: on screen in the Preview group, and on
/// the real strip through the same engine preview the Playground uses, which expires after
/// `K.playgroundPreviewSeconds`, restarts at every change and stops when this page is left.
struct ColorsPage: View {
    @ObservedObject var model: SettingsModel
    @State private var selected: LedPalette.Slot?
    /// `model.palette` plus the edit in flight: the colour panel streams a value per frame while
    /// dragging, and the pictures follow each one while the save waits for the drag to pause.
    @State private var livePalette: LedPalette = .standard
    @State private var pendingCommit: DispatchWorkItem?

    /// How long the colour panel must pause before its value is saved and written to the strip:
    /// one write per pause rather than one per frame of a drag. The Playground's custom colour
    /// commits on the same pause.
    private static let commitPause: TimeInterval = 0.3

    var body: some View {
        let t = Loc.settings.colors
        SettingsPage {
            SettingsGroup(title: t.previewTitle,
                          hint: t.previewHint(seconds: Int(K.playgroundPreviewSeconds)),
                          notes: noStripNotes) {
                SettingsRowFrame {
                    StripPreviewView(state: heroState, power: heroPower, ledCount: ledCount,
                                     dotSize: 18, palette: livePalette)
                        .frame(maxWidth: .infinity)
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    if let selected {
                        if let left = model.previewRemainingSeconds {
                            StatusRow(t.playingLabel,
                                      mark: .busy(t.playingRemaining(title: t.label(selected),
                                                                     seconds: Int(left.rounded()))))
                        } else {
                            StatusRow(t.playingLabel, mark: .info(t.playingEnded))
                        }
                    } else {
                        StatusRow(t.showingLabel, mark: model.displayState.mark)
                    }
                }
                if model.previewRemainingSeconds != nil {
                    ButtonRow {
                        Button(t.stopButton) {
                            model.stopPreview()
                            selected = nil
                        }
                    }
                }
            }

            SettingsGroup(title: t.coloursTitle, hint: t.coloursHint, notes: [t.coloursNote]) {
                ForEach(LedPalette.Slot.allCases, id: \.self) { slot in
                    row(for: slot)
                }
                ButtonRow {
                    Button(t.resetAllButton) { resetAll() }
                        .disabled(livePalette == .standard)
                }
            }
        }
        .onAppear { livePalette = model.palette }
        .onChange(of: model.palette) { _, palette in
            if pendingCommit == nil { livePalette = palette }
        }
        .onDisappear {
            flushPendingCommit()
            model.stopPreview()
            selected = nil
        }
    }

    // MARK: a colour's row

    /// The label and the small strip select the row; the hex field, the colour well and Reset each
    /// select it too, through the change they make.
    private func row(for slot: LedPalette.Slot) -> some View {
        let t = Loc.settings.colors
        let label = t.label(slot)
        let preview = slot.preview
        return SettingsRowFrame {
            HStack(spacing: SettingsMetrics.rowSpacing) {
                Button { play(slot) } label: {
                    Text(label)
                        .font(.body)
                        .foregroundStyle(Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain)
                .layoutPriority(1)
                Spacer(minLength: SettingsMetrics.rowSpacing)
                Button { play(slot) } label: {
                    StripPreviewView(state: preview.state, power: preview.power,
                                     ledCount: ledCount, dotSize: 7, palette: livePalette)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                HexField(hex: livePalette[slot], label: label) { hex in
                    change(slot, to: hex, afterPause: false)
                }
                ColorPicker(label, selection: colourBinding(for: slot), supportsOpacity: false)
                    .labelsHidden()
                Button(t.resetButton) { change(slot, to: nil, afterPause: false) }
                    .disabled(livePalette[slot] == LedPalette.standard[slot])
            }
        }
        .background(selected == slot ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    private func colourBinding(for slot: LedPalette.Slot) -> Binding<Color> {
        Binding(
            get: { Color(deviceHex: livePalette[slot]) ?? .black },
            set: { colour in
                guard let hex = NSColor(colour).deviceHex else { return }
                change(slot, to: hex, afterPause: true)
            })
    }

    // MARK: what a change does

    private func play(_ slot: LedPalette.Slot) {
        selected = slot
        model.startPreview(slot.preview.state, power: slot.preview.power)
    }

    /// Nil puts the slot back to its default. The pictures follow at once; the save, which repaints
    /// the strip, waits for the colour panel to pause and is immediate for everything else.
    private func change(_ slot: LedPalette.Slot, to hex: String?, afterPause: Bool) {
        livePalette[slot] = hex ?? LedPalette.standard[slot]
        selected = slot
        pendingCommit?.cancel()
        pendingCommit = nil
        guard afterPause else {
            commit(slot, hex)
            return
        }
        let work = DispatchWorkItem {
            pendingCommit = nil
            commit(slot, hex)
        }
        pendingCommit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.commitPause, execute: work)
    }

    private func commit(_ slot: LedPalette.Slot, _ hex: String?) {
        model.setColor(hex, for: slot)
        model.startPreview(slot.preview.state, power: slot.preview.power)
    }

    /// Leaving the page mid-drag still saves the colour the drag stopped on.
    private func flushPendingCommit() {
        guard let work = pendingCommit else { return }
        pendingCommit = nil
        work.cancel()
        work.perform()
    }

    private func resetAll() {
        pendingCommit?.cancel()
        pendingCommit = nil
        livePalette = .standard
        model.resetColors()
        if let selected { play(selected) }
    }

    // MARK: the preview

    private var heroState: DisplayState { selected?.preview.state ?? model.displayState }

    private var heroPower: PowerState? {
        guard let selected else { return model.power }
        return selected.preview.power ?? model.power
    }

    private var noStripNotes: [String] {
        (model.status?.devices ?? []).isEmpty ? [Loc.settings.colors.noStripNote] : []
    }

    private var ledCount: Int { model.status?.devices?.first?.leds ?? K.defaultLedCount }
}

/// A colour typed as `#rrggbb`: committed on Return or when the field loses focus, lowercased, and
/// put back to the current colour when it is anything else.
private struct HexField: View {
    let hex: String
    let label: String
    let onCommit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(label, text: $text)
            .labelsHidden()
            .font(.system(.body, design: .monospaced))
            .frame(width: 80)
            .focused($focused)
            .onSubmit { commit() }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            .onAppear { text = hex }
            .onChange(of: hex) { _, colour in
                if !focused { text = colour }
            }
    }

    private func commit() {
        let candidate = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard LedMode.isRGBHex(candidate) else {
            text = hex
            return
        }
        text = candidate
        if candidate != hex { onCommit(candidate) }
    }
}

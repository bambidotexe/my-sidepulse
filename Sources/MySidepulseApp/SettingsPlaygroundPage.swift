import AppKit
import SwiftUI
import MySidepulseCore

/// Try any display state on the real strip. Previews are display-only in the
/// engine, expire after `K.playgroundPreviewSeconds` on their own, and stop
/// when this page is left: three ways a forgotten experiment hands the strip
/// back.
struct PlaygroundPage: View {
    @ObservedObject var model: SettingsModel
    @State private var selected: String?
    @State private var glancePercent = 65.0
    @State private var customHex = K.askAmber
    @State private var colorCommit: DispatchWorkItem?

    private struct Card {
        let id: String
        let title: String
        let subtitle: String
        let state: DisplayState
    }

    private var cards: [Card] {
        let t = Loc.settings.playground
        return [
            Card(id: "working", title: t.titleWorking, subtitle: t.subtitleWorking,
                 state: .working(.claude)),
            Card(id: "codex-working", title: t.titleCodexWorking, subtitle: t.subtitleCodexWorking,
                 state: .working(.codex)),
            Card(id: "both-working", title: t.titleBothWorking, subtitle: t.subtitleBothWorking,
                 state: .working(.both)),
            Card(id: "waiting", title: t.titleWaiting, subtitle: t.subtitleWaiting,
                 state: .waiting(.claude)),
            Card(id: "done", title: t.titleDone, subtitle: t.subtitleDone,
                 state: .done(.claude)),
            Card(id: "waiting-working", title: t.titleWaitingWorking,
                 subtitle: t.subtitleWaitingWorking(leds: K.alertZoneLedsNeedsYou),
                 state: .split(alert: .waiting(.claude), work: .working(.claude))),
            Card(id: "done-working", title: t.titleDoneWorking,
                 subtitle: t.subtitleDoneWorking(leds: K.alertZoneLedsFinished),
                 state: .split(alert: .done(.claude), work: .working(.claude))),
            Card(id: "job", title: t.titleJob, subtitle: t.subtitleJob,
                 state: .jobRunning),
            Card(id: "critical", title: t.titleCritical,
                 subtitle: t.subtitleCritical(percent: K.batteryCriticalPercent),
                 state: .batteryCritical),
            Card(id: "glance", title: t.titleGlance, subtitle: t.subtitleGlance,
                 state: .batteryGlance),
            Card(id: "custom", title: t.titleCustom, subtitle: t.subtitleCustom,
                 state: .manualColor(customHex))]
    }

    /// The fun ones. Also full CLI modes (`mysidepulse led rainbow`), which is
    /// what "Keep It" switches to.
    private var effectCards: [Card] {
        let t = Loc.settings.playground
        let subtitles = ["rainbow": t.effectSubtitleRainbow,
                         "aurora": t.effectSubtitleAurora,
                         "ocean": t.effectSubtitleOcean,
                         "lava": t.effectSubtitleLava,
                         "ember": t.effectSubtitleEmber,
                         "sparkle": t.effectSubtitleSparkle]
        return LedEffects.names.map { name in
            Card(id: name, title: name.capitalized,
                 subtitle: subtitles[name] ?? "", state: .effect(name))
        }
    }

    private var allCards: [Card] { cards + effectCards }

    var body: some View {
        let t = Loc.settings.playground
        SettingsPage {
            SettingsGroup(title: t.onTheStripTitle, notes: stripNotes) {
                SettingsRowFrame {
                    StripPreviewView(state: heroState, power: heroPower,
                                     ledCount: ledCount, dotSize: 18, palette: model.palette)
                        .frame(maxWidth: .infinity)
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    if selected == nil {
                        StatusRow(t.showingLabel, mark: model.displayState.mark)
                    } else if let left = model.previewRemainingSeconds {
                        StatusRow(t.playingLabel,
                                  mark: .busy(t.playingRemaining(title: selectedTitle,
                                                                 seconds: Int(left.rounded()))))
                    } else {
                        StatusRow(t.playingLabel, mark: .info(t.playingEnded))
                    }
                }
                if selected == "glance" {
                    SettingsRow(t.batteryLevelLabel) {
                        HStack(spacing: 8) {
                            Slider(value: $glancePercent, in: 0...100,
                                   onEditingChanged: { editing in
                                       guard !editing, selected == "glance" else { return }
                                       model.startPreview(.batteryGlance, power: glancePower)
                                   })
                                .frame(width: 220)
                            Text("\(Int(glancePercent.rounded())) %")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if selected == "custom" {
                    SettingsRow(t.colourLabel) {
                        HStack(spacing: 8) {
                            Text(customHex)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                            ColorPicker(t.colourLabel, selection: customColorBinding,
                                        supportsOpacity: false)
                                .labelsHidden()
                        }
                    }
                }
                if selected != nil {
                    ButtonRow {
                        if let keep = keepMode {
                            Button(t.keepItButton) {
                                model.setMode(keep)
                                model.stopPreview()
                                selected = nil
                            }
                        }
                        Button(t.stopButton) {
                            model.stopPreview()
                            selected = nil
                        }
                    }
                }
            }

            SettingsGroup(title: t.statesTitle, hint: statesHint) {
                TileGrid(options: cards.map(\.id), perRow: 3, selection: tileSelection,
                         label: { title(of: $0) }) { id in
                    StripPreviewView(state: state(of: id),
                                     power: id == "glance" ? glancePower : nil,
                                     ledCount: ledCount, dotSize: 7, palette: model.palette)
                }
            }

            SettingsGroup(title: t.effectsTitle, hint: effectsHint,
                          notes: [t.effectsNote]) {
                TileGrid(options: effectCards.map(\.id), perRow: 3, selection: tileSelection,
                         label: { title(of: $0) }) { id in
                    StripPreviewView(state: .effect(id), ledCount: ledCount, dotSize: 7,
                                     palette: model.palette)
                }
            }
        }
        .onDisappear {
            colorCommit?.cancel()
            model.stopPreview()
            selected = nil
        }
    }

    // MARK: the tiles

    /// One binding for both grids: a card is picked by clicking it and put back by clicking it
    /// again, so at most one card anywhere on the page is ever selected.
    private var tileSelection: Binding<String?> {
        Binding(get: { selected },
                set: { id in
                    guard let id else { return }
                    if id == selected, previewActive {
                        model.stopPreview()
                        selected = nil
                    } else {
                        selected = id
                        if let card = allCards.first(where: { $0.id == id }) { play(card) }
                    }
                })
    }

    private func title(of id: String) -> String {
        allCards.first(where: { $0.id == id })?.title ?? id
    }

    private func state(of id: String) -> DisplayState {
        allCards.first(where: { $0.id == id })?.state ?? .off
    }

    private var selectedTitle: String { selected.map { title(of: $0) } ?? "" }

    private var selectedCard: Card? {
        selected.flatMap { id in allCards.first(where: { $0.id == id }) }
    }

    private var ledCount: Int { model.status?.devices?.first?.leds ?? K.defaultLedCount }

    private var stripNotes: [String] {
        (model.status?.devices ?? []).isEmpty ? [Loc.settings.playground.stripNoteNoDevice] : []
    }

    /// The hint describes the SELECTED card only: the tiles already show them all.
    private var statesHint: String {
        guard let card = selectedCard, cards.contains(where: { $0.id == card.id }) else {
            return Loc.settings.playground
                .statesHintDefault(seconds: Int(K.playgroundPreviewSeconds))
        }
        return card.subtitle
    }

    private var effectsHint: String {
        guard let card = selectedCard, effectCards.contains(where: { $0.id == card.id }) else {
            return Loc.settings.playground
                .effectsHintDefault(seconds: Int(K.playgroundPreviewSeconds))
        }
        return card.subtitle
    }

    // MARK: what is playing

    private var previewActive: Bool { model.previewRemainingSeconds != nil }

    private var heroState: DisplayState {
        guard let selected, previewActive || selectedIsLocal(selected),
              let card = allCards.first(where: { $0.id == selected }) else {
            return model.displayState
        }
        return card.state
    }

    private var heroPower: PowerState? {
        selected == "glance" ? glancePower : model.power
    }

    /// The hero keeps showing a selection even between slider commits, so the
    /// on-screen strip follows the controls live while the device only gets
    /// the committed values.
    private func selectedIsLocal(_ id: String) -> Bool { id == "glance" || id == "custom" }

    private var glancePower: PowerState {
        PowerState(percent: Int(glancePercent.rounded()), plugged: false,
                   charging: false, charged: false, present: true)
    }

    /// Effects and the custom colour exist as LED modes, so their previews
    /// can graduate into the persistent setting; the Claude states cannot,
    /// because only the real ladder decides those.
    private var keepMode: LedMode? {
        guard let selected else { return nil }
        if LedEffects.names.contains(selected) { return .effect(selected) }
        if selected == "custom" { return .color(customHex) }
        return nil
    }

    private var customColorBinding: Binding<Color> {
        Binding(
            get: { Color(deviceHex: customHex) ?? .orange },
            set: { newColor in
                guard let hex = NSColor(newColor).deviceHex else { return }
                customHex = hex
                guard selected == "custom" else { return }
                // The colour panel streams while dragging; the strip gets one
                // write per pause, the on-screen preview follows live.
                colorCommit?.cancel()
                let work = DispatchWorkItem { model.startPreview(.manualColor(hex)) }
                colorCommit = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            })
    }

    private func play(_ card: Card) {
        switch card.id {
        case "glance": model.startPreview(.batteryGlance, power: glancePower)
        case "custom": model.startPreview(.manualColor(customHex))
        default: model.startPreview(card.state)
        }
    }
}

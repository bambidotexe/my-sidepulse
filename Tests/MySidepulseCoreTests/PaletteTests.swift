import XCTest
@testable import MySidepulseCore

final class PaletteTests: XCTestCase {
    /// Nine colours no default uses, one per slot, so a program that paints
    /// a slot's colour can only have taken it from that slot. Bright enough
    /// that the battery bar's dimmed partial LED cannot land on another one.
    private let custom = LedPalette(
        working: "#c10000", codexWorking: "#c90000", needsYou: "#00c200", done: "#0000c3",
        jobRunning: "#c4c400", batteryCritical: "#00c5c5", batteryLow: "#c600c6",
        batteryMid: "#c7c7c7", batteryHigh: "#c8c8c8")

    private func program(_ state: DisplayState, power: PowerState? = nil,
                         palette: LedPalette) -> String {
        LedProgram.program(for: state, power: power, ledCount: 8, brightness: 255,
                           palette: palette)
    }

    func testTheStandardPaletteIsK() {
        let standard = LedPalette.standard
        XCTAssertEqual(standard[.working], K.claudeWorking)
        XCTAssertEqual(standard[.codexWorking], K.codexWorking)
        XCTAssertEqual(standard[.needsYou], K.askAmber)
        XCTAssertEqual(standard[.done], K.doneGreen)
        XCTAssertEqual(standard[.jobRunning], K.jobRunning)
        XCTAssertEqual(standard[.batteryCritical], K.batteryCriticalRed)
        XCTAssertEqual(standard[.batteryLow], K.batteryLowRed)
        XCTAssertEqual(standard[.batteryMid], K.batteryMidAmber)
        XCTAssertEqual(standard[.batteryHigh], K.batteryHighGreen)
    }

    func testTheSlotKeysAreTheOnesConfigJsonHolds() {
        XCTAssertEqual(LedPalette.Slot.allCases.map(\.rawValue),
                       ["working", "codexWorking", "needsYou", "done", "jobRunning", "batteryCritical",
                        "batteryLow", "batteryMid", "batteryHigh"],
                       "a renamed key orphans every saved colour")
    }

    func testAnOverrideReplacesOnlyItsOwnSlot() {
        let palette = LedPalette.standard.applying(overrides: ["done": "#123456"])
        for slot in LedPalette.Slot.allCases {
            XCTAssertEqual(palette[slot], slot == .done ? "#123456" : LedPalette.standard[slot],
                           "\(slot)")
        }
    }

    /// config.json can be edited by hand, and one malformed colour makes the
    /// whole program unreadable to the device: the strip would blink red
    /// instead of showing anything. So an override that is not `#rrggbb` is
    /// not trusted, and the slot keeps its default.
    func testAMalformedOverrideIsIgnored() {
        let palette = LedPalette.standard.applying(overrides: [
            "working": "123456", "needsYou": "#12345g", "done": "#+00000",
            "jobRunning": "#1234567", "batteryLow": "", "nonsense": "#ffffff",
        ])
        XCTAssertEqual(palette, .standard)
    }

    func testAnOverrideIsLowercased() {
        XCTAssertEqual(LedPalette.standard.applying(overrides: ["done": "#ABCDEF"]).done, "#abcdef")
    }

    func testASlotAtItsDefaultStoresNothing() {
        var saved = LedPalette.overrides([:], setting: .done, to: "#123456")
        XCTAssertEqual(saved, ["done": "#123456"])
        saved = LedPalette.overrides(saved, setting: .working, to: "#ABCDEF")
        XCTAssertEqual(saved, ["done": "#123456", "working": "#abcdef"])
        saved = LedPalette.overrides(saved, setting: .done, to: K.doneGreen.uppercased())
        XCTAssertEqual(saved, ["working": "#abcdef"], "the default itself removes the override")
        saved = LedPalette.overrides(saved, setting: .working, to: nil)
        XCTAssertEqual(saved, [:], "nil is Reset")
    }

    func testAMalformedColourChangesNothing() {
        let saved = ["done": "#123456"]
        XCTAssertEqual(LedPalette.overrides(saved, setting: .done, to: "red"), saved)
        XCTAssertEqual(LedPalette.overrides(saved, setting: .working, to: "#12345"), saved)
    }

    /// What the Colours page plays for a slot must paint that slot's colour,
    /// or the preview would show the owner something other than the colour
    /// they are picking. The battery rows only prove themselves this way: a
    /// charge in the wrong band would paint a neighbour's colour.
    func testEachSlotsPreviewPaintsThatSlotsColour() {
        for slot in LedPalette.Slot.allCases {
            let preview = slot.preview
            let text = program(preview.state, power: preview.power, palette: custom)
            XCTAssertTrue(text.contains(custom[slot]), "\(slot): \(text)")
            for other in LedPalette.Slot.allCases where other != slot {
                XCTAssertFalse(text.contains(custom[other]), "\(slot) also paints \(other)")
            }
        }
    }

    /// A job's alerts are the same alerts as a session's on the strip, so
    /// they share its colours; the split paints both of its sides from the
    /// palette.
    func testJobAlertsAndTheSplitTakeThePalette() {
        XCTAssertEqual(program(.jobFailed, palette: custom), program(.waiting, palette: custom))
        XCTAssertEqual(program(.jobSucceeded, palette: custom), program(.done, palette: custom))
        let asking = program(.split(alert: .waiting, work: .jobRunning), palette: custom)
        XCTAssertTrue(asking.contains(custom.needsYou) && asking.contains(custom.jobRunning), asking)
        let finished = program(.split(alert: .done, work: .working), palette: custom)
        XCTAssertTrue(finished.contains(custom.done) && finished.contains(custom.working), finished)
    }

    func testThePaletteLeavesManualColoursAndEffectsAlone() {
        XCTAssertEqual(program(.manualColor("#123456"), palette: custom), "#123456")
        XCTAssertEqual(program(.effect("ember"), palette: custom),
                       program(.effect("ember"), palette: .standard))
    }
}

import XCTest
@testable import MySidepulseCore

final class ProgramTests: XCTestCase {
    func p(_ s: DisplayState, power: PowerState? = nil, leds: Int = 8, brightness: Int = 255) -> String {
        LedProgram.program(for: s, power: power, ledCount: leds, brightness: brightness)
    }

    func testOffIsBareOff() {
        XCTAssertEqual(p(.off), "off")
        XCTAssertEqual(p(.off, brightness: 40), "off", "dimming darkness is meaningless — no prefix on off")
    }

    func testWorkingEightLeds() {
        XCTAssertEqual(p(.working), """
        off 160ms cosine
        0:#250707 760ms pulse 0ms; 1:#250707 760ms pulse 95ms; 2:#250707 760ms pulse 190ms; 3:#250707 760ms pulse 285ms; 4:#250707 760ms pulse 380ms; 5:#250707 760ms pulse 475ms; 6:#250707 760ms pulse 570ms; 7:#250707 760ms pulse 665ms
        repeat
        """)
    }

    func testWorkingDotUsesTwoLedsAndDotStagger() {
        XCTAssertEqual(p(.working, leds: 2), """
        off 160ms cosine
        0:#250707 760ms pulse 0ms; 1:#250707 760ms pulse 260ms
        repeat
        """)
    }

    /// The device contract, byte for byte. Every token here is a shape the
    /// device is already known to take: the whole-strip pulse this state has
    /// always used, and `off <dur>`, which the vendor's own INIT.LED ends
    /// with. Two pulses separated by dark, then a longer dark pause — the
    /// double blink the strip must show.
    func testWaitingBlinksTwice() {
        XCTAssertEqual(p(.waiting), """
        off
        #331500 200ms pulse
        off 70ms
        #331500 200ms pulse
        off 1030ms
        repeat
        """)
        // Told apart from "finished" by motion now, not only by colour.
        XCTAssertNotEqual(p(.waiting), p(.done))
    }

    /// "Needs you" alone and "needs you + working" must share the SAME
    /// rhythm. The split's pause is pinned by its roll line, so the full
    /// blink's pause is what moved — and this derivation
    /// keeps them locked: retune the blink, the roll, the stagger or the
    /// zone width and this fails rather than letting the two drift apart.
    func testNeedsYouRhythmMatchesTheSplit() {
        let fullCycle = K.askBlinkMs + K.askBlinkGapMs + K.askBlinkMs + K.askBlinkPauseMs
        let zone = LedProgram.splitZone(alert: .waiting, ledCount: 8)
        let rest = 8 - zone
        let rollLine = (rest - 1) * K.rollingStaggerMs + K.rollingPulseMs
        let splitCycle = K.rollingFadeMs + K.askBlinkMs + max(rollLine, K.askBlinkGapMs + K.askBlinkMs)
        XCTAssertEqual(fullCycle, splitCycle, "the two needs-you rhythms must not drift apart")
        let splitPairEnd = K.rollingFadeMs + K.askBlinkMs + K.askBlinkGapMs + K.askBlinkMs
        let splitPause = splitCycle - splitPairEnd + K.rollingFadeMs
        XCTAssertEqual(splitPause, K.askBlinkPauseMs, "pause between pairs must match exactly")
    }

    func testWaitingDoneCritical() {
        XCTAssertEqual(p(.done), "off\n#003311 4.5s pulse\nrepeat")
        XCTAssertEqual(p(.batteryCritical), "off\n#220000 6.0s pulse\nrepeat")
    }

    func testGlanceThirtyPercent() {
        let program = p(.batteryGlance, power: PowerState(percent: 30))
        XCTAssertEqual(program,
            "0:#330900 360ms;1:#330900 360ms;2:#140300 360ms;3:#000000 360ms;4:#000000 360ms;5:#000000 360ms;6:#000000 360ms;7:#000000 360ms")
    }

    func testGlanceWithoutPowerIsOff() {
        XCTAssertEqual(p(.batteryGlance, power: nil), "off")
    }

    func testManualColor() {
        XCTAssertEqual(p(.manualColor("#ff8800")), "#ff8800")
    }

    func testBrightnessPrefix() {
        XCTAssertEqual(p(.done, brightness: 128), "brightness 128\noff\n#003311 4.5s pulse\nrepeat")
        XCTAssertEqual(p(.done, brightness: 255), "off\n#003311 4.5s pulse\nrepeat")
        XCTAssertEqual(p(.done, brightness: 0), "brightness 1\noff\n#003311 4.5s pulse\nrepeat", "clamped to 1")
    }

    /// A job in flight rolls like Claude does — motion says something is
    /// happening — but in its own colour. Its outcomes reuse the Claude alert
    /// programs byte for byte, so the writer's dedupe never sees a spurious
    /// change.
    func testJobPrograms() {
        XCTAssertEqual(p(.jobRunning), """
        off 160ms cosine
        0:#221130 760ms pulse 0ms; 1:#221130 760ms pulse 95ms; 2:#221130 760ms pulse 190ms; 3:#221130 760ms pulse 285ms; 4:#221130 760ms pulse 380ms; 5:#221130 760ms pulse 475ms; 6:#221130 760ms pulse 570ms; 7:#221130 760ms pulse 665ms
        repeat
        """)
        XCTAssertEqual(p(.jobSucceeded), p(.done))
        XCTAssertEqual(p(.jobFailed), p(.waiting))
        XCTAssertEqual(p(.jobRunning, leds: 2), """
        off 160ms cosine
        0:#221130 760ms pulse 0ms; 1:#221130 760ms pulse 260ms
        repeat
        """)
    }

    /// These are hand-tuned against the hardware, so a typo is plausible and
    /// costs more than a wrong colour: the device cannot parse the program at
    /// all and blinks red six times instead of showing anything.
    func testEveryColourConstantIsAValidProgramColour() {
        let palette: [(String, String)] = [
            ("claudeWorking", K.claudeWorking),
            ("jobRunning", K.jobRunning), ("askAmber", K.askAmber), ("doneGreen", K.doneGreen),
            ("batteryCriticalRed", K.batteryCriticalRed), ("batteryLowRed", K.batteryLowRed),
            ("batteryMidAmber", K.batteryMidAmber), ("batteryHighGreen", K.batteryHighGreen),
            ("batteryOff", K.batteryOff),
        ]
        for (name, hex) in palette {
            XCTAssertTrue(LedMode.isRGBHex(hex), "\(name) = \(hex) is not #RRGGBB")
        }
        let effectColours = LedEffects.rainbowWheel + LedEffects.auroraWaves
            + LedEffects.oceanWaves + LedEffects.lavaFlows
            + [LedEffects.emberGlow, LedEffects.sparkleGlint]
        for hex in effectColours {
            XCTAssertTrue(LedMode.isRGBHex(hex), "effect colour \(hex) is not #RRGGBB")
        }
    }

    // MARK: effects — device contract, exact text

    /// The rotating effects are frame sequences — one per-LED assignment
    /// line per step, glance-shaped, crossfading in a loop — so every LED is
    /// always lit and the colours travel. The 512-byte cap fixes the frame
    /// count, and the duration's spelling is what decides it: at "3s" a frame
    /// line is 103 bytes and four fit (437 with a brightness line); at
    /// "3000ms" it is 127 and only three do.
    func testRainbowRotatesTheWheelWithEveryLedOn() {
        XCTAssertEqual(p(.effect("rainbow")), """
        0:#380000 0.2s;1:#381c00 0.2s;2:#383800 0.2s;3:#003800 0.2s;4:#003838 0.2s;5:#000038 0.2s;6:#1c0038 0.2s;7:#380038 0.2s
        0:#383800 0.2s;1:#003800 0.2s;2:#003838 0.2s;3:#000038 0.2s;4:#1c0038 0.2s;5:#380038 0.2s;6:#380000 0.2s;7:#381c00 0.2s
        0:#003838 0.2s;1:#000038 0.2s;2:#1c0038 0.2s;3:#380038 0.2s;4:#380000 0.2s;5:#381c00 0.2s;6:#383800 0.2s;7:#003800 0.2s
        0:#1c0038 0.2s;1:#380038 0.2s;2:#380000 0.2s;3:#381c00 0.2s;4:#383800 0.2s;5:#003800 0.2s;6:#003838 0.2s;7:#000038 0.2s
        repeat
        """)
    }

    func testRainbowOnTheDotPicksComplementaryHues() {
        XCTAssertEqual(p(.effect("rainbow"), leds: 2), """
        0:#380000 0.2s;1:#003838 0.2s
        0:#383800 0.2s;1:#1c0038 0.2s
        0:#003838 0.2s;1:#380000 0.2s
        0:#1c0038 0.2s;1:#383800 0.2s
        repeat
        """)
    }

    func testAuroraOceanLavaRotateTheirPalettes() {
        XCTAssertEqual(p(.effect("aurora")), """
        0:#003812 0.9s;1:#00332e 0.9s;2:#120038 0.9s;3:#003812 0.9s;4:#00332e 0.9s;5:#120038 0.9s;6:#003812 0.9s;7:#00332e 0.9s
        0:#00332e 0.9s;1:#120038 0.9s;2:#003812 0.9s;3:#00332e 0.9s;4:#120038 0.9s;5:#003812 0.9s;6:#00332e 0.9s;7:#120038 0.9s
        0:#120038 0.9s;1:#003812 0.9s;2:#00332e 0.9s;3:#120038 0.9s;4:#003812 0.9s;5:#00332e 0.9s;6:#120038 0.9s;7:#003812 0.9s
        repeat
        """)
        XCTAssertEqual(p(.effect("ocean")), """
        0:#001238 0.8s;1:#003038 0.8s;2:#002e26 0.8s;3:#001238 0.8s;4:#003038 0.8s;5:#002e26 0.8s;6:#001238 0.8s;7:#003038 0.8s
        0:#003038 0.8s;1:#002e26 0.8s;2:#001238 0.8s;3:#003038 0.8s;4:#002e26 0.8s;5:#001238 0.8s;6:#003038 0.8s;7:#002e26 0.8s
        0:#002e26 0.8s;1:#001238 0.8s;2:#003038 0.8s;3:#002e26 0.8s;4:#001238 0.8s;5:#003038 0.8s;6:#002e26 0.8s;7:#001238 0.8s
        repeat
        """)
        XCTAssertEqual(p(.effect("lava")), """
        0:#380400 0.8s;1:#381400 0.8s;2:#300000 0.8s;3:#380400 0.8s;4:#381400 0.8s;5:#300000 0.8s;6:#380400 0.8s;7:#381400 0.8s
        0:#381400 0.8s;1:#300000 0.8s;2:#380400 0.8s;3:#381400 0.8s;4:#300000 0.8s;5:#380400 0.8s;6:#381400 0.8s;7:#300000 0.8s
        0:#300000 0.8s;1:#380400 0.8s;2:#381400 0.8s;3:#300000 0.8s;4:#380400 0.8s;5:#381400 0.8s;6:#300000 0.8s;7:#380400 0.8s
        repeat
        """)
        XCTAssertEqual(p(.effect("aurora"), leds: 2), """
        0:#003812 0.9s;1:#00332e 0.9s
        0:#00332e 0.9s;1:#120038 0.9s
        0:#120038 0.9s;1:#003812 0.9s
        repeat
        """)
    }

    func testEmberIsTheWaitingShapeAtAFiresidePace() {
        XCTAssertEqual(p(.effect("ember")), "off\n#381200 3.2s pulse\nrepeat")
        XCTAssertEqual(p(.effect("ember"), leds: 2), "off\n#381200 3.2s pulse\nrepeat")
    }

    func testSparkleScattersDeterministically() {
        XCTAssertEqual(p(.effect("sparkle")), """
        off 160ms cosine
        0:#2e2e38 360ms pulse 0ms; 1:#2e2e38 360ms pulse 1800ms; 2:#2e2e38 360ms pulse 720ms; 3:#2e2e38 360ms pulse 2520ms; 4:#2e2e38 360ms pulse 1440ms; 5:#2e2e38 360ms pulse 360ms; 6:#2e2e38 360ms pulse 2160ms; 7:#2e2e38 360ms pulse 1080ms
        repeat
        """)
        XCTAssertEqual(p(.effect("sparkle"), leds: 2), """
        off 160ms cosine
        0:#2e2e38 360ms pulse 0ms; 1:#2e2e38 360ms pulse 1440ms
        repeat
        """)
    }

    func testUnknownEffectNameFallsBackToOff() {
        XCTAssertEqual(p(.effect("disco")), "off",
                       "only a hand-edited config can get here — dark beats red-blink parse errors")
    }

    func testEffectsTakeTheBrightnessPrefix() {
        XCTAssertEqual(p(.effect("ember"), brightness: 128),
                       "brightness 128\noff\n#381200 3.2s pulse\nrepeat")
    }

    /// Both hardcoded sites in Engine.sync() ask this instead of listing
    /// states, so a new alert state cannot silently miss ack polling.
    func testAlertableStates() {
        for state: DisplayState in [.waiting, .done, .jobFailed, .jobSucceeded] {
            XCTAssertTrue(state.isAlertable, "\(state) is an unread notification")
        }
        for state: DisplayState in [.off, .working, .jobRunning, .batteryCritical,
                                    .batteryGlance, .manualColor("#123456"),
                                    .effect("rainbow")] {
            XCTAssertFalse(state.isAlertable, "\(state) is not acknowledgeable")
        }
    }

    /// The split display, in the shapes the strip itself dictates: a
    /// baseline frame assigning every LED (a pulse returns to its
    /// PRE-pulse value, so the baseline is what makes dark gaps dark),
    /// then — since scheduling the same LED twice in one line does NOT
    /// stack (it renders one pulse) — the amber pair composed ACROSS
    /// lines: the first blink on its own line, the second on the roll's
    /// line behind the gap's delay. The needs-you zone is wider than the
    /// finished zone. A green zone is set once in the baseline and holds;
    /// it schedules no pulses.
    func testSplitAlertZonePlusWorkingRoll() {
        XCTAssertEqual(p(.split(alert: .waiting, work: .working)), """
        0:#000000 160ms; 1:#000000 160ms; 2:#000000 160ms; 3:#000000 160ms; 4:#000000 160ms; 5:#000000 160ms; 6:#000000 160ms; 7:#000000 160ms
        0:#331500 200ms pulse 0ms; 1:#331500 200ms pulse 0ms; 2:#331500 200ms pulse 0ms
        0:#331500 200ms pulse 70ms; 1:#331500 200ms pulse 70ms; 2:#331500 200ms pulse 70ms; 3:#250707 760ms pulse 0ms; 4:#250707 760ms pulse 95ms; 5:#250707 760ms pulse 190ms; 6:#250707 760ms pulse 285ms; 7:#250707 760ms pulse 380ms
        repeat
        """)
        XCTAssertEqual(p(.split(alert: .done, work: .working)), """
        0:#003311 160ms; 1:#003311 160ms; 2:#000000 160ms; 3:#000000 160ms; 4:#000000 160ms; 5:#000000 160ms; 6:#000000 160ms; 7:#000000 160ms
        2:#250707 760ms pulse 0ms; 3:#250707 760ms pulse 95ms; 4:#250707 760ms pulse 190ms; 5:#250707 760ms pulse 285ms; 6:#250707 760ms pulse 380ms; 7:#250707 760ms pulse 475ms
        repeat
        """)
        // Job outcomes are byte-identical to their Claude counterparts, as
        // everywhere; a job base rolls in the job colour.
        XCTAssertEqual(p(.split(alert: .jobFailed, work: .working)),
                       p(.split(alert: .waiting, work: .working)))
        XCTAssertEqual(p(.split(alert: .jobSucceeded, work: .working)),
                       p(.split(alert: .done, work: .working)))
        XCTAssertTrue(p(.split(alert: .done, work: .jobRunning)).contains(K.jobRunning))
        // Brightness prefixes exactly like every other program.
        XCTAssertTrue(p(.split(alert: .done, work: .working), brightness: 40)
            .hasPrefix("brightness 40\n"))
    }

    /// The Dot keeps one LED for the roll whatever the zone constants say.
    func testSplitOnTheDotLeavesOneLedRolling() {
        XCTAssertEqual(p(.split(alert: .waiting, work: .working), leds: 2), """
        0:#000000 160ms; 1:#000000 160ms
        0:#331500 200ms pulse 0ms
        0:#331500 200ms pulse 70ms; 1:#250707 760ms pulse 0ms
        repeat
        """)
    }

    func testProgramsRespectDeviceLimits() {
        var states: [DisplayState] = [.off, .working, .waiting, .done, .batteryCritical,
                                      .batteryGlance, .manualColor("#123456"),
                                      .jobRunning, .jobSucceeded, .jobFailed,
                                      .split(alert: .waiting, work: .working),
                                      .split(alert: .done, work: .working),
                                      .split(alert: .jobFailed, work: .jobRunning),
                                      .split(alert: .jobSucceeded, work: .jobRunning)]
        states += LedEffects.names.map { .effect($0) }
        for state in states {
            let program = p(state, power: PowerState(percent: 42), brightness: 200)
            XCTAssertLessThanOrEqual(program.utf8.count, 512, "\(state) exceeds 512 bytes")
            XCTAssertLessThanOrEqual(program.split(separator: "\n").count, 20, "\(state) exceeds 20 lines")
        }
    }

    func testLedCountFromVolumeName() {
        XCTAssertEqual(LedProgram.ledCount(volumeName: "SidePulsePro"), 8)
        XCTAssertEqual(LedProgram.ledCount(volumeName: "sidepulsedot"), 2)
        XCTAssertEqual(LedProgram.ledCount(volumeName: "MySidepulse"), 8)
        XCTAssertEqual(LedProgram.ledCount(volumeName: "Untitled"), 8)
    }
}

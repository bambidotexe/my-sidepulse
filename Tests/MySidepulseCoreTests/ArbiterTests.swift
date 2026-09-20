import XCTest
@testable import MySidepulseCore

final class ArbiterTests: XCTestCase {
    func session(_ id: String, _ state: SessionState, acked: Bool = false, host: String? = nil) -> Session {
        var s = Session(id: id, stateSince: Date(timeIntervalSince1970: 0),
                        lastEventAt: Date(timeIntervalSince1970: 0))
        s.state = state; s.acknowledged = acked; s.hostBundleId = host
        return s
    }
    func decide(mode: LedMode = .auto, power: PowerState? = nil, glance: Bool = false,
                _ sessions: [Session] = [], jobs: [Job] = []) -> DisplayState {
        Arbiter.decide(mode: mode, power: power, glanceActive: glance,
                       sessions: sessions, jobs: jobs, now: Date(timeIntervalSince1970: 0))
    }

    func job(_ id: String, _ state: JobState, acked: Bool = false) -> Job {
        var j = Job(id: id, stateSince: Date(timeIntervalSince1970: 0))
        j.state = state; j.acknowledged = acked
        return j
    }

    /// The ladder of section 5 under the split rule: an alert and running
    /// work SHARE the strip (alert zone + the roll) rather than one hiding
    /// the other. Within each half, Claude outranks a job at its matching
    /// rung, and needs-you outranks finished.
    func testJobsInterleaveBelowTheirClaudeCounterparts() {
        XCTAssertEqual(decide(jobs: [job("j", .running)]), .jobRunning)
        XCTAssertEqual(decide(jobs: [job("j", .succeeded)]), .jobSucceeded)
        XCTAssertEqual(decide(jobs: [job("j", .failed)]), .jobFailed)

        XCTAssertEqual(decide([session("s", .waiting(.question))], jobs: [job("j", .failed)]),
                       .waiting, "Claude needing you outranks a failed job for the zone")
        XCTAssertEqual(decide([session("s", .working)], jobs: [job("j", .failed)]),
                       .split(alert: .jobFailed, work: .working),
                       "a failed job gets the zone; the work keeps the rest")
        XCTAssertEqual(decide([session("s", .working)], jobs: [job("j", .running)]),
                       .working, "Claude working outranks a job running for the whole strip")
        XCTAssertEqual(decide([session("s", .done)], jobs: [job("j", .running)]),
                       .split(alert: .done, work: .jobRunning),
                       "a finish is news even over a running job")
        XCTAssertEqual(decide([session("s", .done)], jobs: [job("j", .succeeded)]),
                       .done, "Claude done outranks a job done")
    }

    func testAcknowledgedJobsStopDisplaying() {
        XCTAssertEqual(decide(jobs: [job("j", .succeeded, acked: true)]), .off)
        XCTAssertEqual(decide(jobs: [job("j", .failed, acked: true)]), .off)
        XCTAssertEqual(decide([session("s", .done)], jobs: [job("j", .failed, acked: true)]),
                       .done, "an acknowledged job drops out of the ladder entirely")
    }

    func testBatteryAndManualStillOutrankJobs() {
        XCTAssertEqual(decide(power: PowerState(percent: 5), jobs: [job("j", .failed)]),
                       .batteryCritical)
        XCTAssertEqual(decide(mode: .off, jobs: [job("j", .running)]), .off)
    }

    func testManualOverridesEverything() {
        let critical = PowerState(percent: 5)
        XCTAssertEqual(decide(mode: .off, power: critical, [session("s1", .waiting(.question))]), .off)
        XCTAssertEqual(decide(mode: .color("#ff0000"), power: critical), .manualColor("#ff0000"))
    }

    func testBatteryBeatsAgents() {
        XCTAssertEqual(decide(power: PowerState(percent: 5), [session("s1", .working)]), .batteryCritical)
        XCTAssertEqual(decide(power: PowerState(percent: 80, plugged: true), glance: true,
                              [session("s1", .working)]), .batteryGlance)
        XCTAssertEqual(decide(power: nil, glance: true, [session("s1", .working)]), .working,
                       "no battery, no glance")
    }

    func testBatteryCriticalBeatsGlance() {
        XCTAssertEqual(decide(power: PowerState(percent: 5), glance: true,
                              [session("s1", .working)]), .batteryCritical,
                       "a dying battery outranks the plug/unplug glance")
    }

    /// A finish or a request must be visible even while another session
    /// still works — the alert takes the zone, the work keeps the rest.
    /// Alone, either takes the whole strip.
    func testAgentPriority() {
        XCTAssertEqual(decide([session("a", .done), session("b", .working),
                               session("c", .waiting(.permission))]),
                       .split(alert: .waiting, work: .working),
                       "needs-you wins the zone over a finish; the work keeps rolling")
        XCTAssertEqual(decide([session("a", .done), session("b", .working)]),
                       .split(alert: .done, work: .working),
                       "a finished session is never hidden behind a working one")
        XCTAssertEqual(decide([session("a", .done), session("b", .idle)]), .done,
                       "nothing running: the finish takes the whole strip")
        XCTAssertEqual(decide([session("c", .waiting(.question)), session("b", .idle)]), .waiting,
                       "nothing running: the request takes the whole strip")
        XCTAssertEqual(decide([session("b", .idle)]), .off)
        XCTAssertEqual(decide(), .off)
        XCTAssertTrue(DisplayState.split(alert: .waiting, work: .working).isAlertable,
                      "a split carries an unread alert — input polling must arm")
    }

    func testAcknowledgedAlertsAreInvisible() {
        XCTAssertEqual(decide([session("a", .waiting(.question), acked: true)]), .off)
        XCTAssertEqual(decide([session("a", .done, acked: true)]), .off)
        XCTAssertEqual(decide([session("a", .done, acked: true), session("b", .working)]), .working)
    }

    /// Acknowledging an amber while a subagent or background shell is still
    /// running must not go dark, though the alert itself is seen: it falls
    /// back to showing the work.
    func testAcknowledgedWaitWithWorkInFlightShowsWorking() {
        var withHelper = session("a", .waiting(.permission), acked: true)
        withHelper.liveAgents = ["h1": Date(timeIntervalSince1970: 0)]
        XCTAssertEqual(decide([withHelper]), .working)

        var withShell = session("b", .waiting(.question), acked: true)
        withShell.backgroundIds = ["bash_1"]
        XCTAssertEqual(decide([withShell]), .working)

        var deadTurn = session("c", .waiting(.error), acked: true)
        deadTurn.backgroundIds = ["bash_1"]
        XCTAssertEqual(decide([deadTurn]), .off,
                       "a dead turn's leftovers are not work in flight")

        var expired = session("d", .waiting(.permission), acked: true)
        expired.liveAgents = ["h1": Date(timeIntervalSince1970: -Double(K.agentStaleSeconds) - 1)]
        XCTAssertEqual(decide([expired]), .off,
                       "a helper past the silence window no longer counts as running")
    }

    func testLedModeParse() {
        XCTAssertEqual(LedMode.parse("auto"), .auto)
        XCTAssertEqual(LedMode.parse("off"), .off)
        XCTAssertEqual(LedMode.parse("#FF8800"), .color("#ff8800"))
        XCTAssertNil(LedMode.parse("#ff88"))
        XCTAssertNil(LedMode.parse("red"))
        XCTAssertEqual(LedMode.parse(LedMode.color("#ff8800").configValue), .color("#ff8800"))
        XCTAssertEqual(LedMode.parse(LedMode.auto.configValue), .auto)
    }

    func testEffectsParseLikeModesAndOutrankEverything() {
        for name in LedEffects.names {
            XCTAssertEqual(LedMode.parse(name), .effect(name))
            XCTAssertEqual(LedMode.parse(LedMode.effect(name).configValue), .effect(name),
                           "\(name) must survive the config round trip")
        }
        XCTAssertEqual(LedMode.parse("RAINBOW"), .effect("rainbow"))
        XCTAssertNil(LedMode.parse("disco"), "only the allowlist reaches the device")
        let critical = PowerState(percent: 5, plugged: false)
        XCTAssertEqual(decide(mode: .effect("rainbow"), power: critical,
                              [session("s1", .waiting(.question))]),
                       .effect("rainbow"),
                       "an effect is a manual override — rung 1, like a forced colour")
        XCTAssertEqual(LedMode.effect("rainbow").toggled(), .off,
                       "the shortcut keeps its single direction")
    }

    func testLedModeToggleHasOnePredictableDirection() {
        XCTAssertEqual(LedMode.off.toggled(), .auto, "off hands the strip back to the rules")
        XCTAssertEqual(LedMode.auto.toggled(), .off)
        XCTAssertEqual(LedMode.color("#ff8800").toggled(), .off,
                       "a forced colour toggles to off, not to auto")
        XCTAssertEqual(LedMode.off.toggled().toggled(), .off, "two presses return to where you started")
    }

    func testLedModeRejectsMalformedHex() {
        XCTAssertNil(LedMode.parse("#+00000"), "a leading sign is not a hex colour")
        XCTAssertNil(LedMode.parse("#-00000"))
        XCTAssertNil(LedMode.parse("#zzzzzz"))
        XCTAssertNil(LedMode.parse("#12345"))
        XCTAssertNil(LedMode.parse("#1234567"))
        XCTAssertNil(LedMode.parse("123456"), "missing #")
        XCTAssertNil(LedMode.parse(""))
    }

    func testAcknowledgeAlertsByHost() {
        var store = SessionStore()
        store.apply(ev(.userPromptSubmit, 0, host: "com.mitchellh.ghostty"))
        store.apply(ev(.stop, 1, tail: "Done."))
        store.apply(ev(.userPromptSubmit, 0, sid: "s2", host: "com.apple.Terminal"))
        store.apply(ev(.stop, 1, sid: "s2", tail: "Need anything else?"))
        XCTAssertTrue(store.acknowledgeAlerts(hostBundleId: "org.other.app").isEmpty)
        XCTAssertFalse(store.acknowledgeAlerts(hostBundleId: "com.mitchellh.ghostty").isEmpty)
        XCTAssertTrue(store.sessions["s1"]!.acknowledged)
        XCTAssertFalse(store.sessions["s2"]!.acknowledged, "only the matching host clears")
        XCTAssertTrue(store.acknowledgeAlerts(hostBundleId: "com.mitchellh.ghostty").isEmpty,
                      "second call reports no change")
    }

    func testNewAlertInstanceReArms() {
        var store = SessionStore()
        store.apply(ev(.userPromptSubmit, 0, host: "com.apple.Terminal"))
        store.apply(ev(.stop, 1, tail: "Done."))
        _ = store.acknowledgeAlerts(hostBundleId: "com.apple.Terminal")
        store.apply(ev(.userPromptSubmit, 2))
        store.apply(ev(.stop, 3, tail: "Done again."))
        XCTAssertFalse(store.sessions["s1"]!.acknowledged, "a newer alert re-arms")
    }
}

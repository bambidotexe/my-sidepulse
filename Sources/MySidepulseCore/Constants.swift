import Foundation

/// The timings here were calibrated by eye on real SidePulse hardware: do
/// not retune them except against the device.
///
/// The colours are the owner's defaults for `LedPalette.standard`, which the
/// Colours page overrides slot by slot. Each is a true colour, the same hex on
/// the strip and on screen; the strip's brightness setting is what dims it,
/// never a darker hex.
public enum K {
    public static let claudeWorking = "#ff374a"
    /// A terminal job in flight.
    public static let jobRunning = "#ba5eff"
    public static let askAmber = "#ff7000"
    /// "Needs you" is a double blink, not a breath: two fast pulses, a short
    /// dark gap between them, then a longer dark pause before repeating —
    /// this is the one state worth interrupting for, so it must catch the
    /// eye from across the room.
    ///
    /// Felt values, not derived ones — except the pause,
    /// which is derived (see below). Retune by eye on the strip, never from
    /// the numbers. Cycle 1.5 s, shared exactly with the split's amber zone.
    ///
    /// The gap is what makes the two blinks read as ONE pair rather than four
    /// separate flashes, and it does that by being far shorter than the pause
    /// — keep it well under a third of it. Below roughly 50 ms the two start
    /// merging into a single long pulse, which is the other failure.
    ///
    /// For a pure speed change, scale blink and pause together and leave the
    /// gap's proportion alone; the gap is its own dial, for how tightly the
    /// pair holds together.
    ///
    /// The pause is 1030 and not free to be felt alone: the full-strip blink
    /// and the split's amber zone must land IN THE SAME RHYTHM, and
    /// the split's pause is pinned by its roll line — pair end (baseline +
    /// blink + gap + blink = 630 ms) to the next cycle's first blink, which
    /// on the 8-LED strip with the 3-LED zone is exactly 1030 ms. Both
    /// cycles land on 1500 ms. testNeedsYouRhythmMatchesTheSplit derives
    /// this from the constants, so retuning any of them (or the zone width,
    /// or the roll) breaks a test instead of silently breaking the match.
    public static let askBlinkMs = 200
    public static let askBlinkGapMs = 70
    public static let askBlinkPauseMs = 1030
    public static let doneGreen = "#00ff37"
    /// Done breathes, and that is the whole distinction now: "needs you" blinks
    /// twice and "finished" breathes, so the two are told apart by motion as
    /// well as colour. Deliberate — a finished turn is news you can read
    /// whenever, a question is not.
    ///
    /// One `pulse` is one whole breath, dark to full and back, so this number
    /// IS the breath rate: 4.5 s is about 13 a minute, a resting human one —
    /// the point of green is that nothing is wrong, and it should carry
    /// itself that way.
    public static let doneBreathSeconds = 4.5

    public static let batteryCriticalRed = "#ff0000"
    /// Slower still than done — 6 s, about 10 breaths a minute — keeping done
    /// the faster of the two breaths. It reads as heavy rather than urgent,
    /// which suits what it means: plug in soon, not right now.
    public static let batteryCriticalBreathSeconds = 6.0
    public static let batteryCriticalPercent = 15
    public static let batteryLowRed = "#ff0000"
    public static let batteryMidAmber = "#ff7000"
    public static let batteryHighGreen = "#00ff37"
    public static let batteryOff = "#000000"
    public static let batteryMidPercent = 50
    public static let batterySegmentTransitionMs = 360
    public static let glanceSeconds: TimeInterval = 7

    public static let rollingFadeMs = 160
    public static let rollingPulseMs = 760
    public static let rollingStaggerMs = 95
    public static let rollingStaggerDotMs = 260
    public static let defaultLedCount = 8

    /// How many LEDs, from the left, an alert borrows while running work
    /// keeps the rest: needs-you gets a wider zone than finished — amber
    /// is the state worth interrupting for.
    /// Tune here: 1–7 are meaningful on the 8-LED strip; the program
    /// builder always leaves at least one LED to the roll, so an oversized
    /// value degrades to ledCount − 1 rather than evicting the work.
    public static let alertZoneLedsNeedsYou = 3
    public static let alertZoneLedsFinished = 2

    /// `mysidepulse brightness cycle` without `--steps`: 25 % → 50 % → 75 % →
    /// 100 % → off, perceived (`BrightnessCurve`), the owner's choice.
    public static let brightnessCycleDefaultSteps = 4
    /// How close, in perceived percent, a step above the current brightness
    /// may be and still count as reached. One unit of the strip's 1…255 is
    /// about a percent to the eye around a third of full and more below it
    /// (27, 28 and 29 read 33 %, 33 % and 34 %), so a brightness can sit a
    /// percent under a step, and a press must then go past it rather than move
    /// invisibly.
    public static let brightnessCycleSlackPercent = 1
    /// The most steps `--steps` takes. The strip's dim end is coarse (its
    /// lowest value already reads 6 % at γ 2, 16 % at γ 3), so past a point
    /// the smallest steps land on the same value. Computed by walking every
    /// step count: all steps stay more than the slack apart up to 26 at γ 2,
    /// 20 at 2.2 and 11 at 3. Ten holds for any γ up to 3;
    /// `testTheMostStepsAreStillToldApart` fails if a new γ breaks it.
    public static let brightnessCycleMaxSteps = 10
    /// The Strip page's brightness slider moves in steps of this many
    /// perceived percent, 5 % to 100 %: twenty positions, each a change the eye
    /// can see. At the measured γ 2 steps stay told apart up to 26 of them
    /// (the walk behind `brightnessCycleMaxSteps`), so 5 % is the finest grid
    /// with no position that looks like its neighbour.
    public static let brightnessSliderStepPercent = 5
    /// The curve from a perceived brightness to the strip's `brightness N`
    /// (`BrightnessCurve`). Measured by the owner's eye on a white strip: a
    /// third of full looked like `brightness 30`, two thirds like 110, which
    /// fit γ 1.96. At 2.0 the curve gives 28 and 113, inside what an eye can
    /// place, and the steps read back as exactly 33 % and 67 %.
    public static let brightnessGamma = 2.0
    /// How long LED 0 lights white on a dark strip after a `brightness cycle`
    /// press, restarted by each press: the owner's choice, long enough to
    /// judge the brightness between presses.
    public static let brightnessPreviewSeconds: TimeInterval = 2
    /// Pure white, so the LED shows the brightness itself and nothing else.
    public static let brightnessPreviewWhite = "#ffffff"

    /// How long a Playground state or effect holds the strip before the engine
    /// hands it back. Long enough to watch a full cycle of the slowest effect,
    /// short enough that a forgotten preview cannot hide a real alert. The
    /// Playground's own hint says the number, so it lives here rather than in
    /// the sentence.
    public static let playgroundPreviewSeconds: TimeInterval = 30

    public static let doneVisibleSeconds: TimeInterval = 20 * 60
    public static let holdTTLSeconds: TimeInterval = 30 * 60
    public static let holdGraceSeconds: TimeInterval = 90
    /// How long a subagent may go quiet before it stops holding a finished
    /// turn. Membership in `liveAgents` has no reliable end event — Claude
    /// Code drops `SubagentStop` often enough that 27 of 28 helper-held Stops
    /// in the recorded journal never emptied — so it expires on silence
    /// rather than waiting for one.
    ///
    /// Sized from that journal: across every helper that DID get a matching
    /// SubagentStop, the longest quiet gap before it was 202.4 s. 240 s clears
    /// that with room, so no recorded live helper would have been dropped
    /// early. The cost of it being too short is a green strip while a helper
    /// still runs; too long wedges the strip on working, bounded at 30 min.
    public static let agentStaleSeconds: TimeInterval = 240
    public static let staleSeconds: TimeInterval = 2 * 3600

    /// How quiet the main agent must have been before an `idle_prompt` (or
    /// `agent_needs_input`) notification is believed to mean "the turn is
    /// over and its Stop was lost". Claude Code fires the nudge ~60 s after
    /// a turn goes quiet, so one arriving over fresher main activity is a
    /// glitch and is ignored. 50 s, not 60: journal timestamps are stamped at
    /// hook time and the nudge has arrived at 60.0 s dead in the recorded
    /// journal (median gap exactly 60 s), so the guard needs headroom below
    /// it, not above.
    public static let idleSignalMinQuietSeconds: TimeInterval = 50

    /// How long a `working` session must be silent — no events, no live
    /// helpers, no background shells — before the app consults Claude
    /// Code's own per-process registry (`<config>/sessions/<pid>.json`,
    /// status busy/idle) about it. Esc and Ctrl-C interrupt a turn without
    /// firing any hook at all (11 of 199 recorded prompts), and a Ctrl-C
    /// can even kill hook delivery for the whole session, so the registry
    /// is the only truthful signal left. 20 s is enough: the registry
    /// alone can only say "not running", but paired with the transcript
    /// tail (interrupt vs lost-Stop finish) the verdict is complete, so
    /// the gate only bounds read churn and covers stamp races.
    ///
    /// CPU sampling cannot serve here instead: an idle Claude with a
    /// statusline and MCP servers burns about 4 % of a core in bursts,
    /// indistinguishable from light work by any absolute threshold.
    public static let abandonQuietSeconds: TimeInterval = 20
    /// When the registry says idle but the transcript cannot say HOW the
    /// turn ended (no recorded path, unreadable file, nothing substantive
    /// in the tail), dark still happens — at this conservative distance.
    public static let abandonUndecidedDarkSeconds: TimeInterval = 90
    /// Re-read cadence for the registry while a session stays quiet, and
    /// therefore the detection latency on top of the gate. Also the cadence
    /// for re-checking open waits (question/permission/plan) for having
    /// been answered without any hook firing. Both reads are two small
    /// files; 15 s keeps a Ctrl-C's stale roll under ~35 s end to end.
    public static let abandonRecheckSeconds: TimeInterval = 15
    /// How long a session may report `busy` in Claude Code's registry with
    /// no hook event arriving before the log warns, once per session, that
    /// its hooks look dead.
    public static let hooksSilentWarnSeconds: TimeInterval = 300
    /// How long the front-tab probe may run before it is abandoned (the ack
    /// simply falls open to the app level for that pass), and how long one
    /// answer is trusted. The cache is what bounds subprocess volume: at
    /// most one osascript every cache period, on an activation of a
    /// scriptable terminal or on an input poll while an alert is displayed
    /// with that terminal frontmost. Two seconds keeps tab switches feeling
    /// immediate (the 500 ms input poll re-probes right after one) without a
    /// probe per poll.
    public static let ttyProbeTimeoutSeconds: TimeInterval = 0.5
    public static let ttyProbeCacheSeconds: TimeInterval = 2

    /// How much newer than the dialog's own start the registry's busy stamp
    /// must be to count as the ANSWER rather than the dialog opening.
    /// Evidence: approving a plan stamped busy at the exact
    /// tool_result moment, ten minutes after the dialog opened; whether
    /// opening one also stamps is unproven, so the margin keeps a stamp
    /// born with the dialog from reading as its answer. A real answer
    /// inside the margin is caught by the following hook events (when they
    /// fire) or the next recheck (they were within seconds in all recorded
    /// cases where hooks did fire).
    public static let dialogAnswerMinStampLeadSeconds: TimeInterval = 2

    public static let keepaliveSeconds: TimeInterval = 60
    /// How often to retry a control socket that would not bind, and a
    /// DiskArbitration session that would not open. Retrying instead of
    /// giving up once matters: a one-shot failure would cost the CLI, or
    /// every device, for the whole process.
    public static let controlRetrySeconds: TimeInterval = 30
    public static let deviceSessionRetrySeconds: TimeInterval = 30
    /// Reconciliation sweeps behind the push notifications that normally drive
    /// devices and power. Slow on purpose: they exist to catch a callback that
    /// never arrived, not to replace it.
    public static let deviceRescanSeconds: TimeInterval = 300
    public static let powerRefreshSeconds: TimeInterval = 300
    /// How long a keepalive touch may run before it is signalled, and again
    /// before the signal is escalated to SIGKILL.
    public static let keepaliveTouchTimeoutSeconds: TimeInterval = 5
    /// Touches per device that may be outstanding before keepalive holds off.
    /// Kept above one: a single touch wedged in uninterruptible I/O would
    /// stop the mount's keepalive for good.
    public static let keepaliveMaxOutstandingTouches = 3
    public static let journalSoftMaxBytes = 5 * 1024 * 1024
    public static let journalHardMaxBytes = 20 * 1024 * 1024
    public static let journalLineMaxBytes = 4096
    /// How much of a hook payload is retained for parsing. Stdin is
    /// still drained past this so Claude Code's write never blocks or breaks;
    /// the excess is discarded. Real payloads sit far below it — the cap
    /// exists so a pathological one cannot balloon the hook process.
    public static let hookStdinMaxBytes = 8 * 1024 * 1024
    public static let messageTailMaxChars = 500
    /// How long an alert must hold before it is allowed onto the strip. The
    /// strip keeps showing the outgoing state until then, so an alert that is
    /// over almost immediately never reaches the LEDs.
    ///
    /// Set to 1 s by preference, favouring a responsive strip over complete
    /// flash suppression. Note what that trades away: replaying 803 recorded
    /// events found the shortest real flash held 2.59 s, so this does NOT
    /// cover the case that prompted the feature — that one now shows green for
    /// about 1.6 s instead of 2.59 s. Raising this to 5 s would suppress it
    /// entirely, since recorded history has nothing between 2.59 s and 8.97 s.
    public static let alertSettleSeconds: TimeInterval = 1
    public static let inputPollSeconds: TimeInterval = 0.5
    public static let writeWatchdogSeconds: TimeInterval = 2

    /// How long quitting waits for the strip to go dark before giving up and
    /// exiting anyway. A healthy write is one open/write/close on a mounted
    /// volume, under a millisecond; a card that is dying never returns at all,
    /// so any wait here is either unnecessary or infinite. 1.5 s sits under
    /// `writeWatchdogSeconds`, which is what the app already treats as the
    /// point where a strip has stopped answering, and keeps a quit from
    /// looking like a hang.
    public static let quitBlackoutSeconds: TimeInterval = 1.5

    /// How long an alert must stand before it is worth a phone push. A newer
    /// alert on the same session pushes this forward. Combined with the 90 s
    /// hold grace, a Stop held by a background shell notifies ~105 s after it
    /// settles — deliberately, so nothing rings mid-build.
    /// 15 s favours pushes landing sooner over a longer cancel window for
    /// alerts answered mid-debounce.
    public static let notifyDebounceSeconds: TimeInterval = 15
    /// Below this many seconds of input idle the user is at the machine and
    /// can see the strip, so the phone stays quiet. 60 s favours detecting a
    /// departure sooner over the risk that sitting still for a minute —
    /// reading without touching anything — counts as having left.
    public static let notifyPresenceIdleSeconds: Double = 60
    /// While the user is present a due notification is DEFERRED, not dropped:
    /// each due deadline moves forward by this much until a tick finds them
    /// absent. Acknowledgement — focusing the hosting terminal — cancels the
    /// pending push outright, so deferral only ever delivers alerts that were
    /// never seen. Worst-case ping after leaving ≈ the 60 s idle threshold
    /// plus one recheck.
    public static let notifyDeferRecheckSeconds: TimeInterval = 30
    /// A deadline missed by more than this is stale — journal replay at app
    /// start, or a machine that slept through it — and is dropped, not fired.
    public static let notifyMaxLatenessSeconds: TimeInterval = 120
    public static let notifyTimeoutSeconds: TimeInterval = 5
    /// POSTs per alert, including the first. Small on purpose: a push that
    /// arrives long after the moment it described is worse than no push.
    public static let notifyMaxAttempts = 3
    public static let notifyRetryDelaySeconds: TimeInterval = 2
    public static let notifyServerDefault = "https://ntfy.sh"

    /// How long an update check waits for GitHub. Behind a press someone is
    /// looking at the button, so it is generous next to a push.
    public static let updateCheckTimeoutSeconds: TimeInterval = 15

    /// The check nobody asked for. The first comes a few seconds after launch,
    /// so a Mac that starts the app at login has found its network; then one a
    /// week after the last answer, the owner's figure. A check that could not
    /// reach GitHub is tried again at the first tick an hour or more later, so
    /// 60 to 90 minutes on. The app asks whether one is due on that tick, and
    /// at every wake, rather than arming one week-long timer that would sleep
    /// through its date with the Mac.
    public static let updateLaunchDelaySeconds: TimeInterval = 10
    public static let updateIntervalSeconds: TimeInterval = 7 * 24 * 3600
    public static let updateRetryDelaySeconds: TimeInterval = 3600
    public static let updateTickSeconds: TimeInterval = 1800

    /// Seconds after the click on Install and Relaunch at which an app that is
    /// still running stops the install helper and says it did not quit. One
    /// clock decides: the helper's own limit below is longer and only ever
    /// serves an app too hung to do that.
    public static let updateStallNoticeSeconds: TimeInterval = 20

    /// The install helper's three waits, in seconds: for the app to quit
    /// before it gives up untouched, for the new version to show among the
    /// running processes, and how long after that it is looked for once more.
    /// Measured with a stand-in app: 3 s from the quit to the new version seen
    /// running, the process showing within a second of `open`, so 30 and 15
    /// leave room for a slow quit and a cold launch.
    public static let updateQuitWaitSeconds = 30
    public static let updateLaunchWaitSeconds = 15
    public static let updateSettleSeconds = 2

    /// How long the outcome of an install is news. A line found later than
    /// that was left behind by an install nobody is waiting on any more, and
    /// opens no window.
    public static let updateResultShelfLifeSeconds: TimeInterval = 600

    /// A finished job stays lit for the same window as a Claude `.done`: both
    /// are unread notifications and both clear the same way.
    public static let jobVisibleSeconds: TimeInterval = doneVisibleSeconds
    /// A job whose owner never reported back. Separate from `staleSeconds`
    /// only so the two can be retuned apart.
    public static let jobStaleSeconds: TimeInterval = staleSeconds
    /// `mysidepulse run` is explicit, so it lights the strip at once. The shell
    /// hooks fire on every command, so they wait — short commands stay dark.
    public static let jobShowAfterDefaultSeconds: Double = 0
    public static let shellShowAfterDefaultSeconds: Double = 5

    /// After vetoing an eject, retry the mount on this period. The retries
    /// are dissented while the screen is locked and succeed after unlock, so
    /// this runs for as long as the machine stays locked.
    public static let ejectRemountRetrySeconds: TimeInterval = 5
}

extension K {
    /// How far back the Health page counts crash reports. A week covers the gap between two weekly update
    /// checks, and a crash older than that has either been fixed by a release or been seen again since.
    public static let healthCrashWindow: TimeInterval = 7 * 24 * 60 * 60

    /// The shortest time the Health page's overview reads *Checking* after Check Again. The doctor answers
    /// in a few milliseconds, and a mark that changes back before it can be seen reads as a button that did
    /// nothing; half a second is seen and does not keep anyone waiting.
    public static let healthMinimumBusy: TimeInterval = 0.5
}

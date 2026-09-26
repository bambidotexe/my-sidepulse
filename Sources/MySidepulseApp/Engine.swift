import Foundation
import MySidepulseCore
import MySidepulsePlatform

/// Owns all mutable state, strictly on the main queue. Every input — journal
/// events, timers, power, devices, focus, CLI — funnels into sync(), the one
/// path from state to LEDs.
final class Engine {
    private(set) var store = SessionStore()
    private(set) var jobs = JobStore()
    private(set) var power: PowerState?
    private(set) var display: DisplayState = .off
    var mode: LedMode {
        didSet {
            // Only the cycle's own steps keep the mode its off step replaced.
            if !cyclingMode { config.ledModeBeforeOff = nil }
            config.ledMode = mode.configValue
            config.save()
            sync()
        }
    }
    private var lastPlugged: Bool?
    private var glanceUntil: Date?
    /// The settings window's Playground borrowing the strip. Display-only: it
    /// replaces what is painted, never what the stores believe, so alerts,
    /// acknowledgements and notifications behave exactly as if it were not
    /// there. The TTL hands the strip back when a preview is forgotten.
    private var preview: (state: DisplayState, power: PowerState?)?
    private var previewUntil: Date?
    /// Until when a dark strip shows the brightness a `brightness cycle`
    /// press set, on LED 0. Paint-only, like the Playground preview.
    private var brightnessPreviewUntil: Date?
    /// Set while `cycleBrightness` changes the mode, so `mode`'s observer
    /// keeps `config.ledModeBeforeOff`.
    private var cyclingMode = false
    private var devices: [DeviceKey: LedDevice] = [:]
    /// What each strip plays: the program it is running (a loop, or a
    /// one-shot tail that carries an animation across a rewrite), since when,
    /// the loop to write when a tail ends and the state that loop shows, and
    /// the brightness it is all scaled to (`LedContinuation`). The texts are
    /// unscaled, the palette's true colours; what goes to the strip is
    /// `LedProgram.scaled` at the brightness. The handover is the loop's
    /// write, scheduled at the tail's end; a real change cancels it.
    private struct Painting {
        var playing: String
        var playingSince: Date
        var loop: String
        var state: DisplayState
        var brightness: Int
        var handover: DispatchWorkItem?
        var boundary: Date?
        /// The loop that went dark, and its timeline: `origin` is a moment the
        /// loop starts, so its phase at any time is the time since then modulo
        /// its length. Painted again within `K.resumeFromDarkSeconds` of
        /// `since`, the same animation resumes on that timeline.
        var dark: (loop: String, origin: Date, since: Date)?
    }
    private var paintings: [DeviceKey: Painting] = [:]
    private var config: AppConfig
    private let writer = LedWriter()
    private let keepalive = Keepalive()
    private let procWatcher = ProcessWatcher()
    private let attention = AttentionMonitor()
    private let tabProber = TerminalTabProber()
    private var tailer: JournalTailer?
    private var deadlineTimer: DispatchSourceTimer?
    private var replaying = false
    /// When the last journal event was seen, sessions or no sessions. The
    /// status "last event" line reads this rather than the live session set:
    /// a session that just ended must not turn the line into "none" — its
    /// stated purpose is "are hooks arriving at all".
    private var lastEventSeen: Date?
    /// Canary, once per process: sessions with no pid mean the kqueue
    /// watchers have nothing to watch and a killed session lingers.
    private var warnedMissingPid = false
    /// Once-per-session canaries for the quiet-turn registry check: a
    /// session whose Claude has no readable registry record cannot be
    /// rescued, and one that stays busy long after its hooks went silent
    /// has lost its hooks (both worth exactly one loud line).
    private var warnedNoRegistry: Set<String> = []
    private var warnedHooksSilent: Set<String> = []
    /// The same canary for an agent's own transcript: a quiet Codex
    /// session whose rollout, or a quiet Copilot session whose
    /// `events.jsonl`, cannot be read or holds no turn marker.
    private var warnedNoTranscript: Set<String> = []
    /// The agent-hosted shells already logged as ignored; one line per
    /// shell, the set kept small.
    private var agentShells: Set<Int32> = []
    /// While the journal replays, the agent each shell runs under, read once
    /// per shell: every line of that shell reads the same processes then.
    private var replayedShells: [Int32: AgentKind?] = [:]
    /// The Codex sessions with a question out to Codex's daemon, skipped by
    /// the periodic check until it is answered, and, after an answer that
    /// decided nothing, when each may be asked again: until then its rollout
    /// decides.
    private var askingDaemon: Set<String> = []
    private var daemonAskAgainAt: [String: Date] = [:]
    /// When each Codex session's rollout, and each Copilot session's
    /// `events.jsonl`, was last read: with no event of the session since, it
    /// is read again `K.abandonRecheckSeconds` later at the earliest, however
    /// often the journal delivers other lines (`SessionStore.sourceReadIsDue`).
    /// One map per agent's file; a Copilot session is never both working and
    /// waiting, so its two checks share one.
    private var rolloutCheckedAt: [String: Date] = [:]
    private var transcriptCheckedAt: [String: Date] = [:]
    /// Once per launch, and once per status value the daemon reports that
    /// the verdict does not know.
    private var warnedDaemonSilent = false
    private var warnedDaemonStatuses: Set<String> = []
    /// True until the launch checks have run: until then the daemon is asked
    /// only `thread/loaded/list`, and `thread/read` waits for the first live
    /// check.
    private var launching = true
    /// Notification delivery touches the filesystem (the sessions directory)
    /// and the network, neither of which belongs on the queue that owns the
    /// state and paints the strip.
    private let notifyQueue = DispatchQueue(label: "mysidepulse.notify", qos: .utility)
    var onStateChanged: (() -> Void)? // menu refresh

    init(config: AppConfig) {
        self.config = config
        self.mode = LedMode.parse(config.ledMode) ?? .auto
    }

    // MARK: startup

    func start() {
        procWatcher.onExit = { [weak self] pid in self?.handleProcessExit(pid) }
        // Delivered off the writer's state queue, so hopping to main here is
        // safe and keeps the device lookup on the queue that owns it.
        writer.onStall = { [weak self] key in
            DispatchQueue.main.async {
                let path = self?.devices[key]?.mountPath ?? "unknown"
                Log.app.error("device stalled, writes suspended: \(path, privacy: .public)")
            }
        }
        // notice, not info: the stall above is persisted, so its release has to
        // be too, or the log reads as a strip that never came back.
        writer.onRecover = { [weak self] key in
            DispatchQueue.main.async {
                guard let self else { return }
                let path = self.devices[key]?.mountPath ?? "unknown"
                Log.app.notice("device recovered, writes resumed: \(path, privacy: .public)")
                self.onStateChanged?()
            }
        }
        attention.start()
        attention.onActivity = { [weak self] bundle in self?.acknowledge(bundleId: bundle) }
        tabProber.onDenied = {
            Log.app.warning("""
                terminal automation denied: acknowledgement falls back to the whole \
                terminal app — every tab's alerts clear together. Allow MySidepulse under \
                System Settings > Privacy & Security > Automation to scope it to the \
                visible tab.
                """)
        }

        // Replay: rotated file first, then the tailer's synchronous drain of
        // the live journal. Same code path as live events.
        let bootCut = BootTime.bootDate() ?? .distantPast
        replaying = true
        for event in JournalTailer.readAll(url: Paths.journalRotated)
        where event.loggedAt >= bootCut {
            ingest(event)
        }
        let tailer = JournalTailer(url: Paths.journal)
        self.tailer = tailer
        // start() drains synchronously on the tailer queue; those events
        // arrive via this async hop, filtered by boot time while replaying.
        let cutoff = bootCut
        tailer.onEvents = { [weak self] events in
            DispatchQueue.main.async {
                guard let self else { return }
                let filtered = self.replaying ? events.filter { $0.loggedAt >= cutoff } : events
                self.handle(filtered)
            }
        }
        tailer.start()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Everything queued by the drain has now been applied.
            self.replaying = false
            self.replayedShells.removeAll()
            // Alive is not enough: a pid recycled while the app was down
            // must not keep a dead session's state on the strip. A Claude
            // session is kept only while the pid runs Claude and its
            // registry record, when there is one, names that session. A
            // Codex session's pid is a shared app-server (the managed daemon
            // for every TUI, the desktop app's own for its threads), which
            // proves nothing about the session: it is kept, and the launch
            // check below reads its rollout. A live `copilot` can hold
            // several sessions: each is kept, and read from its events.jsonl.
            self.store.pruneDead(isAlive: { agent, pid in
                guard kill(pid, 0) == 0 || errno == EPERM else { return false }
                if agent == .codex, let info = ProcWalk.info(for: pid), ProcWalk.isCodexDaemon(info) {
                    return true
                }
                return ProcWalk.looksLike(agent, pid: pid)
            }, registrySession: { pid, transcriptPath in
                ClaudeProcessRegistry.read(pid: pid, transcriptPath: transcriptPath)?.sessionId
            })
            // Replayed alerts must not push again: a deadline already long
            // past either fired in the previous instance or was abandoned
            // there. Without this, every `make install` under a standing
            // alert would re-deliver its push a minute later.
            self.store.dropStaleNotifications(now: Date())
            // The time rules first, so a session silent past the staleness
            // backstop is dropped rather than revived by a rollout that
            // still says its turn runs; then every working turn is checked
            // against the registry, its rollout or its events.jsonl before
            // the first paint, with no quiet gate: the hooks that could have
            // ended it fired while the app was away, or never.
            let now = Date()
            let alerts = self.store.tick(now: now, userPresent: AttentionMonitor.userIsPresent())
            self.jobs.tick(now: now)
            // Each replayed running job's shell is asked before the first
            // paint: its end may have been written while the app was away,
            // or lost with the shell.
            self.probeJobs(now: now)
            if !alerts.isEmpty { self.deliver(alerts) }
            // A working session Codex's daemon hosts, whose thread the daemon
            // no longer holds, has nothing running: the daemon is asked which
            // threads it holds (at most `CodexDaemonClient.deadlineSeconds`)
            // before the launch check and the first paint, which wait for it.
            let hosted = self.daemonHostedWorkingSessions()
            guard !hosted.isEmpty, CodexDaemonClient.socketExists() else { return self.finishLaunch(now: now) }
            CodexDaemonClient.loadedThreadIds { [weak self] loaded in
                guard let self, self.launching else { return }
                self.daemonListed(loaded, asked: hosted)
                self.finishLaunch(now: Date())
            }
            // The client answers within its deadline; this only bounds the
            // launch should it ever not.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2 * CodexDaemonClient.deadlineSeconds) { [weak self] in
                guard let self, self.launching else { return }
                self.noteDaemonSilent()
                self.finishLaunch(now: Date())
            }
        }
        keepalive.start { [weak self] in
            guard let self else { return [] }
            return DispatchQueue.main.sync { Array(self.devices.values) }
        }
    }

    /// The rest of the launch: every working turn checked against the
    /// registry, its rollout or its events.jsonl, with no quiet gate, then
    /// the first paint.
    private func finishLaunch(now: Date) {
        checkAbandonedTurns(now: now, quietSeconds: 0)
        launching = false
        armProcessWatchers()
        // Hooks append while the app is away and only the app rotates, so
        // a long absence needs this catch-up — otherwise the journal only
        // rotates once the next live event happens to arrive.
        rotateJournalIfNeeded()
        sync()
    }

    // MARK: inputs (all on main)

    func handle(_ events: [JournalEvent]) {
        guard !events.isEmpty else { return }
        for event in events { ingest(event) }
        // Ack and verdict lines are the app's own and job lines the
        // terminal's; "last event" answers "are hooks arriving", so only an
        // agent's hook traffic may refresh it.
        if let latest = events.filter({ ![.ack, .verdict, .jobBegin, .jobEnd].contains($0.event) })
            .map(\.loggedAt).max(),
           latest > (lastEventSeen ?? .distantPast) {
            lastEventSeen = latest
        }
        armProcessWatchers()
        rotateJournalIfNeeded()
        sync()
    }

    /// One journal line, live or replayed: a job's to the job store, every
    /// other to the session store. A begin from a shell under an agent is
    /// dropped there (`JobStore.apply`), and logged once per shell.
    private func ingest(_ event: JournalEvent) {
        switch jobs.apply(event, hostingAgent: { hostingAgent(ofShell: $0) }) {
        case .notAJobLine:
            store.apply(event)
        case .applied:
            break
        case .agentShell(let pid, let agent):
            if agentShells.count >= 64 { agentShells.removeAll() }
            if agentShells.insert(pid).inserted {
                Log.app.notice("""
                    job ignored: shell \(pid, privacy: .public) runs under \(agent.productName, privacy: .public) \
                    — its commands are that agent's work
                    """)
            }
        }
    }

    private func hostingAgent(ofShell pid: Int32) -> AgentKind? {
        if replaying, let known = replayedShells[pid] { return known }
        let agent = ProcWalk.hostingAgent(in: ProcWalk.chain(from: pid))
        if replaying { replayedShells[pid] = .some(agent) }
        return agent
    }

    /// A `mysidepulse run` wrapper appends its end line, then exits: the
    /// journal is read up to now first, so the line lands before the exit,
    /// which would clear a job still running and lose its outcome.
    private func handleProcessExit(_ pid: Int32) {
        guard let tailer else { return processExited(pid) }
        tailer.catchUp { [weak self] in DispatchQueue.main.async { self?.processExited(pid) } }
    }

    private func processExited(_ pid: Int32) {
        store.processExited(pid: pid)
        jobs.processExited(pid: pid)
        sync()
    }

    /// Every acknowledgement first asks the frontmost terminal which TAB is
    /// visible (async, cached, hard-timed-out), so seeing an alert only
    /// clears the session actually on screen, rather than every tab of the
    /// bundle at once. Any unknown answers nil and the ack falls open to the
    /// whole app.
    func acknowledge(bundleId: String) {
        tabProber.frontTTY(forBundleId: bundleId) { [weak self] tty in
            guard let self else { return }
            if self.acknowledgeAll(bundleId: bundleId, frontTTY: tty) { self.sync() }
        }
    }

    /// Both stores, always. Written as two statements on purpose: as
    /// `store.acknowledgeAlerts(…) || jobs.acknowledge(…)` Swift short-circuits
    /// and silently skips the job acknowledgement on any pass where a session
    /// alert was cleared — which is exactly the pass where both are lit.
    /// Jobs are acknowledged by host app only: they carry no tty.
    @discardableResult
    private func acknowledgeAll(bundleId: String, frontTTY: String?) -> Bool {
        let acked = store.acknowledgeAlerts(hostBundleId: bundleId, frontTTY: frontTTY,
                                            hostIsFocusable: AttentionMonitor.hostIsFocusable)
        let jobsSeen = jobs.acknowledge(hostBundleId: bundleId)
        persist(acks: acked, jobAcks: jobsSeen)
        return !acked.isEmpty || !jobsSeen.isEmpty
    }

    /// An acknowledgement is state the journal replay cannot reconstruct, so
    /// it goes INTO the journal: one `MySidepulseAck` line per cleared alert
    /// or job outcome, keyed by its stateSince. Without this every restart
    /// would forget what had been seen and resurrect both the amber and its
    /// push.
    private func persist(acks: [AckRecord], jobAcks: [JobAckRecord]) {
        let now = Date()
        for record in acks {
            var event = JournalEvent(loggedAt: now, event: .ack)
            event.sessionId = record.sessionId
            event.ackStateSince = record.stateSince
            if let line = try? Trim.cappedLine(event) {
                JournalWriter.append(line, to: Paths.journal)
            }
        }
        for record in jobAcks {
            if let line = try? Trim.cappedLine(JobLine.ack(record, loggedAt: now)) {
                JournalWriter.append(line, to: Paths.journal)
            }
        }
    }

    /// A verdict is state the journal replay cannot reconstruct either: it
    /// goes into the journal as one `MySidepulseVerdict` line, stamped when
    /// it took effect, so a relaunch replays the same verdict as of the same
    /// instant instead of the turn it ended. The tailer delivers the line
    /// back, where it changes nothing. Nil means there is no outcome to
    /// record: nothing changed, or a finish is held behind a helper.
    private func persist(_ verdict: TurnVerdict, sessionId: String, at stamp: Date?) {
        guard let stamp else { return }
        var event = JournalEvent(loggedAt: stamp, event: .verdict)
        event.sessionId = sessionId
        event.verdict = verdict.rawValue
        if let line = try? Trim.cappedLine(event) {
            JournalWriter.append(line, to: Paths.journal)
        }
    }

    /// The rescues' four verdicts, applied to the store and journaled.
    private func finishTurn(_ sessionId: String, now: Date, endedAt: Date?) {
        persist(.turnFinished, sessionId: sessionId,
                at: store.finishTurn(sessionId: sessionId, now: now, endedAt: endedAt))
    }

    private func abandonTurn(_ sessionId: String, now: Date, endedAt: Date?) {
        persist(.turnAbandoned, sessionId: sessionId,
                at: store.abandonTurn(sessionId: sessionId, now: now, endedAt: endedAt))
    }

    private func failTurn(_ sessionId: String, now: Date, endedAt: Date?) {
        persist(.turnFailed, sessionId: sessionId,
                at: store.failTurn(sessionId: sessionId, now: now, endedAt: endedAt))
    }

    private func dialogAnswered(_ sessionId: String, now: Date) {
        persist(.dialogAnswered, sessionId: sessionId,
                at: store.dialogAnswered(sessionId: sessionId, now: now))
    }

    func powerChanged(_ new: PowerState?) {
        if let old = lastPlugged, let plugged = new?.plugged, old != plugged {
            glanceUntil = Date().addingTimeInterval(K.glanceSeconds)
        }
        // Keep the last *known* value: resetting to nil on a failed read would
        // make the guard above skip the next genuine transition, swallowing
        // the glance the user actually asked for by moving the cord.
        if let plugged = new?.plugged { lastPlugged = plugged }
        power = new
        sync()
    }

    /// The menu checkbox. Turning it off is a real decision — it stops the
    /// crash restart too — so it is remembered, and a later launch will not
    /// quietly put it back.
    var autoRestartIsOn: Bool { LoginService.isEnabled }

    /// The engine owns the live config, so the wizard's last button comes through here rather than
    /// writing `config.json` beside it and losing whatever else has changed since it was loaded.
    func markOnboardingDone() {
        guard config.onboardingDone != true else { return }
        config.onboardingDone = true
        config.save()
    }

    func setAutoRestart(_ wanted: Bool) {
        do {
            if wanted { try LoginService.install() } else { try LoginService.remove() }
            config.autoRestartWanted = wanted
            config.save()
        } catch {
            Log.app.error("""
                launch agent \(wanted ? "registration" : "removal") failed: \
                \(String(describing: error), privacy: .public)
                """)
        }
        onStateChanged?()
    }

    func deviceAppeared(_ device: LedDevice) {
        // notice, not info: macOS only persists notice and above, and the
        // plug/unplug trail is exactly what gets read after the fact.
        Log.app.notice(
            "device appeared: \(device.mountPath, privacy: .public) leds=\(device.ledCount)")
        devices[device.key] = device
        writer.deviceAppeared(device)
        paintings[device.key]?.handover?.cancel()
        paintings.removeValue(forKey: device.key)
        sync()
    }

    func deviceGone(_ key: DeviceKey) {
        let path = devices[key]?.mountPath ?? "unknown"
        Log.app.notice("device disappeared: \(path, privacy: .public)")
        devices.removeValue(forKey: key)
        writer.deviceGone(key)
        paintings[key]?.handover?.cancel()
        paintings.removeValue(forKey: key)
        onStateChanged?()
    }

    /// Quitting turns every attached strip off. What the strip shows is only
    /// true while something is watching Claude Code, so a lit strip left
    /// behind by a quit is a colour that means nothing — and the one state
    /// nobody can read as "MySidepulse is not running" is any state at all.
    /// Bounded by `K.quitBlackoutSeconds`: the app exits either way.
    func blackoutForQuit() {
        // The dark program is the same for every strip: `.off` varies with
        // neither the LED count nor the brightness, which `ProgramTests` pins.
        let dark = LedProgram.program(for: .off, power: nil,
                                      ledCount: K.defaultLedCount, brightness: 255)
        let paths = devices.values.map(\.ledsFilePath)
        if !LedWriter.blackout(paths: paths, program: dark, timeout: K.quitBlackoutSeconds) {
            Log.app.notice("quit: not every strip went dark within \(K.quitBlackoutSeconds)s")
        }
    }

    // MARK: settings window

    /// Per-volume-name brightness, the settings window's Devices tab. The app
    /// is config.json's only writer, so routing the edit through here is what
    /// lets it apply live — sync() reads the map on every paint.
    var brightnessOverrides: [String: Int] { config.brightness }

    func setBrightness(_ value: Int?, forVolumeName name: String) {
        let key = name.lowercased()
        if let value {
            config.brightness[key] = max(1, min(255, value))
        } else {
            config.brightness.removeValue(forKey: key)
        }
        config.save()
        sync()
    }

    /// K's colours with the Colours page's overrides applied. `sync()` reads it
    /// on every paint, so a change reaches the strip on the next repaint.
    var palette: LedPalette { LedPalette.standard.applying(overrides: config.colors ?? [:]) }

    /// Nil puts the slot back to its default. The app is config.json's only
    /// writer, so routing the edit through here is what lets it apply live.
    func setColor(_ hex: String?, for slot: LedPalette.Slot) {
        let colors = LedPalette.overrides(config.colors ?? [:], setting: slot, to: hex)
        config.colors = colors.isEmpty ? nil : colors
        config.save()
        sync()
    }

    func resetColors() {
        config.colors = nil
        config.save()
        sync()
    }

    /// One press of `mysidepulse brightness cycle`, resolved here because only
    /// the app knows the mode and the strips. Every plugged-in strip moves to
    /// the same step, taken from the brightest of them; the step past the last
    /// one is the mode `off`, and the press after it brings back the mode that
    /// step replaced.
    private func cycleBrightness(steps: Int) -> ControlResponse {
        guard (1...K.brightnessCycleMaxSteps).contains(steps) else {
            return ControlResponse(ok: false,
                                   error: "bad steps \(steps): use 1 to \(K.brightnessCycleMaxSteps)")
        }
        let names = devices.values.map(\.name)
        guard !names.isEmpty else {
            return ControlResponse(ok: false, error: "no SidePulse strip is plugged in")
        }
        let brightest = names.map(config.brightness(forVolumeName:)).max() ?? 255
        switch BrightnessCycle.next(after: brightest, modeIsOff: mode == .off, steps: steps) {
        case .off:
            brightnessPreviewUntil = nil
            config.ledModeBeforeOff = mode.configValue
            cyclingMode = true
            mode = .off // saves and repaints
            cyclingMode = false
            return ControlResponse(ok: true, mode: mode.configValue)
        case .level(let level):
            // Set before the repaint below, so its first paint carries the white.
            brightnessPreviewUntil = Date().addingTimeInterval(K.brightnessPreviewSeconds)
            for name in names {
                // 255 is the default: store nothing, as the Strip page does.
                if level == 255 {
                    config.brightness.removeValue(forKey: name.lowercased())
                } else {
                    config.brightness[name.lowercased()] = level
                }
            }
            config.save()
            if mode == .off {
                let restored = BrightnessCycle.modeAfterOff(saved: config.ledModeBeforeOff)
                config.ledModeBeforeOff = nil
                cyclingMode = true
                mode = restored // saves and repaints
                cyclingMode = false
            } else {
                sync()
            }
            return ControlResponse(ok: true, mode: mode.configValue,
                                   brightnessPercent: BrightnessCycle.percent(level))
        }
    }

    /// Start (or, with nil, stop) a Playground preview. Passing a state again
    /// restarts its TTL. `power` is only read by the battery-glance program.
    func setPreview(_ state: DisplayState?, power: PowerState? = nil) {
        if let state {
            preview = (state, power)
            previewUntil = Date().addingTimeInterval(K.playgroundPreviewSeconds)
        } else {
            preview = nil
            previewUntil = nil
        }
        sync()
    }

    var previewRemainingSeconds: TimeInterval? {
        guard preview != nil, let until = previewUntil else { return nil }
        let left = until.timeIntervalSince(Date())
        return left > 0 ? left : nil
    }

    private func activePreview(now: Date) -> (state: DisplayState, power: PowerState?)? {
        guard let current = preview, let until = previewUntil else { return nil }
        guard until > now else {
            preview = nil
            previewUntil = nil
            return nil
        }
        return current
    }

    // MARK: the single sync path

    func sync() {
        // Nothing is ticked, pushed or painted before the launch checks have
        // run (`finishLaunch`): the replayed state is not yet what to show.
        guard !launching else { return }
        let now = Date()
        var alerts = store.tick(now: now, userPresent: AttentionMonitor.userIsPresent())
        jobs.tick(now: now)
        probeJobs(now: now)
        // A rescued finish is dated to the turn's real end, so its push can
        // already be due: tick once more, since `nextDeadline` only wakes
        // for deadlines still ahead.
        if checkAbandonedTurns(now: now) {
            alerts += store.tick(now: now, userPresent: AttentionMonitor.userIsPresent())
        }
        if !alerts.isEmpty { deliver(alerts) }
        let glanceActive = glanceUntil.map { $0 > now } ?? false
        var decision = Arbiter.decide(mode: mode, power: power, glanceActive: glanceActive,
                                      sessions: Array(store.sessions.values),
                                      jobs: jobs.displayable, now: now)
        // Pre-paint acknowledgement: an alert born while its host is focused
        // and the user is actively typing must not flash before the first
        // poll. Asynchronous since the front TAB has to be asked first; the
        // 1 s settle absorbs the probe's latency (≤ 0.5 s), so a
        // born-focused alert still never reaches the strip — the ack's own
        // sync() repaints inside the settle window.
        if decision.isAlertable,
           let bundle = AttentionMonitor.frontmostBundleId(),
           AttentionMonitor.inputIdleSeconds() < K.inputPollSeconds {
            acknowledge(bundleId: bundle)
        }
        // The Playground override replaces the painted state only, after the
        // real decision is fully settled: acknowledgement above and the ack
        // polling below both follow the real decision, so a previewed amber
        // cannot arm input polling and a previewed off cannot disarm it.
        let real = decision
        var paintPower = power
        if let preview = activePreview(now: now) {
            decision = preview.state
            paintPower = preview.power ?? power
        }
        display = decision
        if let until = brightnessPreviewUntil, until <= now || mode == .off {
            brightnessPreviewUntil = nil
        }
        let showsWhite = BrightnessCycle.previewShows(mode: mode, painted: decision,
                                                     until: brightnessPreviewUntil, now: now)
        for device in devices.values {
            let brightness = config.brightness(forVolumeName: device.name)
            // Unscaled: the brightness is applied on the way out, by `paint`.
            let program = showsWhite
                ? LedProgram.brightnessPreview(ledCount: device.ledCount, brightness: 255)
                : LedProgram.program(for: decision, power: paintPower, ledCount: device.ledCount,
                                     brightness: 255, palette: palette)
            paint(program, showing: decision, brightness: brightness, on: device, now: now)
        }
        attention.setPolling(real.isAlertable)
        scheduleNextDeadline(now: now)
        onStateChanged?()
    }

    /// One strip's write. An animation that carries on is not restarted: the
    /// same animation at another brightness gets the rest of what it is
    /// playing at the new brightness, a full-strip roll that changes colour
    /// gets the rest of its pass and the new loop at the boundary, a roll
    /// that continues under a zone that opens, closes or changes gets the
    /// transition tail, and the same animation painted again within
    /// `K.resumeFromDarkSeconds` of going dark resumes where it would have
    /// been; the loop itself is written when the tail ends. A brightness tail ends at the loop's own boundary, so a
    /// second change during it cuts the tail again and keeps that boundary.
    /// Anything else is written at once. `program` is unscaled.
    private func paint(_ program: String, showing state: DisplayState, brightness: Int,
                       on device: LedDevice, now: Date) {
        let key = device.key
        if let current = paintings[key] {
            if current.loop == program, current.brightness == brightness {
                // A pending handover writes it; otherwise the writer's dedupe
                // makes this free, and a write that failed is tried again.
                if current.handover == nil {
                    writer.write(program: LedProgram.scaled(program, brightness: brightness), to: device)
                }
                return
            }
            let elapsed = Int(now.timeIntervalSince(current.playingSince) * 1000)
            let ledCount = device.ledCount
            if current.playing == "off", let dark = current.dark,
               now.timeIntervalSince(dark.since) <= K.resumeFromDarkSeconds,
               dark.loop == program, let loopMs = LedContinuation.loopMs(of: dark.loop) {
                let sinceOrigin = Int(now.timeIntervalSince(dark.origin) * 1000)
                let phase = ((sinceOrigin % loopMs) + loopMs) % loopMs
                if let tail = LedContinuation.tail(of: dark.loop, elapsedMs: phase, brightness: brightness,
                                                   fromDark: true) {
                    carryOn(key, device: device, tail: tail, loop: program, state: state,
                            brightness: brightness, now: now,
                            boundary: now.addingTimeInterval(Double(tail.lengthMs) / 1000))
                    return
                }
            }
            // The same loop at another brightness, or the full-strip roll
            // changing colour (an agent's pass joining or leaving the shared
            // roll): the rest of what plays, then the loop at its own boundary.
            if current.loop == program || LedProgram.rollRecolour(from: current.state, to: state),
               let tail = LedContinuation.tail(of: current.playing, elapsedMs: elapsed, brightness: brightness) {
                // The tail says when it ends: the loop's own boundary, or
                // the current pass's on the roll every agent shares. A cut of
                // a tail already playing keeps the boundary it was given.
                let boundary: Date
                if let pending = current.boundary, current.handover != nil {
                    boundary = pending
                } else {
                    boundary = now.addingTimeInterval(Double(tail.lengthMs) / 1000)
                }
                carryOn(key, device: device, tail: tail, loop: program, state: state,
                        brightness: brightness, now: now, boundary: boundary)
                return
            }
            if let roll = LedProgram.rollHandover(from: current.state, to: state, ledCount: ledCount,
                                                  palette: palette),
               let tail = LedContinuation.transition(
                   from: current.playing, to: program, elapsedMs: elapsed, ledCount: ledCount,
                   zoneBefore: roll.zoneBefore, zoneAfter: roll.zoneAfter, opening: roll.opening,
                   brightness: brightness) {
                carryOn(key, device: device, tail: tail, loop: program, state: state,
                        brightness: brightness, now: now,
                        boundary: now.addingTimeInterval(Double(tail.lengthMs) / 1000))
                return
            }
            current.handover?.cancel()
        }
        writer.write(program: LedProgram.scaled(program, brightness: brightness), to: device)
        // Going dark keeps the loop's timeline for a moment, so that coming
        // back at once finds the animation where it would have been.
        var dark: (loop: String, origin: Date, since: Date)?
        if program == "off", let current = paintings[key], LedContinuation.loopMs(of: current.loop) != nil {
            dark = (current.loop, current.boundary ?? current.playingSince, now)
        }
        paintings[key] = Painting(playing: program, playingSince: now, loop: program, state: state,
                                  brightness: brightness, handover: nil, boundary: nil, dark: dark)
    }

    private func carryOn(_ key: DeviceKey, device: LedDevice, tail: LedContinuation.Tail, loop: String,
                         state: DisplayState, brightness: Int, now: Date, boundary: Date) {
        paintings[key]?.handover?.cancel()
        writer.write(program: tail.program, to: device)
        let work = DispatchWorkItem { [weak self] in self?.handOver(key) }
        paintings[key] = Painting(playing: tail.unscaled, playingSince: now, loop: loop, state: state,
                                  brightness: brightness, handover: work, boundary: boundary, dark: nil)
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + max(0, boundary.timeIntervalSince(now)),
                                      execute: work)
    }

    /// The tail has ended: the loop starts here, on its own timeline.
    private func handOver(_ key: DeviceKey) {
        guard let device = devices[key], var current = paintings[key] else { return }
        current.handover = nil
        current.boundary = nil
        current.playing = current.loop
        current.playingSince = Date()
        paintings[key] = current
        writer.write(program: LedProgram.scaled(current.loop, brightness: current.brightness), to: device)
    }

    /// The quiet-turn check. Esc and Ctrl-C interrupt a turn without firing
    /// any hook (11 of 199 recorded prompts) — and a Ctrl-C can kill hook
    /// delivery for the whole session while its turn keeps running. So a
    /// `working` session that has gone silent is asked about at the source:
    /// Claude Code's own per-process registry record, which does not travel
    /// through hooks (`ClaudeQuietTurn` decides).
    /// "idle", stamped after our last main-agent event → the turn is over,
    /// at once; the transcript only says how: a completed answer is the lost
    /// `Stop` (green, push), anything else, an unreadable transcript
    /// included, is dark. "busy" → genuinely still working (silent thinking,
    /// or dead hooks) → stay on the roll and keep the session alive.
    /// Anything else — no record, wrong session, stale stamp, unknown
    /// status — proves nothing and changes nothing.
    /// A quiet Codex turn is asked about at Codex's daemon or read from its
    /// rollout instead (`checkCodexTurns`), and a quiet Copilot turn is read
    /// from its `events.jsonl` (`checkCopilotTurns`). `quietSeconds` is the quiet
    /// gate: 0 for the launch check. A verdict is dated to when the source
    /// says the turn ended (`SessionStore.rescueStamp`). Returns whether any
    /// turn ended synchronously; the daemon's answers arrive later.
    @discardableResult
    private func checkAbandonedTurns(now: Date, quietSeconds: TimeInterval = K.abandonQuietSeconds) -> Bool {
        var ended = false
        for (sessionId, pid) in store.abandonCandidates(at: now, quietSeconds: quietSeconds) {
            guard let session = store.sessions[sessionId] else { continue }
            guard let record = ClaudeProcessRegistry.read(pid: pid, transcriptPath: session.transcriptPath),
                  record.sessionId == sessionId else {
                if warnedNoRegistry.insert(sessionId).inserted {
                    Log.app.warning("""
                        quiet turn undecidable: session \(sessionId, privacy: .public) — \
                        no registry record for claude pid \(pid); only the 2 h staleness \
                        backstop can end it now
                        """)
                }
                continue
            }
            // The transcript is read only once the record has ended the turn,
            // and what it said is kept for the log line.
            var ending: ClaudeQuietTurn.Ending?
            let decision = ClaudeQuietTurn.decision(
                status: record.status, statusUpdatedAt: record.statusUpdatedAt,
                lastMainEventAt: session.lastMainEventAt) {
                    let read = session.transcriptPath.map(TranscriptTail.verdict(atPath:)) ?? .unreadable
                    ending = read
                    return read
                }
            switch decision {
            case .finished(let stamped):
                Log.app.notice("""
                    lost Stop recovered: session \(sessionId, privacy: .public) — claude \
                    pid \(pid) reports idle and the transcript ends on a completed \
                    answer — finished
                    """)
                finishTurn(sessionId, now: now, endedAt: stamped)
                ended = true
            case .abandoned(let stamped):
                if ending == .unreadable {
                    Log.app.notice("""
                        turn abandoned: session \(sessionId, privacy: .public) — claude \
                        pid \(pid) reports idle since \(stamped, privacy: .public) and the \
                        transcript is unreadable — going dark
                        """)
                } else {
                    Log.app.notice("""
                        turn abandoned: session \(sessionId, privacy: .public) — claude pid \
                        \(pid) reports idle since \(stamped, privacy: .public) with no \
                        completed answer in the transcript — going dark
                        """)
                }
                abandonTurn(sessionId, now: now, endedAt: stamped)
                ended = true
            case .busy:
                // lastMainEventAt is NOT refreshed by this, so it keeps
                // measuring true hook silence while liveness is extended.
                if now.timeIntervalSince(session.lastMainEventAt) >= K.hooksSilentWarnSeconds,
                   warnedHooksSilent.insert(sessionId).inserted {
                    Log.app.warning("""
                        hooks look dead for session \(sessionId, privacy: .public): claude \
                        pid \(pid) reports busy but no hook event has arrived for over five \
                        minutes — its finishes and questions cannot be shown until the \
                        session restarts
                        """)
                }
                store.noteBusy(sessionId: sessionId, now: now)
            case .nothing:
                break
            }
        }
        // The answered dialog: approving a plan can fire no hook at all, so
        // the wait would otherwise stand until the next tool call drifted
        // in — unbounded in principle. The approval DOES re-stamp the
        // registry busy, so a wait whose stamp is newer than the wait
        // itself has been answered — back on the work. A failed turn's
        // wait too: busy after it is the agent at work.
        for (sessionId, pid, stateSince) in store.openWaitCandidates() {
            guard let record = ClaudeProcessRegistry.read(pid: pid,
                                                          transcriptPath: store.sessions[sessionId]?.transcriptPath),
                  record.sessionId == sessionId,
                  record.isBusy,
                  let stamped = record.statusUpdatedAt,
                  stamped.timeIntervalSince(stateSince) > K.dialogAnswerMinStampLeadSeconds
            else { continue }
            Log.app.notice("""
                dialog answered without a hook: session \(sessionId, privacy: .public) — \
                claude pid \(pid) went busy at \(stamped, privacy: .public), after the \
                dialog opened — back to working
                """)
            dialogAnswered(sessionId, now: now)
        }
        // Both run, whatever the other found: no short-circuit.
        let codexEnded = checkCodexTurns(now: now, quietSeconds: quietSeconds)
        let copilotEnded = checkCopilotTurns(now: now, quietSeconds: quietSeconds)
        return ended || codexEnded || copilotEnded
    }

    /// Codex has no registry. A quiet session that Codex's managed daemon
    /// hosts is asked about there first (`thread/read`), from the first live
    /// check on; its answer arrives later, on main (`daemonAnswered`). Every
    /// other session, one the daemon could not decide, and every session
    /// while the daemon is down or the launch checks run, is read from its
    /// rollout (`checkCodexRollout`); live, a rollout read with no event of
    /// the session since is read again 15 s later at the earliest.
    private func checkCodexTurns(now: Date, quietSeconds: TimeInterval) -> Bool {
        let candidates = store.codexCandidates(at: now, quietSeconds: quietSeconds)
        daemonAskAgainAt = daemonAskAgainAt.filter { store.sessions[$0.key] != nil }
        rolloutCheckedAt = rolloutCheckedAt.filter { store.sessions[$0.key] != nil }
        guard !candidates.isEmpty else { return false }
        let daemonUp = !launching && CodexDaemonClient.socketExists()
        var ended = false
        for (sessionId, recorded) in candidates where !askingDaemon.contains(sessionId) {
            guard let session = store.sessions[sessionId] else { continue }
            if daemonUp, isHostedByDaemon(session), daemonAskAgainAt[sessionId].map({ now >= $0 }) ?? true {
                askDaemon(sessionId: sessionId, asked: session.lastMainEventAt)
                continue
            }
            if !launching, !SessionStore.sourceReadIsDue(session, checkedAt: rolloutCheckedAt[sessionId], now: now) {
                continue
            }
            ended = checkCodexRollout(sessionId: sessionId, recorded: recorded, now: now) || ended
        }
        return ended
    }

    /// Codex's rollout records every turn's start and end.
    /// `CodexRolloutTail` decides; this only reads the file (the recorded
    /// path when Core trusts it, else the one found by session id), maps the
    /// decision onto the store and logs identifiers, never a line of the
    /// file.
    private func checkCodexRollout(sessionId: String, recorded: String?, now: Date) -> Bool {
        guard let session = store.sessions[sessionId] else { return false }
        rolloutCheckedAt[sessionId] = now
        let verdict = rolloutVerdict(sessionId: sessionId, recorded: recorded)
        var ended = false
        switch CodexRolloutTail.decision(verdict: verdict, lastMainEventAt: session.lastMainEventAt,
                                         lastMainTurnId: session.lastMainTurnId) {
        case .finished(let endedAt):
            Log.app.notice("""
                lost Stop recovered: Codex session \(sessionId, privacy: .public) — rollout \
                ends on task_complete at \(endedAt, privacy: .public) — finished
                """)
            finishTurn(sessionId, now: now, endedAt: endedAt)
            ended = true
        case .aborted(let endedAt):
            Log.app.notice("""
                turn abandoned: Codex session \(sessionId, privacy: .public) — rollout ends \
                on turn_aborted at \(endedAt, privacy: .public) — going dark
                """)
            abandonTurn(sessionId, now: now, endedAt: endedAt)
            ended = true
        case .busy:
            if now.timeIntervalSince(session.lastMainEventAt) >= K.hooksSilentWarnSeconds,
               warnedHooksSilent.insert(sessionId).inserted {
                Log.app.warning("""
                    hooks look dead for Codex session \(sessionId, privacy: .public): its \
                    rollout says the turn runs but no hook event has arrived for over five \
                    minutes — its finishes and questions cannot be shown until the hooks \
                    run again
                    """)
            }
            // Alive as of the rollout's last line: a turn that died with
            // no end marker stops writing, and still meets the 2 h
            // backstop that long after it.
            var writtenAt = now
            if case .running(_, let at) = verdict { writtenAt = min(at, now) }
            store.noteBusy(sessionId: sessionId, now: writtenAt)
        case .nothing:
            if verdict == .unreadable, warnedNoTranscript.insert(sessionId).inserted {
                Log.app.warning("""
                    quiet Codex turn undecidable: session \(sessionId, privacy: .public) — \
                    its rollout cannot be read or holds no turn marker; it stands until \
                    the rollout says more, a hook arrives, or the 2 h staleness backstop
                    """)
            }
        }
        return ended
    }

    /// The rollout's verdict on a Codex session: the recorded path when Core
    /// trusts it, else the daemon's when Core trusts that, else the one found
    /// by session id.
    private func rolloutVerdict(sessionId: String, recorded: String?, daemonPath: String? = nil) -> CodexRolloutTail.Verdict {
        let trusted = [recorded, daemonPath].compactMap { $0 }.first {
            CodexRolloutTail.isTrusted(path: $0, sessionId: sessionId, codexHome: Paths.codexHome.path)
        }
        return CodexRollout.path(recorded: trusted ?? recorded, sessionId: sessionId, codexHome: Paths.codexHome)
            .flatMap(CodexRollout.read(path:))
            .map(CodexRolloutTail.verdict(tail:)) ?? .unreadable
    }

    // MARK: Copilot's events.jsonl

    /// Copilot has no registry and no daemon, and fires no hook for Ctrl+C,
    /// Esc Esc, a failed turn or an answered prompt. Every quiet working
    /// Copilot session, and every one waiting on a permission or a question,
    /// is read from its `events.jsonl`: `CopilotTranscriptTail` decides;
    /// this only reads the file (the recorded path when Core trusts it, else
    /// the session's own under `~/.copilot/session-state`), maps the decision
    /// onto the store and logs identifiers, never a line of the file. Live,
    /// a file read with no event of the session since is read again 15 s
    /// later at the earliest.
    private func checkCopilotTurns(now: Date, quietSeconds: TimeInterval) -> Bool {
        var ended = false
        transcriptCheckedAt = transcriptCheckedAt.filter { store.sessions[$0.key] != nil }
        for (sessionId, recorded) in store.copilotCandidates(at: now, quietSeconds: quietSeconds) {
            guard let session = store.sessions[sessionId] else { continue }
            if !launching, !SessionStore.sourceReadIsDue(session, checkedAt: transcriptCheckedAt[sessionId], now: now) {
                continue
            }
            transcriptCheckedAt[sessionId] = now
            let verdict = CopilotTranscript.verdict(sessionId: sessionId, recorded: recorded,
                                                    root: Paths.copilotSessionState)
            switch CopilotTranscriptTail.decision(verdict: verdict, lastMainEventAt: session.lastMainEventAt) {
            case .finished(let endedAt):
                Log.app.notice("""
                    lost Stop recovered: Copilot session \(sessionId, privacy: .public) — events.jsonl \
                    ends on its agentStop at \(endedAt, privacy: .public) — finished
                    """)
                finishTurn(sessionId, now: now, endedAt: endedAt)
                ended = true
            case .aborted(let endedAt):
                Log.app.notice("""
                    turn abandoned: Copilot session \(sessionId, privacy: .public) — events.jsonl \
                    ends on abort at \(endedAt, privacy: .public) — going dark
                    """)
                abandonTurn(sessionId, now: now, endedAt: endedAt)
                ended = true
            case .failed(let endedAt):
                Log.app.notice("""
                    turn failed: Copilot session \(sessionId, privacy: .public) — events.jsonl \
                    ends on session.error at \(endedAt, privacy: .public) — needs you
                    """)
                failTurn(sessionId, now: now, endedAt: endedAt)
                ended = true
            case .closed(let endedAt):
                Log.app.notice("""
                    turn abandoned: Copilot session \(sessionId, privacy: .public) — events.jsonl \
                    ends on session.shutdown at \(endedAt, privacy: .public) — going dark
                    """)
                abandonTurn(sessionId, now: now, endedAt: endedAt)
                ended = true
            case .busy:
                if now.timeIntervalSince(session.lastMainEventAt) >= K.hooksSilentWarnSeconds,
                   warnedHooksSilent.insert(sessionId).inserted {
                    Log.app.warning("""
                        hooks look dead for Copilot session \(sessionId, privacy: .public): its \
                        events.jsonl says the turn runs but no hook event has arrived for over five \
                        minutes — its finishes and questions cannot be shown until the hooks \
                        run again
                        """)
                }
                // Alive as of the file's last line: a turn that died with
                // no end marker stops writing, and still meets the 2 h
                // backstop that long after it.
                var writtenAt = now
                if case .running(let at) = verdict { writtenAt = min(at, now) }
                store.noteBusy(sessionId: sessionId, now: writtenAt)
            case .nothing:
                if verdict == .unreadable, warnedNoTranscript.insert(sessionId).inserted {
                    Log.app.warning("""
                        quiet Copilot turn undecidable: session \(sessionId, privacy: .public) — \
                        its events.jsonl cannot be read or holds no turn marker; it stands until \
                        the file says more, a hook arrives, or the 2 h staleness backstop
                        """)
                }
            }
        }
        // A permission prompt fires no hook when it is answered, nor when
        // Ctrl+C or Esc Esc cancels it: the file says which
        // (`CopilotTranscriptTail.waitDecision`). An `abort` stamped after
        // the wait began ends the turn; with the turn at work, a latest
        // permission line that is `permission.completed`, stamped after it,
        // is the answer, and the session is back to working; anything else
        // leaves the wait standing.
        for (sessionId, recorded, waitSince) in store.copilotWaitCandidates() {
            guard let session = store.sessions[sessionId] else { continue }
            if !launching, !SessionStore.sourceReadIsDue(session, checkedAt: transcriptCheckedAt[sessionId], now: now) {
                continue
            }
            transcriptCheckedAt[sessionId] = now
            let tail = CopilotTranscript.tail(sessionId: sessionId, recorded: recorded,
                                              root: Paths.copilotSessionState)
            switch tail.map({ CopilotTranscriptTail.waitDecision(tail: $0, sessionId: sessionId, waitSince: waitSince) })
                ?? .nothing {
            case .aborted(let endedAt):
                Log.app.notice("""
                    turn abandoned: Copilot session \(sessionId, privacy: .public) — events.jsonl \
                    ends on abort at \(endedAt, privacy: .public), during its wait — going dark
                    """)
                persist(.turnAbandoned, sessionId: sessionId,
                        at: store.abandonWait(sessionId: sessionId, now: now, endedAt: endedAt))
                ended = true
            case .answered(let at):
                Log.app.notice("""
                    wait answered: Copilot session \(sessionId, privacy: .public) — events.jsonl \
                    shows the prompt answered at \(at, privacy: .public) — back to working
                    """)
                dialogAnswered(sessionId, now: now)
            case .nothing:
                guard !warnedNoTranscript.contains(sessionId),
                      (tail.map { CopilotTranscriptTail.verdict(tail: $0, sessionId: sessionId) } ?? .unreadable)
                        == .unreadable else { continue }
                warnedNoTranscript.insert(sessionId)
                Log.app.warning("""
                    quiet Copilot wait undecidable: session \(sessionId, privacy: .public) — its \
                    events.jsonl cannot be read or holds no turn marker; the wait stands until a \
                    hook arrives or the 2 h staleness backstop
                    """)
            }
        }
        return ended
    }

    // MARK: Codex's daemon

    /// Only a session whose recorded pid is Codex's managed daemon is asked
    /// about at its socket: a `codex exec` thread runs in its own process and
    /// a desktop-app thread in the app's own app-server, and the daemon,
    /// which reads any thread from disk, would call either `notLoaded` while
    /// it works.
    private func isHostedByDaemon(_ session: Session) -> Bool {
        guard session.agent == .codex, let pid = session.agentPid, let info = ProcWalk.info(for: pid) else { return false }
        return ProcWalk.isManagedCodexDaemon(info)
    }

    /// The working Codex sessions the daemon hosts, each with its last
    /// main-agent event; a held `Stop` is the time rules'.
    private func daemonHostedWorkingSessions() -> [String: Date] {
        var hosted: [String: Date] = [:]
        for s in store.sessions.values where s.state == .working && !s.pendingDone && isHostedByDaemon(s) {
            hosted[s.id] = s.lastMainEventAt
        }
        return hosted
    }

    private func askDaemon(sessionId: String, asked: Date) {
        askingDaemon.insert(sessionId)
        CodexDaemonClient.readThread(id: sessionId) { [weak self] record in
            self?.daemonAnswered(sessionId: sessionId, record: record, asked: asked)
        }
    }

    /// The daemon's answer about a session, applied only while the session is
    /// still the one asked about: working, no `Stop` held, and no main-agent
    /// event since the question.
    private func daemonAnswered(sessionId: String, record: CodexThreadRecord?, asked: Date) {
        askingDaemon.remove(sessionId)
        guard let session = store.sessions[sessionId], session.state == .working, !session.pendingDone,
              session.lastMainEventAt == asked else { return }
        let now = Date()
        if record == nil { noteDaemonSilent() }
        switch record?.verdict() ?? .undecided {
        case .over:
            Log.app.notice("Codex daemon says thread \(sessionId, privacy: .public) has nothing running")
            endByRollout(sessionId: sessionId, daemonPath: record?.rolloutPath, fallbackEnd: record?.updatedAt, now: now)
        case .busy:
            if now.timeIntervalSince(session.lastMainEventAt) >= K.hooksSilentWarnSeconds,
               warnedHooksSilent.insert(sessionId).inserted {
                Log.app.warning("""
                    hooks look dead for Codex session \(sessionId, privacy: .public): Codex's \
                    daemon says the thread is active but no hook event has arrived for over \
                    five minutes — its finishes and questions cannot be shown until the hooks \
                    run again
                    """)
            }
            store.noteBusy(sessionId: sessionId, now: now)
        case .undecided:
            if let status = record?.status, warnedDaemonStatuses.insert(status).inserted {
                // The daemon's words, not ours: letters and digits only, and
                // short, before they reach the log.
                let shown = String(String.UnicodeScalarView(
                    status.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.prefix(40)))
                Log.app.notice("Codex daemon reports an unknown thread status \(shown, privacy: .public); using the rollout")
            }
            // The rollout decides this session until then, from the sync below.
            daemonAskAgainAt[sessionId] = now.addingTimeInterval(K.abandonRecheckSeconds)
        }
        sync()
    }

    /// At launch: a working session the daemon hosts, whose thread it does
    /// not hold in memory, has nothing running. A nil answer leaves every
    /// session to its rollout.
    private func daemonListed(_ loaded: Set<String>?, asked: [String: Date]) {
        guard let loaded else { return noteDaemonSilent() }
        let now = Date()
        for (sessionId, lastMain) in asked.sorted(by: { $0.key < $1.key }) where !loaded.contains(sessionId) {
            guard let s = store.sessions[sessionId], s.state == .working, !s.pendingDone,
                  s.lastMainEventAt == lastMain else { continue }
            Log.app.notice("Codex daemon has not loaded thread \(sessionId, privacy: .public): nothing runs in it")
            endByRollout(sessionId: sessionId, daemonPath: nil, fallbackEnd: nil, now: now)
        }
    }

    /// The daemon runs nothing in the session's thread, so its turn is over;
    /// the rollout tells how it ended: a finish on `task_complete`, dark on
    /// `turn_aborted`, and dark when the rollout shows no end of this turn,
    /// dated to when the daemon last saw the thread change.
    private func endByRollout(sessionId: String, daemonPath: String?, fallbackEnd: Date?, now: Date) {
        guard let session = store.sessions[sessionId] else { return }
        let verdict = rolloutVerdict(sessionId: sessionId, recorded: session.transcriptPath, daemonPath: daemonPath)
        switch CodexRolloutTail.decision(verdict: verdict, lastMainEventAt: session.lastMainEventAt,
                                         lastMainTurnId: session.lastMainTurnId) {
        case .finished(let endedAt):
            Log.app.notice("""
                lost Stop recovered: Codex session \(sessionId, privacy: .public) — nothing runs \
                in its thread and the rollout ends on task_complete at \(endedAt, privacy: .public) \
                — finished
                """)
            finishTurn(sessionId, now: now, endedAt: endedAt)
        case .aborted(let endedAt):
            Log.app.notice("""
                turn abandoned: Codex session \(sessionId, privacy: .public) — nothing runs in its \
                thread and the rollout ends on turn_aborted at \(endedAt, privacy: .public) — going dark
                """)
            abandonTurn(sessionId, now: now, endedAt: endedAt)
        case .busy, .nothing:
            Log.app.notice("""
                turn abandoned: Codex session \(sessionId, privacy: .public) — nothing runs in its \
                thread and the rollout shows no end of this turn — going dark
                """)
            abandonTurn(sessionId, now: now, endedAt: fallbackEnd)
        }
    }

    private func noteDaemonSilent() {
        guard !warnedDaemonSilent else { return }
        warnedDaemonSilent = true
        Log.app.notice("Codex daemon not answering; using the rollout")
    }

    /// Asks each running job's process whether it still runs a command
    /// (`ShellJobLiveness`), from its begin on, at every pass: the job
    /// store's deadline brings one at least every `K.jobProbeSeconds`, and
    /// `K.jobPromptSettleSeconds` after a first sighting at the prompt. A
    /// shell gone or recycled, or back at its prompt with no child started
    /// since the job began, clears a job whose `job end` never came; a shell
    /// replaced by its program keeps it until that program exits (kqueue).
    /// A `mysidepulse run` wrapper is no shell, so its job is kept.
    private func probeJobs(now: Date) {
        var dropped = false
        for job in jobs.jobs.values where job.state == .running {
            guard let pid = job.ownerPid else { continue }
            let info = ProcWalk.info(for: pid)
            let probe = ShellJobLiveness.probe(info?.shellReading,
                                               children: info == nil ? [] : ProcWalk.childStartTimes(pid: pid),
                                               jobSince: job.stateSince)
            guard let reason = jobs.probe(id: job.id, probe, now: now) else { continue }
            dropped = true
            Log.app.notice("job \(job.id, privacy: .public) ended without a hook (\(reason, privacy: .public))")
        }
        if dropped { armProcessWatchers() }
    }

    /// Wake re-evaluates everything against the wall clock at once.
    func machineWoke() {
        sync()
    }

    private func scheduleNextDeadline(now: Date) {
        deadlineTimer?.cancel()
        deadlineTimer = nil
        var deadline = store.nextDeadline(after: now)
        if let jobDeadline = jobs.nextDeadline(after: now) {
            deadline = deadline.map { min($0, jobDeadline) } ?? jobDeadline
        }
        if let glance = glanceUntil, glance > now {
            deadline = deadline.map { min($0, glance) } ?? glance
        }
        if let previewEnd = previewUntil, previewEnd > now {
            deadline = deadline.map { min($0, previewEnd) } ?? previewEnd
        }
        if let whiteEnd = brightnessPreviewUntil, whiteEnd > now {
            deadline = deadline.map { min($0, whiteEnd) } ?? whiteEnd
        }
        guard let fireAt = deadline else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Wall clock, not monotonic: a monotonic timer suspends with the
        // machine, so every deadline slipped by the length of the nap and a
        // stale state could stand for minutes after the lid opened until the
        // next monitor callback happened to fire.
        timer.schedule(wallDeadline: .now() + max(0.05, fireAt.timeIntervalSince(now)))
        timer.setEventHandler { [weak self] in self?.sync() }
        timer.resume()
        deadlineTimer = timer
    }

    private func armProcessWatchers() {
        let pids = store.trackedPids.union(jobs.trackedPids)
        for pid in pids { procWatcher.watch(pid: pid) }
        procWatcher.unwatchAll(except: pids)
        if !warnedMissingPid, store.trackedPids.isEmpty, !store.sessions.isEmpty {
            warnedMissingPid = true
            Log.app.warning("""
                no session carries an agent pid: process-death detection is \
                inactive and a killed session will hold the strip until the \
                staleness backstop — check the hook's origin walk
                """)
        }
    }

    private func rotateJournalIfNeeded() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: Paths.journal.path))?[.size]
                as? Int else { return }
        let active = store.sessions.values.contains { $0.state != .idle }
        let shouldRotate = size > K.journalHardMaxBytes || (size > K.journalSoftMaxBytes && !active)
        guard shouldRotate else { return }
        try? FileManager.default.removeItem(at: Paths.journalRotated)
        try? FileManager.default.moveItem(at: Paths.journal, to: Paths.journalRotated)
        // Writers recreate the file via O_CREAT; the tailer follows the rename.
    }

    // MARK: notifications

    /// Off the main queue: the sessions-directory scan and the POST must not
    /// sit in front of the next LED write. Alerts are values, so handing them
    /// across is safe.
    private func deliver(_ alerts: [Alert]) {
        guard config.notifyIsLive, let topic = config.notifyTopic else { return }
        let server = config.notifyServerOrDefault
        notifyQueue.async {
            for alert in alerts {
                // Claude's session record says whether the session is an
                // agent of its own (a background, daemon or teammate
                // session lights the strip but must not ring a phone) and
                // carries the claude.ai link. The other agents have neither:
                // a push lands on the agent's own page.
                let click: String
                switch alert.agent {
                case .claude:
                    let record = ClaudeSessions.find(sessionId: alert.sessionId, in: Paths.claudeSessions)
                    if ClaudeSessions.isSilent(record) { continue }
                    click = ClaudeSessions.link(for: record)
                case .codex, .copilot, .opencode:
                    click = alert.agent.homeLink
                }
                let tag = AlertCopy.tag(for: alert.kind)
                guard let request = Notifier.request(
                    server: server, topic: topic, title: AlertCopy.title(for: alert.agent), tag: tag,
                    click: click, message: AlertCopy.message(for: alert.kind))
                else {
                    Log.app.error("notification not sent: unusable server or topic")
                    continue
                }
                // notice so the attempt survives into `log show`: a push the
                // phone never received is only debuggable if the send is on
                // record. This is once per alert, not per tick.
                Log.app.notice("notifying: \(alert.agent.rawValue, privacy: .public) \(tag, privacy: .public)")
                Notifier.send(request) { reason in
                    Log.app.error("notification failed: \(reason, privacy: .public)")
                }
            }
        }
    }

    /// Only the app writes config.json, so every settings change lands here.
    private func applyNotifySettings(_ request: NotifyRequest) -> ControlResponse {
        if let topic = request.topic { config.notifyTopic = topic }
        if let server = request.server { config.notifyServer = server }
        if let enabled = request.enabled {
            // Turning it on with nothing to send to is a dead setting, so mint
            // a topic rather than reporting success and staying silent.
            if enabled, config.notifyTopic?.isEmpty != false {
                config.notifyTopic = Notifier.generateTopic()
            }
            config.notifyEnabled = enabled
        }
        config.save()
        if request.test == true {
            guard config.notifyIsLive, let topic = config.notifyTopic else {
                return ControlResponse(ok: false, error: "notifications are off")
            }
            guard let probe = Notifier.request(
                server: config.notifyServerOrDefault, topic: topic, title: "MySidepulse",
                tag: "bell", click: AgentKind.claude.homeLink,
                message: "MySidepulse test notification")
            else { return ControlResponse(ok: false, error: "unusable server or topic") }
            Notifier.send(probe) { reason in
                Log.app.error("test notification failed: \(reason, privacy: .public)")
            }
        }
        // Reveal the raw topic only when the caller deliberately enabled or
        // changed it and therefore needs it to (re)subscribe. A pure `test`,
        // `off` or `server` change has no reason to re-print the secret.
        let revealTopic = request.enabled == true || request.topic != nil
        return ControlResponse(ok: true, notify: notifyStatus,
                               notifyTopic: revealTopic ? config.notifyTopic : nil)
    }

    private var notifyStatus: NotifyStatus {
        let usable = Notifier.request(
            server: config.notifyServerOrDefault, topic: config.notifyTopic ?? "",
            title: "t", tag: "t", click: "https://claude.ai/code", message: "m") != nil
        return NotifyStatus(enabled: config.notifyIsLive, server: config.notifyServerOrDefault,
                            topicMasked: Notifier.maskTopic(config.notifyTopic),
                            topicUsable: usable)
    }

    // MARK: control plane

    func controlResponse(for request: ControlRequest, loginItemStatus: @escaping () -> String) -> ControlResponse {
        switch request.cmd {
        case "led":
            // "toggle" resolves here, not in the CLI: only the app knows the
            // current mode, so a client flipping it itself would race the menu.
            let requested: LedMode?
            switch request.mode?.lowercased() {
            case "toggle": requested = mode.toggled()
            case let raw?: requested = LedMode.parse(raw)
            case nil: requested = nil
            }
            guard let newMode = requested else {
                return ControlResponse(ok: false, error: "bad mode — use auto|off|toggle|#RRGGBB "
                    + "or an effect (\(LedEffects.names.joined(separator: ", ")))")
            }
            mode = newMode
            return ControlResponse(ok: true, mode: mode.configValue)
        case "brightness-cycle":
            return cycleBrightness(steps: request.steps ?? K.brightnessCycleDefaultSteps)
        case "autostart":
            // Bare read, or on/off. `make uninstall` uses "off" to take the
            // launch agent down *before* the bundle goes: Background Task
            // Management stores the agent against the bundle, so deleting it
            // first leaves a dangling record that breaks the next install's
            // crash restart with no visible sign.
            switch request.mode?.lowercased() {
            case "on": setAutoRestart(true)
            case "off": setAutoRestart(false)
            case nil: break
            case let other?:
                return ControlResponse(ok: false, error: "bad autostart \(other) — use on|off")
            }
            return ControlResponse(ok: true, loginItem: loginItemStatus())
        case "notify":
            guard let notify = request.notify else {
                // Bare `mysidepulse notify` is THE deliberate read — the one
                // command whose contract is to print the whole topic.
                return ControlResponse(ok: true, notify: notifyStatus,
                                       notifyTopic: config.notifyTopic)
            }
            return applyNotifySettings(notify)
        case "status":
            let now = Date()
            let sessions = store.sessions.values
                .sorted { $0.lastEventAt > $1.lastEventAt }
                .map { s in
                    SessionStatus(id: s.id, agent: s.agent.rawValue, state: stateLabel(s.state),
                                  reason: s.waitReason?.rawValue,
                                  ageSeconds: Int(now.timeIntervalSince(s.lastEventAt)),
                                  cwd: s.cwd)
                }
            let deviceList = devices.values.map {
                DeviceStatus(name: $0.name, path: $0.mountPath, leds: $0.ledCount,
                             stalled: writer.stalledKeys.contains($0.key))
            }
            let age = lastEventSeen.map { now.timeIntervalSince($0) }
            return ControlResponse(
                ok: true, mode: mode.configValue, display: displayLabel(display),
                sessions: sessions, devices: deviceList,
                battery: power.map { BatteryStatus(percent: $0.percent, plugged: $0.plugged) },
                loginItem: loginItemStatus(),
                lastEventAgeSeconds: age.map(Int.init),
                jobs: jobs.jobs.values
                    .sorted { $0.stateSince > $1.stateSince }
                    .map { JobStatus(id: $0.id, state: jobLabel($0.state), label: $0.label,
                                     ageSeconds: Int(now.timeIntervalSince($0.stateSince)),
                                     hostBundleId: $0.hostBundleId,
                                     acknowledged: $0.acknowledged) },
                notify: notifyStatus)
        default:
            return ControlResponse(ok: false, error: "unknown command \(request.cmd)")
        }
    }

    private func stateLabel(_ state: SessionState) -> String {
        switch state {
        case .idle: return "idle"
        case .working: return "working"
        case .waiting: return "waiting"
        case .done: return "done"
        }
    }

    private func jobLabel(_ state: JobState) -> String {
        switch state {
        case .running: return "running"
        case .succeeded: return "succeeded"
        case .failed: return "failed"
        }
    }

    /// `mysidepulse status`'s word for the display. An agent state names its
    /// agents: `working (claude+codex)`.
    private func displayLabel(_ display: DisplayState) -> String {
        func who(_ agents: Agents) -> String {
            "(" + agents.kinds.map(\.rawValue).joined(separator: "+") + ")"
        }
        func workLabel(_ work: SplitWork) -> String {
            switch work {
            case .working(let agents): return "working \(who(agents))"
            case .jobRunning: return "job-running"
            }
        }
        switch display {
        case .off: return "off"
        case .working(let agents): return "working \(who(agents))"
        case .waiting(let agents): return "waiting \(who(agents))"
        case .done(let agents): return "done \(who(agents))"
        case .jobRunning: return "job-running"
        case .jobSucceeded: return "job-succeeded"
        case .jobFailed: return "job-failed"
        case .split(let alert, let work):
            let alertLabel: String
            switch alert {
            case .waiting(let agents): alertLabel = "waiting \(who(agents))"
            case .jobFailed: alertLabel = "job-failed"
            case .done(let agents): alertLabel = "done \(who(agents))"
            case .jobSucceeded: alertLabel = "job-succeeded"
            }
            return "\(alertLabel) over \(workLabel(work))"
        case .batteryCritical: return "battery-critical"
        case .batteryGlance: return "battery-glance"
        case .manualColor(let hex): return "forced \(hex)"
        case .effect(let name): return "playing \(name)"
        }
    }
}

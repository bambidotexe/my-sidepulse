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
    private var devices: [DeviceKey: LedDevice] = [:]
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
            store.apply(event)
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
            // Alive is not enough: a pid recycled while the app was down
            // must not keep a dead session's state on the strip.
            self.store.pruneDead { pid in
                (kill(pid, 0) == 0 || errno == EPERM) && ProcWalk.looksLikeClaude(pid: pid)
            }
            // Replayed alerts must not push again: a deadline already long
            // past either fired in the previous instance or was abandoned
            // there. Without this, every `make install` under a standing
            // alert would re-deliver its push a minute later.
            self.store.dropStaleNotifications(now: Date())
            self.armProcessWatchers()
            // Hooks append while the app is away and only the app rotates, so
            // a long absence needs this catch-up — otherwise the journal only
            // rotates once the next live event happens to arrive.
            self.rotateJournalIfNeeded()
            self.sync()
        }
        keepalive.start { [weak self] in
            guard let self else { return [] }
            return DispatchQueue.main.sync { Array(self.devices.values) }
        }
    }

    // MARK: inputs (all on main)

    func handle(_ events: [JournalEvent]) {
        guard !events.isEmpty else { return }
        for event in events { store.apply(event) }
        // Ack lines are the app's own; "last event" answers "are hooks
        // arriving", so only hook traffic may refresh it.
        if let latest = events.filter({ $0.event != .ack }).map(\.loggedAt).max(),
           latest > (lastEventSeen ?? .distantPast) {
            lastEventSeen = latest
        }
        armProcessWatchers()
        rotateJournalIfNeeded()
        sync()
    }

    private func handleProcessExit(_ pid: Int32) {
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
    /// Jobs stay app-level: they are not journaled and carry no tty.
    @discardableResult
    private func acknowledgeAll(bundleId: String, frontTTY: String?) -> Bool {
        let acked = store.acknowledgeAlerts(hostBundleId: bundleId, frontTTY: frontTTY,
                                            hostIsFocusable: AttentionMonitor.hostIsFocusable)
        let jobsSeen = jobs.acknowledge(hostBundleId: bundleId)
        persist(acks: acked)
        return !acked.isEmpty || jobsSeen
    }

    /// An acknowledgement is state the journal replay cannot reconstruct, so
    /// it goes INTO the journal: one `MySidepulseAck` line per cleared alert,
    /// keyed by the alert's stateSince. Without this every restart would
    /// forget what had been seen and resurrect both the amber and its push.
    /// Jobs are not journaled, so job acks are not either — a restart
    /// forgets the whole job.
    private func persist(acks: [AckRecord]) {
        guard !acks.isEmpty else { return }
        for record in acks {
            var event = JournalEvent(loggedAt: Date(), event: .ack)
            event.sessionId = record.sessionId
            event.ackStateSince = record.stateSince
            if let line = try? Trim.cappedLine(event) {
                JournalWriter.append(line, to: Paths.journal)
            }
        }
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
        sync()
    }

    func deviceGone(_ key: DeviceKey) {
        let path = devices[key]?.mountPath ?? "unknown"
        Log.app.notice("device disappeared: \(path, privacy: .public)")
        devices.removeValue(forKey: key)
        writer.deviceGone(key)
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
        let now = Date()
        let alerts = store.tick(now: now, userPresent: AttentionMonitor.userIsPresent())
        jobs.tick(now: now)
        checkAbandonedTurns(now: now)
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
        for device in devices.values {
            let program = LedProgram.program(for: decision, power: paintPower,
                                             ledCount: device.ledCount,
                                             brightness: config.brightness(forVolumeName: device.name))
            writer.write(program: program, to: device)
        }
        attention.setPolling(real.isAlertable)
        scheduleNextDeadline(now: now)
        onStateChanged?()
    }

    /// The quiet-turn check. Esc and Ctrl-C interrupt a turn without firing
    /// any hook (11 of 199 recorded prompts) — and a Ctrl-C can kill hook
    /// delivery for the whole session while its turn keeps running. So a
    /// `working` session that has gone silent is asked about at the source:
    /// Claude Code's own per-process registry record, which does not travel
    /// through hooks.
    /// "idle", stamped after our last main-agent event → the turn is over
    /// and delivered no verdict → dark. "busy" → genuinely still working
    /// (silent thinking, or dead hooks) → stay on the roll and keep the
    /// session alive. Anything else — no record, wrong session, stale
    /// stamp, unknown status — proves nothing and changes nothing.
    private func checkAbandonedTurns(now: Date) {
        for (sessionId, pid) in store.abandonCandidates(at: now) {
            guard let record = ClaudeProcessRegistry.read(pid: pid),
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
            guard let session = store.sessions[sessionId] else { continue }
            if record.isIdle, let stamped = record.statusUpdatedAt,
               stamped > session.lastMainEventAt {
                // The turn is over. HOW it ended is the transcript's to say:
                // a completed assistant answer means the Stop was lost and
                // the finish is real (green, push); anything unanswered is
                // the interrupt (dark); an unreadable transcript decides
                // nothing and dark falls back to the old conservative gate.
                let ending = session.transcriptPath.map(TranscriptTail.verdict(atPath:))
                    ?? .unreadable
                switch ending {
                case .finished:
                    Log.app.notice("""
                        lost Stop recovered: session \(sessionId, privacy: .public) — claude \
                        pid \(pid) reports idle and the transcript ends on a completed \
                        answer — finished
                        """)
                    store.finishTurn(sessionId: sessionId, now: now)
                case .incomplete:
                    Log.app.notice("""
                        turn abandoned: session \(sessionId, privacy: .public) — claude pid \
                        \(pid) reports idle since \(stamped, privacy: .public) with no \
                        completed answer in the transcript — going dark
                        """)
                    store.abandonTurn(sessionId: sessionId, now: now)
                case .unreadable:
                    if now.timeIntervalSince(session.lastEventAt) >= K.abandonUndecidedDarkSeconds {
                        Log.app.notice("""
                            turn abandoned: session \(sessionId, privacy: .public) — claude \
                            pid \(pid) reports idle, the transcript is unreadable, and the \
                            conservative window has passed — going dark
                            """)
                        store.abandonTurn(sessionId: sessionId, now: now)
                    }
                }
            } else if record.isBusy {
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
            }
        }
        // The answered dialog: approving a plan can fire no hook at all, so
        // the wait would otherwise stand until the next tool call drifted
        // in — unbounded in principle. The approval DOES re-stamp the
        // registry busy, so an open wait whose stamp is newer than the
        // dialog itself has been answered — back on the work.
        for (sessionId, pid, stateSince) in store.openWaitCandidates() {
            guard let record = ClaudeProcessRegistry.read(pid: pid),
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
            store.dialogAnswered(sessionId: sessionId, now: now)
        }
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
                no session carries a claude pid: process-death detection is \
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
                let record = ClaudeSessions.find(sessionId: alert.sessionId,
                                                 in: Paths.claudeSessions)
                // A background, daemon or teammate session is an agent of its
                // own: it lights the strip but must not ring a phone.
                if ClaudeSessions.isSilent(record) { continue }
                let tag = AlertCopy.tag(for: alert.kind)
                guard let request = Notifier.request(
                    server: server, topic: topic, title: AlertCopy.title, tag: tag,
                    click: ClaudeSessions.link(for: record),
                    message: AlertCopy.message(for: alert.kind))
                else {
                    Log.app.error("notification not sent: unusable server or topic")
                    continue
                }
                // notice so the attempt survives into `log show`: a push the
                // phone never received is only debuggable if the send is on
                // record. This is once per alert, not per tick.
                Log.app.notice("notifying: \(tag, privacy: .public)")
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
                server: config.notifyServerOrDefault, topic: topic, title: AlertCopy.title,
                tag: "bell", click: "https://claude.ai/code",
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
        case "job-begin":
            guard let job = request.job else {
                return ControlResponse(ok: false, error: "job-begin needs a job")
            }
            jobs.begin(id: job.id, pid: job.pid, slotPid: job.slotPid ?? job.pid,
                       label: job.label, hostBundleId: job.hostBundleId,
                       showAfterSeconds: job.showAfterSeconds ?? K.jobShowAfterDefaultSeconds,
                       now: Date())
            armProcessWatchers()
            sync()
            return ControlResponse(ok: true)
        case "job-end":
            guard let job = request.job else {
                return ControlResponse(ok: false, error: "job-end needs a job")
            }
            jobs.end(id: job.id, exitCode: job.exitCode ?? 0, now: Date())
            armProcessWatchers()
            sync()
            return ControlResponse(ok: true)
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
                    SessionStatus(id: s.id, state: stateLabel(s.state),
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

    private func displayLabel(_ display: DisplayState) -> String {
        switch display {
        case .off: return "off"
        case .working: return "working"
        case .waiting: return "waiting"
        case .done: return "done"
        case .jobRunning: return "job-running"
        case .jobSucceeded: return "job-succeeded"
        case .jobFailed: return "job-failed"
        case .split(let alert, let work):
            let alertLabel: String
            switch alert {
            case .waiting: alertLabel = "waiting"
            case .jobFailed: alertLabel = "job-failed"
            case .done: alertLabel = "done"
            case .jobSucceeded: alertLabel = "job-succeeded"
            }
            return "\(alertLabel) over \(work == .working ? "working" : "job-running")"
        case .batteryCritical: return "battery-critical"
        case .batteryGlance: return "battery-glance"
        case .manualColor(let hex): return "forced \(hex)"
        case .effect(let name): return "playing \(name)"
        }
    }
}

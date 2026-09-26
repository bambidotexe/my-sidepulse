import AppKit
import Combine
import MySidepulseCore
import MySidepulsePlatform

/// The settings window's view of the engine: a published snapshot, refreshed
/// on engine state changes (coalesced) and on a slow tick while the window is
/// visible so ages count up. Main queue only, like everything that touches
/// the engine.
final class SettingsModel: ObservableObject {
    struct DoctorRun {
        let checks: [Doctor.Check]
        let failures: Int
        let at: Date
    }

    @Published private(set) var status: ControlResponse?
    @Published private(set) var displayState: DisplayState = .off
    @Published private(set) var power: PowerState?
    @Published private(set) var mode: LedMode = .auto
    @Published private(set) var brightnessOverrides: [String: Int] = [:]
    @Published private(set) var palette: LedPalette = .standard
    @Published private(set) var doctor: DoctorRun?
    @Published private(set) var doctorRunning = false
    /// The raw topic, held only while the user has deliberately revealed it:
    /// the window's equivalent of running bare `mysidepulse notify`.
    @Published private(set) var revealedTopic: String?

    /// What came of the last test notification, or nil until one is sent.
    enum TestOutcome {
        case sent
        case failed(String)
    }

    @Published private(set) var lastTest: TestOutcome?
    /// True from the moment a topic is minted until the window stops showing it:
    /// the phone cannot be subscribed to a topic it has not seen yet.
    @Published private(set) var newTopicUnsubscribed = false

    weak var engine: Engine?

    /// Opens the Settings window on a page. Set by `AppDelegate`, which owns the window: the
    /// onboarding's Phone alerts row needs the page carrying the QR code the phone scans.
    var showSettings: ((SettingsPageID) -> Void)?
    /// Opens the onboarding wizard again, from the System page's button. Set by `AppDelegate`.
    var showOnboarding: (() -> Void)?

    private var refreshQueued = false
    private var timer: Timer?

    var windowVisible = false {
        didSet {
            timer?.invalidate()
            timer = nil
            guard windowVisible else { return }
            refresh()
            refreshHooks()
            refreshNotificationsGrant()
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                self?.refresh()
                self?.refreshNotificationsGrant()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    /// Engine.onStateChanged fires on every sync, once per event, timer and
    /// paint, so refreshes are coalesced to the next main-queue turn.
    func stateChanged() {
        guard windowVisible, !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            self.refresh()
        }
    }

    func refresh() {
        guard let engine else { return }
        status = engine.controlResponse(for: ControlRequest(cmd: "status")) {
            LoginService.statusDescription
        }
        displayState = engine.display
        power = engine.power
        mode = engine.mode
        brightnessOverrides = engine.brightnessOverrides
        palette = engine.palette
    }

    // MARK: general

    func setMode(_ newMode: LedMode) {
        engine?.mode = newMode
        refresh()
    }

    var autoRestartIsOn: Bool { engine?.autoRestartIsOn ?? false }

    func setAutoRestart(_ wanted: Bool) {
        engine?.setAutoRestart(wanted)
        refresh()
    }

    /// The same path as ⌘Q and the menu bar item: the delegate darkens the
    /// strip, then the app exits zero, which is what tells launchd the quit
    /// was deliberate and leaves it stopped until the next login.
    func quit() {
        NSApp.terminate(nil)
    }

    // MARK: hooks, through the same installer the CLI uses

    /// nil until first read, and when settings.json exists but cannot be read.
    @Published private(set) var claudeHooksSetUp: Bool?
    /// How many of the agent's events are ours, read alongside `claudeHooksSetUp`/`codexHooksSetUp`/
    /// `copilotHooksSetUp`: nil when the file cannot be read, 0 when nothing of ours is there, which the
    /// Health page shows no differently from an agent that has never been set up at all. Copilot's and
    /// OpenCode's Health lines read `copilotHooksSetUp` and `opencodeState` instead, whose own states
    /// already tell "nothing of ours" apart from "unreadable" and "stale".
    @Published private(set) var claudeHooksInstalledCount: Int?
    /// Events holding something of ours, this copy's or not, naming the agent or not: what keeps the Claude
    /// Code line on the Health page while the entries are there and wrong.
    @Published private(set) var claudeHooksPresentCount: Int?
    @Published private(set) var codexHooksInstalledCount: Int?
    @Published private(set) var copilotHooksInstalledCount: Int?
    /// How many of Codex's events in hooks.json Codex trusts in its config.toml: nil when either file
    /// cannot be read. Only a trusted hook runs.
    @Published private(set) var codexHooksTrustedCount: Int?
    /// The same for Codex's hooks: every event in hooks.json **and** trusted in config.toml.
    @Published private(set) var codexHooksSetUp: Bool?
    /// Whether Codex is on this Mac (`~/.codex` exists), read with the hook files: its group and its
    /// Health line are shown only while it is, or while its hooks are set up.
    @Published private(set) var codexInstalled = false
    /// The same as Codex's, for Copilot's owned hooks file.
    @Published private(set) var copilotHooksSetUp: Bool?
    @Published private(set) var copilotInstalled = false
    /// Whether `disableAllHooks` turns every one of Copilot's user hooks off, read with the hook files.
    @Published private(set) var copilotHooksDisabled = false
    /// Absent, exactly what this bundle would write, or someone else's copy: `hooksSetUp` alone cannot
    /// tell the last two apart, and they read differently (Disabled vs. Invalid).
    @Published private(set) var opencodeState: HookInstaller.OpenCodePluginState = .absent
    @Published private(set) var opencodeInstalled = false
    /// Whether the hook files have been read once, which tells "cannot be read" from "not read yet".
    @Published private(set) var hooksRead = false
    @Published private(set) var zshHookSetUp = false
    /// What went wrong in the last Claude Code hook action, cleared when one works.
    @Published private(set) var claudeHooksError: String?
    /// The same, for the Codex hooks.
    @Published private(set) var codexHooksError: String?
    /// The same, for the Copilot hooks and the OpenCode plugin.
    @Published private(set) var copilotHooksError: String?
    @Published private(set) var opencodeHooksError: String?
    /// The same, for the terminal hook.
    @Published private(set) var zshHookError: String?

    /// `opencodeState` in the shape every other agent's row reads: true set up, false absent, nil a copy
    /// of MySidepulse that is not this one, which reads the same as an unreadable settings file elsewhere.
    var opencodeHooksSetUp: Bool? {
        switch opencodeState {
        case .current: true
        case .absent: false
        case .stale: nil
        }
    }

    /// Read when the window opens, when the System page appears and after each
    /// of its buttons, not on the 2 s tick: these are the user's files, and
    /// they change when a button here is pressed.
    func refreshHooks() {
        claudeHooksSetUp = HookInstaller.hooksSetUp(for: .claude)
        claudeHooksInstalledCount = HookInstaller.hooksInstalled(for: .claude)
        claudeHooksPresentCount = HookInstaller.hooksPresent(for: .claude)
        codexHooksSetUp = HookInstaller.hooksSetUp(for: .codex)
        codexHooksInstalledCount = HookInstaller.hooksInstalled(for: .codex)
        codexHooksTrustedCount = HookInstaller.codexHooksTrusted()
        codexInstalled = HookInstaller.codexInstalled()
        copilotHooksSetUp = HookInstaller.hooksSetUp(for: .copilot)
        copilotHooksInstalledCount = HookInstaller.hooksInstalled(for: .copilot)
        copilotInstalled = HookInstaller.copilotInstalled()
        copilotHooksDisabled = HookInstaller.copilotHooksDisabled()
        opencodeState = HookInstaller.opencodePluginState()
        opencodeInstalled = HookInstaller.opencodeInstalled()
        zshHookSetUp = HookInstaller.zshrcHasSnippet()
        hooksRead = true
    }

    /// Whether Codex trusts what of ours is in hooks.json, which tells the System page's warnings apart:
    /// untrusted, and config.toml that cannot be read.
    var codexTrust: HealthFacts.CodexTrust? {
        HealthFacts.codex(installed: codexHooksInstalledCount, trusted: codexHooksTrustedCount).trust
    }

    /// Whether the window shows Codex at all: on a Mac without it there is nothing to set up, and a
    /// group offering to would be noise. Set-up hooks keep the group, so Remove stays reachable.
    var showsCodex: Bool { codexInstalled || codexHooksSetUp == true }
    /// The same, for Copilot's group and Health line.
    var showsCopilot: Bool { copilotInstalled || copilotHooksSetUp == true }
    /// The same, for OpenCode's: a stale plugin from another copy keeps the group too, so Set Up stays
    /// reachable to replace it.
    var showsOpenCode: Bool { opencodeInstalled || opencodeState != .absent }

    private enum HookTarget { case claude, codex, copilot, opencode, zsh }

    func setUpClaudeHooks() {
        hookAction("install-hooks", HookInstaller.installClaudeHooks(), target: .claude)
    }

    func removeClaudeHooks() {
        hookAction("uninstall-hooks", HookInstaller.removeClaudeHooks(), target: .claude)
    }

    func setUpCodexHooks() {
        hookAction("install-codex-hooks", HookInstaller.installCodexHooks(), target: .codex)
    }

    func removeCodexHooks() {
        hookAction("uninstall-codex-hooks", HookInstaller.removeCodexHooks(), target: .codex)
    }

    func setUpCopilotHooks() {
        hookAction("install-copilot-hooks", HookInstaller.installHooks(for: .copilot), target: .copilot)
    }

    func removeCopilotHooks() {
        hookAction("uninstall-copilot-hooks", HookInstaller.removeHooks(for: .copilot), target: .copilot)
    }

    func setUpOpencodePlugin() {
        hookAction("install-opencode-plugin", HookInstaller.installHooks(for: .opencode), target: .opencode)
    }

    func removeOpencodePlugin() {
        hookAction("uninstall-opencode-plugin", HookInstaller.removeHooks(for: .opencode), target: .opencode)
    }

    func setUpZshHook() {
        hookAction("add-to-zshrc", HookInstaller.addToZshrc(), target: .zsh)
    }

    func removeZshHook() {
        hookAction("remove-from-zshrc", HookInstaller.removeFromZshrc(), target: .zsh)
    }

    /// Only the failure is kept: a hook that worked says so through the status row,
    /// which is read back from the files themselves.
    private func hookAction(_ name: String, _ outcome: HookInstaller.Outcome, target: HookTarget) {
        Log.app.notice("\(name, privacy: .public) from settings: \(outcome.message, privacy: .public)")
        let error = outcome.ok ? nil : outcome.message
        switch target {
        case .claude: claudeHooksError = error
        case .codex: codexHooksError = error
        case .copilot: copilotHooksError = error
        case .opencode: opencodeHooksError = error
        case .zsh: zshHookError = error
        }
        refreshHooks()
    }

    // MARK: devices

    func setBrightness(_ value: Int?, forVolumeName name: String) {
        engine?.setBrightness(value, forVolumeName: name)
        refresh()
    }

    // MARK: colours

    func setColor(_ hex: String?, for slot: LedPalette.Slot) {
        engine?.setColor(hex, for: slot)
        refresh()
    }

    func resetColors() {
        engine?.resetColors()
        refresh()
    }

    // MARK: notifications, all through the same control path the CLI uses

    var notifyStatus: NotifyStatus? { status?.notify }

    func setNotifications(enabled: Bool) {
        let response = sendNotify(NotifyRequest(enabled: enabled))
        // Enabling is one of the deliberate reveals: the user must subscribe
        // their phone to the (possibly just-minted) topic right now.
        if enabled, let topic = response?.notifyTopic, !topic.isEmpty {
            revealedTopic = topic
        }
        if !enabled {
            revealedTopic = nil
            newTopicUnsubscribed = false
        }
    }

    func setServer(_ server: String) {
        let trimmed = server.trimmingCharacters(in: .whitespaces)
        sendNotify(NotifyRequest(server: trimmed.isEmpty ? K.notifyServerDefault : trimmed))
    }

    func rotateTopic() {
        let response = sendNotify(NotifyRequest(topic: Notifier.generateTopic()))
        if let topic = response?.notifyTopic, !topic.isEmpty { revealedTopic = topic }
        newTopicUnsubscribed = true
    }

    func sendTest() {
        let response = sendNotify(NotifyRequest(test: true))
        lastTest = response?.ok == true
            ? .sent
            : .failed(response?.error ?? Loc.settings.notifications.appDidNotAnswer)
    }

    func revealTopic() {
        // The bare `notify` read: the one request whose contract is to
        // return the whole topic.
        let response = engine?.controlResponse(for: ControlRequest(cmd: "notify")) { "" }
        revealedTopic = response?.notifyTopic
    }

    func hideTopic() {
        revealedTopic = nil
        newTopicUnsubscribed = false
    }

    @discardableResult
    private func sendNotify(_ request: NotifyRequest) -> ControlResponse? {
        let response = engine?.controlResponse(
            for: ControlRequest(cmd: "notify", notify: request)) { "" }
        refresh()
        return response
    }

    // MARK: permissions

    /// The notification authorization, nil until it has been read once. Read on the 2 s tick while the
    /// window is open, like every system state the window shows, and published only when it moves.
    @Published private(set) var notificationsGranted: Bool?

    func refreshNotificationsGrant() {
        // The model is main-queue only, like the catalog; the answer lands on the main queue too.
        MainActor.assumeIsolated {
            OnboardingCatalog.refreshNotifications { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let granted = OnboardingCatalog.notificationsGranted
                    if granted != self.notificationsGranted { self.notificationsGranted = granted }
                }
            }
        }
    }

    /// The System page's Allow Notifications: the same ask as the wizard's row, and nothing else. Once
    /// the user has refused, macOS shows nothing and this changes nothing; the warning beside the button
    /// says where to go instead.
    func allowNotifications() {
        MainActor.assumeIsolated {
            OnboardingCatalog.requestNotifications { [weak self] in self?.refreshNotificationsGrant() }
        }
    }

    // MARK: health

    /// When each crash report of the app in the last `K.healthCrashWindow` was written: what only the
    /// Health page shows about the process itself, read when the page is shown and on Check Again, never on
    /// the tick.
    @Published private(set) var recentCrashes: [Date] = []
    /// From a press of Check Again until the doctor has answered, and for at least `K.healthMinimumBusy`.
    @Published private(set) var isChecking = false

    /// Called by the window when the Health page is shown: the doctor, the hook files and the crash
    /// reports, read now. The engine's lines follow the 2 s tick on their own.
    func readHealth() {
        refreshHooks()
        readCrashes()
        runDoctor()
    }

    /// Check Again: everything the page shows, read now, with a spinner beside the button until the doctor
    /// has answered and long enough to be seen.
    func checkAgain() {
        guard !isChecking else { return }
        isChecking = true
        let started = Date()
        refresh()
        refreshNotificationsGrant()
        refreshHooks()
        readCrashes()
        runDoctor { [weak self] in
            let left = max(0, K.healthMinimumBusy - Date().timeIntervalSince(started))
            DispatchQueue.main.asyncAfter(deadline: .now() + left) { self?.isChecking = false }
        }
    }

    private func readCrashes() {
        let process = Bundle.main.executableURL?.lastPathComponent ?? "MySidepulseApp"
        let fresh = CrashReports.recent(process: process, since: Date().addingTimeInterval(-K.healthCrashWindow))
        if fresh != recentCrashes { recentCrashes = fresh }
    }

    /// The real doctor, through the real socket, off the main queue: the
    /// probes deadlock into their timeout if run on main (the control server
    /// answers via a main.sync hop). `done` runs on the main queue once it
    /// has answered, or at once if a run is already going.
    func runDoctor(_ done: (() -> Void)? = nil) {
        guard !doctorRunning else { done?(); return }
        doctorRunning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let report = Doctor.run(Doctor.liveProbes())
            DispatchQueue.main.async {
                guard let self else { return }
                self.doctorRunning = false
                self.doctor = DoctorRun(checks: report.checks, failures: report.failures, at: Date())
                done?()
            }
        }
    }

    /// Everything the Health page reports, as the plain values `HealthReport` turns into rows.
    var healthFacts: HealthFacts {
        var facts = HealthFacts()
        facts.notificationsGranted = notificationsGranted

        if hooksRead {
            // A count of nil is a file that cannot be read; zero is nothing of ours there, never set up
            // or removed; anything short of the full count is something of ours but not all of it.
            func state(count: Int?, present: Int? = nil, setUpCount: Int) -> HealthFacts.HookFile {
                guard let count else { return .unreadable }
                // Something of ours that is not this copy's command (another copy's path, or an entry
                // from before the hook named its agent) is there and wrong, never "not set up".
                if count <= 0 { return (present ?? 0) > 0 ? .missing : .notSetUp }
                return count >= setUpCount ? .setUp : .missing
            }
            facts.claudeHooks = state(count: claudeHooksInstalledCount, present: claudeHooksPresentCount,
                                      setUpCount: HookConfig.setUpCount(for: .claude))
            // Codex's hooks count as set up only while every one is there and trusted in config.toml.
            (facts.codexHooks, facts.codexTrust) = HealthFacts.codex(installed: codexHooksInstalledCount,
                                                                     trusted: codexHooksTrustedCount)
            facts.copilotHooks = state(count: copilotHooksInstalledCount, setUpCount: HookConfig.setUpCount(for: .copilot))
            facts.copilotHooksDisabled = copilotHooksDisabled
            // OpenCode's three-way state already tells "nothing of ours" (absent) apart from "unreadable"
            // (a foreign or another copy's file): `hooksInstalled` alone cannot, since both read as zero.
            facts.opencodeHooks = switch opencodeState {
            case .absent: .notSetUp
            case .current: .setUp
            case .stale: .unreadable
            }
            facts.terminalHookSetUp = zshHookSetUp
        }
        let checks = doctor?.checks ?? []
        func check(_ name: String) -> HealthFacts.Check? {
            checks.first { $0.name == name }.map { HealthFacts.Check(ok: $0.ok, detail: $0.detail) }
        }
        facts.hooksCheck = check("hooks installed")
        facts.hookBinary = check("hook binary")
        facts.hookCommand = check("hook command")?.detail
        facts.codexHooksCheck = check("codex hooks")
        facts.codexHookCommand = HookConfig.command(cliPath: HookInstaller.cliPath(), agent: .codex)
        facts.copilotHooksCheck = check("copilot hooks")
        facts.copilotHookCommand = HookConfig.command(cliPath: HookInstaller.cliPath(), agent: .copilot)
        facts.opencodeHooksCheck = check("opencode plugin")
        facts.opencodeHookCommand = HookConfig.command(cliPath: HookInstaller.cliPath(), agent: .opencode)
        facts.journal = check("journal")
        facts.control = check("app")

        if let status {
            facts.lastHookEventSeconds = status.lastEventAgeSeconds
            facts.sessions = (status.sessions ?? []).map {
                HealthFacts.Session(id: $0.id, agent: $0.agent.flatMap(AgentKind.init(rawValue:)) ?? .claude,
                                    phase: .init(state: $0.state, reason: $0.reason),
                                    ageSeconds: $0.ageSeconds, cwd: $0.cwd)
            }
            facts.jobs = (status.jobs ?? []).map {
                HealthFacts.Job(id: $0.id, label: $0.label, phase: .init(state: $0.state),
                                acknowledged: $0.acknowledged, ageSeconds: $0.ageSeconds)
            }
            facts.devices = (status.devices ?? []).map {
                HealthFacts.Device(name: $0.name, leds: $0.leds, path: $0.path, stalled: $0.stalled)
            }
            facts.phone = status.notify.map { notify in
                guard notify.enabled else { return .disabled }
                let detail = Loc.doctor.notificationsOn(topicMasked: notify.topicMasked, server: notify.server)
                return notify.topicUsable ? .enabled(detail: detail) : .unusable(detail: detail)
            }
            facts.launchAgent = status.loginItem.map { item in
                switch item {
                case "enabled": .enabled
                case "disabled": .disabled
                default: .notSupervised
                }
            }
            facts.display = displayState
        }

        facts.recentCrashes = recentCrashes
        return facts
    }

    // MARK: playground

    func startPreview(_ state: DisplayState, power: PowerState? = nil) {
        engine?.setPreview(state, power: power)
        refresh()
    }

    func stopPreview() {
        engine?.setPreview(nil)
        refresh()
    }

    var previewRemainingSeconds: TimeInterval? { engine?.previewRemainingSeconds }
}

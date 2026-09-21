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
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
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
    @Published private(set) var zshHookSetUp = false
    /// What went wrong in the last Claude Code hook action, cleared when one works.
    @Published private(set) var claudeHooksError: String?
    /// The same, for the terminal hook.
    @Published private(set) var zshHookError: String?

    /// Read when the window opens, when the System page appears and after each
    /// of its buttons, not on the 2 s tick: these are the user's files, and
    /// they change when a button here is pressed.
    func refreshHooks() {
        claudeHooksSetUp = HookInstaller.claudeHooksInstalled().map { $0 == HookConfig.events.count }
        zshHookSetUp = HookInstaller.zshrcHasSnippet()
    }

    func setUpClaudeHooks() {
        hookAction("install-hooks", HookInstaller.installClaudeHooks(), claude: true)
    }

    func removeClaudeHooks() {
        hookAction("uninstall-hooks", HookInstaller.removeClaudeHooks(), claude: true)
    }

    func setUpZshHook() {
        hookAction("add-to-zshrc", HookInstaller.addToZshrc(), claude: false)
    }

    func removeZshHook() {
        hookAction("remove-from-zshrc", HookInstaller.removeFromZshrc(), claude: false)
    }

    /// Only the failure is kept: a hook that worked says so through the status row,
    /// which is read back from the files themselves.
    private func hookAction(_ name: String, _ outcome: HookInstaller.Outcome, claude: Bool) {
        Log.app.notice("\(name, privacy: .public) from settings: \(outcome.message, privacy: .public)")
        let error = outcome.ok ? nil : outcome.message
        if claude { claudeHooksError = error } else { zshHookError = error }
        refreshHooks()
    }

    // MARK: devices

    func setBrightness(_ value: Int?, forVolumeName name: String) {
        engine?.setBrightness(value, forVolumeName: name)
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

    // MARK: health

    /// The real doctor, through the real socket, off the main queue: the
    /// probes deadlock into their timeout if run on main (the control server
    /// answers via a main.sync hop).
    func runDoctor() {
        guard !doctorRunning else { return }
        doctorRunning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let report = Doctor.run(Doctor.liveProbes())
            DispatchQueue.main.async {
                guard let self else { return }
                self.doctorRunning = false
                self.doctor = DoctorRun(checks: report.checks, failures: report.failures, at: Date())
            }
        }
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
